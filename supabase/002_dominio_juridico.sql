-- =============================================================================
-- 002_dominio_juridico.sql — Sprint 1: o domínio trabalhista entra no banco
--
--   * case_phase: a fase é UMA coluna (leads.phase). Kanban, lista, funil e
--     dashboard são projeções dela. advance_phase() é a única forma de mudar.
--   * sete agentes por papel; agent_for_phase() diz quem atende cada fase.
--   * qualification_gate(): portão por faixa de ticket e tempo mínimo de vínculo.
--   * calc_verbas(): estimativa das verbas rescisórias a partir de case_data.
--   * leads.prescricao_em: coluna indexada, derivada de case_data.demissao.
--   * provas, contrato, briefing, peça (modelos por tese), fila de intervenção.
--   * custo de aquisição derivado de messages.ai_meta.
--   * lead_dossier(): o caso inteiro em uma chamada (respeita RLS).
--
-- Idempotente. Depende de 001_schema.sql.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Fase
-- -----------------------------------------------------------------------------

do $$ begin
  if not exists (select 1 from pg_type t join pg_namespace n on n.oid = t.typnamespace
                 where t.typname = 'case_phase' and n.nspname = 'public') then
    create type public.case_phase as enum (
      'novo',          -- chegou, ninguém falou ainda
      'triagem',       -- recepção: entender o que aconteceu
      'qualificacao',  -- dados do vínculo + portão
      'provas',        -- coleta de documentos e testemunhas
      'calculo',       -- verbas estimadas apresentadas ao lead
      'contrato',      -- honorários enviados / assinatura
      'briefing',      -- entrevista detalhada para a peça
      'peca',          -- redação e revisão da inicial
      'encerrado'      -- fechado, com closed_by
    );
  end if;
end $$;

alter table public.leads add column if not exists phase public.case_phase not null default 'novo';
alter table public.leads add column if not exists phase_changed_at timestamptz not null default now();
alter table public.leads add column if not exists closed_by text check (closed_by in ('ia','equipe'));
alter table public.leads add column if not exists closed_reason text;
alter table public.leads add column if not exists tese text;              -- tese principal do caso
alter table public.leads add column if not exists prescricao_em date;     -- derivada de case_data.demissao

create index if not exists leads_phase_idx      on public.leads(office_id, phase);
create index if not exists leads_prescricao_idx on public.leads(office_id, prescricao_em) where closed_at is null;

create or replace function public.phase_order(p public.case_phase)
returns int language sql immutable as $$
  select case p
    when 'novo' then 0 when 'triagem' then 1 when 'qualificacao' then 2 when 'provas' then 3
    when 'calculo' then 4 when 'contrato' then 5 when 'briefing' then 6 when 'peca' then 7
    when 'encerrado' then 8 end;
$$;

-- Única porta de mudança de fase. Grava o evento com o autor.
--   actor 'ia' só avança; 'humano' e 'sistema' podem voltar.
--   'encerrado' exige closed_by ('ia'|'equipe'). Reabrir limpa o encerramento.
create or replace function public.advance_phase(
  p_lead uuid,
  p_to public.case_phase,
  p_actor text,
  p_actor_user uuid default null,
  p_agent text default null,
  p_reason text default null,
  p_closed_by text default null
) returns public.leads
language plpgsql security definer
set search_path = public
as $$
declare
  v_lead public.leads;
  v_from public.case_phase;
