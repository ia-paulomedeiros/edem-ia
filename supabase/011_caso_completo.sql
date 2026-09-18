-- =============================================================================
-- 011_caso_completo.sql — Sprint 4: o caso completo, igual ao do concorrente
--
-- 1. Lead e caso: CPF, e-mail, nascimento, estado civil, endereço; CNPJ da
--    empresa, motivo da saída, acidente, "tem caso", objeções.
-- 2. Lead: encerramento com motivo, pausa (congela follow-up), data de
--    retorno, supervisor e protocolador, pasta do Drive, notas internas,
--    última entrada/saída de mensagem.
-- 3. Intervenção: ações registradas (ligação, mensagem, nota) com resultado.
-- 4. Contrato: pedido de envio (UI ou agente), preenchimento a partir de um
--    modelo, assinatura eletrônica pelo provedor ativo (n8n), link e PDF,
--    confirmação de dados, assinatura manual. Assinado => briefing (já era).
-- 5. Briefing estruturado (seções do concorrente + conteúdo completo).
-- 6. Régua de follow-up: regras por escritório, estado no lead, fila para o
--    n8n; esgotou => intervenção "follow-up esgotado".
-- 7. apply_agent_effects ganha p_contract e p_briefing.
--
-- Idempotente. Rodar depois de 010.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Lead e caso
-- -----------------------------------------------------------------------------

alter table public.contacts
  add column if not exists cpf          text,
  add column if not exists email        text,
  add column if not exists nascimento   date,
  add column if not exists estado_civil text,
  add column if not exists nacionalidade text,
  add column if not exists endereco     text,
  add column if not exists cep          text;

alter table public.case_data
  add column if not exists empresa_cnpj      text,
  add column if not exists motivo_saida      text,
  add column if not exists acidente_trabalho boolean,
  add column if not exists tem_caso          boolean,
  add column if not exists objecao_principal text,
  add column if not exists objecao_detalhe   text;

-- -----------------------------------------------------------------------------
-- 2. Lead: encerramento, pausa, papéis, Drive, notas, última entrada/saída
-- -----------------------------------------------------------------------------

alter table public.leads
  add column if not exists closed_reason     text,
  add column if not exists paused            boolean not null default false,
  add column if not exists paused_at         timestamptz,
  add column if not exists paused_by         uuid references auth.users(id),
  add column if not exists retorno_em        timestamptz,
  add column if not exists supervisor        uuid references auth.users(id),
  add column if not exists protocolador      uuid references auth.users(id),
  add column if not exists drive_folder_id   text,
  add column if not exists drive_folder_url  text,
  add column if not exists notas_internas    text,
  add column if not exists last_inbound_at   timestamptz,
  add column if not exists last_outbound_at  timestamptz,
  add column if not exists followup_step     int not null default 0,
  add column if not exists followup_next_at  timestamptz;
create index if not exists leads_followup_idx on public.leads(office_id, followup_next_at) where followup_next_at is not null;

create or replace function public.ui_close_lead(p_lead uuid, p_reason text)
returns public.leads
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_close_lead exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'informe o motivo do encerramento'; end if;
  update public.leads set closed_reason = p_reason, paused = false, followup_next_at = null where id = p_lead;
  l := public.advance_phase(p_lead, 'encerrado', 'humano', auth.uid(), null, p_reason);
  return l;
end; $$;

create or replace function public.ui_reopen_lead(p_lead uuid, p_to public.case_phase default 'triagem')
returns public.leads
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_reopen_lead exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  update public.leads set closed_reason = null where id = p_lead;
  l := public.advance_phase(p_lead, p_to, 'humano', auth.uid(), null, 'reaberto');
  return l;
end; $$;

-- Pausar congela a régua de follow-up e marca a data de retorno; não encerra nem assume a conversa.
create or replace function public.ui_pause_lead(p_lead uuid, p_paused boolean, p_retorno timestamptz default null)
returns public.leads
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_pause_lead exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  update public.leads
     set paused = p_paused,
         paused_at = case when p_paused then now() else null end,
         paused_by = case when p_paused then auth.uid() else null end,
         retorno_em = case when p_paused then p_retorno else null end,
         followup_next_at = case when p_paused then null else coalesce(p_retorno, followup_next_at) end
   where id = p_lead returning * into l;
  perform public.log_event(l.office_id, l.id, case when p_paused then 'lead_paused' else 'lead_resumed' end, 'humano', auth.uid(), null,
    jsonb_build_object('retorno_em', p_retorno));
  return l;
