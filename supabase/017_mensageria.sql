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

-- Destinatários de uma conversa: o atendente; sem atendente, os membros do
-- departamento; sem departamento com membros, admins e advogados.
create or replace function public.conversation_recipients(p_conv uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  with c as (select * from public.conversations where id = p_conv)
  select c.assigned_to from c where c.assigned_to is not null
  union
  select dm.user_id from c join public.department_members dm on dm.department_id = c.department_id
   where c.assigned_to is null
  union
  select m.user_id from c join public.office_members m on m.office_id = c.office_id and m.role in ('admin','advogado')
   where c.assigned_to is null and not exists (select 1 from public.department_members dm where dm.department_id = c.department_id);
$$;

create or replace function public.notifications_mark_read(p_ids uuid[] default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null then raise exception 'exige usuário'; end if;
  update public.notifications set read_at = now()
   where user_id = auth.uid() and read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end; $$;

-- -----------------------------------------------------------------------------
-- 3b. Gatilho de mensagens (redefinido): só "chat" mexe em prévia, não lidas,
-- takeover e régua. Controla status, espera e a janela de 24h.
--   entrada do contato → janela = +24h; se a IA está pausada, a conversa fica
--     aguardando (waiting_since) e o atendente é notificado;
--   saída humana       → takeover (como antes), status in_service, atendente;
--   saída da IA        → zera a espera.
-- -----------------------------------------------------------------------------
create or replace function public.messages_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_conv public.conversations; r public.followup_rules; u uuid;
begin
  if coalesce(new.kind, 'chat') <> 'chat' then
    return new;
  end if;

  update public.conversations
     set last_message_at = new.created_at,
         last_message_preview = left(coalesce(new.body, '[mídia]'), 140),
         unread_count = case when new.direction = 'in' then unread_count + 1 else 0 end,
         window_expires_at = case when new.direction = 'in' then greatest(coalesce(window_expires_at, new.created_at), new.created_at + interval '24 hours') else window_expires_at end,
         hidden = case when new.direction = 'in' then false else hidden end,
         status = case
                    when new.direction = 'in' and status = 'archived' then 'open'
                    when new.direction = 'in' and status = 'open' and ai_paused then 'waiting'
                    when new.direction = 'out' and new.sender = 'humano' and public.conv_ativa(status) then 'in_service'
                    else status end,
         waiting_since = case
                    when new.direction = 'in' and (ai_paused or status in ('waiting','in_service')) then coalesce(waiting_since, new.created_at)
                    when new.direction = 'out' and new.sender in ('humano','ia') then null
                    else waiting_since end,
         assigned_to = case when new.direction = 'out' and new.sender = 'humano' then coalesce(assigned_to, new.sent_by) else assigned_to end
   where id = new.conversation_id
   returning * into v_conv;

  if new.direction = 'out' and new.sender = 'humano' and not v_conv.ai_paused then
    update public.conversations
       set ai_paused = true, paused_by = new.sent_by, paused_at = now()
     where id = new.conversation_id;
    perform public.log_event(new.office_id, v_conv.lead_id, 'takeover', 'humano', new.sent_by, null,
                             jsonb_build_object('via', 'manual_message', 'message_id', new.id), new.conversation_id);
  end if;

  if new.direction = 'in' then
    update public.leads set last_inbound_at = new.created_at, followup_step = 0, followup_next_at = null where id = v_conv.lead_id;
    if v_conv.ai_paused then
      for u in select * from public.conversation_recipients(v_conv.id) loop
        perform public.notify(u, 'mensagem_recebida', jsonb_build_object(
          'office_id', v_conv.office_id, 'lead_id', v_conv.lead_id, 'conversation_id', v_conv.id,
          'titulo', 'Nova mensagem de ' || coalesce((select ct.name from public.contacts ct where ct.id = v_conv.contact_id), 'contato'),
          'corpo', left(coalesce(new.body, '[mídia]'), 140)));
      end loop;
    end if;
  elsif new.sender = 'ia' then
    r := public.followup_rule(new.office_id, 1);
    update public.leads
       set last_outbound_at = new.created_at,
           followup_step = 0,
           followup_next_at = case when r.id is not null and not paused then new.created_at + make_interval(hours => r.delay_hours) else null end
     where id = v_conv.lead_id;
  else
    update public.leads set last_outbound_at = new.created_at where id = v_conv.lead_id;
  end if;
  return new;
end;
$$;

-- Trava da IA: conversa ativa (open/waiting/in_service). Mesma assinatura.
create or replace function public.ai_should_reply(p_conversation uuid)
returns boolean language sql stable set search_path = public as $$
  select coalesce((
    select public.conv_ativa(c.status) and not c.ai_paused and o.active
       and l.phase <> 'encerrado'
       and not exists (select 1 from public.human_interventions h
                       where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))
    from public.conversations c
    join public.offices o on o.id = c.office_id
    join public.leads l on l.id = c.lead_id
    where c.id = p_conversation
  ), false);
$$;

create or replace function public.followup_queue(p_limit integer default 100)
returns table(lead_id uuid, office_id uuid, conversation_id uuid, wa_id text, phone_number_id text, nome text, escritorio text, step integer,
              template text, janela_aberta boolean, template_name text, template_language text)
language sql stable security definer set search_path = public as $$
  select l.id, l.office_id, c.id, ct.wa_id, wn.phone_number_id, ct.name, o.name, l.followup_step + 1, r.template,
         (l.last_inbound_at is not null and l.last_inbound_at > now() - interval '24 hours') as janela_aberta,
         t.name, t.language
  from public.leads l
  join public.offices o on o.id = l.office_id
  join public.contacts ct on ct.id = l.contact_id
  join lateral (select * from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) c on true
  join public.whatsapp_numbers wn on wn.id = c.whatsapp_number_id
  join lateral (select * from public.followup_rule(l.office_id, l.followup_step + 1)) r on true
  left join public.wa_templates t on t.office_id = l.office_id and t.name = r.template_name and t.status = 'aprovado'
  where l.followup_next_at is not null and l.followup_next_at <= now()
    and not l.paused and l.phase <> 'encerrado'
    and public.conv_ativa(c.status) and not c.ai_paused
    and (l.last_inbound_at is null or l.last_inbound_at <= l.last_outbound_at)
    and not exists (select 1 from public.human_interventions h where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))
  order by l.followup_next_at
  limit p_limit;
$$;

create or replace function public.send_manual_message(p_conversation uuid, p_body text)
returns public.messages language plpgsql security definer set search_path = public as $$
declare v_conv public.conversations; v_msg public.messages;
begin
  if auth.uid() is null then raise exception 'send_manual_message exige usuário autenticado'; end if;
  select * into v_conv from public.conversations where id = p_conversation;
  if v_conv.id is null then raise exception 'conversa % não existe', p_conversation; end if;
  if not public.can_see_conversation(p_conversation) then raise exception 'sem acesso à conversa'; end if;
  if not public.conv_ativa(v_conv.status) then raise exception 'conversa encerrada: reabra antes de enviar'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'mensagem vazia'; end if;
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, sent_by)
  values (v_conv.office_id, p_conversation, 'out', 'humano', p_body, 'pending', auth.uid())
  returning * into v_msg;
  return v_msg;
end;
$$;

