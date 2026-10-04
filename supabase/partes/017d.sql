-- =============================================================================
-- 017d — parte 4 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017c. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- Produtividade (014): mensagens por membro só com chat (nota não é mensagem ao cliente).
create or replace function public.dashboard_produtividade_p(p_office uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_member uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
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
                  'mensagens', (select count(*) from public.messages m, b where m.office_id = p_office and m.sent_by = n.user_id and m.kind = 'chat' and m.created_at >= b.p_start and m.created_at < b.p_end),
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

-- Fila (007): mensagens desde a abertura da intervenção, só chat. Mesmas colunas.
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
  (select count(*) from public.messages m where m.conversation_id = h.conversation_id and m.created_at >= h.created_at and m.kind = 'chat') as msgs_count,
  (current_date - h.created_at::date) as dias
from public.human_interventions h
join public.leads l on l.id = h.lead_id
join public.contacts ct on ct.id = l.contact_id
left join public.lead_qualification q on q.lead_id = l.id
left join public.profiles pr on pr.user_id = h.claimed_by
cross join lateral public.intervention_group(h.category) g;
grant select on public.v_intervention_cards to authenticated;

-- Custo de aquisição (002): mensagens humanas sem as notas. Mesmas colunas.
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
left join public.messages m on m.conversation_id = c.id and m.direction = 'out' and m.kind = 'chat'
group by l.id, l.office_id;

-- Destino do envio (015): só chat pendente (defesa extra; o WA 03 já filtra).
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
  where m.id = p_message and m.status = 'pending' and m.direction = 'out' and m.kind = 'chat';
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

-- ---------- Verificação da parte 017d: deve voltar uma linha com resultado = OK
select '017d' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função conversation_send', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_send')),
    ('função dashboard_produtividade_p', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'dashboard_produtividade_p')),
    ('função media_normalize', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'media_normalize')),
    ('função mensageria_destino', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'mensageria_destino')),
    ('função mensageria_envio', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'mensageria_envio')),
    ('função quick_reply_fill', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'quick_reply_fill')),
    ('função quick_reply_render', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'quick_reply_render')),
    ('função scheduled_cancel', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'scheduled_cancel')),
    ('função scheduled_create', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'scheduled_create')),
    ('função scheduled_dispatch', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'scheduled_dispatch')),
    ('view lead_acquisition_cost', to_regclass('public.lead_acquisition_cost') is not null),
    ('view v_intervention_cards', to_regclass('public.v_intervention_cards') is not null),
    ('tabela quick_replies', to_regclass('public.quick_replies') is not null),
    ('tabela scheduled_messages', to_regclass('public.scheduled_messages') is not null)
) as v(item, ok);
