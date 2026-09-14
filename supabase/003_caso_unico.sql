-- =============================================================================
-- 003_caso_unico.sql — Sprint 2: o caso como objeto único
--
-- O que a UI do Sprint 2 precisa e 001/002 não davam:
--   * profiles: nome de quem fez cada coisa (linha do tempo mostra pessoa, não uuid)
--   * ui_advance_phase(): kanban muda fase SEM poder forjar o autor
--   * v_case_cards: uma projeção de leads.phase para kanban, lista e busca,
--     com prescrição calculada contra office_params.alerta_prescricao_dias
--   * eventos automáticos de dados/provas (trigger), para a linha do tempo não ter buraco
--   * Realtime em leads, case_events, tasks e human_interventions
--   * lead_dossier() v2: inclui card, nomes dos autores e equipe do escritório
--   * bucket 'provas' com policy por escritório (só roda dentro do Supabase)
--
-- Idempotente. Depende de 001 e 002. Não altera migrations anteriores.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Perfis (espelho mínimo de auth.users, legível pela equipe)
-- -----------------------------------------------------------------------------

create table if not exists public.profiles (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  full_name   text,
  avatar_url  text,
  updated_at  timestamptz not null default now()
);

create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (user_id, full_name, avatar_url)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name', split_part(coalesce(new.email, ''), '@', 1)),
          new.raw_user_meta_data->>'avatar_url')
  on conflict (user_id) do nothing;
  return new;
end; $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_auth_user();

-- backfill
insert into public.profiles (user_id, full_name)
select u.id, coalesce(u.raw_user_meta_data->>'full_name', split_part(coalesce(u.email, ''), '@', 1))
from auth.users u
on conflict (user_id) do nothing;

alter table public.profiles enable row level security;
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (user_id = auth.uid() or exists (
    select 1 from public.office_members a
    join public.office_members b on b.office_id = a.office_id
    where a.user_id = auth.uid() and b.user_id = profiles.user_id));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- Ordem estável da linha do tempo (created_at empata dentro de uma transação)
-- -----------------------------------------------------------------------------

alter table public.case_events add column if not exists seq bigint generated always as identity;
create index if not exists case_events_lead_seq_idx on public.case_events(lead_id, seq desc);

-- -----------------------------------------------------------------------------
-- Fase pela UI: autor é sempre auth.uid(), actor sempre 'humano'
-- -----------------------------------------------------------------------------

create or replace function public.ui_advance_phase(p_lead uuid, p_to public.case_phase, p_reason text default null)
returns public.leads
language plpgsql security definer
set search_path = public
as $$
declare v_office uuid;
begin
  if auth.uid() is null then raise exception 'ui_advance_phase exige usuário autenticado'; end if;
  select office_id into v_office from public.leads where id = p_lead;
  if v_office is null or not public.is_office_member(v_office) then raise exception 'lead não encontrado'; end if;
  return public.advance_phase(p_lead, p_to, 'humano', auth.uid(), null, p_reason, 'equipe');
end;
$$;

create or replace function public.ui_qualification_gate(p_lead uuid)
returns public.lead_qualification
language plpgsql security definer
set search_path = public
as $$
declare v_office uuid;
begin
  if auth.uid() is null then raise exception 'ui_qualification_gate exige usuário autenticado'; end if;
  select office_id into v_office from public.leads where id = p_lead;
  if v_office is null or not public.is_office_member(v_office) then raise exception 'lead não encontrado'; end if;
  return public.qualification_gate(p_lead, 'humano', auth.uid());
end;
$$;

-- -----------------------------------------------------------------------------
-- Eventos automáticos: dados do caso e provas
-- -----------------------------------------------------------------------------

-- Quem edita case_data pela UI é humano (auth.uid()); pelo n8n é a IA (uid nulo).
create or replace function public.case_data_log_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_actor text := case when auth.uid() is not null then 'humano' else coalesce(new.updated_by_actor, 'ia') end;
  v_changed jsonb;
begin
  if tg_op = 'INSERT' then
    v_changed := to_jsonb(new) - 'lead_id' - 'office_id' - 'updated_at' - 'updated_by_actor';
  else
    select coalesce(jsonb_object_agg(n.key, n.value), '{}'::jsonb) into v_changed
    from jsonb_each(to_jsonb(new)) n
    left join jsonb_each(to_jsonb(old)) o on o.key = n.key
    where n.key not in ('updated_at','updated_by_actor') and n.value is distinct from o.value;
    if v_changed = '{}'::jsonb then return new; end if;
  end if;
  perform public.log_event(new.office_id, new.lead_id, 'case_data_updated', v_actor, auth.uid(), null,
    jsonb_build_object('fields', v_changed));
  return new;
end; $$;
drop trigger if exists case_data_log_event on public.case_data;
create trigger case_data_log_event after insert or update on public.case_data
  for each row execute function public.case_data_log_event();

create or replace function public.evidences_log_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_actor text := case when auth.uid() is not null then 'humano' else 'ia' end;
begin
  if tg_op = 'INSERT' then
    perform public.log_event(new.office_id, new.lead_id, 'evidence_added',
      case when auth.uid() is not null then 'humano' else new.requested_by_actor end, auth.uid(), null,
      jsonb_build_object('evidence_id', new.id, 'kind', new.kind, 'title', new.title, 'status', new.status));
  elsif new.status is distinct from old.status then
    perform public.log_event(new.office_id, new.lead_id, 'evidence_status_changed', v_actor, auth.uid(), null,
      jsonb_build_object('evidence_id', new.id, 'title', new.title, 'from', old.status, 'to', new.status));
  end if;
  return new;