end; $$;

create or replace function public.ui_set_lead_roles(p_lead uuid, p_assigned uuid default null, p_supervisor uuid default null, p_protocolador uuid default null)
returns public.leads
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_set_lead_roles exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  update public.leads
     set assigned_to = coalesce(p_assigned, assigned_to),
         supervisor = coalesce(p_supervisor, supervisor),
         protocolador = coalesce(p_protocolador, protocolador)
   where id = p_lead returning * into l;
  perform public.log_event(l.office_id, l.id, 'lead_roles_changed', 'humano', auth.uid(), null,
    jsonb_build_object('assigned_to', l.assigned_to, 'supervisor', l.supervisor, 'protocolador', l.protocolador));
  return l;
end; $$;

-- -----------------------------------------------------------------------------
-- 3. Ações da intervenção (ligação, mensagem, nota)
-- -----------------------------------------------------------------------------

create table if not exists public.intervention_actions (
  id               uuid primary key default gen_random_uuid(),
  office_id        uuid not null references public.offices(id) on delete cascade,
  intervention_id  uuid not null references public.human_interventions(id) on delete cascade,
  lead_id          uuid not null references public.leads(id) on delete cascade,
  tipo             text not null check (tipo in ('ligacao','mensagem','nota')),
  resultado        text not null,
  notas            text not null check (length(btrim(notas)) >= 20),
  retorno_em       timestamptz,
  created_by       uuid references auth.users(id),
  created_at       timestamptz not null default now()
);
create index if not exists intervention_actions_int_idx on public.intervention_actions(intervention_id, created_at);
create index if not exists intervention_actions_lead_idx on public.intervention_actions(lead_id, created_at desc);

create or replace function public.intervention_results()
returns table (codigo text, titulo text, tipo text)
language sql immutable set search_path = public as $$
  values
    ('atendeu_quer_fechar', 'Atendeu — quer fechar', 'ligacao'),
    ('atendeu_vai_pensar', 'Atendeu — vai pensar', 'ligacao'),
    ('atendeu_recusou', 'Atendeu — recusou', 'ligacao'),
    ('atendeu_retorno', 'Atendeu — pediu retorno em outro horário', 'ligacao'),
    ('nao_atendeu', 'Não atendeu', 'ligacao'),
    ('caixa_postal', 'Caixa postal', 'ligacao'),
    ('numero_invalido', 'Número inválido / não existe', 'ligacao'),
    ('mensagem_enviada', 'Mensagem enviada', 'mensagem'),
    ('mensagem_respondida', 'Mensagem respondida', 'mensagem'),
    ('sem_resposta', 'Sem resposta', 'mensagem'),
    ('nota', 'Nota interna', 'nota');
$$;

create or replace function public.log_intervention_action(
  p_intervention uuid, p_tipo text, p_resultado text, p_notas text, p_retorno_em timestamptz default null)
returns public.intervention_actions
language plpgsql security definer set search_path = public as $$
declare h public.human_interventions; a public.intervention_actions; v_task uuid;
begin
  if auth.uid() is null then raise exception 'log_intervention_action exige usuário'; end if;
  select * into h from public.human_interventions where id = p_intervention for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if not exists (select 1 from public.intervention_results() r where r.codigo = p_resultado) then
    raise exception 'resultado desconhecido: %', p_resultado;
  end if;
  insert into public.intervention_actions (office_id, intervention_id, lead_id, tipo, resultado, notas, retorno_em, created_by)
  values (h.office_id, h.id, h.lead_id, p_tipo, p_resultado, p_notas, p_retorno_em, auth.uid())
  returning * into a;
  update public.human_interventions
     set calls_count = calls_count + case when p_tipo = 'ligacao' then 1 else 0 end,
         status = case when status = 'pendente' then 'em_atendimento' else status end,
         claimed_by = coalesce(claimed_by, auth.uid()),
         claimed_at = coalesce(claimed_at, now())
   where id = h.id;
  if p_retorno_em is not null then
    insert into public.tasks (office_id, lead_id, title, description, due_at, assigned_to, created_by, created_by_actor)
    values (h.office_id, h.lead_id, 'Retorno combinado', left(p_notas, 500), p_retorno_em, auth.uid(), auth.uid(), 'humano')
    returning id into v_task;
    update public.leads set retorno_em = p_retorno_em where id = h.lead_id;
  end if;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_action', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'tipo', p_tipo, 'resultado', p_resultado,
                       'resultado_titulo', (select titulo from public.intervention_results() r where r.codigo = p_resultado),
                       'notas', left(p_notas, 300), 'task_id', v_task), h.conversation_id);
  return a;
