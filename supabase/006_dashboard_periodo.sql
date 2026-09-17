-- =============================================================================
-- 006_dashboard_periodo.sql — período livre e as abas como o concorrente mostra
--
--   * Período: todas as RPCs do dashboard ganham versão *_p(p_from, p_to);
--     as versões por mês viram atalhos. "Todo o período" = p_from nulo.
--   * Jornada do Cliente: sete etapas (uma por agente) com alcançaram, concluído,
--     em fluxo, intervenção humana e tempo médio na etapa; clique lista clientes.
--   * Produtividade Humana: fila de intervenção com desfecho ("por forma"),
--     tipo, ranking por pessoa e conclusões por dia.
--       - human_interventions.outcome (desfecho) e categorias novas
--       - resolve_intervention() ganha p_outcome
--   * Investimento Financeiro: gasto com anúncios (ad_spend) + tokens em BRL
--     (office_params.cambio_usd_brl), contratos e protocolos por dia.
--       - pieces.protocolado_em + trigger
--
-- Idempotente. Depende de 001..005.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

alter table public.office_params add column if not exists cambio_usd_brl numeric not null default 5.50;

create table if not exists public.ad_spend (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid not null references public.offices(id) on delete cascade,
  dia         date not null,
  canal       text not null default 'meta_ads' check (canal in ('meta_ads','google_ads','tiktok_ads','outro')),
  valor       numeric not null check (valor >= 0),
  nota        text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  unique (office_id, dia, canal)
);
create index if not exists ad_spend_office_dia_idx on public.ad_spend(office_id, dia);
select public.apply_office_rls('ad_spend', array['admin','advogado']);
select public.add_to_realtime('ad_spend');

alter table public.pieces add column if not exists protocolado_em timestamptz;
create index if not exists pieces_protocolado_idx on public.pieces(office_id, protocolado_em) where status = 'protocolada';

create or replace function public.pieces_effects()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor text := case when auth.uid() is not null then 'humano' else coalesce(new.generated_by_actor, 'sistema') end;
begin
  if tg_op = 'INSERT' then
    perform public.log_event(new.office_id, new.lead_id, 'piece_created', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'tese', new.tese, 'status', new.status));
    return new;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'protocolada' then
      new.protocolado_em := coalesce(new.protocolado_em, now());
    end if;
    perform public.log_event(new.office_id, new.lead_id, 'piece_status_changed', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'from', old.status, 'to', new.status, 'protocolo', new.protocolo));
  end if;
  return new;
end; $$;
drop trigger if exists pieces_effects on public.pieces;
create trigger pieces_effects before insert or update on public.pieces
  for each row execute function public.pieces_effects();

-- Fila: tipos do concorrente somados aos nossos, e o desfecho ("por forma")
alter table public.human_interventions drop constraint if exists human_interventions_category_check;
alter table public.human_interventions add constraint human_interventions_category_check
  check (category in (
    'duvida_juridica','fora_de_escopo','cliente_insatisfeito','pedido_de_humano','erro_ia','prescricao','outro',
    'agendamento','caso_escalado','follow_up_esgotado','seguir_conversa','contrato_nao_assinado_24h','ia_sem_resposta','cliente_ja_existente'
  ));
alter table public.human_interventions add column if not exists outcome text
  check (outcome is null or outcome in (
    'sanado','cliente_perdido','follow_up_agendado','cliente_retomado','reativado_para_agente',
    'assumido_pelo_humano','tarefa_cancelada','outro','nao_informada'
  ));
create index if not exists human_interventions_resolved_idx on public.human_interventions(office_id, resolved_at) where status = 'resolvida';

drop function if exists public.resolve_intervention(uuid, text, boolean);
create or replace function public.resolve_intervention(p_id uuid, p_resolution text, p_release_ai boolean default true, p_outcome text default 'nao_informada')
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'resolve_intervention exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if h.status in ('resolvida','cancelada') then return h; end if;
  update public.human_interventions
     set status = 'resolvida', resolved_at = now(), resolution = p_resolution,
         outcome = coalesce(p_outcome, 'nao_informada'), claimed_by = coalesce(claimed_by, auth.uid())
   where id = p_id returning * into h;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_resolved', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'resolution', p_resolution, 'outcome', h.outcome, 'release_ai', p_release_ai), h.conversation_id);
  if p_release_ai and h.conversation_id is not null then perform public.release_to_ai(h.conversation_id); end if;
  return h;
