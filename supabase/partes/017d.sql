-- =============================================================================
-- 017d — parte 4 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017c. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- ---------- Verificação da parte 017d: deve voltar uma linha com resultado = OK
select '017d' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função conversation_merge', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_merge')),
    ('função lead_set_referral', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_set_referral')),
    ('função mensageria_envio', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'mensageria_envio')),
    ('função scheduled_cancel', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'scheduled_cancel')),
    ('função scheduled_create', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'scheduled_create')),
    ('função scheduled_dispatch', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'scheduled_dispatch')),
    ('função template_submit_payload', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'template_submit_payload')),
    ('função template_submitted', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'template_submitted')),
    ('função templates_pending_submit', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'templates_pending_submit')),
    ('função templates_sync_apply', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'templates_sync_apply')),
    ('função templates_sync_targets', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'templates_sync_targets')),
    ('função ui_template_submit', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_template_submit')),
    ('função wa_template_status', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'wa_template_status')),
    ('view v_marketing_anuncios', to_regclass('public.v_marketing_anuncios') is not null),
    ('tabela scheduled_messages', to_regclass('public.scheduled_messages') is not null),
    ('coluna wa_templates.whatsapp_number_id', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'whatsapp_number_id')),
    ('coluna wa_templates.components', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'components')),
    ('coluna wa_templates.rejected_reason', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'rejected_reason')),
    ('coluna wa_templates.last_sync_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'last_sync_at')),
    ('coluna wa_templates.submit_requested_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'submit_requested_at')),
    ('coluna wa_templates.submitted_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'submitted_at')),
    ('coluna wa_templates.submit_error', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'submit_error'))
) as v(item, ok);
