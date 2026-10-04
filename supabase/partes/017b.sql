-- =============================================================================
-- 017b — parte 2 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017a. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- ---------- Verificação da parte 017b: deve voltar uma linha com resultado = OK
select '017b' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função ai_should_reply', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ai_should_reply')),
    ('função conversation_recipients', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_recipients')),
    ('função conversations_status_stamp', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversations_status_stamp')),
    ('função followup_queue', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'followup_queue')),
    ('função human_interventions_notify', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'human_interventions_notify')),
    ('função ingest_inbound', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ingest_inbound')),
    ('função intervention_group', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'intervention_group')),
    ('função messages_after_insert', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'messages_after_insert')),
    ('função notifications_mark_read', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'notifications_mark_read')),
    ('função run_monitors', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'run_monitors')),
    ('função send_manual_message', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'send_manual_message')),
    ('função user_nome', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'user_nome'))
) as v(item, ok);
