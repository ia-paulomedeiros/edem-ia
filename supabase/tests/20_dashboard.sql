-- Testa 004 + seed_demo: gera o demo num escritório e confere as cinco RPCs do dashboard como membro.
\set ON_ERROR_STOP on
set client_min_messages = warning;
begin;

insert into auth.users (id, email, raw_user_meta_data) values ('33333333-3333-3333-3333-333333333333', 'demo@x.test', '{"full_name":"Demo"}');
insert into public.offices (id, name, slug) values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'Escritório Demo', 'demo');
insert into public.office_members (office_id, user_id, role) values ('cccccccc-cccc-cccc-cccc-cccccccccccc', '33333333-3333-3333-3333-333333333333', 'admin');
insert into public.whatsapp_numbers (office_id, phone_number_id, display_phone, token_secret_name) values ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'PNID-DEMO', '5511900000000', 'wa_demo');

\i supabase/seed_demo.sql

do $$
declare n int;
begin
  select count(*) into n from public.leads l join public.contacts c on c.id = l.contact_id where c.wa_id like '5500%';
  assert n = 60, 'seed criou 60 leads, criou ' || n;
  assert (select count(*) from public.contracts where status = 'assinado' and faixa is not null and valor_causa is not null) > 0, 'contratos assinados com faixa e valor';
  assert (select count(*) from public.case_events where type = 'contract_signed' and actor = 'sistema') > 0, 'evento contract_signed';
  assert (select count(*) from public.leads l join public.contracts k on k.lead_id = l.id and k.status = 'assinado' where public.phase_order(l.phase) < public.phase_order('briefing')) = 0, 'assinado => pelo menos briefing';
end $$;

set role authenticated;
set request.jwt.claim.sub = '33333333-3333-3333-3333-333333333333';
do $$
declare g jsonb; f jsonb; j jsonb; p jsonb; inv jsonb;
begin
  g := public.dashboard_geral('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert (g->'fechados'->>'mes')::int > 0, 'geral: fechados no mês';
  assert jsonb_array_length(g->'por_dia') between 28 and 31, 'geral: um item por dia do mês';
  assert jsonb_array_length(g->'por_uf') > 0, 'geral: por uf';
  assert (g->'total'->>'valor')::numeric > 0, 'geral: valor total';
  assert (g->'total'->>'contratos')::int = (g->'fechados'->>'mes')::int, 'geral: total = fechados no mês';

  f := public.dashboard_funil('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert (f->>'leads')::int = 60, 'funil: 60 leads na coorte';
  assert jsonb_array_length(f->'macro') = 4, 'funil: 4 macro-etapas';
  assert (f->'macro'->0->>'n')::int = 60 and (f->'macro'->0->>'pct_topo')::int = 100, 'funil: topo = 60, 100%';
  assert (f->'macro'->1->>'n')::int between 20 and 59, 'funil: abertura (2+ msgs) entre 20 e 59, veio ' || (f->'macro'->1->>'n');
  assert (f->'macro'->1->>'conv_etapa')::int between 30 and 99, 'funil: conversão da abertura';
  assert (f->'macro'->3->>'n')::int = (f->>'contratos')::int, 'funil: contratos = assinados';
  assert (f->'macro'->2->>'n')::int >= (f->'macro'->3->>'n')::int, 'funil: links >= contratos';
  assert (f->'macro'->3->>'conv_etapa') is not null, 'funil: conversão da etapa';
  assert (select count(*) from public.dashboard_funil_leads('cccccccc-cccc-cccc-cccc-cccccccccccc', 'contratos')) = (f->>'contratos')::int, 'funil_leads: lista os assinados';
  assert (select count(*) from public.dashboard_funil_leads('cccccccc-cccc-cccc-cccc-cccccccccccc', 'novos_leads')) = 60, 'funil_leads: lista todos';
  assert jsonb_array_length(f->'etapas') = 8, 'funil: 8 etapas (sem encerrado)';
  assert (f->'etapas'->0->>'taxa')::numeric = 100, 'funil: 100% alcançam novo';

  j := public.dashboard_jornada('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert (j->>'primeira_resposta_min')::numeric between 0.5 and 2, 'jornada: primeira resposta ~1 min';
  assert jsonb_array_length(j->'horas_por_fase') > 0, 'jornada: horas por fase';

  p := public.dashboard_produtividade('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert jsonb_array_length(p->'membros') = 1, 'produtividade: 1 membro';
  assert (p->'ia'->>'mensagens')::int = 120, 'produtividade: 120 mensagens da IA';

  inv := public.dashboard_investimento('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert (inv->>'custo_usd')::numeric > 0, 'investimento: custo > 0';
  assert (inv->>'leads_atendidos')::int = 60, 'investimento: 60 leads';
  assert jsonb_array_length(inv->'por_agente') = 2, 'investimento: 2 agentes';

  -- outro escritório não enxerga nada
  assert public.dashboard_geral('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') is null, 'dashboard de outro escritório é null';
end $$;
reset role; reset request.jwt.claim.sub;

rollback;
\echo DASHBOARD OK
