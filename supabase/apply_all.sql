-- =============================================================================
-- apply_all.sql — 001..010 concatenadas, para colar de uma vez no SQL Editor do Supabase.
-- Idempotente. Gerado a partir dos arquivos individuais; não edite aqui.
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

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/005_funil.sql

-- =============================================================================
-- 005_funil.sql — Funil de Venda como o concorrente mostra
--
-- Quatro macro-etapas sobre a coorte de leads criados no mês:
--   novos_leads     todos os leads da coorte
--   abertura        leads que responderam 2+ mensagens (a "régua")
--   links_enviados  leads com contrato enviado (contracts.sent_at)
--   contratos       leads com contrato assinado
-- Para cada etapa: n, % do topo, conversão da etapa anterior e quantos leads
-- da etapa tiveram intervenção humana (fila ou takeover).
-- dashboard_funil() ganha a chave 'macro'; dashboard_funil_leads() lista os
-- leads de uma etapa (clique no card) como linhas de v_case_cards.
--
-- Idempotente. Depende de 001..004.
-- =============================================================================

-- Conjunto de leads de cada macro-etapa. security definer só para poder ser
-- usado dentro das RPCs; o resultado sempre é filtrado por RLS em quem chama.
create or replace function public.funil_stage_leads(p_office uuid, p_month date, p_member uuid, p_etapa text)
returns setof uuid
language sql stable
set search_path = public
as $$
  with b as (select * from public.month_bounds(p_month)),
  coorte as (
    select l.id from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  )
  select c.id from coorte c
  where case p_etapa
    when 'novos_leads' then true
    when 'abertura' then (
      select count(*) from public.messages m
      join public.conversations cv on cv.id = m.conversation_id
      where cv.lead_id = c.id and m.direction = 'in') >= 2
    when 'links_enviados' then exists (
      select 1 from public.contracts k where k.lead_id = c.id and k.sent_at is not null)
    when 'contratos' then exists (
      select 1 from public.contracts k where k.lead_id = c.id and k.status = 'assinado')
    else false end;
$$;

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
  fases as (select unnest(enum_range(null::public.case_phase)) as phase),
  alcancou as (
    select f.phase,
           (select count(distinct c.id) from coorte c
            where public.phase_order(c.phase) >= public.phase_order(f.phase)
               or exists (select 1 from public.case_events e
                          where e.lead_id = c.id and e.type = 'phase_changed'
                            and (e.payload->>'to')::public.case_phase = f.phase)) as n
    from fases f
  ),
  macro_def as (
    select * from (values
      (1, 'novos_leads',    'Novos leads',        null::text),
      (2, 'abertura',       'Taxa de abertura',   '2+ msgs'),
      (3, 'links_enviados', 'Links enviados',     null),
      (4, 'contratos',      'Contratos fechados', null)
    ) as v(ordem, etapa, titulo, regua)
  ),
  macro_n as (
    select d.ordem, d.etapa, d.titulo, d.regua,
           (select count(*) from public.funil_stage_leads(p_office, p_month, p_member, d.etapa)) as n,
           (select count(*) from public.funil_stage_leads(p_office, p_month, p_member, d.etapa) s
             where exists (select 1 from public.human_interventions h where h.lead_id = s)
                or exists (select 1 from public.case_events e where e.lead_id = s and e.type = 'takeover')) as interv_humana
    from macro_def d
  ),
  macro as (
    select m.*,
           lag(m.n) over (order by m.ordem) as n_anterior,
           first_value(m.n) over (order by m.ordem) as topo
    from macro_n m
  )
  select jsonb_build_object(
    'mes', to_char(date_trunc('month', p_month), 'YYYY-MM'),
    'leads', (select count(*) from coorte),
    'macro', (select coalesce(jsonb_agg(jsonb_build_object(
                'ordem', ordem, 'etapa', etapa, 'titulo', titulo, 'regua', regua,
                'n', n,
                'pct_topo', case when topo = 0 then 0 else round(n::numeric / topo * 100) end,
                'conv_etapa', case when n_anterior is null then null when n_anterior = 0 then 0 else round(n::numeric / n_anterior * 100) end,
                'interv_humana', interv_humana
              ) order by ordem), '[]'::jsonb) from macro),
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

-- Clique na etapa: os leads dela, como cards (respeita RLS via v_case_cards).
create or replace function public.dashboard_funil_leads(p_office uuid, p_etapa text, p_month date default current_date, p_member uuid default null, p_limit int default 200)
returns setof public.v_case_cards
language sql stable
set search_path = public
as $$
  select v.* from public.v_case_cards v
  where v.office_id = p_office
    and v.lead_id in (select public.funil_stage_leads(p_office, p_month, p_member, p_etapa))
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

grant execute on function public.funil_stage_leads(uuid, date, uuid, text) to authenticated;
grant execute on function public.dashboard_funil(uuid, date, uuid) to authenticated;
grant execute on function public.dashboard_funil_leads(uuid, text, date, uuid, int) to authenticated;

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/006_dashboard_periodo.sql

-- =============================================================================
-- 006_dashboard_periodo.sql — período livre e as abas como o concorrente mostra
--
--   * Período: todas as RPCs do dashboard ganham versão *_p(p_from, p_to);
--     as versões por mês viram atalhos. "Todo o período" = p_from nulo.
--   * Jornada do Cliente: sete etapas (uma por agente) com alcançaram, concluído,
--     em fluxo, intervenção humana e tempo médio na etapa; clique lista clientes.
--   * Produtividade Humana: fila de intervenção com desfecho ("por forma"),
--     tipo, ranking por pessoa e conclusões por dia.
--       - human_interventions.outcome (desfecho) e categorias novas
--       - resolve_intervention() ganha p_outcome
--   * Investimento Financeiro: gasto com anúncios (ad_spend) + tokens em BRL
--     (office_params.cambio_usd_brl), contratos e protocolos por dia.
--       - pieces.protocolado_em + trigger
--
-- Idempotente. Depende de 001..005.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Schema
-- -----------------------------------------------------------------------------

alter table public.office_params add column if not exists cambio_usd_brl numeric not null default 5.50;

create table if not exists public.ad_spend (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid not null references public.offices(id) on delete cascade,
  dia         date not null,
  canal       text not null default 'meta_ads' check (canal in ('meta_ads','google_ads','tiktok_ads','outro')),
  valor       numeric not null check (valor >= 0),
  nota        text,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  unique (office_id, dia, canal)
);
create index if not exists ad_spend_office_dia_idx on public.ad_spend(office_id, dia);
select public.apply_office_rls('ad_spend', array['admin','advogado']);
select public.add_to_realtime('ad_spend');

alter table public.pieces add column if not exists protocolado_em timestamptz;
create index if not exists pieces_protocolado_idx on public.pieces(office_id, protocolado_em) where status = 'protocolada';

create or replace function public.pieces_effects()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor text := case when auth.uid() is not null then 'humano' else coalesce(new.generated_by_actor, 'sistema') end;
begin
  if tg_op = 'INSERT' then
    perform public.log_event(new.office_id, new.lead_id, 'piece_created', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'tese', new.tese, 'status', new.status));
    return new;
  end if;
  if new.status is distinct from old.status then
    if new.status = 'protocolada' then
      new.protocolado_em := coalesce(new.protocolado_em, now());
    end if;
    perform public.log_event(new.office_id, new.lead_id, 'piece_status_changed', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'from', old.status, 'to', new.status, 'protocolo', new.protocolo));
  end if;
  return new;
end; $$;
drop trigger if exists pieces_effects on public.pieces;
create trigger pieces_effects before insert or update on public.pieces
  for each row execute function public.pieces_effects();

-- Fila: tipos do concorrente somados aos nossos, e o desfecho ("por forma")
alter table public.human_interventions drop constraint if exists human_interventions_category_check;
alter table public.human_interventions add constraint human_interventions_category_check
  check (category in (
    'duvida_juridica','fora_de_escopo','cliente_insatisfeito','pedido_de_humano','erro_ia','prescricao','outro',
    'agendamento','caso_escalado','follow_up_esgotado','seguir_conversa','contrato_nao_assinado_24h','ia_sem_resposta','cliente_ja_existente'
  ));
alter table public.human_interventions add column if not exists outcome text
  check (outcome is null or outcome in (
    'sanado','cliente_perdido','follow_up_agendado','cliente_retomado','reativado_para_agente',
    'assumido_pelo_humano','tarefa_cancelada','outro','nao_informada'
  ));
create index if not exists human_interventions_resolved_idx on public.human_interventions(office_id, resolved_at) where status = 'resolvida';

drop function if exists public.resolve_intervention(uuid, text, boolean);
create or replace function public.resolve_intervention(p_id uuid, p_resolution text, p_release_ai boolean default true, p_outcome text default 'nao_informada')
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
     set status = 'resolvida', resolved_at = now(), resolution = p_resolution,
         outcome = coalesce(p_outcome, 'nao_informada'), claimed_by = coalesce(claimed_by, auth.uid())
   where id = p_id returning * into h;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_resolved', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'resolution', p_resolution, 'outcome', h.outcome, 'release_ai', p_release_ai), h.conversation_id);
  if p_release_ai and h.conversation_id is not null then perform public.release_to_ai(h.conversation_id); end if;
  return h;