end; $$;

-- -----------------------------------------------------------------------------
-- 4. Contrato com assinatura eletrônica
-- -----------------------------------------------------------------------------

alter table public.contracts
  add column if not exists sign_url          text,        -- link que o lead abre para assinar
  add column if not exists pdf_url           text,        -- PDF assinado no provedor
  add column if not exists dados_confirmados boolean not null default false,
  add column if not exists assinatura_manual boolean not null default false,
  add column if not exists send_requested_at timestamptz,
  add column if not exists provider_payload  jsonb,
  add column if not exists requested_by_actor text not null default 'humano' check (requested_by_actor in ('ia','humano','sistema'));

-- Modelo do contrato (HTML com {{campos}}); global quando office_id nulo. O escritório pode ter o seu.
create table if not exists public.contract_templates (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid references public.offices(id) on delete cascade,
  name        text not null,
  body_html   text not null,
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);
drop trigger if exists contract_templates_touch on public.contract_templates;
create trigger contract_templates_touch before update on public.contract_templates
  for each row execute function public.touch_updated_at();

insert into public.contract_templates (id, office_id, name, body_html)
values ('00000000-0000-0000-0000-00000000c001', null, 'Contrato de honorários — padrão',
$html$<h1>CONTRATO DE PRESTAÇÃO DE SERVIÇOS ADVOCATÍCIOS</h1>
<p><b>CONTRATANTE:</b> {{cliente_nome}}, {{cliente_nacionalidade}}, {{cliente_estado_civil}}, portador(a) do CPF {{cliente_cpf}}, residente em {{cliente_endereco}}.</p>
<p><b>CONTRATADO(A):</b> {{escritorio_nome}}, inscrito(a) no CNPJ {{escritorio_cnpj}}, {{escritorio_oab}}, com sede em {{escritorio_endereco}}.</p>
<h2>1. Objeto</h2>
<p>Patrocínio de reclamação trabalhista em face de {{empresa}} ({{empresa_cnpj}}), relativa ao vínculo de {{admissao}} a {{demissao}}, no cargo de {{cargo}}.</p>
<h2>2. Honorários</h2>
<p>Honorários de êxito de {{honorarios_percent}}% sobre o proveito econômico obtido. Valor estimado da causa: {{valor_causa}}.</p>
<h2>3. Disposições gerais</h2>
<p>O(A) contratante declara ter recebido cópia deste instrumento e concorda com a assinatura eletrônica.</p>
<p>{{cidade}}, {{data_extenso}}.</p>$html$)
on conflict (id) do nothing;