end; $$;
drop trigger if exists evidences_log_event on public.evidences;
create trigger evidences_log_event after insert or update on public.evidences
  for each row execute function public.evidences_log_event();

create or replace function public.tasks_log_event()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.lead_id is null then return new; end if;
  if tg_op = 'INSERT' then
    perform public.log_event(new.office_id, new.lead_id, 'task_created',
      case when auth.uid() is not null then 'humano' else new.created_by_actor end, auth.uid(), null,
      jsonb_build_object('task_id', new.id, 'title', new.title, 'due_at', new.due_at));
  elsif new.done_at is not null and old.done_at is null then
    perform public.log_event(new.office_id, new.lead_id, 'task_done',
      case when auth.uid() is not null then 'humano' else 'sistema' end, auth.uid(), null,
      jsonb_build_object('task_id', new.id, 'title', new.title));
  end if;
  return new;
end; $$;
drop trigger if exists tasks_log_event on public.tasks;
create trigger tasks_log_event after insert or update on public.tasks
  for each row execute function public.tasks_log_event();

-- -----------------------------------------------------------------------------
-- Cards: a projeção única de leads.phase para kanban, lista e busca
-- -----------------------------------------------------------------------------

create or replace view public.v_case_cards
with (security_invoker = true) as
select
  l.id                                   as lead_id,
  l.office_id,
  l.phase,
  l.phase_changed_at,
  l.tese,
  l.assigned_to,
  l.closed_at, l.closed_by,
  l.created_at,
  ct.id                                  as contact_id,
  ct.name                                as contact_name,
  ct.wa_id                               as contact_phone,
  d.empresa,
  c.id                                   as conversation_id,
  c.ai_paused,
  c.last_message_at,
  c.last_message_preview,
  c.unread_count,
  q.passed                               as qualificado,
  q.faixa,
  q.verbas_total,
  l.prescricao_em,
  (l.prescricao_em - current_date)       as prescricao_dias,
  (l.prescricao_em is not null and l.prescricao_em < current_date)                                         as prescricao_vencida,
  (l.prescricao_em is not null and l.prescricao_em >= current_date
     and (l.prescricao_em - current_date) <= p.alerta_prescricao_dias)                                       as prescricao_alerta,
  exists (select 1 from public.human_interventions h
          where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))                             as intervencao_pendente,
  (select count(*) from public.tasks t where t.lead_id = l.id and t.done_at is null)                         as tarefas_abertas
from public.leads l
join public.contacts ct on ct.id = l.contact_id
left join public.office_params p on p.office_id = l.office_id
left join public.case_data d on d.lead_id = l.id
left join public.lead_qualification q on q.lead_id = l.id
left join lateral (
  select * from public.conversations cv where cv.lead_id = l.id
  order by cv.last_message_at desc nulls last limit 1
) c on true;

-- Busca simples (nome, telefone, empresa, tese). Sem pg_trgm de propósito.
create or replace function public.search_cases(p_office uuid, p_q text, p_limit int default 50)
returns setof public.v_case_cards
language sql stable
set search_path = public
as $$
  select * from public.v_case_cards v
  where v.office_id = p_office
    and (coalesce(p_q, '') = '' or
         v.contact_name ilike '%' || p_q || '%' or
         v.contact_phone ilike '%' || regexp_replace(p_q, '\D', '', 'g') || '%' and regexp_replace(p_q, '\D', '', 'g') <> '' or
         v.empresa ilike '%' || p_q || '%' or
         v.tese ilike '%' || p_q || '%')
  order by v.last_message_at desc nulls last, v.created_at desc
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- Dossiê v2: card, nomes dos autores, equipe
-- -----------------------------------------------------------------------------

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
    'cost', (select to_jsonb(ac) from public.lead_acquisition_cost ac where ac.lead_id = p_lead),
    'params', (select jsonb_build_object('alerta_prescricao_dias', p.alerta_prescricao_dias, 'ticket_minimo', p.ticket_minimo,
                                         'vinculo_minimo_meses', p.vinculo_minimo_meses, 'honorarios_percent', p.honorarios_percent)
               from public.office_params p where p.office_id = (select office_id from public.leads where id = p_lead))
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- -----------------------------------------------------------------------------
-- Realtime: kanban, linha do tempo, tarefas e fila ao vivo
-- -----------------------------------------------------------------------------

select public.add_to_realtime('leads');
select public.add_to_realtime('case_events');
select public.add_to_realtime('tasks');
select public.add_to_realtime('human_interventions');
select public.add_to_realtime('evidences');

-- Realtime com RLS precisa de replica identity full para filtrar UPDATE/DELETE por linha
alter table public.leads replica identity full;
alter table public.conversations replica identity full;
alter table public.case_events replica identity full;

-- -----------------------------------------------------------------------------
-- Storage: bucket 'provas' (só existe dentro do Supabase)
-- -----------------------------------------------------------------------------

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_tables where schemaname = 'storage' and tablename = 'buckets') then
    insert into storage.buckets (id, name, public) values ('provas', 'provas', false) on conflict (id) do nothing;

    execute 'drop policy if exists provas_select on storage.objects';
    execute $p$create policy provas_select on storage.objects for select to authenticated
      using (bucket_id = 'provas' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
    execute 'drop policy if exists provas_insert on storage.objects';
    execute $p$create policy provas_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'provas' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
    execute 'drop policy if exists provas_delete on storage.objects';
    execute $p$create policy provas_delete on storage.objects for delete to authenticated
      using (bucket_id = 'provas' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant select on public.v_case_cards to authenticated;
grant execute on function public.ui_advance_phase(uuid, public.case_phase, text) to authenticated;
grant execute on function public.ui_qualification_gate(uuid) to authenticated;
grant execute on function public.search_cases(uuid, text, int) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;