end;
$$;
grant execute on function public.resolve_intervention(uuid, text, boolean, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Período: [p_from, p_to] em dias, inclusivo. p_from nulo = desde o primeiro lead.
-- -----------------------------------------------------------------------------

create or replace function public.period_bounds(p_office uuid, p_from date, p_to date, out p_start timestamptz, out p_end timestamptz)
language sql stable set search_path = public as $$
  select coalesce(p_from, (select min(created_at)::date from public.leads where office_id = p_office), current_date)::timestamptz,
         (coalesce(p_to, current_date) + 1)::timestamptz;
$$;

-- -----------------------------------------------------------------------------
-- Geral (período)
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_geral_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  signed as (
    select k.*, l.assigned_to, ct.uf
    from public.contracts k
    join public.leads l on l.id = k.lead_id
    join public.contacts ct on ct.id = l.contact_id
    where k.office_id = p_office and k.status = 'assinado'
      and (p_member is null or l.assigned_to = p_member)
  ),
  in_p as (select s.* from signed s, b where s.signed_at >= b.p_start and s.signed_at < b.p_end),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'fechados', jsonb_build_object(
      'hoje',    (select count(*) from signed where signed_at::date = current_date),
      'semana',  (select count(*) from signed where signed_at >= date_trunc('week', now())),
      'mes',     (select count(*) from signed where signed_at >= date_trunc('month', now())),
      'periodo', (select count(*) from in_p)
    ),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object(
                  'dia', d.dia,
                  'contratos', (select count(*) from in_p m where m.signed_at::date = d.dia),
                  'valor_causa', (select coalesce(sum(valor_causa), 0) from in_p m where m.signed_at::date = d.dia)
                ) order by d.dia), '[]'::jsonb) from dias d),
    'por_uf', (select coalesce(jsonb_agg(jsonb_build_object('uf', uf, 'contratos', n) order by n desc), '[]'::jsonb)
               from (select coalesce(uf, '--') as uf, count(*) as n from in_p group by 1) t),
    'por_faixa', (select coalesce(jsonb_agg(jsonb_build_object('faixa', faixa, 'contratos', n, 'valor', v) order by
                    case faixa when 'alto' then 1 when 'medio' then 2 when 'baixo' then 3 else 4 end), '[]'::jsonb)
                  from (select coalesce(faixa, 'indefinida') as faixa, count(*) as n, coalesce(sum(valor_causa), 0) as v
                        from in_p group by 1) t),
    'total', jsonb_build_object('contratos', (select count(*) from in_p), 'valor', (select coalesce(sum(valor_causa), 0) from in_p))
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_geral(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_geral_p(p_office, date_trunc('month', p_month)::date,
                                  (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member);
$$;

-- -----------------------------------------------------------------------------
-- Funil (período)
-- -----------------------------------------------------------------------------

create or replace function public.funil_stage_leads_p(p_office uuid, p_from date, p_to date, p_member uuid, p_etapa text)
returns setof uuid
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  coorte as (
    select l.id from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  )
  select c.id from coorte c
  where case p_etapa
    when 'novos_leads' then true
    when 'abertura' then (select count(*) from public.messages m join public.conversations cv on cv.id = m.conversation_id
                          where cv.lead_id = c.id and m.direction = 'in') >= 2
    when 'links_enviados' then exists (select 1 from public.contracts k where k.lead_id = c.id and k.sent_at is not null)
    when 'contratos' then exists (select 1 from public.contracts k where k.lead_id = c.id and k.status = 'assinado')
    else false end;
$$;

create or replace function public.funil_stage_leads(p_office uuid, p_month date, p_member uuid, p_etapa text)
returns setof uuid language sql stable set search_path = public as $$
  select public.funil_stage_leads_p(p_office, date_trunc('month', p_month)::date,
                                    (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member, p_etapa);
$$;

create or replace function public.dashboard_funil_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  coorte as (
    select l.* from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  ),
  fases as (select unnest(enum_range(null::public.case_phase)) as phase),
  alcancou as (
    select f.phase,
           (select count(distinct c.id) from coorte c
            where public.phase_order(c.phase) >= public.phase_order(f.phase)
               or exists (select 1 from public.case_events e where e.lead_id = c.id and e.type = 'phase_changed'
                            and (e.payload->>'to')::public.case_phase = f.phase)) as n
    from fases f
  ),
  macro_def as (
    select * from (values
      (1, 'novos_leads',    'Novos leads',        null::text),
      (2, 'abertura',       'Taxa de abertura',   '2+ msgs'),
      (3, 'links_enviados', 'Links enviados',     null),
      (4, 'contratos',      'Contratos fechados', null)
    ) as v(ordem, etapa, titulo, regua)
  ),
  macro_n as (
    select d.ordem, d.etapa, d.titulo, d.regua,
           (select count(*) from public.funil_stage_leads_p(p_office, p_from, p_to, p_member, d.etapa)) as n,
           (select count(*) from public.funil_stage_leads_p(p_office, p_from, p_to, p_member, d.etapa) s
             where exists (select 1 from public.human_interventions h where h.lead_id = s)
                or exists (select 1 from public.case_events e where e.lead_id = s and e.type = 'takeover')) as interv_humana
    from macro_def d
  ),
  macro as (
    select m.*, lag(m.n) over (order by m.ordem) as n_anterior, first_value(m.n) over (order by m.ordem) as topo
    from macro_n m
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'leads', (select count(*) from coorte),
    'macro', (select coalesce(jsonb_agg(jsonb_build_object(
                'ordem', ordem, 'etapa', etapa, 'titulo', titulo, 'regua', regua, 'n', n,
                'pct_topo', case when topo = 0 then 0 else round(n::numeric / topo * 100) end,
                'conv_etapa', case when n_anterior is null then null when n_anterior = 0 then 0 else round(n::numeric / n_anterior * 100) end,
                'interv_humana', interv_humana) order by ordem), '[]'::jsonb) from macro),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object('fase', a.phase, 'alcancaram', a.n,
                 'taxa', case when (select count(*) from coorte) = 0 then 0 else round(a.n::numeric / (select count(*) from coorte) * 100, 1) end
               ) order by public.phase_order(a.phase)), '[]'::jsonb) from alcancou a where a.phase <> 'encerrado'),
    'atual', (select coalesce(jsonb_agg(jsonb_build_object('fase', phase, 'leads', n) order by public.phase_order(phase)), '[]'::jsonb)
              from (select phase, count(*) as n from coorte group by phase) t),
    'encerrados', jsonb_build_object(
      'ia',     (select count(*) from coorte where phase = 'encerrado' and closed_by = 'ia'),
      'equipe', (select count(*) from coorte where phase = 'encerrado' and closed_by = 'equipe')),
    'qualificacao', jsonb_build_object(
      'aprovados',  (select count(*) from coorte c join public.lead_qualification q on q.lead_id = c.id where q.passed),
      'reprovados', (select count(*) from coorte c join public.lead_qualification q on q.lead_id = c.id where not q.passed)),
    'contratos', (select count(*) from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado')
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_funil(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_funil_p(p_office, date_trunc('month', p_month)::date,
                                  (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member);
$$;

create or replace function public.dashboard_funil_leads_p(p_office uuid, p_etapa text, p_from date default null, p_to date default null, p_member uuid default null, p_limit int default 200)
returns setof public.v_case_cards
language sql stable set search_path = public as $$
  select v.* from public.v_case_cards v
  where v.office_id = p_office
    and v.lead_id in (select public.funil_stage_leads_p(p_office, p_from, p_to, p_member, p_etapa))
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- Jornada do Cliente: sete etapas, uma por agente
-- -----------------------------------------------------------------------------

-- fases de cada etapa/agente, na ordem da jornada
create or replace function public.journey_stages()
returns table(ordem int, role text, titulo text, fases public.case_phase[])
language sql immutable as $$
  values
    (1, 'recepcao',     'Recepção',     array['novo','triagem']::public.case_phase[]),
    (2, 'qualificacao', 'Qualificação', array['qualificacao']::public.case_phase[]),
    (3, 'provas',       'Provas',       array['provas']::public.case_phase[]),
    (4, 'calculo',      'Cálculo',      array['calculo']::public.case_phase[]),
    (5, 'contrato',     'Contrato',     array['contrato']::public.case_phase[]),
    (6, 'briefing',     'Briefing',     array['briefing']::public.case_phase[]),
    (7, 'redacao',      'Redação',      array['peca']::public.case_phase[]);
$$;

-- fase mais avançada que o lead já ocupou (ignora 'encerrado'; todo lead começa em 'novo')
create or replace function public.lead_max_phase_order(p_lead uuid)
returns int
language sql stable set search_path = public as $$
  select greatest(
    coalesce((select case when l.phase = 'encerrado' then 0 else public.phase_order(l.phase) end from public.leads l where l.id = p_lead), 0),
    coalesce((select max(public.phase_order(v.x::public.case_phase))
              from public.case_events e
              cross join lateral (values (e.payload->>'from'), (e.payload->>'to')) as v(x)
              where e.lead_id = p_lead and e.type = 'phase_changed' and v.x is not null and v.x <> 'encerrado'), 0)
  );
$$;

-- leads da coorte que chegaram à etapa (já ocuparam a primeira fase dela ou alguma posterior)
create or replace function public.journey_stage_leads_p(p_office uuid, p_from date, p_to date, p_member uuid, p_role text)
returns setof uuid
language sql stable set search_path = public as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  st as (select * from public.journey_stages() where role = p_role),
  coorte as (
    select l.id from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  )
  select c.id from coorte c, st
  where public.lead_max_phase_order(c.id) >= public.phase_order(st.fases[1]);
$$;

create or replace function public.dashboard_jornada_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  coorte as (
    select l.id, l.phase, l.created_at from public.leads l, b
    where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
      and (p_member is null or l.assigned_to = p_member)
  ),
  trocas as (
    select e.lead_id, (e.payload->>'from')::public.case_phase as fase, e.created_at,
           coalesce(lag(e.created_at) over (partition by e.lead_id order by e.seq), c.created_at) as inicio
    from public.case_events e join coorte c on c.id = e.lead_id
    where e.type = 'phase_changed'
  ),
  st as (
    select s.*,
      (select count(*) from public.journey_stage_leads_p(p_office, p_from, p_to, p_member, s.role)) as n,
      (select count(*) from coorte c where c.phase = any (s.fases)) as em_fluxo,
      (select count(*) from public.journey_stage_leads_p(p_office, p_from, p_to, p_member, s.role) x
        where public.lead_max_phase_order(x) > public.phase_order(s.fases[array_length(s.fases, 1)])) as concluido,
      (select count(distinct e.lead_id) from public.case_events e join coorte c on c.id = e.lead_id
        where e.type = 'intervention_requested' and e.actor_agent = s.role) as interv_humana,
      (select round((avg(extract(epoch from (t.created_at - t.inicio))) / 3600)::numeric, 1)
         from trocas t where t.fase = any (s.fases)) as tempo_medio_horas
    from public.journey_stages() s
  ),
  topo as (select coalesce(max(n) filter (where ordem = 1), 0) as n from st)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'leads', (select count(*) from coorte),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object(
                 'ordem', s.ordem, 'agente', s.role, 'titulo', s.titulo, 'fases', to_jsonb(s.fases),
                 'n', s.n, 'pct_topo', case when topo.n = 0 then 0 else round(s.n::numeric / topo.n * 100) end,
                 'concluido', s.concluido, 'em_fluxo', s.em_fluxo, 'interv_humana', s.interv_humana,
                 'tempo_medio_horas', s.tempo_medio_horas) order by s.ordem), '[]'::jsonb) from st s, topo),
    'primeira_resposta_min', (select round(avg(extract(epoch from (o - i)) / 60)::numeric, 1) from (
        select (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'in') as i,
               (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'out') as o
        from coorte c) t where o is not null and i is not null),
    'dias_ate_contrato', (select round(avg(extract(epoch from (k.signed_at - c.created_at)) / 86400)::numeric, 1)
                          from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado'),
    'mensagens_por_lead', (select round(avg(n)::numeric, 1) from (
        select count(m.id) as n from coorte c
        left join public.conversations cv on cv.lead_id = c.id
        left join public.messages m on m.conversation_id = cv.id group by c.id) t)
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_jornada(p_office uuid, p_month date default current_date, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_jornada_p(p_office, date_trunc('month', p_month)::date,
                                    (date_trunc('month', p_month) + interval '1 month - 1 day')::date, p_member);
$$;

create or replace function public.dashboard_jornada_leads_p(p_office uuid, p_agente text, p_from date default null, p_to date default null, p_member uuid default null, p_limit int default 200)
returns setof public.v_case_cards
language sql stable set search_path = public as $$
  select v.* from public.v_case_cards v
  where v.office_id = p_office
    and v.lead_id in (select public.journey_stage_leads_p(p_office, p_from, p_to, p_member, p_agente))
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- Produtividade Humana: a fila de intervenção
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_produtividade_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  concl as (
    select h.* from public.human_interventions h, b
    where h.office_id = p_office and h.status = 'resolvida'
      and h.resolved_at >= b.p_start and h.resolved_at < b.p_end
      and (p_member is null or h.claimed_by = p_member)
  ),
  nomes as (
    select om.user_id, coalesce(pr.full_name, 'Membro') as nome
    from public.office_members om left join public.profiles pr on pr.user_id = om.user_id
    where om.office_id = p_office
  ),
  ranking as (
    select c.claimed_by, coalesce(n.nome, 'Sem responsável') as nome, count(*) as concluidas,
           round((avg(extract(epoch from (c.resolved_at - c.created_at))) / 3600)::numeric, 1) as tempo_medio_horas
    from concl c left join nomes n on n.user_id = c.claimed_by
    group by c.claimed_by, n.nome
  ),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'concluidas', (select count(*) from concl),
    'em_andamento', (select count(*) from public.human_interventions h
                     where h.office_id = p_office and h.status = 'em_atendimento' and (p_member is null or h.claimed_by = p_member)),
    'pendentes', (select count(*) from public.human_interventions h where h.office_id = p_office and h.status = 'pendente'),
    'tempo_medio_horas', (select round((avg(extract(epoch from (resolved_at - created_at))) / 3600)::numeric, 1) from concl),
    'pessoas', (select count(distinct claimed_by) from concl where claimed_by is not null),
    'tipos', (select count(distinct category) from concl),
    'maior_produtor', (select jsonb_build_object('user_id', claimed_by, 'nome', nome, 'concluidas', concluidas)
                       from ranking order by concluidas desc limit 1),
    'por_forma', (select coalesce(jsonb_agg(jsonb_build_object('forma', forma, 'n', n,
                    'pct', case when (select count(*) from concl) = 0 then 0 else round(n::numeric / (select count(*) from concl) * 100) end) order by n desc), '[]'::jsonb)
                  from (select coalesce(outcome, 'nao_informada') as forma, count(*) as n from concl group by 1) t),
    'por_tipo', (select coalesce(jsonb_agg(jsonb_build_object('tipo', tipo, 'n', n,
                   'pct', case when (select count(*) from concl) = 0 then 0 else round(n::numeric / (select count(*) from concl) * 100) end) order by n desc), '[]'::jsonb)
                 from (select category as tipo, count(*) as n from concl group by 1) t),
    'ranking', (select coalesce(jsonb_agg(jsonb_build_object('user_id', claimed_by, 'nome', nome, 'concluidas', concluidas,
                  'tempo_medio_horas', tempo_medio_horas) order by concluidas desc), '[]'::jsonb) from ranking),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', d.dia,
                  'concluidas', (select count(*) from concl c where c.resolved_at::date = d.dia)) order by d.dia), '[]'::jsonb) from dias d),
    'membros', (select coalesce(jsonb_agg(jsonb_build_object(
                  'user_id', n.user_id, 'nome', n.nome,
                  'takeovers', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor_user_id = n.user_id and e.type = 'takeover' and e.created_at >= b.p_start and e.created_at < b.p_end),
                  'mensagens', (select count(*) from public.messages m, b where m.office_id = p_office and m.sent_by = n.user_id and m.created_at >= b.p_start and m.created_at < b.p_end),
                  'fases_movidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor_user_id = n.user_id and e.type = 'phase_changed' and e.created_at >= b.p_start and e.created_at < b.p_end),
                  'contratos_assinados', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor_user_id = n.user_id and e.type = 'contract_signed' and e.created_at >= b.p_start and e.created_at < b.p_end)
                ) order by n.nome), '[]'::jsonb) from nomes n),
    'ia', jsonb_build_object(
      'mensagens', (select count(*) from public.messages m, b where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end),
      'fases_movidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor = 'ia' and e.type = 'phase_changed' and e.created_at >= b.p_start and e.created_at < b.p_end),
      'intervencoes_pedidas', (select count(*) from public.case_events e, b where e.office_id = p_office and e.actor = 'ia' and e.type = 'intervention_requested' and e.created_at >= b.p_start and e.created_at < b.p_end))
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_produtividade(p_office uuid, p_month date default current_date)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_produtividade_p(p_office, date_trunc('month', p_month)::date,
                                          (date_trunc('month', p_month) + interval '1 month - 1 day')::date, null);
