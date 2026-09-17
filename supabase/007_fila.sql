-- =============================================================================
-- 007_fila.sql — Intervenção humana como esteira (kanban por tipo de tarefa)
--
-- O card da fila precisa de: grupo (coluna), prioridade P1..P4, faixa de
-- ticket, marcadores ("frágil"), título e observação da IA, contadores de
-- ligações / mensagens / dias, responsável. E o topo precisa de busca e
-- filtro por responsável.
--
--   * human_interventions: priority 1..4, note, tags, calls_count, categorias novas
--   * intervention_group(category): a coluna de cada tipo (uma função, para UI e relatórios)
--   * v_intervention_cards: tudo que o card mostra, numa view (RLS via invoker)
--   * request_intervention() ganha p_note e p_tags; apply_agent_effects() repassa
--   * assign_intervention(), log_intervention_call()
--
-- Idempotente. Depende de 001..006.
-- =============================================================================

alter table public.human_interventions drop constraint if exists human_interventions_priority_check;
alter table public.human_interventions add constraint human_interventions_priority_check check (priority between 1 and 4);

alter table public.human_interventions add column if not exists note text;            -- observação da IA (itálico no card)
alter table public.human_interventions add column if not exists tags text[] not null default '{}';  -- 'fragil', 'reincidente', ...
alter table public.human_interventions add column if not exists calls_count int not null default 0;

alter table public.human_interventions drop constraint if exists human_interventions_category_check;
alter table public.human_interventions add constraint human_interventions_category_check
  check (category in (
    'duvida_juridica','fora_de_escopo','cliente_insatisfeito','pedido_de_humano','erro_ia','prescricao','outro',
    'agendamento','caso_escalado','follow_up_esgotado','seguir_conversa','contrato_nao_assinado_24h','ia_sem_resposta','cliente_ja_existente',
    'saneamento_juridico','spam','caso_parado'
  ));

-- Coluna da esteira para cada tipo. Ordem = ordem das colunas.
create or replace function public.intervention_group(p_category text)
returns table(grupo text, titulo text, ordem int)
language sql immutable as $$
  select * from (values
    ('seguir_conversa', 'Seguir conversa', 1),
    ('follow',          'Follow',          2),
    ('agendamento',     'Agendamento',     3),
    ('saneamento',      'Saneamento',      4),
    ('avisos',          'Avisos',          5),
    ('suporte_spam',    'Suporte/Spam',    6),
    ('escalados',       'Escalados',       7)
  ) as g(grupo, titulo, ordem)
  where g.grupo = case p_category
    when 'seguir_conversa' then 'seguir_conversa'
    when 'caso_parado' then 'seguir_conversa'
    when 'follow_up_esgotado' then 'follow'
    when 'contrato_nao_assinado_24h' then 'follow'
    when 'agendamento' then 'agendamento'
    when 'saneamento_juridico' then 'saneamento'
    when 'ia_sem_resposta' then 'avisos'
    when 'prescricao' then 'avisos'
    when 'erro_ia' then 'avisos'
    when 'cliente_ja_existente' then 'suporte_spam'
    when 'spam' then 'suporte_spam'
    when 'fora_de_escopo' then 'suporte_spam'
    else 'escalados' end;
$$;

-- request_intervention com observação e marcadores (substitui a assinatura antiga)
drop function if exists public.request_intervention(uuid, uuid, text, text, int, text, text);
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
   where lead_id = p_lead and status in ('pendente','em_atendimento') limit 1;
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
revoke execute on function public.request_intervention(uuid, uuid, text, text, int, text, text, text, text[]) from anon, authenticated;

