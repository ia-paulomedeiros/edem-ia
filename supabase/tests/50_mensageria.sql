-- Mensageria própria (017). Roda depois de 10..40 (ver run.sh). Tudo numa transação desfeita no fim.

\set ON_ERROR_STOP on
set client_min_messages = warning;
begin;

-- ---------- fixtures: escritório E, admin Ana, atendente Beto, advogado Caio; dois números
insert into auth.users (id, email, raw_user_meta_data) values
  ('77777777-7777-7777-7777-777777777777', 'ana@escritorio-e.test', '{"full_name":"Ana E"}'),
  ('88888888-8888-8888-8888-888888888888', 'beto@escritorio-e.test', '{"full_name":"Beto E"}'),
  ('99999999-9999-9999-9999-999999999999', 'caio@escritorio-e.test', '{"full_name":"Caio E"}');
insert into public.offices (id, name, slug) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'Escritório E', 'e');
insert into public.office_members (office_id, user_id, role) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '77777777-7777-7777-7777-777777777777', 'admin'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '88888888-8888-8888-8888-888888888888', 'atendente'),
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '99999999-9999-9999-9999-999999999999', 'advogado');
insert into public.whatsapp_numbers (id, office_id, phone_number_id, waba_id, display_phone, token_secret_name) values
  ('e1000000-0000-0000-0000-000000000001', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'PNID-E1', 'WABA-E', '5511944440001', 'wa_token_office_e'),
  ('e1000000-0000-0000-0000-000000000002', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'PNID-E2', 'WABA-E', '5511944440002', 'wa_token_office_e');

-- Mensagem recebida pelo caminho real; devolve o retorno do ingest_inbound.
create or replace function pg_temp.entra(p_num text, p_wa text, p_nome text, p_body text default 'Oi') returns jsonb language sql as $$
  select public.ingest_inbound(p_num, p_wa, p_nome, 'wamid.' || p_wa || '.' || extract(epoch from clock_timestamp())::text, p_body);
$$;
create or replace function pg_temp.conv(p_wa text) returns uuid language sql as $$
  select c.id from public.conversations c join public.contacts ct on ct.id = c.contact_id where ct.wa_id = p_wa order by c.created_at desc limit 1;
$$;
create or replace function pg_temp.eventos(p_conv uuid) returns bigint language sql as $$
  select count(*) from public.messages where conversation_id = p_conv and kind = 'evento';
$$;

-- =============================================================================
-- Seed por escritório
-- =============================================================================
do $$
declare e uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
begin
  assert (select count(*) from public.tags where office_id = e and kind = 'sistema') = 6, 'seis etiquetas padrão';
  assert (select count(distinct color) from public.tags where office_id = e) = 6, 'cores distintas';
  assert not exists (select 1 from public.tags where office_id = e and lower(name) in ('assinado','documentos pendentes','audiência')), 'etapa não é etiqueta';
  assert (select count(*) from public.departments where office_id = e) = 2, 'Triagem IA e Advogado';
  assert (select ai_default from public.departments where office_id = e and name = 'Triagem IA'), 'Triagem IA é o padrão da IA';
  assert (select count(*) from public.office_hours where office_id = e) = 5, 'expediente seg–sex';
  assert (select count(*) from public.wa_templates where office_id = e and status = 'pendente' and category = 'UTILITY' and params = 2) = 3, 'três templates UTILITY pendentes';
  assert (select sla_espera_min from public.office_params where office_id = e) = 60, 'SLA padrão 60 min';
  perform public.seed_office_defaults(e);
  assert (select count(*) from public.tags where office_id = e) = 6 and (select count(*) from public.wa_templates where office_id = e) = 3, 'seed idempotente';
end $$;

-- =============================================================================
-- Status, janela, departamento padrão e entrada do WhatsApp
-- =============================================================================
do $$
declare r jsonb; c public.conversations; v_conv uuid;
begin
  r := pg_temp.entra('PNID-E1', '5511944441001', 'Maria Souza', 'Oi, fui demitida');
  select * into c from public.conversations where id = (r->>'conversation_id')::uuid;
  assert c.status = 'open' and not c.ai_paused, 'conversa nova com a IA';
  assert c.window_expires_at > now() + interval '23 hours', 'janela de 24h aberta pela mensagem do contato';
  assert c.department_id = (select id from public.departments where office_id = c.office_id and ai_default), 'entra na Triagem IA';
  assert (r->>'ai_should_reply')::boolean, 'IA responde conversa open';
end $$;