$$;

-- -----------------------------------------------------------------------------
-- Investimento Financeiro: Ads + tokens (BRL) x contratos e protocolos, dia a dia
-- -----------------------------------------------------------------------------

create or replace function public.dashboard_investimento_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b),
  tok as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd,
           coalesce(sum((m.ai_meta->>'tokens_in')::numeric), 0) as tin, coalesce(sum((m.ai_meta->>'tokens_out')::numeric), 0) as tout,
           count(*) as msgs
    from public.messages m, b
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end
    group by 1
  ),
  ads as (
    select a.dia, sum(a.valor) as brl from public.ad_spend a, b
    where a.office_id = p_office and a.dia >= b.p_start::date and a.dia < b.p_end::date group by 1
  ),
  ctr as (
    select k.signed_at::date as dia, count(*) as n from public.contracts k, b
    where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end group by 1
  ),
  prot as (
    select p.protocolado_em::date as dia, count(*) as n from public.pieces p, b
    where p.office_id = p_office and p.status = 'protocolada' and p.protocolado_em >= b.p_start and p.protocolado_em < b.p_end group by 1
  ),
  linha as (
    select d.dia,
           coalesce(a.brl, 0) as ads_brl,
           round(coalesce(t.usd, 0) * cambio.v, 2) as tokens_brl,
           coalesce(a.brl, 0) + round(coalesce(t.usd, 0) * cambio.v, 2) as investimento_brl,
           coalesce(c.n, 0) as contratos,
           coalesce(p.n, 0) as protocolos
    from dias d
    cross join cambio
    left join ads a on a.dia = d.dia
    left join tok t on t.dia = d.dia
    left join ctr c on c.dia = d.dia
    left join prot p on p.dia = d.dia
  ),
  tot as (
    select sum(ads_brl) as ads, sum(tokens_brl) as tokens, sum(investimento_brl) as inv, sum(contratos) as contratos, sum(protocolos) as protocolos
    from linha
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'cambio_usd_brl', (select v from cambio),
    'investimento_total_brl', (select round(inv, 2) from tot),
    'ads_brl', (select round(ads, 2) from tot),
    'tokens_brl', (select round(tokens, 2) from tot),
    'tokens_usd', (select round(coalesce(sum(usd), 0), 4) from tok),
    'tokens_in', (select coalesce(sum(tin), 0) from tok),
    'tokens_out', (select coalesce(sum(tout), 0) from tok),
    'mensagens_ia', (select coalesce(sum(msgs), 0) from tok),
    'contratos_fechados', (select contratos from tot),
    'custo_por_contrato_brl', (select case when contratos = 0 then null else round(inv / contratos, 2) end from tot),
    'protocolos', (select protocolos from tot),
    'custo_por_protocolo_brl', (select case when protocolos = 0 then null else round(inv / protocolos, 2) end from tot),
    'valor_causa_gerado', (select coalesce(sum(valor_causa), 0) from public.contracts k, b
                           where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end),
    'por_agente', (select coalesce(jsonb_agg(jsonb_build_object('agente', agente, 'mensagens', n, 'custo_usd', round(usd, 4), 'custo_brl', round(usd * (select v from cambio), 2)) order by usd desc), '[]'::jsonb)
                   from (select coalesce(m.ai_meta->>'agent_role', 'desconhecido') as agente, count(*) as n, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
                         from public.messages m, b where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end group by 1) t),
    'dia_a_dia', (select coalesce(jsonb_agg(jsonb_build_object(
                    'dia', dia, 'ads_brl', ads_brl, 'tokens_brl', tokens_brl, 'investimento_brl', investimento_brl,
                    'contratos', contratos, 'custo_por_contrato_brl', case when contratos = 0 then null else round(investimento_brl / contratos, 2) end,
                    'protocolos', protocolos, 'custo_por_protocolo_brl', case when protocolos = 0 then null else round(investimento_brl / protocolos, 2) end
                  ) order by dia desc), '[]'::jsonb) from linha)
  )
  from b
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_investimento(p_office uuid, p_month date default current_date)
returns jsonb language sql stable set search_path = public as $$
  select public.dashboard_investimento_p(p_office, date_trunc('month', p_month)::date,
                                         (date_trunc('month', p_month) + interval '1 month - 1 day')::date);
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant execute on function public.period_bounds(uuid, date, date) to authenticated;
grant execute on function public.dashboard_geral_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.funil_stage_leads_p(uuid, date, date, uuid, text) to authenticated;
grant execute on function public.dashboard_funil_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.dashboard_funil_leads_p(uuid, text, date, date, uuid, int) to authenticated;
grant execute on function public.journey_stages() to authenticated;
grant execute on function public.lead_max_phase_order(uuid) to authenticated;
grant execute on function public.journey_stage_leads_p(uuid, date, date, uuid, text) to authenticated;
grant execute on function public.dashboard_jornada_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.dashboard_jornada_leads_p(uuid, text, date, date, uuid, int) to authenticated;
grant execute on function public.dashboard_produtividade_p(uuid, date, date, uuid) to authenticated;
grant execute on function public.dashboard_investimento_p(uuid, date, date) to authenticated;

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/007_fila.sql

-- =============================================================================
-- 007_fila.sql — Intervenção humana como esteira (kanban por tipo de tarefa)
--
-- O card da fila precisa de: grupo (coluna), prioridade P1..P4, faixa de
-- ticket, marcadores ("frágil"), título e observação da IA, contadores de
-- ligações / mensagens / dias, responsável. E o topo precisa de busca e
-- filtro por responsável.
--
--   * human_interventions: priority 1..4, note, tags, calls_count, categorias novas
--   * intervention_group(category): a coluna de cada tipo (uma função, para UI e relatórios)
--   * v_intervention_cards: tudo que o card mostra, numa view (RLS via invoker)
--   * request_intervention() ganha p_note e p_tags; apply_agent_effects() repassa
--   * assign_intervention(), log_intervention_call()
--
-- Idempotente. Depende de 001..006.
-- =============================================================================

alter table public.human_interventions drop constraint if exists human_interventions_priority_check;
alter table public.human_interventions add constraint human_interventions_priority_check check (priority between 1 and 4);

alter table public.human_interventions add column if not exists note text;            -- observação da IA (itálico no card)
alter table public.human_interventions add column if not exists tags text[] not null default '{}';  -- 'fragil', 'reincidente', ...
alter table public.human_interventions add column if not exists calls_count int not null default 0;

alter table public.human_interventions drop constraint if exists human_interventions_category_check;
alter table public.human_interventions add constraint human_interventions_category_check
  check (category in (
    'duvida_juridica','fora_de_escopo','cliente_insatisfeito','pedido_de_humano','erro_ia','prescricao','outro',
    'agendamento','caso_escalado','follow_up_esgotado','seguir_conversa','contrato_nao_assinado_24h','ia_sem_resposta','cliente_ja_existente',
    'saneamento_juridico','spam','caso_parado'
  ));

