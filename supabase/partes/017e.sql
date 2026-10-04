-- =============================================================================
-- 017e — parte 5 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017d. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- ---------- Verificação da parte 017e: deve voltar uma linha com resultado = OK
select '017e' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função agent_tags_context', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_tags_context')),
    ('função apply_agent_effects', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'apply_agent_effects')),
    ('função conversation_merge', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'conversation_merge')),
    ('função lead_set_referral', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_set_referral')),
    ('função template_submit_payload', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'template_submit_payload')),
    ('função template_submitted', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'template_submitted')),
    ('função templates_pending_submit', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'templates_pending_submit')),
    ('função templates_sync_apply', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'templates_sync_apply')),
    ('função templates_sync_targets', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'templates_sync_targets')),
    ('função ui_template_submit', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_template_submit')),
    ('função wa_template_status', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'wa_template_status')),
    ('view v_marketing_anuncios', to_regclass('public.v_marketing_anuncios') is not null),
    ('coluna wa_templates.whatsapp_number_id', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'whatsapp_number_id')),
    ('coluna wa_templates.components', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'components')),
    ('coluna wa_templates.rejected_reason', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'rejected_reason')),
    ('coluna wa_templates.last_sync_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'last_sync_at')),
    ('coluna wa_templates.submit_requested_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'submit_requested_at')),
    ('coluna wa_templates.submitted_at', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'submitted_at')),
    ('coluna wa_templates.submit_error', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'wa_templates' and column_name = 'submit_error'))
) as v(item, ok);