-- =============================================================================
-- Etiquetas (RPCs e IA)
-- =============================================================================
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';   -- Ana, admin
do $$
declare e uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; t public.tags; v_lead uuid;
begin
  v_lead := (select lead_id from public.conversations where id = pg_temp.conv('5511944441001'));
  t := public.tag_upsert(e, 'Gestante', '#DB2777', 'Estabilidade');
  assert t.kind = 'livre' and t.active, 'etiqueta livre criada';
  t := public.tag_upsert(e, 'gestante', '#BE185D');
  assert t.color = '#BE185D' and (select count(*) from public.tags where office_id = e and lower(name) = 'gestante') = 1, 'nome único sem caixa';
  begin perform public.tag_upsert(e, 'Ruim', 'vermelho'); assert false, 'cor inválida deveria falhar';
  exception when others then assert sqlerrm like 'cor inválida%', sqlerrm; end;
  assert public.lead_tag_add(v_lead, 'Urgente'), 'etiqueta por nome';
  assert public.lead_tag_add(v_lead, t.id::text), 'etiqueta por id';
  assert not public.lead_tag_add(v_lead, 'urgente'), 'repetir não duplica';
  assert (select count(*) from public.case_events where lead_id = v_lead and type = 'tag_added' and actor = 'humano') = 2, 'tag_added com autor';
  assert public.lead_tag_remove(v_lead, 'Gestante'), 'remove';
  assert exists (select 1 from public.case_events where lead_id = v_lead and type = 'tag_removed'), 'tag_removed';
  perform public.tag_archive(t.id);
  begin perform public.lead_tag_add(v_lead, 'Gestante'); assert false, 'arquivada não aplica';
  exception when others then assert sqlerrm like '%arquivada%', sqlerrm; end;
  assert jsonb_array_length(public.lead_tags_json(v_lead)) = 1, 'etiquetas do lead em json';
end $$;
set request.jwt.claim.sub = '88888888-8888-8888-8888-888888888888';   -- Beto, atendente
do $$
begin
  begin perform public.tag_upsert('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'X', '#000000'); assert false, 'atendente não cria etiqueta';
  exception when others then assert sqlerrm like 'só admin%', sqlerrm; end;
  assert public.lead_tag_add((select lead_id from public.conversations where id = pg_temp.conv('5511944441001')), 'Indicação'), 'atendente aplica etiqueta';
end $$;
set request.jwt.claim.sub = '';                                      -- n8n
do $$
declare v_conv uuid := pg_temp.conv('5511944441001'); v_lead uuid; r jsonb;
begin
  select lead_id into v_lead from public.conversations where id = v_conv;
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, ai_meta)
  values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', v_conv, 'out', 'ia', 'Entendi, Maria.', 'pending', '{"agent_role":"recepcao"}');
  r := public.apply_agent_effects(v_lead, v_conv, 'recepcao', p_tags => '["Estrangeiro", "Inventada"]'::jsonb);
  assert r->'tags' = '["Estrangeiro"]'::jsonb and r->'tags_ignoradas' = '["Inventada"]'::jsonb, 'IA só aplica etiquetas existentes: ' || r::text;
  assert exists (select 1 from public.lead_tags lt join public.tags t on t.id = lt.tag_id where lt.lead_id = v_lead and t.name = 'Estrangeiro' and lt.added_by_actor = 'ia'), 'autor ia';
  assert (select ai_meta->'tags_ignoradas' from public.messages where conversation_id = v_conv and sender = 'ia' order by created_at desc limit 1) = '["Inventada"]'::jsonb, 'desconhecida no ai_meta';
  r := public.apply_agent_effects(v_lead, v_conv, 'recepcao', null, null, null, null, null, null, null);
  assert r->>'agent_role' = 'recepcao' and not r ? 'tags', 'chamada com 10 argumentos continua valendo';
  assert public.agent_tags_context(v_lead)->'do_lead' ? 'Estrangeiro', 'contexto de etiquetas para o agente';
  assert exists (select 1 from public.agent_prompts p join public.agents a on a.id = p.agent_id where a.office_id is null and p.system_prompt like '%- Etiquetas:%'), 'prompts padrão citam etiquetas';
end $$;

-- =============================================================================
-- Atendimento: envio humano, nota, evento, RPCs de conversa, notificações
-- =============================================================================
set request.jwt.claim.sub = '88888888-8888-8888-8888-888888888888';   -- Beto
do $$
declare v_conv uuid := pg_temp.conv('5511944441001'); c public.conversations; m public.messages; n int; v_prev text;
begin
  m := public.conversation_send(v_conv, 'Oi Maria, aqui é o Beto.');
  select * into c from public.conversations where id = v_conv;
  assert c.status = 'in_service' and c.ai_paused and c.assigned_to = '88888888-8888-8888-8888-888888888888', 'enviar = assumir: in_service e atendente';
  assert c.waiting_since is null, 'resposta humana zera a espera';
  v_prev := c.last_message_preview;
  m := public.conversation_note(v_conv, 'Cliente parece ter caso de gestante');
  select * into c from public.conversations where id = v_conv;
  assert m.kind = 'nota' and m.status = 'sent' and c.last_message_preview = v_prev, 'nota não mexe na prévia';
  assert (public.mensageria_envio(m.id))->>'skip' = 'true', 'WA 03 ignora nota';
  assert not exists (select 1 from jsonb_array_elements(public.conversation_context(v_conv, 50)) x
                     where x->>'body' = 'Cliente parece ter caso de gestante'), 'nota interna não entra no contexto da IA';
  -- mark_read: case_event só com não lidas
  n := (select count(*) from public.case_events where conversation_id = v_conv and type = 'conversation_read');
  perform public.conversation_mark_read(v_conv);
  assert (select count(*) from public.case_events where conversation_id = v_conv and type = 'conversation_read') = n, 'sem não lidas, sem evento';
