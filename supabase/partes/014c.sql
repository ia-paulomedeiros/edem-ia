-- =============================================================================
-- 014c — parte 3 de 5 de supabase/014_paridade_regras.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 014b. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- O lead chegou à etapa? Saneador: chegou à peça e alguma peça passou por saneamento.
create or replace function public.lead_reached_stage(p_lead uuid, p_stage text)
returns boolean language sql stable set search_path = public as $$
  select case p_stage
    when 'saneador' then public.lead_max_phase_order(p_lead) >= public.phase_order('peca')
                         and (exists (select 1 from public.pieces p where p.lead_id = p_lead and p.status = 'saneamento')
                              or exists (select 1 from public.case_events e where e.lead_id = p_lead
                                           and ((e.type = 'piece_status_changed' and e.payload->>'to' = 'saneamento')
                                             or (e.type = 'piece_created' and e.payload->>'status' = 'saneamento')
                                             or e.type = 'saneamento_concluido')))
    else public.lead_max_phase_order(p_lead) >=
         (select public.phase_order(s.fases[1]) from public.journey_stages() s where s.role = p_stage) end;
$$;

-- Concluiu a etapa? Closer/Entrevistador/Coletor: passou da última fase.
-- Saneador: não tem mais peça em saneamento. Redator: peça protocolada.
create or replace function public.lead_done_stage(p_lead uuid, p_stage text)
returns boolean language sql stable set search_path = public as $$
  select case p_stage
    when 'saneador' then not exists (select 1 from public.pieces p where p.lead_id = p_lead and p.status = 'saneamento')
    when 'redator' then exists (select 1 from public.pieces p where p.lead_id = p_lead and p.status = 'protocolada')
    else public.lead_max_phase_order(p_lead) >
         (select public.phase_order(s.fases[array_length(s.fases, 1)]) from public.journey_stages() s where s.role = p_stage) end;
$$;

create or replace function public.journey_stage_leads_p(p_office uuid, p_from date, p_to date, p_member uuid, p_role text)
returns setof uuid language sql stable set search_path = public as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to))
  select l.id from public.leads l, b
  where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
    and (p_member is null or l.assigned_to = p_member)
    and public.lead_reached_stage(l.id, public.journey_stage_key(p_role));
$$;