-- ingest_inbound (015) — mesma assinatura; não derruba waiting/in_service para
-- open a cada mensagem (só reabre conversa encerrada/arquivada).
create or replace function public.ingest_inbound(p_phone_number_id text, p_wa_id text, p_name text, p_wa_message_id text, p_body text,
                                                 p_media jsonb default null, p_ts timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_num public.whatsapp_numbers; v_contact_id uuid; v_lead_id uuid; v_conv_id uuid; v_msg_id uuid;
  v_new_lead boolean := false; v_outro uuid;
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
  on conflict (office_id, wa_id) do update set name = coalesce(public.contacts.name, excluded.name)
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
  on conflict (lead_id, whatsapp_number_id) do update
    set status = case when public.conv_ativa(public.conversations.status) then public.conversations.status else 'open' end,
        closed_at = case when public.conv_ativa(public.conversations.status) then public.conversations.closed_at else null end,
        closed_by = case when public.conv_ativa(public.conversations.status) then public.conversations.closed_by else null end
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

  return jsonb_build_object('duplicate', false, 'new_lead', v_new_lead, 'office_id', v_num.office_id, 'contact_id', v_contact_id,
    'lead_id', v_lead_id, 'conversation_id', v_conv_id, 'message_id', v_msg_id, 'ai_should_reply', public.ai_should_reply(v_conv_id));
end;
$$;

-- Carimbos de status: encerrar (advance_phase grava status = 'closed') preenche
-- closed_at/closed_by; reabrir limpa; devolver para a IA tira da fila humana.
create or replace function public.conversations_status_stamp()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.status = 'closed' and old.status is distinct from 'closed' then
    new.closed_at := coalesce(new.closed_at, now());
    new.closed_by := coalesce(new.closed_by, auth.uid());
    new.waiting_since := null;
  elsif public.conv_ativa(new.status) and old.status in ('closed','archived') then
    new.closed_at := null; new.closed_by := null;
  end if;
  if new.status in ('closed','archived') then new.waiting_since := null; end if;
  -- release_to_ai / conversation_set_ai: IA volta a atender → conversa sai da fila humana.
  if old.ai_paused and not new.ai_paused and new.status in ('waiting','in_service') then
    new.status := 'open'; new.waiting_since := null; new.assigned_to := null;
  end if;
  -- take_over (001) pausa a IA sem mexer no status: a conversa passa a "em atendimento".
  if not old.ai_paused and new.ai_paused and new.status = 'open' then
    new.status := 'in_service'; new.assigned_to := coalesce(new.assigned_to, new.paused_by);
  end if;
  return new;
end; $$;
drop trigger if exists conversations_status_stamp on public.conversations;
create trigger conversations_status_stamp before update of status, ai_paused on public.conversations
  for each row execute function public.conversations_status_stamp();

-- -----------------------------------------------------------------------------
-- 3c. Monitor "Cliente esperando" e notificações de fila
-- -----------------------------------------------------------------------------
alter table public.human_interventions drop constraint if exists human_interventions_category_check;
alter table public.human_interventions add constraint human_interventions_category_check
  check (category in ('duvida_juridica','fora_de_escopo','cliente_insatisfeito','pedido_de_humano','erro_ia','prescricao','outro',
                      'agendamento','caso_escalado','follow_up_esgotado','seguir_conversa','contrato_nao_assinado_24h','ia_sem_resposta',
                      'cliente_ja_existente','saneamento_juridico','spam','caso_parado','cliente_esperando'));

create or replace function public.intervention_group(p_category text)
returns table(grupo text, titulo text, ordem integer) language sql immutable set search_path = public as $$
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
    when 'cliente_esperando' then 'seguir_conversa'
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

-- Pedido de humano vira notificação para quem atende a conversa.
create or replace function public.human_interventions_notify()
returns trigger language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  if new.category = 'pedido_de_humano' and new.conversation_id is not null then
    for u in select * from public.conversation_recipients(new.conversation_id) loop
      perform public.notify(u, 'pedido_humano', jsonb_build_object('office_id', new.office_id, 'lead_id', new.lead_id,
        'conversation_id', new.conversation_id, 'titulo', 'Cliente pediu atendimento humano', 'corpo', new.reason));
    end loop;
  end if;
  return new;
end; $$;
drop trigger if exists human_interventions_notify on public.human_interventions;
create trigger human_interventions_notify after insert on public.human_interventions
  for each row execute function public.human_interventions_notify();

-- run_monitors (015) + cliente_esperando. Mesma assinatura; a chave nova vem no retorno.
create or replace function public.run_monitors()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record; h public.human_interventions; v_t0 timestamptz := now(); u uuid;
  n_parado int := 0; n_ia int := 0; n_ctr int := 0; n_cli int := 0; n_esp int := 0;
begin
  -- Caso parado >48h: fase de atendimento, conversa com a IA, sem régua em curso
  for r in
    select l.id as lead_id, c.id as conv, l.phase
    from public.leads l
    join lateral (select cv.* from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) c on true
    where l.phase not in ('encerrado','peca') and not l.paused and public.conv_ativa(c.status) and not c.ai_paused
      and coalesce(c.last_message_at, l.created_at) < now() - interval '48 hours'
      and l.followup_next_at is null
      and not exists (select 1 from public.human_interventions x where x.lead_id = l.id and x.category = 'caso_parado' and x.status in ('pendente','em_atendimento'))
  loop
    h := public.request_intervention(r.lead_id, r.conv, 'caso_parado', 'Caso parado >48h', 2, 'sistema', null,
           'Nenhuma mensagem há mais de 48 horas (' || public.phase_label(r.phase) || ').', array['monitor']);
    if h.id is not null then n_parado := n_parado + 1; end if;
  end loop;

  -- IA não respondeu há 30+ min: última mensagem (chat) é do lead e a IA deveria responder
  for r in
    select c.id as conv, c.lead_id
    from public.conversations c
    join public.leads l on l.id = c.lead_id
    join lateral (select m.direction, m.created_at from public.messages m where m.conversation_id = c.id and m.kind = 'chat' order by m.created_at desc limit 1) lm on true
    where public.conv_ativa(c.status) and l.phase <> 'encerrado' and lm.direction = 'in' and lm.created_at < now() - interval '30 minutes'
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

  -- Cliente esperando: aguardando humano além do SLA, dentro do expediente. Uma por conversa.
  for r in
    select c.id as conv, c.lead_id, c.office_id, c.waiting_since,
           floor(extract(epoch from now() - c.waiting_since) / 60)::int as minutos
    from public.conversations c
    join public.leads l on l.id = c.lead_id
    left join public.office_params p on p.office_id = c.office_id
    where c.status in ('waiting','in_service') and c.waiting_since is not null
      and c.waiting_since < now() - make_interval(mins => coalesce(p.sla_espera_min, 60))
      and l.phase <> 'encerrado'
      and public.em_expediente(c.office_id, now())
      and not exists (select 1 from public.human_interventions x where x.conversation_id = c.id and x.category = 'cliente_esperando' and x.status in ('pendente','em_atendimento'))
  loop
    h := public.request_intervention(r.lead_id, r.conv, 'cliente_esperando', 'Cliente esperando', 2, 'sistema', null,
           'Cliente aguardando resposta há ' || r.minutos || ' min.', array['monitor', 'sla']);
    if h.id is not null then
      n_esp := n_esp + 1;
      for u in select * from public.conversation_recipients(r.conv) loop
        perform public.notify(u, 'cliente_esperando', jsonb_build_object('office_id', r.office_id, 'lead_id', r.lead_id,
          'conversation_id', r.conv, 'titulo', 'Cliente esperando há ' || r.minutos || ' min', 'corpo', null));
      end loop;
    end if;
  end loop;

  return jsonb_build_object('caso_parado', n_parado, 'ia_sem_resposta', n_ia, 'contrato_nao_assinado_24h', n_ctr,
                            'cliente_ja_existente', n_cli, 'cliente_esperando', n_esp, 'rodou_em', v_t0);
end; $$;

-- -----------------------------------------------------------------------------
-- 3d. RPCs de atendimento. Cada uma grava case_events (actor humano) e uma
-- mensagem de evento (kind = 'evento', sender = 'sistema') na conversa.
-- -----------------------------------------------------------------------------
-- Nome de quem atende (só de quem divide escritório com o usuário).
create or replace function public.user_nome(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select nullif(btrim(p.full_name), '') from public.profiles p
                   where p.user_id = p_user
                     and (auth.uid() is null or p_user = auth.uid()
                          or exists (select 1 from public.office_members a join public.office_members b on b.office_id = a.office_id
                                     where a.user_id = auth.uid() and b.user_id = p_user))), 'Equipe');
$$;

-- Mensagem de evento + case_event (núcleo; sem checagem de acesso).
create or replace function public.conversation_event(p_conv uuid, p_type text, p_texto text, p_actor text, p_user uuid,
                                                     p_payload jsonb default '{}'::jsonb, p_agent text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_msg uuid;
begin
  select * into c from public.conversations where id = p_conv;
  if c.id is null then return null; end if;
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, kind, ai_meta)
  values (c.office_id, p_conv, 'out', 'sistema', p_texto, 'sent', 'evento',
          jsonb_build_object('evento', p_type, 'actor', p_actor, 'actor_user', p_user) || coalesce(p_payload, '{}'::jsonb))
  returning id into v_msg;
  perform public.log_event(c.office_id, c.lead_id, p_type, p_actor, case when p_actor = 'humano' then p_user end, p_agent,
                           coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('message_id', v_msg), p_conv);
  return v_msg;
end; $$;

create or replace function public.conversation_guard(p_conv uuid)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations;
begin
  if auth.uid() is null then raise exception 'exige usuário autenticado'; end if;
  select * into c from public.conversations where id = p_conv for update;
  if c.id is null or not public.can_see_conversation(p_conv) then raise exception 'conversa não encontrada'; end if;
  return c;
end; $$;

create or replace function public.conversation_assign(p_conv uuid, p_user uuid)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_me uuid := auth.uid();
begin
  c := public.conversation_guard(p_conv);
  if p_user is not null and not exists (select 1 from public.office_members m where m.office_id = c.office_id and m.user_id = p_user) then
    raise exception 'usuário não é membro do escritório';
  end if;
  if c.assigned_to is not distinct from p_user then return c; end if;
  if p_user is null then
    update public.conversations
       set assigned_to = null,
           status = case when public.conv_ativa(status) then case when ai_paused then 'waiting' else 'open' end else status end,
           waiting_since = case when ai_paused and public.conv_ativa(status) then coalesce(waiting_since, now()) else waiting_since end
     where id = p_conv returning * into c;
    perform public.conversation_event(p_conv, 'conversation_unassigned', 'Conversa sem atendente (' || public.user_nome(v_me) || ')',
                                      'humano', v_me, '{}'::jsonb);
  else
    update public.conversations
       set assigned_to = p_user,
           status = case when status in ('closed','archived') then status else 'in_service' end,
           ai_paused = true, paused_by = coalesce(paused_by, v_me), paused_at = coalesce(paused_at, now())
     where id = p_conv returning * into c;
    perform public.conversation_event(p_conv, 'conversation_assigned', 'Conversa atribuída a ' || public.user_nome(p_user) || ' por ' || public.user_nome(v_me),
                                      'humano', v_me, jsonb_build_object('assigned_to', p_user));
    if p_user <> v_me then
      perform public.notify(p_user, 'conversa_atribuida', jsonb_build_object('office_id', c.office_id, 'lead_id', c.lead_id,
        'conversation_id', p_conv, 'titulo', 'Conversa atribuída a você', 'corpo', public.user_nome(v_me) || ' atribuiu uma conversa a você.'));
    end if;
  end if;
  return c;
end; $$;

