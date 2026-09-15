-- =============================================================================
-- apply_all.sql — 001 + 002 + 003 + 004 concatenadas, para colar de uma vez no SQL Editor
-- do Supabase. Idempotente. Gerado a partir dos arquivos individuais; não edite aqui.
-- =============================================================================

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/001_schema.sql

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

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/002_dominio_juridico.sql

-- =============================================================================
-- 002_dominio_juridico.sql — Sprint 1: o domínio trabalhista entra no banco
--
--   * case_phase: a fase é UMA coluna (leads.phase). Kanban, lista, funil e
--     dashboard são projeções dela. advance_phase() é a única forma de mudar.
--   * sete agentes por papel; agent_for_phase() diz quem atende cada fase.
--   * qualification_gate(): portão por faixa de ticket e tempo mínimo de vínculo.
--   * calc_verbas(): estimativa das verbas rescisórias a partir de case_data.
--   * leads.prescricao_em: coluna indexada, derivada de case_data.demissao.
--   * provas, contrato, briefing, peça (modelos por tese), fila de intervenção.
--   * custo de aquisição derivado de messages.ai_meta.
--   * lead_dossier(): o caso inteiro em uma chamada (respeita RLS).
--
-- Idempotente. Depende de 001_schema.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Fase
-- -----------------------------------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'case_phase' and n.nspname = 'public') then
    create type public.case_phase as enum (
      'novo',          -- chegou, ninguém falou ainda
      'triagem',       -- recepção: entender o que aconteceu
      'qualificacao',  -- dados do vínculo + portão
      'provas',        -- coleta de documentos e testemunhas
      'calculo',       -- verbas estimadas apresentadas ao lead
      'contrato',      -- honorários enviados / assinatura
      'briefing',      -- entrevista detalhada para a peça
      'peca',          -- redação e revisão da inicial
      'encerrado'      -- fechado, com closed_by
    );
  end if;
end $$;

alter table public.leads add column if not exists phase public.case_phase not null default 'novo';
alter table public.leads add column if not exists phase_changed_at timestamptz not null default now();
alter table public.leads add column if not exists closed_by text check (closed_by in ('ia','equipe'));
alter table public.leads add column if not exists closed_reason text;
alter table public.leads add column if not exists tese text;              -- tese principal do caso
alter table public.leads add column if not exists prescricao_em date;     -- derivada de case_data.demissao

create index if not exists leads_phase_idx      on public.leads(office_id, phase);
create index if not exists leads_prescricao_idx on public.leads(office_id, prescricao_em) where closed_at is null;

create or replace function public.phase_order(p public.case_phase)
returns int language sql immutable as $$
  select case p
    when 'novo' then 0 when 'triagem' then 1 when 'qualificacao' then 2 when 'provas' then 3
    when 'calculo' then 4 when 'contrato' then 5 when 'briefing' then 6 when 'peca' then 7
    when 'encerrado' then 8 end;
$$;

-- Única porta de mudança de fase. Grava o evento com o autor.
--   actor 'ia' só avança; 'humano' e 'sistema' podem voltar.
--   'encerrado' exige closed_by ('ia'|'equipe'). Reabrir limpa o encerramento.
create or replace function public.advance_phase(
  p_lead uuid,
  p_to public.case_phase,
  p_actor text,
  p_actor_user uuid default null,
  p_agent text default null,
  p_reason text default null,
  p_closed_by text default null
) returns public.leads
language plpgsql security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_from public.case_phase;
begin
  if p_actor not in ('ia','humano','sistema') then raise exception 'actor inválido: %', p_actor; end if;
  if p_actor = 'humano' and p_actor_user is null then raise exception 'actor humano exige p_actor_user'; end if;

  select * into v_lead from public.leads where id = p_lead for update;
  if v_lead.id is null then raise exception 'lead % não existe', p_lead; end if;
  v_from := v_lead.phase;
  if v_from = p_to then return v_lead; end if;

  if p_actor = 'ia' and public.phase_order(p_to) < public.phase_order(v_from) then
    raise exception 'IA não pode retroceder fase (% -> %)', v_from, p_to;
  end if;

  if p_to = 'encerrado' then
    if p_closed_by is null then
      p_closed_by := case p_actor when 'ia' then 'ia' else 'equipe' end;
    end if;
    if p_closed_by not in ('ia','equipe') then raise exception 'closed_by inválido: %', p_closed_by; end if;
    update public.leads
       set phase = p_to, phase_changed_at = now(),
           closed_at = now(), closed_by = p_closed_by, closed_reason = p_reason
     where id = p_lead returning * into v_lead;
    update public.conversations set status = 'closed' where lead_id = p_lead;
  else
    update public.leads
       set phase = p_to, phase_changed_at = now(),
           closed_at = null, closed_by = null, closed_reason = null
     where id = p_lead returning * into v_lead;
    if v_from = 'encerrado' then
      update public.conversations set status = 'open' where lead_id = p_lead;
    end if;
  end if;

  perform public.log_event(v_lead.office_id, p_lead, 'phase_changed', p_actor, p_actor_user, p_agent,
    jsonb_build_object('from', v_from, 'to', p_to, 'reason', p_reason, 'closed_by', v_lead.closed_by));
  return v_lead;
end;
$$;

-- -----------------------------------------------------------------------------
-- Agentes (um papel por fase)
-- -----------------------------------------------------------------------------

create table if not exists public.agents (
  id            uuid primary key default gen_random_uuid(),
  office_id     uuid references public.offices(id) on delete cascade,  -- null = padrão global
  role          text not null,
  name          text not null,
  description   text,
  system_prompt text not null default '',                              -- conteúdo: pendência do produto
  model         text not null default 'claude-sonnet-5',
  temperature   numeric not null default 0.3,
  tools         jsonb not null default '[]'::jsonb,                     -- nomes de tools que o n8n expõe
  enabled       boolean not null default true,
  updated_at    timestamptz not null default now()
);
create unique index if not exists agents_scope_role_uidx
  on public.agents (coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), role);

