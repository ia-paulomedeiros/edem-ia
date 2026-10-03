-- Paridade de regras com a Láquila (014) e automações (015).
-- Roda depois de 10_smoke e 20_dashboard (ver run.sh). Tudo dentro de uma transação desfeita no fim.

\set ON_ERROR_STOP on
set client_min_messages = warning;
begin;

-- ---------- fixtures: escritório D, admin Dora e atendente Edu
insert into auth.users (id, email, raw_user_meta_data) values
  ('44444444-4444-4444-4444-444444444444', 'dora@escritorio-d.test', '{"full_name":"Dora D"}'),
  ('55555555-5555-5555-5555-555555555555', 'edu@escritorio-d.test', '{"full_name":"Edu D"}');
insert into public.offices (id, name, slug) values ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'Escritório D', 'd');
insert into public.office_members (office_id, user_id, role) values
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', '44444444-4444-4444-4444-444444444444', 'admin'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', '55555555-5555-5555-5555-555555555555', 'atendente');
insert into public.whatsapp_numbers (office_id, phone_number_id, display_phone, token_secret_name) values
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'PNID-D', '5511955550000', 'wa_token_office_d');

-- Cria um lead pelo caminho real (ingest_inbound) e devolve o id.
create or replace function pg_temp.novo_lead(p_wa text, p_nome text) returns uuid language plpgsql as $$
declare r jsonb;
begin
  r := public.ingest_inbound('PNID-D', p_wa, p_nome, 'wamid.' || p_wa || '.' || extract(epoch from clock_timestamp())::text, 'Oi, preciso de ajuda');
  return (r->>'lead_id')::uuid;
end $$;

-- =============================================================================
-- 014 · 1. Faixas de ticket
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v_lead uuid; q public.lead_qualification; p public.office_params;
begin
  select * into p from public.office_params where office_id = d;
  assert p.ticket_minimo = 2000, 'ticket mínimo padrão = 2.000 (Láquila)';
  assert p.faixas_ticket = '[{"faixa":"baixo","ate":30000},{"faixa":"medio","ate":80000},{"faixa":"alto","ate":null}]'::jsonb, 'faixas padrão LOW/MID/HIGH';
  assert public.faixa_ticket(d, 12101) = 'baixo', '12.101 → LOW';
  assert public.faixa_ticket(d, 67904) = 'medio', '67.904 → MID';
  assert public.faixa_ticket(d, 85002) = 'alto', '85.002 → HIGH';
  assert public.faixa_ticket(d, 30000) = 'baixo' and public.faixa_ticket(d, 80000) = 'medio', 'limites inclusivos';
  assert public.brl(12101) = 'R$ 12.101,00', 'brl formata no padrão brasileiro: ' || public.brl(12101);

  -- caso pequeno: pediu demissão com 2 meses de casa e salário baixo → abaixo de 2.000
  v_lead := pg_temp.novo_lead('5511955551771', 'Lead Pequeno');
  insert into public.case_data (lead_id, office_id, empresa, admissao, demissao, salario, tipo_rescisao, aviso_previo, fgts_depositado)
  values (v_lead, d, 'Mercadinho', current_date - 70, current_date - 10, 900, 'pedido_demissao', 'trabalhado', true);
  q := public.qualification_gate(v_lead, 'sistema');
  assert q.verbas_total < 2000, 'caso pequeno fica abaixo de R$ 2.000: ' || q.verbas_total;
  assert not q.passed and exists (select 1 from unnest(q.motivos) m where m like 'ticket_baixo:%<2000'), 'abaixo do LOW reprova no portão: ' || array_to_string(q.motivos, ',');
  -- sem salário/admissão: motivo dados_insuficientes (na 002 isto quebrava com "malformed array literal")
  q := public.qualification_gate(pg_temp.novo_lead('5511955550000', 'Lead Sem Dados'), 'sistema');
  assert not q.passed and q.motivos = array['dados_insuficientes'], 'dados insuficientes';
end $$;

-- =============================================================================
-- 014 · 2. Tempo mínimo de vínculo por tipo de saída
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v_lead uuid; q public.lead_qualification;
begin
  update public.office_params set vinculo_minimo =
    '{"com_vinculo":{"demitido":3,"pediu_demissao":12,"ainda_trabalha":6},"sem_vinculo":{"demitido":24,"pediu_demissao":36,"ainda_trabalha":48}}'
   where office_id = d;
  assert public.tipo_saida('sem_justa_causa') = 'demitido' and public.tipo_saida('justa_causa') = 'demitido' and public.tipo_saida('acordo') = 'demitido', 'demitido';
  assert public.tipo_saida('pedido_demissao') = 'pediu_demissao', 'pediu demissão';
  assert public.tipo_saida('rescisao_indireta') = 'ainda_trabalha', 'rescisão indireta = ainda trabalha';
  assert public.vinculo_minimo_exigido(d, 'sem_justa_causa', true, false) = 3, 'com vínculo · demitido';
  assert public.vinculo_minimo_exigido(d, 'pedido_demissao', true, false) = 12, 'com vínculo · pediu demissão';
  assert public.vinculo_minimo_exigido(d, 'rescisao_indireta', true, false) = 6, 'com vínculo · ainda trabalha';
  assert public.vinculo_minimo_exigido(d, 'sem_justa_causa', false, false) = 24, 'sem vínculo · demitido';
  assert public.vinculo_minimo_exigido(d, 'pedido_demissao', false, false) = 36, 'sem vínculo · pediu demissão';
  assert public.vinculo_minimo_exigido(d, 'rescisao_indireta', false, false) = 48, 'sem vínculo · ainda trabalha';
  assert public.vinculo_minimo_exigido(d, 'sem_justa_causa', true, true) = 0, 'acidente: tempo ignorado (opção ligada por padrão)';
  update public.office_params set ignorar_tempo_acidente = false where office_id = d;
  assert public.vinculo_minimo_exigido(d, 'sem_justa_causa', true, true) = 3, 'acidente com a opção desligada: tempo conferido';
  update public.office_params set ignorar_tempo_acidente = true where office_id = d;

  -- portão: 10 meses sem carteira, demitido → exige 24 → reprova; com acidente → passa no tempo
  v_lead := pg_temp.novo_lead('5511955552424', 'Lead Sem Carteira');
  insert into public.case_data (lead_id, office_id, empresa, admissao, demissao, salario, tipo_rescisao, aviso_previo, ctps_assinada, fgts_depositado, horas_extras_semanais)
  values (v_lead, d, 'Obra Y', current_date - 330, current_date - 30, 4000, 'sem_justa_causa', 'indenizado', false, false, 10);
  q := public.qualification_gate(v_lead, 'sistema');
  assert exists (select 1 from unnest(q.motivos) m where m like 'vinculo_curto:%<24'), 'sem vínculo · demitido exige 24 meses: ' || array_to_string(q.motivos, ',');
  update public.case_data set acidente_trabalho = true where lead_id = v_lead;
  q := public.qualification_gate(v_lead, 'sistema');
  assert not exists (select 1 from unnest(q.motivos) m where m like 'vinculo_curto%'), 'acidente: tempo não é conferido';
  -- 0 = sem exigência
  update public.office_params set vinculo_minimo =
    '{"com_vinculo":{"demitido":0,"pediu_demissao":0,"ainda_trabalha":0},"sem_vinculo":{"demitido":0,"pediu_demissao":0,"ainda_trabalha":0}}'
   where office_id = d;
  update public.case_data set acidente_trabalho = false where lead_id = v_lead;
  q := public.qualification_gate(v_lead, 'sistema');
  assert not exists (select 1 from unnest(q.motivos) m where m like 'vinculo_curto%'), '0 = sem exigência';