create or replace function public.conversation_transfer_department(p_conv uuid, p_dept uuid)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; d public.departments; v_me uuid := auth.uid(); u uuid;
begin
  c := public.conversation_guard(p_conv);
  select * into d from public.departments where id = p_dept and office_id = c.office_id and active;
  if d.id is null then raise exception 'departamento não encontrado'; end if;
  if d.ai_default then
    update public.conversations
       set department_id = d.id, assigned_to = null, ai_paused = false, paused_by = null, paused_at = null,
           status = case when public.conv_ativa(status) then 'open' else status end, waiting_since = null
     where id = p_conv returning * into c;
  else
    update public.conversations
       set department_id = d.id, assigned_to = null, ai_paused = true, paused_by = coalesce(paused_by, v_me), paused_at = coalesce(paused_at, now()),
           status = case when public.conv_ativa(status) then 'waiting' else status end,
           waiting_since = case when public.conv_ativa(status) then coalesce(waiting_since, now()) else waiting_since end
     where id = p_conv returning * into c;
  end if;
  perform public.conversation_event(p_conv, 'conversation_transferred', 'Transferida para ' || d.name || ' por ' || public.user_nome(v_me),
                                    'humano', v_me, jsonb_build_object('department_id', d.id, 'department', d.name, 'ai', d.ai_default));
  if not d.ai_default then
    for u in select dm.user_id from public.department_members dm where dm.department_id = d.id and dm.user_id <> v_me loop
      perform public.notify(u, 'conversa_atribuida', jsonb_build_object('office_id', c.office_id, 'lead_id', c.lead_id,
        'conversation_id', p_conv, 'titulo', 'Nova conversa em ' || d.name, 'corpo', public.user_nome(v_me) || ' transferiu uma conversa.'));
    end loop;
  end if;
  return c;
end; $$;

create or replace function public.conversation_close(p_conv uuid)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_me uuid := auth.uid();
begin
  c := public.conversation_guard(p_conv);
  if c.status = 'closed' then return c; end if;
  update public.conversations set status = 'closed', closed_at = now(), closed_by = v_me, waiting_since = null, unread_count = 0
   where id = p_conv returning * into c;
  perform public.conversation_event(p_conv, 'conversation_closed', 'Atendimento finalizado por ' || public.user_nome(v_me), 'humano', v_me);
  return c;
end; $$;

create or replace function public.conversation_reopen(p_conv uuid)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_me uuid := auth.uid();
begin
  c := public.conversation_guard(p_conv);
  if public.conv_ativa(c.status) then return c; end if;
  if exists (select 1 from public.leads l where l.id = c.lead_id and l.closed_at is not null) then
    raise exception 'o caso está encerrado: reabra o caso antes da conversa';
  end if;
  update public.conversations
     set status = case when not ai_paused then 'open' when assigned_to is not null then 'in_service' else 'waiting' end,
         hidden = false, closed_at = null, closed_by = null
   where id = p_conv returning * into c;
  perform public.conversation_event(p_conv, 'conversation_reopened', 'Conversa reaberta por ' || public.user_nome(v_me), 'humano', v_me);
  return c;
end; $$;

create or replace function public.conversation_archive(p_conv uuid)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_me uuid := auth.uid();
begin
  c := public.conversation_guard(p_conv);
  if c.status = 'archived' then return c; end if;
  update public.conversations set status = 'archived', closed_at = coalesce(closed_at, now()), closed_by = coalesce(closed_by, v_me),
         waiting_since = null, unread_count = 0
   where id = p_conv returning * into c;
  perform public.conversation_event(p_conv, 'conversation_archived', 'Conversa arquivada por ' || public.user_nome(v_me), 'humano', v_me);
  return c;
end; $$;

-- Ler não gera mensagem de evento (seria ruído a cada clique); gera case_event só
-- quando havia não lidas.
create or replace function public.conversation_mark_read(p_conv uuid)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_me uuid := auth.uid(); n int;
begin
  c := public.conversation_guard(p_conv);
  n := c.unread_count;
  if n = 0 then return c; end if;
  update public.conversations set unread_count = 0 where id = p_conv returning * into c;
  perform public.log_event(c.office_id, c.lead_id, 'conversation_read', 'humano', v_me, null, jsonb_build_object('unread', n), p_conv);
  return c;
end; $$;

create or replace function public.conversation_set_ai(p_conv uuid, p_on boolean)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_me uuid := auth.uid();
begin
  c := public.conversation_guard(p_conv);
  if p_on = not c.ai_paused then return c; end if;
  if p_on then
    update public.conversations set ai_paused = false, paused_by = null, paused_at = null, assigned_to = null
     where id = p_conv returning * into c;
    perform public.conversation_event(p_conv, 'ai_released', 'IA reativada por ' || public.user_nome(v_me), 'humano', v_me);
  else
    update public.conversations
       set ai_paused = true, paused_by = v_me, paused_at = now(),
           status = case when status = 'open' then 'in_service' else status end,
           assigned_to = coalesce(assigned_to, v_me)
     where id = p_conv returning * into c;
    perform public.conversation_event(p_conv, 'takeover', 'IA pausada: ' || public.user_nome(v_me) || ' assumiu a conversa', 'humano', v_me,
                                      jsonb_build_object('via', 'conversation_set_ai'));
  end if;
  return c;
end; $$;

create or replace function public.conversation_hide(p_conv uuid, p_hidden boolean default true)
returns public.conversations language plpgsql security definer set search_path = public as $$
declare c public.conversations; v_me uuid := auth.uid();
begin
  c := public.conversation_guard(p_conv);
  if c.hidden = p_hidden then return c; end if;
  update public.conversations set hidden = p_hidden where id = p_conv returning * into c;
  perform public.log_event(c.office_id, c.lead_id, case when p_hidden then 'conversation_hidden' else 'conversation_unhidden' end,
                           'humano', v_me, null, '{}'::jsonb, p_conv);
  return c;
end; $$;

-- Nota interna: fica na conversa, nunca vai para o WhatsApp.
create or replace function public.conversation_note(p_conv uuid, p_body text)
returns public.messages language plpgsql security definer set search_path = public as $$
declare c public.conversations; m public.messages; v_me uuid := auth.uid();
begin
  c := public.conversation_guard(p_conv);
  if coalesce(btrim(p_body), '') = '' then raise exception 'nota vazia'; end if;
  insert into public.messages (office_id, conversation_id, direction, sender, body, status, kind, sent_by)
  values (c.office_id, p_conv, 'out', 'humano', p_body, 'sent', 'nota', v_me) returning * into m;
  perform public.log_event(c.office_id, c.lead_id, 'note_added', 'humano', v_me, null, jsonb_build_object('message_id', m.id), p_conv);
  return m;
end; $$;

-- -----------------------------------------------------------------------------
-- 3e. Lista de conversas
-- -----------------------------------------------------------------------------
alter table public.leads add column if not exists ad_referral jsonb;

create or replace function public.conversation_status_titulo(p_status text)
returns text language sql immutable set search_path = public as $$
  select case p_status when 'open' then 'Com a IA' when 'waiting' then 'Aguardando' when 'in_service' then 'Em atendimento'
                       when 'closed' then 'Finalizada' when 'archived' then 'Arquivada' else p_status end;
$$;

create or replace view public.v_conversas with (security_invoker = true) as
select
  c.id as conversation_id, c.office_id, c.lead_id, c.contact_id, c.whatsapp_number_id,
  wn.display_phone as numero_exibicao,
  ct.name as contact_name, ct.wa_id as contact_phone,
  l.phase, public.lead_etapa(l.id) as etapa, public.etapa_titulo(public.lead_etapa(l.id)) as etapa_titulo,
  case when exists (select 1 from public.contracts k where k.lead_id = l.id and k.status = 'assinado') then 'assinado'
       when l.closed_at is not null then 'encerrado'
       when exists (select 1 from public.contracts k where k.lead_id = l.id and k.status = 'enviado') then 'contrato_enviado'
       end as selo,
  public.lead_tags_json(l.id) as etiquetas,
  c.department_id, d.name as departamento_nome, d.color as departamento_cor,
  c.assigned_to, case when c.assigned_to is not null then public.user_nome(c.assigned_to) end as atendente_nome,
  c.status, public.conversation_status_titulo(c.status) as status_titulo,
  case when public.conv_ativa(c.status) then 'open' else 'closed' end as status_legado,
  c.ai_paused, (public.conv_ativa(c.status) and not c.ai_paused) as com_ia,
  c.hidden, c.unread_count,
  c.waiting_since,
  case when c.waiting_since is not null then floor(extract(epoch from now() - c.waiting_since) / 60)::int end as minutos_esperando,
  c.window_expires_at,
  coalesce(c.window_expires_at > now(), false) as janela_aberta,
  case when c.window_expires_at > now() then floor(extract(epoch from c.window_expires_at - now()) / 60)::int end as janela_restante_min,
  l.source as origem,
  l.ad_referral->>'headline' as anuncio_titulo,
  l.ad_referral->>'source_id' as anuncio_id,
  l.ad_referral,
  c.last_message_at, c.last_message_preview as previa,
  (select m.sender from public.messages m where m.conversation_id = c.id and m.kind = 'chat' order by m.created_at desc limit 1) as ultima_mensagem_de,
  c.closed_at, c.closed_by, c.created_at
from public.conversations c
join public.leads l on l.id = c.lead_id
join public.contacts ct on ct.id = c.contact_id
left join public.whatsapp_numbers wn on wn.id = c.whatsapp_number_id
left join public.departments d on d.id = c.department_id;
grant select on public.v_conversas to authenticated;

-- Contadores das abas. Invoker: conta só o que o usuário pode ver.
create or replace function public.conversas_counts(p_office uuid)
returns table(todas bigint, aguardando bigint, em_atendimento bigint, com_ia bigint, finalizadas bigint, arquivadas bigint,
              ocultas bigint, nao_lidas bigint)
language sql stable set search_path = public as $$
  select count(*) filter (where c.status <> 'archived' and not c.hidden),
         count(*) filter (where c.status = 'waiting' and not c.hidden),
         count(*) filter (where c.status = 'in_service' and not c.hidden),
         count(*) filter (where public.conv_ativa(c.status) and not c.ai_paused and not c.hidden),
         count(*) filter (where c.status = 'closed' and not c.hidden),
         count(*) filter (where c.status = 'archived'),
         count(*) filter (where c.hidden),
         count(*) filter (where c.unread_count > 0 and c.status <> 'archived' and not c.hidden)
  from public.conversations c
  where c.office_id = p_office and public.can_see_conversation(c.id);