insert into public.agents (office_id, role, name, description) values
  (null, 'recepcao',     'Recepção',      'Acolhe o lead, entende o que aconteceu e coleta o mínimo para a triagem.'),
  (null, 'qualificacao', 'Qualificação',  'Levanta dados do vínculo (admissão, demissão, salário, rescisão) e roda o portão.'),
  (null, 'provas',       'Provas',        'Pede e organiza documentos, prints, áudios e testemunhas.'),
  (null, 'calculo',      'Cálculo',       'Apresenta a estimativa de verbas e responde dúvidas sobre valores.'),
  (null, 'contrato',     'Contrato',      'Explica honorários, envia contrato e acompanha a assinatura.'),
  (null, 'briefing',     'Briefing',      'Entrevista detalhada para a peça: fatos, datas, pessoas, pedidos.'),
  (null, 'redacao',      'Redação',       'Monta a minuta da inicial a partir do modelo da tese e do briefing.')
on conflict do nothing;

create or replace function public.agent_for_phase(p public.case_phase)
returns text language sql immutable as $$
  select case p
    when 'novo' then 'recepcao' when 'triagem' then 'recepcao'
    when 'qualificacao' then 'qualificacao' when 'provas' then 'provas'
    when 'calculo' then 'calculo' when 'contrato' then 'contrato'
    when 'briefing' then 'briefing' when 'peca' then 'redacao'
    else null end;
$$;

-- Config efetiva do agente: override do escritório ou padrão global.
create or replace function public.agent_config(p_office uuid, p_phase public.case_phase)
returns public.agents
language sql stable
set search_path = public
as $$
  select a.* from public.agents a
  where a.role = public.agent_for_phase(p_phase) and a.enabled
    and (a.office_id = p_office or a.office_id is null)
  order by a.office_id nulls last
  limit 1;
$$;

-- -----------------------------------------------------------------------------
-- Parâmetros do escritório
-- -----------------------------------------------------------------------------

create table if not exists public.office_params (
  office_id               uuid primary key references public.offices(id) on delete cascade,
  ticket_minimo           numeric not null default 5000,     -- abaixo disso o portão reprova
  faixas_ticket           jsonb not null default '[{"faixa":"baixo","ate":10000},{"faixa":"medio","ate":50000},{"faixa":"alto","ate":null}]'::jsonb,
  vinculo_minimo_meses    integer not null default 6,
  alerta_prescricao_dias  integer not null default 90,       -- janela do alerta no card
  honorarios_percent      numeric not null default 30,
  horario_atendimento     jsonb not null default '{"inicio":"08:00","fim":"20:00","dias":[1,2,3,4,5,6]}'::jsonb,
  updated_at              timestamptz not null default now()
);

create or replace function public.offices_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.office_params (office_id) values (new.id) on conflict do nothing;
  return new;
end; $$;
drop trigger if exists offices_after_insert on public.offices;
create trigger offices_after_insert after insert on public.offices
  for each row execute function public.offices_after_insert();

insert into public.office_params (office_id) select id from public.offices on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Dados do vínculo (base do cálculo, do portão e da prescrição)
-- -----------------------------------------------------------------------------

create table if not exists public.case_data (
  lead_id                 uuid primary key references public.leads(id) on delete cascade,
  office_id               uuid not null references public.offices(id) on delete cascade,
  empresa                 text,
  cargo                   text,
  admissao                date,
  demissao                date,
  salario                 numeric,                            -- último salário mensal
  tipo_rescisao           text check (tipo_rescisao in ('sem_justa_causa','justa_causa','pedido_demissao','rescisao_indireta','acordo','termino_contrato','sem_registro','ainda_empregado')),
  aviso_previo            text check (aviso_previo in ('trabalhado','indenizado','nao_cumprido','nao_se_aplica')),
  ctps_assinada           boolean,
  fgts_depositado         boolean,
  ferias_vencidas         integer not null default 0,        -- períodos aquisitivos vencidos não gozados
  horas_extras_semanais   numeric not null default 0,        -- média não paga
  verbas_pagas            numeric not null default 0,        -- já recebido na rescisão
  extras                  jsonb not null default '{}'::jsonb, -- assédio, insalubridade, etc.
  updated_by_actor        text not null default 'ia' check (updated_by_actor in ('ia','humano','sistema')),
  updated_at              timestamptz not null default now(),
  constraint case_data_datas check (admissao is null or demissao is null or demissao >= admissao)
);

-- Prescrição bienal (CF art. 7º, XXIX): 2 anos da extinção do contrato.
-- A quinquenal (5 anos retroativos) é aplicada no cálculo, não aqui.
create or replace function public.case_data_sync_lead()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  update public.leads
     set prescricao_em = case when new.demissao is not null then (new.demissao + interval '2 years')::date else null end
   where id = new.lead_id;
  return new;
end; $$;
drop trigger if exists case_data_sync_lead on public.case_data;
create trigger case_data_sync_lead before insert or update on public.case_data
  for each row execute function public.case_data_sync_lead();

create or replace function public.vinculo_meses(p_admissao date, p_demissao date)
returns int language sql immutable as $$
  select case when p_admissao is null then null
         else (extract(year from age(coalesce(p_demissao, current_date), p_admissao)) * 12
             + extract(month from age(coalesce(p_demissao, current_date), p_admissao)))::int end;
$$;

-- Estimativa de verbas. É ESTIMATIVA para triagem, não cálculo pericial.
-- Retorna o detalhamento e o total líquido do que ainda seria devido.
create or replace function public.calc_verbas(p_lead uuid)
returns jsonb
language plpgsql stable
set search_path = public
as $$
declare
  d public.case_data;
  v_meses int;
  v_meses_5 int;                 -- limitado pela quinquenal
  v_anos int;
  v_saldo numeric := 0;
  v_aviso numeric := 0;
  v_13 numeric := 0;
  v_ferias_prop numeric := 0;
  v_ferias_venc numeric := 0;
  v_fgts_nao_dep numeric := 0;
  v_multa_fgts numeric := 0;
  v_he numeric := 0;
  v_total numeric := 0;
  v_sem_justa boolean;
  v_meses_ano int;
  v_meses_aquis int;