end $$;
set request.jwt.claim.sub = '';
do $$
declare r jsonb; c public.conversations;
begin
  r := pg_temp.entra('PNID-E1', '5511944441001', 'Maria Souza', 'Tá, e agora?');
  select * into c from public.conversations where id = (r->>'conversation_id')::uuid;
  assert c.status = 'in_service' and c.waiting_since is not null and c.unread_count = 1, 'entrada não derruba in_service e marca espera';
  assert not (r->>'ai_should_reply')::boolean, 'IA pausada não responde';
  assert exists (select 1 from public.notifications where user_id = '88888888-8888-8888-8888-888888888888' and tipo = 'mensagem_recebida'), 'atendente notificado';
end $$;
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';   -- Ana
do $$
declare v_conv uuid := pg_temp.conv('5511944441001'); c public.conversations; ev bigint; d_adv uuid; d_ia uuid;
begin
  select id into d_adv from public.departments where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and name = 'Advogado';
  select id into d_ia from public.departments where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and ai_default;
  perform public.conversation_mark_read(v_conv);
  assert exists (select 1 from public.case_events where conversation_id = v_conv and type = 'conversation_read' and actor = 'humano'), 'leitura com não lidas gera case_event';

  ev := pg_temp.eventos(v_conv);
  c := public.conversation_assign(v_conv, '99999999-9999-9999-9999-999999999999');
  assert c.assigned_to = '99999999-9999-9999-9999-999999999999' and c.status = 'in_service', 'atribuída ao Caio';
  assert exists (select 1 from public.notifications where user_id = '99999999-9999-9999-9999-999999999999' and tipo = 'conversa_atribuida'), 'Caio notificado';
  c := public.conversation_transfer_department(v_conv, d_adv);
  assert c.department_id = d_adv and c.status = 'waiting' and c.assigned_to is null and c.ai_paused, 'transferida: aguardando';
  c := public.conversation_transfer_department(v_conv, d_ia);
  assert c.status = 'open' and not c.ai_paused and c.waiting_since is null, 'de volta à Triagem IA: IA atende';
  c := public.conversation_set_ai(v_conv, false);
  assert c.ai_paused and c.status = 'in_service', 'IA desligada';
  c := public.conversation_set_ai(v_conv, true);
  assert not c.ai_paused and c.status = 'open', 'IA religada';
  c := public.conversation_close(v_conv);
  assert c.status = 'closed' and c.closed_by = '77777777-7777-7777-7777-777777777777' and c.closed_at is not null, 'finalizada';
  assert not public.ai_should_reply(v_conv), 'finalizada não responde';
  begin perform public.send_manual_message(v_conv, 'oi'); assert false, 'envio em conversa finalizada';
  exception when others then assert sqlerrm like 'conversa encerrada%', sqlerrm; end;
  c := public.conversation_reopen(v_conv);
  assert c.status = 'open' and c.closed_at is null, 'reaberta';
  c := public.conversation_archive(v_conv);
  assert c.status = 'archived', 'arquivada';
  assert pg_temp.eventos(v_conv) = ev + 8, 'cada RPC grava mensagem de evento: ' || (pg_temp.eventos(v_conv) - ev);
  assert (select count(*) from public.case_events where conversation_id = v_conv and type in
          ('conversation_assigned','conversation_transferred','takeover','ai_released','conversation_closed','conversation_reopened','conversation_archived')) >= 8, 'case_events das RPCs';
  assert (select bool_and(sender = 'sistema' and status = 'sent' and direction = 'out') from public.messages where conversation_id = v_conv and kind = 'evento'), 'evento = sistema, nunca pendente';
  assert jsonb_array_length(public.conversation_context(v_conv, 500)) = (select count(*) from public.messages where conversation_id = v_conv and kind = 'chat')
     and not exists (select 1 from jsonb_array_elements(public.conversation_context(v_conv, 500)) x where x->>'body' like 'Conversa %' or x->>'body' like 'Atendimento finalizado%'),
     'contexto da IA só com chat (sem mensagens de evento)';
end $$;
set request.jwt.claim.sub = '';
do $$
declare r jsonb; c public.conversations;
begin
  r := pg_temp.entra('PNID-E1', '5511944441001', 'Maria Souza', 'Voltei');
  select * into c from public.conversations where id = (r->>'conversation_id')::uuid;
  assert c.status = 'open' and not c.hidden, 'mensagem nova desarquiva';
end $$;

-- =============================================================================
-- Visibilidade: números e departamentos (RLS via can_see_conversation)
-- =============================================================================
do $$ begin perform pg_temp.entra('PNID-E2', '5511944442002', 'João Lima', 'Oi pelo número 2'); end $$;
insert into public.member_number_access (office_id, user_id, whatsapp_number_id)
values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '88888888-8888-8888-8888-888888888888', 'e1000000-0000-0000-0000-000000000002');
insert into public.department_members (department_id, user_id)
select id, '99999999-9999-9999-9999-999999999999' from public.departments where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and name = 'Advogado';
update public.conversations set department_id = (select id from public.departments where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and name = 'Advogado')
 where id = pg_temp.conv('5511944442002');