end;
$$;
grant execute on function public.resolve_intervention(uuid, text, boolean, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Período: [p_from, p_to] em dias, inclusivo. p_from nulo = desde o primeiro lead.
-- -----------------------------------------------------------------------------

create or replace function public.period_bounds(p_office uuid, p_from date, p_to date, out p_start timestamptz, out p_end timestamptz)
language sql stable set search_path = public as $$
  select coalesce(p_from, (select min(created_at)::date from public.leads where office_id = p_office), current_date)::timestamptz,
         (coalesce(p_to, current_date) + 1)::timestamptz;
$$;

-- -----------------------------------------------------------------------------
-- Geral (período)
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_geral_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  signed as (
    select k.*, l.assigned_to, ct.uf
    from public.contracts k
    join public.leads l on l.id = k.lead_id
    join public.contacts ct on ct.id = l.contact_id
    where k.office_id = p_office and k.status = 'assinado'
      and (p_member is null or l.assigned_to = p_member)
  ),
  in_p as (select s.* from signed s, b where s.signed_at >= b.p_start and s.signed_at < b.p_end),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'fechados', jsonb_build_object(
      'hoje',    (select count(*) from signed where signed_at::date = current_date),
      'semana',  (select count(*) from signed where signed_at >= date_trunc('week', now())),
      'mes',     (select count(*) from signed where signed_at >= date_trunc('month', now())),
      'periodo', (select count(*) from in_p)
    ),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object(
                  'dia', d.dia,
                  'contratos', (select count(*) from in_p m where m.signed_at::date = d.dia),
                  'valor_causa', (select coalesce(sum(valor_causa), 0) from in_p m where m.signed_at::date = d.dia)
                ) order by d.dia), '[]'::jsonb) from dias d),
    'por_uf', (select coalesce(jsonb_agg(jsonb_build_object('uf', uf, 'contratos', n) order by n desc), '[]'::jsonb)
               from (select coalesce(uf, '--') as uf, count(*) as n from in_p group by 1) t),
    'por_faixa', (select coalesce(jsonb_agg(jsonb_build_object('faixa', faixa, 'contratos', n, 'valor', v) order by
                    case faixa when 'alto' then 1 when 'medio' then 2 when 'baixo' then 3 else 4 end), '[]'::jsonb)
                  from (select coalesce(faixa, 'indefinida') as faixa, count(*) as n, coalesce(sum(valor_causa), 0) as v
                        from in_p group by 1) t),
    'total', jsonb_build_object('contratos', (select count(*) from in_p), 'valor', (select coalesce(sum(valor_causa), 0) from in_p))
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_geral(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_geral_p(p_office, date_trunc('month', p_month)::date,
                                  (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member);
$$;

-- -----------------------------------------------------------------------------
-- Funil (período)
-- -----------------------------------------------------------------------------

create or replace function public.funil_stage_leads_p(p_office uuid, p_from date, p_to date, p_member uuid, p_etapa text)
returns setof uuid
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  coorte as (
    select l.id from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  )
  select c.id from coorte c
  where case p_etapa
    when 'novos_leads' then true
    when 'abertura' then (select count(*) from public.messages m join public.conversations cv on cv.id = m.conversation_id
                          where cv.lead_id = c.id and m.direction = 'in') >= 2
    when 'links_enviados' then exists (select 1 from public.contracts k where k.lead_id = c.id and k.sent_at is not null)
    when 'contratos' then exists (select 1 from public.contracts k where k.lead_id = c.id and k.status = 'assinado')
    else false end;
$$;

create or replace function public.funil_stage_leads(p_office uuid, p_month date, p_member uuid, p_etapa text)
returns setof uuid language sql stable set search_path = public as $$
  select public.funil_stage_leads_p(p_office, date_trunc('month', p_month)::date,
                                    (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member, p_etapa);
$$;

create or replace function public.dashboard_funil_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
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
               or exists (select 1 from public.case_events e where e.lead_id = c.id and e.type = 'phase_changed'
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
           (select count(*) from public.funil_stage_leads_p(p_office, p_from, p_to, p_member, d.etapa)) as n,
           (select count(*) from public.funil_stage_leads_p(p_office, p_from, p_to, p_member, d.etapa) s
             where exists (select 1 from public.human_interventions h where h.lead_id = s)
                or exists (select 1 from public.case_events e where e.lead_id = s and e.type = 'takeover')) as interv_humana
    from macro_def d
  ),
  macro as (
    select m.*, lag(m.n) over (order by m.ordem) as n_anterior, first_value(m.n) over (order by m.ordem) as topo
    from macro_n m
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'leads', (select count(*) from coorte),
    'macro', (select coalesce(jsonb_agg(jsonb_build_object(
                'ordem', ordem, 'etapa', etapa, 'titulo', titulo, 'regua', regua, 'n', n,
                'pct_topo', case when topo = 0 then 0 else round(n::numeric / topo * 100) end,
                'conv_etapa', case when n_anterior is null then null when n_anterior = 0 then 0 else round(n::numeric / n_anterior * 100) end,
                'interv_humana', interv_humana) order by ordem), '[]'::jsonb) from macro),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object('fase', a.phase, 'alcancaram', a.n,
                 'taxa', case when (select count(*) from coorte) = 0 then 0 else round(a.n::numeric / (select count(*) from coorte) * 100, 1) end
               ) order by public.phase_order(a.phase)), '[]'::jsonb) from alcancou a where a.phase <> 'encerrado'),
    'atual', (select coalesce(jsonb_agg(jsonb_build_object('fase', phase, 'leads', n) order by public.phase_order(phase)), '[]'::jsonb)
              from (select phase, count(*) as n from coorte group by phase) t),
    'encerrados', jsonb_build_object(
      'ia',     (select count(*) from coorte where phase = 'encerrado' and closed_by = 'ia'),
      'equipe', (select count(*) from coorte where phase = 'encerrado' and closed_by = 'equipe')),
    'qualificacao', jsonb_build_object(
      'aprovados',  (select count(*) from coorte c join public.lead_qualification q on q.lead_id = c.id where q.passed),
      'reprovados', (select count(*) from coorte c join public.lead_qualification q on q.lead_id = c.id where not q.passed)),
    'contratos', (select count(*) from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado')
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_funil(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_funil_p(p_office, date_trunc('month', p_month)::date,
                                  (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member);
$$;

create or replace function public.dashboard_funil_leads_p(p_office uuid, p_etapa text, p_from date default null, p_to date default null, p_member uuid default null, p_limit int default 200)
returns setof public.v_case_cards
language sql stable set search_path = public as $$
  select v.* from public.v_case_cards v
  where v.office_id = p_office
    and v.lead_id in (select public.funil_stage_leads_p(p_office, p_from, p_to, p_member, p_etapa))
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- Jornada do Cliente: sete etapas, uma por agente
-- -----------------------------------------------------------------------------

-- fases de cada etapa/agente, na ordem da jornada
create or replace function public.journey_stages()
returns table(ordem int, role text, titulo text, fases public.case_phase[])
language sql immutable as $$
  values
    (1, 'recepcao',     'Recepção',     array['novo','triagem']::public.case_phase[]),
    (2, 'qualificacao', 'Qualificação', array['qualificacao']::public.case_phase[]),
    (3, 'provas',       'Provas',       array['provas']::public.case_phase[]),
    (4, 'calculo',      'Cálculo',      array['calculo']::public.case_phase[]),
    (5, 'contrato',     'Contrato',     array['contrato']::public.case_phase[]),
    (6, 'briefing',     'Briefing',     array['briefing']::public.case_phase[]),
    (7, 'redacao',      'Redação',      array['peca']::public.case_phase[]);
$$;

-- fase mais avançada que o lead já ocupou (ignora 'encerrado'; todo lead começa em 'novo')
create or replace function public.lead_max_phase_order(p_lead uuid)
returns int
language sql stable set search_path = public as $$
  select greatest(
    coalesce((select case when l.phase = 'encerrado' then 0 else public.phase_order(l.phase) end from public.leads l where l.id = p_lead), 0),
    coalesce((select max(public.phase_order(v.x::public.case_phase))
              from public.case_events e
              cross join lateral (values (e.payload->>'from'), (e.payload->>'to')) as v(x)
              where e.lead_id = p_lead and e.type = 'phase_changed' and v.x is not null and v.x <> 'encerrado'), 0)
  );
$$;

-- leads da coorte que chegaram à etapa (já ocuparam a primeira fase dela ou alguma posterior)
create or replace function public.journey_stage_leads_p(p_office uuid, p_from date, p_to date, p_member uuid, p_role text)
returns setof uuid
language sql stable set search_path = public as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  st as (select * from public.journey_stages() where role = p_role),
  coorte as (
    select l.id from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  )
  select c.id from coorte c, st
  where public.lead_max_phase_order(c.id) >= public.phase_order(st.fases[1]);
$$;

create or replace function public.dashboard_jornada_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  coorte as (
    select l.id, l.phase, l.created_at from public.leads l, b
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
    select s.*,
      (select count(*) from public.journey_stage_leads_p(p_office, p_from, p_to, p_member, s.role)) as n,
      (select count(*) from coorte c where c.phase = any (s.fases)) as em_fluxo,
      (select count(*) from public.journey_stage_leads_p(p_office, p_from, p_to, p_member, s.role) x
        where public.lead_max_phase_order(x) > public.phase_order(s.fases[array_length(s.fases, 1)])) as concluido,
      (select count(distinct e.lead_id) from public.case_events e join coorte c on c.id = e.lead_id
        where e.type = 'intervention_requested' and e.actor_agent = s.role) as interv_humana,
      (select round((avg(extract(epoch from (t.created_at - t.inicio))) / 3600)::numeric, 1)
         from trocas t where t.fase = any (s.fases)) as tempo_medio_horas
    from public.journey_stages() s
  ),
  topo as (select coalesce(max(n) filter (where ordem = 1), 0) as n from st)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'leads', (select count(*) from coorte),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object(
                 'ordem', s.ordem, 'agente', s.role, 'titulo', s.titulo, 'fases', to_jsonb(s.fases),
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

create or replace function public.dashboard_jornada(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_jornada_p(p_office, date_trunc('month', p_month)::date,
                                    (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member);
$$;

create or replace function public.dashboard_jornada_leads_p(p_office uuid, p_agente text, p_from date default null, p_to date default null, p_member uuid default null, p_limit int default 200)
returns setof public.v_case_cards
language sql stable set search_path = public as $$
  select v.* from public.v_case_cards v
  where v.office_id = p_office
    and v.lead_id in (select public.journey_stage_leads_p(p_office, p_from, p_to, p_member, p_agente))
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- Produtividade Humana: a fila de intervenção
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_produtividade_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  concl as (
    select h.* from public.human_interventions h, b
    where h.office_id = p_office and h.status = 'resolvida'
      and h.resolved_at >= b.p_start and h.resolved_at < b.p_end
      and (p_member is null or h.claimed_by = p_member)
  ),
  nomes as (
    select om.user_id, coalesce(pr.full_name, 'Membro') as nome
    from public.office_members om left join public.profiles pr on pr.user_id = om.user_id
    where om.office_id = p_office
  ),
  ranking as (
    select c.claimed_by, coalesce(n.nome, 'Sem responsável') as nome, count(*) as concluidas,
           round((avg(extract(epoch from (c.resolved_at - c.created_at))) / 3600)::numeric, 1) as tempo_medio_horas
    from concl c left join nomes n on n.user_id = c.claimed_by
    group by c.claimed_by, n.nome
  ),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'concluidas', (select count(*) from concl),
    'em_andamento', (select count(*) from public.human_interventions h
                     where h.office_id = p_office and h.status = 'em_atendimento' and (p_member is null or h.claimed_by = p_member)),
    'pendentes', (select count(*) from public.human_interventions h where h.office_id = p_office and h.status = 'pendente'),
    'tempo_medio_horas', (select round((avg(extract(epoch from (resolved_at - created_at))) / 3600)::numeric, 1) from concl),
    'pessoas', (select count(distinct claimed_by) from concl where claimed_by is not null),
    'tipos', (select count(distinct category) from concl),
    'maior_produtor', (select jsonb_build_object('user_id', claimed_by, 'nome', nome, 'concluidas', concluidas)
                       from ranking order by concluidas desc limit 1),
    'por_forma', (select coalesce(jsonb_agg(jsonb_build_object('forma', forma, 'n', n,
                    'pct', case when (select count(*) from concl) = 0 then 0 else round(n::numeric / (select count(*) from concl) * 100) end) order by n desc), '[]'::jsonb)
                  from (select coalesce(outcome, 'nao_informada') as forma, count(*) as n from concl group by 1) t),
    'por_tipo', (select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'n', n,
                   'pct', case when (select count(*) from concl) = 0 then 0 else round(n::numeric / (select count(*) from concl) * 100) end) order by n desc), '[]'::jsonb)
                 from (select category as tipo, count(*) as n from concl group by 1) t),
    'ranking', (select coalesce(jsonb_agg(jsonb_build_object('user_id', claimed_by, 'nome', nome, 'concluidas', concluidas,
                  'tempo_medio_horas', tempo_medio_horas) order by concluidas desc), '[]'::jsonb) from ranking),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia,
                  'concluidas', (select count(*) from concl c where c.resolved_at::date = d.dia)) order by d.dia), '[]'::jsonb) from dias d),
    'membros', (select coalesce(jsonb_agg(jsonb_build_object(
                  'user_id', n.user_id, 'nome', n.nome,
                  'takeovers', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor_user_id = n.user_id and e.type = 'takeover' and e.created_at >= b.p_start and e.created_at < b.p_end),
                  'mensagens', (select count(*) from public.messages m, b where m.office_id = p_office and m.sent_by = n.user_id and m.created_at >= b.p_start and m.created_at < b.p_end),
                  'fases_movidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor_user_id = n.user_id and e.type = 'phase_changed' and e.created_at >= b.p_start and e.created_at < b.p_end),
                  'contratos_assinados', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor_user_id = n.user_id and e.type = 'contract_signed' and e.created_at >= b.p_start and e.created_at < b.p_end)
                ) order by n.nome), '[]'::jsonb) from nomes n),
    'ia', jsonb_build_object(
      'mensagens', (select count(*) from public.messages m, b where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end),
      'fases_movidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor = 'ia' and e.type = 'phase_changed' and e.created_at >= b.p_start and e.created_at < b.p_end),
      'intervencoes_pedidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor = 'ia' and e.type = 'intervention_requested' and e.created_at >= b.p_start and e.created_at < b.p_end))
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_produtividade(p_office uuid, p_month date default current_date)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_produtividade_p(p_office, date_trunc('month', p_month)::date,
                                          (date_trunc('month', p_month) + interval '1 month - 1 day')::date, null);
$$;

-- -----------------------------------------------------------------------------
-- Investimento Financeiro: Ads + tokens (BRL) x contratos e protocolos, dia a dia
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_investimento_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b),
  tok as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd,
           coalesce(sum((m.ai_meta->>'tokens_in')::numeric), 0) as tin, coalesce(sum((m.ai_meta->>'tokens_out')::numeric), 0) as tout,
           count(*) as msgs
    from public.messages m, b
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end
    group by 1
  ),
  ads as (
    select a.dia, sum(a.valor) as brl from public.ad_spend a, b
    where a.office_id = p_office and a.dia >= b.p_start::date and a.dia < b.p_end::date group by 1
  ),
  ctr as (
    select k.signed_at::date as dia, count(*) as n from public.contracts k, b
    where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end group by 1
  ),
  prot as (
    select p.protocolado_em::date as dia, count(*) as n from public.pieces p, b
    where p.office_id = p_office and p.status = 'protocolada' and p.protocolado_em >= b.p_start and p.protocolado_em < b.p_end group by 1
  ),
  linha as (
    select d.dia,
           coalesce(a.brl, 0) as ads_brl,
           round(coalesce(t.usd, 0) * cambio.v, 2) as tokens_brl,
           coalesce(a.brl, 0) + round(coalesce(t.usd, 0) * cambio.v, 2) as investimento_brl,
           coalesce(c.n, 0) as contratos,
           coalesce(p.n, 0) as protocolos
    from dias d
    cross join cambio
    left join ads a on a.dia = d.dia
    left join tok t on t.dia = d.dia
    left join ctr c on c.dia = d.dia
    left join prot p on p.dia = d.dia
  ),
  tot as (
    select sum(ads_brl) as ads, sum(tokens_brl) as tokens, sum(investimento_brl) as inv, sum(contratos) as contratos, sum(protocolos) as protocolos
    from linha
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'cambio_usd_brl', (select v from cambio),
    'investimento_total_brl', (select round(inv, 2) from tot),
    'ads_brl', (select round(ads, 2) from tot),
    'tokens_brl', (select round(tokens, 2) from tot),
    'tokens_usd', (select round(coalesce(sum(usd), 0), 4) from tok),
    'tokens_in', (select coalesce(sum(tin), 0) from tok),
    'tokens_out', (select coalesce(sum(tout), 0) from tok),
    'mensagens_ia', (select coalesce(sum(msgs), 0) from tok),
    'contratos_fechados', (select contratos from tot),
    'custo_por_contrato_brl', (select case when contratos = 0 then null else round(inv / contratos, 2) end from tot),
    'protocolos', (select protocolos from tot),
    'custo_por_protocolo_brl', (select case when protocolos = 0 then null else round(inv / protocolos, 2) end from tot),
    'valor_causa_gerado', (select coalesce(sum(valor_causa), 0) from public.contracts k, b
                           where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end),
    'por_agente', (select coalesce(jsonb_agg(jsonb_build_object('agente', agente, 'mensagens', n, 'custo_usd', round(usd, 4), 'custo_brl', round(usd * (select v from cambio), 2)) order by usd desc), '[]'::jsonb)
                   from (select coalesce(m.ai_meta->>'agent_role', 'desconhecido') as agente, count(*) as n, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
                         from public.messages m, b where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end group by 1) t),
    'dia_a_dia', (select coalesce(jsonb_agg(jsonb_build_object(
                    'dia', dia, 'ads_brl', ads_brl, 'tokens_brl', tokens_brl, 'investimento_brl', investimento_brl,
                    'contratos', contratos, 'custo_por_contrato_brl', case when contratos = 0 then null else round(investimento_brl / contratos, 2) end,
                    'protocolos', protocolos, 'custo_por_protocolo_brl', case when protocolos = 0 then null else round(investimento_brl / protocolos, 2) end
                  ) order by dia desc), '[]'::jsonb) from linha)
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_investimento(p_office uuid, p_month date default current_date)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_investimento_p(p_office, date_trunc('month', p_month)::date,
                                         (date_trunc('month', p_month) + interval '1 month - 1 day')::date);
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant execute on function public.period_bounds(uuid, date, date) to authenticated;
grant execute on function public.dashboard_geral_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.funil_stage_leads_p(uuid, date, date, uuid, text) to authenticated;
grant execute on function public.dashboard_funil_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.dashboard_funil_leads_p(uuid, text, date, date, uuid, int) to authenticated;
grant execute on function public.journey_stages() to authenticated;
grant execute on function public.lead_max_phase_order(uuid) to authenticated;
grant execute on function public.journey_stage_leads_p(uuid, date, date, uuid, text) to authenticated;
grant execute on function public.dashboard_jornada_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.dashboard_jornada_leads_p(uuid, text, date, date, uuid, int) to authenticated;
grant execute on function public.dashboard_produtividade_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.dashboard_investimento_p(uuid, date, date) to authenticated;