-- Coluna da esteira para cada tipo. Ordem = ordem das colunas.
create or replace function public.intervention_group(p_category text)
returns table(grupo text, titulo text, ordem int)
language sql immutable as $$
  select * from (values
    ('seguir_conversa', 'Seguir conversa', 1),
    ('follow',          'Follow',          2),
    ('agendamento',     'Agendamento',     3),
    ('saneamento',      'Saneamento',      4),
    ('avisos',          'Avisos',          5),
    ('suporte_spam',    'Suporte/Spam',    6),
    ('escalados',       'Escalados',       7)
  ) as g(grupo, titulo, ordem)
  where g.grupo = case p_category
    when 'seguir_conversa' then 'seguir_conversa'
    when 'caso_parado' then 'seguir_conversa'
    when 'follow_up_esgotado' then 'follow'
    when 'contrato_nao_assinado_24h' then 'follow'
    when 'agendamento' then 'agendamento'
    when 'saneamento_juridico' then 'saneamento'
    when 'ia_sem_resposta' then 'avisos'
    when 'prescricao' then 'avisos'
    when 'erro_ia' then 'avisos'
    when 'cliente_ja_existente' then 'suporte_spam'
    when 'spam' then 'suporte_spam'
    when 'fora_de_escopo' then 'suporte_spam'
    else 'escalados' end;
$$;

-- request_intervention com observação e marcadores (substitui a assinatura antiga)
drop function if exists public.request_intervention(uuid, uuid, text, text, int, text, text);
create or replace function public.request_intervention(
  p_lead uuid, p_conversation uuid, p_category text, p_reason text,
  p_priority int default 2, p_actor text default 'ia', p_agent text default null,
  p_note text default null, p_tags text[] default null
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

  insert into public.human_interventions (office_id, lead_id, conversation_id, category, reason, priority, requested_by_actor, note, tags)
  values (l.office_id, p_lead, p_conversation, p_category, p_reason, least(greatest(coalesce(p_priority, 2), 1), 4), p_actor, p_note, coalesce(p_tags, '{}'))
  returning * into h;

  if p_conversation is not null then
    update public.conversations set ai_paused = true, paused_at = now() where id = p_conversation and not ai_paused;
  end if;
  perform public.log_event(l.office_id, p_lead, 'intervention_requested', p_actor, null, p_agent,
    jsonb_build_object('intervention_id', h.id, 'category', p_category, 'reason', p_reason, 'priority', h.priority, 'tags', to_jsonb(h.tags)), p_conversation);
  return h;
end;
$$;
revoke execute on function public.request_intervention(uuid, uuid, text, text, int, text, text, text, text[]) from anon, authenticated;

-- apply_agent_effects repassa note/tags da intervenção pedida pelo agente
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

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
      updated_by_actor      = 'ia'
    where d.lead_id = p_lead;
    v_result := v_result || jsonb_build_object('case_data_updated', true);
  end if;

  if p_advance_to is not null and p_advance_to <> '' then
    l := public.advance_phase(p_lead, p_advance_to::public.case_phase, 'ia', null, p_agent_role, p_advance_reason);
    v_result := v_result || jsonb_build_object('phase', l.phase);
  end if;

  if p_intervention is not null and jsonb_typeof(p_intervention) = 'object' then
    if jsonb_typeof(p_intervention->'tags') = 'array' then
      select array_agg(x) into v_tags from jsonb_array_elements_text(p_intervention->'tags') x;
    end if;
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', p_agent_role,
           p_intervention->>'note', v_tags);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  return v_result;
end;
$$;

-- Atribuir a um membro (sem precisar ser quem clica). Assume a conversa em nome dele.
create or replace function public.assign_intervention(p_id uuid, p_user uuid)
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'assign_intervention exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if p_user is not null and not exists (select 1 from public.office_members where office_id = h.office_id and user_id = p_user) then
    raise exception 'usuário não é membro do escritório';
  end if;
  if h.status in ('resolvida','cancelada') then return h; end if;
  update public.human_interventions
     set claimed_by = p_user, claimed_at = case when p_user is null then null else now() end,
         status = case when p_user is null then 'pendente' else 'em_atendimento' end
   where id = p_id returning * into h;
  if p_user is not null and h.conversation_id is not null then perform public.take_over(h.conversation_id, p_user); end if;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_assigned', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'assigned_to', p_user), h.conversation_id);
  return h;
end;
$$;

-- "Lig": registra uma ligação feita para o lead
create or replace function public.log_intervention_call(p_id uuid, p_note text default null)
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'log_intervention_call exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  update public.human_interventions set calls_count = calls_count + 1 where id = p_id returning * into h;
  perform public.log_event(h.office_id, h.lead_id, 'call_logged', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'note', p_note, 'calls_count', h.calls_count), h.conversation_id);
  return h;
end;
$$;

-- O card inteiro
create or replace view public.v_intervention_cards
with (security_invoker = true) as
select
  h.id, h.office_id, h.lead_id, h.conversation_id,
  h.category, g.grupo, g.titulo as grupo_titulo, g.ordem as grupo_ordem,
  h.reason, h.note, h.tags, h.priority, h.status, h.requested_by_actor,
  h.claimed_by, pr.full_name as responsavel_nome, h.claimed_at, h.resolved_at, h.outcome, h.created_at,
  ct.name as contact_name, ct.wa_id as contact_phone,
  l.phase, q.faixa, q.verbas_total, l.prescricao_em,
  h.calls_count,
  (select count(*) from public.messages m where m.conversation_id = h.conversation_id and m.created_at >= h.created_at) as msgs_count,
  (current_date - h.created_at::date) as dias
from public.human_interventions h
join public.leads l on l.id = h.lead_id
join public.contacts ct on ct.id = l.contact_id
left join public.lead_qualification q on q.lead_id = l.id
left join public.profiles pr on pr.user_id = h.claimed_by
cross join lateral public.intervention_group(h.category) g;

grant select on public.v_intervention_cards to authenticated;
grant execute on function public.intervention_group(text) to authenticated;
grant execute on function public.assign_intervention(uuid, uuid) to authenticated;
grant execute on function public.log_intervention_call(uuid, text) to authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb) from anon, authenticated;

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/008_configuracoes.sql

-- =============================================================================
-- 008_configuracoes.sql — Sprint 3: Configurações no layout do concorrente
--
-- 1. Empresa: dados cadastrais do escritório (CNPJ, OAB, fundador, endereço,
--    e-mail, telefone, WhatsApp comercial, telefone do suporte) e do perfil.
-- 2. Integrações por provedor (mensageria, assinatura, armazenamento, LLM,
--    transcrição). O segredo vai para o Vault; a tabela guarda só o nome.
--    Só RPCs escrevem (admin); o cliente nunca lê o segredo. O n8n resolve
--    com service_role e registra o resultado do teste.
-- 3. Modelos de petição = biblioteca de arquivos do escritório (bucket
--    'modelos'), sem limite de quantidade, com ATIVO e OBRIGATÓRIO.
-- 4. Prompts dos agentes e esqueletos internos ficam fora do alcance do
--    cliente: agents.system_prompt vai para agent_prompts (sem policy) e
--    piece_templates perde as policies. Só service_role (n8n) lê.
--
-- Idempotente. Rodar depois de 007.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Empresa e perfil
-- -----------------------------------------------------------------------------

alter table public.offices
  add column if not exists tipo               text not null default 'escritorio' check (tipo in ('escritorio','autonomo','departamento')),
  add column if not exists cnpj               text,
  add column if not exists oab_responsavel    text,
  add column if not exists fundador           text,
  add column if not exists fundacao           date,
  add column if not exists endereco           text,
  add column if not exists cidade             text,
  add column if not exists uf                 text,
  add column if not exists email              text,
  add column if not exists telefone           text,
  add column if not exists whatsapp_comercial text,
  add column if not exists telefone_suporte   text,
  add column if not exists site               text,
  add column if not exists logo_path          text,
  add column if not exists updated_at         timestamptz not null default now();

drop trigger if exists offices_touch on public.offices;
create trigger offices_touch before update on public.offices
  for each row execute function public.touch_updated_at();

alter table public.profiles
  add column if not exists phone text,
  add column if not exists oab   text,
  add column if not exists cargo text;

-- -----------------------------------------------------------------------------
-- 2. Integrações
-- -----------------------------------------------------------------------------

-- Catálogo (global): o que a tela de Integrações oferece e que campos avançados cada um tem.
create table if not exists public.integration_catalog (
  provider      text primary key,
  kind          text not null check (kind in ('mensageria','assinatura','armazenamento','llm','llm_admin','transcricao','transcricao_admin')),
  label         text not null,
  description   text not null default '',
  secret_label  text not null default 'Chave de API',
  config_fields jsonb not null default '[]'::jsonb,   -- [{key,label,type,placeholder,required}]
  docs_url      text,
  ordem         int not null default 100
);

insert into public.integration_catalog (provider, kind, label, description, secret_label, config_fields, docs_url, ordem) values
  ('meta_whatsapp', 'mensageria', 'WhatsApp Cloud API (Meta)', 'Número oficial do WhatsApp Business. Recebe e envia as mensagens dos leads.', 'Token permanente do sistema',
   '[{"key":"phone_number_id","label":"Phone number ID","type":"text","required":true},{"key":"waba_id","label":"WABA ID","type":"text","required":false},{"key":"display_phone","label":"Número exibido","type":"text","placeholder":"5511999999999","required":false}]',
   'https://developers.facebook.com/docs/whatsapp/cloud-api', 10),
  ('datacrazy', 'mensageria', 'Datacrazy', 'Mensageria alternativa por API. Uma mensageria ativa por vez.', 'Chave de API',
   '[{"key":"instance_url","label":"URL da instância","type":"url","required":true},{"key":"instance_name","label":"Nome da instância","type":"text","required":false}]',
   null, 20),
  ('autentique', 'assinatura', 'Autentique', 'Assinatura eletrônica do contrato de honorários.', 'Token da API',
   '[{"key":"sandbox","label":"Ambiente de testes","type":"boolean","required":false}]',
   'https://docs.autentique.com.br', 30),
  ('google_drive', 'armazenamento', 'Google Drive / Docs', 'Pasta do escritório para contratos, peças e provas exportadas.', 'Credencial (JSON da conta de serviço ou refresh token)',
   '[{"key":"folder_id","label":"ID da pasta raiz","type":"text","required":true}]',
   'https://developers.google.com/drive', 40),
  ('anthropic', 'llm', 'Anthropic', 'Modelo dos agentes de atendimento.', 'Chave de API',
   '[{"key":"model","label":"Modelo padrão","type":"text","placeholder":"claude-sonnet-5","required":false}]',
   'https://docs.anthropic.com', 50),
  ('anthropic_admin', 'llm_admin', 'Anthropic Admin', 'Chave administrativa para ler uso e custo por token.', 'Admin API key',
   '[]', 'https://docs.anthropic.com', 60),
  ('openai_whisper', 'transcricao', 'OpenAI Whisper', 'Transcrição dos áudios recebidos no WhatsApp.', 'Chave de API',
   '[{"key":"model","label":"Modelo","type":"text","placeholder":"whisper-1","required":false},{"key":"language","label":"Idioma","type":"text","placeholder":"pt","required":false}]',
   'https://platform.openai.com/docs', 70),
  ('openai_admin', 'transcricao_admin', 'OpenAI Admin', 'Chave administrativa para ler uso e custo da transcrição.', 'Admin API key',
   '[]', 'https://platform.openai.com/docs', 80)