-- Dados para preencher o contrato (n8n e prévia na UI).
create or replace function public.contract_fill_data(p_lead uuid)
returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'cliente_nome', ct.name, 'cliente_cpf', coalesce(ct.cpf, '—'), 'cliente_email', ct.email, 'cliente_telefone', ct.wa_id,
    'cliente_nacionalidade', coalesce(ct.nacionalidade, 'brasileiro(a)'), 'cliente_estado_civil', coalesce(ct.estado_civil, '—'),
    'cliente_endereco', concat_ws(', ', ct.endereco, ct.cidade, ct.uf, ct.cep),
    'escritorio_nome', o.name, 'escritorio_cnpj', coalesce(o.cnpj, '—'), 'escritorio_oab', coalesce(o.oab_responsavel, ''),
    'escritorio_endereco', concat_ws(', ', o.endereco, o.cidade, o.uf), 'escritorio_email', o.email,
    'empresa', coalesce(d.empresa, '—'), 'empresa_cnpj', coalesce(d.empresa_cnpj, '—'), 'cargo', coalesce(d.cargo, '—'),
    'admissao', coalesce(to_char(d.admissao, 'DD/MM/YYYY'), '—'), 'demissao', coalesce(to_char(d.demissao, 'DD/MM/YYYY'), '—'),
    'salario', coalesce(to_char(d.salario, 'FM999G999G990D00'), '—'),
    'honorarios_percent', coalesce(k.honorarios_percent, p.honorarios_percent),
    'valor_causa', coalesce('R$ ' || to_char(coalesce(k.valor_causa, q.verbas_total), 'FM999G999G990D00'), 'a apurar'),
    'cidade', coalesce(o.cidade, ct.cidade, ''),
    'data_extenso', to_char(current_date, 'DD') || ' de ' ||
      (array['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro'])[extract(month from current_date)::int]
      || ' de ' || to_char(current_date, 'YYYY'),
    'template_html', (select t.body_html from public.contract_templates t
                       where t.active and (t.office_id = l.office_id or t.office_id is null)
                       order by t.office_id nulls last limit 1),
    'provider', public.active_integration(l.office_id, 'assinatura')
  )
  from public.leads l
  join public.contacts ct on ct.id = l.contact_id
  join public.offices o on o.id = l.office_id
  left join public.office_params p on p.office_id = l.office_id
  left join public.case_data d on d.lead_id = l.id
  left join public.lead_qualification q on q.lead_id = l.id
  left join lateral (select honorarios_percent, valor_causa from public.contracts k where k.lead_id = l.id and k.status in ('rascunho','enviado','assinado') order by created_at desc limit 1) k on true
  where l.id = p_lead;
$$;

-- Pedir o envio (UI ou agente): cancela o ativo e cria um novo em 'enviado' (o n8n gera, envia e preenche a referência).
create or replace function public.request_contract(p_lead uuid, p_actor text, p_actor_user uuid default null, p_honorarios numeric default null)
returns public.contracts
language plpgsql security definer set search_path = public as $$
declare l public.leads; k public.contracts; v_pct numeric;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  select coalesce(p_honorarios, honorarios_percent) into v_pct from public.office_params where office_id = l.office_id;
  update public.contracts set status = 'cancelado' where lead_id = p_lead and status in ('rascunho','enviado');
  insert into public.contracts (office_id, lead_id, status, honorarios_percent, send_requested_at, requested_by_actor, signature_provider)
  values (l.office_id, p_lead, 'enviado', coalesce(v_pct, 30), now(), p_actor, public.active_integration(l.office_id, 'assinatura'))
  returning * into k;
  if public.phase_order(l.phase) < public.phase_order('contrato') then
    perform public.advance_phase(p_lead, 'contrato', p_actor, p_actor_user, case when p_actor = 'ia' then 'contrato' else null end, 'contrato enviado');
  end if;
  return k;
end; $$;

create or replace function public.ui_request_contract(p_lead uuid, p_honorarios numeric default null)
returns public.contracts
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'ui_request_contract exige usuário'; end if;
  if not exists (select 1 from public.leads l where l.id = p_lead and public.member_role(l.office_id) in ('admin','advogado')) then
    raise exception 'apenas admin ou advogado envia contrato';
  end if;
  return public.request_contract(p_lead, 'humano', auth.uid(), p_honorarios);
end; $$;

create or replace function public.ui_confirm_contract_data(p_contract uuid, p_confirmed boolean default true)
returns public.contracts
language plpgsql set search_path = public as $$
declare k public.contracts;
begin
  update public.contracts set dados_confirmados = p_confirmed where id = p_contract returning * into k;
  if k.id is null then raise exception 'contrato não encontrado'; end if;
  return k;
end; $$;

-- Assinatura manual (papel): advogado anexa o PDF e marca assinado.
create or replace function public.ui_manual_signature(p_contract uuid, p_document_path text)
returns public.contracts
language plpgsql set search_path = public as $$
declare k public.contracts;
begin
  if auth.uid() is null then raise exception 'ui_manual_signature exige usuário'; end if;
  update public.contracts
     set assinatura_manual = true, document_path = coalesce(p_document_path, document_path),
         signature_provider = 'manual', status = 'assinado'
   where id = p_contract returning * into k;
  if k.id is null then raise exception 'contrato não encontrado'; end if;
  return k;
end; $$;