end $$;

-- =============================================================================
-- 014 · 3. Empresa: métricas comerciais e taxa de manutenção
-- =============================================================================
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';   -- Edu, atendente
do $$ begin
  begin
    perform public.ui_save_empresa('dddddddd-dddd-dddd-dddd-dddddddddddd', '{"volume_processos": 1}', '{}');
    raise exception 'atendente salvou a Empresa';
  exception when others then assert sqlerrm like '%só o admin%', sqlerrm; end;
end $$;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';   -- Dora, admin
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; r jsonb; v_lead uuid; cfg jsonb;
begin
  r := public.ui_save_empresa(d,
    '{"volume_processos": 1200, "clientes_representados": 900, "avaliacoes_5_estrelas": 310, "plataforma_reviews": "Google",
      "exemplo_honorarios": "Se ganhar R$ 20 mil, o escritório fica com R$ 6 mil.", "cobra_taxa_manutencao": false}',
    '{"honorarios_percent": 30, "ticket_minimo": 2000, "faixa_baixo_ate": 30000, "faixa_medio_ate": 80000,
      "vinculo_minimo": {"com_vinculo":{"demitido":0,"pediu_demissao":0,"ainda_trabalha":0},"sem_vinculo":{"demitido":0,"pediu_demissao":0,"ainda_trabalha":0}},
      "ignorar_tempo_acidente": true}');
  assert (r->'office'->>'volume_processos')::int = 1200, 'métricas gravadas';
  assert r->'escritorio'->>'prova_social' like '%1200 processos%310 avaliações 5 estrelas no Google%', 'prova social montada: ' || (r->'escritorio'->>'prova_social');
  assert r->'escritorio'->>'proposta_honorarios' like '%Se não ganhar, não paga nada%R$ 20 mil%', 'sem taxa: risco zero + exemplo do escritório';
  assert coalesce(r->'escritorio'->>'taxa_manutencao_texto', '') = '', 'sem taxa: nenhum texto de taxa';

  -- prompt do Closer (qualificação) sem a taxa
  v_lead := pg_temp.novo_lead('5511955553030', 'Lead Proposta');
  perform public.advance_phase(v_lead, 'qualificacao', 'sistema');
  cfg := public.agent_config_full_lead(v_lead);
  assert cfg->>'role' = 'qualificacao', 'agente por lead: qualificação';
  assert cfg->>'system_prompt' like '%só cobra 30% do que você ganhar%Se não ganhar, não paga nada%', 'proposta com o percentual do escritório';
  assert cfg->>'system_prompt' not like '%taxa de manutenção%', 'taxa não aparece quando o escritório não cobra';
  assert cfg->>'system_prompt' not like '%{{%', 'nenhum placeholder sobrando';
  assert cfg->'escritorio'->>'volume_processos' = '1200', 'bloco escritorio em agent_config_full_lead';
  assert (public.lead_dossier(v_lead))->'escritorio'->>'clientes_representados' = '900', 'bloco escritorio no dossiê';

  -- liga a taxa
  r := public.ui_save_empresa(d, '{"cobra_taxa_manutencao": true, "taxa_manutencao_valor": 49.9, "taxa_manutencao_periodicidade": "mensal", "taxa_manutencao_obs": "Cobre custas de acompanhamento."}', '{}');
  cfg := public.agent_config_full_lead(v_lead);
  assert cfg->>'system_prompt' like '%taxa de manutenção de R$ 49,90 por mês. Cobre custas de acompanhamento.%', 'taxa aparece quando cobra: ' || (r->'escritorio'->>'taxa_manutencao_texto');
  assert cfg->>'system_prompt' not like '%Se não ganhar, não paga nada%', 'com taxa não promete custo zero';

  -- validações
  begin
    perform public.ui_save_empresa(d, '{}', '{"faixa_baixo_ate": 90000, "faixa_medio_ate": 80000}');
    raise exception 'aceitou faixas fora de ordem';
  exception when others then assert sqlerrm like 'faixas inválidas%', sqlerrm; end;
  begin
    perform public.ui_save_empresa(d, '{"taxa_manutencao_periodicidade": "semanal"}', '{}');
    raise exception 'aceitou periodicidade inválida';
  exception when others then assert sqlerrm like '%mensal, unica ou anual%', sqlerrm; end;
  begin
    perform public.ui_save_empresa(d, '{}', '{"vinculo_minimo": {"com_vinculo": {"demitido": 1}}}');
    raise exception 'aceitou vinculo_minimo incompleto';
  exception when others then assert sqlerrm like 'vinculo_minimo.%', sqlerrm; end;
  r := public.ui_save_empresa(d, '{"cobra_taxa_manutencao": false}', '{"ticket_minimo": 2000, "faixa_baixo_ate": 30000, "faixa_medio_ate": 80000}');
end $$;