begin
  if p_actor not in ('ia','humano','sistema') then raise exception 'actor inválido: %', p_actor; end if;
  if p_actor = 'humano' and p_actor_user is null then raise exception 'actor humano exige p_actor_user'; end if;

  select * into v_lead from public.leads where id = p_lead for update;
  if v_lead.id is null then raise exception 'lead % não existe', p_lead; end if;
  v_from := v_lead.phase;
  if v_from = p_to then return v_lead; end if;

  if p_actor = 'ia' and public.phase_order(p_to) < public.phase_order(v_from) then
    raise exception 'IA não pode retroceder fase (% -> %)', v_from, p_to;
  end if;

  if p_to = 'encerrado' then
    if p_closed_by is null then
      p_closed_by := case p_actor when 'ia' then 'ia' else 'equipe' end;
    end if;
    if p_closed_by not in ('ia','equipe') then raise exception 'closed_by inválido: %', p_closed_by; end if;
    update public.leads
       set phase = p_to, phase_changed_at = now(),
           closed_at = now(), closed_by = p_closed_by, closed_reason = p_reason
     where id = p_lead returning * into v_lead;
    update public.conversations set status = 'closed' where lead_id = p_lead;
  else
    update public.leads
       set phase = p_to, phase_changed_at = now(),
           closed_at = null, closed_by = null, closed_reason = null
     where id = p_lead returning * into v_lead;
    if v_from = 'encerrado' then
      update public.conversations set status = 'open' where lead_id = p_lead;
    end if;
  end if;

  perform public.log_event(v_lead.office_id, p_lead, 'phase_changed', p_actor, p_actor_user, p_agent,
    jsonb_build_object('from', v_from, 'to', p_to, 'reason', p_reason, 'closed_by', v_lead.closed_by));
  return v_lead;
end;
$$;

-- -----------------------------------------------------------------------------
-- Agentes (um papel por fase)
-- -----------------------------------------------------------------------------

create table if not exists public.agents (
  id            uuid primary key default gen_random_uuid(),
  office_id     uuid references public.offices(id) on delete cascade,  -- null = padrão global
  role          text not null,
  name          text not null,
  description   text,
  system_prompt text not null default '',                              -- conteúdo: pendência do produto
  model         text not null default 'claude-sonnet-5',
  temperature   numeric not null default 0.3,
  tools         jsonb not null default '[]'::jsonb,                     -- nomes de tools que o n8n expõe
  enabled       boolean not null default true,
  updated_at    timestamptz not null default now()
);
create unique index if not exists agents_scope_role_uidx
  on public.agents (coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), role);

insert into public.agents (office_id, role, name, description) values
  (null, 'recepcao',     'Recepção',      'Acolhe o lead, entende o que aconteceu e coleta o mínimo para a triagem.'),
  (null, 'qualificacao', 'Qualificação',  'Levanta dados do vínculo (admissão, demissão, salário, rescisão) e roda o portão.'),
  (null, 'provas',       'Provas',        'Pede e organiza documentos, prints, áudios e testemunhas.'),
  (null, 'calculo',      'Cálculo',       'Apresenta a estimativa de verbas e responde dúvidas sobre valores.'),
  (null, 'contrato',     'Contrato',      'Explica honorários, envia contrato e acompanha a assinatura.'),
  (null, 'briefing',     'Briefing',      'Entrevista detalhada para a peça: fatos, datas, pessoas, pedidos.'),
  (null, 'redacao',      'Redação',       'Monta a minuta da inicial a partir do modelo da tese e do briefing.')
on conflict do nothing;

create or replace function public.agent_for_phase(p public.case_phase)
returns text language sql immutable as $$
  select case p
    when 'novo' then 'recepcao' when 'triagem' then 'recepcao'
    when 'qualificacao' then 'qualificacao' when 'provas' then 'provas'
    when 'calculo' then 'calculo' when 'contrato' then 'contrato'
    when 'briefing' then 'briefing' when 'peca' then 'redacao'
    else null end;
$$;

-- Config efetiva do agente: override do escritório ou padrão global.
create or replace function public.agent_config(p_office uuid, p_phase public.case_phase)
returns public.agents
language sql stable
set search_path = public
as $$
  select a.* from public.agents a
  where a.role = public.agent_for_phase(p_phase) and a.enabled
    and (a.office_id = p_office or a.office_id is null)
  order by a.office_id nulls last
  limit 1;
$$;

-- -----------------------------------------------------------------------------
-- Parâmetros do escritório
-- -----------------------------------------------------------------------------