-- n8n (service_role): enviado ao provedor
create or replace function public.contract_mark_sent(p_contract uuid, p_provider text, p_ref text, p_sign_url text, p_document_path text default null, p_payload jsonb default null)
returns void
language sql security definer set search_path = public as $$
  update public.contracts
     set signature_provider = p_provider, signature_ref = p_ref, sign_url = p_sign_url,
         document_path = coalesce(p_document_path, document_path), provider_payload = p_payload, sent_at = coalesce(sent_at, now())
   where id = p_contract;
$$;

-- n8n (service_role): webhook do provedor disse "assinado"
create or replace function public.contract_mark_signed(p_ref text, p_pdf_url text default null, p_signed_at timestamptz default null)
returns public.contracts
language plpgsql security definer set search_path = public as $$
declare k public.contracts;
begin
  update public.contracts
     set pdf_url = coalesce(p_pdf_url, pdf_url), signed_at = coalesce(p_signed_at, now()), status = 'assinado'
   where signature_ref = p_ref and status in ('enviado','rascunho')
   returning * into k;
  return k;
end; $$;

-- Rejeição/erro do provedor
create or replace function public.contract_mark_failed(p_contract uuid, p_error text)
returns void
language sql security definer set search_path = public as $$
  update public.contracts set provider_payload = coalesce(provider_payload, '{}'::jsonb) || jsonb_build_object('error', left(p_error, 500)) where id = p_contract;
$$;

-- -----------------------------------------------------------------------------
-- 5. Briefing estruturado
-- -----------------------------------------------------------------------------

alter table public.briefings
  add column if not exists agent_role       text,
  add column if not exists dados_pessoais   jsonb not null default '{}'::jsonb,
  add column if not exists dados_vinculo    jsonb not null default '{}'::jsonb,
  add column if not exists verbas           jsonb not null default '{}'::jsonb,
  add column if not exists timeline         jsonb not null default '[]'::jsonb,
  add column if not exists inconsistencias  text,
  add column if not exists gaps             text,
  add column if not exists teses            text[] not null default '{}',
  add column if not exists fatos            text,
  add column if not exists alertas          text,
  add column if not exists testemunhas      jsonb not null default '[]'::jsonb,
  add column if not exists conteudo         text;

create or replace function public.upsert_briefing(p_lead uuid, p_data jsonb, p_actor text default 'ia', p_actor_user uuid default null, p_agent text default 'briefing')
returns public.briefings
language plpgsql security definer set search_path = public as $$
declare l public.leads; b public.briefings; v_teses text[];
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  if jsonb_typeof(p_data->'teses') = 'array' then select array_agg(x) into v_teses from jsonb_array_elements_text(p_data->'teses') x; end if;
  insert into public.briefings (office_id, lead_id, conducted_by_actor, agent_role) values (l.office_id, p_lead, p_actor, p_agent)
  on conflict (lead_id) do nothing;
  update public.briefings b2 set
    answers         = b2.answers || coalesce(p_data->'answers', '{}'::jsonb),
    dados_pessoais  = b2.dados_pessoais || coalesce(p_data->'dados_pessoais', '{}'::jsonb),
    dados_vinculo   = b2.dados_vinculo || coalesce(p_data->'dados_vinculo', '{}'::jsonb),
    verbas          = b2.verbas || coalesce(p_data->'verbas', '{}'::jsonb),
    timeline        = case when jsonb_typeof(p_data->'timeline') = 'array' then p_data->'timeline' else b2.timeline end,
    inconsistencias = coalesce(p_data->>'inconsistencias', b2.inconsistencias),
    gaps            = coalesce(p_data->>'gaps', b2.gaps),
    teses           = coalesce(v_teses, b2.teses),
    fatos           = coalesce(p_data->>'fatos', b2.fatos),
    alertas         = coalesce(p_data->>'alertas', b2.alertas),
    testemunhas     = case when jsonb_typeof(p_data->'testemunhas') = 'array' then p_data->'testemunhas' else b2.testemunhas end,
    conteudo        = coalesce(p_data->>'conteudo', b2.conteudo),
    summary         = coalesce(p_data->>'summary', b2.summary),
    status          = coalesce(p_data->>'status', b2.status),
    completed_at    = case when p_data->>'status' = 'concluido' then coalesce(b2.completed_at, now()) else b2.completed_at end,
    agent_role      = coalesce(p_agent, b2.agent_role)
  where b2.lead_id = p_lead returning * into b;
  perform public.log_event(l.office_id, p_lead, case when b.status = 'concluido' and p_data->>'status' = 'concluido' then 'briefing_completed' else 'briefing_updated' end,
    p_actor, p_actor_user, case when p_actor = 'ia' then p_agent else null end,
    jsonb_build_object('briefing_id', b.id, 'status', b.status, 'teses', b.teses));
  return b;