-- =============================================================================
-- 014 · 4. Encerramento por motivo do catálogo
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v_a uuid; v_b uuid; v_c uuid; l public.leads; r jsonb;
begin
  assert (select count(*) from public.close_reasons()) = 8, '8 motivos';
  assert (select count(*) from public.close_reasons() where tipo = 'inviavel') = 5 and (select count(*) from public.close_reasons() where tipo = 'insanavel') = 3, '5 inviáveis + 3 insanáveis';

  v_a := pg_temp.novo_lead('5511955554001', 'Lead Prescrito');
  l := public.ui_close_lead(v_a, 'prescrito', null, 'Saiu em 2021');
  assert l.phase = 'encerrado' and l.closed_kind = 'inviavel' and l.closed_code = 'prescrito' and l.closed_reason = 'Prescrito'
     and l.closed_note = 'Saiu em 2021' and l.closed_by = 'equipe', 'Prescrito → Inviável, pela equipe';
  assert (select payload->>'tipo' from public.case_events where lead_id = v_a and type = 'lead_closed') = 'inviavel', 'evento lead_closed';

  v_b := pg_temp.novo_lead('5511955554002', 'Lead Desistiu');
  l := public.ui_close_lead(v_b, 'cliente_desistiu');
  assert l.closed_kind = 'insanavel' and l.closed_reason = 'Cliente desistiu / sem interesse', 'Cliente desistiu → Insanável';
  l := public.ui_reopen_lead(v_b);
  assert l.phase <> 'encerrado' and l.closed_code is null and l.closed_kind is null, 'reabrir limpa o motivo';

  -- a IA encerra com código (autor IA)
  v_c := pg_temp.novo_lead('5511955554003', 'Lead Servidor');
  r := public.apply_agent_effects(v_c, null, 'qualificacao', null, 'encerrado', 'servidor_publico');
  select * into l from public.leads where id = v_c;
  assert l.phase = 'encerrado' and l.closed_by = 'ia' and l.closed_kind = 'inviavel' and l.closed_code = 'servidor_publico', 'IA encerra com código';
  assert (select actor from public.case_events where lead_id = v_c and type = 'lead_closed') = 'ia'
     and (select actor_agent from public.case_events where lead_id = v_c and type = 'phase_changed' order by seq desc limit 1) = 'qualificacao', 'evento nomeia a IA e o agente';
end $$;

-- =============================================================================
-- 014 · 5. Etapa detalhada do lead
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v uuid; v_conv uuid; v_piece uuid; e jsonb;
begin
  v := pg_temp.novo_lead('5511955555001', 'Lead Jornada');
  select id into v_conv from public.conversations where lead_id = v;
  assert public.lead_etapa(v) = 'novo', 'novo';
  perform public.advance_phase(v, 'triagem', 'ia', null, 'recepcao');
  assert public.lead_etapa(v) = 'qualificando', 'qualificando';
  select payload into e from public.case_events where lead_id = v and type = 'phase_changed' order by seq desc limit 1;
  assert e->>'etapa_from' = 'novo' and e->>'etapa_to' = 'qualificando' and e->>'etapa_to_titulo' = 'Qualificando', 'phase_changed grava etapa_from/etapa_to';
  insert into public.lead_qualification (lead_id, office_id, passed, faixa, verbas_total) values (v, d, true, 'baixo', 12101);
  assert public.lead_etapa(v) = 'qualificado', 'qualificado';
  perform public.advance_phase(v, 'contrato', 'ia', null, 'qualificacao');
  assert public.lead_etapa(v) = 'qualificado', 'contrato sem envio ainda = qualificado';
  insert into public.contracts (office_id, lead_id, status, honorarios_percent) values (d, v, 'enviado', 30);
  assert public.lead_etapa(v) = 'contrato_enviado' and public.etapa_titulo('contrato_enviado') = 'Contrato Enviado', 'contrato_enviado';
  update public.contracts set status = 'assinado' where lead_id = v;
  assert (select phase from public.leads where id = v) = 'briefing', 'assinatura avança para a entrevista';
  assert public.lead_etapa(v) = 'contrato_assinado' and public.etapa_titulo('contrato_assinado') = 'Contrato Fechado', 'Contrato Fechado';
  insert into public.briefings (office_id, lead_id) values (d, v);
  assert public.lead_etapa(v) = 'em_entrevista' and public.etapa_titulo('em_entrevista') = 'Em Entrevista', 'Em Entrevista';
  perform public.advance_phase(v, 'calculo', 'ia', null, 'briefing');
  assert public.lead_etapa(v) = 'em_viabilidade', 'em_viabilidade';
  perform public.advance_phase(v, 'provas', 'ia', null, 'calculo');
  assert public.lead_etapa(v) = 'coletando_docs' and public.etapa_titulo('coletando_docs') = 'Coletando Docs', 'Coletando Docs';
  perform public.advance_phase(v, 'peca', 'ia', null, 'provas');
  assert public.lead_etapa(v) = 'peticionado', 'peça sem status / rascunho = Peticionado';
  insert into public.pieces (office_id, lead_id, tese, status) values (d, v, 'horas_extras', 'rascunho') returning id into v_piece;
  assert public.lead_etapa(v) = 'peticionado' and public.etapa_titulo('peticionado') = 'Peticionado', 'Peticionado';
  update public.pieces set status = 'revisao' where id = v_piece;     assert public.lead_etapa(v) = 'revisao', 'revisao';
  update public.pieces set status = 'aguardando' where id = v_piece;  assert public.lead_etapa(v) = 'aguardando', 'aguardando';
  update public.pieces set status = 'saneamento' where id = v_piece;  assert public.lead_etapa(v) = 'saneamento', 'saneamento';
  update public.pieces set status = 'aprovada' where id = v_piece;    assert public.lead_etapa(v) = 'pronto_protocolo', 'pronto_protocolo';
  update public.conversations set ai_paused = true where id = v_conv;
  assert public.lead_etapa(v) = 'humano_assumiu' and public.etapa_titulo('humano_assumiu') = 'Humano Assumiu', 'conversa assumida = Humano Assumiu';
  update public.pieces set status = 'protocolada' where id = v_piece;
  assert public.lead_etapa(v) = 'protocolado' and public.etapa_titulo('protocolado') = 'Protocolado', 'protocolada vence o takeover = Protocolado';
  update public.conversations set ai_paused = false where id = v_conv;
  perform public.advance_phase(v, 'encerrado', 'sistema', null, null, 'teste');
  assert public.lead_etapa(v) = 'encerrado', 'encerrado';
  assert (select count(*) from public.etapas()) = 16, '16 etapas no catálogo';
end $$;