create table if not exists public.office_params (
  office_id               uuid primary key references public.offices(id) on delete cascade,
  ticket_minimo           numeric not null default 5000,     -- abaixo disso o portão reprova
  faixas_ticket           jsonb not null default '[{"faixa":"baixo","ate":10000},{"faixa":"medio","ate":50000},{"faixa":"alto","ate":null}]'::jsonb,
  vinculo_minimo_meses    integer not null default 6,
  alerta_prescricao_dias  integer not null default 90,       -- janela do alerta no card
  honorarios_percent      numeric not null default 30,
  horario_atendimento     jsonb not null default '{"inicio":"08:00","fim":"20:00","dias":[1,2,3,4,5,6]}'::jsonb,
  updated_at              timestamptz not null default now()
);

create or replace function public.offices_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.office_params (office_id) values (new.id) on conflict do nothing;
  return new;
end; $$;
drop trigger if exists offices_after_insert on public.offices;
create trigger offices_after_insert after insert on public.offices
  for each row execute function public.offices_after_insert();

insert into public.office_params (office_id) select id from public.offices on conflict do nothing;

-- -----------------------------------------------------------------------------
-- Dados do vínculo (base do cálculo, do portão e da prescrição)
-- -----------------------------------------------------------------------------

create table if not exists public.case_data (
  lead_id                 uuid primary key references public.leads(id) on delete cascade,
  office_id               uuid not null references public.offices(id) on delete cascade,
  empresa                 text,
  cargo                   text,
  admissao                date,
  demissao                date,
  salario                 numeric,                            -- último salário mensal
  tipo_rescisao           text check (tipo_rescisao in ('sem_justa_causa','justa_causa','pedido_demissao','rescisao_indireta','acordo','termino_contrato','sem_registro','ainda_empregado')),
  aviso_previo            text check (aviso_previo in ('trabalhado','indenizado','nao_cumprido','nao_se_aplica')),
  ctps_assinada           boolean,
  fgts_depositado         boolean,
  ferias_vencidas         integer not null default 0,        -- períodos aquisitivos vencidos não gozados
  horas_extras_semanais   numeric not null default 0,        -- média não paga
  verbas_pagas            numeric not null default 0,        -- já recebido na rescisão
  extras                  jsonb not null default '{}'::jsonb, -- assédio, insalubridade, etc.
  updated_by_actor        text not null default 'ia' check (updated_by_actor in ('ia','humano','sistema')),
  updated_at              timestamptz not null default now(),
  constraint case_data_datas check (admissao is null or demissao is null or demissao >= admissao)
);

-- Prescrição bienal (CF art. 7º, XXIX): 2 anos da extinção do contrato.
-- A quinquenal (5 anos retroativos) é aplicada no cálculo, não aqui.
create or replace function public.case_data_sync_lead()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  update public.leads
     set prescricao_em = case when new.demissao is not null then (new.demissao + interval '2 years')::date else null end
   where id = new.lead_id;
  return new;
end; $$;
drop trigger if exists case_data_sync_lead on public.case_data;
create trigger case_data_sync_lead before insert or update on public.case_data
  for each row execute function public.case_data_sync_lead();

create or replace function public.vinculo_meses(p_admissao date, p_demissao date)
returns int language sql immutable as $$
  select case when p_admissao is null then null
         else (extract(year from age(coalesce(p_demissao, current_date), p_admissao)) * 12
             + extract(month from age(coalesce(p_demissao, current_date), p_admissao)))::int end;
$$;

-- Estimativa de verbas. É ESTIMATIVA para triagem, não cálculo pericial.
-- Retorna o detalhamento e o total líquido do que ainda seria devido.
create or replace function public.calc_verbas(p_lead uuid)
returns jsonb
language plpgsql stable
set search_path = public
as $$
declare
  d public.case_data;
  v_meses int;
  v_meses_5 int;                 -- limitado pela quinquenal
  v_anos int;
  v_saldo numeric := 0;
  v_aviso numeric := 0;
  v_13 numeric := 0;
  v_ferias_prop numeric := 0;
  v_ferias_venc numeric := 0;
  v_fgts_nao_dep numeric := 0;
  v_multa_fgts numeric := 0;
  v_he numeric := 0;
  v_total numeric := 0;
  v_sem_justa boolean;
  v_meses_ano int;
  v_meses_aquis int;