end; $$;

create or replace function public.ui_upsert_briefing(p_lead uuid, p_data jsonb)
returns public.briefings
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'ui_upsert_briefing exige usuário'; end if;
  if not exists (select 1 from public.leads l where l.id = p_lead and public.is_office_member(l.office_id)) then raise exception 'caso não encontrado'; end if;
  return public.upsert_briefing(p_lead, p_data, 'humano', auth.uid(), null);
end; $$;

-- -----------------------------------------------------------------------------
-- 6. Régua de follow-up
-- -----------------------------------------------------------------------------

create table if not exists public.followup_rules (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid references public.offices(id) on delete cascade,   -- null = padrão global
  step        int not null check (step between 1 and 10),
  delay_hours int not null check (delay_hours > 0),
  template    text not null,                                           -- {{nome}}, {{escritorio}}
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);
create unique index if not exists followup_rules_scope_step_uidx
  on public.followup_rules (coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), step);

insert into public.followup_rules (office_id, step, delay_hours, template) values
  (null, 1, 4,  'Oi {{nome}}, aqui é do {{escritorio}}. Ficou alguma dúvida? Estou por aqui para continuar quando você puder.'),
  (null, 2, 24, '{{nome}}, passando para lembrar: podemos seguir com o seu caso quando quiser. É rápido, são poucas perguntas.'),
  (null, 3, 72, '{{nome}}, esta é a última mensagem por aqui. Se quiser retomar, é só responder que eu continuo de onde paramos.')
on conflict do nothing;

create or replace function public.followup_rule(p_office uuid, p_step int)
returns public.followup_rules
language sql stable set search_path = public as $$
  select * from public.followup_rules r
  where r.active and r.step = p_step and (r.office_id = p_office or r.office_id is null)
  order by r.office_id nulls last limit 1;
$$;

-- Fila para o n8n: leads calados depois da última resposta da IA, não pausados, não assumidos, não encerrados.
create or replace function public.followup_due(p_limit int default 100)
returns table (lead_id uuid, office_id uuid, conversation_id uuid, wa_id text, phone_number_id text, nome text, escritorio text, step int, template text)
language sql stable security definer set search_path = public as $$
  select l.id, l.office_id, c.id, ct.wa_id, wn.phone_number_id, ct.name, o.name, l.followup_step + 1, r.template
  from public.leads l
  join public.offices o on o.id = l.office_id
  join public.contacts ct on ct.id = l.contact_id
  join lateral (select * from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) c on true
  join public.whatsapp_numbers wn on wn.id = c.whatsapp_number_id
  join lateral (select * from public.followup_rule(l.office_id, l.followup_step + 1)) r on true
  where l.followup_next_at is not null and l.followup_next_at <= now()
    and not l.paused and l.phase <> 'encerrado'
    and c.status = 'open' and not c.ai_paused
    and (l.last_inbound_at is null or l.last_inbound_at <= l.last_outbound_at)
    and not exists (select 1 from public.human_interventions h where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))
  order by l.followup_next_at
  limit p_limit;
$$;

-- n8n marcou o envio do passo atual: agenda o próximo ou esgota (=> fila)
create or replace function public.followup_mark_sent(p_lead uuid)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare l public.leads; r public.followup_rules; v_next int;
begin
  select * into l from public.leads where id = p_lead for update;
  v_next := l.followup_step + 2;
  r := public.followup_rule(l.office_id, v_next);
  if r.id is null then
    update public.leads set followup_step = followup_step + 1, followup_next_at = null where id = p_lead;
    perform public.request_intervention(p_lead, (select id from public.conversations where lead_id = p_lead order by last_message_at desc nulls last limit 1),
      'follow_up_esgotado', 'Follow-up esgotado (' || (l.followup_step + 1) || ' tentativas sem resposta)', 3, 'sistema', null,
      'Régua automática concluída sem resposta do lead.', array['follow_up']);
    return jsonb_build_object('step', l.followup_step + 1, 'exhausted', true);
  end if;
  update public.leads set followup_step = followup_step + 1, followup_next_at = now() + make_interval(hours => r.delay_hours) where id = p_lead;
  return jsonb_build_object('step', l.followup_step + 1, 'next_at', now() + make_interval(hours => r.delay_hours));