-- =============================================================================
-- 014 · 6. Agentes: persona, Saneador, agente por lead
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v uuid; v_piece uuid; a public.agents; cfg jsonb; r jsonb;
begin
  assert (select count(*) from public.agents where office_id is null) = 8, '8 agentes globais';
  assert (select name from public.agents where office_id is null and role = 'recepcao') = 'Closer', 'Closer';
  assert (select name from public.agents where office_id is null and role = 'briefing') = 'Entrevistador', 'Entrevistador';
  assert (select name from public.agents where office_id is null and role = 'calculo') = 'Qualificador (Calculista)', 'Calculista';
  assert (select name from public.agents where office_id is null and role = 'provas') = 'Coletor', 'Coletor';
  assert (select name from public.agents where office_id is null and role = 'saneamento') = 'Saneador', 'Saneador';
  assert (select name from public.agents where office_id is null and role = 'redacao') = 'Redator', 'Redator';

  -- persona por escritório (override criado na hora; prompt continua o global)
  a := public.ui_set_agent_persona(d, 'qualificacao', 'Fernanda');
  assert a.office_id = d and a.persona_nome = 'Fernanda' and a.name = 'Closer', 'override com persona';
  assert public.agent_label(a.name, a.persona_nome) = 'Closer — Fernanda', 'rótulo {name} — {persona}';
  assert public.agent_label('Coletor', null) = 'Coletor', 'sem persona: só o nome';

  v := pg_temp.novo_lead('5511955556001', 'Lead Saneamento');
  perform public.advance_phase(v, 'qualificacao', 'sistema');
  assert public.agent_label_lead(v) = 'Closer — Fernanda', 'agente do lead com persona';
  cfg := public.agent_config_full_lead(v);
  assert cfg->>'system_prompt' like 'Você é Fernanda, assistente virtual do Escritório D%', 'persona entra como {{agent_name}}';
  assert cfg->>'label' = 'Closer — Fernanda', 'label no config';

  perform public.advance_phase(v, 'peca', 'sistema');
  assert public.agent_for_lead(v) = 'redacao', 'peça sem saneamento → Redator';
  insert into public.pieces (office_id, lead_id, tese, status, alerta) values (d, v, 'horas_extras', 'saneamento', 'Falta extrato do FGTS') returning id into v_piece;
  assert public.agent_for_lead(v) = 'saneamento', 'peça em saneamento → Saneador';
  cfg := public.agent_config_full_lead(v);
  assert cfg->>'role' = 'saneamento' and cfg->>'system_prompt' like '%SUA ETAPA: SANEAMENTO%' and cfg->>'system_prompt' like 'Você é Saneador%', 'prompt do Saneador';
  assert cfg->>'etapa' = 'saneamento', 'etapa no config do lead';
  perform set_config('request.jwt.claim.sub', '', false);   -- como o n8n: sem usuário
  r := public.apply_agent_effects(v, null, null, '{"extras":{"fgts":"enviado"}}', 'revisao', 'pendências respondidas');
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);
  assert r->>'agent_role' = 'saneamento', 'sem papel informado, usa o agente do lead';
  assert (select status from public.pieces where id = v_piece) = 'revisao', 'Saneador devolve a peça para revisão';
  assert (select actor from public.case_events where lead_id = v and type = 'piece_status_changed' order by seq desc limit 1) = 'ia', 'mudança da peça com autor IA';
  assert (select actor_agent from public.case_events where lead_id = v and type = 'saneamento_concluido') = 'saneamento', 'evento nomeia o Saneador';
  assert public.agent_for_lead(v) = 'redacao', 'de volta ao Redator';

  -- jornada: 5 etapas, Saneador/Redator pela etapa da peça
  assert (select array_agg(role order by ordem) from public.journey_stages()) = array['closer','entrevistador','coletor','saneador','redator'], 'jornada da Láquila';
  assert public.journey_stage_key('recepcao') = 'closer' and public.journey_stage_key('calculo') = 'entrevistador', 'papel → etapa';
  assert public.lead_reached_stage(v, 'saneador') and public.lead_done_stage(v, 'saneador'), 'passou e saiu do saneamento';
  assert public.lead_journey_stage(v) = 'redator', 'agora no Redator';
end $$;

-- =============================================================================
-- 014 · 7. Marketing: Claude e OpenAI separados
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; r jsonb; m public.v_marketing_dia; inv jsonb;
begin
  r := public.marketing_lancar(d, current_date, p_ads_brl => 100, p_claude_brl => 30, p_openai_brl => 10, p_nota => 'teste');
  assert (r->>'tokens_anthropic_brl')::numeric = 30 and (r->>'tokens_openai_brl')::numeric = 10 and (r->>'total_brl')::numeric = 140, 'lançamento separa Claude e OpenAI';
  select * into m from public.marketing_dia_p(d, current_date, current_date);
  assert m.ads_brl = 100 and m.tokens_brl = 40 and m.tokens_anthropic_brl = 30 and m.tokens_openai_brl = 10, 'v_marketing_dia';
  r := public.marketing_resumo_p(d, current_date, current_date);
  assert (r->>'tokens_anthropic_brl')::numeric = 30 and (r->>'tokens_openai_brl')::numeric = 10 and (r->>'tokens_brl')::numeric = 40, 'resumo separa';
  inv := public.dashboard_investimento_p(d, current_date, current_date);
  assert (inv->>'tokens_anthropic_brl')::numeric = 30 and (inv->>'tokens_openai_brl')::numeric = 10, 'investimento separa';
  assert (inv->'dia_a_dia'->0->>'tokens_openai_brl')::numeric = 10, 'dia a dia separa';
  assert (inv->>'investimento_total_brl')::numeric = 140, 'total = ads + Claude + OpenAI';
  -- só OpenAI lançado: Claude volta para a estimativa pelas mensagens (antes sumia)
  delete from public.ad_spend where office_id = d and canal in ('tokens','tokens_anthropic');
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, ai_meta)
  select d, c.id, 'out', 'ia', 'oi', 'sent', '{"cost_usd": 1}' from public.conversations c where c.office_id = d limit 1;
  select * into m from public.marketing_dia_p(d, current_date, current_date);
  assert (select anthropic_brl from public.marketing_tokens_split(d, current_date, current_date)) > 0, 'estimativa conta como Claude';
  assert (select openai_brl from public.marketing_tokens_split(d, current_date, current_date)) = 10, 'OpenAI lançado mantido';
end $$;

