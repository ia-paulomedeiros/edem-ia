-- =============================================================================
-- 017a — parte 1 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 016 inteira (todas as partes 016*). Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- =============================================================================
-- 017_mensageria.sql — mensageria própria do Edem
--
-- O Edem é o CRM e a mensageria do escritório; Datacrazy/Evolution ficam como
-- provedores opcionais (adaptador do WA 02/WA 03). Canal padrão: WhatsApp Cloud API.
--
--  1. Etiquetas do lead (tags, lead_tags) — a etapa NÃO é etiqueta.
--  2. Departamentos, membros e acesso por número; can_see_conversation nas policies.
--  3. Status da conversa (open, waiting, in_service, closed, archived), espera,
--     janela de 24h, atendente; RPCs de atendimento com mensagem de evento;
--     messages.kind (chat | evento | nota); v_conversas e conversas_counts;
--     monitor "Cliente esperando".
--  4. Respostas rápidas (texto, áudio, arquivo) e bucket 'respostas'.
--  5. Envio de mídia e trava da janela de 24h no WA 03 (mensageria_envio).
--  6. Mensagens agendadas.
--  7. Templates da Meta: colunas novas, seed de 3 UTILITY, sincronização e envio.
--  8. Mesclar conversas.
--  9. Origem do anúncio (Click-to-WhatsApp) e v_marketing_anuncios.
-- 10. Expediente, preferências de notificação e notificações (sino).
-- 11. Mensagem não suportada (WA 02) — só fluxo; nada no banco além do texto.
-- 12. Modelos de petição editáveis pelo escritório (sobreposição + versões).
--
-- Contexto da IA e métricas leem só kind = 'chat' (seção 3f); nota e evento nunca
-- entram no que o agente vê nem no que se mede como conversa.
--
-- Compatibilidade: "conversa ativa" passa a ser status in (open, waiting,
-- in_service) — ai_should_reply, followup_queue, run_monitors e
-- send_manual_message foram redefinidos. v_conversas traz status_legado
-- (open/closed) para telas que ainda leem o valor antigo.
--
-- Idempotente. Rodar depois de 016.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 3a. Colunas novas de mensagens e conversas
-- -----------------------------------------------------------------------------
alter table public.messages add column if not exists kind text not null default 'chat';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'messages_kind_check') then
    alter table public.messages add constraint messages_kind_check check (kind in ('chat','evento','nota'));
  end if;
end $$;
comment on column public.messages.kind is 'chat = vai para o WhatsApp; evento = registro do sistema na conversa; nota = nota interna da equipe. O WA 03 só envia chat.';

alter table public.conversations
  add column if not exists waiting_since timestamptz,
  add column if not exists assigned_to uuid references auth.users(id),
  add column if not exists closed_at timestamptz,
  add column if not exists closed_by uuid references auth.users(id),
  add column if not exists hidden boolean not null default false,
  add column if not exists window_expires_at timestamptz;

alter table public.conversations drop constraint if exists conversations_status_check;
alter table public.conversations add constraint conversations_status_check
  check (status in ('open','waiting','in_service','closed','archived'));

-- Conversa "ativa" (aceita mensagem e IA). Substitui o antigo status = 'open'.
create or replace function public.conv_ativa(p_status text)
returns boolean language sql immutable set search_path = public as $$
  select p_status in ('open','waiting','in_service');
$$;

-- Migração dos dados (só mexe em quem ainda está no modelo antigo): assumida com a última
-- mensagem do contato → waiting; assumida sem pendência → in_service.
update public.conversations c
   set window_expires_at = lm.ult_in + interval '24 hours'
  from (select m.conversation_id, max(m.created_at) as ult_in from public.messages m where m.direction = 'in' group by 1) lm
 where lm.conversation_id = c.id and c.window_expires_at is null;
update public.conversations c
   set status = 'waiting',
       waiting_since = coalesce(c.waiting_since, (select max(m.created_at) from public.messages m where m.conversation_id = c.id and m.direction = 'in'))
 where c.status = 'open' and c.ai_paused
   and (select m.direction from public.messages m where m.conversation_id = c.id order by m.created_at desc limit 1) = 'in';
