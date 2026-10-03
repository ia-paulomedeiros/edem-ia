-- =============================================================================
-- 015a — parte 1 de 3 de supabase/015_paridade_automacoes.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 014 inteira (todas as partes 014*). Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- ---------- Verificação da parte 015a: deve voltar uma linha com resultado = OK
select '015a' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função agendamento_mark_done', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agendamento_mark_done')),
    ('função agendamentos_due', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agendamentos_due')),
    ('função agendamentos_escalar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agendamentos_escalar')),
    ('função doc_tipo_titulo', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'doc_tipo_titulo')),
    ('função doc_tipos', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'doc_tipos')),
    ('função ingest_media', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ingest_media')),
    ('função run_monitors', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'run_monitors')),
    ('função task_status_titulo', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'task_status_titulo')),
    ('função tasks_status_sync', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tasks_status_sync')),
    ('função ui_cancel_agendamento', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_cancel_agendamento')),
    ('função ui_confirm_agendamento', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_confirm_agendamento')),
    ('função ui_reschedule_agendamento', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_reschedule_agendamento')),
    ('função ui_set_agendamento', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_set_agendamento')),
    ('view v_agenda', to_regclass('public.v_agenda') is not null),
    ('view v_tasks', to_regclass('public.v_tasks') is not null),
    ('coluna evidences.doc_tipo', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'evidences' and column_name = 'doc_tipo')),
    ('coluna evidences.mime_type', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'evidences' and column_name = 'mime_type')),
    ('coluna evidences.size_bytes', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'evidences' and column_name = 'size_bytes')),
    ('coluna evidences.origem', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'evidences' and column_name = 'origem')),
    ('coluna evidences.agent_role', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'evidences' and column_name = 'agent_role')),
    ('coluna tasks.kind', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tasks' and column_name = 'kind')),
    ('coluna tasks.status', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tasks' and column_name = 'status')),
    ('coluna tasks.status_changed_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tasks' and column_name = 'status_changed_at')),
    ('coluna tasks.escalada_em', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tasks' and column_name = 'escalada_em')),
    ('coluna tasks.agent_role', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'tasks' and column_name = 'agent_role'))
) as v(item, ok);