on conflict (provider) do update set
  kind = excluded.kind, label = excluded.label, description = excluded.description,
  secret_label = excluded.secret_label, config_fields = excluded.config_fields, docs_url = excluded.docs_url, ordem = excluded.ordem;

create table if not exists public.integrations (
  id                 uuid primary key default gen_random_uuid(),
  office_id          uuid not null references public.offices(id) on delete cascade,
  provider           text not null references public.integration_catalog(provider),
  kind               text not null,
  active             boolean not null default false,
  -- Nome do segredo no Vault (vault.secrets.name). O valor NUNCA passa por aqui.
  secret_name        text,
  secret_set_at      timestamptz,
  config             jsonb not null default '{}'::jsonb,
  status             text not null default 'nao_testado' check (status in ('nao_testado','teste_solicitado','validado','falhou')),
  test_requested_at  timestamptz,
  tested_at          timestamptz,
  last_error         text,
  updated_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (office_id, provider)
);
create index if not exists integrations_office_idx on public.integrations(office_id, kind);
-- Uma mensageria e uma assinatura ativas por escritório.
create unique index if not exists integrations_one_active_uidx
  on public.integrations (office_id, kind) where active and kind in ('mensageria','assinatura');
drop trigger if exists integrations_touch on public.integrations;
create trigger integrations_touch before update on public.integrations
  for each row execute function public.touch_updated_at();

-- Projeção pública da integração (sem nome nem valor do segredo).
create or replace function public.integration_public(i public.integrations)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'id', i.id, 'office_id', i.office_id, 'provider', i.provider, 'kind', i.kind,
    'active', i.active, 'has_secret', i.secret_name is not null, 'secret_set_at', i.secret_set_at,
    'config', i.config, 'status', i.status, 'tested_at', i.tested_at, 'last_error', i.last_error,
    'updated_at', i.updated_at);
$$;

create or replace function public.integration_secret_name(p_office uuid, p_provider text)
returns text language sql immutable as $$
  select 'int_' || p_provider || '_' || replace(p_office::text, '-', '');
$$;

-- Salvar (admin): cria/atualiza a integração; segredo vai para o Vault.
create or replace function public.set_integration(
  p_office uuid, p_provider text, p_secret text default null, p_config jsonb default null, p_active boolean default null)
returns jsonb
language plpgsql security definer set search_path = public, vault
as $$
declare
  v_kind text; v_name text; v_vault uuid; i public.integrations;
begin
  if public.member_role(p_office) is distinct from 'admin' then
    raise exception 'apenas admin do escritório altera integrações' using errcode = '42501';
  end if;
  select kind into v_kind from public.integration_catalog where provider = p_provider;
  if v_kind is null then raise exception 'provedor desconhecido: %', p_provider; end if;

  insert into public.integrations (office_id, provider, kind, updated_by)
  values (p_office, p_provider, v_kind, auth.uid())
  on conflict (office_id, provider) do update set updated_by = auth.uid()
  returning * into i;

  if p_secret is not null and length(trim(p_secret)) > 0 then
    v_name := public.integration_secret_name(p_office, p_provider);
    select id into v_vault from vault.secrets where name = v_name;
    if v_vault is null then
      perform vault.create_secret(p_secret, v_name, 'integração ' || p_provider || ' do escritório ' || p_office::text);
    else
      perform vault.update_secret(v_vault, p_secret);
    end if;
    update public.integrations set secret_name = v_name, secret_set_at = now(), status = 'nao_testado', last_error = null
     where id = i.id;
  end if;

  if p_config is not null then
    update public.integrations set config = p_config where id = i.id;
  end if;

  if p_active is not null then
    if p_active and v_kind in ('mensageria','assinatura') then
      update public.integrations set active = false where office_id = p_office and kind = v_kind and id <> i.id and active;
    end if;
    update public.integrations set active = p_active where id = i.id;
  end if;

  select * into i from public.integrations where id = i.id;

  -- Meta: o número passa a apontar para este segredo (whatsapp_numbers continua a fonte do webhook)
  if p_provider = 'meta_whatsapp' and i.secret_name is not null and coalesce(i.config->>'phone_number_id', '') <> '' then
    insert into public.whatsapp_numbers (office_id, phone_number_id, waba_id, display_phone, token_secret_name, active)
    values (p_office, i.config->>'phone_number_id', i.config->>'waba_id', i.config->>'display_phone', i.secret_name, i.active)
    on conflict (phone_number_id) do update set
      office_id = excluded.office_id, waba_id = coalesce(excluded.waba_id, public.whatsapp_numbers.waba_id),
      display_phone = coalesce(excluded.display_phone, public.whatsapp_numbers.display_phone),
      token_secret_name = excluded.token_secret_name, active = excluded.active;
  end if;

  return public.integration_public(i);
end; $$;

-- Remover (admin): apaga a linha e o segredo do Vault.
create or replace function public.remove_integration(p_office uuid, p_provider text)
returns void
language plpgsql security definer set search_path = public, vault
as $$
declare i public.integrations;
begin
  if public.member_role(p_office) is distinct from 'admin' then
    raise exception 'apenas admin do escritório altera integrações' using errcode = '42501';
  end if;
  select * into i from public.integrations where office_id = p_office and provider = p_provider;
  if i.id is null then return; end if;
  if i.secret_name is not null then
    update public.whatsapp_numbers set active = false where office_id = p_office and token_secret_name = i.secret_name;
    delete from vault.secrets where name = i.secret_name;
  end if;
  delete from public.integrations where id = i.id;
end; $$;

-- Testar (admin): marca o pedido; o n8n (webhook em integrations UPDATE) executa e responde.
create or replace function public.request_integration_test(p_office uuid, p_provider text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if public.member_role(p_office) is distinct from 'admin' then
    raise exception 'apenas admin do escritório altera integrações' using errcode = '42501';
  end if;
  update public.integrations set status = 'teste_solicitado', test_requested_at = now(), last_error = null
   where office_id = p_office and provider = p_provider and secret_name is not null
  returning id into v_id;
  if v_id is null then raise exception 'salve o segredo antes de testar'; end if;
  return v_id;
end; $$;

-- Resultado do teste (n8n, service_role).
create or replace function public.integration_tested(p_id uuid, p_ok boolean, p_error text default null)
returns void
language sql security definer set search_path = public
as $$
  update public.integrations
     set status = case when p_ok then 'validado' else 'falhou' end,
         tested_at = now(), last_error = case when p_ok then null else left(p_error, 500) end
   where id = p_id;
$$;

-- Segredo em claro (n8n, service_role). Nunca para o cliente.
create or replace function public.integration_secret(p_office uuid, p_provider text)
returns text
language sql stable security definer set search_path = public, vault
as $$
  select d.decrypted_secret
  from public.integrations i
  join vault.decrypted_secrets d on d.name = i.secret_name
  where i.office_id = p_office and i.provider = p_provider;
$$;

-- Provedor ativo de um tipo (UI e n8n).
create or replace function public.active_integration(p_office uuid, p_kind text)
returns text language sql stable set search_path = public as $$
  select provider from public.integrations where office_id = p_office and kind = p_kind and active
  order by updated_at desc limit 1;
$$;

-- -----------------------------------------------------------------------------
-- 3. Modelos de petição: biblioteca de arquivos
-- -----------------------------------------------------------------------------

create table if not exists public.piece_models (
  id           uuid primary key default gen_random_uuid(),
  office_id    uuid not null references public.offices(id) on delete cascade,
  name         text not null,
  category     text not null default 'geral',      -- 'geral' ou a tese (verbas_rescisorias, horas_extras, ...)
  description  text,
  file_path    text not null,                      -- bucket 'modelos': <office_id>/<uuid>-<arquivo>
  mime_type    text,
  size_bytes   bigint,
  required     boolean not null default false,     -- OBRIGATÓRIO: entra em toda peça
  active       boolean not null default true,      -- ATIVO
  uploaded_by  uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists piece_models_office_idx on public.piece_models(office_id, active, category);
drop trigger if exists piece_models_touch on public.piece_models;
create trigger piece_models_touch before update on public.piece_models
  for each row execute function public.touch_updated_at();

-- Modelos que entram numa peça: os obrigatórios + os da tese (+ 'geral' quando a tese não tem nenhum).
create or replace function public.piece_models_for(p_office uuid, p_tese text)
returns setof public.piece_models
language sql stable set search_path = public as $$
  select * from public.piece_models
  where office_id = p_office and active
    and (required or category = p_tese
         or (category = 'geral' and not exists (select 1 from public.piece_models m2 where m2.office_id = p_office and m2.active and m2.category = p_tese)))
  order by required desc, name;
$$;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_tables where schemaname = 'storage' and tablename = 'buckets') then
    insert into storage.buckets (id, name, public) values ('modelos', 'modelos', false) on conflict (id) do nothing;
    execute 'drop policy if exists modelos_select on storage.objects';
    execute $p$create policy modelos_select on storage.objects for select to authenticated
      using (bucket_id = 'modelos' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
    execute 'drop policy if exists modelos_insert on storage.objects';
    execute $p$create policy modelos_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'modelos' and public.member_role((storage.foldername(name))[1]::uuid) in ('admin','advogado'))$p$;
    execute 'drop policy if exists modelos_update on storage.objects';
    execute $p$create policy modelos_update on storage.objects for update to authenticated
      using (bucket_id = 'modelos' and public.member_role((storage.foldername(name))[1]::uuid) in ('admin','advogado'))$p$;
    execute 'drop policy if exists modelos_delete on storage.objects';
    execute $p$create policy modelos_delete on storage.objects for delete to authenticated
      using (bucket_id = 'modelos' and public.member_role((storage.foldername(name))[1]::uuid) in ('admin','advogado'))$p$;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 4. Prompts e esqueletos internos fora do alcance do cliente
-- -----------------------------------------------------------------------------

create table if not exists public.agent_prompts (
  agent_id      uuid primary key references public.agents(id) on delete cascade,
  system_prompt text not null default '',
  updated_at    timestamptz not null default now()
);

-- migra o que existir na coluna antiga e a remove
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'agents' and column_name = 'system_prompt') then
    insert into public.agent_prompts (agent_id, system_prompt)
    select id, system_prompt from public.agents
    on conflict (agent_id) do update set system_prompt = excluded.system_prompt;
    alter table public.agents drop column system_prompt;
  end if;
end $$;
insert into public.agent_prompts (agent_id) select id from public.agents on conflict do nothing;

