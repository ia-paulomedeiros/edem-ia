-- =============================================================================
-- 015_paridade_automacoes.sql — automações que a Láquila faz sozinha (P2)
--
-- 8.  Documentos do WhatsApp entram no caso: ingest_media (service_role) cria a
--     prova (evidences) com o tipo classificado pelo modelo e o evento
--     document_received com o agente do lead. O n8n 02 baixa, classifica e
--     sobe no bucket 'provas'; não faz insert direto.
-- 9.  Agendamento que a IA retoma: tasks.kind (agendamento|tarefa) e
--     tasks.status (agendado|confirmado|realizado|cancelado|remarcado).
--     agendamentos_escalar / agendamentos_due / agendamento_mark_done (n8n 09)
--     e RPCs de front para confirmar, remarcar e cancelar.
-- 10. Monitores da fila: run_monitors() (n8n 10, a cada 10 min) abre, no
--     máximo uma por lead e categoria: caso_parado, ia_sem_resposta,
--     contrato_nao_assinado_24h e cliente_ja_existente (também na ingestão).
-- 11. Calculista: qualification_records versionado; prescrição calculada em
--     SQL (prescricao_info) e injetada; save_qualification_record atualiza
--     lead_qualification, avança calculo → provas e grava qualificacao_gerada.
-- 12. Geração da peça: ui_finish_collection (ou o Coletor) pede a peça;
--     piece_generation_claim / piece_generation_save (n8n 08) montam blocos +
--     teses com briefing, qualificação e provas e põem em revisão.
--
-- Mesma regra da 014: nada de colunas novas em views de migrations anteriores
-- (a reaplicação quebraria). v_tasks só muda a expressão de situacao; o resto
-- da agenda sai em v_agenda.
--
-- Idempotente. Rodar depois de 014.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 8. Documentos recebidos pelo WhatsApp
-- -----------------------------------------------------------------------------
alter table public.evidences
  add column if not exists doc_tipo text,
  add column if not exists mime_type text,
  add column if not exists size_bytes bigint,
  add column if not exists origem text not null default 'equipe',
  add column if not exists agent_role text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'evidences_origem_check') then
    alter table public.evidences add constraint evidences_origem_check check (origem in ('whatsapp','equipe','ia'));
  end if;
end $$;

create or replace function public.doc_tipos()
returns table (ordem int, codigo text, titulo text)
language sql immutable set search_path = public as $$
  values
    ( 1, 'rg',              'RG'),
    ( 2, 'cnh',             'CNH'),
    ( 3, 'cpf',             'CPF'),
    ( 4, 'ctps',            'CTPS'),
    ( 5, 'holerite',        'Holerite'),
    ( 6, 'comprovante_pix', 'Comprovante PIX'),
    ( 7, 'extrato_fgts',    'Extrato do FGTS'),
    ( 8, 'trct',            'TRCT'),
    ( 9, 'atestado',        'Atestado'),
    (10, 'laudo',           'Laudo'),
    (11, 'print_conversa',  'Print de conversa'),
    (12, 'foto',            'Foto'),
    (13, 'outro',           'Outro documento');
$$;

create or replace function public.doc_tipo_titulo(p_codigo text)
returns text language sql immutable set search_path = public as $$
  select coalesce((select d.titulo from public.doc_tipos() d where d.codigo = p_codigo), 'Outro documento');
$$;