begin
  select * into d from public.case_data where lead_id = p_lead;
  if d.lead_id is null or d.salario is null or d.admissao is null then
    return jsonb_build_object('calculado', false, 'motivo', 'faltam salario/admissao');
  end if;

  v_meses := public.vinculo_meses(d.admissao, d.demissao);
  v_meses_5 := least(v_meses, 60);
  v_anos := v_meses / 12;
  v_sem_justa := d.tipo_rescisao in ('sem_justa_causa','rescisao_indireta');

  if d.demissao is not null then
    -- saldo de salário do mês da demissão
    v_saldo := round(d.salario / 30 * extract(day from d.demissao), 2);

    -- aviso prévio indenizado: 30 dias + 3 por ano completo, máx. 90 (Lei 12.506/11)
    if v_sem_justa and coalesce(d.aviso_previo, 'indenizado') in ('indenizado','nao_cumprido') then
      v_aviso := round(d.salario / 30 * least(30 + 3 * v_anos, 90), 2);
    end if;

    -- 13º proporcional: meses do ano com 15+ dias
    v_meses_ano := extract(month from d.demissao)::int - (case when extract(day from d.demissao) >= 15 then 0 else 1 end);
    if extract(year from d.admissao) = extract(year from d.demissao) then
      v_meses_ano := v_meses_ano - (extract(month from d.admissao)::int - 1);
    end if;
    if d.tipo_rescisao <> 'justa_causa' then
      v_13 := round(d.salario * greatest(v_meses_ano, 0) / 12, 2);
    end if;

    -- férias proporcionais + 1/3
    v_meses_aquis := v_meses % 12;
    if d.tipo_rescisao <> 'justa_causa' then
      v_ferias_prop := round(d.salario * v_meses_aquis / 12 * 4 / 3, 2);
    end if;
  end if;

  -- férias vencidas em dobro só após o período concessivo; aqui simples + 1/3 (conservador)
  v_ferias_venc := round(d.ferias_vencidas * d.salario * 4 / 3, 2);

  -- FGTS 8% não depositado (últimos 60 meses) e multa de 40%
  if coalesce(d.fgts_depositado, true) = false then
    v_fgts_nao_dep := round(d.salario * 0.08 * v_meses_5, 2);
  end if;
  if v_sem_justa then
    v_multa_fgts := round(d.salario * 0.08 * v_meses * 0.40, 2);
  end if;

  -- horas extras não pagas: divisor 220, adicional 50%, 4,5 semanas/mês, últimos 60 meses
  if d.horas_extras_semanais > 0 then
    v_he := round(d.salario / 220 * 1.5 * d.horas_extras_semanais * 4.5 * v_meses_5, 2);
  end if;

  v_total := v_saldo + v_aviso + v_13 + v_ferias_prop + v_ferias_venc + v_fgts_nao_dep + v_multa_fgts + v_he
             - coalesce(d.verbas_pagas, 0);
  if v_total < 0 then v_total := 0; end if;

  return jsonb_build_object(
    'calculado', true,
    'vinculo_meses', v_meses,
    'itens', jsonb_build_object(
      'saldo_salario', v_saldo,
      'aviso_previo', v_aviso,
      'decimo_terceiro', v_13,
      'ferias_proporcionais', v_ferias_prop,
      'ferias_vencidas', v_ferias_venc,
      'fgts_nao_depositado', v_fgts_nao_dep,
      'multa_fgts_40', v_multa_fgts,
      'horas_extras', v_he
    ),
    'verbas_pagas', coalesce(d.verbas_pagas, 0),
    'total', round(v_total, 2),
    'aviso', 'Estimativa de triagem. Não substitui cálculo pericial.'
  );
end;
$$;

create or replace function public.faixa_ticket(p_office uuid, p_valor numeric)
returns text language sql stable set search_path = public as $$
  select coalesce((
    select f->>'faixa'
    from public.office_params p, jsonb_array_elements(p.faixas_ticket) with ordinality as f(f, i)
    where p.office_id = p_office
      and (f->>'ate' is null or p_valor <= (f->>'ate')::numeric)
    order by i limit 1
  ), 'indefinida');
$$;

-- -----------------------------------------------------------------------------
-- Portão de qualificação
-- -----------------------------------------------------------------------------

create table if not exists public.lead_qualification (
  lead_id           uuid primary key references public.leads(id) on delete cascade,
  office_id         uuid not null references public.offices(id) on delete cascade,
  passed            boolean not null,
  faixa             text,
  verbas            jsonb,
  verbas_total      numeric,
  vinculo_meses     integer,
  motivos           text[] not null default '{}',
  evaluated_by_actor text not null default 'sistema' check (evaluated_by_actor in ('ia','humano','sistema')),
  evaluated_at      timestamptz not null default now()
);

