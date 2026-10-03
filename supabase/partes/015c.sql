-- =============================================================================
-- 015c — parte 3 de 3 de supabase/015_paridade_automacoes.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 015b. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- apply_agent_effects (014 + agendamento com data/hora + Coletor pede a peça).
-- Mesma assinatura.
-- -----------------------------------------------------------------------------
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null, p_task jsonb default null, p_contract jsonb default null, p_briefing jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
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

  return v_result || jsonb_build_object('agent_role', v_role);
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
grant select on public.v_tasks, public.v_agenda to authenticated;
grant execute on function public.doc_tipos() to authenticated;
grant execute on function public.doc_tipo_titulo(text) to authenticated;
grant execute on function public.task_status_titulo(text) to authenticated;
grant execute on function public.ui_set_agendamento(uuid, text, timestamptz) to authenticated;
grant execute on function public.ui_confirm_agendamento(uuid) to authenticated;
grant execute on function public.ui_reschedule_agendamento(uuid, timestamptz) to authenticated;
grant execute on function public.ui_cancel_agendamento(uuid) to authenticated;
grant execute on function public.prescricao_info(uuid) to authenticated;
grant execute on function public.faixa_label(text, boolean) to authenticated;
grant execute on function public.to_num(text) to authenticated;
grant execute on function public.ui_finish_collection(uuid) to authenticated;

-- Só o n8n (service_role) ou o próprio banco.
do $$
declare f text;
begin
  foreach f in array array[
    'public.ingest_media(uuid, text, text, bigint, text, text, text)',
    'public.agendamentos_escalar(int)',
    'public.agendamentos_due(int)',
    'public.agendamento_mark_done(uuid, text, uuid)',
    'public.run_monitors()',
    'public.ingest_inbound(text, text, text, text, text, jsonb, timestamptz)',
    'public.calculista_queue(int)',
    'public.save_qualification_record(uuid, jsonb, text, jsonb)',
    'public.calculista_failed(uuid, text)',
    'public.request_piece_generation(uuid, text, uuid, text)',
    'public.piece_generation_claim(int)',
    'public.piece_generation_save(uuid, text, text, jsonb, text, jsonb)',
    'public.piece_generation_failed(uuid, text)',
    'public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- =============================================================================
-- P3. Mensageria e assinatura por provedor
-- =============================================================================
-- Um provedor ativo por tipo (mensageria, assinatura). set_integration já
-- desligava os outros; agora o banco garante.
update public.integrations i set active = false
 where i.active and i.kind in ('mensageria','assinatura')
   and exists (select 1 from public.integrations j where j.office_id = i.office_id and j.kind = i.kind and j.active
                 and (j.updated_at > i.updated_at or (j.updated_at = i.updated_at and j.id > i.id)));
create unique index if not exists integrations_um_ativo_por_tipo
  on public.integrations (office_id, kind) where active and kind in ('mensageria','assinatura');

-- Provedor de mensageria do escritório. Sem integração ativa, o número do
-- WhatsApp Cloud cadastrado continua valendo (comportamento até a 014).
create or replace function public.mensageria_provider(p_office uuid)
returns text language sql stable set search_path = public as $$
  select coalesce(public.active_integration(p_office, 'mensageria'),
                  case when exists (select 1 from public.whatsapp_numbers w where w.office_id = p_office and w.active) then 'meta_whatsapp' end);
$$;

-- Tudo que o WA 03 precisa para enviar uma linha pendente, já com o provedor.
-- O segredo sai do Vault e nunca volta para o front (só service_role executa).
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
  where m.id = p_message and m.status = 'pending' and m.direction = 'out';
$$;

-- Marca uma linha como falha com o motivo (provedor sem envio implementado etc.).
create or replace function public.message_mark_failed(p_message uuid, p_error text)
returns void language sql security definer set search_path = public as $$
  update public.messages set status = 'failed', error = left(p_error, 500) where id = p_message and status = 'pending';
$$;

grant execute on function public.mensageria_provider(uuid) to authenticated;
do $$
declare f text;
begin
  foreach f in array array['public.mensageria_destino(uuid)', 'public.message_mark_failed(uuid, text)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- Títulos dos desfechos da fila (Histórico de tarefas): os mesmos códigos da
-- constraint human_interventions_outcome_check, para a UI não fixar lista.
create or replace function public.intervention_outcomes()
returns table (ordem int, codigo text, titulo text)
language sql immutable set search_path = public as $$
  values
    (1, 'sanado',                'Sanado'),
    (2, 'cliente_retomado',      'Cliente retomado'),
    (3, 'reativado_para_agente', 'Reativado para o agente'),
    (4, 'assumido_pelo_humano',  'Assumido pelo humano'),
    (5, 'follow_up_agendado',    'Follow-up agendado'),
    (6, 'cliente_perdido',       'Cliente perdido'),
    (7, 'tarefa_cancelada',      'Tarefa cancelada'),
    (8, 'outro',                 'Outro'),
    (9, 'nao_informada',         'Não informada');
$$;
grant execute on function public.intervention_outcomes() to authenticated;

-- ---------- Verificação da parte 015c: deve voltar uma linha com resultado = OK
select '015c' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função apply_agent_effects', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'apply_agent_effects')),
    ('função intervention_outcomes', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'intervention_outcomes')),
    ('função mensageria_destino', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'mensageria_destino')),
    ('função mensageria_provider', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'mensageria_provider')),
    ('função message_mark_failed', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'message_mark_failed'))
) as v(item, ok);