set role authenticated;
set request.jwt.claim.sub = '88888888-8888-8888-8888-888888888888';   -- Beto só vê o número 2
do $$ begin
  assert (select count(*) from public.conversations where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = 1, 'Beto vê só o número liberado';
  assert (select count(*) from public.messages m join public.conversations c on c.id = m.conversation_id where c.whatsapp_number_id = 'e1000000-0000-0000-0000-000000000001') = 0, 'nem as mensagens';
  assert (select todas from public.conversas_counts('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee')) = 1, 'contadores respeitam acesso';
end $$;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';   -- Caio só vê o departamento Advogado
do $$ begin
  assert (select count(*) from public.v_conversas where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = 1, 'Caio vê só o departamento dele';
  assert (select departamento_nome from public.v_conversas limit 1) = 'Advogado', 'departamento na view';
end $$;
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';   -- Ana (admin) vê tudo
do $$
declare v record; k record;
begin
  assert (select count(*) from public.v_conversas where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = 2, 'admin vê tudo';
  select * into v from public.v_conversas where contact_phone = '5511944441001';
  assert v.status = 'open' and v.status_legado = 'open' and v.com_ia and v.janela_aberta and v.janela_restante_min > 1380, 'colunas de status e janela';
  assert jsonb_array_length(v.etiquetas) = 3 and v.etapa is not null and v.previa = 'Voltei' and v.ultima_mensagem_de = 'contact', 'etiquetas, etapa e prévia';
  select * into k from public.conversas_counts('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
  assert k.todas = 2 and k.com_ia = 2 and k.arquivadas = 0, 'contadores: ' || row_to_json(k)::text;
  assert not has_function_privilege('authenticated', 'public.mensageria_envio(uuid)', 'execute'), 'mensageria_envio só n8n';
  assert not has_function_privilege('authenticated', 'public.scheduled_dispatch(integer)', 'execute'), 'scheduled_dispatch só n8n';
  assert not has_function_privilege('authenticated', 'public.templates_sync_apply(uuid, jsonb)', 'execute'), 'templates_sync_apply só n8n';
  assert not has_function_privilege('authenticated', 'public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb, jsonb)', 'execute'), 'apply_agent_effects só n8n';
  assert not has_function_privilege('authenticated', 'public.notify(uuid, text, jsonb)', 'execute'), 'notify só sistema';
  assert has_function_privilege('authenticated', 'public.conversation_assign(uuid, uuid)', 'execute'), 'RPC de atendimento para o front';
end $$;
reset role;
delete from public.member_number_access where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
delete from public.department_members where user_id = '99999999-9999-9999-9999-999999999999';

-- =============================================================================
-- Respostas rápidas, mídia e janela de 24h no envio
-- =============================================================================
insert into public.quick_replies (office_id, group_name, title, shortcut, kind, body) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'Boas-vindas', 'Saudação', '/oi', 'texto', 'Olá, {{primeiro_nome}}! Sou {{atendente}}, do {{escritorio}}.');
insert into public.quick_replies (office_id, group_name, title, shortcut, kind, media_path, mime_type) values
  ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'Áudios', 'Explicação', '/audio', 'audio', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/explicacao.ogg', 'audio/ogg');
set request.jwt.claim.sub = '88888888-8888-8888-8888-888888888888';
do $$
declare v_conv uuid := pg_temp.conv('5511944441001'); m public.messages; r jsonb;
begin
  m := public.conversation_send(v_conv, null, null, (select id from public.quick_replies where shortcut = '/oi'));
  assert m.body = 'Olá, Maria! Sou Beto E, do Escritório E.', 'placeholders da resposta rápida: ' || m.body;
  m := public.conversation_send(v_conv, null, null, (select id from public.quick_replies where shortcut = '/audio'));
  assert m.media->>'bucket' = 'respostas' and m.media->>'tipo' = 'audio' and m.media->>'filename' = 'explicacao.ogg', 'áudio da resposta rápida';
  begin perform public.conversation_send(v_conv, 'doc', '{"bucket":"provas","storage_path":"outro-escritorio/x.pdf"}'::jsonb); assert false, 'mídia de outro escritório';
  exception when others then assert sqlerrm like 'storage_path precisa%', sqlerrm; end;
  begin perform public.conversation_send(v_conv, 'doc', '{"bucket":"publico","storage_path":"x.pdf"}'::jsonb); assert false, 'bucket fora da lista';
  exception when others then assert sqlerrm like 'bucket de mídia inválido%', sqlerrm; end;
end $$;
set request.jwt.claim.sub = '';
do $$
declare v_conv uuid := pg_temp.conv('5511944441001'); m uuid; r jsonb;
begin
  select id into m from public.messages where conversation_id = v_conv and media->>'tipo' = 'audio' order by created_at desc limit 1;
  r := public.mensageria_envio(m);
  assert (r->>'ok')::boolean and r->>'media_tipo' = 'audio' and r->>'sign_path' = 'respostas/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/explicacao.ogg'
     and r->>'phone_number_id' = 'PNID-E1', 'envio com mídia: ' || r::text;
  -- janela fechada
  update public.conversations set window_expires_at = now() - interval '1 hour' where id = v_conv;
  insert into public.messages (office_id, conversation_id, direction, sender, body, status) values
    ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', v_conv, 'out', 'ia', 'fora da janela', 'pending') returning id into m;
  r := public.mensageria_envio(m);
  assert not (r->>'ok')::boolean and (select status from public.messages where id = m) = 'failed'
     and (select error from public.messages where id = m) = 'Janela de 24h fechada: use um template aprovado', 'janela fechada sem template falha';
  insert into public.messages (office_id, conversation_id, direction, sender, body, template, status) values
    ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', v_conv, 'out', 'sistema', 'retomada', '{"name":"edem_followup","language":"pt_BR","params":["Maria","Escritório E"]}', 'pending') returning id into m;
  assert (public.mensageria_envio(m)->>'ok')::boolean, 'template passa com a janela fechada';
  update public.conversations set window_expires_at = now() + interval '20 hours' where id = v_conv;
end $$;

-- =============================================================================
-- Mensagens agendadas
-- =============================================================================
set request.jwt.claim.sub = '88888888-8888-8888-8888-888888888888';
do $$
declare v_conv uuid := pg_temp.conv('5511944441001'); v_conv2 uuid := pg_temp.conv('5511944442002'); s public.scheduled_messages; s2 public.scheduled_messages; s3 public.scheduled_messages;
begin
  s := public.scheduled_create(v_conv, 'Lembrete: amanhã às 9h', now() + interval '1 hour');
  s2 := public.scheduled_create(v_conv, 'Outro', now() + interval '2 hours');
  s3 := public.scheduled_create(v_conv2, 'Para o João', now() + interval '1 hour');
  s2 := public.scheduled_cancel(s2.id);
  assert s2.status = 'cancelada', 'cancelada';
  assert exists (select 1 from public.case_events where type = 'scheduled_created' and actor = 'humano'), 'scheduled_created';
  begin perform public.scheduled_create(v_conv, 'x', now() - interval '1 day'); assert false, 'data no passado';
  exception when others then assert sqlerrm like 'informe uma data futura%', sqlerrm; end;
  update public.scheduled_messages set send_at = now() - interval '1 minute' where id in (s.id, s3.id);
  update public.conversations set window_expires_at = now() - interval '1 minute' where id = v_conv2;
end $$;
set request.jwt.claim.sub = '';
do $$
declare r jsonb; n_prev int;
begin
  r := public.scheduled_dispatch(50);
  assert (r->>'enviadas')::int = 1 and (r->>'falharam')::int = 1, 'dispatch: ' || r::text;
  assert exists (select 1 from public.scheduled_messages s join public.messages m on m.id = s.sent_message_id
                 where s.status = 'enviada' and m.sender = 'sistema' and m.status = 'pending' and m.body = 'Lembrete: amanhã às 9h'), 'virou mensagem pendente';
  assert (select error from public.scheduled_messages where body = 'Para o João') = 'Janela de 24h fechada: use um template aprovado', 'janela fechada no agendamento';
  assert (public.scheduled_dispatch(50)->>'enviadas')::int = 0, 'não reenvia';
end $$;

-- =============================================================================
-- Templates da Meta
-- =============================================================================
do $$
declare e uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; r jsonb; t public.wa_templates;
begin
  assert exists (select 1 from public.templates_sync_targets() x where x.waba_id = 'WABA-E') = (public.mensageria_provider(e) = 'meta_whatsapp'), 'alvos da sincronização';
  r := public.templates_sync_apply('e1000000-0000-0000-0000-000000000001', '[
    {"name":"edem_followup","language":"pt_BR","status":"APPROVED","category":"UTILITY","id":"111","components":[{"type":"BODY","text":"Olá, {{1}}! Aqui é do {{2}}."}]},
    {"name":"edem_aviso_contrato","language":"pt_BR","status":"REJECTED","category":"UTILITY","id":"112","rejected_reason":"INVALID_FORMAT","components":[]},
    {"name":"criado_na_meta","language":"pt_BR","status":"PENDING","category":"MARKETING","id":"113","components":[{"type":"BODY","text":"Promo {{1}}"}]}
  ]'::jsonb);
  assert (r->>'atualizados')::int = 2 and (r->>'novos')::int = 1, 'sync: ' || r::text;
  select * into t from public.wa_templates where office_id = e and name = 'edem_followup';
  assert t.status = 'aprovado' and t.meta_id = '111' and t.last_sync_at is not null and t.whatsapp_number_id is not null, 'aprovado na sincronização';
  assert (select status = 'rejeitado' and rejected_reason = 'INVALID_FORMAT' and body like 'Olá, {{1}}! O {{2}} enviou%' from public.wa_templates where office_id = e and name = 'edem_aviso_contrato'), 'rejeitado com motivo, corpo mantido';
  assert (select params from public.wa_templates where office_id = e and name = 'criado_na_meta') = 1, 'template criado direto na Meta';
  t := (select x from public.wa_templates x where office_id = e and name = 'edem_lembrete_documentos');
  assert not (public.template_submit_payload(t.id)->>'ok')::boolean, 'sem pedido do admin, não envia';
end $$;
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
do $$ begin perform public.ui_template_submit((select id from public.wa_templates where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and name = 'edem_lembrete_documentos')); end $$;
set request.jwt.claim.sub = '';
do $$
declare v_id uuid := (select id from public.wa_templates where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and name = 'edem_lembrete_documentos'); p jsonb; t public.wa_templates;
begin
  assert v_id in (select public.templates_pending_submit()), 'na fila de envio';
  p := public.template_submit_payload(v_id);
  assert (p->>'ok')::boolean and p->>'waba_id' = 'WABA-E' and p->'payload'->>'category' = 'UTILITY'
     and p->'payload'->'components'->0->'example'->'body_text'->0 = '["Maria", "Escritório E"]'::jsonb, 'payload da Meta: ' || p::text;
  t := public.template_submitted(v_id, '999', 'PENDING');
  assert t.meta_id = '999' and t.submitted_at is not null and v_id not in (select public.templates_pending_submit()), 'enviado';
end $$;

-- =============================================================================
-- Origem do anúncio
-- =============================================================================
do $$
declare r jsonb; l public.leads;
begin
  r := pg_temp.entra('PNID-E1', '5511944443003', 'Ana Anúncio', 'Vi o anúncio');
  l := public.lead_set_referral((r->>'lead_id')::uuid, '{"source_id":"AD-1","source_type":"ad","headline":"Demitido? Fale conosco","ctwa_clid":"clid-1","source_url":"https://fb.me/x"}', (r->>'new_lead')::boolean);
  assert l.source = 'meta_ads' and l.ad_referral->>'ctwa_clid' = 'clid-1', 'referral gravado';
  l := public.lead_set_referral(l.id, '{"source_id":"AD-2"}', false);
  assert l.ad_referral->>'source_id' = 'AD-1', 'vale o primeiro anúncio';
  assert (select leads from public.v_marketing_anuncios where anuncio_id = 'AD-1') = 1, 'v_marketing_anuncios';
  assert (select anuncio_titulo from public.v_conversas where lead_id = l.id) = 'Demitido? Fale conosco', 'anúncio na lista de conversas';
end $$;

-- =============================================================================
-- Mesclar conversas
-- =============================================================================
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
do $$
declare k uuid := pg_temp.conv('5511944441001'); f uuid := pg_temp.conv('5511944443003'); lk uuid; lf uuid; n_msg int; r jsonb;
begin
  select lead_id into lk from public.conversations where id = k;
  select lead_id into lf from public.conversations where id = f;
  insert into public.tasks (office_id, lead_id, title) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', lf, 'Ligar para Ana');
  n_msg := (select count(*) from public.messages where conversation_id = f);
  r := public.conversation_merge(k, f);
  assert (r->>'mensagens')::int = n_msg and (r->>'tarefas')::int = 1, 'mescla: ' || r::text;
  assert (select status from public.conversations where id = f) = 'archived', 'origem arquivada';
  assert exists (select 1 from public.tasks where lead_id = lk and title = 'Ligar para Ana'), 'tarefa movida';
  assert exists (select 1 from public.case_events where lead_id = lf and type = 'conversation_merged_into')
     and exists (select 1 from public.case_events where lead_id = lk and type = 'conversation_merged'), 'eventos dos dois lados';
  insert into public.contracts (office_id, lead_id, status, honorarios_percent) values
    ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', lk, 'assinado', 30), ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', lf, 'assinado', 30);
  begin perform public.conversation_merge(k, pg_temp.conv('5511944442002')); exception when others then null; end;
  begin perform public.conversation_merge(k, f); assert false, 'dois assinados';
  exception when others then assert sqlerrm like 'os dois casos têm contrato assinado%', sqlerrm; end;
end $$;

-- =============================================================================
-- Notificações: preferências e agrupamento
-- =============================================================================
set request.jwt.claim.sub = '';
do $$
declare e uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; u uuid := '99999999-9999-9999-9999-999999999999'; id1 uuid; id2 uuid;
begin
  id1 := public.notify(u, 'pedido_humano', jsonb_build_object('office_id', e, 'titulo', 'Teste'));
  id2 := public.notify(u, 'pedido_humano', jsonb_build_object('office_id', e, 'titulo', 'Teste'));
  assert id1 = id2 and (select qtd from public.notifications where id = id1) = 2, 'agrupa repetições';
  insert into public.notification_prefs (user_id, office_id, eventos) values (u, e, '{"pedido_humano": false}');
  assert public.notify(u, 'pedido_humano', jsonb_build_object('office_id', e, 'titulo', 'Teste')) is null, 'evento desligado não notifica';
  assert public.notify('11111111-1111-1111-1111-111111111111', 'pedido_humano', jsonb_build_object('office_id', e)) is null, 'só membros';
end $$;
set role authenticated;
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';
do $$ begin
  assert (select count(*) from public.notifications) >= 1 and (select count(*) from public.notifications where user_id <> auth.uid()) = 0, 'cada um vê só as suas';
  assert public.notifications_mark_read() >= 1, 'marcar lidas';
end $$;
do $$ begin
  assert (select count(*) from public.notifications where read_at is null) = 0, 'nenhuma não lida';
end $$;
reset role;

-- =============================================================================
-- Métricas só com chat: nota e evento antes da primeira mensagem não mudam nada
-- =============================================================================
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';   -- Ana
do $$
declare e uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; r jsonb; v_conv uuid; v_lead uuid;
        j1 jsonb; j2 jsonb; p1 jsonb; p2 jsonb; h1 bigint; h2 bigint; err text;
begin
  r := public.ingest_inbound('PNID-E1', '5511944444004', 'Paula Métrica', 'wamid.metrica.1', 'Oi', null, now() - interval '30 minutes');
  v_conv := (r->>'conversation_id')::uuid; v_lead := (r->>'lead_id')::uuid;
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, created_at, ai_meta)
  values (e, v_conv, 'out', 'ia', 'Olá, Paula!', 'sent', now() - interval '29 minutes', '{"agent_role":"recepcao"}');
  j1 := public.dashboard_jornada_p(e, null, null);
  p1 := public.dashboard_produtividade_p(e, null, null);
  select mensagens_humano into h1 from public.lead_acquisition_cost where lead_id = v_lead;
  assert (j1->>'primeira_resposta_min') is not null and (j1->>'mensagens_por_lead') is not null, 'jornada calculada: ' || j1::text;

  -- nota e evento duas horas ANTES da primeira mensagem do contato
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, kind, sent_by, created_at)
  values (e, v_conv, 'out', 'humano', 'Nota antiga da equipe', 'sent', 'nota', '77777777-7777-7777-7777-777777777777', now() - interval '2 hours');
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, kind, created_at)
  values (e, v_conv, 'out', 'sistema', 'Conversa atribuída', 'sent', 'evento', now() - interval '2 hours');

  j2 := public.dashboard_jornada_p(e, null, null);
  p2 := public.dashboard_produtividade_p(e, null, null);
  select mensagens_humano into h2 from public.lead_acquisition_cost where lead_id = v_lead;
  assert j2->'primeira_resposta_min' = j1->'primeira_resposta_min', 'nota não altera primeira_resposta_min: ' || (j1->>'primeira_resposta_min') || ' → ' || (j2->>'primeira_resposta_min');
  assert j2->'mensagens_por_lead' = j1->'mensagens_por_lead', 'nota não altera mensagens_por_lead: ' || (j1->>'mensagens_por_lead') || ' → ' || (j2->>'mensagens_por_lead');
  assert (select x->'mensagens' from jsonb_array_elements(p2->'membros') x where x->>'user_id' = '77777777-7777-7777-7777-777777777777')
       = (select x->'mensagens' from jsonb_array_elements(p1->'membros') x where x->>'user_id' = '77777777-7777-7777-7777-777777777777'), 'nota não conta como mensagem do membro';
  assert h2 = h1, 'nota não conta no custo de aquisição';
  assert jsonb_array_length(public.conversation_context(v_conv)) = 2, 'contexto: só a mensagem do contato e a resposta';

  -- a constraint impede nota/evento com remetente errado
  begin
    insert into public.messages (office_id, conversation_id, direction, sender, body, status, kind) values (e, v_conv, 'out', 'ia', 'x', 'sent', 'nota');
    assert false, 'nota da IA deveria falhar';
  exception when check_violation then null; end;
