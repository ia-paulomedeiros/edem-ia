-- =============================================================================
-- 010_juridico_agenda.sql — Sprint 3: Jurídico como esteira e Agenda por dia
--
-- 1. Jurídico igual ao concorrente: a esteira do trabalho jurídico depois do
--    contrato. pieces.status ganha 'aguardando' e 'saneamento':
--      rascunho (IA redigindo) → revisao → aguardando (cliente/documentos)
--      → saneamento (corrigir) → aprovada (pronto p/ protocolo) → protocolada.
--    Cada peça pode ter um alerta ("Confirmar com o cliente antes de
--    protocolar"), um responsável e a data de entrada na etapa.
--    v_legal_cards: um card por peça com tudo que o quadro mostra.
-- 2. Agenda: apply_agent_effects aceita p_task (o agente marca "retomar
--    amanhã às 09:00" como tarefa do lead, autor IA). v_tasks para a lista
--    por dia (lead, telefone, responsável, situação).
-- 3. Limpeza do linter do Supabase: search_path fixo em todas as funções e
--    execução só para authenticated/service_role (nunca anon/public).
--
-- Idempotente. Rodar depois de 009.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Esteira jurídica
-- -----------------------------------------------------------------------------

alter table public.pieces
  add column if not exists alerta            text,
  add column if not exists responsavel       uuid references auth.users(id),
  add column if not exists stage_changed_at  timestamptz not null default now();

alter table public.pieces drop constraint if exists pieces_status_check;
alter table public.pieces add constraint pieces_status_check
  check (status in ('rascunho','revisao','aguardando','saneamento','aprovada','protocolada'));
create index if not exists pieces_office_status_idx on public.pieces(office_id, status, stage_changed_at);

create or replace function public.piece_stage_title(p_status text)
returns text language sql immutable set search_path = public as $$
  select case p_status
    when 'rascunho' then 'Em redação'
    when 'revisao' then 'Revisão'
    when 'aguardando' then 'Aguardando'
    when 'saneamento' then 'Saneamento'
    when 'aprovada' then 'Pronto p/ protocolo'
    when 'protocolada' then 'Protocolado'
    else p_status end;
$$;

create or replace function public.piece_stages()
returns table (ordem int, status text, titulo text)
language sql immutable set search_path = public as $$
  values (1,'rascunho','Em redação'), (2,'revisao','Revisão'), (3,'aguardando','Aguardando'),
         (4,'saneamento','Saneamento'), (5,'aprovada','Pronto p/ protocolo'), (6,'protocolada','Protocolado');
$$;

-- Trigger de efeitos: registra a troca de etapa com autor e carimba stage_changed_at.
create or replace function public.pieces_effects()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor text := case when auth.uid() is not null then 'humano' else coalesce(new.generated_by_actor, 'sistema') end;
begin
  if tg_op = 'INSERT' then
    new.stage_changed_at := coalesce(new.stage_changed_at, now());
    perform public.log_event(new.office_id, new.lead_id, 'piece_created', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'tese', new.tese, 'status', new.status));
    return new;
  end if;
  if new.status is distinct from old.status then
    new.stage_changed_at := now();
    if new.status = 'protocolada' then
      new.protocolado_em := coalesce(new.protocolado_em, now());
    end if;
    perform public.log_event(new.office_id, new.lead_id, 'piece_status_changed', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'from', old.status, 'to', new.status,
                         'from_title', public.piece_stage_title(old.status), 'to_title', public.piece_stage_title(new.status),
                         'protocolo', new.protocolo));
  end if;
  if new.alerta is distinct from old.alerta and new.alerta is not null then
    perform public.log_event(new.office_id, new.lead_id, 'piece_alert', v_actor, auth.uid(), null,
      jsonb_build_object('piece_id', new.id, 'alerta', new.alerta));
  end if;
  return new;
end; $$;
drop trigger if exists pieces_effects on public.pieces;
create trigger pieces_effects before insert or update on public.pieces
  for each row execute function public.pieces_effects();

-- Um card por peça (a mais recente de cada lead), com o que o quadro mostra.
create or replace view public.v_legal_cards
with (security_invoker = true) as
select
  p.id                                    as piece_id,
  p.lead_id, p.office_id,
  p.status,
  public.piece_stage_title(p.status)      as etapa,
  (select ordem from public.piece_stages() s where s.status = p.status) as etapa_ordem,
  p.tese, p.alerta, p.protocolo, p.protocolado_em,
  p.responsavel, l.assigned_to,
  p.generated_by_actor, p.reviewed_by,
  p.stage_changed_at, p.updated_at, p.created_at,
  extract(epoch from (now() - p.stage_changed_at)) / 3600.0 as horas_na_etapa,
  l.phase,
  ct.name                                 as contact_name,
  ct.wa_id                                as contact_phone,
  d.empresa, d.cargo,
  coalesce(k.valor_causa, q.verbas_total) as valor_causa,
  coalesce(k.faixa, q.faixa)              as faixa,
  coalesce(q.passed, false)               as viavel,
  (coalesce(q.passed, false) = false
   or exists (select 1 from public.human_interventions h where h.lead_id = l.id and 'fragil' = any (h.tags))) as fragil,
  coalesce(c.ai_paused, false)            as em_atendimento,
  exists (select 1 from public.human_interventions h where h.lead_id = l.id and h.status in ('pendente','em_atendimento')) as intervencao_pendente,
  l.prescricao_em
