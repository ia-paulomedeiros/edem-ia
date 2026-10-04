-- =============================================================================
-- 017c — parte 3 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017b. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- ---------- Verificação da parte 017c: deve voltar uma linha com resultado = OK
select '017c' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função conversas_counts', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversas_counts')),
    ('função conversation_archive', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_archive')),
    ('função conversation_assign', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_assign')),
    ('função conversation_close', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_close')),
    ('função conversation_event', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_event')),
    ('função conversation_guard', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_guard')),
    ('função conversation_hide', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_hide')),
    ('função conversation_mark_read', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_mark_read')),
    ('função conversation_note', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_note')),
    ('função conversation_reopen', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_reopen')),
    ('função conversation_send', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_send')),
    ('função conversation_set_ai', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_set_ai')),
    ('função conversation_status_titulo', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_status_titulo')),
    ('função conversation_transfer_department', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_transfer_department')),
    ('função media_normalize', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'media_normalize')),
    ('função quick_reply_fill', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'quick_reply_fill')),
    ('função quick_reply_render', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'quick_reply_render')),
    ('view v_conversas', to_regclass('public.v_conversas') is not null),
    ('tabela quick_replies', to_regclass('public.quick_replies') is not null),
    ('coluna leads.ad_referral', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'leads' and column_name = 'ad_referral'))
) as v(item, ok);