create or replace function public.dashboard_jornada_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  coorte as (
    select l.id, l.phase, l.created_at, public.lead_journey_stage(l.id) as etapa_atual from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  ),
  trocas as (
    select e.lead_id, (e.payload->>'from')::public.case_phase as fase, e.created_at,
           coalesce(lag(e.created_at) over (partition by e.lead_id order by e.seq), c.created_at) as inicio
    from public.case_events e join coorte c on c.id = e.lead_id
    where e.type = 'phase_changed'
  ),
  st as (
    select s.*, public.journey_stage_agents(s.role) as agentes,
      (select count(*) from coorte c where public.lead_reached_stage(c.id, s.role)) as n,
      (select count(*) from coorte c where c.etapa_atual = s.role) as em_fluxo,
      (select count(*) from coorte c where public.lead_reached_stage(c.id, s.role) and public.lead_done_stage(c.id, s.role)) as concluido,
      (select count(distinct e.lead_id) from public.case_events e join coorte c on c.id = e.lead_id
        where e.type = 'intervention_requested' and e.actor_agent = any (public.journey_stage_agents(s.role))) as interv_humana,
      (select round((avg(extract(epoch from (t.created_at - t.inicio))) / 3600)::numeric, 1)
         from trocas t where t.fase = any (s.fases) and s.role not in ('saneador','redator')) as tempo_medio_horas
    from public.journey_stages() s
  ),
  topo as (select coalesce(max(n) filter (where ordem = 1), 0) as n from st)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'leads', (select count(*) from coorte),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object(
                 'ordem', s.ordem, 'agente', s.role, 'titulo', s.titulo, 'fases', to_jsonb(s.fases), 'agentes', to_jsonb(s.agentes),
                 'n', s.n, 'pct_topo', case when topo.n = 0 then 0 else round(s.n::numeric / topo.n * 100) end,
                 'concluido', s.concluido, 'em_fluxo', s.em_fluxo, 'interv_humana', s.interv_humana,
                 'tempo_medio_horas', s.tempo_medio_horas) order by s.ordem), '[]'::jsonb) from st s, topo),
    'primeira_resposta_min', (select round(avg(extract(epoch from (o - i)) / 60)::numeric, 1) from (
        select (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'in') as i,
               (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'out') as o
        from coorte c) t where o is not null and i is not null),
    'dias_ate_contrato', (select round(avg(extract(epoch from (k.signed_at - c.created_at)) / 86400)::numeric, 1)
                          from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado'),
    'mensagens_por_lead', (select round(avg(n)::numeric, 1) from (
        select count(m.id) as n from coorte c
        left join public.conversations cv on cv.lead_id = c.id
        left join public.messages m on m.conversation_id = cv.id group by c.id) t)
  )
  from b
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- 4b/5b/6b. apply_agent_effects: agente por lead, encerramento com código,
-- Saneador devolve a peça para revisão. Mesma assinatura da 013.
-- -----------------------------------------------------------------------------
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null, p_task jsonb default null, p_contract jsonb default null, p_briefing jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
  v_task uuid; k public.contracts; b public.briefings;
  v_role text;
  v_piece uuid;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  v_role := coalesce(nullif(p_agent_role, ''), public.agent_for_lead(p_lead));

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
      empresa_cnpj          = coalesce(p_case_data->>'empresa_cnpj', d.empresa_cnpj),
      motivo_saida          = coalesce(p_case_data->>'motivo_saida', d.motivo_saida),
      acidente_trabalho     = coalesce((p_case_data->>'acidente_trabalho')::boolean, d.acidente_trabalho),
      tem_caso              = coalesce((p_case_data->>'tem_caso')::boolean, d.tem_caso),
      objecao_principal     = coalesce(p_case_data->>'objecao_principal', d.objecao_principal),
      objecao_detalhe       = coalesce(p_case_data->>'objecao_detalhe', d.objecao_detalhe),
      updated_by_actor      = 'ia'
    where d.lead_id = p_lead;

    if p_case_data ? 'cpf' and not public.cpf_valido(p_case_data->>'cpf') then
      v_result := v_result || jsonb_build_object('cpf_invalido', true);
    end if;
    update public.contacts ct set
      cpf = case when public.cpf_valido(p_case_data->>'cpf') then public.cpf_formatado(p_case_data->>'cpf') else ct.cpf end,
      email = coalesce(p_case_data->>'email', ct.email),
      nascimento = coalesce((p_case_data->>'nascimento')::date, ct.nascimento), estado_civil = coalesce(p_case_data->>'estado_civil', ct.estado_civil),
      nacionalidade = coalesce(p_case_data->>'nacionalidade', ct.nacionalidade), endereco = coalesce(p_case_data->>'endereco', ct.endereco),
      cep = coalesce(p_case_data->>'cep', ct.cep), cidade = coalesce(p_case_data->>'cidade', ct.cidade), uf = coalesce(p_case_data->>'uf', ct.uf)
    where ct.id = l.contact_id;
    v_result := v_result || jsonb_build_object('case_data_updated', true);
  end if;

  if p_advance_to is not null and p_advance_to <> '' then
    if p_advance_to = 'encerrado' then
      -- encerramento pela IA: advance_reason é o código de close_reasons()
      l := public.close_lead_with_reason(p_lead, coalesce(nullif(p_advance_reason, ''), 'outro'), 'outro', null, 'ia', null, v_role);
      v_result := v_result || jsonb_build_object('phase', l.phase, 'closed_kind', l.closed_kind, 'closed_code', l.closed_code);
    elsif p_advance_to = 'revisao' then
      -- Saneador: pendências respondidas, a peça volta para o revisor
      select id into v_piece from public.pieces where lead_id = p_lead and status = 'saneamento' order by created_at desc limit 1;
      if v_piece is not null then
        update public.pieces set status = 'revisao', generated_by_actor = 'ia', updated_at = now() where id = v_piece;
        perform public.log_event(l.office_id, p_lead, 'saneamento_concluido', 'ia', null, v_role,
          jsonb_build_object('piece_id', v_piece, 'reason', p_advance_reason), p_conversation);
        v_result := v_result || jsonb_build_object('piece_id', v_piece, 'piece_status', 'revisao');
      end if;
    else
      l := public.advance_phase(p_lead, p_advance_to::public.case_phase, 'ia', null, v_role, p_advance_reason);
      v_result := v_result || jsonb_build_object('phase', l.phase);
    end if;
  end if;

  if p_intervention is not null and jsonb_typeof(p_intervention) = 'object' then
    if jsonb_typeof(p_intervention->'tags') = 'array' then
      select array_agg(x) into v_tags from jsonb_array_elements_text(p_intervention->'tags') x;
    end if;
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', v_role,
           p_intervention->>'note', v_tags);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  if p_task is not null and jsonb_typeof(p_task) = 'object' and coalesce(p_task->>'title', '') <> '' then
    insert into public.tasks (office_id, lead_id, title, description, due_at, assigned_to, created_by_actor)
    values (l.office_id, p_lead, p_task->>'title', p_task->>'description',
            coalesce((p_task->>'due_at')::timestamptz, (current_date + 1) + time '09:00'), l.assigned_to, 'ia')
    returning id into v_task;
    v_result := v_result || jsonb_build_object('task_id', v_task);
  end if;

  if p_contract is not null and jsonb_typeof(p_contract) = 'object' and p_contract->>'action' = 'send' then
    k := public.request_contract(p_lead, 'ia', null, (p_contract->>'honorarios_percent')::numeric);
    v_result := v_result || jsonb_build_object('contract_id', k.id);
  end if;

  if p_briefing is not null and jsonb_typeof(p_briefing) = 'object' and p_briefing <> '{}'::jsonb then
    b := public.upsert_briefing(p_lead, p_briefing, 'ia', null, coalesce(v_role, 'briefing'));
    v_result := v_result || jsonb_build_object('briefing_id', b.id, 'briefing_status', b.status);
  end if;

  return v_result || jsonb_build_object('agent_role', v_role);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Marketing: Claude (Anthropic) e OpenAI separados