-- Avalia e persiste. Reprova por: vínculo curto, ticket abaixo do mínimo, prescrição vencida.
create or replace function public.qualification_gate(p_lead uuid, p_actor text default 'sistema', p_actor_user uuid default null)
returns public.lead_qualification
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  p public.office_params;
  v_verbas jsonb;
  v_total numeric;
  v_meses int;
  v_motivos text[] := '{}';
  q public.lead_qualification;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  select * into p from public.office_params where office_id = l.office_id;

  v_verbas := public.calc_verbas(p_lead);
  if not coalesce((v_verbas->>'calculado')::boolean, false) then
    v_motivos := v_motivos || 'dados_insuficientes';
  else
    v_total := (v_verbas->>'total')::numeric;
    v_meses := (v_verbas->>'vinculo_meses')::int;
    if v_meses < p.vinculo_minimo_meses then v_motivos := v_motivos || format('vinculo_curto:%s<%s', v_meses, p.vinculo_minimo_meses); end if;
    if v_total < p.ticket_minimo then v_motivos := v_motivos || format('ticket_baixo:%s<%s', v_total, p.ticket_minimo); end if;
  end if;
  if l.prescricao_em is not null and l.prescricao_em < current_date then
    v_motivos := v_motivos || format('prescrito_em:%s', l.prescricao_em);
  end if;

  insert into public.lead_qualification (lead_id, office_id, passed, faixa, verbas, verbas_total, vinculo_meses, motivos, evaluated_by_actor, evaluated_at)
  values (p_lead, l.office_id, cardinality(v_motivos) = 0, public.faixa_ticket(l.office_id, coalesce(v_total, 0)),
          v_verbas, v_total, v_meses, v_motivos, p_actor, now())
  on conflict (lead_id) do update
    set passed = excluded.passed, faixa = excluded.faixa, verbas = excluded.verbas, verbas_total = excluded.verbas_total,
        vinculo_meses = excluded.vinculo_meses, motivos = excluded.motivos,
        evaluated_by_actor = excluded.evaluated_by_actor, evaluated_at = now()
  returning * into q;

  perform public.log_event(l.office_id, p_lead, 'qualification_evaluated', p_actor, p_actor_user, null,
    jsonb_build_object('passed', q.passed, 'faixa', q.faixa, 'total', q.verbas_total, 'motivos', to_jsonb(q.motivos)));
  return q;
end;
$$;

-- -----------------------------------------------------------------------------
-- Provas
-- -----------------------------------------------------------------------------

