-- =============================================================================
-- 012_fila_por_lead.sql — Fila: visão "Por lead" e resolução em lote
--
-- O concorrente passou a agrupar a fila por lead (colunas por prioridade,
-- um card por lead com "N tarefas abertas") e a resolver todas as pendências
-- de um lead com um clique ("Concluir lead"). Aqui:
--   * v_intervention_leads: um card por lead com pendências abertas
--     (prioridade mais alta, contagem, grupos, tags, responsável, idade).
--   * resolve_lead_interventions(): resolve tudo de uma vez, um evento só,
--     com desfecho e liberação da IA opcionais.
--   * request_intervention: dedup por (lead, categoria), não mais por lead.
--
-- Idempotente. Rodar depois de 011.
-- =============================================================================

create or replace view public.v_intervention_leads
with (security_invoker = true) as
select
  h.lead_id, h.office_id,
  min(h.priority)                                                     as priority,        -- 1 = mais urgente
  count(*)                                                            as pendencias,
  count(*) filter (where h.status = 'em_atendimento')                 as em_atendimento,
  array_agg(distinct h.category)                                      as categorias,
  array_agg(distinct g.titulo)                                        as grupos,
  (select array_agg(distinct t) from public.human_interventions h2, unnest(h2.tags) t
    where h2.lead_id = h.lead_id and h2.status in ('pendente','em_atendimento'))   as tags,
  array_agg(h.reason order by h.priority, h.created_at)               as titulos,
  min(h.created_at)                                                   as mais_antiga_em,
  (current_date - min(h.created_at)::date)                            as dias,
  sum(h.calls_count)                                                  as ligacoes,
  (array_agg(h.claimed_by order by h.claimed_at desc nulls last))[1]  as claimed_by,
  (array_agg(pr.full_name order by h.claimed_at desc nulls last))[1]  as responsavel_nome,
  ct.name as contact_name, ct.wa_id as contact_phone,
  l.phase, l.paused, q.faixa, q.verbas_total, l.prescricao_em,
  (select cv.ai_paused from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) as em_atendimento_humano
from public.human_interventions h
join public.leads l on l.id = h.lead_id
join public.contacts ct on ct.id = l.contact_id
left join public.lead_qualification q on q.lead_id = l.id
left join public.profiles pr on pr.user_id = h.claimed_by
cross join lateral public.intervention_group(h.category) g
where h.status in ('pendente','em_atendimento')
group by h.lead_id, h.office_id, ct.name, ct.wa_id, l.id, l.phase, l.paused, q.faixa, q.verbas_total, l.prescricao_em;

-- Concluir lead: resolve todas as pendências abertas de uma vez.
create or replace function public.resolve_lead_interventions(
  p_lead uuid, p_resolution text default 'Concluído em lote', p_release_ai boolean default true, p_outcome text default 'nao_informada')
returns int
language plpgsql security definer set search_path = public as $$
declare l public.leads; n int; v_ids uuid[]; v_conv uuid;
begin
  if auth.uid() is null then raise exception 'resolve_lead_interventions exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  update public.human_interventions
     set status = 'resolvida', resolved_at = now(), resolution = p_resolution,
         outcome = coalesce(p_outcome, 'nao_informada'), claimed_by = coalesce(claimed_by, auth.uid()), claimed_at = coalesce(claimed_at, now())
   where lead_id = p_lead and status in ('pendente','em_atendimento');
  get diagnostics n = row_count;
  if n = 0 then return 0; end if;
  select array_agg(id) into v_ids from public.human_interventions where lead_id = p_lead and resolved_at >= now() - interval '1 second' and status = 'resolvida';
  select id into v_conv from public.conversations where lead_id = p_lead order by last_message_at desc nulls last limit 1;
  perform public.log_event(l.office_id, p_lead, 'interventions_bulk_resolved', 'humano', auth.uid(), null,
    jsonb_build_object('count', n, 'intervention_ids', to_jsonb(v_ids), 'resolution', p_resolution, 'outcome', p_outcome, 'release_ai', p_release_ai), v_conv);
  if p_release_ai and v_conv is not null then perform public.release_to_ai(v_conv); end if;
  return n;
end; $$;

-- Um lead pode ter várias tarefas abertas, uma por categoria (antes: uma só por lead).
-- Repetir a mesma categoria continua devolvendo a existente.
create or replace function public.request_intervention(
  p_lead uuid, p_conversation uuid, p_category text, p_reason text,
  p_priority int default 2, p_actor text default 'ia', p_agent text default null,
  p_note text default null, p_tags text[] default null
) returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  h public.human_interventions;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

  select * into h from public.human_interventions
   where lead_id = p_lead and category = p_category and status in ('pendente','em_atendimento') limit 1;
  if h.id is not null then return h; end if;

  insert into public.human_interventions (office_id, lead_id, conversation_id, category, reason, priority, requested_by_actor, note, tags)
  values (l.office_id, p_lead, p_conversation, p_category, p_reason, least(greatest(coalesce(p_priority, 2), 1), 4), p_actor, p_note, coalesce(p_tags, '{}'))
  returning * into h;

  if p_conversation is not null then
    update public.conversations set ai_paused = true, paused_at = now() where id = p_conversation and not ai_paused;
  end if;
  perform public.log_event(l.office_id, p_lead, 'intervention_requested', p_actor, null, p_agent,
    jsonb_build_object('intervention_id', h.id, 'category', p_category, 'reason', p_reason, 'priority', h.priority, 'tags', to_jsonb(h.tags)), p_conversation);
  return h;
end;
$$;

grant select on public.v_intervention_leads to authenticated;
grant execute on function public.resolve_lead_interventions(uuid, text, boolean, text) to authenticated;
