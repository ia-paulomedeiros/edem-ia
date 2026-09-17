-- =============================================================================
-- 005_funil.sql — Funil de Venda como o concorrente mostra
--
-- Quatro macro-etapas sobre a coorte de leads criados no mês:
--   novos_leads     todos os leads da coorte
--   abertura        leads que responderam 2+ mensagens (a "régua")
--   links_enviados  leads com contrato enviado (contracts.sent_at)
--   contratos       leads com contrato assinado
-- Para cada etapa: n, % do topo, conversão da etapa anterior e quantos leads
-- da etapa tiveram intervenção humana (fila ou takeover).
-- dashboard_funil() ganha a chave 'macro'; dashboard_funil_leads() lista os
-- leads de uma etapa (clique no card) como linhas de v_case_cards.
--
-- Idempotente. Depende de 001..004.
-- =============================================================================

-- Conjunto de leads de cada macro-etapa. security definer só para poder ser
-- usado dentro das RPCs; o resultado sempre é filtrado por RLS em quem chama.
create or replace function public.funil_stage_leads(p_office uuid, p_month date, p_member uuid, p_etapa text)
returns setof uuid
language sql stable
set search_path = public
as $$
  with b as (select * from public.month_bounds(p_month)),
  coorte as (
    select l.id from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  )
  select c.id from coorte c
  where case p_etapa
    when 'novos_leads' then true
    when 'abertura' then (
      select count(*) from public.messages m
      join public.conversations cv on cv.id = m.conversation_id
      where cv.lead_id = c.id and m.direction = 'in') >= 2
    when 'links_enviados' then exists (
      select 1 from public.contracts k where k.lead_id = c.id and k.sent_at is not null)
    when 'contratos' then exists (
      select 1 from public.contracts k where k.lead_id = c.id and k.status = 'assinado')
    else false end;
$$;

create or replace function public.dashboard_funil(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.month_bounds(p_month)),
  coorte as (
    select l.* from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  ),
  fases as (select unnest(enum_range(null::public.case_phase)) as phase),
  alcancou as (
    select f.phase,
           (select count(distinct c.id) from coorte c
            where public.phase_order(c.phase) >= public.phase_order(f.phase)
               or exists (select 1 from public.case_events e
                          where e.lead_id = c.id and e.type = 'phase_changed'
                            and (e.payload->>'to')::public.case_phase = f.phase)) as n
    from fases f
  ),
  macro_def as (
    select * from (values
      (1, 'novos_leads',    'Novos leads',        null::text),
      (2, 'abertura',       'Taxa de abertura',   '2+ msgs'),
      (3, 'links_enviados', 'Links enviados',     null),
      (4, 'contratos',      'Contratos fechados', null)
    ) as v(ordem, etapa, titulo, regua)
  ),
  macro_n as (
    select d.ordem, d.etapa, d.titulo, d.regua,
           (select count(*) from public.funil_stage_leads(p_office, p_month, p_member, d.etapa)) as n,
           (select count(*) from public.funil_stage_leads(p_office, p_month, p_member, d.etapa) s
             where exists (select 1 from public.human_interventions h where h.lead_id = s)
                or exists (select 1 from public.case_events e where e.lead_id = s and e.type = 'takeover')) as interv_humana
    from macro_def d
  ),
  macro as (
    select m.*,
           lag(m.n) over (order by m.ordem) as n_anterior,
           first_value(m.n) over (order by m.ordem) as topo
    from macro_n m
  )
  select jsonb_build_object(
    'mes', to_char(date_trunc('month', p_month), 'YYYY-MM'),
    'leads', (select count(*) from coorte),
    'macro', (select coalesce(jsonb_agg(jsonb_build_object(
                'ordem', ordem, 'etapa', etapa, 'titulo', titulo, 'regua', regua,
                'n', n,
                'pct_topo', case when topo = 0 then 0 else round(n::numeric / topo * 100) end,
                'conv_etapa', case when n_anterior is null then null when n_anterior = 0 then 0 else round(n::numeric / n_anterior * 100) end,
                'interv_humana', interv_humana
              ) order by ordem), '[]'::jsonb) from macro),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object(
                 'fase', a.phase, 'alcancaram', a.n,
                 'taxa', case when (select count(*) from coorte) = 0 then 0
                              else round(a.n::numeric / (select count(*) from coorte) * 100, 1) end
               ) order by public.phase_order(a.phase)), '[]'::jsonb)
               from alcancou a where a.phase <> 'encerrado'),
    'atual', (select coalesce(jsonb_agg(jsonb_build_object('fase', phase, 'leads', n) order by public.phase_order(phase)), '[]'::jsonb)
              from (select phase, count(*) as n from coorte group by phase) t),
    'encerrados', jsonb_build_object(
      'ia',     (select count(*) from coorte where phase = 'encerrado' and closed_by = 'ia'),
      'equipe', (select count(*) from coorte where phase = 'encerrado' and closed_by = 'equipe')
    ),
    'qualificacao', jsonb_build_object(
      'aprovados', (select count(*) from coorte c join public.lead_qualification q on q.lead_id = c.id where q.passed),
      'reprovados', (select count(*) from coorte c join public.lead_qualification q on q.lead_id = c.id where not q.passed)
    ),
    'contratos', (select count(*) from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado')
  )
  where public.is_office_member(p_office);
$$;

-- Clique na etapa: os leads dela, como cards (respeita RLS via v_case_cards).
create or replace function public.dashboard_funil_leads(p_office uuid, p_etapa text, p_month date default current_date, p_member uuid default null, p_limit int default 200)
returns setof public.v_case_cards
language sql stable
set search_path = public
as $$
  select v.* from public.v_case_cards v
  where v.office_id = p_office
    and v.lead_id in (select public.funil_stage_leads(p_office, p_month, p_member, p_etapa))
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

grant execute on function public.funil_stage_leads(uuid, date, uuid, text) to authenticated;
grant execute on function public.dashboard_funil(uuid, date, uuid) to authenticated;
grant execute on function public.dashboard_funil_leads(uuid, text, date, uuid, int) to authenticated;