create table if not exists public.evidences (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  kind                text not null check (kind in ('documento','foto','audio','video','print','testemunha','outro')),
  title               text not null,
  description         text,
  storage_path        text,                                   -- bucket 'provas': office_id/lead_id/arquivo
  message_id          uuid references public.messages(id) on delete set null,
  status              text not null default 'solicitada' check (status in ('solicitada','recebida','validada','rejeitada')),
  requested_by_actor  text not null default 'ia' check (requested_by_actor in ('ia','humano','sistema')),
  validated_by        uuid references auth.users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists evidences_lead_idx on public.evidences(lead_id, created_at);
drop trigger if exists evidences_touch on public.evidences;
create trigger evidences_touch before update on public.evidences
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Contrato
-- -----------------------------------------------------------------------------

create table if not exists public.contracts (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  status              text not null default 'rascunho' check (status in ('rascunho','enviado','assinado','recusado','cancelado')),
  honorarios_percent  numeric not null,
  document_path       text,
  signature_provider  text,                                   -- ex.: 'clicksign','zapsign','manual'
  signature_ref       text,                                   -- id externo da assinatura
  sent_at             timestamptz,
  signed_at           timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index if not exists contracts_one_active_per_lead on public.contracts(lead_id)
  where status in ('rascunho','enviado','assinado');
drop trigger if exists contracts_touch on public.contracts;
create trigger contracts_touch before update on public.contracts
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Briefing (entrevista para a peça)
-- -----------------------------------------------------------------------------

create table if not exists public.briefings (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null unique references public.leads(id) on delete cascade,
  questions           jsonb not null default '[]'::jsonb,
  answers             jsonb not null default '{}'::jsonb,
  summary             text,
  status              text not null default 'em_andamento' check (status in ('em_andamento','concluido')),
  conducted_by_actor  text not null default 'ia' check (conducted_by_actor in ('ia','humano','sistema')),
  completed_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
drop trigger if exists briefings_touch on public.briefings;
create trigger briefings_touch before update on public.briefings
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Peça: modelos por tese e minutas
-- -----------------------------------------------------------------------------

create table if not exists public.piece_templates (
  id                uuid primary key default gen_random_uuid(),
  office_id         uuid references public.offices(id) on delete cascade,   -- null = global
  tese              text not null,
  name              text not null,
  body              text not null,                            -- placeholders {{campo}}
  required_evidence jsonb not null default '[]'::jsonb,       -- kinds/títulos esperados
  active            boolean not null default true,
  updated_at        timestamptz not null default now()
);
create unique index if not exists piece_templates_scope_uidx
  on public.piece_templates (coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), tese, name);

insert into public.piece_templates (office_id, tese, name, body, required_evidence) values
  (null, 'verbas_rescisorias', 'Reclamação trabalhista — verbas rescisórias',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DO DIREITO\n{{fundamentos}}\n\nIII. DOS PEDIDOS\n{{pedidos}}\n\nIV. DO VALOR DA CAUSA\n{{valor_causa}}\n\n{{fechamento}}',
   '["documento","print"]'),
  (null, 'horas_extras', 'Reclamação trabalhista — horas extras',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DA JORNADA\n{{jornada}}\n\nIII. DO DIREITO\n{{fundamentos}}\n\nIV. DOS PEDIDOS\n{{pedidos}}\n\n{{fechamento}}',
   '["documento","print","testemunha"]'),
  (null, 'rescisao_indireta', 'Reclamação trabalhista — rescisão indireta',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DAS FALTAS GRAVES DO EMPREGADOR\n{{faltas}}\n\nIII. DO DIREITO\n{{fundamentos}}\n\nIV. DOS PEDIDOS\n{{pedidos}}\n\n{{fechamento}}',
   '["documento","print","audio","testemunha"]'),
  (null, 'vinculo_empregaticio', 'Reclamação trabalhista — reconhecimento de vínculo',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DOS REQUISITOS DO VÍNCULO\n{{requisitos}}\n\nIII. DO DIREITO\n{{fundamentos}}\n\nIV. DOS PEDIDOS\n{{pedidos}}\n\n{{fechamento}}',
   '["print","foto","testemunha"]')
on conflict do nothing;

create table if not exists public.pieces (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  template_id         uuid references public.piece_templates(id),
  tese                text not null,
  content             text not null default '',
  status              text not null default 'rascunho' check (status in ('rascunho','revisao','aprovada','protocolada')),
  generated_by_actor  text not null default 'ia' check (generated_by_actor in ('ia','humano','sistema')),
  reviewed_by         uuid references auth.users(id),
  protocolo           text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists pieces_lead_idx on public.pieces(lead_id, created_at desc);
drop trigger if exists pieces_touch on public.pieces;
create trigger pieces_touch before update on public.pieces
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Fila de intervenção humana
-- -----------------------------------------------------------------------------

create table if not exists public.human_interventions (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  conversation_id     uuid references public.conversations(id) on delete set null,
  category            text not null default 'outro' check (category in ('duvida_juridica','fora_de_escopo','cliente_insatisfeito','pedido_de_humano','erro_ia','prescricao','outro')),
  reason              text not null,
  priority            integer not null default 2 check (priority between 1 and 3),   -- 1 = urgente
  status              text not null default 'pendente' check (status in ('pendente','em_atendimento','resolvida','cancelada')),
  requested_by_actor  text not null default 'ia' check (requested_by_actor in ('ia','humano','sistema')),
  claimed_by          uuid references auth.users(id),
  claimed_at          timestamptz,
  resolved_at         timestamptz,
  resolution          text,
  created_at          timestamptz not null default now()
);
create index if not exists human_interventions_queue_idx
  on public.human_interventions(office_id, priority, created_at) where status in ('pendente','em_atendimento');
create index if not exists human_interventions_lead_idx on public.human_interventions(lead_id);

-- A IA (via n8n) pede ajuda: entra na fila e pausa a conversa. Evento nomeia a IA.
create or replace function public.request_intervention(
  p_lead uuid, p_conversation uuid, p_category text, p_reason text,
  p_priority int default 2, p_actor text default 'ia', p_agent text default null
) returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  h public.human_interventions;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

  select * into h from public.human_interventions
   where lead_id = p_lead and status in ('pendente','em_atendimento') limit 1;
  if h.id is not null then return h; end if;

  insert into public.human_interventions (office_id, lead_id, conversation_id, category, reason, priority, requested_by_actor)
  values (l.office_id, p_lead, p_conversation, p_category, p_reason, p_priority, p_actor)
  returning * into h;

  if p_conversation is not null then
    update public.conversations set ai_paused = true, paused_at = now() where id = p_conversation and not ai_paused;
  end if;
  perform public.log_event(l.office_id, p_lead, 'intervention_requested', p_actor, null, p_agent,
    jsonb_build_object('intervention_id', h.id, 'category', p_category, 'reason', p_reason, 'priority', p_priority), p_conversation);
  return h;
end;
$$;

create or replace function public.claim_intervention(p_id uuid)
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'claim_intervention exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if h.status <> 'pendente' then return h; end if;
  update public.human_interventions set status = 'em_atendimento', claimed_by = auth.uid(), claimed_at = now()
   where id = p_id returning * into h;
  if h.conversation_id is not null then perform public.take_over(h.conversation_id); end if;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_claimed', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id), h.conversation_id);
  return h;
end;
$$;

create or replace function public.resolve_intervention(p_id uuid, p_resolution text, p_release_ai boolean default true)
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
     set status = 'resolvida', resolved_at = now(), resolution = p_resolution, claimed_by = coalesce(claimed_by, auth.uid())
   where id = p_id returning * into h;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_resolved', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'resolution', p_resolution, 'release_ai', p_release_ai), h.conversation_id);
  if p_release_ai and h.conversation_id is not null then perform public.release_to_ai(h.conversation_id); end if;
  return h;
end;
$$;

-- ai_should_reply ganha o domínio: caso encerrado ou intervenção aberta = IA cala.
create or replace function public.ai_should_reply(p_conversation uuid)
returns boolean
language sql stable
set search_path = public
as $$
  select coalesce((
    select c.status = 'open' and not c.ai_paused and o.active
       and l.phase <> 'encerrado'
       and not exists (select 1 from public.human_interventions h
                       where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))
    from public.conversations c
    join public.offices o on o.id = c.office_id
    join public.leads l on l.id = c.lead_id
    where c.id = p_conversation
  ), false);
$$;

-- -----------------------------------------------------------------------------
-- Efeitos estruturados do agente (n8n chama depois de cada resposta da IA)
-- Tudo aqui nomeia a IA como autor. A resposta em si é gravada em messages
-- pelo workflow, ANTES de qualquer envio.
-- -----------------------------------------------------------------------------

create or replace function public.apply_agent_effects(
  p_lead uuid,
  p_conversation uuid,
  p_agent_role text,
  p_case_data jsonb default null,
  p_advance_to text default null,
  p_advance_reason text default null,
  p_intervention jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

  if p_case_data is not null and jsonb_typeof(p_case_data) = 'object' and p_case_data <> '{}'::jsonb then
    insert into public.case_data (lead_id, office_id, updated_by_actor)
    values (p_lead, l.office_id, 'ia')
    on conflict (lead_id) do nothing;

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
      updated_by_actor      = 'ia'
    where d.lead_id = p_lead;
    v_result := v_result || jsonb_build_object('case_data_updated', true);
  end if;

  if p_advance_to is not null and p_advance_to <> '' then
    l := public.advance_phase(p_lead, p_advance_to::public.case_phase, 'ia', null, p_agent_role, p_advance_reason);
    v_result := v_result || jsonb_build_object('phase', l.phase);
  end if;

  if p_intervention is not null and jsonb_typeof(p_intervention) = 'object' then
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', p_agent_role);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- Custo de aquisição (derivado de messages.ai_meta, nunca digitado)
-- ai_meta esperado: {agent_role, model, tokens_in, tokens_out, cost_usd}
-- -----------------------------------------------------------------------------

create or replace view public.lead_acquisition_cost
with (security_invoker = true) as
select
  l.id as lead_id,
  l.office_id,
  count(m.id) filter (where m.sender = 'ia')                              as mensagens_ia,
  count(m.id) filter (where m.sender = 'humano')                          as mensagens_humano,
  coalesce(sum((m.ai_meta->>'tokens_in')::numeric), 0)                    as tokens_in,
  coalesce(sum((m.ai_meta->>'tokens_out')::numeric), 0)                   as tokens_out,
  coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0)                     as cost_usd
from public.leads l
left join public.conversations c on c.lead_id = l.id
left join public.messages m on m.conversation_id = c.id and m.direction = 'out'
group by l.id, l.office_id;

-- -----------------------------------------------------------------------------
-- Dossiê: o caso inteiro em uma chamada. security invoker => RLS decide.
-- -----------------------------------------------------------------------------

create or replace function public.lead_dossier(p_lead uuid)
returns jsonb
language sql stable
set search_path = public
as $$
  select jsonb_build_object(
    'lead', (select to_jsonb(l) from public.leads l where l.id = p_lead),
    'contact', (select to_jsonb(ct) from public.contacts ct join public.leads l on l.contact_id = ct.id where l.id = p_lead),
    'conversations', (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at), '[]'::jsonb) from public.conversations c where c.lead_id = p_lead),
    'case_data', (select to_jsonb(d) from public.case_data d where d.lead_id = p_lead),
    'qualification', (select to_jsonb(q) from public.lead_qualification q where q.lead_id = p_lead),
    'verbas', public.calc_verbas(p_lead),
    'evidences', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at), '[]'::jsonb) from public.evidences e where e.lead_id = p_lead),
    'contract', (select to_jsonb(k) from public.contracts k where k.lead_id = p_lead and k.status in ('rascunho','enviado','assinado') limit 1),
    'briefing', (select to_jsonb(b) from public.briefings b where b.lead_id = p_lead),
    'pieces', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb) from public.pieces p where p.lead_id = p_lead),
    'interventions', (select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc), '[]'::jsonb) from public.human_interventions h where h.lead_id = p_lead),
    'tasks', (select coalesce(jsonb_agg(to_jsonb(t) order by t.due_at nulls last), '[]'::jsonb) from public.tasks t where t.lead_id = p_lead),
    'events', (select coalesce(jsonb_agg(to_jsonb(ev) order by ev.created_at desc), '[]'::jsonb)
               from (select * from public.case_events where lead_id = p_lead order by created_at desc limit 300) ev),
    'cost', (select to_jsonb(ac) from public.lead_acquisition_cost ac where ac.lead_id = p_lead)
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------