end; $$;

-- Mensagens: última entrada/saída no lead e o estado da régua.
create or replace function public.messages_after_insert()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare v_conv public.conversations; r public.followup_rules;
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

  if new.direction = 'in' then
    update public.leads set last_inbound_at = new.created_at, followup_step = 0, followup_next_at = null where id = v_conv.lead_id;
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
drop trigger if exists messages_after_insert on public.messages;
create trigger messages_after_insert after insert on public.messages
  for each row execute function public.messages_after_insert();

-- -----------------------------------------------------------------------------
-- 7. Efeitos do agente: + p_contract {action:'send', honorarios_percent} e + p_briefing {...}
-- -----------------------------------------------------------------------------

drop function if exists public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb);
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null, p_task jsonb default null,
  p_contract jsonb default null, p_briefing jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
  v_task uuid; k public.contracts; b public.briefings;
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

  if p_contract is not null and jsonb_typeof(p_contract) = 'object' and p_contract->>'action' = 'send' then
    k := public.request_contract(p_lead, 'ia', null, (p_contract->>'honorarios_percent')::numeric);
    v_result := v_result || jsonb_build_object('contract_id', k.id);
  end if;

  if p_briefing is not null and jsonb_typeof(p_briefing) = 'object' and p_briefing <> '{}'::jsonb then
    b := public.upsert_briefing(p_lead, p_briefing, 'ia', null, coalesce(p_agent_role, 'briefing'));
    v_result := v_result || jsonb_build_object('briefing_id', b.id, 'briefing_status', b.status);
  end if;

  if p_case_data is not null and jsonb_typeof(p_case_data) = 'object' then
    update public.contacts ct set
      cpf = coalesce(p_case_data->>'cpf', ct.cpf), email = coalesce(p_case_data->>'email', ct.email),
      nascimento = coalesce((p_case_data->>'nascimento')::date, ct.nascimento), estado_civil = coalesce(p_case_data->>'estado_civil', ct.estado_civil),
      nacionalidade = coalesce(p_case_data->>'nacionalidade', ct.nacionalidade), endereco = coalesce(p_case_data->>'endereco', ct.endereco),
      cep = coalesce(p_case_data->>'cep', ct.cep), cidade = coalesce(p_case_data->>'cidade', ct.cidade), uf = coalesce(p_case_data->>'uf', ct.uf)
    where ct.id = l.contact_id;
    update public.case_data d set
      empresa_cnpj = coalesce(p_case_data->>'empresa_cnpj', d.empresa_cnpj), motivo_saida = coalesce(p_case_data->>'motivo_saida', d.motivo_saida),
      acidente_trabalho = coalesce((p_case_data->>'acidente_trabalho')::boolean, d.acidente_trabalho), tem_caso = coalesce((p_case_data->>'tem_caso')::boolean, d.tem_caso),
      objecao_principal = coalesce(p_case_data->>'objecao_principal', d.objecao_principal), objecao_detalhe = coalesce(p_case_data->>'objecao_detalhe', d.objecao_detalhe)
    where d.lead_id = p_lead;
  end if;

  return v_result;
end;
$$;

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
    'agent', (select jsonb_build_object('role', a.role, 'name', a.name, 'description', a.description)
              from public.leads l2, public.agent_config(l2.office_id, l2.phase) a where l2.id = p_lead),
    'actions', (select coalesce(jsonb_agg(to_jsonb(x) || jsonb_build_object('created_by_name', pr.full_name,
                    'resultado_titulo', (select titulo from public.intervention_results() r where r.codigo = x.resultado)) order by x.created_at desc), '[]'::jsonb)
                from public.intervention_actions x left join public.profiles pr on pr.user_id = x.created_by where x.lead_id = p_lead),
    'contracts', (select coalesce(jsonb_agg(to_jsonb(k) order by k.created_at desc), '[]'::jsonb) from public.contracts k where k.lead_id = p_lead),
    'roles', (select jsonb_build_object('assigned_to', l2.assigned_to, 'assigned_name', pa.full_name,
                                        'supervisor', l2.supervisor, 'supervisor_name', ps.full_name,
                                        'protocolador', l2.protocolador, 'protocolador_name', pp.full_name)
              from public.leads l2 left join public.profiles pa on pa.user_id = l2.assigned_to
              left join public.profiles ps on ps.user_id = l2.supervisor left join public.profiles pp on pp.user_id = l2.protocolador
              where l2.id = p_lead),
    'params', (select jsonb_build_object('alerta_prescricao_dias', p.alerta_prescricao_dias, 'ticket_minimo', p.ticket_minimo,
                                         'vinculo_minimo_meses', p.vinculo_minimo_meses, 'honorarios_percent', p.honorarios_percent)
               from public.office_params p where p.office_id = (select office_id from public.leads where id = p_lead))
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- -----------------------------------------------------------------------------
-- RLS e grants
-- -----------------------------------------------------------------------------