from public.pieces p
join public.leads l on l.id = p.lead_id
join public.contacts ct on ct.id = l.contact_id
left join public.case_data d on d.lead_id = l.id
left join public.lead_qualification q on q.lead_id = l.id
left join lateral (select valor_causa, faixa from public.contracts k where k.lead_id = l.id and k.status = 'assinado' order by signed_at desc limit 1) k on true
left join lateral (select ai_paused from public.conversations cv where cv.lead_id = l.id order by last_message_at desc nulls last limit 1) c on true
where p.id = (select p2.id from public.pieces p2 where p2.lead_id = p.lead_id order by p2.created_at desc limit 1);

-- Mover a peça de etapa pela UI (autor humano garantido pelo trigger); alerta opcional.
create or replace function public.ui_set_piece_status(p_piece uuid, p_status text, p_alerta text default null, p_protocolo text default null)
returns public.pieces
language plpgsql set search_path = public as $$
declare p public.pieces;
begin
  if auth.uid() is null then raise exception 'ui_set_piece_status exige usuário'; end if;
  update public.pieces
     set status = p_status,
         alerta = case when p_alerta = '' then null else coalesce(p_alerta, alerta) end,
         protocolo = coalesce(p_protocolo, protocolo),
         reviewed_by = case when p_status in ('aprovada','protocolada') then auth.uid() else reviewed_by end
   where id = p_piece
   returning * into p;
  if p.id is null then raise exception 'peça não encontrada'; end if;
  return p;
end; $$;

-- -----------------------------------------------------------------------------
-- 2. Agenda
-- -----------------------------------------------------------------------------

create or replace view public.v_tasks
with (security_invoker = true) as
select
  t.id, t.office_id, t.lead_id, t.title, t.description, t.due_at, t.done_at, t.assigned_to, t.created_by, t.created_by_actor, t.created_at,
  ct.name   as contact_name,
  ct.wa_id  as contact_phone,
  l.phase,
  pr.full_name as assigned_name,
  case when t.done_at is not null then 'realizado'
       when t.due_at is not null and t.due_at < now() then 'atrasado'
       else 'pendente' end as situacao,
  (t.due_at at time zone 'America/Sao_Paulo')::date as dia
from public.tasks t
left join public.leads l on l.id = t.lead_id
left join public.contacts ct on ct.id = l.contact_id
left join public.profiles pr on pr.user_id = t.assigned_to;

-- Efeitos do agente: + p_task {title, description, due_at}
drop function if exists public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb);
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null, p_task jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
  v_task uuid;
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

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Limpeza do linter: search_path fixo e execução só para quem deve
-- -----------------------------------------------------------------------------

alter function public.apply_office_rls(text, text[]) set search_path = public;
alter function public.touch_updated_at() set search_path = public;
alter function public.add_to_realtime(text) set search_path = public;
alter function public.phase_order(public.case_phase) set search_path = public;
alter function public.agent_for_phase(public.case_phase) set search_path = public;
alter function public.vinculo_meses(date, date) set search_path = public;
alter function public.journey_stages() set search_path = public;
alter function public.intervention_group(text) set search_path = public;
alter function public.integration_public(public.integrations) set search_path = public;
alter function public.integration_secret_name(uuid, text) set search_path = public;
alter function public.canal_tipo(text) set search_path = public;

-- Nenhuma função do schema public é executável por anon/public. authenticated executa tudo,
-- menos as reservadas ao n8n (service_role). Triggers e helpers de migration ficam só com o dono.
do $$
declare r record; v_sig text;
  v_service_only text[] := array['integration_secret','integration_tested','agent_config_full','marketing_import','marketing_import_targets'];
  v_internal text[] := array['apply_office_rls','add_to_realtime'];
begin
  for r in
    select p.oid, p.proname, pg_get_function_identity_arguments(p.oid) as args, p.prorettype
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
  loop
    v_sig := format('public.%I(%s)', r.proname, r.args);
    execute format('revoke execute on function %s from public, anon', v_sig);
    if r.prorettype = 'trigger'::regtype then
      continue;   -- triggers rodam pelo dono; não mexer
    elsif r.proname = any (v_internal) then
      execute format('revoke execute on function %s from authenticated, service_role', v_sig);
    elsif r.proname = any (v_service_only) then
      execute format('revoke execute on function %s from authenticated', v_sig);
      execute format('grant execute on function %s to service_role', v_sig);
    else
      execute format('grant execute on function %s to authenticated, service_role', v_sig);
    end if;
  end loop;
end $$;
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from anon;

grant select on public.v_legal_cards to authenticated;
grant select on public.v_tasks to authenticated;