select public.apply_office_rls('office_params', array['admin']);
select public.apply_office_rls('case_data');
select public.apply_office_rls('lead_qualification');
select public.apply_office_rls('evidences');
select public.apply_office_rls('contracts', array['admin','advogado']);
select public.apply_office_rls('briefings');
select public.apply_office_rls('pieces', array['admin','advogado']);
select public.apply_office_rls('human_interventions');

-- agents e piece_templates: globais (office_id null) legíveis por todos; override só do próprio escritório (admin)
alter table public.agents enable row level security;
drop policy if exists agents_select on public.agents;
create policy agents_select on public.agents for select to authenticated
  using (office_id is null or public.is_office_member(office_id));
drop policy if exists agents_write on public.agents;
create policy agents_write on public.agents for all to authenticated
  using (office_id is not null and public.member_role(office_id) = 'admin')
  with check (office_id is not null and public.member_role(office_id) = 'admin');

alter table public.piece_templates enable row level security;
drop policy if exists piece_templates_select on public.piece_templates;
create policy piece_templates_select on public.piece_templates for select to authenticated
  using (office_id is null or public.is_office_member(office_id));
drop policy if exists piece_templates_write on public.piece_templates;
create policy piece_templates_write on public.piece_templates for all to authenticated
  using (office_id is not null and public.member_role(office_id) in ('admin','advogado'))
  with check (office_id is not null and public.member_role(office_id) in ('admin','advogado'));

-- Cliente: lê dossiê, calcula, roda o portão, atende a fila. Fase só via 003 (ui_advance_phase).
grant execute on function public.lead_dossier(uuid) to authenticated;
grant execute on function public.calc_verbas(uuid) to authenticated;
grant execute on function public.faixa_ticket(uuid, numeric) to authenticated;
grant execute on function public.claim_intervention(uuid) to authenticated;
grant execute on function public.resolve_intervention(uuid, text, boolean) to authenticated;
revoke execute on function public.advance_phase(uuid, public.case_phase, text, uuid, text, text, text) from anon, authenticated;
revoke execute on function public.qualification_gate(uuid, text, uuid) from anon, authenticated;
revoke execute on function public.request_intervention(uuid, uuid, text, text, int, text, text) from anon, authenticated;
revoke execute on function public.agent_config(uuid, public.case_phase) from anon, authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb) from anon, authenticated;

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/003_caso_unico.sql

-- =============================================================================
-- 003_caso_unico.sql — Sprint 2: o caso como objeto único
--
-- O que a UI do Sprint 2 precisa e 001/002 não davam:
--   * profiles: nome de quem fez cada coisa (linha do tempo mostra pessoa, não uuid)
--   * ui_advance_phase(): kanban muda fase SEM poder forjar o autor
--   * v_case_cards: uma projeção de leads.phase para kanban, lista e busca,
--     com prescrição calculada contra office_params.alerta_prescricao_dias
--   * eventos automáticos de dados/provas (trigger), para a linha do tempo não ter buraco
--   * Realtime em leads, case_events, tasks e human_interventions
--   * lead_dossier() v2: inclui card, nomes dos autores e equipe do escritório
--   * bucket 'provas' com policy por escritório (só roda dentro do Supabase)
--
-- Idempotente. Depende de 001 e 002. Não altera migrations anteriores.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Perfis (espelho mínimo de auth.users, legível pela equipe)
-- -----------------------------------------------------------------------------