begin
  select * into d from public.case_data where lead_id = p_lead;
  if d.lead_id is null or d.salario is null or d.admissao is null then
    return jsonb_build_object('calculado', false, 'motivo', 'faltam salario/admissao');
  end if;

  v_meses := public.vinculo_meses(d.admissao, d.demissao);
  v_meses_5 := least(v_meses, 60);
  v_anos := v_meses / 12;
  v_sem_justa := d.tipo_rescisao in ('sem_justa_causa','rescisao_indireta');

  if d.demissao is not null then
    -- saldo de salário do mês da demissão
    v_saldo := round(d.salario / 30 * extract(day from d.demissao), 2);

    -- aviso prévio indenizado: 30 dias + 3 por ano completo, máx. 90 (Lei 12.506/11)
    if v_sem_justa and coalesce(d.aviso_previo, 'indenizado') in ('indenizado','nao_cumprido') then
      v_aviso := round(d.salario / 30 * least(30 + 3 * v_anos, 90), 2);
    end if;

    -- 13º proporcional: meses do ano com 15+ dias
    v_meses_ano := extract(month from d.demissao)::int - (case when extract(day from d.demissao) >= 15 then 0 else 1 end);
    if extract(year from d.admissao) = extract(year from d.demissao) then
      v_meses_ano := v_meses_ano - (extract(month from d.admissao)::int - 1);
    end if;
    if d.tipo_rescisao <> 'justa_causa' then
      v_13 := round(d.salario * greatest(v_meses_ano, 0) / 12, 2);
    end if;

    -- férias proporcionais + 1/3
    v_meses_aquis := v_meses % 12;
    if d.tipo_rescisao <> 'justa_causa' then
      v_ferias_prop := round(d.salario * v_meses_aquis / 12 * 4 / 3, 2);
    end if;
  end if;

  -- férias vencidas em dobro só após o período concessivo; aqui simples + 1/3 (conservador)
  v_ferias_venc := round(d.ferias_vencidas * d.salario * 4 / 3, 2);

  -- FGTS 8% não depositado (últimos 60 meses) e multa de 40%
  if coalesce(d.fgts_depositado, true) = false then
    v_fgts_nao_dep := round(d.salario * 0.08 * v_meses_5, 2);
  end if;
  if v_sem_justa then
    v_multa_fgts := round(d.salario * 0.08 * v_meses * 0.40, 2);
  end if;

  -- horas extras não pagas: divisor 220, adicional 50%, 4,5 semanas/mês, últimos 60 meses
  if d.horas_extras_semanais > 0 then
    v_he := round(d.salario / 220 * 1.5 * d.horas_extras_semanais * 4.5 * v_meses_5, 2);
  end if;

  v_total := v_saldo + v_aviso + v_13 + v_ferias_prop + v_ferias_venc + v_fgts_nao_dep + v_multa_fgts + v_he
             - coalesce(d.verbas_pagas, 0);
  if v_total < 0 then v_total := 0; end if;

  return jsonb_build_object(
    'calculado', true,
    'vinculo_meses', v_meses,
    'itens', jsonb_build_object(
      'saldo_salario', v_saldo,
      'aviso_previo', v_aviso,
      'decimo_terceiro', v_13,
      'ferias_proporcionais', v_ferias_prop,
      'ferias_vencidas', v_ferias_venc,
      'fgts_nao_depositado', v_fgts_nao_dep,
      'multa_fgts_40', v_multa_fgts,
      'horas_extras', v_he
    ),
    'verbas_pagas', coalesce(d.verbas_pagas, 0),
    'total', round(v_total, 2),
    'aviso', 'Estimativa de triagem. Não substitui cálculo pericial.'
  );
end;
$$;

create or replace function public.faixa_ticket(p_office uuid, p_valor numeric)
returns text language sql stable set search_path = public as $$
  select coalesce((
    select f->>'faixa'
    from public.office_params p, jsonb_array_elements(p.faixas_ticket) with ordinality as f(f, i)
    where p.office_id = p_office
      and (f->>'ate' is null or p_valor <= (f->>'ate')::numeric)
    order by i limit 1
  ), 'indefinida');
$$;

-- -----------------------------------------------------------------------------
-- Portão de qualificação
-- -----------------------------------------------------------------------------