$$;

-- -----------------------------------------------------------------------------
-- 4. Respostas rápidas e buckets de envio
-- Mídia de mensagem (messages.media / quick_replies): {"bucket": "respostas",
-- "storage_path": "<office_id>/arquivo.ogg", "mime_type": "audio/ogg",
-- "filename": "arquivo.ogg", "tipo": "audio|document|image|video"}.
-- -----------------------------------------------------------------------------
create table if not exists public.quick_replies (
  id         uuid primary key default gen_random_uuid(),
  office_id  uuid not null references public.offices(id) on delete cascade,
  group_name text not null default 'Geral',
  title      text not null,
  shortcut   text,
  kind       text not null default 'texto' check (kind in ('texto','audio','arquivo')),
  body       text,
  media_path text,                       -- caminho no bucket 'respostas', começando pelo office_id
  mime_type  text,
  active     boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint quick_replies_conteudo check (
    (kind = 'texto' and coalesce(btrim(body), '') <> '') or (kind in ('audio','arquivo') and media_path is not null))
);
create unique index if not exists quick_replies_shortcut_uidx on public.quick_replies (office_id, lower(shortcut)) where shortcut is not null and active;
select public.apply_office_rls('quick_replies', array['admin','advogado']);

do $$
declare b text;
begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_tables where schemaname = 'storage' and tablename = 'buckets') then
    foreach b in array array['respostas','pecas','contratos'] loop
      insert into storage.buckets (id, name, public) values (b, b, false) on conflict (id) do nothing;
      execute format('drop policy if exists %I on storage.objects', b || '_select');
      execute format($p$create policy %I on storage.objects for select to authenticated
        using (bucket_id = %L and public.is_office_member((storage.foldername(name))[1]::uuid))$p$, b || '_select', b);
      execute format('drop policy if exists %I on storage.objects', b || '_insert');
      execute format($p$create policy %I on storage.objects for insert to authenticated
        with check (bucket_id = %L and public.is_office_member((storage.foldername(name))[1]::uuid))$p$, b || '_insert', b);
      execute format('drop policy if exists %I on storage.objects', b || '_delete');
      execute format($p$create policy %I on storage.objects for delete to authenticated
        using (bucket_id = %L and public.is_office_member((storage.foldername(name))[1]::uuid))$p$, b || '_delete', b);
    end loop;
  end if;
end $$;

-- Normaliza a mídia: bucket permitido e caminho dentro da pasta do escritório.
create or replace function public.media_normalize(p_office uuid, p_media jsonb)
returns jsonb language plpgsql immutable set search_path = public as $$
declare v_bucket text := p_media->>'bucket'; v_path text := btrim(coalesce(p_media->>'storage_path', p_media->>'path', ''), '/');
        v_mime text := p_media->>'mime_type'; v_tipo text := p_media->>'tipo';
begin
  if p_media is null or p_media = 'null'::jsonb then return null; end if;
  if v_bucket is null and split_part(v_path, '/', 1) in ('respostas','provas','pecas','contratos') then
    v_bucket := split_part(v_path, '/', 1); v_path := substr(v_path, length(v_bucket) + 2);
  end if;
  if v_bucket is null or v_bucket not in ('respostas','provas','pecas','contratos') then
    raise exception 'bucket de mídia inválido: % (use respostas, provas, pecas ou contratos)', coalesce(v_bucket, '—');
  end if;
  if split_part(v_path, '/', 1) <> p_office::text then raise exception 'storage_path precisa começar pelo escritório: %/…', p_office; end if;
  if v_tipo is null then
    v_tipo := case when v_mime like 'audio/%' then 'audio' when v_mime like 'image/%' then 'image'
                   when v_mime like 'video/%' then 'video' else 'document' end;
  end if;
  if v_tipo not in ('audio','document','image','video') then raise exception 'tipo de mídia inválido: %', v_tipo; end if;
  return jsonb_build_object('bucket', v_bucket, 'storage_path', v_path, 'mime_type', v_mime, 'tipo', v_tipo,
    'filename', coalesce(nullif(p_media->>'filename', ''), regexp_replace(v_path, '^.*/', '')), 'caption', p_media->>'caption');
end; $$;