-- =============================================================================
-- 014 · 8. Consistência
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v uuid; v_piece uuid; v_conv uuid; h public.human_interventions; r jsonb;
begin
  -- soltar em Peça vindo de Revisão → rascunho (o card fica na coluna Peça)
  v := pg_temp.novo_lead('5511955557001', 'Lead Coluna');
  perform public.ui_move_to_column(v, 'revisao');
  select id into v_piece from public.pieces where lead_id = v;
  assert (select status from public.pieces where id = v_piece) = 'revisao', 'revisão';
  perform public.ui_move_to_column(v, 'peca');
  assert (select status from public.pieces where id = v_piece) = 'rascunho', 'Peça leva a rascunho';
  assert (select coluna from public.v_workflow_cards where lead_id = v) = 'peca', 'card fica em Peça';

  -- quem reivindica o lead com peça em revisão vira o revisor
  perform public.ui_move_to_column(v, 'revisao');
  select id into v_conv from public.conversations where lead_id = v;
  h := public.request_intervention(v, v_conv, 'saneamento_juridico', 'Revisar peça', 2, 'sistema');
  h := public.claim_intervention(h.id);
  assert (select responsavel from public.pieces where id = v_piece) = '44444444-4444-4444-4444-444444444444', 'responsavel = quem reivindicou';

  -- régua sem template com a janela fechada: abre follow_up_esgotado e para de vencer
  v := pg_temp.novo_lead('5511955557002', 'Lead Régua Fechada');
  update public.leads set followup_next_at = now() - interval '1 hour', last_inbound_at = now() - interval '3 days', last_outbound_at = now() - interval '2 days' where id = v;
  r := public.followup_no_template(v);
  assert (r->>'exhausted')::boolean and r->>'reason' = 'sem_template', 'retorno';
  assert (select followup_next_at from public.leads where id = v) is null, 'sai da fila da régua';
  assert exists (select 1 from public.human_interventions where lead_id = v and category = 'follow_up_esgotado' and status = 'pendente' and 'sem_template' = any (tags)), 'follow_up_esgotado aberto';
end $$;

-- ---------- views novas e privilégios (como membro, com RLS)
reset request.jwt.claim.sub;
set role authenticated;
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
do $$ begin
  assert (select count(*) from public.v_clientes) > 0 and not exists (select 1 from public.v_clientes where etapa is null), 'v_clientes com etapa';
  assert exists (select 1 from public.v_clientes where etapa_titulo = 'Encerrado' and closed_kind = 'inviavel'), 'v_clientes: encerramento';
  assert exists (select 1 from public.v_fluxo_cards where agente_rotulo = 'Closer — Fernanda'), 'v_fluxo_cards: agente com persona';
  assert exists (select 1 from public.v_juridico_cards where etapa is not null and peca_etapa is not null and versao >= 1), 'v_juridico_cards';
  assert exists (select 1 from public.v_juridico_cards where responsavel_nome = 'Dora D'), 'v_juridico_cards: responsável';
  assert exists (select 1 from public.v_fila_leads where etapa_titulo is not null), 'v_fila_leads';
  assert not exists (select 1 from public.v_clientes where office_id <> 'dddddddd-dddd-dddd-dddd-dddddddddddd'), 'RLS: só o escritório D';
  assert not has_function_privilege('authenticated', 'public.agent_config_full_lead(uuid)', 'execute'), 'config com prompt só n8n';
  assert not has_function_privilege('authenticated', 'public.followup_no_template(uuid)', 'execute'), 'régua só n8n';
  assert not has_function_privilege('authenticated', 'public.close_lead_with_reason(uuid, text, text, text, text, uuid, text)', 'execute'), 'encerramento interno só pelo banco';
  assert not has_function_privilege('authenticated', 'public.advance_phase(uuid, public.case_phase, text, uuid, text, text, text)', 'execute'), 'advance_phase não é chamável do front';
  assert not has_function_privilege('anon', 'public.ui_close_lead(uuid, text, text, text)', 'execute'), 'anon não executa';
  assert has_function_privilege('authenticated', 'public.ui_close_lead(uuid, text, text, text)', 'execute'), 'front encerra';
end $$;
reset role; reset request.jwt.claim.sub;

-- =============================================================================
-- 015 · 8. Documentos do WhatsApp entram no caso
-- =============================================================================
set request.jwt.claim.sub = '44444444-4444-4444-4444-444444444444';
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v uuid; v_msg uuid; v_msg2 uuid; r jsonb; e public.evidences; v_path text;
begin
  v := pg_temp.novo_lead('5511955558001', 'Lead Documentos');
  select m.id into v_msg from public.messages m join public.conversations c on c.id = m.conversation_id where c.lead_id = v order by m.created_at desc limit 1;
  v_path := d || '/' || v || '/' || v_msg || '.jpg';
  r := public.ingest_media(v_msg, v_path, 'image/jpeg', 245000, 'rg', null, 'meu rg');
  select * into e from public.evidences where id = (r->>'evidence_id')::uuid;
  assert e.status = 'recebida' and e.kind = 'foto' and e.title = 'RG' and e.doc_tipo = 'rg' and e.origem = 'whatsapp'
     and e.storage_path = v_path and e.message_id = v_msg and e.size_bytes = 245000 and e.agent_role = 'recepcao', 'prova criada a partir da mídia';
  assert (select media->>'evidence_id' from public.messages where id = v_msg) = e.id::text, 'mensagem aponta para a prova';
  assert (select actor from public.case_events where lead_id = v and type = 'document_received') = 'ia'
     and (select actor_agent from public.case_events where lead_id = v and type = 'document_received') = 'recepcao', 'document_received com autor IA e agente';
  r := public.ingest_media(v_msg, v_path, 'image/jpeg', 245000, 'rg');
  assert (r->>'duplicate')::boolean and (select count(*) from public.evidences where lead_id = v) = 1, 'reentrega não duplica';

  -- atende uma prova solicitada do mesmo tipo
  insert into public.evidences (office_id, lead_id, kind, title, status, doc_tipo) values (d, v, 'documento', 'CTPS', 'solicitada', 'ctps');
  perform public.ingest_inbound('PNID-D', '5511955558001', 'Lead Documentos', 'wamid.doc2', null, '{"type":"document","mime_type":"application/pdf"}');
  select id into v_msg2 from public.messages where wa_message_id = 'wamid.doc2';
  r := public.ingest_media(v_msg2, d || '/' || v || '/' || v_msg2 || '.pdf', 'application/pdf', 88000, 'ctps', 'ctps.pdf');
  assert (r->>'atendeu_pedido')::boolean and (select count(*) from public.evidences where lead_id = v) = 2, 'pedido atendido, sem prova nova';
  assert (select status from public.evidences where lead_id = v and doc_tipo = 'ctps') = 'recebida', 'CTPS recebida';
  assert public.doc_tipo_titulo('comprovante_pix') = 'Comprovante PIX' and public.doc_tipo_titulo('xyz') = 'Outro documento', 'catálogo de tipos';
  begin
    perform public.ingest_media(v_msg2, 'outro-escritorio/x.pdf', 'application/pdf');
    raise exception 'aceitou caminho fora do escritório';
  exception when others then assert sqlerrm like 'storage_path precisa%', sqlerrm; end;