create table if not exists public.profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  avatar_url  text,
  updated_at  timestamptz not null default now()
);

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id, full_name, avatar_url)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(coalesce(new.email, ''), '@', 1)),
          new.raw_user_meta_data->>'avatar_url')
  on conflict (user_id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- backfill
insert into public.profiles (user_id, full_name)
select u.id, coalesce(u.raw_user_meta_data->>'full_name', split_part(coalesce(u.email, ''), '@', 1))
from auth.users u
on conflict (user_id) do nothing;

alter table public.profiles enable row level security;
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (user_id = auth.uid() or exists (
    select 1 from public.office_members a
    join public.office_members b on b.office_id = a.office_id
    where a.user_id = auth.uid() and b.user_id = profiles.user_id));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Ordem estável da linha do tempo (created_at empata dentro de uma transação)
-- -----------------------------------------------------------------------------

alter table public.case_events add column if not exists seq bigint generated always as identity;
create index if not exists case_events_lead_seq_idx on public.case_events(lead_id, seq desc);

-- -----------------------------------------------------------------------------
-- Fase pela UI: autor é sempre auth.uid(), actor sempre 'humano'
-- -----------------------------------------------------------------------------

create or replace function public.ui_advance_phase(p_lead uuid, p_to public.case_phase, p_reason text default null)
returns public.leads
language plpgsql security definer
set search_path = public
as $$
declare v_office uuid;
begin
  if auth.uid() is null then raise exception 'ui_advance_phase exige usuário autenticado'; end if;
  select office_id into v_office from public.leads where id = p_lead;
  if v_office is null or not public.is_office_member(v_office) then raise exception 'lead não encontrado'; end if;
  return public.advance_phase(p_lead, p_to, 'humano', auth.uid(), null, p_reason, 'equipe');
end;
$$;

create or replace function public.ui_qualification_gate(p_lead uuid)
returns public.lead_qualification
language plpgsql security definer
set search_path = public
as $$
declare v_office uuid;
begin
  if auth.uid() is null then raise exception 'ui_qualification_gate exige usuário autenticado'; end if;
  select office_id into v_office from public.leads where id = p_lead;
  if v_office is null or not public.is_office_member(v_office) then raise exception 'lead não encontrado'; end if;
  return public.qualification_gate(p_lead, 'humano', auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- Eventos automáticos: dados do caso e provas
-- -----------------------------------------------------------------------------

-- Quem edita case_data pela UI é humano (auth.uid()); pelo n8n é a IA (uid nulo).
create or replace function public.case_data_log_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_actor text := case when auth.uid() is not null then 'humano' else coalesce(new.updated_by_actor, 'ia') end;
  v_changed jsonb;
begin
  if tg_op = 'INSERT' then
    v_changed := to_jsonb(new) - 'lead_id' - 'office_id' - 'updated_at' - 'updated_by_actor';
  else
    select coalesce(jsonb_object_agg(n.key, n.value), '{}'::jsonb) into v_changed
    from jsonb_each(to_jsonb(new)) n
    left join jsonb_each(to_jsonb(old)) o on o.key = n.key
    where n.key not in ('updated_at','updated_by_actor') and n.value is distinct from o.value;
    if v_changed = '{}'::jsonb then return new; end if;
  end if;
  perform public.log_event(new.office_id, new.lead_id, 'case_data_updated', v_actor, auth.uid(), null,
    jsonb_build_object('fields', v_changed));
  return new;
end; $$;
drop trigger if exists case_data_log_event on public.case_data;
create trigger case_data_log_event after insert or update on public.case_data
  for each row execute function public.case_data_log_event();

create or replace function public.evidences_log_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor text := case when auth.uid() is not null then 'humano' else 'ia' end;
begin
  if tg_op = 'INSERT' then
    perform public.log_event(new.office_id, new.lead_id, 'evidence_added',
      case when auth.uid() is not null then 'humano' else new.requested_by_actor end, auth.uid(), null,
      jsonb_build_object('evidence_id', new.id, 'kind', new.kind, 'title', new.title, 'status', new.status));
  elsif new.status is distinct from old.status then
    perform public.log_event(new.office_id, new.lead_id, 'evidence_status_changed', v_actor, auth.uid(), null,
      jsonb_build_object('evidence_id', new.id, 'title', new.title, 'from', old.status, 'to', new.status));
  end if;
  return new;
end; $$;
drop trigger if exists evidences_log_event on public.evidences;
create trigger evidences_log_event after insert or update on public.evidences
  for each row execute function public.evidences_log_event();

create or replace function public.tasks_log_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null then return new; end if;
  if tg_op = 'INSERT' then
    perform public.log_event(new.office_id, new.lead_id, 'task_created',
      case when auth.uid() is not null then 'humano' else new.created_by_actor end, auth.uid(), null,
      jsonb_build_object('task_id', new.id, 'title', new.title, 'due_at', new.due_at));
  elsif new.done_at is not null and old.done_at is null then
    perform public.log_event(new.office_id, new.lead_id, 'task_done',
      case when auth.uid() is not null then 'humano' else 'sistema' end, auth.uid(), null,
      jsonb_build_object('task_id', new.id, 'title', new.title));
  end if;
  return new;
end; $$;
drop trigger if exists tasks_log_event on public.tasks;
create trigger tasks_log_event after insert or update on public.tasks
  for each row execute function public.tasks_log_event();

-- -----------------------------------------------------------------------------
-- Cards: a projeção única de leads.phase para kanban, lista e busca
-- -----------------------------------------------------------------------------

create or replace view public.v_case_cards
with (security_invoker = true) as
select
  l.id                                   as lead_id,
  l.office_id,
  l.phase,
  l.phase_changed_at,
  l.tese,
  l.assigned_to,
  l.closed_at, l.closed_by,
  l.created_at,
  ct.id                                  as contact_id,
  ct.name                                as contact_name,
  ct.wa_id                               as contact_phone,
  d.empresa,
  c.id                                   as conversation_id,
  c.ai_paused,
  c.last_message_at,
  c.last_message_preview,
  c.unread_count,
  q.passed                               as qualificado,
  q.faixa,
  q.verbas_total,
  l.prescricao_em,
  (l.prescricao_em - current_date)       as prescricao_dias,
  (l.prescricao_em is not null and l.prescricao_em < current_date)                                         as prescricao_vencida,
  (l.prescricao_em is not null and l.prescricao_em >= current_date
     and (l.prescricao_em - current_date) <= p.alerta_prescricao_dias)                                       as prescricao_alerta,
  exists (select 1 from public.human_interventions h
          where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))                             as intervencao_pendente,
  (select count(*) from public.tasks t where t.lead_id = l.id and t.done_at is null)                         as tarefas_abertas
from public.leads l
join public.contacts ct on ct.id = l.contact_id
left join public.office_params p on p.office_id = l.office_id
left join public.case_data d on d.lead_id = l.id
left join public.lead_qualification q on q.lead_id = l.id
left join lateral (
  select * from public.conversations cv where cv.lead_id = l.id
  order by cv.last_message_at desc nulls last limit 1
) c on true;

-- Busca simples (nome, telefone, empresa, tese). Sem pg_trgm de propósito.
create or replace function public.search_cases(p_office uuid, p_q text, p_limit int default 50)
returns setof public.v_case_cards
language sql stable
set search_path = public
as $$
  select * from public.v_case_cards v
  where v.office_id = p_office
    and (coalesce(p_q, '') = '' or
         v.contact_name ilike '%' || p_q || '%' or
         v.contact_phone ilike '%' || regexp_replace(p_q, '\D', '', 'g') || '%' and regexp_replace(p_q, '\D', '', 'g') <> '' or
         v.empresa ilike '%' || p_q || '%' or
         v.tese ilike '%' || p_q || '%')
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- Dossiê v2: card, nomes dos autores, equipe
-- -----------------------------------------------------------------------------

create or replace function public.lead_dossier(p_lead uuid)
returns jsonb
language sql stable
set search_path = public
as $$
  select jsonb_build_object(
    'lead', (select to_jsonb(l) from public.leads l where l.id = p_lead),
    'card', (select to_jsonb(v) from public.v_case_cards v where v.lead_id = p_lead),
    'contact', (select to_jsonb(ct) from public.contacts ct join public.leads l on l.contact_id = ct.id where l.id = p_lead),
    'conversations', (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at), '[]'::jsonb) from public.conversations c where c.lead_id = p_lead),
    'case_data', (select to_jsonb(d) from public.case_data d where d.lead_id = p_lead),
    'qualification', (select to_jsonb(q) from public.lead_qualification q where q.lead_id = p_lead),
    'verbas', public.calc_verbas(p_lead),
    'evidences', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at), '[]'::jsonb) from public.evidences e where e.lead_id = p_lead),
    'contract', (select to_jsonb(k) from public.contracts k where k.lead_id = p_lead and k.status in ('rascunho','enviado','assinado') limit 1),
    'briefing', (select to_jsonb(b) from public.briefings b where b.lead_id = p_lead),
    'pieces', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb) from public.pieces p where p.lead_id = p_lead),
    'interventions', (select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc), '[]'::jsonb) from public.human_interventions h where h.lead_id = p_lead),
    'tasks', (select coalesce(jsonb_agg(to_jsonb(t) order by t.due_at nulls last), '[]'::jsonb) from public.tasks t where t.lead_id = p_lead),
    'events', (select coalesce(jsonb_agg(
                 to_jsonb(ev) || jsonb_build_object('actor_name',
                   case ev.actor when 'humano' then coalesce(pr.full_name, 'Equipe')
                                 when 'ia' then coalesce(ag.name, 'IA')
                                 else 'Sistema' end)
                 order by ev.seq desc), '[]'::jsonb)
               from (select * from public.case_events where lead_id = p_lead order by seq desc limit 300) ev
               left join public.profiles pr on pr.user_id = ev.actor_user_id
               left join public.agents ag on ag.role = ev.actor_agent and ag.office_id is null),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'role', m.role, 'full_name', pr.full_name)), '[]'::jsonb)
                from public.office_members m
                left join public.profiles pr on pr.user_id = m.user_id
                where m.office_id = (select office_id from public.leads where id = p_lead)),
    'cost', (select to_jsonb(ac) from public.lead_acquisition_cost ac where ac.lead_id = p_lead),
    'params', (select jsonb_build_object('alerta_prescricao_dias', p.alerta_prescricao_dias, 'ticket_minimo', p.ticket_minimo,
                                         'vinculo_minimo_meses', p.vinculo_minimo_meses, 'honorarios_percent', p.honorarios_percent)
               from public.office_params p where p.office_id = (select office_id from public.leads where id = p_lead))
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- -----------------------------------------------------------------------------
-- Realtime: kanban, linha do tempo, tarefas e fila ao vivo
-- -----------------------------------------------------------------------------