update public.conversations set closed_at = coalesce(closed_at, last_message_at, created_at) where status = 'closed' and closed_at is null;
update public.conversations set status = 'in_service', assigned_to = coalesce(assigned_to, paused_by) where status = 'open' and ai_paused;

-- -----------------------------------------------------------------------------
-- 1. Etiquetas
-- -----------------------------------------------------------------------------
create table if not exists public.tags (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid not null references public.offices(id) on delete cascade,
  name        text not null,
  color       text not null default '#64748B' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  description text,
  kind        text not null default 'livre' check (kind in ('livre','sistema')),
  active      boolean not null default true,
  created_by  uuid references auth.users(id),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists tags_office_name_uidx on public.tags (office_id, lower(name));

create table if not exists public.lead_tags (
  lead_id        uuid not null references public.leads(id) on delete cascade,
  tag_id         uuid not null references public.tags(id) on delete cascade,
  office_id      uuid not null references public.offices(id) on delete cascade,
  added_by_actor text not null default 'humano' check (added_by_actor in ('ia','humano','sistema')),
  added_by_user  uuid references auth.users(id),
  added_at       timestamptz not null default now(),
  primary key (lead_id, tag_id)
);
create index if not exists lead_tags_tag_idx on public.lead_tags (tag_id);

select public.apply_office_rls('tags', array['admin','advogado']);
select public.apply_office_rls('lead_tags');
select public.add_to_realtime('lead_tags');
select public.add_to_realtime('tags');

create or replace function public.tag_find(p_office uuid, p_tag text)
returns public.tags language sql stable set search_path = public as $$
  select t.* from public.tags t
  where t.office_id = p_office
    and (t.id::text = btrim(p_tag) or lower(t.name) = lower(btrim(p_tag)))
  order by (t.id::text = btrim(p_tag)) desc limit 1;
$$;

create or replace function public.tag_upsert(p_office uuid, p_name text, p_color text default '#64748B', p_description text default null, p_id uuid default null)
returns public.tags language plpgsql security definer set search_path = public as $$
declare t public.tags;
begin
  if auth.uid() is null then raise exception 'tag_upsert exige usuário'; end if;
  if public.member_role(p_office) not in ('admin','advogado') then raise exception 'só admin ou advogado gerencia etiquetas'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'informe o nome da etiqueta'; end if;
  if coalesce(p_color, '') !~ '^#[0-9A-Fa-f]{6}$' then raise exception 'cor inválida: use #RRGGBB'; end if;
  if p_id is not null then
    update public.tags set name = btrim(p_name), color = p_color, description = p_description, active = true, updated_at = now()
     where id = p_id and office_id = p_office returning * into t;
    if t.id is null then raise exception 'etiqueta não encontrada'; end if;
  else
    insert into public.tags (office_id, name, color, description, created_by)
    values (p_office, btrim(p_name), p_color, p_description, auth.uid())
    on conflict (office_id, lower(name)) do update set color = excluded.color, description = coalesce(excluded.description, public.tags.description),
      active = true, updated_at = now()
    returning * into t;
  end if;
  return t;
end; $$;

create or replace function public.tag_archive(p_tag uuid)
returns public.tags language plpgsql security definer set search_path = public as $$
declare t public.tags;
begin
  select * into t from public.tags where id = p_tag;
  if t.id is null or public.member_role(t.office_id) not in ('admin','advogado') then raise exception 'etiqueta não encontrada'; end if;
  update public.tags set active = false, updated_at = now() where id = p_tag returning * into t;
  return t;
end; $$;

-- Núcleo (sem checagem de usuário): usado pelas RPCs e por apply_agent_effects.
create or replace function public.lead_tag_apply(p_lead uuid, p_tag public.tags, p_add boolean, p_actor text, p_user uuid, p_agent text default null)
returns boolean language plpgsql security definer set search_path = public as $$
declare l public.leads; n int;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null or p_tag.id is null or p_tag.office_id <> l.office_id then return false; end if;
  if p_add then
    insert into public.lead_tags (lead_id, tag_id, office_id, added_by_actor, added_by_user)
    values (p_lead, p_tag.id, l.office_id, p_actor, p_user) on conflict do nothing;
  else
    delete from public.lead_tags where lead_id = p_lead and tag_id = p_tag.id;
  end if;
  get diagnostics n = row_count;
  if n > 0 then
    perform public.log_event(l.office_id, p_lead, case when p_add then 'tag_added' else 'tag_removed' end, p_actor, p_user, p_agent,
      jsonb_build_object('tag_id', p_tag.id, 'name', p_tag.name, 'color', p_tag.color));
  end if;
  return n > 0;
end; $$;

create or replace function public.lead_tag_add(p_lead uuid, p_tag_name_or_id text)
returns boolean language plpgsql security definer set search_path = public as $$
declare l public.leads; t public.tags;
begin
  if auth.uid() is null then raise exception 'lead_tag_add exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  t := public.tag_find(l.office_id, p_tag_name_or_id);
  if t.id is null or not t.active then raise exception 'etiqueta não encontrada ou arquivada: %', p_tag_name_or_id; end if;
  return public.lead_tag_apply(p_lead, t, true, 'humano', auth.uid());
end; $$;

create or replace function public.lead_tag_remove(p_lead uuid, p_tag_name_or_id text)
returns boolean language plpgsql security definer set search_path = public as $$
declare l public.leads; t public.tags;
begin
  if auth.uid() is null then raise exception 'lead_tag_remove exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  t := public.tag_find(l.office_id, p_tag_name_or_id);
  if t.id is null then raise exception 'etiqueta não encontrada: %', p_tag_name_or_id; end if;
  return public.lead_tag_apply(p_lead, t, false, 'humano', auth.uid());
end; $$;

create or replace function public.lead_tags_json(p_lead uuid)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name, 'color', t.color) order by t.name), '[]'::jsonb)
  from public.lead_tags lt join public.tags t on t.id = lt.tag_id
  where lt.lead_id = p_lead and t.active;