end $$;

-- =============================================================================
-- 015 · 9. Agendamentos que a IA retoma
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v1 uuid; v2 uuid; r jsonb; t1 uuid; t2 uuid; t public.tasks;
begin
  v1 := pg_temp.novo_lead('5511955559001', 'Lead Agenda Livre');
  r := public.apply_agent_effects(v1, null, 'qualificacao', null, null, null, null,
         jsonb_build_object('title', 'Retomar', 'description', 'Ligar depois do almoço para fechar', 'due_at', now() - interval '5 minutes'));
  t1 := (r->>'task_id')::uuid;
  assert r->>'task_kind' = 'agendamento', 'IA cria agendamento';
  assert (select payload->>'texto' from public.case_events where lead_id = v1 and type = 'agendamento_criado') like 'Agendamento criado para % — Ligar depois do almoço para fechar', 'evento com data e descrição';
  assert (select actor_agent from public.case_events where lead_id = v1 and type = 'agendamento_criado') = 'qualificacao', 'evento com o agente autor';
  assert (select agente_rotulo from public.v_agenda where id = t1) = 'Closer — Fernanda', 'v_agenda com o agente';

  -- outro lead com a conversa assumida pela equipe
  v2 := pg_temp.novo_lead('5511955559002', 'Lead Agenda Assumida');
  update public.conversations set ai_paused = true where lead_id = v2;
  insert into public.tasks (office_id, lead_id, title, description, due_at, created_by_actor, kind, agent_role)
  values (d, v2, 'Retomar', 'Mandar a proposta', now() - interval '1 minute', 'ia', 'agendamento', 'qualificacao') returning id into t2;

  assert public.agendamentos_escalar() = 1, 'escala só o agendamento com a conversa assumida';
  assert exists (select 1 from public.human_interventions where lead_id = v2 and category = 'agendamento' and status = 'pendente'), 'intervenção agendamento para a equipe';
  assert (select escalada_em from public.tasks where id = t2) is not null, 'marcado como escalado';
  assert public.agendamentos_escalar() = 0, 'escalar é idempotente';
  assert exists (select 1 from public.agendamentos_due(50) where task_id = t1) and not exists (select 1 from public.agendamentos_due(50) where task_id = t2), 'due: só conversa não assumida';

  t := public.agendamento_mark_done(t1, 'realizado');
  assert t.status = 'realizado' and t.done_at is not null and (select situacao from public.v_tasks where id = t1) = 'realizado', 'realizado';
  assert not exists (select 1 from public.agendamentos_due(50) where task_id = t1), 'sai da fila';
  assert (select actor from public.case_events where lead_id = v1 and type = 'agendamento_retomado') = 'ia', 'evento da retomada';

  -- front: confirmar, remarcar, cancelar
  t := public.ui_confirm_agendamento(t2);
  assert t.status = 'confirmado' and t.escalada_em is null, 'confirmar libera para nova retomada';
  t := public.ui_reschedule_agendamento(t2, now() + interval '2 days');
  assert t.status = 'remarcado' and t.due_at > now() + interval '1 day', 'remarcar';
  assert (select situacao from public.v_tasks where id = t2) = 'remarcado' and (select status_titulo from public.v_agenda where id = t2) = 'Remarcado', 'situação vem do status';
  t := public.ui_cancel_agendamento(t2);
  assert (select situacao from public.v_tasks where id = t2) = 'cancelado', 'cancelar';
  assert (select count(*) from public.case_events where lead_id = v2 and type = 'agendamento_status' and actor = 'humano') = 3, 'eventos humanos';
  -- UI antiga marcando done_at continua funcionando
  update public.tasks set done_at = now() where id = t1;
  insert into public.tasks (office_id, lead_id, title, due_at) values (d, v1, 'Tarefa manual', now() + interval '1 day') returning id into t1;
  update public.tasks set done_at = now() where id = t1;
  assert (select status from public.tasks where id = t1) = 'realizado', 'done_at → realizado';
end $$;

