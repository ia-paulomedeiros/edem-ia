-- Smoke test: roda depois de 001, 002 e 003 (ver run.sh).
-- Cobre: ingestão idempotente, isolamento entre escritórios, trava do takeover,
-- fase com autor (critério de aceite do Sprint 2), portão, prescrição, fila, dossiê.
-- Qualquer falha aborta com exception.

\set ON_ERROR_STOP on
set client_min_messages = warning;

begin;

-- ---------- fixtures (como service_role: superuser aqui, bypass RLS)
insert into auth.users (id, email, raw_user_meta_data) values
  ('11111111-1111-1111-1111-111111111111', 'ana@escritorio-a.test', '{"full_name":"Ana A"}'),
  ('22222222-2222-2222-2222-222222222222', 'bruno@escritorio-b.test', '{"full_name":"Bruno B"}');

insert into public.offices (id, name, slug) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Escritório A', 'a'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'Escritório B', 'b');

insert into public.office_members (office_id, user_id, role) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '11111111-1111-1111-1111-111111111111', 'advogado'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '22222222-2222-2222-2222-222222222222', 'admin');

insert into public.whatsapp_numbers (office_id, phone_number_id, display_phone, token_secret_name) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'PNID-A', '5511999990000', 'wa_token_office_a'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'PNID-B', '5511999991111', 'wa_token_office_b');

-- ---------- ingestão (n8n)
create temp table t as
select public.ingest_inbound('PNID-A', '5511988887777', 'Carlos Lead', 'wamid.1', 'Oi, fui demitido sem receber nada') r;

do $$
declare r jsonb; r2 jsonb;
begin
  select t.r into r from t;
  assert (r->>'duplicate')::boolean = false, 'primeira ingestão não é duplicada';
  assert (r->>'new_lead')::boolean = true, 'cria lead';
  assert (r->>'ai_should_reply')::boolean = true, 'IA deve responder a lead novo';
  r2 := public.ingest_inbound('PNID-A', '5511988887777', 'Carlos Lead', 'wamid.1', 'Oi, fui demitido sem receber nada');
  assert (r2->>'duplicate')::boolean = true, 'reentrega da Meta é ignorada';
  assert (select count(*) from public.messages) = 1, 'uma mensagem só';
  assert (select count(*) from public.case_events where type = 'lead_created' and actor = 'sistema') = 1, 'evento lead_created com autor sistema';
  assert (select profiles.full_name from public.profiles where user_id = '11111111-1111-1111-1111-111111111111') = 'Ana A', 'profile criado pelo trigger';
end $$;

-- lead do escritório B, para o teste de isolamento
do $$ begin perform public.ingest_inbound('PNID-B', '5511977776666', 'Lead do B', 'wamid.b1', 'olá'); end $$;

-- ---------- isolamento (Ana só vê A; Bruno só vê B)
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
declare v_lead uuid;
begin
  assert (select count(*) from public.leads) = 1, 'Ana vê 1 lead';
  assert (select count(*) from public.messages) = 1, 'Ana vê 1 mensagem';
  assert (select count(*) from public.case_events) >= 1, 'Ana vê eventos';
  assert (select count(*) from public.v_case_cards) = 1, 'Ana vê 1 card';
  assert (select office_id from public.leads limit 1) = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'e é do escritório A';
  select id into v_lead from public.leads;
  assert public.lead_dossier(v_lead) is not null, 'dossiê do próprio escritório';
end $$;