-- apply_agent_effects repassa note/tags da intervenção pedida pelo agente
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

  if p_case_data is not null and jsonb_typeof(p_case_data) = 'object' and p_case_data <> '{}'::jsonb then
    insert into public.case_data (lead_id, office_id, updated_by_actor) values (p_lead, l.office_id, 'ia') on conflict (lead_id) do nothing;
    update public.case_data d set
      empresa               = coalesce(p_case_data->>'empresa', d.empresa),
      cargo                 = coalesce(p_case_data->>'cargo', d.cargo),
      admissao              = coalesce((p_case_data->>'admissao')::date, d.admissao),
      demissao              = coalesce((p_case_data->>'demissao')::date, d.demissao),
      salario               = coalesce((p_case_data->>'salario')::numeric, d.salario),
      tipo_rescisao         = coalesce(p_case_data->>'tipo_rescisao', d.tipo_rescisao),
      aviso_previo          = coalesce(p_case_data->>'aviso_previo', d.aviso_previo),
      ctps_assinada         = coalesce((p_case_data->>'ctps_assinada')::boolean, d.ctps_assinada),
      fgts_depositado       = coalesce((p_case_data->>'fgts_depositado')::boolean, d.fgts_depositado),
      ferias_vencidas       = coalesce((p_case_data->>'ferias_vencidas')::int, d.ferias_vencidas),
      horas_extras_semanais = coalesce((p_case_data->>'horas_extras_semanais')::numeric, d.horas_extras_semanais),
      verbas_pagas          = coalesce((p_case_data->>'verbas_pagas')::numeric, d.verbas_pagas),
      extras                = d.extras || coalesce(p_case_data->'extras', '{}'::jsonb),
      updated_by_actor      = 'ia'
    where d.lead_id = p_lead;
    v_result := v_result || jsonb_build_object('case_data_updated', true);
  end if;

  if p_advance_to is not null and p_advance_to <> '' then
    l := public.advance_phase(p_lead, p_advance_to::public.case_phase, 'ia', null, p_agent_role, p_advance_reason);
    v_result := v_result || jsonb_build_object('phase', l.phase);
  end if;

  if p_intervention is not null and jsonb_typeof(p_intervention) = 'object' then
    if jsonb_typeof(p_intervention->'tags') = 'array' then
      select array_agg(x) into v_tags from jsonb_array_elements_text(p_intervention->'tags') x;
    end if;
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', p_agent_role,
           p_intervention->>'note', v_tags);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  return v_result;
end;
$$;

-- Atribuir a um membro (sem precisar ser quem clica). Assume a conversa em nome dele.
create or replace function public.assign_intervention(p_id uuid, p_user uuid)
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'assign_intervention exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if p_user is not null and not exists (select 1 from public.office_members where office_id = h.office_id and user_id = p_user) then
    raise exception 'usuário não é membro do escritório';
  end if;
  if h.status in ('resolvida','cancelada') then return h; end if;
  update public.human_interventions
     set claimed_by = p_user, claimed_at = case when p_user is null then null else now() end,
         status = case when p_user is null then 'pendente' else 'em_atendimento' end
   where id = p_id returning * into h;
  if p_user is not null and h.conversation_id is not null then perform public.take_over(h.conversation_id, p_user); end if;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_assigned', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'assigned_to', p_user), h.conversation_id);
  return h;
end;
$$;

-- "Lig": registra uma ligação feita para o lead
create or replace function public.log_intervention_call(p_id uuid, p_note text default null)
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'log_intervention_call exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  update public.human_interventions set calls_count = calls_count + 1 where id = p_id returning * into h;
  perform public.log_event(h.office_id, h.lead_id, 'call_logged', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'note', p_note, 'calls_count', h.calls_count), h.conversation_id);
  return h;
end;
$$;

-- O card inteiro
create or replace view public.v_intervention_cards
with (security_invoker = true) as
select
  h.id, h.office_id, h.lead_id, h.conversation_id,
  h.category, g.grupo, g.titulo as grupo_titulo, g.ordem as grupo_ordem,
  h.reason, h.note, h.tags, h.priority, h.status, h.requested_by_actor,
  h.claimed_by, pr.full_name as responsavel_nome, h.claimed_at, h.resolved_at, h.outcome, h.created_at,
  ct.name as contact_name, ct.wa_id as contact_phone,
  l.phase, q.faixa, q.verbas_total, l.prescricao_em,
  h.calls_count,
  (select count(*) from public.messages m where m.conversation_id = h.conversation_id and m.created_at >= h.created_at) as msgs_count,
  (current_date - h.created_at::date) as dias
from public.human_interventions h
join public.leads l on l.id = h.lead_id
join public.contacts ct on ct.id = l.contact_id
left join public.lead_qualification q on q.lead_id = l.id
left join public.profiles pr on pr.user_id = h.claimed_by
cross join lateral public.intervention_group(h.category) g;

grant select on public.v_intervention_cards to authenticated;
grant execute on function public.intervention_group(text) to authenticated;
grant execute on function public.assign_intervention(uuid, uuid) to authenticated;
grant execute on function public.log_intervention_call(uuid, text) to authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb) from anon, authenticated;
