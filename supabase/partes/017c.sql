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
-- 3f. Contexto da IA e métricas só com kind = 'chat'
-- Nota interna e mensagem de evento ficam fora do que a IA lê e do que se mede
-- como conversa. A constraint garante no banco que mensagem de contato e da IA
-- é sempre chat (evento = sistema, nota = humano, ambos saindo), então o que
-- filtra por sender = 'ia' ou direction = 'in' (dashboard_investimento_p,
-- marketing_tokens_split, mensagens da IA em dashboard_produtividade_p, a
-- "abertura" do funil, ingest_media) já não pode contar nota nem evento.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'messages_kind_sender') then
    alter table public.messages add constraint messages_kind_sender check (
      kind = 'chat' or (kind = 'evento' and sender = 'sistema') or (kind = 'nota' and sender = 'humano'));
  end if;
end $$;

-- Contexto do agente (001): mesma assinatura, só chat. Notas da equipe não vão
-- para o modelo (ele as repetiria ao cliente como se fossem dele).
create or replace function public.conversation_context(p_conversation uuid, p_limit integer default 30)
returns jsonb language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'role', case when m.direction = 'in' then 'user' else 'assistant' end,
           'sender', m.sender, 'body', m.body, 'media', m.media, 'at', m.created_at
         ) order by m.created_at), '[]'::jsonb)
  from (
    select * from public.messages where conversation_id = p_conversation and kind = 'chat'
    order by created_at desc limit p_limit
  ) m;
$$;

-- Jornada (014): primeira resposta e mensagens por lead só com chat.
create or replace function public.dashboard_jornada_p(p_office uuid, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_member uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  coorte as (
    select l.id, l.phase, l.created_at, public.lead_journey_stage(l.id) as etapa_atual from public.leads l, b
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
    select s.*, public.journey_stage_agents(s.role) as agentes,
      (select count(*) from coorte c where public.lead_reached_stage(c.id, s.role)) as n,
      (select count(*) from coorte c where c.etapa_atual = s.role) as em_fluxo,
      (select count(*) from coorte c where public.lead_reached_stage(c.id, s.role) and public.lead_done_stage(c.id, s.role)) as concluido,
      (select count(distinct e.lead_id) from public.case_events e join coorte c on c.id = e.lead_id
        where e.type = 'intervention_requested' and e.actor_agent = any (public.journey_stage_agents(s.role))) as interv_humana,
      (select round((avg(extract(epoch from (t.created_at - t.inicio))) / 3600)::numeric, 1)
         from trocas t where t.fase = any (s.fases) and s.role not in ('saneador','redator')) as tempo_medio_horas
    from public.journey_stages() s
  ),
  topo as (select coalesce(max(n) filter (where ordem = 1), 0) as n from st)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'leads', (select count(*) from coorte),
    'etapas', (select coalesce(jsonb_agg(jsonb_build_object(
                 'ordem', s.ordem, 'agente', s.role, 'titulo', s.titulo, 'fases', to_jsonb(s.fases), 'agentes', to_jsonb(s.agentes),
                 'n', s.n, 'pct_topo', case when topo.n = 0 then 0 else round(s.n::numeric / topo.n * 100) end,
                 'concluido', s.concluido, 'em_fluxo', s.em_fluxo, 'interv_humana', s.interv_humana,
                 'tempo_medio_horas', s.tempo_medio_horas) order by s.ordem), '[]'::jsonb) from st s, topo),
    'primeira_resposta_min', (select round(avg(extract(epoch from (o - i)) / 60)::numeric, 1) from (
        select (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'in' and m.kind = 'chat') as i,
               (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'out' and m.kind = 'chat') as o
        from coorte c) t where o is not null and i is not null),
    'dias_ate_contrato', (select round(avg(extract(epoch from (k.signed_at - c.created_at)) / 86400)::numeric, 1)
                          from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado'),
    'mensagens_por_lead', (select round(avg(n)::numeric, 1) from (
        select count(m.id) as n from coorte c
        left join public.conversations cv on cv.lead_id = c.id
        left join public.messages m on m.conversation_id = cv.id and m.kind = 'chat' group by c.id) t)
  )
  from b
  where public.is_office_member(p_office);
$$;

-- ---------- Verificação da parte 017c: deve voltar uma linha com resultado = OK
select '017c' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função conversas_counts', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversas_counts')),
    ('função conversation_archive', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_archive')),
    ('função conversation_assign', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_assign')),
    ('função conversation_close', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_close')),
    ('função conversation_context', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_context')),
    ('função conversation_event', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_event')),
    ('função conversation_guard', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_guard')),
    ('função conversation_hide', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_hide')),
    ('função conversation_mark_read', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_mark_read')),
    ('função conversation_note', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_note')),
    ('função conversation_reopen', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_reopen')),
    ('função conversation_set_ai', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_set_ai')),
    ('função conversation_status_titulo', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_status_titulo')),
    ('função conversation_transfer_department', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_transfer_department')),
    ('função dashboard_jornada_p', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'dashboard_jornada_p')),
    ('view v_conversas', to_regclass('public.v_conversas') is not null),
    ('coluna leads.ad_referral', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'leads' and column_name = 'ad_referral'))
) as v(item, ok);
