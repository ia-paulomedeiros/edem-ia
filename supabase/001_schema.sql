-- =============================================================================
-- 001_schema.sql — Sprint 0: fundação multi-tenant
--
-- Escritório (office) é o tenant. Tudo carrega office_id e tem RLS.
-- Decisões que esta migration materializa (ver docs/01-blueprint.md):
--   * a trava do takeover mora no banco: conversations.ai_paused + ai_should_reply()
--   * nenhuma mensagem vai para o WhatsApp sem virar linha em messages primeiro
--   * todo evento nomeia o autor: case_events.actor in ('ia','humano','sistema')
--   * segredo não vai para tabela: whatsapp_numbers guarda só o NOME do segredo no Vault
--
-- Idempotente: pode ser reaplicada sem efeito colateral.
-- Testada em PostgreSQL 16 (ver supabase/tests/run.sh).
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- Helpers de RLS
-- -----------------------------------------------------------------------------

create table if not exists public.offices (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text unique,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);

create table if not exists public.office_members (
  office_id   uuid not null references public.offices(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null default 'atendente' check (role in ('admin','advogado','atendente')),
  created_at  timestamptz not null default now(),
  primary key (office_id, user_id)
);
create index if not exists office_members_user_idx on public.office_members(user_id);

-- security definer para não recursionar na policy de office_members
create or replace function public.is_office_member(p_office uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.office_members m
    where m.office_id = p_office and m.user_id = auth.uid()
  );
$$;

create or replace function public.member_role(p_office uuid)
returns text
language sql stable security definer
set search_path = public
as $$
  select m.role from public.office_members m
  where m.office_id = p_office and m.user_id = auth.uid();
$$;

-- Aplica o conjunto padrão de policies "membro do escritório" numa tabela
-- que tenha coluna office_id. Escrita pode ser restrita a papéis.
create or replace function public.apply_office_rls(p_table text, p_write_roles text[] default null)
returns void
language plpgsql
as $$
declare
  v_write text;
begin
  if p_write_roles is null then
    v_write := format('public.is_office_member(%I)', 'office_id');
  else
    v_write := format('public.member_role(%I) = any (%L::text[])', 'office_id', p_write_roles);
  end if;

  execute format('alter table public.%I enable row level security', p_table);

  execute format('drop policy if exists %I on public.%I', p_table || '_select', p_table);
  execute format('create policy %I on public.%I for select to authenticated using (public.is_office_member(office_id))',
                 p_table || '_select', p_table);

  execute format('drop policy if exists %I on public.%I', p_table || '_insert', p_table);
  execute format('create policy %I on public.%I for insert to authenticated with check (%s)',
                 p_table || '_insert', p_table, v_write);

  execute format('drop policy if exists %I on public.%I', p_table || '_update', p_table);
  execute format('create policy %I on public.%I for update to authenticated using (%s) with check (%s)',
                 p_table || '_update', p_table, v_write, v_write);

  execute format('drop policy if exists %I on public.%I', p_table || '_delete', p_table);
  execute format('create policy %I on public.%I for delete to authenticated using (%s)',
                 p_table || '_delete', p_table, v_write);
end;
$$;

-- -----------------------------------------------------------------------------
-- Canal: números de WhatsApp (Cloud API oficial da Meta)
-- -----------------------------------------------------------------------------

create table if not exists public.whatsapp_numbers (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  phone_number_id     text not null unique,       -- id do número na Meta (chega no webhook)
  waba_id             text,                       -- WhatsApp Business Account
  display_phone       text,
  -- Nome do segredo no Supabase Vault (vault.decrypted_secrets.name).
  -- O token de acesso NUNCA é gravado aqui; o n8n resolve o nome com service_role.
  token_secret_name   text not null,
  active              boolean not null default true,
  created_at          timestamptz not null default now()
);
create index if not exists whatsapp_numbers_office_idx on public.whatsapp_numbers(office_id);

-- -----------------------------------------------------------------------------
-- Contatos, leads, conversas, mensagens
-- -----------------------------------------------------------------------------

create table if not exists public.contacts (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid not null references public.offices(id) on delete cascade,
  wa_id       text not null,                      -- telefone E.164 sem '+', como a Meta manda
  name        text,
  created_at  timestamptz not null default now(),
  unique (office_id, wa_id)
);

create table if not exists public.leads (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid not null references public.offices(id) on delete cascade,
  contact_id  uuid not null references public.contacts(id) on delete cascade,
  source      text not null default 'whatsapp',
  assigned_to uuid references auth.users(id),
  notes       text,
  closed_at   timestamptz,                        -- derivado da fase (002); nunca setar na UI
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists leads_office_idx   on public.leads(office_id, created_at desc);
create index if not exists leads_contact_idx  on public.leads(contact_id);
create unique index if not exists leads_one_open_per_contact on public.leads(contact_id) where closed_at is null;

create table if not exists public.conversations (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  contact_id          uuid not null references public.contacts(id) on delete cascade,
  whatsapp_number_id  uuid not null references public.whatsapp_numbers(id),
  status              text not null default 'open' check (status in ('open','closed')),
  -- A TRAVA. true = IA não responde; equipe assumiu.
  ai_paused           boolean not null default false,
  paused_by           uuid references auth.users(id),
  paused_at           timestamptz,
  last_message_at     timestamptz,
  last_message_preview text,
  unread_count        integer not null default 0,
  created_at          timestamptz not null default now(),
  unique (lead_id, whatsapp_number_id)
);
create index if not exists conversations_office_last_idx on public.conversations(office_id, last_message_at desc nulls last);

create table if not exists public.messages (
  id              uuid primary key default gen_random_uuid(),
  office_id       uuid not null references public.offices(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  direction       text not null check (direction in ('in','out')),
  sender          text not null check (sender in ('contact','ia','humano','sistema')),
  body            text,
  media           jsonb,                          -- {type, id, mime_type, caption, storage_path}
  wa_message_id   text unique,                    -- id da Meta; idempotência do webhook
  status          text not null default 'pending' check (status in ('pending','sent','delivered','read','failed','received')),
  error           text,
  ai_meta         jsonb,                          -- {agent_role, model, tokens_in, tokens_out, cost_usd, ...}
  sent_by         uuid references auth.users(id), -- humano que enviou (sender='humano')
  created_at      timestamptz not null default now(),
  constraint messages_sender_direction check (
    (direction = 'in'  and sender = 'contact') or
    (direction = 'out' and sender in ('ia','humano','sistema'))
  ),
  constraint messages_human_has_user check (sender <> 'humano' or sent_by is not null)
);
create index if not exists messages_conversation_idx on public.messages(conversation_id, created_at);
create index if not exists messages_office_idx       on public.messages(office_id, created_at desc);
create index if not exists messages_pending_out_idx  on public.messages(status) where direction = 'out' and status = 'pending';

-- -----------------------------------------------------------------------------
-- Tarefas e linha do tempo
-- -----------------------------------------------------------------------------

create table if not exists public.tasks (
  id              uuid primary key default gen_random_uuid(),
  office_id       uuid not null references public.offices(id) on delete cascade,
  lead_id         uuid references public.leads(id) on delete cascade,
  title           text not null,
  description     text,
  due_at          timestamptz,
  done_at         timestamptz,
  assigned_to     uuid references auth.users(id),
  created_by      uuid references auth.users(id),
  created_by_actor text not null default 'humano' check (created_by_actor in ('ia','humano','sistema')),
  created_at      timestamptz not null default now()
);
create index if not exists tasks_office_open_idx on public.tasks(office_id, due_at) where done_at is null;
create index if not exists tasks_lead_idx on public.tasks(lead_id);

create table if not exists public.case_events (
  id              uuid primary key default gen_random_uuid(),
  office_id       uuid not null references public.offices(id) on delete cascade,
  lead_id         uuid not null references public.leads(id) on delete cascade,
  conversation_id uuid references public.conversations(id) on delete set null,
  type            text not null,                  -- 'lead_created','takeover','ai_released','phase_changed',...
  actor           text not null check (actor in ('ia','humano','sistema')),
  actor_user_id   uuid references auth.users(id), -- obrigatório quando actor='humano'
  actor_agent     text,                           -- papel do agente quando actor='ia'
  payload         jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now(),
  constraint case_events_human_has_user check (actor <> 'humano' or actor_user_id is not null)
);
create index if not exists case_events_lead_idx   on public.case_events(lead_id, created_at);
create index if not exists case_events_office_idx on public.case_events(office_id, created_at desc);

create or replace function public.log_event(
  p_office uuid, p_lead uuid, p_type text, p_actor text,
  p_actor_user uuid default null, p_agent text default null,
  p_payload jsonb default '{}'::jsonb, p_conversation uuid default null
) returns uuid
language plpgsql
set search_path = public
as $$
declare v_id uuid;
begin
  insert into public.case_events (office_id, lead_id, conversation_id, type, actor, actor_user_id, actor_agent, payload)
  values (p_office, p_lead, p_conversation, p_type, p_actor, p_actor_user, p_agent, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- A trava do takeover
-- -----------------------------------------------------------------------------

-- O n8n chama isto ANTES de gerar qualquer resposta. 002 amplia com fase e fila.
create or replace function public.ai_should_reply(p_conversation uuid)
returns boolean
language sql stable
set search_path = public
as $$
  select coalesce((
    select c.status = 'open' and not c.ai_paused and o.active
    from public.conversations c
    join public.offices o on o.id = c.office_id
    where c.id = p_conversation
  ), false);
$$;

-- Equipe assume a conversa (UI). Usa auth.uid(); com service_role passe p_user.
create or replace function public.take_over(p_conversation uuid, p_user uuid default null)
returns public.conversations
language plpgsql security definer
set search_path = public
as $$
declare
  v_user uuid := coalesce(p_user, auth.uid());
  v_conv public.conversations;
begin
  select * into v_conv from public.conversations where id = p_conversation for update;
  if v_conv.id is null then raise exception 'conversa % não existe', p_conversation; end if;
  if v_user is null then raise exception 'take_over exige usuário'; end if;
  if auth.uid() is not null and not public.is_office_member(v_conv.office_id) then
    raise exception 'sem acesso ao escritório';
  end if;

  if not v_conv.ai_paused then
    update public.conversations
       set ai_paused = true, paused_by = v_user, paused_at = now()
     where id = p_conversation
     returning * into v_conv;
    perform public.log_event(v_conv.office_id, v_conv.lead_id, 'takeover', 'humano', v_user, null, '{}'::jsonb, p_conversation);
  end if;
  return v_conv;
end;
$$;

-- Equipe devolve a conversa para a IA.
create or replace function public.release_to_ai(p_conversation uuid, p_user uuid default null)
returns public.conversations
language plpgsql security definer
set search_path = public
as $$
declare
  v_user uuid := coalesce(p_user, auth.uid());
  v_conv public.conversations;
begin
  select * into v_conv from public.conversations where id = p_conversation for update;
  if v_conv.id is null then raise exception 'conversa % não existe', p_conversation; end if;
  if v_user is null then raise exception 'release_to_ai exige usuário'; end if;
  if auth.uid() is not null and not public.is_office_member(v_conv.office_id) then
    raise exception 'sem acesso ao escritório';
  end if;

  if v_conv.ai_paused then
    update public.conversations
       set ai_paused = false, paused_by = null, paused_at = null
     where id = p_conversation
     returning * into v_conv;
    perform public.log_event(v_conv.office_id, v_conv.lead_id, 'ai_released', 'humano', v_user, null, '{}'::jsonb, p_conversation);
  end if;
  return v_conv;
end;
$$;

-- -----------------------------------------------------------------------------
-- Mensagens: efeitos colaterais
-- -----------------------------------------------------------------------------

-- Toda mensagem atualiza o resumo da conversa. Mensagem manual de humano
-- pausa a IA automaticamente (enviar = assumir), com evento nomeando o autor.
create or replace function public.messages_after_insert()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_conv public.conversations;
begin
  update public.conversations
     set last_message_at = new.created_at,
         last_message_preview = left(coalesce(new.body, '[mídia]'), 140),
         unread_count = case when new.direction = 'in' then unread_count + 1 else 0 end
   where id = new.conversation_id
   returning * into v_conv;

  if new.direction = 'out' and new.sender = 'humano' and not v_conv.ai_paused then
    update public.conversations
       set ai_paused = true, paused_by = new.sent_by, paused_at = now()
     where id = new.conversation_id;
    perform public.log_event(new.office_id, v_conv.lead_id, 'takeover', 'humano', new.sent_by, null,
                             jsonb_build_object('via', 'manual_message', 'message_id', new.id), new.conversation_id);
  end if;
  return new;
end;
$$;

drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert
  after insert on public.messages
  for each row execute function public.messages_after_insert();

-- Envio manual pela UI: cria a LINHA. O envio ao WhatsApp é consequência
-- (n8n 03_manual_send reage ao insert via Database Webhook).
create or replace function public.send_manual_message(p_conversation uuid, p_body text)
returns public.messages
language plpgsql security definer
set search_path = public
as $$
declare
  v_conv public.conversations;
  v_msg  public.messages;
begin
  if auth.uid() is null then raise exception 'send_manual_message exige usuário autenticado'; end if;
  select * into v_conv from public.conversations where id = p_conversation;
  if v_conv.id is null then raise exception 'conversa % não existe', p_conversation; end if;
  if not public.is_office_member(v_conv.office_id) then raise exception 'sem acesso ao escritório'; end if;
  if v_conv.status <> 'open' then raise exception 'conversa encerrada'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'mensagem vazia'; end if;

  insert into public.messages (office_id, conversation_id, direction, sender, body, status, sent_by)
  values (v_conv.office_id, p_conversation, 'out', 'humano', p_body, 'pending', auth.uid())
  returning * into v_msg;
  return v_msg;
end;
$$;

-- Marca leitura (UI abriu a conversa).
create or replace function public.mark_conversation_read(p_conversation uuid)
returns void
language sql security definer
set search_path = public
as $$
  update public.conversations set unread_count = 0
  where id = p_conversation and public.is_office_member(office_id);
$$;

-- -----------------------------------------------------------------------------
-- Ingestão do webhook (chamado pelo n8n com service_role)
-- Idempotente por wa_message_id. Cria contato, lead aberto e conversa se preciso.
-- -----------------------------------------------------------------------------

create or replace function public.ingest_inbound(
  p_phone_number_id text,
  p_wa_id text,
  p_name text,
  p_wa_message_id text,
  p_body text,
  p_media jsonb default null,
  p_ts timestamptz default now()
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  v_num   public.whatsapp_numbers;
  v_contact_id uuid;
  v_lead_id uuid;
  v_conv_id uuid;
  v_msg_id uuid;
  v_new_lead boolean := false;
begin
  select * into v_num from public.whatsapp_numbers where phone_number_id = p_phone_number_id and active;
  if v_num.id is null then
    raise exception 'phone_number_id % não cadastrado/ativo', p_phone_number_id;
  end if;

  -- duplicado? (Meta reentrega)
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

-- Últimas N mensagens para montar o contexto do agente (n8n).
create or replace function public.conversation_context(p_conversation uuid, p_limit int default 30)
returns jsonb
language sql stable
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'role', case when m.direction = 'in' then 'user' else 'assistant' end,
           'sender', m.sender, 'body', m.body, 'media', m.media, 'at', m.created_at
         ) order by m.created_at), '[]'::jsonb)
  from (
    select * from public.messages where conversation_id = p_conversation
    order by created_at desc limit p_limit
  ) m;
$$;

-- -----------------------------------------------------------------------------
-- updated_at
-- -----------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;

drop trigger if exists leads_touch on public.leads;
create trigger leads_touch before update on public.leads
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Realtime: inbox ao vivo
-- -----------------------------------------------------------------------------

create or replace function public.add_to_realtime(p_table text)
returns void language plpgsql as $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = p_table) then
    execute format('alter publication supabase_realtime add table public.%I', p_table);
  end if;
end; $$;

select public.add_to_realtime('conversations');
select public.add_to_realtime('messages');

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------

alter table public.offices enable row level security;
drop policy if exists offices_select on public.offices;
create policy offices_select on public.offices for select to authenticated using (public.is_office_member(id));
drop policy if exists offices_update on public.offices;
create policy offices_update on public.offices for update to authenticated
  using (public.member_role(id) = 'admin') with check (public.member_role(id) = 'admin');

alter table public.office_members enable row level security;
drop policy if exists office_members_select on public.office_members;
create policy office_members_select on public.office_members for select to authenticated
  using (user_id = auth.uid() or public.is_office_member(office_id));
drop policy if exists office_members_write on public.office_members;
create policy office_members_write on public.office_members for all to authenticated
  using (public.member_role(office_id) = 'admin') with check (public.member_role(office_id) = 'admin');

select public.apply_office_rls('whatsapp_numbers', array['admin']);
select public.apply_office_rls('contacts');
select public.apply_office_rls('leads');
select public.apply_office_rls('conversations');
select public.apply_office_rls('tasks');

-- messages: membro lê; só insere mensagem de saída própria (humano = auth.uid()).
-- Preferir send_manual_message(); a policy garante o mínimo mesmo em insert direto.
select public.apply_office_rls('messages');
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (public.is_office_member(office_id) and direction = 'out' and sender = 'humano' and sent_by = auth.uid());
drop policy if exists messages_update on public.messages;
drop policy if exists messages_delete on public.messages;

-- case_events: membro lê; só insere evento humano assinado por si; nunca edita/apaga.
select public.apply_office_rls('case_events');
drop policy if exists case_events_insert on public.case_events;
create policy case_events_insert on public.case_events for insert to authenticated
  with check (public.is_office_member(office_id) and actor = 'humano' and actor_user_id = auth.uid());
drop policy if exists case_events_update on public.case_events;
drop policy if exists case_events_delete on public.case_events;

-- Funções que o cliente chama
grant execute on function public.take_over(uuid, uuid) to authenticated;
grant execute on function public.release_to_ai(uuid, uuid) to authenticated;
grant execute on function public.send_manual_message(uuid, text) to authenticated;
grant execute on function public.mark_conversation_read(uuid) to authenticated;
grant execute on function public.ai_should_reply(uuid) to authenticated;
-- Só o n8n (service_role) ingere e monta contexto
revoke execute on function public.ingest_inbound(text, text, text, text, text, jsonb, timestamptz) from anon, authenticated;
revoke execute on function public.conversation_context(uuid, int) from anon, authenticated;
revoke execute on function public.log_event(uuid, uuid, text, text, uuid, text, jsonb, uuid) from anon, authenticated;