-- =============================================================================
-- 015 · 10. Monitores da fila (idempotentes)
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v_parado uuid; v_ia uuid; v_ctr uuid; v_dup uuid; v_ant uuid; r1 jsonb; r2 jsonb; n int; r jsonb;
begin
  -- caso parado: última mensagem há 3 dias
  v_parado := pg_temp.novo_lead('5511955550101', 'Lead Parado');
  update public.messages set created_at = now() - interval '3 days' where conversation_id in (select id from public.conversations where lead_id = v_parado);
  update public.conversations set last_message_at = now() - interval '3 days' where lead_id = v_parado;
  -- a IA não respondeu: última mensagem do lead há 40 min
  v_ia := pg_temp.novo_lead('5511955550102', 'Lead Sem Resposta');
  update public.messages set created_at = now() - interval '40 minutes' where conversation_id in (select id from public.conversations where lead_id = v_ia);
  update public.conversations set last_message_at = now() - interval '40 minutes' where lead_id = v_ia;
  -- contrato enviado há 25h
  v_ctr := pg_temp.novo_lead('5511955550103', 'Lead Contrato');
  insert into public.contracts (office_id, lead_id, status, honorarios_percent, sent_at) values (d, v_ctr, 'enviado', 30, now() - interval '25 hours');
  -- mesmo CPF de quem já tem caso assinado
  v_ant := pg_temp.novo_lead('5511955550104', 'Cliente Antigo');
  update public.contacts set cpf = '020.383.999-48' where id = (select contact_id from public.leads where id = v_ant);
  insert into public.contracts (office_id, lead_id, status, honorarios_percent) values (d, v_ant, 'assinado', 30);
  v_dup := pg_temp.novo_lead('5511955550105', 'Cliente Antigo Outro Número');
  update public.contacts set cpf = '020.383.999-48' where id = (select contact_id from public.leads where id = v_dup);

  r1 := public.run_monitors();
  assert exists (select 1 from public.human_interventions where lead_id = v_parado and category = 'caso_parado' and reason = 'Caso parado >48h' and requested_by_actor = 'sistema'), 'caso parado';
  assert exists (select 1 from public.human_interventions where lead_id = v_ia and category = 'ia_sem_resposta' and reason = 'IA não respondeu há 30+ min'), 'IA sem resposta';
  assert exists (select 1 from public.human_interventions where lead_id = v_ctr and category = 'contrato_nao_assinado_24h' and reason = 'Contrato pendente >24h'), 'contrato pendente';
  assert exists (select 1 from public.human_interventions where lead_id = v_dup and category = 'cliente_ja_existente' and reason = 'Cliente já existente'), 'cliente já existente (CPF)';
  assert not exists (select 1 from public.human_interventions where lead_id = v_ant and category = 'cliente_ja_existente'), 'quem já assinou não é alertado';
  assert (r1->>'caso_parado')::int >= 1 and (r1->>'ia_sem_resposta')::int >= 1 and (r1->>'contrato_nao_assinado_24h')::int = 1 and (r1->>'cliente_ja_existente')::int = 1, 'contagem: ' || r1::text;
  select count(*) into n from public.human_interventions where status in ('pendente','em_atendimento');
  r2 := public.run_monitors();
  assert (r2->>'caso_parado')::int = 0 and (r2->>'ia_sem_resposta')::int = 0 and (r2->>'contrato_nao_assinado_24h')::int = 0 and (r2->>'cliente_ja_existente')::int = 0, 'segunda rodada não cria nada: ' || r2::text;
  assert (select count(*) from public.human_interventions where status in ('pendente','em_atendimento')) = n, 'segunda rodada não duplica';
  assert (select grupo_titulo from public.v_intervention_cards where lead_id = v_parado and category = 'caso_parado') = 'Seguir conversa', 'caso parado cai em Seguir conversa';

  -- na ingestão: telefone com caso assinado (lead encerrado) abre lead novo com alerta
  perform public.advance_phase(v_ant, 'encerrado', 'sistema', null, null, 'protocolado e arquivado');
  r := public.ingest_inbound('PNID-D', '5511955550104', 'Cliente Antigo', 'wamid.volta', 'Oi, e o meu processo?');
  assert (r->>'new_lead')::boolean and not (r->>'ai_should_reply')::boolean, 'lead novo, IA não responde por cima';
  assert exists (select 1 from public.human_interventions where lead_id = (r->>'lead_id')::uuid and category = 'cliente_ja_existente'), 'alerta na ingestão';
end $$;

-- =============================================================================
-- 015 · 11. Calculista: qualificação detalhada e versionada
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v uuid; v2 uuid; q public.qualification_records; p jsonb; ev jsonb;
begin
  v := pg_temp.novo_lead('5511955550201', 'Lead Calculista');
  insert into public.case_data (lead_id, office_id, empresa, admissao, demissao, salario, tipo_rescisao, aviso_previo, ctps_assinada, fgts_depositado)
  values (v, d, 'Fábrica Z', current_date - 1500, current_date - 700, 3200, 'sem_justa_causa', 'indenizado', true, false);
  perform public.advance_phase(v, 'calculo', 'sistema');
  insert into public.briefings (office_id, lead_id, status, completed_at, teses) values (d, v, 'concluido', now() - interval '1 minute', array['horas_extras']);

  p := public.prescricao_info(v);
  assert p->>'status_bienal' = 'alerta' and (p->>'dias_restantes')::int = 30, 'prescrição bienal calculada no banco: ' || p::text;
  assert (p->>'limite_quinquenal')::date = ((p->>'data_provavel_ajuizamento')::date - interval '5 years')::date, 'quinquenal';
  assert jsonb_array_length(p->'excecoes') >= 1, 'exceção do FGTS listada';

  assert exists (select 1 from public.calculista_queue(10) c where c.lead_id = v and c.prescricao->>'status_bienal' = 'alerta'), 'na fila do Calculista com a prescrição';
  q := public.save_qualification_record(v, '{"dados_base":{"salario_base_calculo":3200,"meses_contrato":"26"},
        "verbas":[{"verba":"Horas extras","valor_calculado":"R$ 9.000,00","ja_recebido":0},{"verba":"FGTS","total":3101}],
        "prescricao":{"status_bienal":"ok"}}'::jsonb, 'calculo', '{"tokens_in":10}');
  assert q.versao = 1 and (q.data->>'total')::numeric = 12101 and q.data->>'faixa' = 'baixo' and q.data->>'faixa_label' = 'LOW_TICKET', 'v1 LOW: ' || q.data::text;
  assert q.data->'prescricao'->>'status_bienal' = 'alerta', 'prescrição do LLM é substituída pela do banco';
  assert (select verbas_total from public.lead_qualification where lead_id = v) = 12101 and (select faixa from public.lead_qualification where lead_id = v) = 'baixo', 'lead_qualification atualizada';
  assert (select phase from public.leads where id = v) = 'provas', 'calculo → provas';
  assert (select actor_agent from public.case_events where lead_id = v and type = 'phase_changed' order by seq desc limit 1) = 'calculo', 'avanço com o Calculista';
  select payload into ev from public.case_events where lead_id = v and type = 'qualificacao_gerada' order by seq desc limit 1;
  assert ev->>'texto' = 'Qualificação (cálculo) gerada — LOW_TICKET R$ 12.101,00', 'evento: ' || (ev->>'texto');
  assert not exists (select 1 from public.calculista_queue(10) c where c.lead_id = v), 'sai da fila';
  q := public.save_qualification_record(v, '{"verbas":[{"verba":"Rescisórias","total":"67.904,00"}]}');
  assert q.versao = 2 and q.data->>'faixa' = 'medio' and (select faixa from public.lead_qualification where lead_id = v) = 'medio', 'v2 recalcula a faixa (MID)';

  -- abaixo do mínimo: não avança; a equipe decide
  v2 := pg_temp.novo_lead('5511955550202', 'Lead Calculista Pequeno');
  perform public.advance_phase(v2, 'calculo', 'sistema');
  q := public.save_qualification_record(v2, '{"verbas":[{"verba":"Saldo","total":1771}]}');
  assert q.data->>'faixa_label' = 'INVIAVEL' and not (q.data->>'passed')::boolean, 'abaixo de 2.000 = inviável';
  assert (select phase from public.leads where id = v2) = 'calculo', 'inviável não avança';
  assert exists (select 1 from public.human_interventions where lead_id = v2 and category = 'saneamento_juridico' and 'calculista' = any (tags)), 'equipe avisada';
  begin
    perform public.save_qualification_record(v2, '{"verbas":"nada"}');
    raise exception 'aceitou verbas inválidas';
  exception when others then assert sqlerrm like 'data.verbas%', sqlerrm; end;
  assert public.to_num('R$ 1.234,56') = 1234.56 and public.to_num('1,234.56') = 1234.56 and public.to_num('abc') is null, 'to_num';
  assert exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'qualification_records'), 'Realtime';