end $$;

-- =============================================================================
-- Monitor "Cliente esperando"
-- =============================================================================
set request.jwt.claim.sub = '';
do $$
declare e uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; v_conv uuid := pg_temp.conv('5511944442002'); r jsonb; h public.human_interventions;
begin
  delete from public.office_hours where office_id = e;
  insert into public.office_hours (office_id, weekday, start_at, end_at) select e, d, '00:00', '23:59:59' from generate_series(0, 6) d;
  assert public.em_expediente(e), 'dentro do expediente';
  update public.conversations set status = 'waiting', ai_paused = true, waiting_since = now() - interval '2 hours' where id = v_conv;
  r := public.run_monitors();
  assert (r->>'cliente_esperando')::int >= 1, 'monitor: ' || r::text;
  select * into h from public.human_interventions where conversation_id = v_conv and category = 'cliente_esperando';
  assert h.priority = 2 and h.reason = 'Cliente esperando' and (select grupo from public.intervention_group(h.category)) = 'seguir_conversa', 'intervenção prioridade 2';
  r := public.run_monitors();
  assert (select count(*) from public.human_interventions where conversation_id = v_conv and category = 'cliente_esperando') = 1, 'uma por conversa';
  delete from public.office_hours where office_id = e;
  insert into public.office_hours (office_id, weekday, start_at, end_at) values (e, (extract(dow from now() at time zone 'America/Sao_Paulo')::int + 1) % 7, '08:00', '09:00');
  assert not public.em_expediente(e), 'fora do expediente';