$$;

-- -----------------------------------------------------------------------------
-- 2. Departamentos e acesso por número
-- -----------------------------------------------------------------------------
create table if not exists public.departments (
  id         uuid primary key default gen_random_uuid(),
  office_id  uuid not null references public.offices(id) on delete cascade,
  name       text not null,
  color      text not null default '#2563EB' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  ai_default boolean not null default false,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists departments_office_name_uidx on public.departments (office_id, lower(name));
create unique index if not exists departments_ai_default_uidx on public.departments (office_id) where ai_default and active;
select public.apply_office_rls('departments', array['admin']);

create table if not exists public.department_members (
  department_id uuid not null references public.departments(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  created_at    timestamptz not null default now(),
  primary key (department_id, user_id)
);
alter table public.department_members enable row level security;
drop policy if exists department_members_select on public.department_members;
create policy department_members_select on public.department_members for select to authenticated
  using (exists (select 1 from public.departments d where d.id = department_id and public.is_office_member(d.office_id)));
drop policy if exists department_members_write on public.department_members;
create policy department_members_write on public.department_members for all to authenticated
  using (exists (select 1 from public.departments d where d.id = department_id and public.member_role(d.office_id) = 'admin'))
  with check (exists (select 1 from public.departments d where d.id = department_id and public.member_role(d.office_id) = 'admin'));

alter table public.conversations add column if not exists department_id uuid references public.departments(id) on delete set null;

create table if not exists public.member_number_access (
  office_id          uuid not null references public.offices(id) on delete cascade,
  user_id            uuid not null references auth.users(id) on delete cascade,
  whatsapp_number_id uuid not null references public.whatsapp_numbers(id) on delete cascade,
  created_at         timestamptz not null default now(),
  primary key (office_id, user_id, whatsapp_number_id)
);
select public.apply_office_rls('member_number_access', array['admin']);

-- Quem vê a conversa: admin vê tudo; quem é o atendente vê; os demais respeitam
-- os números e departamentos liberados. Sem linhas de acesso = vê tudo (como antes).
create or replace function public.can_see_conversation(p_conv uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((
    select public.is_office_member(c.office_id) and (
      public.member_role(c.office_id) = 'admin'
      or c.assigned_to = auth.uid()
      or (
        (not exists (select 1 from public.member_number_access a where a.office_id = c.office_id and a.user_id = auth.uid())
         or exists (select 1 from public.member_number_access a where a.office_id = c.office_id and a.user_id = auth.uid()
                      and a.whatsapp_number_id = c.whatsapp_number_id))
        and (c.department_id is null
             or not exists (select 1 from public.department_members dm join public.departments d on d.id = dm.department_id
                            where d.office_id = c.office_id and dm.user_id = auth.uid())
             or exists (select 1 from public.department_members dm where dm.department_id = c.department_id and dm.user_id = auth.uid()))
      ))
    from public.conversations c where c.id = p_conv), false);
$$;

drop policy if exists conversations_select on public.conversations;
create policy conversations_select on public.conversations for select to authenticated using (public.can_see_conversation(id));
drop policy if exists conversations_update on public.conversations;
create policy conversations_update on public.conversations for update to authenticated
  using (public.can_see_conversation(id)) with check (public.is_office_member(office_id));
drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select to authenticated using (public.can_see_conversation(conversation_id));

-- Conversa nova entra no departamento padrão da IA.
create or replace function public.conversations_default_department()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.department_id is null then
    select id into new.department_id from public.departments where office_id = new.office_id and ai_default and active limit 1;
  end if;
  return new;
end; $$;
drop trigger if exists conversations_default_department on public.conversations;
create trigger conversations_default_department before insert on public.conversations
  for each row execute function public.conversations_default_department();

-- -----------------------------------------------------------------------------
-- 10. Expediente, preferências e notificações
-- -----------------------------------------------------------------------------
create table if not exists public.office_hours (
  id        uuid primary key default gen_random_uuid(),
  office_id uuid not null references public.offices(id) on delete cascade,
  weekday   int not null check (weekday between 0 and 6),          -- 0 = domingo
  start_at  time not null,
  end_at    time not null check (end_at > start_at),
  unique (office_id, weekday, start_at)
);
select public.apply_office_rls('office_hours', array['admin']);

alter table public.office_params add column if not exists sla_espera_min int not null default 60;

-- Dentro do expediente? Escritório sem horário cadastrado = sempre.
create or replace function public.em_expediente(p_office uuid, p_ts timestamptz default now())
returns boolean language sql stable set search_path = public as $$
  select not exists (select 1 from public.office_hours h where h.office_id = p_office)
      or exists (select 1 from public.office_hours h
                 where h.office_id = p_office
                   and h.weekday = extract(dow from p_ts at time zone 'America/Sao_Paulo')::int
                   and (p_ts at time zone 'America/Sao_Paulo')::time >= h.start_at
                   and (p_ts at time zone 'America/Sao_Paulo')::time < h.end_at);
$$;

create table if not exists public.notification_prefs (
  user_id     uuid not null references auth.users(id) on delete cascade,
  office_id   uuid not null references public.offices(id) on delete cascade,
  eventos     jsonb not null default '{"mensagem_recebida": true, "conversa_atribuida": true, "cliente_esperando": true, "pedido_humano": true}'::jsonb,
  janela_inicio time,
  janela_fim    time,
  agrupar_min int not null default 5 check (agrupar_min >= 0),
  updated_at  timestamptz not null default now(),
  primary key (user_id, office_id)
);
alter table public.notification_prefs enable row level security;
drop policy if exists notification_prefs_own on public.notification_prefs;
create policy notification_prefs_own on public.notification_prefs for all to authenticated
  using (user_id = auth.uid() and public.is_office_member(office_id))
  with check (user_id = auth.uid() and public.is_office_member(office_id));

create table if not exists public.notifications (
  id              uuid primary key default gen_random_uuid(),
  office_id       uuid not null references public.offices(id) on delete cascade,
  user_id         uuid not null references auth.users(id) on delete cascade,
  tipo            text not null check (tipo in ('mensagem_recebida','conversa_atribuida','cliente_esperando','pedido_humano')),
  titulo          text not null,
  corpo           text,
  payload         jsonb not null default '{}'::jsonb,
  lead_id         uuid references public.leads(id) on delete cascade,
  conversation_id uuid references public.conversations(id) on delete cascade,
  qtd             int not null default 1,
  silenciosa      boolean not null default false,
  read_at         timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, read_at, created_at desc);
alter table public.notifications enable row level security;
drop policy if exists notifications_own_select on public.notifications;
create policy notifications_own_select on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists notifications_own_update on public.notifications;
create policy notifications_own_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
select public.add_to_realtime('notifications');

-- notify(usuário, tipo, payload). payload: office_id, titulo, corpo, lead_id, conversation_id.
-- Respeita as preferências: evento desligado não grava; fora da janela grava silenciosa;
-- repetições do mesmo tipo/conversa dentro de agrupar_min somam na mesma notificação.
create or replace function public.notify(p_user uuid, p_tipo text, p_payload jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_office uuid := (p_payload->>'office_id')::uuid; v_conv uuid := (p_payload->>'conversation_id')::uuid;
  pr public.notification_prefs; v_id uuid; v_local time := (now() at time zone 'America/Sao_Paulo')::time; v_silenciosa boolean := false;
begin
  if p_user is null or v_office is null then return null; end if;
  if not exists (select 1 from public.office_members m where m.office_id = v_office and m.user_id = p_user) then return null; end if;
  select * into pr from public.notification_prefs where user_id = p_user and office_id = v_office;
  if pr.user_id is not null and coalesce((pr.eventos->>p_tipo)::boolean, true) = false then return null; end if;
  if pr.janela_inicio is not null and pr.janela_fim is not null then
    v_silenciosa := not (case when pr.janela_inicio <= pr.janela_fim then v_local between pr.janela_inicio and pr.janela_fim
                              else v_local >= pr.janela_inicio or v_local <= pr.janela_fim end);
  end if;
  if coalesce(pr.agrupar_min, 5) > 0 then
    select id into v_id from public.notifications
     where user_id = p_user and tipo = p_tipo and read_at is null and conversation_id is not distinct from v_conv
       and updated_at > now() - make_interval(mins => coalesce(pr.agrupar_min, 5))
     order by updated_at desc limit 1;
    if v_id is not null then
      update public.notifications set qtd = qtd + 1, corpo = coalesce(p_payload->>'corpo', corpo), payload = p_payload, updated_at = now() where id = v_id;
      return v_id;
    end if;
  end if;
  insert into public.notifications (office_id, user_id, tipo, titulo, corpo, payload, lead_id, conversation_id, silenciosa)
  values (v_office, p_user, p_tipo, coalesce(p_payload->>'titulo', p_tipo), p_payload->>'corpo', p_payload,
          (p_payload->>'lead_id')::uuid, v_conv, v_silenciosa)
  returning id into v_id;
  return v_id;
end; $$;

-- ---------- Verificação da parte 017a: deve voltar uma linha com resultado = OK
select '017a' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função can_see_conversation', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'can_see_conversation')),
    ('função conv_ativa', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conv_ativa')),
    ('função conversations_default_department', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversations_default_department')),
    ('função em_expediente', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'em_expediente')),
    ('função lead_tag_add', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_tag_add')),
    ('função lead_tag_apply', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_tag_apply')),
    ('função lead_tag_remove', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_tag_remove')),
    ('função lead_tags_json', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_tags_json')),
    ('função notify', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'notify')),
    ('função tag_archive', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tag_archive')),
    ('função tag_find', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tag_find')),
    ('função tag_upsert', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tag_upsert')),
    ('tabela department_members', to_regclass('public.department_members') is not null),
    ('tabela departments', to_regclass('public.departments') is not null),
    ('tabela lead_tags', to_regclass('public.lead_tags') is not null),
    ('tabela member_number_access', to_regclass('public.member_number_access') is not null),
    ('tabela notification_prefs', to_regclass('public.notification_prefs') is not null),
    ('tabela notifications', to_regclass('public.notifications') is not null),
    ('tabela office_hours', to_regclass('public.office_hours') is not null),
    ('tabela tags', to_regclass('public.tags') is not null),
    ('coluna messages.kind', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'messages' and column_name = 'kind')),
    ('coluna conversations.waiting_since', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations' and column_name = 'waiting_since')),
    ('coluna conversations.assigned_to', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations' and column_name = 'assigned_to')),
    ('coluna conversations.closed_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations' and column_name = 'closed_at')),
    ('coluna conversations.closed_by', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations' and column_name = 'closed_by')),
    ('coluna conversations.hidden', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations' and column_name = 'hidden')),
    ('coluna conversations.window_expires_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations' and column_name = 'window_expires_at')),
    ('coluna conversations.department_id', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'conversations' and column_name = 'department_id')),
    ('coluna office_params.sla_espera_min', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'office_params' and column_name = 'sla_espera_min'))
) as v(item, ok);