-- Config completa do agente (n8n): linha de agents + prompt. Service_role apenas.
create or replace function public.agent_config_full(p_office uuid, p_phase public.case_phase)
returns jsonb
language sql stable security definer set search_path = public as $$
  -- override do escritório sem prompt próprio herda o prompt do agente global do mesmo papel
  select to_jsonb(a) || jsonb_build_object('system_prompt',
           coalesce(nullif(p.system_prompt, ''),
                    (select g.system_prompt from public.agents ga join public.agent_prompts g on g.agent_id = ga.id
                      where ga.office_id is null and ga.role = a.role),
                    ''))
  from public.agent_config(p_office, p_phase) a
  left join public.agent_prompts p on p.agent_id = a.id;
$$;

-- RLS ligado e sem policy = invisível para o cliente; service_role passa por cima.
alter table public.agent_prompts enable row level security;
drop policy if exists piece_templates_select on public.piece_templates;
drop policy if exists piece_templates_write on public.piece_templates;
alter table public.piece_templates enable row level security;

-- -----------------------------------------------------------------------------
-- RLS e grants
-- -----------------------------------------------------------------------------

alter table public.integration_catalog enable row level security;
drop policy if exists integration_catalog_select on public.integration_catalog;
create policy integration_catalog_select on public.integration_catalog for select to authenticated using (true);

-- integrations: membros leem (sem segredo); escrita só pelas RPCs acima
alter table public.integrations enable row level security;
drop policy if exists integrations_select on public.integrations;
create policy integrations_select on public.integrations for select to authenticated
  using (public.is_office_member(office_id));
drop policy if exists integrations_insert on public.integrations;
drop policy if exists integrations_update on public.integrations;
drop policy if exists integrations_delete on public.integrations;

select public.apply_office_rls('piece_models', array['admin','advogado']);

grant execute on function public.set_integration(uuid, text, text, jsonb, boolean) to authenticated;
grant execute on function public.remove_integration(uuid, text) to authenticated;
grant execute on function public.request_integration_test(uuid, text) to authenticated;
grant execute on function public.active_integration(uuid, text) to authenticated;
grant execute on function public.piece_models_for(uuid, text) to authenticated;
grant execute on function public.integration_public(public.integrations) to authenticated;

revoke execute on function public.integration_secret(uuid, text) from public, anon, authenticated;
revoke execute on function public.integration_tested(uuid, boolean, text) from public, anon, authenticated;
revoke execute on function public.agent_config_full(uuid, public.case_phase) from public, anon, authenticated;
grant execute on function public.integration_secret(uuid, text) to service_role;
grant execute on function public.integration_tested(uuid, boolean, text) to service_role;
grant execute on function public.agent_config_full(uuid, public.case_phase) to service_role;

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/009_marketing.sql

-- =============================================================================
-- 009_marketing.sql — Sprint 3: Marketing (custos) igual ao concorrente
--
-- 1. ad_spend vira o livro de lançamentos de marketing: por dia, anúncios
--    (meta_ads, google_ads, ...) e tokens (tokens, tokens_anthropic,
--    tokens_openai), com origem manual ou importado.
-- 2. Tokens por dia: o lançamento (manual/importado) manda; sem lançamento,
--    vale a estimativa pelas mensagens da IA (messages.ai_meta × câmbio).
--    Uma função só (marketing_tokens_por_dia) alimenta Marketing e Dashboard.
-- 3. Custo por lead (lead_cost): tokens do próprio caso + rateio dos anúncios
--    do dia em que o lead chegou + média do mês. Entra no dossiê ('cost').
-- 4. Importação (n8n, service_role): Meta Ads (Marketing API), Anthropic Admin
--    (cost_report) e OpenAI Admin (organization/costs). Catálogo ganha meta_ads.
--
-- Idempotente. Rodar depois de 008.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Lançamentos
-- -----------------------------------------------------------------------------

alter table public.ad_spend
  add column if not exists origem     text not null default 'manual',
  add column if not exists valor_usd  numeric,
  add column if not exists updated_by uuid references auth.users(id),
  add column if not exists updated_at timestamptz not null default now();

alter table public.ad_spend drop constraint if exists ad_spend_canal_check;
alter table public.ad_spend add constraint ad_spend_canal_check
  check (canal in ('meta_ads','google_ads','tiktok_ads','outro','tokens','tokens_anthropic','tokens_openai'));
alter table public.ad_spend drop constraint if exists ad_spend_origem_check;
alter table public.ad_spend add constraint ad_spend_origem_check check (origem in ('manual','importado'));

drop trigger if exists ad_spend_touch on public.ad_spend;
create trigger ad_spend_touch before update on public.ad_spend
  for each row execute function public.touch_updated_at();

create or replace function public.canal_tipo(p_canal text)
returns text language sql immutable as $$
  select case when p_canal like 'tokens%' then 'tokens' else 'ads' end;
$$;

-- Um dia por linha: anúncios, tokens, total, origem e os itens.
create or replace view public.v_marketing_lancamentos
with (security_invoker = true) as
select
  a.office_id, a.dia,
  coalesce(sum(a.valor) filter (where public.canal_tipo(a.canal) = 'ads'), 0)    as ads_brl,
  coalesce(sum(a.valor) filter (where public.canal_tipo(a.canal) = 'tokens'), 0) as tokens_brl,
  coalesce(sum(a.valor), 0)                                                       as total_brl,
  bool_or(a.origem = 'importado')                                                 as tem_importado,
  bool_or(a.origem = 'manual')                                                    as tem_manual,
  string_agg(a.nota, ' · ' order by a.canal) filter (where a.nota is not null)    as observacao,
  jsonb_agg(jsonb_build_object('id', a.id, 'canal', a.canal, 'tipo', public.canal_tipo(a.canal), 'origem', a.origem,
                               'valor_brl', a.valor, 'valor_usd', a.valor_usd, 'nota', a.nota) order by a.canal) as itens,
  max(a.updated_at)                                                               as updated_at
from public.ad_spend a
group by a.office_id, a.dia;

-- Lançar/editar um dia (admin ou advogado; RLS de ad_spend decide).
create or replace function public.marketing_lancar(
  p_office uuid, p_dia date, p_ads_brl numeric default null, p_tokens_brl numeric default null, p_nota text default null)
returns jsonb
language plpgsql set search_path = public as $$
begin
  if p_ads_brl is not null then
    insert into public.ad_spend (office_id, dia, canal, valor, nota, origem, created_by, updated_by)
    values (p_office, p_dia, 'meta_ads', p_ads_brl, p_nota, 'manual', auth.uid(), auth.uid())
    on conflict (office_id, dia, canal) do update
      set valor = excluded.valor, nota = coalesce(excluded.nota, public.ad_spend.nota), origem = 'manual', updated_by = auth.uid();
  end if;
  if p_tokens_brl is not null then
    insert into public.ad_spend (office_id, dia, canal, valor, nota, origem, created_by, updated_by)
    values (p_office, p_dia, 'tokens', p_tokens_brl, p_nota, 'manual', auth.uid(), auth.uid())
    on conflict (office_id, dia, canal) do update
      set valor = excluded.valor, nota = coalesce(excluded.nota, public.ad_spend.nota), origem = 'manual', updated_by = auth.uid();
  end if;
  if p_ads_brl is null and p_tokens_brl is null and p_nota is not null then
    update public.ad_spend set nota = p_nota, updated_by = auth.uid() where office_id = p_office and dia = p_dia;
  end if;
  return (select to_jsonb(v) from public.v_marketing_lancamentos v where v.office_id = p_office and v.dia = p_dia);
end; $$;

-- Remover os lançamentos manuais do dia (os importados ficam).
create or replace function public.marketing_remover(p_office uuid, p_dia date)
returns int
language plpgsql set search_path = public as $$
declare n int;
begin
  delete from public.ad_spend where office_id = p_office and dia = p_dia and origem = 'manual';
  get diagnostics n = row_count;
  return n;
end; $$;

-- -----------------------------------------------------------------------------
-- 2. Tokens por dia: lançamento manda; senão, estimativa pelas mensagens
-- -----------------------------------------------------------------------------

create or replace function public.marketing_tokens_por_dia(p_office uuid, p_from date, p_to date)
returns table (dia date, tokens_brl numeric, tokens_usd numeric, origem text)
language sql stable set search_path = public as $$
  with cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  lanc as (
    select a.dia, sum(a.valor) as brl, sum(a.valor_usd) as usd
    from public.ad_spend a
    where a.office_id = p_office and public.canal_tipo(a.canal) = 'tokens' and a.dia >= p_from and a.dia <= p_to
    group by a.dia
  ),
  est as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
    from public.messages m
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= p_from::timestamptz and m.created_at < (p_to + 1)::timestamptz
    group by 1
  )
  select d.dia::date,
         coalesce(l.brl, round(coalesce(e.usd, 0) * cambio.v, 2)) as tokens_brl,
         coalesce(l.usd, e.usd, 0) as tokens_usd,
         case when l.dia is not null then 'lancado' when e.dia is not null then 'estimado' else 'nenhum' end as origem
  from generate_series(p_from, p_to, interval '1 day') as d(dia)
  cross join cambio
  left join lanc l on l.dia = d.dia::date
  left join est e on e.dia = d.dia::date;
$$;

-- Resumo do período (cards do topo da página Marketing).
create or replace function public.marketing_resumo_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb
language sql stable set search_path = public as $$
  with b as (select p_start::date as d0, (p_end - interval '1 day')::date as d1 from public.period_bounds(p_office, p_from, p_to)),
  ads as (select coalesce(sum(a.valor), 0) as brl from public.ad_spend a, b
          where a.office_id = p_office and public.canal_tipo(a.canal) = 'ads' and a.dia between b.d0 and b.d1),
  tok as (select coalesce(sum(t.tokens_brl), 0) as brl, count(*) filter (where t.origem = 'lancado') as lancados
          from b, public.marketing_tokens_por_dia(p_office, b.d0, b.d1) t),
  leads as (select count(*) as n from public.leads l, b where l.office_id = p_office and l.created_at >= b.d0 and l.created_at < b.d1 + 1),
  ctr as (select count(*) as n from public.contracts k, b where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.d0 and k.signed_at < b.d1 + 1),
  lanc as (select count(*) as n from public.v_marketing_lancamentos v, b where v.office_id = p_office and v.dia between b.d0 and b.d1)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.d0, 'ate', b.d1),
    'ads_brl', round(ads.brl, 2),
    'tokens_brl', round(tok.brl, 2),
    'total_brl', round(ads.brl + tok.brl, 2),
    'lancamentos', lanc.n,
    'dias_tokens_lancados', tok.lancados,
    'leads', leads.n,
    'custo_medio_por_lead_brl', case when leads.n = 0 then null else round((ads.brl + tok.brl) / leads.n, 2) end,
    'contratos', ctr.n,
    'custo_por_contrato_brl', case when ctr.n = 0 then null else round((ads.brl + tok.brl) / ctr.n, 2) end
  )
  from b, ads, tok, leads, ctr, lanc
  where public.is_office_member(p_office);
$$;