-- Chamada pelo n8n 02 depois de subir o arquivo em provas/<office>/<lead>/<message_id>.<ext>.
-- Idempotente por mensagem. Se havia uma prova "solicitada" do mesmo tipo, ela é atendida.
create or replace function public.ingest_media(p_message_id uuid, p_storage_path text, p_mime text,
                                               p_size bigint default null, p_doc_tipo text default 'outro',
                                               p_filename text default null, p_caption text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m public.messages; c public.conversations; l public.leads;
  v_tipo text; v_kind text; v_title text; v_role text; v_ev uuid; v_pedido boolean := false; v_saneamento boolean;
begin
  select * into m from public.messages where id = p_message_id;
  if m.id is null then raise exception 'mensagem % não existe', p_message_id; end if;
  if m.direction <> 'in' then raise exception 'só mensagens recebidas viram prova'; end if;
  select * into c from public.conversations where id = m.conversation_id;
  select * into l from public.leads where id = c.lead_id;
  if coalesce(p_storage_path, '') = '' or split_part(p_storage_path, '/', 1) <> l.office_id::text then
    raise exception 'storage_path precisa começar pelo escritório: %/…', l.office_id;
  end if;

  select id into v_ev from public.evidences where message_id = p_message_id limit 1;
  if v_ev is not null then
    return jsonb_build_object('duplicate', true, 'evidence_id', v_ev);
  end if;

  v_tipo := case when exists (select 1 from public.doc_tipos() d where d.codigo = p_doc_tipo) then p_doc_tipo else 'outro' end;
  v_kind := case
    when p_mime like 'image/%' then 'foto'
    when p_mime like 'video/%' then 'video'
    when p_mime like 'audio/%' then 'audio'
    when p_mime like 'application/%' or p_mime like 'text/%' then 'documento'
    else 'outro' end;
  v_title := public.doc_tipo_titulo(v_tipo);
  v_role := public.agent_for_lead(l.id);
  v_saneamento := exists (select 1 from public.pieces p where p.lead_id = l.id and p.status = 'saneamento');

  select id into v_ev from public.evidences
   where lead_id = l.id and status = 'solicitada' and v_tipo <> 'outro'
     and (doc_tipo = v_tipo or (doc_tipo is null and lower(title) = lower(v_title)))
   order by created_at limit 1;
  if v_ev is not null then
    v_pedido := true;
    update public.evidences set status = 'recebida', storage_path = p_storage_path, message_id = p_message_id, doc_tipo = v_tipo,
           mime_type = p_mime, size_bytes = p_size, origem = 'whatsapp', agent_role = v_role,
           description = coalesce(description, nullif(btrim(coalesce(p_caption, p_filename, '')), ''))
     where id = v_ev;
  else
    insert into public.evidences (office_id, lead_id, kind, title, description, storage_path, message_id, status, requested_by_actor,
                                  doc_tipo, mime_type, size_bytes, origem, agent_role)
    values (l.office_id, l.id, v_kind, v_title, nullif(btrim(coalesce(p_caption, p_filename, '')), ''), p_storage_path, p_message_id,
            'recebida', 'ia', v_tipo, p_mime, p_size, 'whatsapp', v_role)
    returning id into v_ev;
  end if;

  update public.messages set media = coalesce(media, '{}'::jsonb)
         || jsonb_build_object('storage_path', p_storage_path, 'evidence_id', v_ev, 'doc_tipo', v_tipo)
   where id = p_message_id;

  perform public.log_event(l.office_id, l.id, 'document_received', 'ia', null, v_role,
    jsonb_build_object('evidence_id', v_ev, 'doc_tipo', v_tipo, 'titulo', v_title, 'storage_path', p_storage_path,
                       'mime_type', p_mime, 'size_bytes', p_size, 'atendeu_pedido', v_pedido, 'durante_saneamento', v_saneamento),
    c.id);
  return jsonb_build_object('duplicate', false, 'evidence_id', v_ev, 'doc_tipo', v_tipo, 'titulo', v_title, 'kind', v_kind,
                            'atendeu_pedido', v_pedido, 'durante_saneamento', v_saneamento);
end; $$;

-- -----------------------------------------------------------------------------
-- 9. Agendamentos com status e retomada pela IA
-- -----------------------------------------------------------------------------
alter table public.tasks
  add column if not exists kind text not null default 'tarefa',
  add column if not exists status text,
  add column if not exists status_changed_at timestamptz,
  add column if not exists escalada_em timestamptz,
  add column if not exists agent_role text;

update public.tasks set status = case when done_at is not null then 'realizado' else 'agendado' end where status is null;
alter table public.tasks alter column status set default 'agendado';
alter table public.tasks alter column status set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'tasks_kind_check') then
    alter table public.tasks add constraint tasks_kind_check check (kind in ('agendamento','tarefa'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'tasks_status_check') then
    alter table public.tasks add constraint tasks_status_check check (status in ('agendado','confirmado','realizado','cancelado','remarcado'));
  end if;
end $$;

-- done_at e status andam juntos (a UI antiga ainda marca done_at).
create or replace function public.tasks_status_sync()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.status is null then
    new.status := case when new.done_at is not null then 'realizado' else 'agendado' end;
  end if;
  if tg_op = 'UPDATE' then
    if new.done_at is not null and old.done_at is null and new.status = old.status and new.status not in ('realizado','cancelado') then
      new.status := 'realizado';
    end if;
    if new.status is distinct from old.status then
      new.status_changed_at := now();
    end if;
  end if;
  if new.status = 'realizado' and new.done_at is null then new.done_at := now(); end if;
  return new;
end; $$;
drop trigger if exists tasks_status_sync on public.tasks;
create trigger tasks_status_sync before insert or update on public.tasks for each row execute function public.tasks_status_sync();

create or replace function public.task_status_titulo(p_status text)
returns text language sql immutable set search_path = public as $$
  select case p_status when 'agendado' then 'Agendado' when 'confirmado' then 'Confirmado' when 'realizado' then 'Realizado'
                       when 'cancelado' then 'Cancelado' when 'remarcado' then 'Remarcado' else p_status end;
$$;

-- v_tasks (010): mesmas colunas; situacao passa a vir de status.
create or replace view public.v_tasks with (security_invoker = true) as
select t.id, t.office_id, t.lead_id, t.title, t.description, t.due_at, t.done_at, t.assigned_to, t.created_by, t.created_by_actor, t.created_at,
  ct.name as contact_name, ct.wa_id as contact_phone, l.phase, pr.full_name as assigned_name,
  case
    when t.status = 'realizado' or t.done_at is not null then 'realizado'
    when t.status = 'cancelado' then 'cancelado'
    when t.due_at is not null and t.due_at < now() then 'atrasado'
    when t.kind = 'agendamento' then t.status
    else 'pendente' end as situacao,
  (t.due_at at time zone 'America/Sao_Paulo')::date as dia
from public.tasks t
left join public.leads l on l.id = t.lead_id
left join public.contacts ct on ct.id = l.contact_id
left join public.profiles pr on pr.user_id = t.assigned_to;

create or replace view public.v_agenda with (security_invoker = true) as
select v.*, t.kind, t.status, public.task_status_titulo(t.status) as status_titulo, t.status_changed_at, t.escalada_em,
  t.agent_role, public.agent_label(a.name, a.persona_nome) as agente_rotulo
from public.v_tasks v
join public.tasks t on t.id = v.id
left join lateral (select * from public.agent_config_role(t.office_id, t.agent_role)) a on t.agent_role is not null;

-- Agendamentos vencidos com a conversa assumida (ou sem conversa) viram tarefa
-- da equipe; a IA não retoma por cima de um humano.
create or replace function public.agendamentos_escalar(p_limit int default 100)
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in
    select t.id, t.lead_id, t.title, t.description, t.due_at, c.id as conv
    from public.tasks t
    join public.leads l on l.id = t.lead_id
    left join lateral (select cv.id from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) c on true
    where t.kind = 'agendamento' and t.status in ('agendado','confirmado','remarcado') and t.due_at <= now() and t.escalada_em is null
      and not l.paused and l.phase <> 'encerrado'
      and (c.id is null or not public.ai_should_reply(c.id))
    order by t.due_at limit p_limit
  loop
    perform public.request_intervention(r.lead_id, r.conv, 'agendamento', 'Agendamento: ' || r.title, 2, 'sistema', null,
      'Retomada combinada para ' || to_char(r.due_at at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || coalesce(' — ' || r.description, '')
      || '. A conversa está com a equipe, então a IA não retomou.', array['agendamento']);
    update public.tasks set escalada_em = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end; $$;

-- Agendamentos que a IA retoma agora: vencidos, conversa não assumida, lead
-- não pausado nem encerrado.
create or replace function public.agendamentos_due(p_limit int default 50)
returns table (task_id uuid, office_id uuid, lead_id uuid, conversation_id uuid, title text, description text, due_at timestamptz)
language sql stable security definer set search_path = public as $$
  select t.id, t.office_id, t.lead_id, c.id, t.title, t.description, t.due_at
  from public.tasks t
  join public.leads l on l.id = t.lead_id
  join lateral (select cv.id from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) c on true
  where t.kind = 'agendamento' and t.status in ('agendado','confirmado','remarcado') and t.due_at <= now() and t.escalada_em is null
    and not l.paused and l.phase <> 'encerrado'
    and public.ai_should_reply(c.id)
  order by t.due_at
  limit p_limit;
$$;

create or replace function public.agendamento_mark_done(p_task uuid, p_status text default 'realizado', p_message_id uuid default null)
returns public.tasks language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  if p_status not in ('realizado','cancelado') then raise exception 'status final: realizado ou cancelado'; end if;
  update public.tasks set status = p_status where id = p_task returning * into t;
  if t.id is null then raise exception 'tarefa % não existe', p_task; end if;
  perform public.log_event(t.office_id, t.lead_id, 'agendamento_retomado', 'ia', null, public.agent_for_lead(t.lead_id),
    jsonb_build_object('task_id', t.id, 'status', p_status, 'message_id', p_message_id, 'description', t.description));
  return t;
end; $$;

create or replace function public.ui_set_agendamento(p_task uuid, p_status text, p_due_at timestamptz default null)
returns public.tasks language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  if auth.uid() is null then raise exception 'exige usuário'; end if;
  select * into t from public.tasks where id = p_task;
  if t.id is null or not public.is_office_member(t.office_id) then raise exception 'agendamento não encontrado'; end if;
  if p_status = 'remarcado' and p_due_at is null then raise exception 'informe a nova data e hora'; end if;
  update public.tasks
     set status = p_status,
         due_at = coalesce(p_due_at, due_at),
         escalada_em = case when p_status in ('remarcado','confirmado') then null else escalada_em end,
         done_at = case when p_status in ('agendado','confirmado','remarcado') then null else done_at end
   where id = p_task returning * into t;
  if t.lead_id is not null then
    perform public.log_event(t.office_id, t.lead_id, 'agendamento_status', 'humano', auth.uid(), null,
      jsonb_build_object('task_id', t.id, 'status', p_status, 'status_titulo', public.task_status_titulo(p_status), 'due_at', t.due_at));
  end if;
  return t;
end; $$;

create or replace function public.ui_confirm_agendamento(p_task uuid)
returns public.tasks language sql security definer set search_path = public as $$
  select public.ui_set_agendamento(p_task, 'confirmado');
$$;
create or replace function public.ui_reschedule_agendamento(p_task uuid, p_due_at timestamptz)
returns public.tasks language sql security definer set search_path = public as $$
  select public.ui_set_agendamento(p_task, 'remarcado', p_due_at);
$$;
create or replace function public.ui_cancel_agendamento(p_task uuid)
returns public.tasks language sql security definer set search_path = public as $$
  select public.ui_set_agendamento(p_task, 'cancelado');
$$;

-- -----------------------------------------------------------------------------
-- 10. Monitores da fila
-- -----------------------------------------------------------------------------
create or replace function public.run_monitors()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; h public.human_interventions; v_t0 timestamptz := now();
  n_parado int := 0; n_ia int := 0; n_ctr int := 0; n_cli int := 0;
begin
  -- Caso parado >48h: fase de atendimento, conversa com a IA, sem régua em curso
  for r in
    select l.id as lead_id, c.id as conv, l.phase
    from public.leads l
    join lateral (select cv.* from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) c on true
    where l.phase not in ('encerrado','peca') and not l.paused and c.status = 'open' and not c.ai_paused
      and coalesce(c.last_message_at, l.created_at) < now() - interval '48 hours'
      and l.followup_next_at is null
      and not exists (select 1 from public.human_interventions x where x.lead_id = l.id and x.category = 'caso_parado' and x.status in ('pendente','em_atendimento'))
  loop
    h := public.request_intervention(r.lead_id, r.conv, 'caso_parado', 'Caso parado >48h', 2, 'sistema', null,
           'Nenhuma mensagem há mais de 48 horas (' || public.phase_label(r.phase) || ').', array['monitor']);
    if h.id is not null then n_parado := n_parado + 1; end if;
  end loop;

  -- IA não respondeu há 30+ min: última mensagem é do lead e a IA deveria responder
  for r in
    select c.id as conv, c.lead_id
    from public.conversations c
    join public.leads l on l.id = c.lead_id
    join lateral (select m.direction, m.created_at from public.messages m where m.conversation_id = c.id order by m.created_at desc limit 1) lm on true
    where c.status = 'open' and l.phase <> 'encerrado' and lm.direction = 'in' and lm.created_at < now() - interval '30 minutes'
      and public.ai_should_reply(c.id)
      and not exists (select 1 from public.human_interventions x where x.lead_id = c.lead_id and x.category = 'ia_sem_resposta' and x.status in ('pendente','em_atendimento'))
  loop
    h := public.request_intervention(r.lead_id, r.conv, 'ia_sem_resposta', 'IA não respondeu há 30+ min', 1, 'sistema', null,
           'A última mensagem é do lead e não houve resposta automática. Verifique o n8n e responda.', array['monitor']);
    if h.id is not null then n_ia := n_ia + 1; end if;
  end loop;

  -- Contrato pendente >24h
  for r in
    select k.lead_id, k.id as contract_id,
           (select cv.id from public.conversations cv where cv.lead_id = k.lead_id order by cv.last_message_at desc nulls last limit 1) as conv
    from public.contracts k
    join public.leads l on l.id = k.lead_id
    where k.status = 'enviado' and coalesce(k.sent_at, k.send_requested_at, k.created_at) < now() - interval '24 hours'
      and l.phase <> 'encerrado'
      and not exists (select 1 from public.human_interventions x where x.lead_id = k.lead_id and x.category = 'contrato_nao_assinado_24h' and x.status in ('pendente','em_atendimento'))
  loop
    h := public.request_intervention(r.lead_id, r.conv, 'contrato_nao_assinado_24h', 'Contrato pendente >24h', 2, 'sistema', null,
           'Contrato enviado há mais de 24 horas e ainda não assinado.', array['monitor','contrato']);
    if h.id is not null then n_ctr := n_ctr + 1; end if;
  end loop;

  -- Cliente já existente (CPF de quem já tem caso assinado em outro lead)
  for r in
    select l.id as lead_id,
           (select cv.id from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) as conv,
           o.lead_id as outro
    from public.leads l
    join public.contacts ct on ct.id = l.contact_id
    join lateral (select l2.id as lead_id from public.leads l2 join public.contacts c2 on c2.id = l2.contact_id
                  join public.contracts k2 on k2.lead_id = l2.id and k2.status = 'assinado'
                  where l2.office_id = l.office_id and l2.id <> l.id and c2.cpf = ct.cpf limit 1) o on true
    where l.closed_at is null and ct.cpf is not null
      and not exists (select 1 from public.contracts k where k.lead_id = l.id and k.status = 'assinado')
      and not exists (select 1 from public.human_interventions x where x.lead_id = l.id and x.category = 'cliente_ja_existente' and x.status in ('pendente','em_atendimento'))
  loop
    h := public.request_intervention(r.lead_id, r.conv, 'cliente_ja_existente', 'Cliente já existente', 2, 'sistema', null,
           'O CPF deste lead já tem caso assinado em outro atendimento.', array['monitor', 'lead:' || r.outro]);
    if h.id is not null then n_cli := n_cli + 1; end if;
  end loop;

  return jsonb_build_object('caso_parado', n_parado, 'ia_sem_resposta', n_ia, 'contrato_nao_assinado_24h', n_ctr,
                            'cliente_ja_existente', n_cli, 'rodou_em', v_t0);
end; $$;

-- ingest_inbound (001) + alerta de cliente já existente quando um telefone com
-- caso assinado abre um lead novo. Mesma assinatura.
create or replace function public.ingest_inbound(p_phone_number_id text, p_wa_id text, p_name text, p_wa_message_id text, p_body text,
                                                 p_media jsonb default null, p_ts timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_num   public.whatsapp_numbers;
  v_contact_id uuid;
  v_lead_id uuid;
  v_conv_id uuid;
  v_msg_id uuid;
  v_new_lead boolean := false;
  v_outro uuid;
begin
  select * into v_num from public.whatsapp_numbers where phone_number_id = p_phone_number_id and active;
  if v_num.id is null then
    raise exception 'phone_number_id % não cadastrado/ativo', p_phone_number_id;
  end if;

  if p_wa_message_id is not null and exists (select 1 from public.messages where wa_message_id = p_wa_message_id) then
    select m.id, m.conversation_id, c.lead_id into v_msg_id, v_conv_id, v_lead_id
      from public.messages m join public.conversations c on c.id = m.conversation_id
     where m.wa_message_id = p_wa_message_id;
    return jsonb_build_object('duplicate', true, 'office_id', v_num.office_id, 'lead_id', v_lead_id,
                              'conversation_id', v_conv_id, 'message_id', v_msg_id, 'ai_should_reply', false);
  end if;

  insert into public.contacts (office_id, wa_id, name)
  values (v_num.office_id, p_wa_id, nullif(p_name, ''))
  on conflict (office_id, wa_id) do update
    set name = coalesce(public.contacts.name, excluded.name)
  returning id into v_contact_id;

  select id into v_lead_id from public.leads where contact_id = v_contact_id and closed_at is null;
  if v_lead_id is null then
    insert into public.leads (office_id, contact_id, source) values (v_num.office_id, v_contact_id, 'whatsapp')
    returning id into v_lead_id;
    v_new_lead := true;
    perform public.log_event(v_num.office_id, v_lead_id, 'lead_created', 'sistema', null, null,
                             jsonb_build_object('source', 'whatsapp', 'wa_id', p_wa_id));
  end if;

  insert into public.conversations (office_id, lead_id, contact_id, whatsapp_number_id)
  values (v_num.office_id, v_lead_id, v_contact_id, v_num.id)
  on conflict (lead_id, whatsapp_number_id) do update set status = 'open'
  returning id into v_conv_id;

  insert into public.messages (office_id, conversation_id, direction, sender, body, media, wa_message_id, status, created_at)
  values (v_num.office_id, v_conv_id, 'in', 'contact', p_body, p_media, p_wa_message_id, 'received', coalesce(p_ts, now()))
  returning id into v_msg_id;

  if v_new_lead then
    select l2.id into v_outro from public.leads l2 join public.contracts k on k.lead_id = l2.id and k.status = 'assinado'
     where l2.contact_id = v_contact_id and l2.id <> v_lead_id limit 1;
    if v_outro is not null then
      perform public.request_intervention(v_lead_id, v_conv_id, 'cliente_ja_existente', 'Cliente já existente', 2, 'sistema', null,
        'Este telefone já tem caso assinado em outro atendimento. Confira se é andamento de processo (jurídico) ou um caso novo.',
        array['monitor', 'lead:' || v_outro]);
    end if;
  end if;

  return jsonb_build_object(
    'duplicate', false,
    'new_lead', v_new_lead,
    'office_id', v_num.office_id,
    'contact_id', v_contact_id,
    'lead_id', v_lead_id,
    'conversation_id', v_conv_id,
    'message_id', v_msg_id,
    'ai_should_reply', public.ai_should_reply(v_conv_id)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. Calculista: qualificação detalhada e versionada
-- -----------------------------------------------------------------------------
create table if not exists public.qualification_records (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.leads(id) on delete cascade,
  office_id   uuid not null references public.offices(id) on delete cascade,
  versao      int not null,
  data        jsonb not null default '{}'::jsonb,
  agent_role  text not null default 'calculo',
  ai_meta     jsonb,
  created_at  timestamptz not null default now(),
  unique (lead_id, versao)
);
create index if not exists qualification_records_lead_idx on public.qualification_records (lead_id, versao desc);
alter table public.qualification_records enable row level security;
drop policy if exists qualification_records_select on public.qualification_records;
create policy qualification_records_select on public.qualification_records for select to authenticated
  using (public.is_office_member(office_id));
-- sem insert/update/delete para o front: só save_qualification_record (n8n)
select public.add_to_realtime('qualification_records');
grant select on public.qualification_records to authenticated;

-- Prescrição calculada pelo banco (nunca pelo LLM).
create or replace function public.prescricao_info(p_lead uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  d public.case_data; p public.office_params; l public.leads;
  v_prazo date; v_dias int; v_status text; v_ajuiz date; v_quinq date; v_inicio date; v_exc text[] := '{}';
begin
  select * into l from public.leads where id = p_lead;
  select * into d from public.case_data where lead_id = p_lead;
  select * into p from public.office_params where office_id = l.office_id;
  if d.demissao is null then
    v_status := 'nao_iniciado';
    v_exc := array_append(v_exc, 'Contrato em curso ou sem data de saída: o prazo de 2 anos ainda não começou.'::text);
  else
    v_prazo := (d.demissao + interval '2 years')::date;
    v_dias := v_prazo - current_date;
    v_status := case when v_dias < 0 then 'vencido' when v_dias <= coalesce(p.alerta_prescricao_dias, 90) then 'alerta' else 'ok' end;
  end if;
  v_ajuiz := case when v_prazo is null then current_date + 15 else least(current_date + 15, greatest(v_prazo, current_date)) end;
  v_quinq := (v_ajuiz - interval '5 years')::date;
  v_inicio := greatest(coalesce(d.admissao, v_quinq), v_quinq);
  if coalesce(d.acidente_trabalho, false) then
    v_exc := array_append(v_exc, 'Acidente de trabalho: conferir estabilidade (art. 118 da Lei 8.213/91) e eventuais prazos próprios.'::text);
  end if;
  if d.fgts_depositado = false then
    v_exc := array_append(v_exc, 'FGTS não depositado: cobrança limitada aos últimos 5 anos (STF, ARE 709.212).'::text);
  end if;
  if d.tipo_rescisao = 'rescisao_indireta' then
    v_exc := array_append(v_exc, 'Rescisão indireta: a data de saída depende do reconhecimento em juízo.'::text);
  end if;
  return jsonb_build_object(
    'data_saida', d.demissao,
    'prazo_bienal', v_prazo,
    'status_bienal', v_status,
    'dias_restantes', v_dias,
    'data_provavel_ajuizamento', v_ajuiz,
    'limite_quinquenal', v_quinq,
    'inicio_periodo_nao_prescrito', v_inicio,
    'meses_nao_prescritos', public.vinculo_meses(v_inicio, coalesce(d.demissao, current_date)),
    'excecoes', to_jsonb(v_exc));
end; $$;

-- Leads com a entrevista concluída esperando o Calculista (n8n 11).
create or replace function public.calculista_queue(p_limit int default 10)
returns table (lead_id uuid, office_id uuid, nome text, briefing jsonb, case_data jsonb, prescricao jsonb, estimativa jsonb,
               params jsonb, versao_atual int, model text)
language sql stable security definer set search_path = public as $$
  select l.id, l.office_id, ct.name, to_jsonb(b), to_jsonb(d), public.prescricao_info(l.id), public.calc_verbas(l.id),
         jsonb_build_object('ticket_minimo', p.ticket_minimo, 'faixas_ticket', p.faixas_ticket, 'honorarios_percent', p.honorarios_percent,
                            'cambio_usd_brl', p.cambio_usd_brl),
         (select max(r.versao) from public.qualification_records r where r.lead_id = l.id),
         (select a.model from public.agent_config_role(l.office_id, 'calculo') a)
  from public.leads l
  join public.briefings b on b.lead_id = l.id and b.status = 'concluido'
  join public.contacts ct on ct.id = l.contact_id
  left join public.case_data d on d.lead_id = l.id
  left join public.office_params p on p.office_id = l.office_id
  where l.phase = 'calculo'
    and not exists (select 1 from public.qualification_records r where r.lead_id = l.id and r.created_at >= coalesce(b.completed_at, b.updated_at))
    and not exists (select 1 from public.case_events e where e.lead_id = l.id and e.type = 'calculista_falhou' and e.created_at > now() - interval '1 hour')
  order by coalesce(b.completed_at, b.updated_at)
  limit p_limit;
$$;

create or replace function public.faixa_label(p_faixa text, p_passou_minimo boolean default true)
returns text language sql immutable set search_path = public as $$
  select case when not coalesce(p_passou_minimo, true) then 'INVIAVEL'
    else case p_faixa when 'baixo' then 'LOW_TICKET' when 'medio' then 'MID_TICKET' when 'alto' then 'HIGH_TICKET' else upper(coalesce(p_faixa, 'indefinida')) end end;
$$;

-- Número vindo do LLM: aceita 1234.56, "1234,56", "R$ 1.234,56"; lixo vira null.
create or replace function public.to_num(p text)
returns numeric language plpgsql immutable set search_path = public as $$
declare s text := regexp_replace(coalesce(p, ''), '[^0-9,.\-]', '', 'g');
begin
  if s = '' then return null; end if;
  if s ~ ',\d{1,2}$' then s := replace(replace(s, '.', ''), ',', '.');   -- 1.234,56
  else s := replace(s, ',', ''); end if;                                -- 1,234.56 ou 1234.56
  return s::numeric;
exception when others then return null;
end; $$;

-- Grava a versão nova do cálculo. data: {dados_base, verbas[], ...}; a
-- prescrição do banco substitui qualquer prescrição que venha no JSON.
create or replace function public.save_qualification_record(p_lead uuid, p_data jsonb, p_agent_role text default 'calculo', p_ai_meta jsonb default null)
returns public.qualification_records language plpgsql security definer set search_path = public as $$
declare
  l public.leads; p public.office_params; r public.qualification_records;
  v_versao int; v_total numeric; v_faixa text; v_motivos text[] := '{}'; v_presc jsonb; v_data jsonb; v_label text; v_passed boolean;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'data precisa ser um objeto JSON'; end if;
  if jsonb_typeof(coalesce(p_data->'verbas', 'null'::jsonb)) <> 'array' then raise exception 'data.verbas precisa ser uma lista'; end if;
  select * into p from public.office_params where office_id = l.office_id;

  v_presc := public.prescricao_info(p_lead);
  select coalesce(sum(coalesce(public.to_num(v->>'total'),
                               coalesce(public.to_num(v->>'valor_calculado'), 0) - coalesce(public.to_num(v->>'ja_recebido'), 0))), 0)
    into v_total from jsonb_array_elements(p_data->'verbas') v;
  v_faixa := public.faixa_ticket(l.office_id, v_total);
  if v_total < p.ticket_minimo then v_motivos := v_motivos || format('ticket_baixo:%s<%s', v_total, p.ticket_minimo); end if;
  if v_presc->>'status_bienal' = 'vencido' then v_motivos := v_motivos || format('prescrito_em:%s', v_presc->>'prazo_bienal'); end if;
  v_passed := cardinality(v_motivos) = 0;
  v_label := public.faixa_label(v_faixa, v_total >= p.ticket_minimo);

  select coalesce(max(versao), 0) + 1 into v_versao from public.qualification_records where lead_id = p_lead;
  v_data := (p_data - 'prescricao') || jsonb_build_object('prescricao', v_presc, 'total', v_total, 'faixa', v_faixa, 'faixa_label', v_label,
                                                          'passed', v_passed, 'motivos', to_jsonb(v_motivos));
  insert into public.qualification_records (lead_id, office_id, versao, data, agent_role, ai_meta)
  values (p_lead, l.office_id, v_versao, v_data, coalesce(p_agent_role, 'calculo'), p_ai_meta)
  returning * into r;

  insert into public.lead_qualification (lead_id, office_id, passed, faixa, verbas, verbas_total, vinculo_meses, motivos, evaluated_by_actor, evaluated_at)
  values (p_lead, l.office_id, v_passed, v_faixa, p_data->'verbas', v_total,
          round(public.to_num(p_data->'dados_base'->>'meses_contrato'))::int, v_motivos, 'ia', now())
  on conflict (lead_id) do update
    set passed = excluded.passed, faixa = excluded.faixa, verbas = excluded.verbas, verbas_total = excluded.verbas_total,
        vinculo_meses = coalesce(excluded.vinculo_meses, public.lead_qualification.vinculo_meses), motivos = excluded.motivos,
        evaluated_by_actor = 'ia', evaluated_at = now();

  perform public.log_event(l.office_id, p_lead, 'qualificacao_gerada', 'ia', null, coalesce(p_agent_role, 'calculo'),
    jsonb_build_object('record_id', r.id, 'versao', v_versao, 'total', v_total, 'faixa', v_faixa, 'faixa_label', v_label, 'passed', v_passed,
                       'motivos', to_jsonb(v_motivos), 'texto', 'Qualificação (cálculo) gerada — ' || v_label || ' ' || public.brl(v_total)));

  if l.phase = 'calculo' then
    if v_passed then
      perform public.advance_phase(p_lead, 'provas', 'ia', null, coalesce(p_agent_role, 'calculo'), 'qualificação gerada — ' || v_label);
    else
      -- inviável ou prescrito: a equipe decide (encerrar como Inviável ou seguir)
      perform public.request_intervention(p_lead,
        (select id from public.conversations where lead_id = p_lead order by last_message_at desc nulls last limit 1),
        'saneamento_juridico', 'Cálculo pede revisão: ' || array_to_string(v_motivos, ', '), 2, 'ia', coalesce(p_agent_role, 'calculo'),
        'Qualificação v' || v_versao || ' — ' || v_label || ' ' || public.brl(v_total) || '. Avalie encerrar como Inviável ou seguir.',
        array['calculista']);
    end if;
  end if;
  return r;
end; $$;

create or replace function public.calculista_failed(p_lead uuid, p_error text)
returns void language sql security definer set search_path = public as $$
  select public.log_event(l.office_id, l.id, 'calculista_falhou', 'sistema', null, 'calculo', jsonb_build_object('error', left(p_error, 500)))
  from public.leads l where l.id = p_lead;
$$;

-- -----------------------------------------------------------------------------
-- 12. Geração da peça
-- -----------------------------------------------------------------------------
alter table public.pieces
  add column if not exists geracao_status text,
  add column if not exists geracao_solicitada_em timestamptz,
  add column if not exists geracao_iniciada_em timestamptz,
  add column if not exists geracao_erro text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pieces_geracao_status_check') then
    alter table public.pieces add constraint pieces_geracao_status_check
      check (geracao_status is null or geracao_status in ('pendente','gerando','gerada','falhou'));
  end if;
end $$;

-- Coleta terminou: lead vai para a peça e a peça fica pendente de geração.
create or replace function public.request_piece_generation(p_lead uuid, p_actor text, p_actor_user uuid default null, p_agent text default null)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare l public.leads; pc public.pieces; v_tese text;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  if l.phase = 'provas' then
    l := public.advance_phase(p_lead, 'peca', p_actor, p_actor_user, p_agent, 'coleta de documentos finalizada');
  elsif l.phase <> 'peca' then
    raise exception 'a peça só é gerada depois da coleta de documentos (fase atual: %)', public.phase_label(l.phase);
  end if;

  select * into pc from public.pieces where lead_id = p_lead order by created_at desc limit 1;
  if pc.id is not null and pc.status <> 'rascunho' then
    return pc;   -- já está em revisão/saneamento/protocolo: não gera outra por cima
  end if;
  if pc.id is null then
    v_tese := coalesce(l.tese, (select b.teses[1] from public.briefings b where b.lead_id = p_lead limit 1), 'verbas_rescisorias');
    insert into public.pieces (office_id, lead_id, tese, status, generated_by_actor, geracao_status, geracao_solicitada_em)
    values (l.office_id, p_lead, v_tese, 'rascunho', 'ia', 'pendente', now())
    returning * into pc;
  elsif coalesce(pc.geracao_status, '') not in ('pendente','gerando') then
    update public.pieces set geracao_status = 'pendente', geracao_solicitada_em = now(), geracao_erro = null
     where id = pc.id returning * into pc;
  end if;
  perform public.log_event(l.office_id, p_lead, 'piece_generation_requested', p_actor, p_actor_user, p_agent,
    jsonb_build_object('piece_id', pc.id, 'tese', pc.tese));
  return pc;
end; $$;

create or replace function public.ui_finish_collection(p_lead uuid)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_finish_collection exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  return public.request_piece_generation(p_lead, 'humano', auth.uid(), null);
end; $$;

-- n8n 08 pega as peças pendentes (e as que travaram em "gerando" há 30+ min).
create or replace function public.piece_generation_claim(p_limit int default 5)
returns table (piece_id uuid, lead_id uuid, office_id uuid, tese text, teses text[], blocos jsonb, briefing jsonb, qualificacao jsonb,
               evidencias jsonb, case_data jsonb, contato jsonb, escritorio jsonb, model text)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with alvo as (
    select p.id from public.pieces p
    where p.geracao_status = 'pendente' or (p.geracao_status = 'gerando' and p.geracao_iniciada_em < now() - interval '30 minutes')
    order by p.geracao_solicitada_em nulls last
    limit p_limit
    for update skip locked
  ), c as (
    update public.pieces p set geracao_status = 'gerando', geracao_iniciada_em = now()
    from alvo where p.id = alvo.id
    returning p.*
  )
  select c.id, c.lead_id, c.office_id, c.tese, t.teses,
    (select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'code', x.code, 'nome', x.name, 'tese', x.tese, 'obrigatorio', x.required,
                                                  'ordem', x.ordem, 'texto', x.body, 'provas_exigidas', x.required_evidence)
                               order by case x.kind when 'bloco' then 0 else 1 end, x.ordem), '[]'::jsonb)
       from (select distinct on (coalesce(pt.code, pt.tese || ':' || pt.name)) pt.*
               from public.piece_templates pt
              where pt.active and (pt.office_id = c.office_id or pt.office_id is null)
                and ((pt.kind = 'bloco' and pt.required) or (pt.kind = 'tese' and pt.tese = any (t.teses)))
              order by coalesce(pt.code, pt.tese || ':' || pt.name), pt.office_id nulls last) x),
    (select to_jsonb(b) from public.briefings b where b.lead_id = c.lead_id limit 1),
    coalesce((select r.data || jsonb_build_object('versao', r.versao) from public.qualification_records r where r.lead_id = c.lead_id order by r.versao desc limit 1),
             (select to_jsonb(q) from public.lead_qualification q where q.lead_id = c.lead_id)),
    (select coalesce(jsonb_agg(jsonb_build_object('titulo', e.title, 'doc_tipo', e.doc_tipo, 'status', e.status, 'descricao', e.description)
                               order by e.created_at), '[]'::jsonb)
       from public.evidences e where e.lead_id = c.lead_id and e.status in ('recebida','validada')),
    (select to_jsonb(d) from public.case_data d where d.lead_id = c.lead_id),
    (select jsonb_build_object('nome', ct.name, 'cpf', ct.cpf, 'nascimento', ct.nascimento, 'estado_civil', ct.estado_civil,
                               'nacionalidade', ct.nacionalidade, 'endereco', ct.endereco, 'cidade', ct.cidade, 'uf', ct.uf, 'cep', ct.cep)
       from public.leads l join public.contacts ct on ct.id = l.contact_id where l.id = c.lead_id),
    public.office_escritorio(c.office_id) || (select jsonb_build_object('oab_responsavel', o.oab_responsavel, 'cidade', o.cidade, 'uf', o.uf)
                                              from public.offices o where o.id = c.office_id),
    (select a.model from public.agent_config_role(c.office_id, 'redacao') a)
  from c
  cross join lateral (select coalesce(nullif((select b.teses from public.briefings b where b.lead_id = c.lead_id limit 1), '{}'::text[]),
                                      array[c.tese]) as teses) t;
end; $$;

create or replace function public.piece_generation_save(p_piece uuid, p_content text, p_resumo_executivo text default null,
                                                        p_documentos_anexar jsonb default '[]'::jsonb, p_qualidade text default null,
                                                        p_ai_meta jsonb default null)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare pc public.pieces;
begin
  if coalesce(btrim(p_content), '') = '' then raise exception 'conteúdo vazio'; end if;
  update public.pieces
     set content = p_content,
         resumo_executivo = coalesce(p_resumo_executivo, resumo_executivo),
         documentos_anexar = case when jsonb_typeof(p_documentos_anexar) = 'array' then p_documentos_anexar else documentos_anexar end,
         qualidade = case when p_qualidade in ('viavel','fragil') then p_qualidade else qualidade end,
         generated_by_actor = 'ia', status = 'revisao', geracao_status = 'gerada', geracao_erro = null
   where id = p_piece returning * into pc;
  if pc.id is null then raise exception 'peça % não existe', p_piece; end if;
  perform public.log_event(pc.office_id, pc.lead_id, 'piece_generated', 'ia', null, 'redacao',
    jsonb_build_object('piece_id', pc.id, 'tese', pc.tese, 'versao', pc.versao, 'qualidade', pc.qualidade,
                       'caracteres', length(p_content), 'ai_meta', p_ai_meta));
  return pc;
end; $$;

create or replace function public.piece_generation_failed(p_piece uuid, p_error text)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare pc public.pieces;
begin
  update public.pieces set geracao_status = 'falhou', geracao_erro = left(p_error, 500) where id = p_piece returning * into pc;
  if pc.id is null then raise exception 'peça % não existe', p_piece; end if;
  perform public.log_event(pc.office_id, pc.lead_id, 'piece_generation_failed', 'sistema', null, 'redacao',
    jsonb_build_object('piece_id', pc.id, 'error', left(p_error, 500)));
  perform public.request_intervention(pc.lead_id, null, 'erro_ia', 'Falha ao gerar a peça', 2, 'sistema', 'redacao',
    left(p_error, 300), array['peca']);
  return pc;
end; $$;

-- -----------------------------------------------------------------------------
-- apply_agent_effects (014 + agendamento com data/hora + Coletor pede a peça).
-- Mesma assinatura.
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
  v_task uuid; k public.contracts; b public.briefings; pc public.pieces;
  v_role text;
  v_piece uuid;
  v_kind text;
  v_due timestamptz;
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
      l := public.close_lead_with_reason(p_lead, coalesce(nullif(p_advance_reason, ''), 'outro'), 'outro', null, 'ia', null, v_role);
      v_result := v_result || jsonb_build_object('phase', l.phase, 'closed_kind', l.closed_kind, 'closed_code', l.closed_code);
    elsif p_advance_to = 'revisao' then
      select id into v_piece from public.pieces where lead_id = p_lead and status = 'saneamento' order by created_at desc limit 1;
      if v_piece is not null then
        update public.pieces set status = 'revisao', generated_by_actor = 'ia', updated_at = now() where id = v_piece;
        perform public.log_event(l.office_id, p_lead, 'saneamento_concluido', 'ia', null, v_role,
          jsonb_build_object('piece_id', v_piece, 'reason', p_advance_reason), p_conversation);
        v_result := v_result || jsonb_build_object('piece_id', v_piece, 'piece_status', 'revisao');
      end if;
    elsif p_advance_to = 'peca' and l.phase = 'provas' then
      -- o Coletor terminou: vai para a peça e pede a geração (n8n 08)
      pc := public.request_piece_generation(p_lead, 'ia', null, v_role);
      v_result := v_result || jsonb_build_object('phase', 'peca', 'piece_id', pc.id, 'geracao', pc.geracao_status);
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
    v_kind := case when p_task->>'kind' = 'agendamento' or (p_task ? 'due_at' and coalesce(p_task->>'kind', '') = '') then 'agendamento' else 'tarefa' end;
    v_due := coalesce((p_task->>'due_at')::timestamptz, (current_date + 1) + time '09:00');
    insert into public.tasks (office_id, lead_id, title, description, due_at, assigned_to, created_by_actor, kind, status, agent_role)
    values (l.office_id, p_lead, p_task->>'title', p_task->>'description', v_due, l.assigned_to, 'ia', v_kind, 'agendado', v_role)
    returning id into v_task;
    if v_kind = 'agendamento' then
      perform public.log_event(l.office_id, p_lead, 'agendamento_criado', 'ia', null, v_role,
        jsonb_build_object('task_id', v_task, 'due_at', v_due, 'description', coalesce(p_task->>'description', p_task->>'title'),
                           'texto', 'Agendamento criado para ' || to_char(v_due at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
                                    || ' — ' || coalesce(p_task->>'description', p_task->>'title')),
        p_conversation);
    end if;
    v_result := v_result || jsonb_build_object('task_id', v_task, 'task_kind', v_kind);
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
-- Grants
-- -----------------------------------------------------------------------------
grant select on public.v_tasks, public.v_agenda to authenticated;
grant execute on function public.doc_tipos() to authenticated;
grant execute on function public.doc_tipo_titulo(text) to authenticated;
grant execute on function public.task_status_titulo(text) to authenticated;
grant execute on function public.ui_set_agendamento(uuid, text, timestamptz) to authenticated;
grant execute on function public.ui_confirm_agendamento(uuid) to authenticated;
grant execute on function public.ui_reschedule_agendamento(uuid, timestamptz) to authenticated;
grant execute on function public.ui_cancel_agendamento(uuid) to authenticated;
grant execute on function public.prescricao_info(uuid) to authenticated;
grant execute on function public.faixa_label(text, boolean) to authenticated;
grant execute on function public.to_num(text) to authenticated;
grant execute on function public.ui_finish_collection(uuid) to authenticated;

-- Só o n8n (service_role) ou o próprio banco.
do $$
declare f text;
begin
  foreach f in array array[
    'public.ingest_media(uuid, text, text, bigint, text, text, text)',
    'public.agendamentos_escalar(int)',
    'public.agendamentos_due(int)',
    'public.agendamento_mark_done(uuid, text, uuid)',
    'public.run_monitors()',
    'public.ingest_inbound(text, text, text, text, text, jsonb, timestamptz)',
    'public.calculista_queue(int)',
    'public.save_qualification_record(uuid, jsonb, text, jsonb)',
    'public.calculista_failed(uuid, text)',
    'public.request_piece_generation(uuid, text, uuid, text)',
    'public.piece_generation_claim(int)',
    'public.piece_generation_save(uuid, text, text, jsonb, text, jsonb)',
    'public.piece_generation_failed(uuid, text)',
    'public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- =============================================================================
-- P3. Mensageria e assinatura por provedor
-- =============================================================================
-- Um provedor ativo por tipo (mensageria, assinatura). set_integration já
-- desligava os outros; agora o banco garante.
update public.integrations i set active = false
 where i.active and i.kind in ('mensageria','assinatura')
   and exists (select 1 from public.integrations j where j.office_id = i.office_id and j.kind = i.kind and j.active
                 and (j.updated_at > i.updated_at or (j.updated_at = i.updated_at and j.id > i.id)));
create unique index if not exists integrations_um_ativo_por_tipo
  on public.integrations (office_id, kind) where active and kind in ('mensageria','assinatura');

-- Provedor de mensageria do escritório. Sem integração ativa, o número do
-- WhatsApp Cloud cadastrado continua valendo (comportamento até a 014).
create or replace function public.mensageria_provider(p_office uuid)
returns text language sql stable set search_path = public as $$
  select coalesce(public.active_integration(p_office, 'mensageria'),
                  case when exists (select 1 from public.whatsapp_numbers w where w.office_id = p_office and w.active) then 'meta_whatsapp' end);
$$;

-- Tudo que o WA 03 precisa para enviar uma linha pendente, já com o provedor.
-- O segredo sai do Vault e nunca volta para o front (só service_role executa).
create or replace function public.mensageria_destino(p_message uuid)
returns table (message_id uuid, office_id uuid, provider text, body text, template jsonb, wa_id text, phone_number_id text,
               token text, provider_config jsonb)
language sql stable security definer set search_path = public as $$
  select m.id, m.office_id, public.mensageria_provider(m.office_id), m.body, m.template, ct.wa_id, wn.phone_number_id,
         case public.mensageria_provider(m.office_id)
           when 'meta_whatsapp' then (select s.decrypted_secret from vault.decrypted_secrets s where s.name = wn.token_secret_name)
           else public.integration_secret(m.office_id, public.mensageria_provider(m.office_id)) end,
         (select i.config from public.integrations i where i.office_id = m.office_id and i.provider = public.mensageria_provider(m.office_id))
  from public.messages m
  join public.conversations c on c.id = m.conversation_id
  join public.contacts ct on ct.id = c.contact_id
  left join public.whatsapp_numbers wn on wn.id = c.whatsapp_number_id
  where m.id = p_message and m.status = 'pending' and m.direction = 'out';
$$;

-- Marca uma linha como falha com o motivo (provedor sem envio implementado etc.).
create or replace function public.message_mark_failed(p_message uuid, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.messages set status = 'failed', error = left(p_error, 500) where id = p_message and status = 'pending';
$$;

grant execute on function public.mensageria_provider(uuid) to authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.mensageria_destino(uuid)', 'public.message_mark_failed(uuid, text)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