end $$;

-- =============================================================================
-- 015 · 12. Geração da peça
-- =============================================================================
do $$
declare d uuid := 'dddddddd-dddd-dddd-dddd-dddddddddddd'; v uuid; v2 uuid; pc public.pieces; c record; n int; r jsonb;
begin
  v := (select id from public.leads where office_id = d and phase = 'provas' and contact_id = (select id from public.contacts where wa_id = '5511955550201'));
  pc := public.ui_finish_collection(v);
  assert (select phase from public.leads where id = v) = 'peca', 'Finalizar coleta leva à peça';
  assert pc.status = 'rascunho' and pc.geracao_status = 'pendente' and pc.tese = 'horas_extras', 'peça criada em rascunho, pendente de geração';
  assert (select actor from public.case_events where lead_id = v and type = 'piece_generation_requested') = 'humano', 'pedido com autor humano';
  assert (public.ui_finish_collection(v)).id = pc.id, 'clicar de novo devolve a mesma peça';
  assert (select count(*) from public.pieces where lead_id = v) = 1, 'clicar de novo não cria outra peça';

  select count(*) into n from public.piece_generation_claim(5) x where x.piece_id = pc.id;
  assert n = 1, 'n8n pega a peça';
  assert (select geracao_status from public.pieces where id = pc.id) = 'gerando', 'marcada como gerando';
  assert not exists (select 1 from public.piece_generation_claim(5) x where x.piece_id = pc.id), 'não pega duas vezes';
  update public.pieces set geracao_status = 'pendente' where id = pc.id;
  select * into c from public.piece_generation_claim(5) x where x.piece_id = pc.id;
  assert jsonb_array_length(c.blocos) >= 8 and c.teses = array['horas_extras'] and (c.qualificacao->>'versao')::int = 2
     and c.contato->>'nome' = 'Lead Calculista' and c.escritorio->>'nome' = 'Escritório D', 'insumos: blocos, teses, qualificação, contato, escritório';
  perform set_config('request.jwt.claim.sub', '', false);   -- como o n8n
  pc := public.piece_generation_save(pc.id, E'EXCELENTÍSSIMO SENHOR JUIZ...\n\nDOS FATOS...', 'Horas extras habituais sem pagamento.',
                                     '["CTPS","Holerites"]', 'viavel', '{"tokens_out": 5000}');
  assert pc.status = 'revisao' and pc.geracao_status = 'gerada' and pc.qualidade = 'viavel' and pc.resumo_executivo is not null, 'peça em revisão';
  assert (select actor_agent from public.case_events where lead_id = v and type = 'piece_generated') = 'redacao', 'evento do Redator';
  assert (select actor from public.case_events where lead_id = v and type = 'piece_status_changed' order by seq desc limit 1) = 'ia', 'mudança de etapa com autor IA';
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);

  -- o Coletor também finaliza
  v2 := pg_temp.novo_lead('5511955550203', 'Lead Coletor');
  perform public.advance_phase(v2, 'provas', 'sistema');
  perform set_config('request.jwt.claim.sub', '', false);
  r := public.apply_agent_effects(v2, null, 'provas', null, 'peca', 'documentos essenciais recebidos');
  assert (select phase from public.leads where id = v2) = 'peca' and r->>'geracao' = 'pendente', 'Coletor pede a peça';
  assert (select actor_agent from public.case_events where lead_id = v2 and type = 'piece_generation_requested') = 'provas', 'pedido com o agente Coletor';
  pc := public.piece_generation_failed((r->>'piece_id')::uuid, 'timeout do modelo');
  assert pc.geracao_status = 'falhou' and exists (select 1 from public.human_interventions where lead_id = v2 and category = 'erro_ia'), 'falha vira tarefa';
  perform set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', false);

  v2 := pg_temp.novo_lead('5511955550204', 'Lead Cedo Demais');
  begin
    perform public.ui_finish_collection(v2);
    raise exception 'gerou peça antes da coleta';
  exception when others then assert sqlerrm like 'a peça só é gerada depois%', sqlerrm; end;
end $$;

-- ---------- privilégios 015 e RLS
reset request.jwt.claim.sub;
set role authenticated;
set request.jwt.claim.sub = '55555555-5555-5555-5555-555555555555';   -- Edu, atendente do D
do $$ begin
  assert (select count(*) from public.qualification_records) >= 3, 'membro lê o cálculo';
  assert exists (select 1 from public.v_agenda), 'membro lê a agenda';
  begin
    insert into public.qualification_records (lead_id, office_id, versao) select id, office_id, 99 from public.leads limit 1;
    raise exception 'front gravou cálculo';
  exception when insufficient_privilege then null; when others then assert sqlerrm like '%row-level security%', sqlerrm; end;
  assert not has_function_privilege('authenticated', 'public.ingest_media(uuid, text, text, bigint, text, text, text)', 'execute'), 'ingest_media só n8n';
  assert not has_function_privilege('authenticated', 'public.run_monitors()', 'execute'), 'monitores só n8n';
  assert not has_function_privilege('authenticated', 'public.agendamentos_due(int)', 'execute'), 'agenda da IA só n8n';
  assert not has_function_privilege('authenticated', 'public.save_qualification_record(uuid, jsonb, text, jsonb)', 'execute'), 'cálculo só n8n';
  assert not has_function_privilege('authenticated', 'public.piece_generation_claim(int)', 'execute'), 'geração só n8n';
  assert not has_function_privilege('authenticated', 'public.ingest_inbound(text, text, text, text, text, jsonb, timestamptz)', 'execute'), 'ingestão só n8n';
  assert has_function_privilege('authenticated', 'public.ui_finish_collection(uuid)', 'execute') and has_function_privilege('authenticated', 'public.ui_reschedule_agendamento(uuid, timestamptz)', 'execute'), 'RPCs do front';
end $$;
reset role; reset request.jwt.claim.sub;

rollback;
\echo PARIDADE OK