-- Lista do período (tabela da página Marketing), mais recente primeiro.
create or replace function public.marketing_lancamentos_p(p_office uuid, p_from date default null, p_to date default null)
returns setof public.v_marketing_lancamentos
language sql stable set search_path = public as $$
  select v.* from public.v_marketing_lancamentos v, public.period_bounds(p_office, p_from, p_to) b
  where v.office_id = p_office and v.dia >= b.p_start::date and v.dia < b.p_end::date
  order by v.dia desc;
$$;

-- -----------------------------------------------------------------------------
-- 3. Custo por lead
-- -----------------------------------------------------------------------------

create or replace function public.lead_cost(p_lead uuid)
returns jsonb
language sql stable set search_path = public as $$
  with l as (select id, office_id, created_at::date as dia from public.leads where id = p_lead),
  cambio as (select coalesce((select cambio_usd_brl from public.office_params p, l where p.office_id = l.office_id), 5.5) as v),
  ac as (select * from public.lead_acquisition_cost where lead_id = p_lead),
  ads_dia as (select coalesce(sum(a.valor), 0) as brl from public.ad_spend a, l
              where a.office_id = l.office_id and a.dia = l.dia and public.canal_tipo(a.canal) = 'ads'),
  leads_dia as (select count(*) as n from public.leads x, l where x.office_id = l.office_id and x.created_at::date = l.dia),
  mes as (select date_trunc('month', l.dia)::date as d0, (date_trunc('month', l.dia) + interval '1 month - 1 day')::date as d1 from l),
  mes_tot as (
    select (select coalesce(sum(a.valor), 0) from public.ad_spend a, l, mes
             where a.office_id = l.office_id and public.canal_tipo(a.canal) = 'ads' and a.dia between mes.d0 and mes.d1)
         + (select coalesce(sum(t.tokens_brl), 0) from l, mes, public.marketing_tokens_por_dia(l.office_id, mes.d0, mes.d1) t) as brl,
           (select count(*) from public.leads x, l, mes where x.office_id = l.office_id and x.created_at::date between mes.d0 and mes.d1) as leads
  )
  select jsonb_build_object(
    'mensagens_ia', coalesce(ac.mensagens_ia, 0),
    'tokens_in', coalesce(ac.tokens_in, 0),
    'tokens_out', coalesce(ac.tokens_out, 0),
    'tokens_usd', round(coalesce(ac.cost_usd, 0), 4),
    'tokens_brl', round(coalesce(ac.cost_usd, 0) * cambio.v, 2),
    'ads_dia_brl', round(ads_dia.brl, 2),
    'leads_no_dia', leads_dia.n,
    'ads_rateio_brl', case when leads_dia.n = 0 then 0 else round(ads_dia.brl / leads_dia.n, 2) end,
    'custo_lead_brl', round(coalesce(ac.cost_usd, 0) * cambio.v + case when leads_dia.n = 0 then 0 else ads_dia.brl / leads_dia.n end, 2),
    'mes', jsonb_build_object('de', mes.d0, 'ate', mes.d1, 'marketing_brl', round(mes_tot.brl, 2), 'leads', mes_tot.leads,
                              'custo_medio_lead_brl', case when mes_tot.leads = 0 then null else round(mes_tot.brl / mes_tot.leads, 2) end),
    'cambio_usd_brl', cambio.v
  )
  from l, cambio, ads_dia, leads_dia, mes, mes_tot
  left join ac on true;
$$;

-- Dossiê: 'cost' passa a ser lead_cost (contém os campos antigos + rateio + média do mês)

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
    'cost', public.lead_cost(p_lead),
    'params', (select jsonb_build_object('alerta_prescricao_dias', p.alerta_prescricao_dias, 'ticket_minimo', p.ticket_minimo,
                                         'vinculo_minimo_meses', p.vinculo_minimo_meses, 'honorarios_percent', p.honorarios_percent)
               from public.office_params p where p.office_id = (select office_id from public.leads where id = p_lead))
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- Dashboard Investimento: tokens por dia vêm de marketing_tokens_por_dia (lançado > estimado)
create or replace function public.dashboard_investimento_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb
language sql stable
set search_path = public
as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b),
  tok as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd,
           coalesce(sum((m.ai_meta->>'tokens_in')::numeric), 0) as tin, coalesce(sum((m.ai_meta->>'tokens_out')::numeric), 0) as tout,
           count(*) as msgs
    from public.messages m, b
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end
    group by 1
  ),
  ads as (
    select a.dia, sum(a.valor) as brl from public.ad_spend a, b
    where a.office_id = p_office and public.canal_tipo(a.canal) = 'ads' and a.dia >= b.p_start::date and a.dia < b.p_end::date group by 1
  ),
  tk as (
    select t.dia, t.tokens_brl, t.tokens_usd from b, public.marketing_tokens_por_dia(p_office, b.p_start::date, (b.p_end - interval '1 day')::date) t
  ),
  ctr as (
    select k.signed_at::date as dia, count(*) as n from public.contracts k, b
    where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end group by 1
  ),
  prot as (
    select p.protocolado_em::date as dia, count(*) as n from public.pieces p, b
    where p.office_id = p_office and p.status = 'protocolada' and p.protocolado_em >= b.p_start and p.protocolado_em < b.p_end group by 1
  ),
  linha as (
    select d.dia,
           coalesce(a.brl, 0) as ads_brl,
           coalesce(k.tokens_brl, 0) as tokens_brl,
           coalesce(a.brl, 0) + coalesce(k.tokens_brl, 0) as investimento_brl,
           coalesce(c.n, 0) as contratos,
           coalesce(p.n, 0) as protocolos
    from dias d
    cross join cambio
    left join ads a on a.dia = d.dia
    left join tk k on k.dia = d.dia
    left join ctr c on c.dia = d.dia
    left join prot p on p.dia = d.dia
  ),
  tot as (
    select sum(ads_brl) as ads, sum(tokens_brl) as tokens, sum(investimento_brl) as inv, sum(contratos) as contratos, sum(protocolos) as protocolos
    from linha
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'cambio_usd_brl', (select v from cambio),
    'investimento_total_brl', (select round(inv, 2) from tot),
    'ads_brl', (select round(ads, 2) from tot),
    'tokens_brl', (select round(tokens, 2) from tot),
    'tokens_usd', (select round(coalesce(sum(tokens_usd), 0), 4) from tk),
    'tokens_estimados_por_mensagens_usd', (select round(coalesce(sum(usd), 0), 4) from tok),
    'tokens_in', (select coalesce(sum(tin), 0) from tok),
    'tokens_out', (select coalesce(sum(tout), 0) from tok),
    'mensagens_ia', (select coalesce(sum(msgs), 0) from tok),
    'contratos_fechados', (select contratos from tot),
    'custo_por_contrato_brl', (select case when contratos = 0 then null else round(inv / contratos, 2) end from tot),
    'protocolos', (select protocolos from tot),
    'custo_por_protocolo_brl', (select case when protocolos = 0 then null else round(inv / protocolos, 2) end from tot),
    'valor_causa_gerado', (select coalesce(sum(valor_causa), 0) from public.contracts k, b
                           where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end),
    'por_agente', (select coalesce(jsonb_agg(jsonb_build_object('agente', agente, 'mensagens', n, 'custo_usd', round(usd, 4), 'custo_brl', round(usd * (select v from cambio), 2)) order by usd desc), '[]'::jsonb)
                   from (select coalesce(m.ai_meta->>'agent_role', 'desconhecido') as agente, count(*) as n, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
                         from public.messages m, b where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end group by 1) t),
    'dia_a_dia', (select coalesce(jsonb_agg(jsonb_build_object(
                    'dia', dia, 'ads_brl', ads_brl, 'tokens_brl', tokens_brl, 'investimento_brl', investimento_brl,
                    'contratos', contratos, 'custo_por_contrato_brl', case when contratos = 0 then null else round(investimento_brl / contratos, 2) end,
                    'protocolos', protocolos, 'custo_por_protocolo_brl', case when protocolos = 0 then null else round(investimento_brl / protocolos, 2) end
                  ) order by dia desc), '[]'::jsonb) from linha)
  )
  from b
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- 4. Importação automática (n8n, service_role)
-- -----------------------------------------------------------------------------

alter table public.integration_catalog drop constraint if exists integration_catalog_kind_check;
alter table public.integration_catalog add constraint integration_catalog_kind_check
  check (kind in ('mensageria','ads','assinatura','armazenamento','llm','llm_admin','transcricao','transcricao_admin'));

insert into public.integration_catalog (provider, kind, label, description, secret_label, config_fields, docs_url, ordem) values
  ('meta_ads', 'ads', 'Meta Ads', 'Importa o gasto diário da conta de anúncios para a página Marketing.', 'Token de acesso (Marketing API)',
   '[{"key":"ad_account_id","label":"ID da conta de anúncios","type":"text","placeholder":"act_123456789","required":true},{"key":"currency","label":"Moeda da conta","type":"text","placeholder":"BRL","required":false}]',
   'https://developers.facebook.com/docs/marketing-api/insights', 25)
on conflict (provider) do update set
  kind = excluded.kind, label = excluded.label, description = excluded.description,
  secret_label = excluded.secret_label, config_fields = excluded.config_fields, docs_url = excluded.docs_url, ordem = excluded.ordem;

-- Alvos da importação: integrações ativas com segredo. O n8n resolve o segredo com integration_secret().
create or replace function public.marketing_import_targets()
returns table (office_id uuid, provider text, config jsonb, cambio_usd_brl numeric)
language sql stable security definer set search_path = public as $$
  select i.office_id, i.provider, i.config, coalesce(p.cambio_usd_brl, 5.5)
  from public.integrations i
  left join public.office_params p on p.office_id = i.office_id
  where i.active and i.secret_name is not null and i.provider in ('meta_ads','anthropic_admin','openai_admin');
$$;

create or replace function public.marketing_import(
  p_office uuid, p_dia date, p_canal text, p_valor_brl numeric, p_valor_usd numeric default null, p_nota text default null)
returns void
language sql security definer set search_path = public as $$
  insert into public.ad_spend (office_id, dia, canal, valor, valor_usd, nota, origem)
  values (p_office, p_dia, p_canal, greatest(p_valor_brl, 0), p_valor_usd, p_nota, 'importado')
  on conflict (office_id, dia, canal) do update
    set valor = excluded.valor, valor_usd = excluded.valor_usd, nota = excluded.nota, origem = 'importado';
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant select on public.v_marketing_lancamentos to authenticated;
grant execute on function public.canal_tipo(text) to authenticated;
grant execute on function public.marketing_lancar(uuid, date, numeric, numeric, text) to authenticated;
grant execute on function public.marketing_remover(uuid, date) to authenticated;
grant execute on function public.marketing_tokens_por_dia(uuid, date, date) to authenticated;
grant execute on function public.marketing_resumo_p(uuid, date, date) to authenticated;
grant execute on function public.marketing_lancamentos_p(uuid, date, date) to authenticated;
grant execute on function public.lead_cost(uuid) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;
grant execute on function public.dashboard_investimento_p(uuid, date, date) to authenticated;

revoke execute on function public.marketing_import_targets() from public, anon, authenticated;
revoke execute on function public.marketing_import(uuid, date, text, numeric, numeric, text) from public, anon, authenticated;
grant execute on function public.marketing_import_targets() to service_role;
grant execute on function public.marketing_import(uuid, date, text, numeric, numeric, text) to service_role;