-- {{nome}}, {{primeiro_nome}}, {{escritorio}}, {{atendente}}
create or replace function public.quick_reply_fill(p_text text, p_conv uuid, p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select replace(replace(replace(replace(coalesce(p_text, ''),
           '{{nome}}', coalesce(ct.name, '')),
           '{{primeiro_nome}}', coalesce(split_part(btrim(ct.name), ' ', 1), '')),
           '{{escritorio}}', coalesce(o.name, '')),
           '{{atendente}}', case when p_user is null then 'Equipe' else public.user_nome(p_user) end)
  from public.conversations c join public.contacts ct on ct.id = c.contact_id join public.offices o on o.id = c.office_id
  where c.id = p_conv;
$$;

create or replace function public.quick_reply_render(p_quick_reply uuid, p_conv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q public.quick_replies; c public.conversations;
begin
  if auth.uid() is null then raise exception 'exige usuário'; end if;
  select * into c from public.conversations where id = p_conv;
  if c.id is null or not public.can_see_conversation(p_conv) then raise exception 'conversa não encontrada'; end if;
  select * into q from public.quick_replies where id = p_quick_reply and office_id = c.office_id and active;
  if q.id is null then raise exception 'resposta rápida não encontrada'; end if;
  return jsonb_build_object('quick_reply_id', q.id, 'kind', q.kind, 'body', nullif(public.quick_reply_fill(q.body, p_conv, auth.uid()), ''),
    'media', case when q.media_path is not null then public.media_normalize(c.office_id,
               jsonb_build_object('bucket', 'respostas', 'storage_path', q.media_path, 'mime_type', q.mime_type)) end);
end; $$;

-- Envio pela tela de conversa (texto, mídia ou resposta rápida). Grava a linha
-- pendente; o WA 03 envia. Enviar = assumir (takeover pelo gatilho).
create or replace function public.conversation_send(p_conv uuid, p_body text default null, p_media jsonb default null, p_quick_reply uuid default null)
returns public.messages language plpgsql security definer set search_path = public as $$
declare c public.conversations; m public.messages; v_body text := p_body; v_media jsonb; q jsonb;
begin
  c := public.conversation_guard(p_conv);
  if not public.conv_ativa(c.status) then raise exception 'conversa encerrada: reabra antes de enviar'; end if;
  if p_quick_reply is not null then
    q := public.quick_reply_render(p_quick_reply, p_conv);
    v_body := coalesce(nullif(btrim(p_body), ''), q->>'body');
    v_media := q->'media';
    if v_media = 'null'::jsonb then v_media := null; end if;
  end if;
  if p_media is not null then v_media := public.media_normalize(c.office_id, p_media); end if;
  if coalesce(btrim(v_body), '') = '' and v_media is null then raise exception 'mensagem vazia'; end if;
  if v_media is not null and v_media->>'caption' is null and v_media->>'tipo' in ('image','video','document') and v_body is not null then
    v_media := v_media || jsonb_build_object('caption', v_body);
  end if;
  insert into public.messages (office_id, conversation_id, direction, sender, body, media, status, sent_by, ai_meta)
  values (c.office_id, p_conv, 'out', 'humano', nullif(btrim(v_body), ''), v_media, 'pending', auth.uid(),
          case when p_quick_reply is not null then jsonb_build_object('quick_reply_id', p_quick_reply) end)
  returning * into m;
  return m;
end; $$;

-- -----------------------------------------------------------------------------
-- 5. Envio (WA 03): destino + mídia + trava da janela de 24h.
-- Só kind = 'chat', direction = 'out', status = 'pending'. Janela fechada sem
-- template → a linha vira failed com o motivo e o retorno vem com ok = false.
-- -----------------------------------------------------------------------------
create or replace function public.mensageria_envio(p_message uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare m public.messages; c public.conversations; d record; v_media jsonb; v_aberta boolean;
begin
  select * into m from public.messages where id = p_message;
  if m.id is null or m.direction <> 'out' or m.status <> 'pending' or m.kind <> 'chat' then
    return jsonb_build_object('ok', false, 'skip', true, 'message_id', p_message, 'motivo', 'não é envio pendente');
  end if;
  select * into c from public.conversations where id = m.conversation_id;
  v_aberta := coalesce(c.window_expires_at > now(), false);
  if not v_aberta and m.template is null then
    perform public.message_mark_failed(m.id, 'Janela de 24h fechada: use um template aprovado');
    return jsonb_build_object('ok', false, 'skip', false, 'message_id', m.id, 'motivo', 'Janela de 24h fechada: use um template aprovado');
  end if;
  begin
    v_media := public.media_normalize(m.office_id, m.media);
  exception when others then
    perform public.message_mark_failed(m.id, 'Mídia inválida: ' || sqlerrm);
    return jsonb_build_object('ok', false, 'skip', false, 'message_id', m.id, 'motivo', 'Mídia inválida: ' || sqlerrm);
  end;
  select * into d from public.mensageria_destino(m.id);
  return jsonb_build_object('ok', true, 'message_id', m.id, 'office_id', m.office_id, 'provider', d.provider,
    'body', m.body, 'template', m.template, 'wa_id', d.wa_id, 'phone_number_id', d.phone_number_id, 'token', d.token,
    'provider_config', d.provider_config, 'janela_aberta', v_aberta, 'media', v_media,
    'media_tipo', v_media->>'tipo', 'sign_path', case when v_media is not null then (v_media->>'bucket') || '/' || (v_media->>'storage_path') end);
end; $$;

-- -----------------------------------------------------------------------------
-- 6. Mensagens agendadas. O disparo (scheduled_dispatch, n8n a cada minuto)
-- grava a linha em messages com sender = 'sistema' (não vira takeover).
-- -----------------------------------------------------------------------------
create table if not exists public.scheduled_messages (
  id              uuid primary key default gen_random_uuid(),
  office_id       uuid not null references public.offices(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  body            text,
  media           jsonb,
  template        jsonb,
  send_at         timestamptz not null,
  status          text not null default 'pendente' check (status in ('pendente','enviada','cancelada','falhou')),
  error           text,
  created_by      uuid references auth.users(id),
  sent_message_id uuid references public.messages(id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint scheduled_messages_conteudo check (coalesce(btrim(body), '') <> '' or media is not null or template is not null)
);
create index if not exists scheduled_messages_due_idx on public.scheduled_messages (send_at) where status = 'pendente';
alter table public.scheduled_messages enable row level security;
drop policy if exists scheduled_messages_select on public.scheduled_messages;
create policy scheduled_messages_select on public.scheduled_messages for select to authenticated
  using (public.is_office_member(office_id) and public.can_see_conversation(conversation_id));
-- escrita só pelas RPCs
select public.add_to_realtime('scheduled_messages');

create or replace function public.scheduled_create(p_conv uuid, p_body text, p_send_at timestamptz, p_media jsonb default null, p_template jsonb default null)
returns public.scheduled_messages language plpgsql security definer set search_path = public as $$
declare c public.conversations; s public.scheduled_messages;
begin
  c := public.conversation_guard(p_conv);
  if p_send_at is null or p_send_at < now() - interval '1 minute' then raise exception 'informe uma data futura'; end if;
  if coalesce(btrim(p_body), '') = '' and p_media is null and p_template is null then raise exception 'mensagem vazia'; end if;
  if p_template is not null and not exists (select 1 from public.wa_templates t where t.office_id = c.office_id
        and t.name = p_template->>'name' and t.status = 'aprovado') then
    raise exception 'template não aprovado: %', p_template->>'name';
  end if;
  insert into public.scheduled_messages (office_id, conversation_id, body, media, template, send_at, created_by)
  values (c.office_id, p_conv, nullif(btrim(p_body), ''), public.media_normalize(c.office_id, p_media), p_template, p_send_at, auth.uid())
  returning * into s;
  perform public.log_event(c.office_id, c.lead_id, 'scheduled_created', 'humano', auth.uid(), null,
                           jsonb_build_object('scheduled_id', s.id, 'send_at', s.send_at), p_conv);
  return s;
end; $$;

create or replace function public.scheduled_cancel(p_id uuid)
returns public.scheduled_messages language plpgsql security definer set search_path = public as $$
declare s public.scheduled_messages; c public.conversations;
begin
  select * into s from public.scheduled_messages where id = p_id;
  if s.id is null then raise exception 'agendamento não encontrado'; end if;
  c := public.conversation_guard(s.conversation_id);
  if s.status <> 'pendente' then raise exception 'agendamento já %', s.status; end if;
  update public.scheduled_messages set status = 'cancelada', updated_at = now() where id = p_id returning * into s;
  perform public.log_event(c.office_id, c.lead_id, 'scheduled_cancelled', 'humano', auth.uid(), null,
                           jsonb_build_object('scheduled_id', s.id), s.conversation_id);
  return s;
end; $$;

create or replace function public.scheduled_dispatch(p_limit int default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.scheduled_messages; c public.conversations; m uuid; n_ok int := 0; n_falha int := 0; v_err text;
begin
  for s in select * from public.scheduled_messages where status = 'pendente' and send_at <= now()
            order by send_at limit p_limit for update skip locked
  loop
    select * into c from public.conversations where id = s.conversation_id;
    v_err := case
      when not public.conv_ativa(c.status) then 'Conversa encerrada'
      when s.template is null and not coalesce(c.window_expires_at > now(), false) then 'Janela de 24h fechada: use um template aprovado'
      end;
    if v_err is not null then
      update public.scheduled_messages set status = 'falhou', error = v_err, updated_at = now() where id = s.id;
      perform public.log_event(c.office_id, c.lead_id, 'scheduled_failed', 'sistema', null, null,
                               jsonb_build_object('scheduled_id', s.id, 'error', v_err), c.id);
      n_falha := n_falha + 1;
      continue;
    end if;
    insert into public.messages (office_id, conversation_id, direction, sender, body, media, template, status, sent_by, ai_meta)
    values (c.office_id, c.id, 'out', 'sistema', s.body, s.media, s.template, 'pending', s.created_by,
            jsonb_build_object('scheduled_id', s.id))
    returning id into m;
    update public.scheduled_messages set status = 'enviada', sent_message_id = m, updated_at = now() where id = s.id;
    perform public.log_event(c.office_id, c.lead_id, 'scheduled_sent', 'sistema', null, null,
                             jsonb_build_object('scheduled_id', s.id, 'message_id', m), c.id);
    n_ok := n_ok + 1;
  end loop;
  return jsonb_build_object('enviadas', n_ok, 'falharam', n_falha);
end; $$;

-- -----------------------------------------------------------------------------
-- 7. Templates da Meta: sincronização e envio para aprovação (n8n 12)
-- -----------------------------------------------------------------------------
alter table public.wa_templates
  add column if not exists whatsapp_number_id uuid references public.whatsapp_numbers(id) on delete set null,
  add column if not exists components jsonb,
  add column if not exists rejected_reason text,
  add column if not exists last_sync_at timestamptz,
  add column if not exists submit_requested_at timestamptz,
  add column if not exists submitted_at timestamptz,
  add column if not exists submit_error text;
alter table public.wa_templates drop constraint if exists wa_templates_status_check;
alter table public.wa_templates add constraint wa_templates_status_check
  check (status in ('pendente','aprovado','rejeitado','pausado','desativado'));

create or replace function public.wa_template_status(p_meta text)
returns text language sql immutable set search_path = public as $$
  select case upper(coalesce(p_meta, '')) when 'APPROVED' then 'aprovado' when 'REJECTED' then 'rejeitado'
              when 'PAUSED' then 'pausado' when 'DISABLED' then 'desativado' else 'pendente' end;
$$;

-- Números com WABA para o GET /{waba_id}/message_templates (service_role).
create or replace function public.templates_sync_targets()
returns table(whatsapp_number_id uuid, office_id uuid, waba_id text, token text)
language sql stable security definer set search_path = public as $$
  select wn.id, wn.office_id, wn.waba_id, (select s.decrypted_secret from vault.decrypted_secrets s where s.name = wn.token_secret_name)
  from public.whatsapp_numbers wn
  where wn.active and wn.waba_id is not null
    and public.mensageria_provider(wn.office_id) = 'meta_whatsapp';
$$;

-- Aplica a lista "data" da Meta. Atualiza os conhecidos e cadastra os criados direto no Gerenciador.
create or replace function public.templates_sync_apply(p_number uuid, p_templates jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare wn public.whatsapp_numbers; t jsonb; v_body text; n_upd int := 0; n_new int := 0; v_id uuid; v_existia boolean;
begin
  select * into wn from public.whatsapp_numbers where id = p_number;
  if wn.id is null then raise exception 'número não encontrado'; end if;
  for t in select * from jsonb_array_elements(coalesce(p_templates, '[]'::jsonb)) loop
    select c->>'text' into v_body from jsonb_array_elements(coalesce(t->'components', '[]'::jsonb)) c where upper(c->>'type') = 'BODY' limit 1;
    select id into v_id from public.wa_templates where office_id = wn.office_id and name = t->>'name' and language = coalesce(t->>'language', 'pt_BR');
    v_existia := v_id is not null;
    insert into public.wa_templates (office_id, name, language, category, body, params, status, meta_id, whatsapp_number_id, components,
                                     rejected_reason, last_sync_at, submitted_at, updated_at)
    values (wn.office_id, t->>'name', coalesce(t->>'language', 'pt_BR'), coalesce(upper(t->>'category'), 'UTILITY'), coalesce(v_body, ''),
            (select count(distinct x[1]) from regexp_matches(coalesce(v_body, ''), '\{\{(\d+)\}\}', 'g') x),
            public.wa_template_status(t->>'status'), t->>'id', wn.id, t->'components',
            nullif(t->>'rejected_reason', 'NONE'), now(), now(), now())
    on conflict (office_id, name, language) do update
      set status = excluded.status, meta_id = excluded.meta_id, category = excluded.category,
          whatsapp_number_id = coalesce(public.wa_templates.whatsapp_number_id, excluded.whatsapp_number_id),
          components = excluded.components, rejected_reason = excluded.rejected_reason, last_sync_at = now(),
          body = case when excluded.body <> '' then excluded.body else public.wa_templates.body end,
          submitted_at = coalesce(public.wa_templates.submitted_at, now()), submit_error = null, updated_at = now();
    if v_existia then n_upd := n_upd + 1; else n_new := n_new + 1; end if;
  end loop;
  return jsonb_build_object('atualizados', n_upd, 'novos', n_new, 'office_id', wn.office_id);
end; $$;

-- Pedido de aprovação feito pelo admin; o n8n 12 envia (webhook ou varredura).
create or replace function public.ui_template_submit(p_template uuid)
returns public.wa_templates language plpgsql security definer set search_path = public as $$
declare t public.wa_templates;
begin
  select * into t from public.wa_templates where id = p_template;
  if t.id is null or public.member_role(t.office_id) <> 'admin' then raise exception 'template não encontrado'; end if;
  if t.status = 'aprovado' then raise exception 'template já aprovado'; end if;
  update public.wa_templates set submit_requested_at = now(), submit_error = null, updated_at = now()
   where id = p_template returning * into t;
  return t;
end; $$;

create or replace function public.templates_pending_submit()
returns setof uuid language sql stable security definer set search_path = public as $$
  select t.id from public.wa_templates t
  where t.submit_requested_at is not null and (t.submitted_at is null or t.submitted_at < t.submit_requested_at)
  order by t.submit_requested_at limit 20;
$$;

-- Corpo do POST /{waba_id}/message_templates. Só para templates pedidos por um admin.
create or replace function public.template_submit_payload(p_template uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.wa_templates; wn public.whatsapp_numbers; o public.offices; v_ex jsonb;
begin
  select * into t from public.wa_templates where id = p_template;
  if t.id is null or t.submit_requested_at is null then
    return jsonb_build_object('ok', false, 'motivo', 'template sem pedido de envio');
  end if;
  select * into o from public.offices where id = t.office_id;
  select * into wn from public.whatsapp_numbers
   where id = coalesce(t.whatsapp_number_id, (select x.id from public.whatsapp_numbers x where x.office_id = t.office_id and x.active and x.waba_id is not null order by x.created_at limit 1));
  if wn.id is null or wn.waba_id is null then
    return jsonb_build_object('ok', false, 'template_id', t.id, 'motivo', 'escritório sem número com WABA');
  end if;
  select coalesce(jsonb_agg(case g when 1 then 'Maria' when 2 then coalesce(o.name, 'Escritório') else 'exemplo' end order by g), '[]'::jsonb)
    into v_ex from generate_series(1, greatest(t.params, 0)) g;
  return jsonb_build_object('ok', true, 'template_id', t.id, 'whatsapp_number_id', wn.id, 'waba_id', wn.waba_id,
    'token', (select s.decrypted_secret from vault.decrypted_secrets s where s.name = wn.token_secret_name),
    'payload', jsonb_build_object('name', t.name, 'language', t.language, 'category', t.category,
      'components', coalesce(t.components, jsonb_build_array(
        case when t.params > 0 then jsonb_build_object('type', 'BODY', 'text', t.body, 'example', jsonb_build_object('body_text', jsonb_build_array(v_ex)))
             else jsonb_build_object('type', 'BODY', 'text', t.body) end))));
end; $$;

create or replace function public.template_submitted(p_template uuid, p_meta_id text, p_status text, p_error text default null)
returns public.wa_templates language plpgsql security definer set search_path = public as $$
declare t public.wa_templates;
begin
  update public.wa_templates
     set meta_id = coalesce(p_meta_id, meta_id),
         status = case when p_error is not null then status else public.wa_template_status(p_status) end,
         submitted_at = case when p_error is null then now() else submitted_at end,
         submit_requested_at = case when p_error is null then submit_requested_at else null end,
         submit_error = left(p_error, 500), updated_at = now()
   where id = p_template returning * into t;
  return t;
end; $$;

-- -----------------------------------------------------------------------------
-- 8. Mesclar conversas (mesmo escritório). Mantém p_keep; p_from é arquivada.
-- Leads diferentes: move mensagens, tarefas e provas; mesmo lead: só mensagens.
-- -----------------------------------------------------------------------------
create or replace function public.conversation_merge(p_keep uuid, p_from uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k public.conversations; f public.conversations; n_msg int := 0; n_task int := 0; n_ev int := 0; v_me uuid := auth.uid();
begin
  if p_keep = p_from then raise exception 'escolha duas conversas diferentes'; end if;
  k := public.conversation_guard(p_keep);
  f := public.conversation_guard(p_from);
  if k.office_id <> f.office_id then raise exception 'conversas de escritórios diferentes'; end if;
  if k.lead_id <> f.lead_id
     and exists (select 1 from public.contracts x where x.lead_id = k.lead_id and x.status = 'assinado')
     and exists (select 1 from public.contracts x where x.lead_id = f.lead_id and x.status = 'assinado') then
    raise exception 'os dois casos têm contrato assinado: não é possível mesclar';
  end if;

  update public.messages set conversation_id = p_keep where conversation_id = p_from;
  get diagnostics n_msg = row_count;
  if k.lead_id <> f.lead_id then
    update public.tasks set lead_id = k.lead_id where lead_id = f.lead_id;
    get diagnostics n_task = row_count;
    update public.evidences set lead_id = k.lead_id where lead_id = f.lead_id;
    get diagnostics n_ev = row_count;
  end if;

  update public.conversations c
     set last_message_at = x.ult, last_message_preview = x.prev,
         window_expires_at = greatest(k.window_expires_at, f.window_expires_at),
         unread_count = k.unread_count + f.unread_count
    from (select max(m.created_at) as ult,
                 (select left(coalesce(m2.body, '[mídia]'), 140) from public.messages m2 where m2.conversation_id = p_keep and m2.kind = 'chat' order by m2.created_at desc limit 1) as prev
            from public.messages m where m.conversation_id = p_keep and m.kind = 'chat') x
   where c.id = p_keep;
  update public.conversations set status = 'archived', unread_count = 0, last_message_preview = 'Mesclada em outra conversa' where id = p_from;

  perform public.conversation_event(p_keep, 'conversation_merged', 'Conversa mesclada por ' || public.user_nome(v_me) || ' (' || n_msg || ' mensagens)',
                                    'humano', v_me, jsonb_build_object('from', p_from, 'from_lead', f.lead_id, 'mensagens', n_msg, 'tarefas', n_task, 'provas', n_ev));
  perform public.conversation_event(p_from, 'conversation_merged_into', 'Mesclada na conversa principal por ' || public.user_nome(v_me),
                                    'humano', v_me, jsonb_build_object('into', p_keep, 'into_lead', k.lead_id));
  return jsonb_build_object('keep', p_keep, 'from', p_from, 'mensagens', n_msg, 'tarefas', n_task, 'provas', n_ev);
end; $$;

-- -----------------------------------------------------------------------------
-- 9. Origem do anúncio (Click-to-WhatsApp)
-- -----------------------------------------------------------------------------
create or replace function public.lead_set_referral(p_lead uuid, p_referral jsonb, p_new_lead boolean default false)
returns public.leads language plpgsql security definer set search_path = public as $$
declare l public.leads; v_ref jsonb;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null or p_referral is null or p_referral = 'null'::jsonb then return l; end if;
  if l.ad_referral is not null then return l; end if;            -- vale o primeiro anúncio
  v_ref := jsonb_strip_nulls(jsonb_build_object(
    'source_id', p_referral->>'source_id', 'source_type', p_referral->>'source_type', 'headline', p_referral->>'headline',
    'body', p_referral->>'body', 'ctwa_clid', p_referral->>'ctwa_clid', 'source_url', p_referral->>'source_url',
    'media_type', p_referral->>'media_type', 'recebido_em', now()));
  update public.leads set ad_referral = v_ref, source = case when p_new_lead then 'meta_ads' else source end
   where id = p_lead returning * into l;
  perform public.log_event(l.office_id, l.id, 'ad_referral', 'sistema', null, null, v_ref);
  return l;
end; $$;

create or replace view public.v_marketing_anuncios with (security_invoker = true) as
select l.office_id,
       l.ad_referral->>'source_id' as anuncio_id,
       max(l.ad_referral->>'headline') as anuncio_titulo,
       max(l.ad_referral->>'source_type') as tipo,
       max(l.ad_referral->>'source_url') as url,
       count(*) as leads,
       count(*) filter (where exists (select 1 from public.lead_qualification q where q.lead_id = l.id and q.passed)) as qualificados,
       count(*) filter (where exists (select 1 from public.contracts k where k.lead_id = l.id and k.status = 'assinado')) as assinados,
       min(l.created_at) as primeiro_lead_em, max(l.created_at) as ultimo_lead_em
from public.leads l
where l.ad_referral is not null
group by l.office_id, l.ad_referral->>'source_id';
grant select on public.v_marketing_anuncios to authenticated;

-- -----------------------------------------------------------------------------
-- 1b. Etiquetas na saída do agente: apply_agent_effects ganha p_tags (11º).
-- A versão de 10 parâmetros sai (a chamada com 10 continua valendo: p_tags tem default).
-- -----------------------------------------------------------------------------
drop function if exists public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb);
create or replace function public.apply_agent_effects(p_lead uuid, p_conversation uuid, p_agent_role text, p_case_data jsonb DEFAULT NULL::jsonb, p_advance_to text DEFAULT NULL::text, p_advance_reason text DEFAULT NULL::text, p_intervention jsonb DEFAULT NULL::jsonb, p_task jsonb DEFAULT NULL::jsonb, p_contract jsonb DEFAULT NULL::jsonb, p_briefing jsonb DEFAULT NULL::jsonb, p_tags jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
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
  t public.tags; v_tag text; v_tag_ok text[] := '{}'; v_tag_ign text[] := '{}';
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

  -- 017: etiquetas. Só existentes e ativas; desconhecidas são ignoradas e
  -- registradas no ai_meta da última resposta da IA nesta conversa.
  if p_tags is not null and jsonb_typeof(p_tags) = 'array' and jsonb_array_length(p_tags) > 0 then
    for v_tag in select btrim(x) from jsonb_array_elements_text(p_tags) x where btrim(x) <> '' loop
      t := public.tag_find(l.office_id, v_tag);
      if t.id is not null and t.active then
        perform public.lead_tag_apply(p_lead, t, true, 'ia', null, v_role);
        v_tag_ok := array_append(v_tag_ok, t.name);
      else
        v_tag_ign := array_append(v_tag_ign, v_tag);
      end if;
    end loop;
    if cardinality(v_tag_ign) > 0 and p_conversation is not null then
      update public.messages m set ai_meta = coalesce(m.ai_meta, '{}'::jsonb) || jsonb_build_object('tags_ignoradas', to_jsonb(v_tag_ign))
       where m.id = (select m2.id from public.messages m2 where m2.conversation_id = p_conversation and m2.sender = 'ia'
                     order by m2.created_at desc limit 1);
    end if;
    v_result := v_result || jsonb_build_object('tags', to_jsonb(v_tag_ok), 'tags_ignoradas', to_jsonb(v_tag_ign));
  end if;

  return v_result || jsonb_build_object('agent_role', v_role);
end;
$$;

-- Contexto de etiquetas para o agente (WA 02 põe no prompt): as disponíveis e as do lead.
create or replace function public.agent_tags_context(p_lead uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'disponiveis', coalesce((select jsonb_agg(t.name order by t.name) from public.tags t where t.office_id = l.office_id and t.active), '[]'::jsonb),
    'do_lead', coalesce((select jsonb_agg(t.name order by t.name) from public.lead_tags lt join public.tags t on t.id = lt.tag_id where lt.lead_id = l.id), '[]'::jsonb))
  from public.leads l where l.id = p_lead;
$$;

-- Prompts padrão (globais): uma linha sobre etiquetas. Prompts próprios do
-- escritório não mudam; o formato de saída (com "tags" opcional) vem do WA 02.
update public.agent_prompts p
   set system_prompt = replace(p.system_prompt, '- Saída: SOMENTE o JSON no formato que o sistema pede.',
         '- Etiquetas: se a conversa deixar claro, devolva "tags" com nomes da lista de etiquetas disponíveis (ex.: "Urgente", "Indicação", "Estrangeiro"). Nunca invente etiqueta e nunca use etiqueta para indicar etapa.' || chr(10) ||
         '- Saída: SOMENTE o JSON no formato que o sistema pede.'),
       updated_at = now()
  from public.agents a
 where a.id = p.agent_id and a.office_id is null
   and p.system_prompt like '%- Saída: SOMENTE o JSON no formato que o sistema pede.%'
   and p.system_prompt not like '%- Etiquetas: se a conversa deixar claro%';

-- -----------------------------------------------------------------------------
-- 12. Modelos de petição editáveis pelo escritório
-- piece_templates continua interna (sem policy para o escritório). O escritório
-- edita por RPC: a edição vira uma linha própria (office_id, code) que sobrepõe
-- o padrão; restaurar apaga a sobreposição. Toda gravação gera uma versão.
-- -----------------------------------------------------------------------------
create table if not exists public.piece_template_versions (
  id        uuid primary key default gen_random_uuid(),
  office_id uuid not null references public.offices(id) on delete cascade,
  code      text not null,
  versao    int not null,
  acao      text not null default 'salvar' check (acao in ('salvar','restaurar')),
  name      text, tese text, kind text, body text, required boolean, ordem int, active boolean,
  saved_by  uuid references auth.users(id),
  saved_at  timestamptz not null default now(),
  unique (office_id, code, versao)
);
alter table public.piece_template_versions enable row level security;
drop policy if exists piece_template_versions_select on public.piece_template_versions;
create policy piece_template_versions_select on public.piece_template_versions for select to authenticated
  using (public.is_office_member(office_id) and public.member_role(office_id) in ('admin','advogado'));
-- escrita só pelas RPCs

-- Teses próprias do escritório: tese do briefing → código do modelo.
create table if not exists public.piece_tese_aliases (
  office_id uuid not null references public.offices(id) on delete cascade,
  tese      text not null,
  code      text not null,
  primary key (office_id, tese, code)
);
alter table public.piece_tese_aliases enable row level security;
drop policy if exists piece_tese_aliases_select on public.piece_tese_aliases;
create policy piece_tese_aliases_select on public.piece_tese_aliases for select to authenticated
  using (public.is_office_member(office_id));

create or replace function public.piece_tese_codes_office(p_office uuid, p_teses text[])
returns text[] language sql stable set search_path = public as $$
  select coalesce(array_agg(distinct c), '{}') from (
    select unnest(public.piece_tese_codes(p_teses)) as c
    union all
    select upper(a.code) from public.piece_tese_aliases a
    join unnest(coalesce(p_teses, '{}')) as u(tt) on lower(u.tt) = a.tese
    where a.office_id = p_office
  ) z where c is not null;
$$;

-- Modelo vigente por código (escritório sobrepõe o padrão; a sobreposição
-- inativa desliga o padrão para o escritório).
create or replace function public.piece_templates_vigentes(p_office uuid)
returns setof public.piece_templates language sql stable security definer set search_path = public as $$
  select distinct on (pt.code) pt.* from public.piece_templates pt
  where (pt.office_id = p_office or pt.office_id is null) and pt.code is not null
  order by pt.code, pt.office_id nulls last;
$$;

-- piece_render (016) com teses do escritório e sobreposição inativa. Mesma assinatura.
create or replace function public.piece_render(p_piece uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  pc public.pieces; v_teses text[]; v_codes text[]; v_texto text; v_ctx jsonb; v_out text;
  v_blocos text[]; v_tpl_teses text[];
begin
  select * into pc from public.pieces where id = p_piece;
  if pc.id is null then raise exception 'peça % não existe', p_piece; end if;
  select array(select distinct x from unnest(coalesce(b.teses, '{}') || array[pc.tese]) x where x is not null)
    into v_teses from (select 1) z left join public.briefings b on b.lead_id = pc.lead_id;
  v_codes := public.piece_tese_codes_office(pc.office_id, v_teses);

  with tpl as (
    select t.kind, t.code, t.ordem, t.body from public.piece_templates_vigentes(pc.office_id) t
    where t.active
      and ((t.kind = 'bloco' and t.required)
        or (t.kind = 'tese' and upper(t.code) = any (v_codes) and t.body not like '%{{cabecalho}}%'))
  ), corte as (
    select coalesce((select ordem from tpl where kind = 'bloco' and code = 'ABERTURA_PEDIDOS'),
                    (select max(ordem) from tpl where kind = 'bloco')) as v
  ), x as (
    select tpl.*, case when kind = 'tese' then 2 when corte.v is null or ordem < corte.v then 1 else 3 end as grupo from tpl, corte
  )
  select string_agg(body, E'\n\n' order by grupo, ordem, code),
         array_agg(code order by grupo, ordem, code) filter (where kind = 'bloco'),
         array_agg(code order by grupo, ordem, code) filter (where kind = 'tese')
    into v_texto, v_blocos, v_tpl_teses
  from x;

  v_ctx := public.piece_fill_context(pc.lead_id);
  v_out := public.piece_fill_text(v_texto, v_ctx);
  return jsonb_build_object(
    'piece_id', pc.id, 'lead_id', pc.lead_id,
    'texto', v_out,
    'blocos', to_jsonb(coalesce(v_blocos, '{}')), 'teses', to_jsonb(coalesce(v_tpl_teses, '{}')), 'teses_pedidas', to_jsonb(v_teses),
    'ia', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'descricao', p.descricao, 'formato', p.formato) order by m.code), '[]'::jsonb)
             from (select distinct x[1] as code from regexp_matches(v_out, '\{\{IA:([^{}]+)\}\}', 'g') x) m
             left join public.piece_placeholders p on p.code = m.code),
    'manual', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'descricao', p.descricao) order by m.code), '[]'::jsonb)
                 from (select distinct x[1] as code from regexp_matches(v_out, '\[PREENCHER: ([^\]]+)\]', 'g') x) m
                 left join public.piece_placeholders p on p.code = m.code));
end; $$;

-- {{X}} usados no texto e os que o sistema não conhece ({{IA:...}} é campo da IA).
create or replace function public.modelo_placeholders(p_body text)
returns table(usados text[], desconhecidos text[]) language sql stable set search_path = public as $$
  with u as (select distinct x[1] as code from regexp_matches(coalesce(p_body, ''), '\{\{\s*([^{}]+?)\s*\}\}', 'g') x)
  select coalesce(array_agg(code order by code), '{}'),
         coalesce(array_agg(code order by code) filter (where code not like 'IA:%'
                    and not exists (select 1 from public.piece_placeholders p where p.code = u.code)), '{}')
  from u;
$$;

create or replace function public.modelos_guard(p_office uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(public.member_role(p_office), '') not in ('admin','advogado') then
    raise exception 'só admin ou advogado do escritório edita modelos';
  end if;
end; $$;

create or replace function public.ui_placeholders()
returns table(code text, fonte text, formato text, se_vazio text, descricao text, laquila boolean)
language sql stable security definer set search_path = public as $$
  select p.code, p.fonte, p.formato, p.se_vazio, p.descricao, p.laquila from public.piece_placeholders p order by p.laquila desc, p.code;
$$;

create or replace function public.ui_modelos(p_office uuid)
returns table(code text, name text, tese text, kind text, required boolean, ordem int, active boolean, body text, origem text,
              tem_padrao boolean, placeholders text[], desconhecidos text[], updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.modelos_guard(p_office);
  return query
  select t.code, t.name, t.tese, t.kind, t.required, t.ordem, t.active, t.body,
         case when t.office_id is null then 'padrao' else 'escritorio' end,
         exists (select 1 from public.piece_templates g where g.office_id is null and g.code = t.code),
         mp.usados, mp.desconhecidos, t.updated_at
  from public.piece_templates_vigentes(p_office) t
  cross join lateral public.modelo_placeholders(t.body) mp
  order by t.kind, t.ordem, t.code;
end; $$;

create or replace function public.modelo_versionar(p_office uuid, p_code text, p_acao text)
returns int language plpgsql security definer set search_path = public as $$
declare t public.piece_templates; v int;
begin
  select * into t from public.piece_templates_vigentes(p_office) x where x.code = p_code;
  select coalesce(max(versao), 0) + 1 into v from public.piece_template_versions where office_id = p_office and code = p_code;
  insert into public.piece_template_versions (office_id, code, versao, acao, name, tese, kind, body, required, ordem, active, saved_by)
  values (p_office, p_code, v, p_acao, t.name, t.tese, t.kind, t.body, t.required, t.ordem, t.active, auth.uid());
  return v;
end; $$;

create or replace function public.ui_modelo_salvar(p_office uuid, p_code text, p_name text, p_tese text, p_kind text, p_body text,
                                                   p_required boolean default null, p_ordem int default null, p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text := upper(regexp_replace(btrim(coalesce(p_code, '')), '[^A-Za-z0-9_]+', '_', 'g'));
  g public.piece_templates; o public.piece_templates; v_novo boolean; v int; mp record; v_tese text;
begin
  perform public.modelos_guard(p_office);
  if v_code = '' then raise exception 'informe o código do modelo'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'o texto do modelo está vazio'; end if;
  select * into g from public.piece_templates where office_id is null and code = v_code;
  select * into o from public.piece_templates where office_id = p_office and code = v_code;
  v_novo := g.id is null and o.id is null;
  if coalesce(p_kind, g.kind, o.kind, 'tese') not in ('tese','bloco') then raise exception 'tipo inválido: use tese ou bloco'; end if;
  v_tese := lower(btrim(coalesce(nullif(btrim(p_tese), ''), o.tese, g.tese, v_code)));

  if o.id is null then
    insert into public.piece_templates (office_id, code, name, tese, kind, body, required, ordem, active, required_evidence)
    values (p_office, v_code, coalesce(nullif(btrim(p_name), ''), g.name, v_code), v_tese, coalesce(p_kind, g.kind, 'tese'), p_body,
            coalesce(p_required, g.required, false), coalesce(p_ordem, g.ordem, 100), coalesce(p_active, true),
            coalesce(g.required_evidence, '[]'::jsonb))
    returning * into o;
  else
    update public.piece_templates
       set name = coalesce(nullif(btrim(p_name), ''), name), tese = v_tese, kind = coalesce(p_kind, kind), body = p_body,
           required = coalesce(p_required, required), ordem = coalesce(p_ordem, ordem), active = coalesce(p_active, active), updated_at = now()
     where id = o.id returning * into o;
  end if;

  if o.kind = 'tese' and g.id is null then
    insert into public.piece_tese_aliases (office_id, tese, code) values (p_office, v_tese, v_code) on conflict do nothing;
  end if;
  v := public.modelo_versionar(p_office, v_code, 'salvar');
  select * into mp from public.modelo_placeholders(p_body);
  return jsonb_build_object('ok', true, 'code', v_code, 'origem', 'escritorio', 'novo', v_novo, 'versao', v,
    'placeholders', to_jsonb(mp.usados), 'desconhecidos', to_jsonb(mp.desconhecidos),
    'avisos', (select coalesce(jsonb_agg('Placeholder desconhecido: {{' || d || '}} (vai sair como está na peça)'), '[]'::jsonb)
                 from unnest(mp.desconhecidos) d));
end; $$;

create or replace function public.ui_modelo_restaurar(p_office uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g public.piece_templates; o public.piece_templates; v int;
begin
  perform public.modelos_guard(p_office);
  select * into g from public.piece_templates where office_id is null and code = upper(p_code);
  select * into o from public.piece_templates where office_id = p_office and code = upper(p_code);
  if o.id is null then return jsonb_build_object('ok', true, 'code', upper(p_code), 'origem', 'padrao', 'alterado', false); end if;
  if g.id is null then raise exception 'modelo próprio do escritório, sem padrão para restaurar: desative-o'; end if;
  update public.pieces set template_id = g.id where template_id = o.id;
  delete from public.piece_templates where id = o.id;
  v := public.modelo_versionar(p_office, g.code, 'restaurar');
  return jsonb_build_object('ok', true, 'code', g.code, 'origem', 'padrao', 'alterado', true, 'versao', v);
end; $$;

create or replace function public.ui_modelo_versoes(p_office uuid, p_code text)
returns table(versao int, acao text, name text, tese text, kind text, body text, required boolean, ordem int, active boolean,
              saved_by uuid, saved_by_nome text, saved_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.modelos_guard(p_office);
  return query
  select v.versao, v.acao, v.name, v.tese, v.kind, v.body, v.required, v.ordem, v.active, v.saved_by,
         case when v.saved_by is not null then public.user_nome(v.saved_by) end, v.saved_at
  from public.piece_template_versions v where v.office_id = p_office and v.code = upper(p_code)
  order by v.versao desc;
end; $$;

-- Prévia com os dados de um lead do escritório; o que faltar sai [PREENCHER: X].
create or replace function public.ui_modelo_preview(p_office uuid, p_code text, p_lead uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.piece_templates; v_out text;
begin
  perform public.modelos_guard(p_office);
  if not exists (select 1 from public.leads l where l.id = p_lead and l.office_id = p_office) then raise exception 'caso não encontrado'; end if;
  select * into t from public.piece_templates_vigentes(p_office) x where x.code = upper(p_code);
  if t.id is null then raise exception 'modelo não encontrado: %', p_code; end if;
  v_out := public.piece_fill_text(t.body, public.piece_fill_context(p_lead));
  v_out := regexp_replace(v_out, '\{\{\s*(IA:)?([^{}]+?)\s*\}\}', '[PREENCHER: \2]', 'g');
  return jsonb_build_object('code', t.code, 'origem', case when t.office_id is null then 'padrao' else 'escritorio' end,
    'texto', v_out,
    'faltando', (select coalesce(jsonb_agg(distinct x[1]), '[]'::jsonb) from regexp_matches(v_out, '\[PREENCHER: ([^\]]+)\]', 'g') x));
end; $$;

-- -----------------------------------------------------------------------------
-- Seed por escritório (novo e existentes): etiquetas, departamentos, expediente,
-- templates. Só semeia o que o escritório ainda não tem.
-- -----------------------------------------------------------------------------
create or replace function public.seed_office_defaults(p_office uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.tags where office_id = p_office) then
    insert into public.tags (office_id, name, color, description, kind) values
      (p_office, 'Urgente',     '#DC2626', 'Precisa de atenção rápida', 'sistema'),
      (p_office, 'Indicação',   '#16A34A', 'Chegou por indicação', 'sistema'),
      (p_office, 'Reincidente', '#9333EA', 'Já foi atendido antes', 'sistema'),
      (p_office, 'Remarketing', '#EA580C', 'Retomado por campanha', 'sistema'),
      (p_office, 'Estrangeiro', '#0891B2', 'Trabalhador estrangeiro', 'sistema'),
      (p_office, 'Cliente VIP', '#CA8A04', 'Atendimento prioritário', 'sistema')
    on conflict do nothing;
  end if;
  if not exists (select 1 from public.departments where office_id = p_office) then
    insert into public.departments (office_id, name, color, ai_default) values
      (p_office, 'Triagem IA', '#2563EB', true),
      (p_office, 'Advogado',   '#0F766E', false)
    on conflict do nothing;
  end if;
  if not exists (select 1 from public.office_hours where office_id = p_office) then
    insert into public.office_hours (office_id, weekday, start_at, end_at)
    select p_office, d, '08:00', '18:00' from generate_series(1, 5) d
    on conflict do nothing;
  end if;
  insert into public.wa_templates (office_id, name, language, category, body, params, status) values
    (p_office, 'edem_followup', 'pt_BR', 'UTILITY',
     'Olá, {{1}}! Aqui é do {{2}}. Estamos dando continuidade ao seu atendimento. Podemos seguir com a conversa por aqui?', 2, 'pendente'),
    (p_office, 'edem_lembrete_documentos', 'pt_BR', 'UTILITY',
     'Olá, {{1}}! O {{2}} lembra que ainda faltam alguns documentos para darmos andamento ao seu caso. Pode enviá-los por aqui quando puder?', 2, 'pendente'),
    (p_office, 'edem_aviso_contrato', 'pt_BR', 'UTILITY',
     'Olá, {{1}}! O {{2}} enviou o contrato para sua assinatura digital. Se tiver qualquer dúvida, é só responder esta mensagem.', 2, 'pendente')
  on conflict (office_id, name, language) do nothing;
end; $$;

create or replace function public.offices_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.office_params (office_id) values (new.id) on conflict do nothing;
  perform public.seed_office_defaults(new.id);
  return new;
end; $$;

select public.seed_office_defaults(o.id) from public.offices o;

-- Conversas existentes sem departamento: IA ativa → Triagem IA; pausada → Advogado.
update public.conversations c
   set department_id = (select d.id from public.departments d
                         where d.office_id = c.office_id and d.active
                           and (case when c.ai_paused then not d.ai_default else d.ai_default end)
                         order by d.created_at limit 1)
 where c.department_id is null;

-- -----------------------------------------------------------------------------
-- Permissões. O 010 concede authenticated em tudo; aqui o que é só do n8n volta
-- para service_role.
-- -----------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.mensageria_envio(uuid)',
    'public.scheduled_dispatch(integer)',
    'public.templates_sync_targets()',
    'public.templates_sync_apply(uuid, jsonb)',
    'public.templates_pending_submit()',
    'public.template_submit_payload(uuid)',
    'public.template_submitted(uuid, text, text, text)',
    'public.lead_set_referral(uuid, jsonb, boolean)',
    'public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb, jsonb)',
    'public.agent_tags_context(uuid)',
    'public.lead_tag_apply(uuid, public.tags, boolean, text, uuid, text)',
    'public.conversation_event(uuid, text, text, text, uuid, jsonb, text)',
    'public.notify(uuid, text, jsonb)',
    'public.conversation_recipients(uuid)',
    'public.quick_reply_fill(text, uuid, uuid)',
    'public.seed_office_defaults(uuid)',
    'public.modelo_versionar(uuid, text, text)',
    'public.piece_templates_vigentes(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