select public.apply_office_rls('intervention_actions');
drop policy if exists intervention_actions_update on public.intervention_actions;
drop policy if exists intervention_actions_delete on public.intervention_actions;

alter table public.contract_templates enable row level security;
drop policy if exists contract_templates_select on public.contract_templates;
create policy contract_templates_select on public.contract_templates for select to authenticated
  using (office_id is null or public.is_office_member(office_id));
drop policy if exists contract_templates_write on public.contract_templates;
create policy contract_templates_write on public.contract_templates for all to authenticated
  using (office_id is not null and public.member_role(office_id) in ('admin','advogado'))
  with check (office_id is not null and public.member_role(office_id) in ('admin','advogado'));

alter table public.followup_rules enable row level security;
drop policy if exists followup_rules_select on public.followup_rules;
create policy followup_rules_select on public.followup_rules for select to authenticated
  using (office_id is null or public.is_office_member(office_id));
drop policy if exists followup_rules_write on public.followup_rules;
create policy followup_rules_write on public.followup_rules for all to authenticated
  using (office_id is not null and public.member_role(office_id) = 'admin')
  with check (office_id is not null and public.member_role(office_id) = 'admin');

select public.add_to_realtime('contracts');
select public.add_to_realtime('briefings');
select public.add_to_realtime('intervention_actions');
alter table public.contracts replica identity full;
alter table public.briefings replica identity full;

grant execute on function public.ui_close_lead(uuid, text) to authenticated;
grant execute on function public.ui_reopen_lead(uuid, public.case_phase) to authenticated;
grant execute on function public.ui_pause_lead(uuid, boolean, timestamptz) to authenticated;
grant execute on function public.ui_set_lead_roles(uuid, uuid, uuid, uuid) to authenticated;
grant execute on function public.intervention_results() to authenticated;
grant execute on function public.log_intervention_action(uuid, text, text, text, timestamptz) to authenticated;
grant execute on function public.contract_fill_data(uuid) to authenticated, service_role;
grant execute on function public.ui_request_contract(uuid, numeric) to authenticated;
grant execute on function public.ui_confirm_contract_data(uuid, boolean) to authenticated;
grant execute on function public.ui_manual_signature(uuid, text) to authenticated;
grant execute on function public.ui_upsert_briefing(uuid, jsonb) to authenticated;
grant execute on function public.followup_rule(uuid, int) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;

revoke execute on function public.request_contract(uuid, text, uuid, numeric) from public, anon, authenticated;
revoke execute on function public.contract_mark_sent(uuid, text, text, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.contract_mark_signed(text, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.contract_mark_failed(uuid, text) from public, anon, authenticated;
revoke execute on function public.upsert_briefing(uuid, jsonb, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.followup_due(int) from public, anon, authenticated;
revoke execute on function public.followup_mark_sent(uuid) from public, anon, authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.request_contract(uuid, text, uuid, numeric) to service_role;
grant execute on function public.contract_mark_sent(uuid, text, text, text, text, jsonb) to service_role;
grant execute on function public.contract_mark_signed(text, text, timestamptz) to service_role;
grant execute on function public.contract_mark_failed(uuid, text) to service_role;
grant execute on function public.upsert_briefing(uuid, jsonb, text, uuid, text) to service_role;
grant execute on function public.followup_due(int) to service_role;
grant execute on function public.followup_mark_sent(uuid) to service_role;
grant execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) to service_role;
