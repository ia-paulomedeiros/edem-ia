-- =============================================================================
-- 004_dashboard.sql — Sprint 3 (antecipado): dashboard e paridade de navegação
--
-- O concorrente abre no Dashboard com filtro por mês e por agente, e cinco
-- abas: Geral, Funil de Venda, Jornada do Cliente, Produtividade Humana,
-- Investimento Financeiro. Tudo aqui é PROJEÇÃO do que já existe:
-- leads.phase, contracts, case_events, messages.ai_meta. Nada de estado novo.
--
--   * contacts.uf / cidade: "regiões que mais fecham"
--   * contracts.valor_causa / faixa: "contratos por tipo (ticket)" e "valor de causa por dia"
--   * trigger de contrato: assinar preenche valor/faixa, grava evento com autor
--     e avança a fase para 'briefing' como sistema
--   * dashboard_geral / funil / jornada / produtividade / investimento: uma RPC por aba
--
-- Idempotente. Depende de 001..003.
-- =============================================================================

alter table public.contacts add column if not exists uf text check (uf is null or uf ~ '^[A-Z]{2}$');
alter table public.contacts add column if not exists cidade text;

alter table public.contracts add column if not exists valor_causa numeric;
alter table public.contracts add column if not exists faixa text check (faixa is null or faixa in ('baixo','medio','alto'));
create index if not exists contracts_signed_idx on public.contracts(office_id, signed_at) where status = 'assinado';

-- -----------------------------------------------------------------------------
-- Contrato: efeitos ao mudar de status
-- -----------------------------------------------------------------------------

create or replace function public.contracts_effects()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_actor text := case when auth.uid() is not null then 'humano' else 'sistema' end;
  v_phase public.case_phase;
begin
  if tg_op = 'INSERT' then
    perform public.log_event(new.office_id, new.lead_id, 'contract_created', v_actor, auth.uid(), null,
      jsonb_build_object('contract_id', new.id, 'honorarios_percent', new.honorarios_percent));
    return new;
  end if;

  if new.status is distinct from old.status then
    if new.status = 'enviado' then
      new.sent_at := coalesce(new.sent_at, now());
      perform public.log_event(new.office_id, new.lead_id, 'contract_sent', v_actor, auth.uid(), null,
        jsonb_build_object('contract_id', new.id));
    elsif new.status = 'assinado' then
      new.signed_at := coalesce(new.signed_at, now());
      if new.valor_causa is null then
        select q.verbas_total into new.valor_causa from public.lead_qualification q where q.lead_id = new.lead_id;
      end if;
      new.faixa := coalesce(new.faixa, public.faixa_ticket(new.office_id, coalesce(new.valor_causa, 0)));
      perform public.log_event(new.office_id, new.lead_id, 'contract_signed', v_actor, auth.uid(), null,
        jsonb_build_object('contract_id', new.id, 'valor_causa', new.valor_causa, 'faixa', new.faixa));
      select phase into v_phase from public.leads where id = new.lead_id;
      if public.phase_order(v_phase) < public.phase_order('briefing') then
        perform public.advance_phase(new.lead_id, 'briefing', 'sistema', null, null, 'contrato assinado');
      end if;
    elsif new.status in ('recusado','cancelado') then
      perform public.log_event(new.office_id, new.lead_id, 'contract_' || new.status, v_actor, auth.uid(), null,
        jsonb_build_object('contract_id', new.id));
    end if;
  end if;
  return new;
end; $$;
drop trigger if exists contracts_effects on public.contracts;
create trigger contracts_effects before insert or update on public.contracts
  for each row execute function public.contracts_effects();

-- -----------------------------------------------------------------------------
-- Helpers de período
-- -----------------------------------------------------------------------------

-- p_month: qualquer dia do mês desejado. Retorna [inicio, fim) do mês.
create or replace function public.month_bounds(p_month date, out p_start timestamptz, out p_end timestamptz)
language sql immutable as $$
  select date_trunc('month', coalesce(p_month, current_date))::timestamptz,
         (date_trunc('month', coalesce(p_month, current_date)) + interval '1 month')::timestamptz;
$$;