create table if not exists public.lead_qualification (
  lead_id           uuid primary key references public.leads(id) on delete cascade,
  office_id         uuid not null references public.offices(id) on delete cascade,
  passed            boolean not null,
  faixa             text,
  verbas            jsonb,
  verbas_total      numeric,
  vinculo_meses     integer,
  motivos           text[] not null default '{}',
  evaluated_by_actor text not null default 'sistema' check (evaluated_by_actor in ('ia','humano','sistema')),
  evaluated_at      timestamptz not null default now()
);

-- Avalia e persiste. Reprova por: vínculo curto, ticket abaixo do mínimo, prescrição vencida.
create or replace function public.qualification_gate(p_lead uuid, p_actor text default 'sistema', p_actor_user uuid default null)
returns public.lead_qualification
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  p public.office_params;
  v_verbas jsonb;
  v_total numeric;
  v_meses int;
  v_motivos text[] := '{}';
  q public.lead_qualification;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  select * into p from public.office_params where office_id = l.office_id;

  v_verbas := public.calc_verbas(p_lead);
  if not coalesce((v_verbas->>'calculado')::boolean, false) then
    v_motivos := v_motivos || 'dados_insuficientes';
  else
    v_total := (v_verbas->>'total')::numeric;
    v_meses := (v_verbas->>'vinculo_meses')::int;
    if v_meses < p.vinculo_minimo_meses then v_motivos := v_motivos || format('vinculo_curto:%s<%s', v_meses, p.vinculo_minimo_meses); end if;
    if v_total < p.ticket_minimo then v_motivos := v_motivos || format('ticket_baixo:%s<%s', v_total, p.ticket_minimo); end if;
  end if;
  if l.prescricao_em is not null and l.prescricao_em < current_date then
    v_motivos := v_motivos || format('prescrito_em:%s', l.prescricao_em);
  end if;

  insert into public.lead_qualification (lead_id, office_id, passed, faixa, verbas, verbas_total, vinculo_meses, motivos, evaluated_by_actor, evaluated_at)
  values (p_lead, l.office_id, cardinality(v_motivos) = 0, public.faixa_ticket(l.office_id, coalesce(v_total, 0)),
          v_verbas, v_total, v_meses, v_motivos, p_actor, now())
  on conflict (lead_id) do update
    set passed = excluded.passed, faixa = excluded.faixa, verbas = excluded.verbas, verbas_total = excluded.verbas_total,
        vinculo_meses = excluded.vinculo_meses, motivos = excluded.motivos,
        evaluated_by_actor = excluded.evaluated_by_actor, evaluated_at = now()
  returning * into q;

  perform public.log_event(l.office_id, p_lead, 'qualification_evaluated', p_actor, p_actor_user, null,
    jsonb_build_object('passed', q.passed, 'faixa', q.faixa, 'total', q.verbas_total, 'motivos', to_jsonb(q.motivos)));
  return q;
end;
$$;

-- -----------------------------------------------------------------------------
-- Provas
-- -----------------------------------------------------------------------------