set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
declare v_lead_a uuid; v_dossier jsonb;
begin
  assert (select count(*) from public.leads) = 1, 'Bruno vê 1 lead';
  assert (select office_id from public.leads limit 1) = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'e é do escritório B';
  assert (select count(*) from public.messages where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 0, 'Bruno não vê mensagens de A';
  assert (select count(*) from public.case_events where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 0, 'Bruno não vê eventos de A';
  assert (select count(*) from public.tasks where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') = 0, 'Bruno não vê tarefas de A';
end $$;
reset role; reset request.jwt.claim.sub;

-- ---------- critério de aceite: fase pelo kanban grava evento com autor
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
declare v_lead uuid; l public.leads; ev public.case_events;
begin
  select id into v_lead from public.leads;
  l := public.ui_advance_phase(v_lead, 'qualificacao', 'arrastado no kanban');
  assert l.phase = 'qualificacao', 'fase mudou';
  select * into ev from public.case_events where lead_id = v_lead and type = 'phase_changed' order by seq desc limit 1;
  assert ev.actor = 'humano', 'autor é humano';
  assert ev.actor_user_id = '11111111-1111-1111-1111-111111111111', 'autor é a Ana';
  assert ev.payload->>'from' = 'novo' and ev.payload->>'to' = 'qualificacao', 'payload from/to';
  assert (public.lead_dossier(v_lead)->'events'->0->>'actor_name') = 'Ana A', 'linha do tempo mostra o nome';

  -- ninguém forja autor por insert direto
  begin
    insert into public.case_events (office_id, lead_id, type, actor, actor_user_id)
    values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_lead, 'x', 'ia', null);
    raise exception 'insert direto de evento da IA pela UI deveria falhar';
  exception when insufficient_privilege or check_violation then null;
  end;
end $$;

-- Bruno não move lead da Ana
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
do $$
declare v_lead uuid;
begin
  select id into v_lead from public.leads where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  assert v_lead is null, 'Bruno nem enxerga o lead de A';
  begin
    perform public.ui_advance_phase('00000000-0000-0000-0000-000000000000', 'provas');
    raise exception 'deveria falhar';
  exception when others then
    assert sqlerrm like '%não encontrado%', 'erro esperado: lead não encontrado, veio: ' || sqlerrm;
  end;
end $$;
reset role; reset request.jwt.claim.sub;

-- ---------- IA não retrocede; sistema pode
do $$
declare v_lead uuid;
begin
  select id into v_lead from public.leads where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  begin
    perform public.advance_phase(v_lead, 'novo', 'ia', null, 'recepcao');
    raise exception 'IA retrocedeu';
  exception when others then
    assert sqlerrm like '%não pode retroceder%', sqlerrm;
  end;
  perform public.advance_phase(v_lead, 'provas', 'ia', null, 'qualificacao', 'portão aprovado');
  assert (select phase from public.leads where id = v_lead) = 'provas', 'IA avançou';
  assert (select actor_agent from public.case_events where lead_id = v_lead and type = 'phase_changed' order by seq desc limit 1) = 'qualificacao', 'evento da IA nomeia o agente';
  assert public.agent_for_phase('provas') = 'provas', 'agent_for_phase';
  assert (public.agent_config('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'peca')).role = 'redacao', 'agent_config global';
end $$;

-- ---------- dados do caso, prescrição, portão, cards
do $$
declare v_lead uuid; q public.lead_qualification; v jsonb; card public.v_case_cards;
begin
  select id into v_lead from public.leads where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  insert into public.case_data (lead_id, office_id, empresa, admissao, demissao, salario, tipo_rescisao, aviso_previo, fgts_depositado, horas_extras_semanais)
  values (v_lead, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'Empresa X', '2021-03-01', current_date - 700, 3000, 'sem_justa_causa', 'indenizado', false, 5);

  assert (select prescricao_em from public.leads where id = v_lead) = (current_date - 700 + interval '2 years')::date, 'prescrição bienal';
  assert (select count(*) from public.case_events where lead_id = v_lead and type = 'case_data_updated') = 1, 'evento de dados';

  v := public.calc_verbas(v_lead);
  assert (v->>'calculado')::boolean, 'calculou';
  assert (v->>'total')::numeric > 0, 'total > 0';

  q := public.qualification_gate(v_lead, 'ia');
  assert q.passed, 'portão aprova: ' || array_to_string(q.motivos, ',');
  assert q.faixa in ('baixo','medio','alto'), 'faixa';

  select * into card from public.v_case_cards where lead_id = v_lead;
  assert card.prescricao_dias = 730 - 700, 'dias até prescrever';
  assert card.prescricao_alerta = true, 'dentro da janela de 90 dias';
  assert card.prescricao_vencida = false, 'não vencida';
  assert card.qualificado = true, 'card mostra qualificado';

  -- apertar o vínculo mínimo reprova
  update public.office_params set vinculo_minimo_meses = 120 where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  q := public.qualification_gate(v_lead, 'sistema');
  assert not q.passed and q.motivos[1] like 'vinculo_curto%', 'reprova por vínculo';
  update public.office_params set vinculo_minimo_meses = 6 where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';

  -- alerta obedece office_params.alerta_prescricao_dias
  update public.office_params set alerta_prescricao_dias = 10 where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  assert (select prescricao_alerta from public.v_case_cards where lead_id = v_lead) = false, 'fora da janela de 10 dias';

  assert (select count(*) from public.search_cases('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'carlos')) = 1, 'busca por nome';
  assert (select count(*) from public.search_cases('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '(11) 98888')) = 1, 'busca por telefone formatado';
  assert (select count(*) from public.search_cases('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'empresa x')) = 1, 'busca por empresa';
end $$;

-- ---------- trava do takeover
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
declare v_conv uuid; m public.messages;
begin
  select id into v_conv from public.conversations;
  assert public.ai_should_reply(v_conv), 'IA responde antes do takeover';
  m := public.send_manual_message(v_conv, 'Olá, aqui é a Ana, vou continuar seu atendimento');
  assert m.sender = 'humano' and m.status = 'pending' and m.sent_by = '11111111-1111-1111-1111-111111111111', 'linha criada antes de qualquer envio';
  assert (select ai_paused from public.conversations where id = v_conv), 'enviar manual = assumir';
  assert not public.ai_should_reply(v_conv), 'IA cala';
  assert (select count(*) from public.case_events where type = 'takeover' and actor = 'humano' and actor_user_id = '11111111-1111-1111-1111-111111111111') = 1, 'evento takeover com autor';
  perform public.release_to_ai(v_conv);
  assert public.ai_should_reply(v_conv), 'IA volta';
  assert (select count(*) from public.case_events where type = 'ai_released') = 1, 'evento ai_released';

  -- UI não insere mensagem em nome da IA
  begin
    insert into public.messages (office_id, conversation_id, direction, sender, body)
    values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', v_conv, 'out', 'ia', 'x');
    raise exception 'UI inseriu mensagem como IA';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role; reset request.jwt.claim.sub;

-- ---------- fila de intervenção
do $$
declare v_lead uuid; v_conv uuid; h public.human_interventions;
begin
  select id into v_lead from public.leads where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  select id into v_conv from public.conversations where lead_id = v_lead;
  h := public.request_intervention(v_lead, v_conv, 'duvida_juridica', 'Lead pergunta sobre acordo extrajudicial', 1, 'ia', 'provas');
  assert h.status = 'pendente', 'na fila';
  assert not public.ai_should_reply(v_conv), 'IA cala com intervenção aberta';
  assert (select intervencao_pendente from public.v_case_cards where lead_id = v_lead), 'card mostra fila';
  assert (public.request_intervention(v_lead, v_conv, 'outro', 'de novo')).id = h.id, 'não duplica';
end $$;

set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$
declare h public.human_interventions; v_conv uuid;
begin
  select * into h from public.human_interventions;
  h := public.claim_intervention(h.id);
  assert h.status = 'em_atendimento' and h.claimed_by = '11111111-1111-1111-1111-111111111111', 'assumiu';
  h := public.assign_intervention(h.id, null);
  assert h.status = 'pendente' and h.claimed_by is null, 'devolveu para a fila';
  h := public.assign_intervention(h.id, '11111111-1111-1111-1111-111111111111');
  assert h.status = 'em_atendimento', 'atribuiu';
  h := public.log_intervention_call(h.id, 'ligou, caixa postal');
  assert h.calls_count = 1, 'ligação registrada';
  assert (select count(*) from public.case_events where type = 'call_logged') = 1, 'evento de ligação';
  h := public.resolve_intervention(h.id, 'Expliquei e seguimos', true);
  assert h.status = 'resolvida', 'resolvida';
  select id into v_conv from public.conversations;
  assert public.ai_should_reply(v_conv), 'IA liberada ao resolver';
end $$;
reset role; reset request.jwt.claim.sub;

-- ---------- efeitos estruturados do agente (n8n)
do $$
declare v_lead uuid; v_conv uuid; r jsonb;
begin
  select id into v_lead from public.leads where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  select id into v_conv from public.conversations where lead_id = v_lead;
  r := public.apply_agent_effects(v_lead, v_conv, 'provas', '{"cargo":"vendedor","ferias_vencidas":1}', 'calculo', 'provas suficientes', null);
  assert r->>'phase' = 'calculo', 'agente avançou para calculo';
  assert (select cargo from public.case_data where lead_id = v_lead) = 'vendedor', 'agente atualizou dados';
  assert (select updated_by_actor from public.case_data where lead_id = v_lead) = 'ia', 'autor ia nos dados';
  assert (select actor from public.case_events where lead_id = v_lead and type = 'case_data_updated' order by seq desc limit 1) = 'ia', 'evento de dados nomeia a IA';
  r := public.apply_agent_effects(v_lead, v_conv, 'calculo', null, null, null, '{"category":"pedido_de_humano","reason":"quer falar com advogado","priority":1}');
  assert (r->>'intervention_id') is not null, 'intervenção criada';
  assert not public.ai_should_reply(v_conv), 'IA cala';
  update public.human_interventions set status = 'cancelada' where lead_id = v_lead and status = 'pendente';
  update public.conversations set ai_paused = false where id = v_conv;
end $$;

-- ---------- encerramento com closed_by e realtime
do $$
declare v_lead uuid; l public.leads;
begin
  select id into v_lead from public.leads where office_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
  l := public.advance_phase(v_lead, 'encerrado', 'ia', null, 'recepcao', 'fora do escopo');
  assert l.closed_by = 'ia' and l.closed_at is not null, 'closed_by ia';
  assert (select status from public.conversations where lead_id = v_lead) = 'closed', 'conversa fechou';
  l := public.advance_phase(v_lead, 'provas', 'sistema', null, null, 'reaberto');
  assert l.closed_by is null and l.closed_at is null, 'reabriu';
  assert (select status from public.conversations where lead_id = v_lead) = 'open', 'conversa reabriu';

  assert (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public'
          and tablename in ('messages','conversations','leads','case_events','tasks','human_interventions','evidences')) = 7,
         'todas as tabelas ao vivo estão na publicação';

  assert (select count(*) from public.lead_acquisition_cost where lead_id = v_lead) = 1, 'custo de aquisição projetado';
end $$;

-- ---------- configurações: integrações com segredo no Vault, modelos, prompts ocultos
reset role; reset request.jwt.claim.sub;
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';   -- Bruno, admin do B
do $$
declare r jsonb; v_id uuid; b uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
begin
  r := public.set_integration(b, 'meta_whatsapp', 'EAAG-token-secreto',
        '{"phone_number_id":"PNID-B","waba_id":"WABA-B","display_phone":"5511999991111"}', true);
  assert r->>'status' = 'nao_testado' and (r->>'has_secret')::boolean and (r->>'active')::boolean, 'integração salva';
  assert not (r ? 'secret') and not (r ? 'secret_name'), 'projeção pública não expõe o segredo';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'integrations' and column_name = 'secret'), 'tabela não tem coluna de segredo';
  assert (select token_secret_name from public.whatsapp_numbers where phone_number_id = 'PNID-B') = public.integration_secret_name(b, 'meta_whatsapp'), 'número da Meta aponta para o segredo';

  -- ativar outra mensageria desativa a anterior (uma ativa por vez)
  r := public.set_integration(b, 'datacrazy', 'dc-key', '{"instance_url":"https://dc.example"}', true);
  assert (select active from public.integrations where office_id = b and provider = 'meta_whatsapp') = false, 'meta desativada';
  assert public.active_integration(b, 'mensageria') = 'datacrazy', 'datacrazy ativa';

  v_id := public.request_integration_test(b, 'datacrazy');
  assert (select status from public.integrations where id = v_id) = 'teste_solicitado', 'teste solicitado';

  r := public.set_integration(b, 'anthropic', 'sk-ant-x', null, true);
  assert (select count(*) from public.integrations) = 3, 'Bruno vê as 3 integrações do B';
  assert (select count(*) from public.integration_catalog) = 9, 'catálogo com 9 provedores';

  -- funções do n8n não são executáveis pelo cliente
  assert not has_function_privilege('authenticated', 'public.integration_secret(uuid,text)', 'execute'), 'integration_secret bloqueada';
  assert not has_function_privilege('authenticated', 'public.integration_tested(uuid,boolean,text)', 'execute'), 'integration_tested bloqueada';
  assert not has_function_privilege('authenticated', 'public.agent_config_full(uuid,public.case_phase)', 'execute'), 'agent_config_full bloqueada';

  -- prompts e esqueletos internos não aparecem para o cliente
  assert (select count(*) from public.agents) >= 7, 'agentes visíveis (nome, papel, modelo)';
  assert not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'agents' and column_name = 'system_prompt'), 'prompt saiu de agents';
  assert (select count(*) from public.agent_prompts) = 0, 'agent_prompts invisível';
  assert (select count(*) from public.piece_templates) = 0, 'piece_templates invisível';

  -- modelos de petição: biblioteca de arquivos
  insert into public.piece_models (office_id, name, category, file_path, required)
  values (b, 'Cabeçalho padrão', 'geral', b::text || '/cabecalho.docx', true),
         (b, 'Horas extras — modelo', 'horas_extras', b::text || '/he.docx', false);
  assert (select count(*) from public.piece_models) = 2, 'Bruno vê os 2 modelos';
  assert (select count(*) from public.piece_models_for(b, 'horas_extras')) = 2, 'obrigatório + tese';
  assert (select count(*) from public.piece_models_for(b, 'verbas_rescisorias')) = 1, 'só o obrigatório';

  -- dados da empresa
  update public.offices set cnpj = '12.345.678/0001-90', oab_responsavel = 'OAB/SP 123456', whatsapp_comercial = '5511999991111' where id = b;
  assert (select cnpj from public.offices where id = b) = '12.345.678/0001-90', 'admin edita a empresa';

  -- remover apaga a linha
  perform public.remove_integration(b, 'anthropic');
  assert (select count(*) from public.integrations where provider = 'anthropic') = 0, 'integração removida';
end $$;

-- Ana (advogado do A) não vê nada do B e não altera integração (não é admin)
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
do $$ begin
  assert (select count(*) from public.integrations) = 0, 'Ana não vê integrações do B';
  assert (select count(*) from public.piece_models) = 0, 'Ana não vê modelos do B';
  begin
    perform public.set_integration('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'anthropic', 'sk', null, true);
    raise exception 'FALHOU';
  exception when others then
    if sqlerrm = 'FALHOU' then raise exception 'advogado não pode salvar integração'; end if;
  end;
end $$;

-- n8n (service_role): resolve o segredo, registra o teste, lê o prompt
reset role; reset request.jwt.claim.sub;
do $$
declare v_id uuid; b uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
begin
  assert public.integration_secret(b, 'datacrazy') = 'dc-key', 'segredo resolvido';
  assert public.integration_secret(b, 'meta_whatsapp') = 'EAAG-token-secreto', 'token da Meta resolvido';
  assert (select decrypted_secret from vault.decrypted_secrets d join public.whatsapp_numbers w on w.token_secret_name = d.name where w.phone_number_id = 'PNID-B') = 'EAAG-token-secreto', 'token pelo número';
  assert not exists (select 1 from vault.secrets where name = public.integration_secret_name(b, 'anthropic')), 'remover apagou o segredo do Vault';
  select id into v_id from public.integrations where office_id = b and provider = 'datacrazy';
  perform public.integration_tested(v_id, false, 'HTTP 401');
  assert (select status from public.integrations where id = v_id) = 'falhou' and (select last_error from public.integrations where id = v_id) = 'HTTP 401', 'falha registrada';
  perform public.integration_tested(v_id, true);
  assert (select status from public.integrations where id = v_id) = 'validado' and (select last_error from public.integrations where id = v_id) is null, 'validado';
  assert (public.agent_config_full(b, 'novo')->>'role') = 'recepcao' and (public.agent_config_full(b, 'novo') ? 'system_prompt'), 'config completa do agente com prompt';
  -- prompt global é definido só por quem tem service_role; override do escritório (sem prompt) herda
  update public.agent_prompts p set system_prompt = 'PROMPT GLOBAL RECEPCAO' from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'recepcao';
  insert into public.agents (office_id, role, name, model) values (b, 'recepcao', 'Recepção do B', 'claude-haiku-4-5-20251001');
  assert (public.agent_config_full(b, 'novo')->>'model') = 'claude-haiku-4-5-20251001', 'override do escritório vale';
  assert (public.agent_config_full(b, 'novo')->>'system_prompt') = 'PROMPT GLOBAL RECEPCAO', 'override herda o prompt global';
end $$;

rollback;
\echo SMOKE OK