-- -----------------------------------------------------------------------------
-- Aba Geral
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_geral(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.month_bounds(p_month)),
  signed as (
    select k.*, l.assigned_to, ct.uf
    from public.contracts k
    join public.leads l on l.id = k.lead_id
    join public.contacts ct on ct.id = l.contact_id
    where k.office_id = p_office and k.status = 'assinado'
      and (p_member is null or l.assigned_to = p_member)
  ),
  in_month as (select s.* from signed s, b where s.signed_at >= b.p_start and s.signed_at < b.p_end),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b)
  select jsonb_build_object(
    'mes', to_char(date_trunc('month', p_month), 'YYYY-MM'),
    'fechados', jsonb_build_object(
      'hoje',   (select count(*) from signed where signed_at::date = current_date),
      'semana', (select count(*) from signed where signed_at >= date_trunc('week', now())),
      'mes',    (select count(*) from in_month)
    ),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object(
                  'dia', d.dia,
                  'contratos', (select count(*) from in_month m where m.signed_at::date = d.dia),
                  'valor_causa', (select coalesce(sum(valor_causa), 0) from in_month m where m.signed_at::date = d.dia)
                ) order by d.dia), '[]'::jsonb) from dias d),
    'por_uf', (select coalesce(jsonb_agg(jsonb_build_object('uf', uf, 'contratos', n) order by n desc), '[]'::jsonb)
               from (select coalesce(uf, '--') as uf, count(*) as n from in_month group by 1) t),
    'por_faixa', (select coalesce(jsonb_agg(jsonb_build_object('faixa', faixa, 'contratos', n, 'valor', v) order by
                    case faixa when 'alto' then 1 when 'medio' then 2 when 'baixo' then 3 else 4 end), '[]'::jsonb)
                  from (select coalesce(faixa, 'indefinida') as faixa, count(*) as n, coalesce(sum(valor_causa), 0) as v
                        from in_month group by 1) t),
    'total', jsonb_build_object(
      'contratos', (select count(*) from in_month),
      'valor', (select coalesce(sum(valor_causa), 0) from in_month)
    )
  )
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- Aba Funil de Venda: leads criados no mês, onde estão e quanto converteu
-- -----------------------------------------------------------------------------

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
  fases as (
    select unnest(enum_range(null::public.case_phase)) as phase
  ),
  alcancou as (
    -- quantos da coorte chegaram a cada fase (pela linha do tempo ou pela fase atual)
    select f.phase,
           (select count(distinct c.id) from coorte c
            where public.phase_order(c.phase) >= public.phase_order(f.phase)
               or exists (select 1 from public.case_events e
                          where e.lead_id = c.id and e.type = 'phase_changed'
                            and (e.payload->>'to')::public.case_phase = f.phase)) as n
    from fases f
  )
  select jsonb_build_object(
    'mes', to_char(date_trunc('month', p_month), 'YYYY-MM'),
    'leads', (select count(*) from coorte),
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

-- -----------------------------------------------------------------------------
-- Aba Jornada do Cliente: tempo médio por fase e tempo de primeira resposta
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_jornada(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.month_bounds(p_month)),
  coorte as (
    select l.id, l.created_at from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  ),
  trocas as (
    select e.lead_id, (e.payload->>'from')::public.case_phase as fase, e.created_at,
           lag(e.created_at) over (partition by e.lead_id order by e.seq) as anterior
    from public.case_events e
    join coorte c on c.id = e.lead_id
    where e.type = 'phase_changed'
  ),
  duracoes as (
    select fase, extract(epoch from (created_at - coalesce(anterior, (select created_at from coorte where id = t.lead_id)))) / 3600 as horas
    from trocas t
  ),
  primeira as (
    select c.id,
      (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id
        where cv.lead_id = c.id and m.direction = 'in') as primeira_in,
      (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id
        where cv.lead_id = c.id and m.direction = 'out') as primeira_out
    from coorte c
  )
  select jsonb_build_object(
    'mes', to_char(date_trunc('month', p_month), 'YYYY-MM'),
    'horas_por_fase', (select coalesce(jsonb_agg(jsonb_build_object('fase', fase, 'media_horas', media, 'n', n)
                                          order by public.phase_order(fase)), '[]'::jsonb)
                       from (select fase, round(avg(horas)::numeric, 1) as media, count(*) as n from duracoes group by fase) t),
    'primeira_resposta_min', (select round(avg(extract(epoch from (primeira_out - primeira_in)) / 60)::numeric, 1)
                              from primeira where primeira_out is not null and primeira_in is not null),
    'dias_ate_contrato', (select round(avg(extract(epoch from (k.signed_at - c.created_at)) / 86400)::numeric, 1)
                          from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado'),
    'mensagens_por_lead', (select round(avg(n)::numeric, 1) from (
                             select count(m.id) as n from coorte c
                             left join public.conversations cv on cv.lead_id = c.id
                             left join public.messages m on m.conversation_id = cv.id
                             group by c.id) t)
  )
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- Aba Produtividade Humana: o que cada membro fez no mês
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_produtividade(p_office uuid, p_month date default current_date)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.month_bounds(p_month)),
  ev as (
    select e.* from public.case_events e, b
    where e.office_id = p_office and e.actor = 'humano' and e.created_at >= b.p_start and e.created_at < b.p_end
  ),
  msgs as (
    select m.sent_by, count(*) as n from public.messages m, b
    where m.office_id = p_office and m.sender = 'humano' and m.created_at >= b.p_start and m.created_at < b.p_end
    group by m.sent_by
  )
  select jsonb_build_object(
    'mes', to_char(date_trunc('month', p_month), 'YYYY-MM'),
    'membros', (select coalesce(jsonb_agg(jsonb_build_object(
                  'user_id', om.user_id,
                  'nome', coalesce(pr.full_name, 'Membro'),
                  'role', om.role,
                  'takeovers', (select count(*) from ev where ev.actor_user_id = om.user_id and ev.type = 'takeover'),
                  'mensagens', coalesce((select n from msgs where msgs.sent_by = om.user_id), 0),
                  'fases_movidas', (select count(*) from ev where ev.actor_user_id = om.user_id and ev.type = 'phase_changed'),
                  'intervencoes_resolvidas', (select count(*) from ev where ev.actor_user_id = om.user_id and ev.type = 'intervention_resolved'),
                  'contratos_assinados', (select count(*) from ev where ev.actor_user_id = om.user_id and ev.type = 'contract_signed'),
                  'provas_validadas', (select count(*) from ev where ev.actor_user_id = om.user_id and ev.type = 'evidence_status_changed' and ev.payload->>'to' = 'validada')
                ) order by pr.full_name), '[]'::jsonb)
                from public.office_members om
                left join public.profiles pr on pr.user_id = om.user_id
                where om.office_id = p_office),
    'ia', jsonb_build_object(
      'mensagens', (select count(*) from public.messages m, b where m.office_id = p_office and m.sender = 'ia'
                    and m.created_at >= b.p_start and m.created_at < b.p_end),
      'fases_movidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor = 'ia'
                        and e.type = 'phase_changed' and e.created_at >= b.p_start and e.created_at < b.p_end),
      'intervencoes_pedidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor = 'ia'
                               and e.type = 'intervention_requested' and e.created_at >= b.p_start and e.created_at < b.p_end)
    )
  )
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- Aba Investimento Financeiro: custo de IA (ai_meta) contra resultado
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_investimento(p_office uuid, p_month date default current_date)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.month_bounds(p_month)),
  m as (
    select m.*, cv.lead_id from public.messages m
    join public.conversations cv on cv.id = m.conversation_id, b
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end
  ),
  custo as (
    select coalesce(sum((ai_meta->>'cost_usd')::numeric), 0) as usd,
           coalesce(sum((ai_meta->>'tokens_in')::numeric), 0) as tin,
           coalesce(sum((ai_meta->>'tokens_out')::numeric), 0) as tout,
           count(*) as msgs, count(distinct lead_id) as leads
    from m
  ),
  contratos as (
    select count(*) as n, coalesce(sum(valor_causa), 0) as valor from public.contracts k, b
    where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end
  )
  select jsonb_build_object(
    'mes', to_char(date_trunc('month', p_month), 'YYYY-MM'),
    'custo_usd', (select round(usd, 4) from custo),
    'tokens_in', (select tin from custo),
    'tokens_out', (select tout from custo),
    'mensagens_ia', (select msgs from custo),
    'leads_atendidos', (select leads from custo),
    'custo_por_lead_usd', (select case when leads = 0 then 0 else round(usd / leads, 4) end from custo),
    'contratos_assinados', (select n from contratos),
    'custo_por_contrato_usd', (select case when (select n from contratos) = 0 then 0 else round(usd / (select n from contratos), 4) end from custo),
    'valor_causa_gerado', (select valor from contratos),
    'por_agente', (select coalesce(jsonb_agg(jsonb_build_object('agente', agente, 'mensagens', n, 'custo_usd', round(usd, 4)) order by usd desc), '[]'::jsonb)
                   from (select coalesce(ai_meta->>'agent_role', 'desconhecido') as agente, count(*) as n,
                                coalesce(sum((ai_meta->>'cost_usd')::numeric), 0) as usd
                         from m group by 1) t),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', dia, 'custo_usd', round(usd, 4)) order by dia), '[]'::jsonb)
                from (select created_at::date as dia, coalesce(sum((ai_meta->>'cost_usd')::numeric), 0) as usd from m group by 1) t)
  )
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant execute on function public.dashboard_geral(uuid, date, uuid) to authenticated;
grant execute on function public.dashboard_funil(uuid, date, uuid) to authenticated;
grant execute on function public.dashboard_jornada(uuid, date, uuid) to authenticated;
grant execute on function public.dashboard_produtividade(uuid, date) to authenticated;
grant execute on function public.dashboard_investimento(uuid, date) to authenticated;