-- -----------------------------------------------------------------------------
-- Claude = lançado em tokens/tokens_anthropic; sem lançamento no dia, a
-- estimativa pelas mensagens da IA (ai_meta.cost_usd). OpenAI = lançado em
-- tokens_openai (Whisper não é estimado).
create or replace function public.marketing_tokens_split(p_office uuid, p_from date, p_to date)
returns table (dia date, anthropic_brl numeric, openai_brl numeric, tokens_brl numeric, tokens_usd numeric,
               origem_anthropic text, origem_openai text)
language sql stable set search_path = public as $$
  with cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  lanc as (
    select a.dia,
           sum(a.valor) filter (where a.canal in ('tokens','tokens_anthropic')) as ant_brl,
           sum(a.valor_usd) filter (where a.canal in ('tokens','tokens_anthropic')) as ant_usd,
           sum(a.valor) filter (where a.canal = 'tokens_openai') as oai_brl,
           sum(a.valor_usd) filter (where a.canal = 'tokens_openai') as oai_usd
    from public.ad_spend a
    where a.office_id = p_office and public.canal_tipo(a.canal) = 'tokens' and a.dia >= p_from and a.dia <= p_to
    group by a.dia
  ),
  est as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
    from public.messages m
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= p_from::timestamptz and m.created_at < (p_to + 1)::timestamptz
    group by 1
  )
  select d.dia::date,
         coalesce(l.ant_brl, round(coalesce(e.usd, 0) * cambio.v, 2)) as anthropic_brl,
         coalesce(l.oai_brl, 0) as openai_brl,
         coalesce(l.ant_brl, round(coalesce(e.usd, 0) * cambio.v, 2)) + coalesce(l.oai_brl, 0) as tokens_brl,
         coalesce(l.ant_usd, case when l.ant_brl is null then e.usd end, 0) + coalesce(l.oai_usd, 0) as tokens_usd,
         case when l.ant_brl is not null then 'lancado' when e.dia is not null then 'estimado' else 'nenhum' end,
         case when l.oai_brl is not null then 'lancado' else 'nenhum' end
  from generate_series(p_from, p_to, interval '1 day') as d(dia)
  cross join cambio
  left join lanc l on l.dia = d.dia::date
  left join est e on e.dia = d.dia::date;
$$;

-- Mesma assinatura da 009; agora soma Claude + OpenAI.
create or replace function public.marketing_tokens_por_dia(p_office uuid, p_from date, p_to date)
returns table (dia date, tokens_brl numeric, tokens_usd numeric, origem text)
language sql stable set search_path = public as $$
  select s.dia, s.tokens_brl, s.tokens_usd,
         case when s.origem_anthropic = 'lancado' or s.origem_openai = 'lancado' then 'lancado' else s.origem_anthropic end
  from public.marketing_tokens_split(p_office, p_from, p_to) s;
$$;

create or replace view public.v_marketing_dia with (security_invoker = true) as
select v.*,
  coalesce((select sum(a.valor) from public.ad_spend a where a.office_id = v.office_id and a.dia = v.dia and a.canal in ('tokens','tokens_anthropic')), 0) as tokens_anthropic_brl,
  coalesce((select sum(a.valor) from public.ad_spend a where a.office_id = v.office_id and a.dia = v.dia and a.canal = 'tokens_openai'), 0) as tokens_openai_brl
from public.v_marketing_lancamentos v;

create or replace function public.marketing_dia_p(p_office uuid, p_from date default null, p_to date default null)
returns setof public.v_marketing_dia language sql stable set search_path = public as $$
  select v.* from public.v_marketing_dia v, public.period_bounds(p_office, p_from, p_to) b
  where v.office_id = p_office and v.dia >= b.p_start::date and v.dia < b.p_end::date
  order by v.dia desc;
$$;

-- ---------- Verificação da parte 014c: deve voltar uma linha com resultado = OK
select '014c' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função apply_agent_effects', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'apply_agent_effects')),
    ('função dashboard_jornada_p', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'dashboard_jornada_p')),
    ('função journey_stage_leads_p', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'journey_stage_leads_p')),
    ('função lead_done_stage', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_done_stage')),
    ('função lead_reached_stage', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_reached_stage')),
    ('função marketing_dia_p', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'marketing_dia_p')),
    ('função marketing_tokens_por_dia', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'marketing_tokens_por_dia')),
    ('função marketing_tokens_split', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'marketing_tokens_split')),
    ('view v_marketing_dia', to_regclass('public.v_marketing_dia') is not null)
) as v(item, ok);