create table if not exists public.evidences (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  kind                text not null check (kind in ('documento','foto','audio','video','print','testemunha','outro')),
  title               text not null,
  description         text,
  storage_path        text,                                   -- bucket 'provas': office_id/lead_id/arquivo
  message_id          uuid references public.messages(id) on delete set null,
  status              text not null default 'solicitada' check (status in ('solicitada','recebida','validada','rejeitada')),
  requested_by_actor  text not null default 'ia' check (requested_by_actor in ('ia','humano','sistema')),
  validated_by        uuid references auth.users(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists evidences_lead_idx on public.evidences(lead_id, created_at);
drop trigger if exists evidences_touch on public.evidences;
create trigger evidences_touch before update on public.evidences
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Contrato
-- -----------------------------------------------------------------------------

create table if not exists public.contracts (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  status              text not null default 'rascunho' check (status in ('rascunho','enviado','assinado','recusado','cancelado')),
  honorarios_percent  numeric not null,
  document_path       text,
  signature_provider  text,                                   -- ex.: 'clicksign','zapsign','manual'
  signature_ref       text,                                   -- id externo da assinatura
  sent_at             timestamptz,
  signed_at           timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create unique index if not exists contracts_one_active_per_lead on public.contracts(lead_id)
  where status in ('rascunho','enviado','assinado');
drop trigger if exists contracts_touch on public.contracts;
create trigger contracts_touch before update on public.contracts
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Briefing (entrevista para a peça)
-- -----------------------------------------------------------------------------

create table if not exists public.briefings (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null unique references public.leads(id) on delete cascade,
  questions           jsonb not null default '[]'::jsonb,
  answers             jsonb not null default '{}'::jsonb,
  summary             text,
  status              text not null default 'em_andamento' check (status in ('em_andamento','concluido')),
  conducted_by_actor  text not null default 'ia' check (conducted_by_actor in ('ia','humano','sistema')),
  completed_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
drop trigger if exists briefings_touch on public.briefings;
create trigger briefings_touch before update on public.briefings
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Peça: modelos por tese e minutas
-- -----------------------------------------------------------------------------

create table if not exists public.piece_templates (
  id                uuid primary key default gen_random_uuid(),
  office_id         uuid references public.offices(id) on delete cascade,   -- null = global
  tese              text not null,
  name              text not null,
  body              text not null,                            -- placeholders {{campo}}
  required_evidence jsonb not null default '[]'::jsonb,       -- kinds/títulos esperados
  active            boolean not null default true,
  updated_at        timestamptz not null default now()
);
create unique index if not exists piece_templates_scope_uidx
  on public.piece_templates (coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), tese, name);

insert into public.piece_templates (office_id, tese, name, body, required_evidence) values
  (null, 'verbas_rescisorias', 'Reclamação trabalhista — verbas rescisórias',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DO DIREITO\n{{fundamentos}}\n\nIII. DOS PEDIDOS\n{{pedidos}}\n\nIV. DO VALOR DA CAUSA\n{{valor_causa}}\n\n{{fechamento}}',
   '["documento","print"]'),
  (null, 'horas_extras', 'Reclamação trabalhista — horas extras',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DA JORNADA\n{{jornada}}\n\nIII. DO DIREITO\n{{fundamentos}}\n\nIV. DOS PEDIDOS\n{{pedidos}}\n\n{{fechamento}}',
   '["documento","print","testemunha"]'),
  (null, 'rescisao_indireta', 'Reclamação trabalhista — rescisão indireta',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DAS FALTAS GRAVES DO EMPREGADOR\n{{faltas}}\n\nIII. DO DIREITO\n{{fundamentos}}\n\nIV. DOS PEDIDOS\n{{pedidos}}\n\n{{fechamento}}',
   '["documento","print","audio","testemunha"]'),
  (null, 'vinculo_empregaticio', 'Reclamação trabalhista — reconhecimento de vínculo',
   E'{{cabecalho}}\n\nI. DOS FATOS\n{{fatos}}\n\nII. DOS REQUISITOS DO VÍNCULO\n{{requisitos}}\n\nIII. DO DIREITO\n{{fundamentos}}\n\nIV. DOS PEDIDOS\n{{pedidos}}\n\n{{fechamento}}',
   '["print","foto","testemunha"]')
on conflict do nothing;

create table if not exists public.pieces (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  template_id         uuid references public.piece_templates(id),
  tese                text not null,
  content             text not null default '',
  status              text not null default 'rascunho' check (status in ('rascunho','revisao','aprovada','protocolada')),
  generated_by_actor  text not null default 'ia' check (generated_by_actor in ('ia','humano','sistema')),
  reviewed_by         uuid references auth.users(id),
  protocolo           text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index if not exists pieces_lead_idx on public.pieces(lead_id, created_at desc);
drop trigger if exists pieces_touch on public.pieces;
create trigger pieces_touch before update on public.pieces
  for each row execute function public.touch_updated_at();

-- -----------------------------------------------------------------------------
-- Fila de intervenção humana
-- -----------------------------------------------------------------------------

create table if not exists public.human_interventions (
  id                  uuid primary key default gen_random_uuid(),
  office_id           uuid not null references public.offices(id) on delete cascade,
  lead_id             uuid not null references public.leads(id) on delete cascade,
  conversation_id     uuid references public.conversations(id) on delete set null,
  category            text not null default 'outro' check (category in ('duvida_juridica','fora_de_escopo','cliente_insatisfeito','pedido_de_humano','erro_ia','prescricao','outro')),
  reason              text not null,
  priority            integer not null default 2 check (priority between 1 and 3),   -- 1 = urgente
  status              text not null default 'pendente' check (status in ('pendente','em_atendimento','resolvida','cancelada')),
  requested_by_actor  text not null default 'ia' check (requested_by_actor in ('ia','humano','sistema')),
  claimed_by          uuid references auth.users(id),
  claimed_at          timestamptz,
  resolved_at         timestamptz,
  resolution          text,
  created_at          timestamptz not null default now()
);
create index if not exists human_interventions_queue_idx
  on public.human_interventions(office_id, priority, created_at) where status in ('pendente','em_atendimento');
create index if not exists human_interventions_lead_idx on public.human_interventions(lead_id);

-- A IA (via n8n) pede ajuda: entra na fila e pausa a conversa. Evento nomeia a IA.
create or replace function public.request_intervention(
  p_lead uuid, p_conversation uuid, p_category text, p_reason text,
  p_priority int default 2, p_actor text default 'ia', p_agent text default null
) returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  h public.human_interventions;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

  select * into h from public.human_interventions
   where lead_id = p_lead and status in ('pendente','em_atendimento') limit 1;
  if h.id is not null then return h; end if;

  insert into public.human_interventions (office_id, lead_id, conversation_id, category, reason, priority, requested_by_actor)
  values (l.office_id, p_lead, p_conversation, p_category, p_reason, p_priority, p_actor)
  returning * into h;

  if p_conversation is not null then
    update public.conversations set ai_paused = true, paused_at = now() where id = p_conversation and not ai_paused;
  end if;
  perform public.log_event(l.office_id, p_lead, 'intervention_requested', p_actor, null, p_agent,
    jsonb_build_object('intervention_id', h.id, 'category', p_category, 'reason', p_reason, 'priority', p_priority), p_conversation);
  return h;
end;
$$;

create or replace function public.claim_intervention(p_id uuid)
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'claim_intervention exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if h.status <> 'pendente' then return h; end if;
  update public.human_interventions set status = 'em_atendimento', claimed_by = auth.uid(), claimed_at = now()
   where id = p_id returning * into h;
  if h.conversation_id is not null then perform public.take_over(h.conversation_id); end if;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_claimed', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id), h.conversation_id);
  return h;
end;
$$;

create or replace function public.resolve_intervention(p_id uuid, p_resolution text, p_release_ai boolean default true)
returns public.human_interventions
language plpgsql security definer
set search_path = public
as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'resolve_intervention exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if h.status in ('resolvida','cancelada') then return h; end if;
  update public.human_interventions
     set status = 'resolvida', resolved_at = now(), resolution = p_resolution, claimed_by = coalesce(claimed_by, auth.uid())
   where id = p_id returning * into h;
  perform public.log_event(h.office_id, h.lead_id, 'intervention_resolved', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id, 'resolution', p_resolution, 'release_ai', p_release_ai), h.conversation_id);
  if p_release_ai and h.conversation_id is not null then perform public.release_to_ai(h.conversation_id); end if;
  return h;
end;
$$;

-- ai_should_reply ganha o domínio: caso encerrado ou intervenção aberta = IA cala.
create or replace function public.ai_should_reply(p_conversation uuid)
returns boolean
language sql stable
set search_path = public
as $$
  select coalesce((
    select c.status = 'open' and not c.ai_paused and o.active
       and l.phase <> 'encerrado'
       and not exists (select 1 from public.human_interventions h
                       where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))
    from public.conversations c
    join public.offices o on o.id = c.office_id
    join public.leads l on l.id = c.lead_id
    where c.id = p_conversation
  ), false);
$$;

-- -----------------------------------------------------------------------------
-- Efeitos estruturados do agente (n8n chama depois de cada resposta da IA)
-- Tudo aqui nomeia a IA como autor. A resposta em si é gravada em messages
-- pelo workflow, ANTES de qualquer envio.
-- -----------------------------------------------------------------------------

create or replace function public.apply_agent_effects(
  p_lead uuid,
  p_conversation uuid,
  p_agent_role text,
  p_case_data jsonb default null,
  p_advance_to text default null,
  p_advance_reason text default null,
  p_intervention jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

  if p_case_data is not null and jsonb_typeof(p_case_data) = 'object' and p_case_data <> '{}'::jsonb then
    insert into public.case_data (lead_id, office_id, updated_by_actor)
    values (p_lead, l.office_id, 'ia')
    on conflict (lead_id) do nothing;

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
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', p_agent_role);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  return v_result;
end;
$$;

-- -----------------------------------------------------------------------------
-- Custo de aquisição (derivado de messages.ai_meta, nunca digitado)
-- ai_meta esperado: {agent_role, model, tokens_in, tokens_out, cost_usd}
-- -----------------------------------------------------------------------------

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
left join public.messages m on m.conversation_id = c.id and m.direction = 'out'
group by l.id, l.office_id;

-- -----------------------------------------------------------------------------
-- Dossiê: o caso inteiro em uma chamada. security invoker => RLS decide.
-- -----------------------------------------------------------------------------

create or replace function public.lead_dossier(p_lead uuid)
returns jsonb
language sql stable
set search_path = public
as $$
  select jsonb_build_object(
    'lead', (select to_jsonb(l) from public.leads l where l.id = p_lead),
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
    'events', (select coalesce(jsonb_agg(to_jsonb(ev) order by ev.created_at desc), '[]'::jsonb)
               from (select * from public.case_events where lead_id = p_lead order by created_at desc limit 300) ev),
    'cost', (select to_jsonb(ac) from public.lead_acquisition_cost ac where ac.lead_id = p_lead)
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------

select public.apply_office_rls('office_params', array['admin']);
select public.apply_office_rls('case_data');
select public.apply_office_rls('lead_qualification');
select public.apply_office_rls('evidences');
select public.apply_office_rls('contracts', array['admin','advogado']);
select public.apply_office_rls('briefings');
select public.apply_office_rls('pieces', array['admin','advogado']);
select public.apply_office_rls('human_interventions');

-- agents e piece_templates: globais (office_id null) legíveis por todos; override só do próprio escritório (admin)
alter table public.agents enable row level security;
drop policy if exists agents_select on public.agents;
create policy agents_select on public.agents for select to authenticated
  using (office_id is null or public.is_office_member(office_id));
drop policy if exists agents_write on public.agents;
create policy agents_write on public.agents for all to authenticated
  using (office_id is not null and public.member_role(office_id) = 'admin')
  with check (office_id is not null and public.member_role(office_id) = 'admin');

alter table public.piece_templates enable row level security;
drop policy if exists piece_templates_select on public.piece_templates;
create policy piece_templates_select on public.piece_templates for select to authenticated
  using (office_id is null or public.is_office_member(office_id));
drop policy if exists piece_templates_write on public.piece_templates;
create policy piece_templates_write on public.piece_templates for all to authenticated
  using (office_id is not null and public.member_role(office_id) in ('admin','advogado'))
  with check (office_id is not null and public.member_role(office_id) in ('admin','advogado'));

-- Cliente: lê dossiê, calcula, roda o portão, atende a fila. Fase só via 003 (ui_advance_phase).
grant execute on function public.lead_dossier(uuid) to authenticated;
grant execute on function public.calc_verbas(uuid) to authenticated;
grant execute on function public.faixa_ticket(uuid, numeric) to authenticated;
grant execute on function public.claim_intervention(uuid) to authenticated;
grant execute on function public.resolve_intervention(uuid, text, boolean) to authenticated;
revoke execute on function public.advance_phase(uuid, public.case_phase, text, uuid, text, text, text) from anon, authenticated;
revoke execute on function public.qualification_gate(uuid, text, uuid) from anon, authenticated;
revoke execute on function public.request_intervention(uuid, uuid, text, text, int, text, text) from anon, authenticated;
revoke execute on function public.agent_config(uuid, public.case_phase) from anon, authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb) from anon, authenticated;
