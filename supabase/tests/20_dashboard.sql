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
  assert jsonb_array_length(j->'etapas') = 7, 'jornada: sete etapas por agente';

  p := public.dashboard_produtividade('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert jsonb_array_length(p->'membros') = 1, 'produtividade: 1 membro';
  assert (p->'ia'->>'mensagens')::int = 120, 'produtividade: 120 mensagens da IA';

  inv := public.dashboard_investimento('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert (inv->>'tokens_usd')::numeric > 0, 'investimento: custo em tokens > 0';
  assert (inv->>'mensagens_ia')::int = 120, 'investimento: 120 mensagens da IA';
  assert jsonb_array_length(inv->'por_agente') = 2, 'investimento: 2 agentes';

  -- 006: período livre, jornada por agente, produtividade da fila, investimento em BRL
  g := public.dashboard_geral_p('cccccccc-cccc-cccc-cccc-cccccccccccc', null, null);
  assert (g->'fechados'->>'periodo')::int = (g->'fechados'->>'mes')::int, 'geral_p: todo o período = mês (demo só tem este mês)';
  g := public.dashboard_geral_p('cccccccc-cccc-cccc-cccc-cccccccccccc', current_date, current_date);
  assert jsonb_array_length(g->'por_dia') = 1, 'geral_p: hoje = 1 dia';
  assert (g->'fechados'->>'periodo')::int = (g->'fechados'->>'hoje')::int, 'geral_p: hoje bate';

  j := public.dashboard_jornada_p('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert jsonb_array_length(j->'etapas') = 7, 'jornada: 7 etapas';
  assert (j->'etapas'->0->>'n')::int = 60 and (j->'etapas'->0->>'pct_topo')::int = 100, 'jornada: recepção = todos';
  assert (j->'etapas'->0->>'concluido')::int + (j->'etapas'->0->>'em_fluxo')::int <= 60, 'jornada: concluído + em fluxo <= n';
  assert (j->'etapas'->0->>'concluido')::int > 0, 'jornada: recepção tem concluídos';
  assert (j->'etapas'->3->>'n')::int >= (f->>'contratos')::int, 'jornada: entrevista (4ª etapa na ordem 013) >= contratos';
  assert (select count(*) from public.dashboard_jornada_leads_p('cccccccc-cccc-cccc-cccc-cccccccccccc', 'recepcao')) = 60, 'jornada_leads: recepção lista todos';

  p := public.dashboard_produtividade_p('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert (p->>'concluidas')::int > 0, 'produtividade: concluídas > 0';
  assert (p->>'tempo_medio_horas')::numeric > 0, 'produtividade: tempo médio';
  assert jsonb_array_length(p->'por_forma') > 1, 'produtividade: por forma';
  assert jsonb_array_length(p->'por_tipo') > 1, 'produtividade: por tipo';
  assert (p->'maior_produtor'->>'nome') = 'Demo', 'produtividade: maior produtor';
  assert (select sum((x->>'concluidas')::int) from jsonb_array_elements(p->'por_dia') x) = (p->>'concluidas')::int, 'produtividade: por dia soma';

  inv := public.dashboard_investimento_p('cccccccc-cccc-cccc-cccc-cccccccccccc');
  assert (inv->>'ads_brl')::numeric > 0 and (inv->>'tokens_brl')::numeric > 0, 'investimento: ads e tokens';
  assert (inv->>'investimento_total_brl')::numeric = (inv->>'ads_brl')::numeric + (inv->>'tokens_brl')::numeric, 'investimento: total = ads + tokens';
  assert (inv->>'protocolos')::int > 0, 'investimento: protocolos';
  assert (inv->>'custo_por_contrato_brl')::numeric > 0, 'investimento: custo por contrato';
  assert jsonb_array_length(inv->'dia_a_dia') between 1 and 31, 'investimento: dia a dia (todo o período = do primeiro lead até hoje)';

  -- 007: cards da fila
  assert (select count(*) from public.v_intervention_cards where status = 'pendente') > 0, 'fila: cards pendentes';
  assert (select count(distinct grupo) from public.v_intervention_cards) >= 3, 'fila: vários grupos';
  assert (select count(*) from public.v_intervention_cards where priority = 4) >= 0, 'fila: P4 aceito';
  assert (select bool_and(msgs_count >= 0 and dias >= 0) from public.v_intervention_cards), 'fila: contadores';
  assert (select count(*) from public.v_intervention_cards where note is not null) > 0, 'fila: observações';

  -- outro escritório não enxerga nada
  assert public.dashboard_geral('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') is null, 'dashboard de outro escritório é null';
end $$;

-- 009: marketing (lançamentos, tokens lançado > estimado, custo por lead, importação só service_role)
do $$
declare r jsonb; c uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc'; v_lead uuid; inv jsonb; d jsonb; tok_est numeric;
begin
  inv := public.dashboard_investimento_p(c, current_date, current_date);
  tok_est := (inv->>'tokens_brl')::numeric;
  r := public.marketing_lancar(c, current_date, 100, 20, 'teste');
  assert (r->>'ads_brl')::numeric = 100 and (r->>'tokens_brl')::numeric = 20 and (r->>'total_brl')::numeric = 120, 'lançamento do dia';
  assert (r->>'tem_manual')::boolean and not (r->>'tem_importado')::boolean, 'origem manual';
  assert (select count(*) from public.marketing_lancamentos_p(c)) >= 1, 'lista de lançamentos';
  r := public.marketing_resumo_p(c, current_date, current_date);
  assert (r->>'ads_brl')::numeric = 100 and (r->>'tokens_brl')::numeric = 20, 'resumo do dia usa o lançado, não a estimativa';
  inv := public.dashboard_investimento_p(c, current_date, current_date);
  assert (inv->>'tokens_brl')::numeric = 20, 'dashboard usa o lançado (' || tok_est || ' estimado) => ' || (inv->>'tokens_brl');
  assert (inv->>'ads_brl')::numeric = 100, 'dashboard ads do dia';
  -- sem lançamento de tokens, vale a estimativa
  assert (select sum(tokens_brl) from public.marketing_tokens_por_dia(c, current_date - 40, current_date - 1)) >= 0, 'tokens por dia';
  assert (select count(*) from public.marketing_tokens_por_dia(c, current_date - 2, current_date)) = 3, '3 dias';
  -- custo por lead
  select id into v_lead from public.leads where office_id = c order by created_at limit 1;
  d := public.lead_cost(v_lead);
  assert (d->>'tokens_brl')::numeric > 0, 'custo tokens do lead';
  assert (d->>'custo_lead_brl')::numeric >= (d->>'tokens_brl')::numeric, 'custo do lead inclui rateio';
  assert (d->'mes'->>'custo_medio_lead_brl')::numeric > 0, 'média do mês';
  assert public.lead_dossier(v_lead)->'cost' ? 'custo_lead_brl', 'dossiê traz o custo';
  -- remover só apaga o manual
  assert public.marketing_remover(c, current_date) = 2, 'removeu ads e tokens manuais';
  assert not has_function_privilege('authenticated', 'public.marketing_import(uuid,date,text,numeric,numeric,text)', 'execute'), 'import bloqueado';
  assert not has_function_privilege('authenticated', 'public.marketing_import_targets()', 'execute'), 'targets bloqueado';
  assert (select count(*) from public.integration_catalog where provider = 'meta_ads' and kind = 'ads') = 1, 'meta_ads no catálogo';
end $$;
reset role; reset request.jwt.claim.sub;
do $$
declare c uuid := 'cccccccc-cccc-cccc-cccc-cccccccccccc'; r record;
begin
  perform public.marketing_import(c, current_date - 1, 'tokens_anthropic', 55, 10, 'Anthropic cost_report');
  perform public.marketing_import(c, current_date - 1, 'meta_ads', 300, null, 'Meta Ads insights');
  select * into r from public.v_marketing_lancamentos where office_id = c and dia = current_date - 1;
  assert r.tem_importado and r.ads_brl = 300 and r.tokens_brl = 55, 'importado no dia';
  assert (select tokens_brl from public.marketing_tokens_por_dia(c, current_date - 1, current_date - 1)) = 55, 'dashboard usa o importado';
  assert (select count(*) from public.marketing_import_targets()) = 0, 'sem integração ativa com segredo => sem alvo';
end $$;

rollback;
\echo DASHBOARD OK