-- >>>>>>>>>>>>>>>>>>>>>>>>>> supabase/010_juridico_agenda.sql

-- =============================================================================
-- 010_juridico_agenda.sql — Sprint 3: Jurídico como esteira e Agenda por dia
--
-- 1. Jurídico igual ao concorrente: a esteira do trabalho jurídico depois do
--    contrato. pieces.status ganha 'aguardando' e 'saneamento':
--      rascunho (IA redigindo) → revisao → aguardando (cliente/documentos)
--      → saneamento (corrigir) → aprovada (pronto p/ protocolo) → protocolada.
--    Cada peça pode ter um alerta ("Confirmar com o cliente antes de
--    protocolar"), um responsável e a data de entrada na etapa.
--    v_legal_cards: um card por peça com tudo que o quadro mostra.
-- 2. Agenda: apply_agent_effects aceita p_task (o agente marca "retomar
--    amanhã às 09:00" como tarefa do lead, autor IA). v_tasks para a lista
--    por dia (lead, telefone, responsável, situação).
-- 3. Limpeza do linter do Supabase: search_path fixo em todas as funções e
--    execução só para authenticated/service_role (nunca anon/public).
--
-- Idempotente. Rodar depois de 009.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Esteira jurídica
-- -----------------------------------------------------------------------------

alter table public.pieces
  add column if not exists alerta            text,
  add column if not exists responsavel       uuid references auth.users(id),
  add column if not exists stage_changed_at  timestamptz not null default now();

alter table public.pieces drop constraint if exists pieces_status_check;
alter table public.pieces add constraint pieces_status_check
  check (status in ('rascunho','revisao','aguardando','saneamento','aprovada','protocolada'));
create index if not exists pieces_office_status_idx on public.pieces(office_id, status, stage_changed_at);

create or replace function public.piece_stage_title(p_status text)
returns text language sql immutable set search_path = public as $$
  select case p_status
    when 'rascunho' then 'Em redação'
    when 'revisao' then 'Revisão'
    when 'aguardando' then 'Aguardando'
    when 'saneamento' then 'Saneamento'
    when 'aprovada' then 'Pronto p/ protocolo'
    when 'protocolada' then 'Protocolado'
    else p_status end;
$$;

create or replace function public.piece_stages()
returns table (ordem int, status text, titulo text)
language sql immutable set search_path = public as $$
  values (1,'rascunho','Em redação'), (2,'revisao','Revisão'), (3,'aguardando','Aguardando'),
         (4,'saneamento','Saneamento'), (5,'aprovada','Pronto p/ protocolo'), (6,'protocolada','Protocolado');
$$;

-- Trigger de efeitos: registra a troca de etapa com autor e carimba stage_changed_at.
create or replace function public.pieces_effects()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor text := case when auth.uid() is not null then 'humano' else coalesce(new.generated_by_actor, 'sistema') end;
begin
  if tg_op = 'INSERT' then
    new.stage_changed_at := coalesce(new.stage_changed_at, now());
    perform public.log_event(new.office_id, new.lead_id, 'piece_created', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'tese', new.tese, 'status', new.status));
    return new;
  end if;
  if new.status is distinct from old.status then
    new.stage_changed_at := now();
    if new.status = 'protocolada' then
      new.protocolado_em := coalesce(new.protocolado_em, now());
    end if;
    perform public.log_event(new.office_id, new.lead_id, 'piece_status_changed', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'from', old.status, 'to', new.status,
                         'from_title', public.piece_stage_title(old.status), 'to_title', public.piece_stage_title(new.status),
                         'protocolo', new.protocolo));
  end if;
  if new.alerta is distinct from old.alerta and new.alerta is not null then
    perform public.log_event(new.office_id, new.lead_id, 'piece_alert', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'alerta', new.alerta));
  end if;
  return new;
end; $$;
drop trigger if exists pieces_effects on public.pieces;
create trigger pieces_effects before insert or update on public.pieces
  for each row execute function public.pieces_effects();

-- Um card por peça (a mais recente de cada lead), com o que o quadro mostra.
create or replace view public.v_legal_cards
with (security_invoker = true) as
select
  p.id                                    as piece_id,
  p.lead_id, p.office_id,
  p.status,
  public.piece_stage_title(p.status)      as etapa,
  (select ordem from public.piece_stages() s where s.status = p.status) as etapa_ordem,
  p.tese, p.alerta, p.protocolo, p.protocolado_em,
  p.responsavel, l.assigned_to,
  p.generated_by_actor, p.reviewed_by,
  p.stage_changed_at, p.updated_at, p.created_at,
  extract(epoch from (now() - p.stage_changed_at)) / 3600.0 as horas_na_etapa,
  l.phase,
  ct.name                                 as contact_name,
  ct.wa_id                                as contact_phone,
  d.empresa, d.cargo,
  coalesce(k.valor_causa, q.verbas_total) as valor_causa,
  coalesce(k.faixa, q.faixa)              as faixa,
  coalesce(q.passed, false)               as viavel,
  (coalesce(q.passed, false) = false
   or exists (select 1 from public.human_interventions h where h.lead_id = l.id and 'fragil' = any (h.tags))) as fragil,
  coalesce(c.ai_paused, false)            as em_atendimento,
  exists (select 1 from public.human_interventions h where h.lead_id = l.id and h.status in ('pendente','em_atendimento')) as intervencao_pendente,
  l.prescricao_em
from public.pieces p
join public.leads l on l.id = p.lead_id
join public.contacts ct on ct.id = l.contact_id
left join public.case_data d on d.lead_id = l.id
left join public.lead_qualification q on q.lead_id = l.id
left join lateral (select valor_causa, faixa from public.contracts k where k.lead_id = l.id and k.status = 'assinado' order by signed_at desc limit 1) k on true
left join lateral (select ai_paused from public.conversations cv where cv.lead_id = l.id order by last_message_at desc nulls last limit 1) c on true
where p.id = (select p2.id from public.pieces p2 where p2.lead_id = p.lead_id order by p2.created_at desc limit 1);

-- Mover a peça de etapa pela UI (autor humano garantido pelo trigger); alerta opcional.
create or replace function public.ui_set_piece_status(p_piece uuid, p_status text, p_alerta text default null, p_protocolo text default null)
returns public.pieces
language plpgsql set search_path = public as $$
declare p public.pieces;
begin
  if auth.uid() is null then raise exception 'ui_set_piece_status exige usuário'; end if;
  update public.pieces
     set status = p_status,
         alerta = case when p_alerta = '' then null else coalesce(p_alerta, alerta) end,
         protocolo = coalesce(p_protocolo, protocolo),
         reviewed_by = case when p_status in ('aprovada','protocolada') then auth.uid() else reviewed_by end
   where id = p_piece
   returning * into p;
  if p.id is null then raise exception 'peça não encontrada'; end if;
  return p;
end; $$;

-- -----------------------------------------------------------------------------
-- 2. Agenda
-- -----------------------------------------------------------------------------

create or replace view public.v_tasks
with (security_invoker = true) as
select
  t.id, t.office_id, t.lead_id, t.title, t.description, t.due_at, t.done_at, t.assigned_to, t.created_by, t.created_by_actor, t.created_at,
  ct.name   as contact_name,
  ct.wa_id  as contact_phone,
  l.phase,
  pr.full_name as assigned_name,
  case when t.done_at is not null then 'realizado'
       when t.due_at is not null and t.due_at < now() then 'atrasado'
       else 'pendente' end as situacao,
  (t.due_at at time zone 'America/Sao_Paulo')::date as dia
from public.tasks t
left join public.leads l on l.id = t.lead_id
left join public.contacts ct on ct.id = l.contact_id
left join public.profiles pr on pr.user_id = t.assigned_to;

-- Efeitos do agente: + p_task {title, description, due_at}
drop function if exists public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb);
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null, p_task jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
  v_task uuid;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

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
      updated_by_actor      = 'ia'
    where d.lead_id = p_lead;
    v_result := v_result || jsonb_build_object('case_data_updated', true);
  end if;

  if p_advance_to is not null and p_advance_to <> '' then
    l := public.advance_phase(p_lead, p_advance_to::public.case_phase, 'ia', null, p_agent_role, p_advance_reason);
    v_result := v_result || jsonb_build_object('phase', l.phase);
  end if;

  if p_intervention is not null and jsonb_typeof(p_intervention) = 'object' then
    if jsonb_typeof(p_intervention->'tags') = 'array' then
      select array_agg(x) into v_tags from jsonb_array_elements_text(p_intervention->'tags') x;
    end if;
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', p_agent_role,
           p_intervention->>'note', v_tags);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  if p_task is not null and jsonb_typeof(p_task) = 'object' and coalesce(p_task->>'title', '') <> '' then
    insert into public.tasks (office_id, lead_id, title, description, due_at, assigned_to, created_by_actor)
    values (l.office_id, p_lead, p_task->>'title', p_task->>'description',
            coalesce((p_task->>'due_at')::timestamptz, (current_date + 1) + time '09:00'), l.assigned_to, 'ia')
    returning id into v_task;
    v_result := v_result || jsonb_build_object('task_id', v_task);
  end if;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Limpeza do linter: search_path fixo e execução só para quem deve
-- -----------------------------------------------------------------------------

alter function public.apply_office_rls(text, text[]) set search_path = public;
alter function public.touch_updated_at() set search_path = public;
alter function public.add_to_realtime(text) set search_path = public;
alter function public.phase_order(public.case_phase) set search_path = public;
alter function public.agent_for_phase(public.case_phase) set search_path = public;
alter function public.vinculo_meses(date, date) set search_path = public;
alter function public.journey_stages() set search_path = public;
alter function public.intervention_group(text) set search_path = public;
alter function public.integration_public(public.integrations) set search_path = public;
alter function public.integration_secret_name(uuid, text) set search_path = public;
alter function public.canal_tipo(text) set search_path = public;

-- Nenhuma função do schema public é executável por anon/public. authenticated executa tudo,
-- menos as reservadas ao n8n (service_role). Triggers e helpers de migration ficam só com o dono.
do $$
declare r record; v_sig text;
  v_service_only text[] := array['integration_secret','integration_tested','agent_config_full','marketing_import','marketing_import_targets'];
  v_internal text[] := array['apply_office_rls','add_to_realtime'];
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
  loop
    v_sig := format('public.%I(%s)', r.proname, r.args);
    execute format('revoke execute on function %s from public, anon', v_sig);
    if r.prorettype = 'trigger'::regtype then
      continue;   -- triggers rodam pelo dono; não mexer
    elsif r.proname = any (v_internal) then
      execute format('revoke execute on function %s from authenticated, service_role', v_sig);
    elsif r.proname = any (v_service_only) then
      execute format('revoke execute on function %s from authenticated', v_sig);
      execute format('grant execute on function %s to service_role', v_sig);
    else
      execute format('grant execute on function %s to authenticated, service_role', v_sig);
    end if;
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;

grant select on public.v_legal_cards to authenticated;
grant select on public.v_tasks to authenticated;