select public.add_to_realtime('leads');
select public.add_to_realtime('case_events');
select public.add_to_realtime('tasks');
select public.add_to_realtime('human_interventions');
select public.add_to_realtime('evidences');

-- Realtime com RLS precisa de replica identity full para filtrar UPDATE/DELETE por linha
alter table public.leads replica identity full;
alter table public.conversations replica identity full;
alter table public.case_events replica identity full;

-- -----------------------------------------------------------------------------
-- Storage: bucket 'provas' (só existe dentro do Supabase)
-- -----------------------------------------------------------------------------

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_tables where schemaname = 'storage' and tablename = 'buckets') then
    insert into storage.buckets (id, name, public) values ('provas', 'provas', false) on conflict (id) do nothing;

    execute 'drop policy if exists provas_select on storage.objects';
    execute $p$create policy provas_select on storage.objects for select to authenticated
      using (bucket_id = 'provas' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
    execute 'drop policy if exists provas_insert on storage.objects';
    execute $p$create policy provas_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'provas' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
    execute 'drop policy if exists provas_delete on storage.objects';
    execute $p$create policy provas_delete on storage.objects for delete to authenticated
      using (bucket_id = 'provas' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant select on public.v_case_cards to authenticated;
grant execute on function public.ui_advance_phase(uuid, public.case_phase, text) to authenticated;
grant execute on function public.ui_qualification_gate(uuid) to authenticated;
grant execute on function public.search_cases(uuid, text, int) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/004_dashboard.sql

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