end $$;

-- take_over (001) sem mensagem: vira em atendimento com o atendente
set request.jwt.claim.sub = '77777777-7777-7777-7777-777777777777';
do $$
declare v_conv uuid := pg_temp.conv('5511944442002'); c public.conversations;
begin
  update public.conversations set status = 'open', ai_paused = false, assigned_to = null where id = v_conv;
  c := public.take_over(v_conv);
  assert c.status = 'in_service' and c.assigned_to = '77777777-7777-7777-7777-777777777777', 'take_over: in_service com atendente';
  c := public.release_to_ai(v_conv);
  assert c.status = 'open', 'release_to_ai: volta para a IA';
end $$;

-- =============================================================================
-- Modelos de petição editáveis
-- =============================================================================
set request.jwt.claim.sub = '99999999-9999-9999-9999-999999999999';   -- Caio, advogado
do $$
declare e uuid := 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'; r jsonb; v_lead uuid; n int;
begin
  n := (select count(*) from public.ui_modelos(e));
  assert n > 0 and (select bool_and(origem = 'padrao') from public.ui_modelos(e)), 'modelos padrão';
  r := public.ui_modelo_salvar(e, 'JUSTICA_GRATUITA', null, null, null, 'Requer justiça gratuita para {{NOME_RECLAMANTE}} {{CAMPO_QUE_NAO_EXISTE}} {{IA:FATOS}}');
  assert r->>'origem' = 'escritorio' and (r->>'versao')::int = 1 and r->'desconhecidos' = '["CAMPO_QUE_NAO_EXISTE"]'::jsonb
     and jsonb_array_length(r->'avisos') = 1, 'sobreposição com aviso: ' || r::text;
  assert (select origem from public.ui_modelos(e) where code = 'JUSTICA_GRATUITA') = 'escritorio', 'sobrepõe o padrão';
  assert (select count(*) from public.ui_modelos(e)) = n, 'não duplica o código';
  v_lead := (select lead_id from public.conversations where id = pg_temp.conv('5511944441001'));
  r := public.ui_modelo_preview(e, 'JUSTICA_GRATUITA', v_lead);
  assert r->>'texto' like '%[PREENCHER: CAMPO_QUE_NAO_EXISTE]%' and r->>'texto' like '%[PREENCHER: FATOS]%' and r->'faltando' ? 'FATOS', 'prévia: ' || (r->>'texto');
  r := public.ui_modelo_salvar(e, 'minha tese', 'Minha tese', 'tese_propria', 'tese', 'Texto da tese própria {{NOME_RECLAMANTE}}');
  assert r->>'code' = 'MINHA_TESE' and (r->>'novo')::boolean, 'tese nova do escritório';
  assert 'MINHA_TESE' = any (public.piece_tese_codes_office(e, array['tese_propria'])), 'tese do briefing aponta para o código novo';
  assert not ('MINHA_TESE' = any (public.piece_tese_codes_office('dddddddd-dddd-dddd-dddd-dddddddddddd', array['tese_propria']))), 'só no escritório dono';
  r := public.ui_modelo_restaurar(e, 'JUSTICA_GRATUITA');
  assert (r->>'alterado')::boolean and (select origem from public.ui_modelos(e) where code = 'JUSTICA_GRATUITA') = 'padrao', 'restaurado';
  assert (select count(*) from public.ui_modelo_versoes(e, 'JUSTICA_GRATUITA')) = 2
     and (select acao from public.ui_modelo_versoes(e, 'JUSTICA_GRATUITA') limit 1) = 'restaurar', 'versões';
  begin perform public.ui_modelo_restaurar(e, 'MINHA_TESE'); assert false, 'tese própria não restaura';
  exception when others then assert sqlerrm like 'modelo próprio%', sqlerrm; end;
  -- desativar um bloco padrão só para o escritório
  r := public.ui_modelo_salvar(e, 'JUSTICA_GRATUITA', null, null, null, (select body from public.piece_templates where office_id is null and code = 'JUSTICA_GRATUITA'), null, null, false);
  assert not (select active from public.ui_modelos(e) where code = 'JUSTICA_GRATUITA'), 'bloco desativado no escritório';
  assert (select count(*) from public.ui_placeholders()) = (select count(*) from public.piece_placeholders), 'catálogo de placeholders';
end $$;
set request.jwt.claim.sub = '88888888-8888-8888-8888-888888888888';   -- atendente não edita
do $$ begin
  begin perform public.ui_modelos('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'); assert false, 'atendente não vê modelos';
  exception when others then assert sqlerrm like 'só admin ou advogado%', sqlerrm; end;
end $$;
set request.jwt.claim.sub = '';
do $$
declare v_lead uuid := (select lead_id from public.conversations where id = pg_temp.conv('5511944441001')); pc uuid; r jsonb;
begin
  insert into public.pieces (office_id, lead_id, tese) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', v_lead, 'tese_propria') returning id into pc;
  r := public.piece_render(pc);
  assert r->'teses' ? 'MINHA_TESE' and r->>'texto' like '%Texto da tese própria%', 'tese própria entra na peça';
  assert not (r->'blocos' ? 'JUSTICA_GRATUITA'), 'bloco desativado fica fora';
end $$;

rollback;
\echo MENSAGERIA OK
