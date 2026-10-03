-- =============================================================================
-- 014_paridade_regras.sql — paridade de regras com a Láquila (P1)
--
-- 1. Faixas de ticket da Láquila: abaixo de R$ 2.000 inviável; LOW até 30 mil;
--    MID até 80 mil; HIGH acima. Defaults novos, linhas com os defaults antigos
--    atualizadas, faixa recalculada nos casos abertos.
-- 2. Tempo mínimo de vínculo por tipo de saída (com/sem vínculo × demitido /
--    pediu demissão / ainda trabalha) e "ignorar o tempo em caso de acidente".
--    office_params.vinculo_minimo_meses fica, mas o portão não lê mais.
-- 3. Métricas comerciais e taxa de manutenção em offices; o prompt do Closer
--    usa {{proposta_honorarios}}, {{prova_social}} e {{taxa_manutencao}}.
--    ui_save_empresa salva Empresa + parâmetros numa chamada.
-- 4. Encerramento por motivo do catálogo (close_reasons): o código define o
--    tipo (inviável / insanável). Humano por ui_close_lead, IA por
--    apply_agent_effects (advance_to 'encerrado' + advance_reason = código).
-- 5. Etapa detalhada do lead (lead_etapa), só projeção: novo … protocolado,
--    humano_assumiu, encerrado. phase_changed grava etapa_from/etapa_to.
-- 6. Agentes com nome de pessoa (persona_nome), títulos da Láquila e o 8º
--    agente, Saneador. agent_for_lead olha a etapa da peça. Jornada com 5
--    etapas: Closer, Entrevistador, Coletor, Saneador, Redator.
-- 7. Marketing com Claude e OpenAI separados.
-- 8. Consistência: soltar em "Peça" leva a peça a rascunho; quem reivindica um
--    lead com peça em revisão vira o revisor; régua sem template abre
--    follow_up_esgotado em vez de pular o lead para sempre.
--
-- VIEWS NOVAS (e por quê): o run.sh reaplica 001..015 duas vezes. Na segunda
-- rodada, 003/009/010/012/013 recriam v_case_cards, v_marketing_lancamentos,
-- v_legal_cards, v_intervention_leads e v_workflow_cards com as colunas antigas, e
-- o Postgres não deixa um CREATE OR REPLACE VIEW tirar colunas. Por isso as
-- colunas novas moram em views novas (as antigas continuam iguais):
--   v_clientes        = v_case_cards      + etapa, agente, encerramento
--   v_fluxo_cards     = v_workflow_cards  + etapa, agente com persona, encerramento
--   v_juridico_cards  = v_legal_cards     + qualidade, versão, docx, prazo,
--                                           responsável, etapa, agente
--   v_fila_leads      = v_intervention_leads + etapa, agente
--   v_marketing_dia   = v_marketing_lancamentos + Claude / OpenAI separados
-- Pelo mesmo motivo, funções que mudam de assinatura ganham nome novo ou
-- aridade nova (a antiga é derrubada aqui; a migration antiga a recria na
-- reaplicação e esta derruba de novo).
--
-- Idempotente. Rodar depois de 013.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 0. Utilitário: valor em reais no padrão brasileiro (R$ 12.101,00)
-- -----------------------------------------------------------------------------
create or replace function public.brl(p numeric)
returns text language sql immutable set search_path = public as $$
  select case when p is null then null
    else 'R$ ' || translate(to_char(round(p, 2), 'FM999,999,999,990.00'), ',.', '.,') end;
$$;

-- -----------------------------------------------------------------------------
-- 1. Faixas de ticket
-- -----------------------------------------------------------------------------
alter table public.office_params alter column ticket_minimo set default 2000;
alter table public.office_params alter column faixas_ticket
  set default '[{"faixa":"baixo","ate":30000},{"faixa":"medio","ate":80000},{"faixa":"alto","ate":null}]'::jsonb;

update public.office_params set ticket_minimo = 2000, updated_at = now() where ticket_minimo = 5000;
update public.office_params
   set faixas_ticket = '[{"faixa":"baixo","ate":30000},{"faixa":"medio","ate":80000},{"faixa":"alto","ate":null}]'::jsonb,
       updated_at = now()
 where faixas_ticket = '[{"faixa":"baixo","ate":10000},{"faixa":"medio","ate":50000},{"faixa":"alto","ate":null}]'::jsonb;

-- Recalcula a faixa dos casos abertos com a régua nova.
update public.lead_qualification q
   set faixa = public.faixa_ticket(q.office_id, coalesce(q.verbas_total, 0))
  from public.leads l
 where l.id = q.lead_id and l.closed_at is null
   and q.faixa is distinct from public.faixa_ticket(q.office_id, coalesce(q.verbas_total, 0));

update public.contracts k
   set faixa = public.faixa_ticket(k.office_id, k.valor_causa)
  from public.leads l
 where l.id = k.lead_id and l.closed_at is null and k.valor_causa is not null
   and k.faixa is distinct from public.faixa_ticket(k.office_id, k.valor_causa);

-- -----------------------------------------------------------------------------
-- 2. Tempo mínimo de vínculo por tipo de saída
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'office_params' and column_name = 'vinculo_minimo') then
    alter table public.office_params add column vinculo_minimo jsonb not null default
      '{"com_vinculo":{"demitido":0,"pediu_demissao":0,"ainda_trabalha":0},"sem_vinculo":{"demitido":0,"pediu_demissao":0,"ainda_trabalha":0}}'::jsonb;
    -- Quem tinha mudado o mínimo antigo (padrão era 6) leva o mesmo número para os seis campos.
    update public.office_params
       set vinculo_minimo = jsonb_build_object(
             'com_vinculo', jsonb_build_object('demitido', vinculo_minimo_meses, 'pediu_demissao', vinculo_minimo_meses, 'ainda_trabalha', vinculo_minimo_meses),
             'sem_vinculo', jsonb_build_object('demitido', vinculo_minimo_meses, 'pediu_demissao', vinculo_minimo_meses, 'ainda_trabalha', vinculo_minimo_meses))
     where vinculo_minimo_meses <> 6;
  end if;
end $$;
alter table public.office_params add column if not exists ignorar_tempo_acidente boolean not null default true;

comment on column public.office_params.vinculo_minimo_meses is
  'OBSOLETA desde a 014: o portão usa vinculo_minimo (por tipo de saída) e ignorar_tempo_acidente. Mantida só para não quebrar leituras antigas.';
comment on column public.office_params.vinculo_minimo is
  'Meses mínimos de vínculo: {"com_vinculo"|"sem_vinculo": {"demitido","pediu_demissao","ainda_trabalha"}}. 0 = sem exigência.';

-- Tipo de saída do portão a partir de case_data.tipo_rescisao.
create or replace function public.tipo_saida(p_tipo_rescisao text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_tipo_rescisao = 'pedido_demissao' then 'pediu_demissao'
    when p_tipo_rescisao in ('rescisao_indireta', 'ainda_empregado') then 'ainda_trabalha'
    else 'demitido' end;   -- sem_justa_causa, justa_causa, acordo, termino_contrato, sem_registro, não informado
$$;

-- Meses exigidos para este caso (0 = sem exigência).
create or replace function public.vinculo_minimo_exigido(p_office uuid, p_tipo_rescisao text, p_ctps boolean, p_acidente boolean)
returns int language sql stable set search_path = public as $$
  select case
    when coalesce(p_acidente, false) and p.ignorar_tempo_acidente then 0
    else coalesce((p.vinculo_minimo
            -> (case when coalesce(p_ctps, true) and coalesce(p_tipo_rescisao, '') <> 'sem_registro' then 'com_vinculo' else 'sem_vinculo' end)
            ->> public.tipo_saida(p_tipo_rescisao))::int, 0) end
  from public.office_params p where p.office_id = p_office;
$$;

create or replace function public.qualification_gate(p_lead uuid, p_actor text default 'sistema', p_actor_user uuid default null)
returns public.lead_qualification
language plpgsql security definer set search_path = public as $$
declare
  l public.leads;
  p public.office_params;
  d public.case_data;
  v_verbas jsonb;
  v_total numeric;
  v_meses int;
  v_min int;
  v_motivos text[] := '{}';
  q public.lead_qualification;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  select * into p from public.office_params where office_id = l.office_id;
  select * into d from public.case_data where lead_id = p_lead;

  v_verbas := public.calc_verbas(p_lead);
  if not coalesce((v_verbas->>'calculado')::boolean, false) then
    v_motivos := v_motivos || 'dados_insuficientes';
  else
    v_total := (v_verbas->>'total')::numeric;
    v_meses := (v_verbas->>'vinculo_meses')::int;
    v_min := public.vinculo_minimo_exigido(l.office_id, d.tipo_rescisao, d.ctps_assinada, d.acidente_trabalho);
    if v_min > 0 and v_meses < v_min then
      v_motivos := v_motivos || format('vinculo_curto:%s<%s', v_meses, v_min);
    end if;
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
    jsonb_build_object('passed', q.passed, 'faixa', q.faixa, 'total', q.verbas_total, 'motivos', to_jsonb(q.motivos),
                       'vinculo_minimo', v_min, 'tipo_saida', public.tipo_saida(d.tipo_rescisao)));
  return q;
end;
$$;

-- -----------------------------------------------------------------------------
-- 3. Métricas comerciais e taxa de manutenção
-- -----------------------------------------------------------------------------
alter table public.offices
  add column if not exists exemplo_honorarios text,
  add column if not exists volume_processos int,
  add column if not exists clientes_representados int,
  add column if not exists video_institucional_url text,
  add column if not exists plataforma_reviews text,
  add column if not exists avaliacoes_5_estrelas int,
  add column if not exists cobra_taxa_manutencao boolean not null default false,
  add column if not exists taxa_manutencao_valor numeric,
  add column if not exists taxa_manutencao_periodicidade text,
  add column if not exists taxa_manutencao_obs text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'offices_taxa_manutencao_periodicidade_check') then
    alter table public.offices add constraint offices_taxa_manutencao_periodicidade_check
      check (taxa_manutencao_periodicidade is null or taxa_manutencao_periodicidade in ('mensal','unica','anual'));
  end if;
end $$;

-- Bloco "escritorio" que os agentes e o dossiê usam. Os textos prontos já
-- obedecem à regra: a taxa só aparece quando cobra_taxa_manutencao.
create or replace function public.office_escritorio(p_office uuid)
returns jsonb language sql stable set search_path = public as $$
  with b as (
    select o.*, coalesce(op.honorarios_percent, 30) as pct,
      case when o.cobra_taxa_manutencao and o.taxa_manutencao_valor is not null then
        'Existe também uma taxa de manutenção de ' || public.brl(o.taxa_manutencao_valor) || ' '
        || case o.taxa_manutencao_periodicidade when 'mensal' then 'por mês' when 'anual' then 'por ano' else '(pagamento único)' end
        || '.' || coalesce(' ' || nullif(btrim(o.taxa_manutencao_obs), ''), '')
      else '' end as taxa_texto
    from public.offices o left join public.office_params op on op.office_id = o.id
    where o.id = p_office
  )
  select jsonb_build_object(
    'nome', b.name,
    'honorarios_percent', b.pct,
    'exemplo_honorarios', b.exemplo_honorarios,
    'volume_processos', b.volume_processos,
    'clientes_representados', b.clientes_representados,
    'video_institucional_url', b.video_institucional_url,
    'plataforma_reviews', b.plataforma_reviews,
    'avaliacoes_5_estrelas', b.avaliacoes_5_estrelas,
    'cobra_taxa_manutencao', b.cobra_taxa_manutencao,
    'taxa_manutencao_valor', case when b.cobra_taxa_manutencao then b.taxa_manutencao_valor end,
    'taxa_manutencao_periodicidade', case when b.cobra_taxa_manutencao then b.taxa_manutencao_periodicidade end,
    'taxa_manutencao_obs', case when b.cobra_taxa_manutencao then b.taxa_manutencao_obs end,
    'whatsapp_juridico', b.whatsapp_juridico,
    'site', b.site, 'instagram', b.instagram,
    'taxa_manutencao_texto', b.taxa_texto,
    'proposta_honorarios',
      'E funciona assim: o escritório só cobra ' || b.pct || '% do que você ganhar.'
      || case when b.taxa_texto <> '' then ' Os ' || b.pct || '% só são cobrados se você ganhar. ' || b.taxa_texto
              else ' Se não ganhar, não paga nada. Risco zero pra você.' end
      || ' ' || coalesce(nullif(btrim(b.exemplo_honorarios), ''),
                         'Por exemplo, se ganhar R$ 10 mil, você fica com a maior parte e o escritório com ' || b.pct || '%.'),
    'prova_social', btrim(concat_ws(' ',
      case when b.volume_processos > 0 then 'O escritório já conduziu mais de ' || b.volume_processos || ' processos.' end,
      case when b.clientes_representados > 0 then 'Já representamos mais de ' || b.clientes_representados || ' clientes.' end,
      case when b.avaliacoes_5_estrelas > 0 then 'São ' || b.avaliacoes_5_estrelas || ' avaliações 5 estrelas no ' || coalesce(nullif(b.plataforma_reviews, ''), 'Google') || '.' end,
      case when coalesce(b.video_institucional_url, '') <> '' then 'Vídeo do escritório: ' || b.video_institucional_url end))
  )
  from b;
$$;

-- Salva a tela Empresa (dados + métricas + parâmetros) numa chamada. Só admin.
-- p_office_data: chaves de offices (texto/números); presente = grava (null limpa).
-- p_params: honorarios_percent, ticket_minimo (Threshold LOW), faixa_baixo_ate
-- (Threshold MID), faixa_medio_ate (Threshold HIGH), vinculo_minimo,
-- ignorar_tempo_acidente, alerta_prescricao_dias, cambio_usd_brl, horario_atendimento.
create or replace function public.ui_save_empresa(p_office uuid, p_office_data jsonb default '{}'::jsonb, p_params jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  o jsonb := coalesce(p_office_data, '{}'::jsonb);
  p jsonb := coalesce(p_params, '{}'::jsonb);
  cur public.office_params;
  v_low numeric; v_mid numeric; v_high numeric;
  k text;
begin
  if auth.uid() is null then raise exception 'ui_save_empresa exige usuário'; end if;
  if public.member_role(p_office) is distinct from 'admin' then raise exception 'só o admin do escritório altera a Empresa'; end if;

  if o ? 'taxa_manutencao_periodicidade' and o->>'taxa_manutencao_periodicidade' is not null
     and o->>'taxa_manutencao_periodicidade' not in ('mensal','unica','anual') then
    raise exception 'periodicidade da taxa: mensal, unica ou anual';
  end if;

  update public.offices f set
    name = case when o ? 'name' and coalesce(o->>'name', '') <> '' then o->>'name' else f.name end,
    tipo = case when o ? 'tipo' then coalesce(o->>'tipo', f.tipo) else f.tipo end,
    cnpj = case when o ? 'cnpj' then o->>'cnpj' else f.cnpj end,
    oab_responsavel = case when o ? 'oab_responsavel' then o->>'oab_responsavel' else f.oab_responsavel end,
    fundador = case when o ? 'fundador' then o->>'fundador' else f.fundador end,
    fundacao = case when o ? 'fundacao' then (o->>'fundacao')::date else f.fundacao end,
    endereco = case when o ? 'endereco' then o->>'endereco' else f.endereco end,
    cidade = case when o ? 'cidade' then o->>'cidade' else f.cidade end,
    uf = case when o ? 'uf' then o->>'uf' else f.uf end,
    email = case when o ? 'email' then o->>'email' else f.email end,
    telefone = case when o ? 'telefone' then o->>'telefone' else f.telefone end,
    whatsapp_comercial = case when o ? 'whatsapp_comercial' then o->>'whatsapp_comercial' else f.whatsapp_comercial end,
    whatsapp_juridico = case when o ? 'whatsapp_juridico' then o->>'whatsapp_juridico' else f.whatsapp_juridico end,
    telefone_suporte = case when o ? 'telefone_suporte' then o->>'telefone_suporte' else f.telefone_suporte end,
    site = case when o ? 'site' then o->>'site' else f.site end,
    logo_path = case when o ? 'logo_path' then o->>'logo_path' else f.logo_path end,
    instagram = case when o ? 'instagram' then o->>'instagram' else f.instagram end,
    facebook = case when o ? 'facebook' then o->>'facebook' else f.facebook end,
    linkedin = case when o ? 'linkedin' then o->>'linkedin' else f.linkedin end,
    seguidores_instagram = case when o ? 'seguidores_instagram' then (o->>'seguidores_instagram')::int else f.seguidores_instagram end,
    descricao_comercial = case when o ? 'descricao_comercial' then o->>'descricao_comercial' else f.descricao_comercial end,
    exemplo_honorarios = case when o ? 'exemplo_honorarios' then o->>'exemplo_honorarios' else f.exemplo_honorarios end,
    volume_processos = case when o ? 'volume_processos' then (o->>'volume_processos')::int else f.volume_processos end,
    clientes_representados = case when o ? 'clientes_representados' then (o->>'clientes_representados')::int else f.clientes_representados end,
    video_institucional_url = case when o ? 'video_institucional_url' then o->>'video_institucional_url' else f.video_institucional_url end,
    plataforma_reviews = case when o ? 'plataforma_reviews' then o->>'plataforma_reviews' else f.plataforma_reviews end,
    avaliacoes_5_estrelas = case when o ? 'avaliacoes_5_estrelas' then (o->>'avaliacoes_5_estrelas')::int else f.avaliacoes_5_estrelas end,
    cobra_taxa_manutencao = case when o ? 'cobra_taxa_manutencao' then coalesce((o->>'cobra_taxa_manutencao')::boolean, false) else f.cobra_taxa_manutencao end,
    taxa_manutencao_valor = case when o ? 'taxa_manutencao_valor' then (o->>'taxa_manutencao_valor')::numeric else f.taxa_manutencao_valor end,
    taxa_manutencao_periodicidade = case when o ? 'taxa_manutencao_periodicidade' then o->>'taxa_manutencao_periodicidade' else f.taxa_manutencao_periodicidade end,
    taxa_manutencao_obs = case when o ? 'taxa_manutencao_obs' then o->>'taxa_manutencao_obs' else f.taxa_manutencao_obs end
  where f.id = p_office;

  if p <> '{}'::jsonb then
    insert into public.office_params (office_id) values (p_office) on conflict do nothing;
    select * into cur from public.office_params where office_id = p_office;
    v_low := coalesce((p->>'ticket_minimo')::numeric, cur.ticket_minimo);
    v_mid := coalesce((p->>'faixa_baixo_ate')::numeric,
                      (select (f->>'ate')::numeric from jsonb_array_elements(cur.faixas_ticket) f where f->>'faixa' = 'baixo'));
    v_high := coalesce((p->>'faixa_medio_ate')::numeric,
                       (select (f->>'ate')::numeric from jsonb_array_elements(cur.faixas_ticket) f where f->>'faixa' = 'medio'));
    if not (v_low >= 0 and v_low < v_mid and v_mid < v_high) then
      raise exception 'faixas inválidas: LOW (%) < MID (%) < HIGH (%)', v_low, v_mid, v_high;
    end if;
    if p ? 'vinculo_minimo' then
      foreach k in array array['com_vinculo','sem_vinculo'] loop
        if jsonb_typeof(p->'vinculo_minimo'->k) <> 'object'
           or (select count(*) from jsonb_each_text(p->'vinculo_minimo'->k) e
                where e.key in ('demitido','pediu_demissao','ainda_trabalha') and e.value ~ '^\d+$') <> 3 then
          raise exception 'vinculo_minimo.% precisa de demitido, pediu_demissao e ainda_trabalha (meses, 0 = sem exigência)', k;
        end if;
      end loop;
    end if;
    update public.office_params set
      ticket_minimo = v_low,
      faixas_ticket = jsonb_build_array(jsonb_build_object('faixa','baixo','ate',v_mid), jsonb_build_object('faixa','medio','ate',v_high),
                                        jsonb_build_object('faixa','alto','ate',null)),
      honorarios_percent = coalesce((p->>'honorarios_percent')::numeric, honorarios_percent),
      vinculo_minimo = case when p ? 'vinculo_minimo' then p->'vinculo_minimo' else vinculo_minimo end,
      ignorar_tempo_acidente = coalesce((p->>'ignorar_tempo_acidente')::boolean, ignorar_tempo_acidente),
      alerta_prescricao_dias = coalesce((p->>'alerta_prescricao_dias')::int, alerta_prescricao_dias),
      cambio_usd_brl = coalesce((p->>'cambio_usd_brl')::numeric, cambio_usd_brl),
      horario_atendimento = coalesce(p->'horario_atendimento', horario_atendimento),
      updated_at = now()
    where office_id = p_office;
  end if;

  return jsonb_build_object(
    'office', (select to_jsonb(f) from public.offices f where f.id = p_office),
    'params', (select to_jsonb(x) from public.office_params x where x.office_id = p_office),
    'escritorio', public.office_escritorio(p_office));
end; $$;

-- -----------------------------------------------------------------------------
-- 4. Encerramento por motivo do catálogo
-- -----------------------------------------------------------------------------
create or replace function public.close_reasons()
returns table (codigo text, titulo text, tipo text, ordem int)
language sql immutable set search_path = public as $$
  values
    ('sem_caso',         'Sem caso — inviabilidade jurídica',  'inviavel',  1),
    ('sem_viabilidade',  'Sem viabilidade (pós-entrevista)',   'inviavel',  2),
    ('servidor_publico', 'Servidor público',                   'inviavel',  3),
    ('sem_provas',       'Sem provas',                         'inviavel',  4),
    ('prescrito',        'Prescrito',                          'inviavel',  5),
    ('cliente_desistiu', 'Cliente desistiu / sem interesse',   'insanavel', 6),
    ('insanavel',        'Insanável — não pôde seguir',        'insanavel', 7),
    ('sem_resposta',     'Sem resposta / não atende mais',     'insanavel', 8);
$$;

alter table public.leads drop constraint if exists leads_closed_kind_check;
alter table public.leads add constraint leads_closed_kind_check
  check (closed_kind is null or closed_kind in ('perdido','inviavel','insanavel','outro'));
alter table public.leads add column if not exists closed_code text;
alter table public.leads add column if not exists closed_note text;

-- Grava código/tipo/observação depois que advance_phase encerrou o lead.
create or replace function public.close_lead_with_reason(p_lead uuid, p_reason text, p_kind text, p_note text,
                                                         p_actor text, p_actor_user uuid, p_agent text)
returns public.leads language plpgsql security definer set search_path = public as $$
declare l public.leads; r record; v_title text; v_kind text;
begin
  select * into r from public.close_reasons() c where c.codigo = btrim(p_reason);
  if r.codigo is not null then
    v_title := r.titulo; v_kind := r.tipo;
  else
    v_title := btrim(p_reason);
    v_kind := case when p_kind in ('perdido','inviavel','insanavel','outro') then p_kind else 'outro' end;
  end if;
  if coalesce(v_title, '') = '' then raise exception 'informe o motivo do encerramento'; end if;
  update public.leads set paused = false, followup_next_at = null where id = p_lead;
  l := public.advance_phase(p_lead, 'encerrado', p_actor, p_actor_user, p_agent, v_title);
  update public.leads
     set closed_kind = v_kind, closed_code = r.codigo, closed_note = nullif(btrim(p_note), ''), closed_reason = v_title
   where id = p_lead returning * into l;
  perform public.log_event(l.office_id, p_lead, 'lead_closed', p_actor, p_actor_user, p_agent,
    jsonb_build_object('codigo', r.codigo, 'titulo', v_title, 'tipo', v_kind, 'nota', l.closed_note, 'closed_by', l.closed_by));
  return l;
end; $$;

-- Humano encerra. p_reason = código de close_reasons() (o tipo vem dele);
-- texto livre também é aceito (tipo = p_kind ou 'outro'). p_note é opcional.
drop function if exists public.ui_close_lead(uuid, text, text);
create or replace function public.ui_close_lead(p_lead uuid, p_reason text, p_kind text default null, p_note text default null)
returns public.leads language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_close_lead exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  return public.close_lead_with_reason(p_lead, p_reason, p_kind, p_note, 'humano', auth.uid(), null);
end; $$;

create or replace function public.ui_reopen_lead(p_lead uuid, p_to public.case_phase default null)
returns public.leads language plpgsql security definer set search_path = public as $$
declare l public.leads; v_to public.case_phase;
begin
  if auth.uid() is null then raise exception 'ui_reopen_lead exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  v_to := p_to;
  if v_to is null then
    select (e.payload->>'from')::public.case_phase into v_to
    from public.case_events e where e.lead_id = p_lead and e.type = 'phase_changed' and e.payload->>'to' = 'encerrado'
    order by e.seq desc limit 1;
  end if;
  v_to := coalesce(v_to, 'triagem');
  if v_to = 'encerrado' or v_to = 'novo' then v_to := 'triagem'; end if;
  update public.leads set closed_reason = null, closed_kind = null, closed_code = null, closed_note = null where id = p_lead;
  l := public.advance_phase(p_lead, v_to, 'humano', auth.uid(), null, 'reaberto');
  return l;
end; $$;

-- -----------------------------------------------------------------------------
-- 5. Etapa detalhada do lead (projeção; nenhuma coluna de estado nova)
-- -----------------------------------------------------------------------------
create or replace function public.etapas()
returns table (ordem int, codigo text, titulo text)
language sql immutable set search_path = public as $$
  values
    ( 1, 'novo',              'Novo'),
    ( 2, 'qualificando',      'Qualificando'),
    ( 3, 'qualificado',       'Qualificado'),
    ( 4, 'contrato_enviado',  'Contrato Enviado'),
    ( 5, 'contrato_assinado', 'Contrato Fechado'),
    ( 6, 'em_entrevista',     'Em Entrevista'),
    ( 7, 'em_viabilidade',    'Em Viabilidade'),
    ( 8, 'coletando_docs',    'Coletando Docs'),
    ( 9, 'peticionado',       'Peticionado'),
    (10, 'saneamento',        'Saneamento'),
    (11, 'revisao',           'Revisão'),
    (12, 'aguardando',        'Aguardando'),
    (13, 'pronto_protocolo',  'Pronto p/ Protocolo'),
    (14, 'protocolado',       'Protocolado'),
    (15, 'humano_assumiu',    'Humano Assumiu'),
    (16, 'encerrado',         'Encerrado');
$$;

create or replace function public.etapa_titulo(p_codigo text)
returns text language sql immutable set search_path = public as $$
  select coalesce((select e.titulo from public.etapas() e where e.codigo = p_codigo), p_codigo);
$$;

-- Ordem de precedência: encerrado > protocolado > humano_assumiu > fase.
create or replace function public.lead_etapa(p_lead uuid)
returns text language sql stable set search_path = public as $$
  select case
    when l.phase = 'encerrado' then 'encerrado'
    when l.phase = 'peca' and pc.status = 'protocolada' then 'protocolado'
    when coalesce(cv.ai_paused, false) then 'humano_assumiu'
    when l.phase = 'novo' then 'novo'
    when l.phase in ('triagem','qualificacao') then case when coalesce(q.passed, false) then 'qualificado' else 'qualificando' end
    when l.phase = 'contrato' then case k.status when 'enviado' then 'contrato_enviado' when 'assinado' then 'contrato_assinado' else 'qualificado' end
    when l.phase = 'briefing' then case when b.id is not null then 'em_entrevista' else 'contrato_assinado' end
    when l.phase = 'calculo' then 'em_viabilidade'
    when l.phase = 'provas' then 'coletando_docs'
    when l.phase = 'peca' then case pc.status
                                 when 'saneamento' then 'saneamento' when 'revisao' then 'revisao'
                                 when 'aguardando' then 'aguardando' when 'aprovada' then 'pronto_protocolo'
                                 else 'peticionado' end
  end
  from public.leads l
  left join lateral (select p.status from public.pieces p where p.lead_id = l.id order by p.created_at desc limit 1) pc on true
  left join lateral (select c.ai_paused from public.conversations c where c.lead_id = l.id order by c.last_message_at desc nulls last limit 1) cv on true
  left join public.lead_qualification q on q.lead_id = l.id
  left join lateral (select k.status from public.contracts k where k.lead_id = l.id and k.status in ('rascunho','enviado','assinado')
                     order by k.created_at desc limit 1) k on true
  left join lateral (select b.id from public.briefings b where b.lead_id = l.id limit 1) b on true
  where l.id = p_lead;
$$;

-- advance_phase: igual ao da 002, e o evento passa a levar a etapa de/para.
create or replace function public.advance_phase(
  p_lead uuid, p_to public.case_phase, p_actor text, p_actor_user uuid default null,
  p_agent text default null, p_reason text default null, p_closed_by text default null)
returns public.leads language plpgsql security definer set search_path = public as $$
declare
  v_lead public.leads;
  v_from public.case_phase;
  v_etapa_from text;
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
  v_etapa_from := public.lead_etapa(p_lead);

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
    jsonb_build_object('from', v_from, 'to', p_to, 'reason', p_reason, 'closed_by', v_lead.closed_by,
                       'etapa_from', v_etapa_from, 'etapa_to', public.lead_etapa(p_lead),
                       'etapa_from_titulo', public.etapa_titulo(v_etapa_from),
                       'etapa_to_titulo', public.etapa_titulo(public.lead_etapa(p_lead))));
  return v_lead;
end;
$$;

-- -----------------------------------------------------------------------------
-- 6. Agentes: persona, títulos da Láquila, Saneador, agente por lead, jornada
-- -----------------------------------------------------------------------------
alter table public.agents add column if not exists persona_nome text;
comment on column public.agents.persona_nome is 'Nome de pessoa que o agente usa com o cliente (ex.: Fernanda). Por escritório (linha de override).';

insert into public.agents (office_id, role, name, description) values
  (null, 'saneamento', 'Saneador', 'Conversa com o cliente quando a peça volta da revisão para saneamento: busca o que o revisor pediu.')
on conflict do nothing;
insert into public.agent_prompts (agent_id) select id from public.agents on conflict do nothing;

update public.agents a set name = v.name, description = coalesce(v.descr, a.description), updated_at = now()
from (values
  ('recepcao',     'Closer',                    'Closer · recepção: acolhe o lead e entende o que aconteceu.'),
  ('qualificacao', 'Closer',                    'Closer · qualificação: levanta o vínculo, roda o portão e faz a proposta.'),
  ('contrato',     'Closer',                    'Closer · contrato: coleta os dados, confirma e acompanha a assinatura.'),
  ('briefing',     'Entrevistador',             'Entrevista detalhada depois do contrato: fatos, datas, provas e testemunhas.'),
  ('calculo',      'Qualificador (Calculista)', 'Roda logo após a entrevista: dados base, prescrição e verbas calculadas.'),
  ('provas',       'Coletor',                   'Pede e organiza os documentos pelo WhatsApp.'),
  ('saneamento',   'Saneador',                  null),
  ('redacao',      'Redator',                   'Monta a peça a partir dos blocos, do briefing, da qualificação e das provas.')
) as v(role, name, descr)
where a.office_id is null and a.role = v.role and (a.name is distinct from v.name or (v.descr is not null and a.description is distinct from v.descr));

-- Rótulo "{name} — {persona_nome}" (só {name} sem persona).
create or replace function public.agent_label(p_name text, p_persona text)
returns text language sql immutable set search_path = public as $$
  select case when coalesce(btrim(p_persona), '') = '' then p_name else p_name || ' — ' || btrim(p_persona) end;
$$;

-- Agente do lead: peça em saneamento → Saneador; senão o agente da fase.
create or replace function public.agent_for_lead(p_lead uuid)
returns text language sql stable set search_path = public as $$
  select case
    when l.phase = 'peca' and (select p.status from public.pieces p where p.lead_id = l.id order by p.created_at desc limit 1) = 'saneamento'
      then 'saneamento'
    else public.agent_for_phase(l.phase) end
  from public.leads l where l.id = p_lead;
$$;

create or replace function public.agent_config_role(p_office uuid, p_role text)
returns public.agents language sql stable set search_path = public as $$
  select a.* from public.agents a
  where a.role = p_role and a.enabled and (a.office_id = p_office or a.office_id is null)
  order by a.office_id nulls last
  limit 1;
$$;

create or replace function public.agent_config_lead(p_lead uuid)
returns public.agents language sql stable set search_path = public as $$
  select a.* from public.leads l, public.agent_config_role(l.office_id, public.agent_for_lead(l.id)) a
  where l.id = p_lead and a.id is not null;
$$;

create or replace function public.agent_label_lead(p_lead uuid)
returns text language sql stable set search_path = public as $$
  select public.agent_label(a.name, a.persona_nome) from public.agent_config_lead(p_lead) a;
$$;

-- Texto do prompt com os placeholders resolvidos. Override do escritório sem
-- texto herda o prompt global do mesmo papel.
create or replace function public.agent_prompt_render(p_agent public.agents, p_office uuid)
returns text language sql stable security definer set search_path = public as $$
  with e as (select public.office_escritorio(p_office) as j),
  t as (
    select coalesce(nullif((select p.system_prompt from public.agent_prompts p where p.agent_id = p_agent.id), ''),
                    (select g.system_prompt from public.agents ga join public.agent_prompts g on g.agent_id = ga.id
                      where ga.office_id is null and ga.role = p_agent.role), '') as s
  )
  select
    replace(replace(replace(replace(replace(replace(replace(replace(replace(t.s,
      '{{agent_name}}', coalesce(nullif(btrim(p_agent.persona_nome), ''), p_agent.name)),
      '{{office_name}}', coalesce(e.j->>'nome', 'o escritório')),
      '{{honorarios}}', coalesce(e.j->>'honorarios_percent', '30')),
      '{{whatsapp_juridico}}', coalesce(e.j->>'whatsapp_juridico', 'o número do jurídico (a equipe informa)')),
      '{{proposta_honorarios}}', coalesce(e.j->>'proposta_honorarios', '')),
      '{{prova_social}}', coalesce(nullif(e.j->>'prova_social', ''), '(sem números cadastrados: fale do atendimento todo pelo celular e da equipe que acompanha)')),
      '{{taxa_manutencao}}', coalesce(e.j->>'taxa_manutencao_texto', '')),
      '{{exemplo_honorarios}}', coalesce(e.j->>'exemplo_honorarios', '')),
      '{{video_institucional}}', coalesce(e.j->>'video_institucional_url', ''))
  from t, e;
$$;

-- Config por fase (mantida para quem já chama) e por lead (a que o n8n usa).
create or replace function public.agent_config_full(p_office uuid, p_phase public.case_phase)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object(
    'system_prompt', public.agent_prompt_render(a, p_office),
    'label', public.agent_label(a.name, a.persona_nome),
    'escritorio', public.office_escritorio(p_office))
  from public.agent_config(p_office, p_phase) a;
$$;

create or replace function public.agent_config_full_lead(p_lead uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object(
    'system_prompt', public.agent_prompt_render(a, l.office_id),
    'label', public.agent_label(a.name, a.persona_nome),
    'escritorio', public.office_escritorio(l.office_id),
    'etapa', public.lead_etapa(l.id))
  from public.leads l, public.agent_config_lead(l.id) a
  where l.id = p_lead;
$$;

-- Nome de pessoa do agente no escritório: cria o override (copiando o global)
-- se ainda não existe. O prompt continua herdado do global.
create or replace function public.ui_set_agent_persona(p_office uuid, p_role text, p_persona text)
returns public.agents language plpgsql security definer set search_path = public as $$
declare g public.agents; a public.agents;
begin
  if auth.uid() is null then raise exception 'ui_set_agent_persona exige usuário'; end if;
  if public.member_role(p_office) is distinct from 'admin' then raise exception 'só o admin do escritório altera os agentes'; end if;
  select * into a from public.agents where office_id = p_office and role = p_role;
  if a.id is null then
    select * into g from public.agents where office_id is null and role = p_role;
    if g.id is null then raise exception 'agente desconhecido: %', p_role; end if;
    insert into public.agents (office_id, role, name, description, model, temperature, tools, enabled, persona_nome)
    values (p_office, p_role, g.name, g.description, g.model, g.temperature, g.tools, g.enabled, nullif(btrim(p_persona), ''))
    returning * into a;
    insert into public.agent_prompts (agent_id) values (a.id) on conflict do nothing;
  else
    update public.agents set persona_nome = nullif(btrim(p_persona), ''), updated_at = now() where id = a.id returning * into a;
  end if;
  return a;
end; $$;

-- Prompts: proposta com as métricas do escritório; encerramento com código;
-- Saneador (8º agente). Tudo por replace, para rodar de novo sem duplicar.
update public.agent_prompts p
   set system_prompt = replace(p.system_prompt,
         'E funciona assim: o escritório só cobra {{honorarios}}% do que você ganhar. Se não ganhar, não paga nada. Risco zero pra você. Por exemplo, se ganhar R$ 10 mil, você fica com a maior parte e o escritório com {{honorarios}}%.',
         '{{proposta_honorarios}}'),
       updated_at = now()
  from public.agents a
 where a.id = p.agent_id and a.office_id is null and a.role = 'qualificacao'
   and position('E funciona assim: o escritório só cobra {{honorarios}}%' in p.system_prompt) > 0;

update public.agent_prompts p
   set system_prompt = replace(p.system_prompt,
         'Quer dar esse primeiro passo pra buscar o que é seu?"',
         'Quer dar esse primeiro passo pra buscar o que é seu?"' || chr(10)
         || '- Se a pessoa perguntar se o escritório é confiável ou hesitar: {{prova_social}}'),
       updated_at = now()
  from public.agents a
 where a.id = p.agent_id and a.office_id is null and a.role = 'qualificacao'
   and position('{{prova_social}}' in p.system_prompt) = 0;

update public.agent_prompts p
   set system_prompt = replace(p.system_prompt,
         'Confirmação: com tudo em mãos,',
         'Honorários (se a pessoa perguntar de novo, repita exatamente isto e não fale de nenhum outro custo): {{proposta_honorarios}}' || chr(10) || chr(10)
         || 'Confirmação: com tudo em mãos,'),
       updated_at = now()
  from public.agents a
 where a.id = p.agent_id and a.office_id is null and a.role = 'contrato'
   and position('{{proposta_honorarios}}' in p.system_prompt) = 0;

update public.agent_prompts p
   set system_prompt = replace(p.system_prompt,
         '- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.',
         '- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.' || chr(10)
         || '- Encerrar o caso: só quando a pessoa disser com todas as letras que desistiu (advance_to "encerrado", advance_reason "cliente_desistiu") ou contar que é servidor público estatutário (advance_reason "servidor_publico"). Qualquer outra dúvida sobre viabilidade vira intervention, nunca encerramento.'),
       updated_at = now()
  from public.agents a
 where a.id = p.agent_id and a.office_id is null
   and position('advance_reason "cliente_desistiu"' in p.system_prompt) = 0;

-- Saneador: mesmo cabeçalho dos outros sete + a etapa dele.
update public.agent_prompts p
   set system_prompt = (
         select left(r.system_prompt, position('SUA ETAPA:' in r.system_prompt) - 1)
         from public.agent_prompts r join public.agents ra on ra.id = r.agent_id
         where ra.office_id is null and ra.role = 'recepcao' and position('SUA ETAPA:' in r.system_prompt) > 0
       ) || $p$SUA ETAPA: SANEAMENTO (a peça voltou da revisão)
Objetivo: conseguir com o cliente exatamente o que o revisor pediu para a peça poder seguir. O pedido do revisor está no dossiê: pieces[0].alerta (o que falta), pieces[0].documentos_anexar e a última intervention de saneamento.

Roteiro:
1. Abertura: explique em uma frase que o advogado revisou o caso e precisa de mais uma informação ou documento para entrar com a ação. Diga o que é, sem juridiquês.
2. Peça UM item por vez. Para documento, diga como conseguir (app da CTPS Digital, app do FGTS, banco, RH da empresa) e que pode mandar foto ou PDF aqui mesmo.
3. A cada resposta ou arquivo, confirme ("Recebi, obrigada!") e siga para o próximo item. Dado novo vai em case_data.
4. Se a pessoa não tem como conseguir algo, pergunte uma alternativa (testemunha, print, extrato); se não houver, registre intervention "saneamento_juridico" explicando o que não dá para obter.
5. Quando tudo o que o revisor pediu estiver respondido: advance_to "revisao" (o sistema devolve a peça para o revisor) e diga que o advogado vai conferir e avisa quando protocolar.
Nunca diga que a ação já foi protocolada. Nunca prometa data de protocolo.
$p$,
       updated_at = now()
  from public.agents a
 where a.id = p.agent_id and a.office_id is null and a.role = 'saneamento';

-- Jornada da Láquila: 5 etapas. A assinatura de journey_stages() não muda
-- (ordem, role, titulo, fases); role agora é a chave da etapa. Saneador e
-- Redator dividem a fase peca pela etapa da peça (journey_stage_piece_status).
create or replace function public.journey_stages()
returns table (ordem int, role text, titulo text, fases public.case_phase[])
language sql immutable set search_path = public as $$
  values
    (1, 'closer',        'Closer',        array['novo','triagem','qualificacao','contrato']::public.case_phase[]),
    (2, 'entrevistador', 'Entrevistador', array['briefing','calculo']::public.case_phase[]),
    (3, 'coletor',       'Coletor',       array['provas']::public.case_phase[]),
    (4, 'saneador',      'Saneador',      array['peca']::public.case_phase[]),
    (5, 'redator',       'Redator',       array['peca']::public.case_phase[]);
$$;

create or replace function public.journey_stage_agents(p_stage text)
returns text[] language sql immutable set search_path = public as $$
  select case p_stage
    when 'closer' then array['recepcao','qualificacao','contrato']
    when 'entrevistador' then array['briefing','calculo']
    when 'coletor' then array['provas']
    when 'saneador' then array['saneamento']
    when 'redator' then array['redacao'] end;
$$;

-- Aceita a chave da etapa ou o papel de um agente dela (ex.: 'recepcao' → closer).
create or replace function public.journey_stage_key(p text)
returns text language sql immutable set search_path = public as $$
  select coalesce((select s.role from public.journey_stages() s where s.role = p),
                  (select s.role from public.journey_stages() s where p = any (public.journey_stage_agents(s.role)) order by s.ordem limit 1));
$$;

-- Etapa da jornada em que o lead está agora (null se encerrado).
create or replace function public.lead_journey_stage(p_lead uuid)
returns text language sql stable set search_path = public as $$
  select case
    when l.phase = 'encerrado' then null
    when l.phase = 'peca' then case when (select p.status from public.pieces p where p.lead_id = l.id order by p.created_at desc limit 1) = 'saneamento'
                                    then 'saneador' else 'redator' end
    else (select s.role from public.journey_stages() s where l.phase = any (s.fases) order by s.ordem limit 1) end
  from public.leads l where l.id = p_lead;
$$;

-- O lead chegou à etapa? Saneador: chegou à peça e alguma peça passou por saneamento.
create or replace function public.lead_reached_stage(p_lead uuid, p_stage text)
returns boolean language sql stable set search_path = public as $$
  select case p_stage
    when 'saneador' then public.lead_max_phase_order(p_lead) >= public.phase_order('peca')
                         and (exists (select 1 from public.pieces p where p.lead_id = p_lead and p.status = 'saneamento')
                              or exists (select 1 from public.case_events e where e.lead_id = p_lead
                                           and ((e.type = 'piece_status_changed' and e.payload->>'to' = 'saneamento')
                                             or (e.type = 'piece_created' and e.payload->>'status' = 'saneamento')
                                             or e.type = 'saneamento_concluido')))
    else public.lead_max_phase_order(p_lead) >=
         (select public.phase_order(s.fases[1]) from public.journey_stages() s where s.role = p_stage) end;
$$;

-- Concluiu a etapa? Closer/Entrevistador/Coletor: passou da última fase.
-- Saneador: não tem mais peça em saneamento. Redator: peça protocolada.
create or replace function public.lead_done_stage(p_lead uuid, p_stage text)
returns boolean language sql stable set search_path = public as $$
  select case p_stage
    when 'saneador' then not exists (select 1 from public.pieces p where p.lead_id = p_lead and p.status = 'saneamento')
    when 'redator' then exists (select 1 from public.pieces p where p.lead_id = p_lead and p.status = 'protocolada')
    else public.lead_max_phase_order(p_lead) >
         (select public.phase_order(s.fases[array_length(s.fases, 1)]) from public.journey_stages() s where s.role = p_stage) end;
$$;

create or replace function public.journey_stage_leads_p(p_office uuid, p_from date, p_to date, p_member uuid, p_role text)
returns setof uuid language sql stable set search_path = public as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to))
  select l.id from public.leads l, b
  where l.office_id = p_office and l.created_at >= b.p_start and l.created_at < b.p_end
    and (p_member is null or l.assigned_to = p_member)
    and public.lead_reached_stage(l.id, public.journey_stage_key(p_role));
$$;

create or replace function public.dashboard_jornada_p(p_office uuid, p_from date default null, p_to date default null, p_member uuid default null)
returns jsonb language sql stable set search_path = public as $$
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
        select (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'in') as i,
               (select min(m.created_at) from public.messages m join public.conversations cv on cv.id = m.conversation_id where cv.lead_id = c.id and m.direction = 'out') as o
        from coorte c) t where o is not null and i is not null),
    'dias_ate_contrato', (select round(avg(extract(epoch from (k.signed_at - c.created_at)) / 86400)::numeric, 1)
                          from coorte c join public.contracts k on k.lead_id = c.id and k.status = 'assinado'),
    'mensagens_por_lead', (select round(avg(n)::numeric, 1) from (
        select count(m.id) as n from coorte c
        left join public.conversations cv on cv.lead_id = c.id
        left join public.messages m on m.conversation_id = cv.id group by c.id) t)
  )
  from b
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- 4b/5b/6b. apply_agent_effects: agente por lead, encerramento com código,
-- Saneador devolve a peça para revisão. Mesma assinatura da 013.
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
  v_task uuid; k public.contracts; b public.briefings;
  v_role text;
  v_piece uuid;
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
      -- encerramento pela IA: advance_reason é o código de close_reasons()
      l := public.close_lead_with_reason(p_lead, coalesce(nullif(p_advance_reason, ''), 'outro'), 'outro', null, 'ia', null, v_role);
      v_result := v_result || jsonb_build_object('phase', l.phase, 'closed_kind', l.closed_kind, 'closed_code', l.closed_code);
    elsif p_advance_to = 'revisao' then
      -- Saneador: pendências respondidas, a peça volta para o revisor
      select id into v_piece from public.pieces where lead_id = p_lead and status = 'saneamento' order by created_at desc limit 1;
      if v_piece is not null then
        update public.pieces set status = 'revisao', generated_by_actor = 'ia', updated_at = now() where id = v_piece;
        perform public.log_event(l.office_id, p_lead, 'saneamento_concluido', 'ia', null, v_role,
          jsonb_build_object('piece_id', v_piece, 'reason', p_advance_reason), p_conversation);
        v_result := v_result || jsonb_build_object('piece_id', v_piece, 'piece_status', 'revisao');
      end if;
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
    b := public.upsert_briefing(p_lead, p_briefing, 'ia', null, coalesce(v_role, 'briefing'));
    v_result := v_result || jsonb_build_object('briefing_id', b.id, 'briefing_status', b.status);
  end if;

  return v_result || jsonb_build_object('agent_role', v_role);
end;
$$;

-- -----------------------------------------------------------------------------
-- 7. Marketing: Claude (Anthropic) e OpenAI separados
-- -----------------------------------------------------------------------------
-- Claude = lançado em tokens/tokens_anthropic; sem lançamento no dia, a
-- estimativa pelas mensagens da IA (ai_meta.cost_usd). OpenAI = lançado em
-- tokens_openai (Whisper não é estimado).
create or replace function public.marketing_tokens_split(p_office uuid, p_from date, p_to date)
returns table (dia date, anthropic_brl numeric, openai_brl numeric, tokens_brl numeric, tokens_usd numeric,
               origem_anthropic text, origem_openai text)
language sql stable set search_path = public as $$
  with cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  lanc as (
    select a.dia,
           sum(a.valor) filter (where a.canal in ('tokens','tokens_anthropic')) as ant_brl,
           sum(a.valor_usd) filter (where a.canal in ('tokens','tokens_anthropic')) as ant_usd,
           sum(a.valor) filter (where a.canal = 'tokens_openai') as oai_brl,
           sum(a.valor_usd) filter (where a.canal = 'tokens_openai') as oai_usd
    from public.ad_spend a
    where a.office_id = p_office and public.canal_tipo(a.canal) = 'tokens' and a.dia >= p_from and a.dia <= p_to
    group by a.dia
  ),
  est as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
    from public.messages m
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= p_from::timestamptz and m.created_at < (p_to + 1)::timestamptz
    group by 1
  )
  select d.dia::date,
         coalesce(l.ant_brl, round(coalesce(e.usd, 0) * cambio.v, 2)) as anthropic_brl,
         coalesce(l.oai_brl, 0) as openai_brl,
         coalesce(l.ant_brl, round(coalesce(e.usd, 0) * cambio.v, 2)) + coalesce(l.oai_brl, 0) as tokens_brl,
         coalesce(l.ant_usd, case when l.ant_brl is null then e.usd end, 0) + coalesce(l.oai_usd, 0) as tokens_usd,
         case when l.ant_brl is not null then 'lancado' when e.dia is not null then 'estimado' else 'nenhum' end,
         case when l.oai_brl is not null then 'lancado' else 'nenhum' end
  from generate_series(p_from, p_to, interval '1 day') as d(dia)
  cross join cambio
  left join lanc l on l.dia = d.dia::date
  left join est e on e.dia = d.dia::date;
$$;

-- Mesma assinatura da 009; agora soma Claude + OpenAI.
create or replace function public.marketing_tokens_por_dia(p_office uuid, p_from date, p_to date)
returns table (dia date, tokens_brl numeric, tokens_usd numeric, origem text)
language sql stable set search_path = public as $$
  select s.dia, s.tokens_brl, s.tokens_usd,
         case when s.origem_anthropic = 'lancado' or s.origem_openai = 'lancado' then 'lancado' else s.origem_anthropic end
  from public.marketing_tokens_split(p_office, p_from, p_to) s;
$$;

create or replace view public.v_marketing_dia with (security_invoker = true) as
select v.*,
  coalesce((select sum(a.valor) from public.ad_spend a where a.office_id = v.office_id and a.dia = v.dia and a.canal in ('tokens','tokens_anthropic')), 0) as tokens_anthropic_brl,
  coalesce((select sum(a.valor) from public.ad_spend a where a.office_id = v.office_id and a.dia = v.dia and a.canal = 'tokens_openai'), 0) as tokens_openai_brl
from public.v_marketing_lancamentos v;

create or replace function public.marketing_dia_p(p_office uuid, p_from date default null, p_to date default null)
returns setof public.v_marketing_dia language sql stable set search_path = public as $$
  select v.* from public.v_marketing_dia v, public.period_bounds(p_office, p_from, p_to) b
  where v.office_id = p_office and v.dia >= b.p_start::date and v.dia < b.p_end::date
  order by v.dia desc;
$$;

-- Lançamento manual com Claude e OpenAI. p_tokens_brl continua aceito
-- (conta como Claude). Substitui a versão de 5 parâmetros da 009.
drop function if exists public.marketing_lancar(uuid, date, numeric, numeric, text);
create or replace function public.marketing_lancar(p_office uuid, p_dia date, p_ads_brl numeric default null, p_tokens_brl numeric default null,
                                                   p_nota text default null, p_claude_brl numeric default null, p_openai_brl numeric default null)
returns jsonb language plpgsql set search_path = public as $$
declare
  v_claude numeric := coalesce(p_claude_brl, p_tokens_brl);
begin
  if p_ads_brl is not null then
    insert into public.ad_spend (office_id, dia, canal, valor, nota, origem, created_by, updated_by)
    values (p_office, p_dia, 'meta_ads', p_ads_brl, p_nota, 'manual', auth.uid(), auth.uid())
    on conflict (office_id, dia, canal) do update
      set valor = excluded.valor, nota = coalesce(excluded.nota, public.ad_spend.nota), origem = 'manual', updated_by = auth.uid();
  end if;
  if v_claude is not null then
    delete from public.ad_spend where office_id = p_office and dia = p_dia and canal = 'tokens' and v_claude is not null and p_claude_brl is not null;
    insert into public.ad_spend (office_id, dia, canal, valor, nota, origem, created_by, updated_by)
    values (p_office, p_dia, case when p_claude_brl is not null then 'tokens_anthropic' else 'tokens' end, v_claude, p_nota, 'manual', auth.uid(), auth.uid())
    on conflict (office_id, dia, canal) do update
      set valor = excluded.valor, nota = coalesce(excluded.nota, public.ad_spend.nota), origem = 'manual', updated_by = auth.uid();
  end if;
  if p_openai_brl is not null then
    insert into public.ad_spend (office_id, dia, canal, valor, nota, origem, created_by, updated_by)
    values (p_office, p_dia, 'tokens_openai', p_openai_brl, p_nota, 'manual', auth.uid(), auth.uid())
    on conflict (office_id, dia, canal) do update
      set valor = excluded.valor, nota = coalesce(excluded.nota, public.ad_spend.nota), origem = 'manual', updated_by = auth.uid();
  end if;
  if p_ads_brl is null and v_claude is null and p_openai_brl is null and p_nota is not null then
    update public.ad_spend set nota = p_nota, updated_by = auth.uid() where office_id = p_office and dia = p_dia;
  end if;
  return (select to_jsonb(v) from public.v_marketing_dia v where v.office_id = p_office and v.dia = p_dia);
end; $$;

create or replace function public.marketing_resumo_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb language sql stable set search_path = public as $$
  with b as (select p_start::date as d0, (p_end - interval '1 day')::date as d1 from public.period_bounds(p_office, p_from, p_to)),
  ads as (select coalesce(sum(a.valor), 0) as brl from public.ad_spend a, b
          where a.office_id = p_office and public.canal_tipo(a.canal) = 'ads' and a.dia between b.d0 and b.d1),
  tok as (select coalesce(sum(t.tokens_brl), 0) as brl, coalesce(sum(t.anthropic_brl), 0) as ant, coalesce(sum(t.openai_brl), 0) as oai,
                 count(*) filter (where t.origem_anthropic = 'lancado' or t.origem_openai = 'lancado') as lancados
          from b, public.marketing_tokens_split(p_office, b.d0, b.d1) t),
  leads as (select count(*) as n from public.leads l, b where l.office_id = p_office and l.created_at >= b.d0 and l.created_at < b.d1 + 1),
  ctr as (select count(*) as n from public.contracts k, b where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.d0 and k.signed_at < b.d1 + 1),
  lanc as (select count(*) as n from public.v_marketing_lancamentos v, b where v.office_id = p_office and v.dia between b.d0 and b.d1)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.d0, 'ate', b.d1),
    'ads_brl', round(ads.brl, 2),
    'tokens_brl', round(tok.brl, 2),
    'tokens_anthropic_brl', round(tok.ant, 2),
    'tokens_openai_brl', round(tok.oai, 2),
    'total_brl', round(ads.brl + tok.brl, 2),
    'lancamentos', lanc.n,
    'dias_tokens_lancados', tok.lancados,
    'leads', leads.n,
    'custo_medio_por_lead_brl', case when leads.n = 0 then null else round((ads.brl + tok.brl) / leads.n, 2) end,
    'contratos', ctr.n,
    'custo_por_contrato_brl', case when ctr.n = 0 then null else round((ads.brl + tok.brl) / ctr.n, 2) end
  )
  from b, ads, tok, leads, ctr, lanc
  where public.is_office_member(p_office);
$$;

create or replace function public.dashboard_investimento_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb language sql stable set search_path = public as $$
  with b as (select * from public.period_bounds(p_office, p_from, p_to)),
  cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  dias as (select generate_series(b.p_start, b.p_end - interval '1 day', interval '1 day')::date as dia from b),
  tok as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd,
           coalesce(sum((m.ai_meta->>'tokens_in')::numeric), 0) as tin, coalesce(sum((m.ai_meta->>'tokens_out')::numeric), 0) as tout,
           count(*) as msgs
    from public.messages m, b
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end
    group by 1
  ),
  ads as (
    select a.dia, sum(a.valor) as brl from public.ad_spend a, b
    where a.office_id = p_office and public.canal_tipo(a.canal) = 'ads' and a.dia >= b.p_start::date and a.dia < b.p_end::date group by 1
  ),
  tk as (
    select t.* from b, public.marketing_tokens_split(p_office, b.p_start::date, (b.p_end - interval '1 day')::date) t
  ),
  ctr as (
    select k.signed_at::date as dia, count(*) as n from public.contracts k, b
    where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end group by 1
  ),
  prot as (
    select p.protocolado_em::date as dia, count(*) as n from public.pieces p, b
    where p.office_id = p_office and p.status = 'protocolada' and p.protocolado_em >= b.p_start and p.protocolado_em < b.p_end group by 1
  ),
  linha as (
    select d.dia,
           coalesce(a.brl, 0) as ads_brl,
           coalesce(k.anthropic_brl, 0) as tokens_anthropic_brl,
           coalesce(k.openai_brl, 0) as tokens_openai_brl,
           coalesce(k.tokens_brl, 0) as tokens_brl,
           coalesce(a.brl, 0) + coalesce(k.tokens_brl, 0) as investimento_brl,
           coalesce(c.n, 0) as contratos,
           coalesce(p.n, 0) as protocolos
    from dias d
    left join ads a on a.dia = d.dia
    left join tk k on k.dia = d.dia
    left join ctr c on c.dia = d.dia
    left join prot p on p.dia = d.dia
  ),
  tot as (
    select sum(ads_brl) as ads, sum(tokens_anthropic_brl) as ant, sum(tokens_openai_brl) as oai, sum(tokens_brl) as tokens,
           sum(investimento_brl) as inv, sum(contratos) as contratos, sum(protocolos) as protocolos
    from linha
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'cambio_usd_brl', (select v from cambio),
    'investimento_total_brl', (select round(inv, 2) from tot),
    'ads_brl', (select round(ads, 2) from tot),
    'tokens_brl', (select round(tokens, 2) from tot),
    'tokens_anthropic_brl', (select round(ant, 2) from tot),
    'tokens_openai_brl', (select round(oai, 2) from tot),
    'tokens_usd', (select round(coalesce(sum(tokens_usd), 0), 4) from tk),
    'tokens_estimados_por_mensagens_usd', (select round(coalesce(sum(usd), 0), 4) from tok),
    'tokens_in', (select coalesce(sum(tin), 0) from tok),
    'tokens_out', (select coalesce(sum(tout), 0) from tok),
    'mensagens_ia', (select coalesce(sum(msgs), 0) from tok),
    'contratos_fechados', (select contratos from tot),
    'custo_por_contrato_brl', (select case when contratos = 0 then null else round(inv / contratos, 2) end from tot),
    'protocolos', (select protocolos from tot),
    'custo_por_protocolo_brl', (select case when protocolos = 0 then null else round(inv / protocolos, 2) end from tot),
    'valor_causa_gerado', (select coalesce(sum(valor_causa), 0) from public.contracts k, b
                           where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.p_start and k.signed_at < b.p_end),
    'por_agente', (select coalesce(jsonb_agg(jsonb_build_object('agente', agente, 'mensagens', n, 'custo_usd', round(usd, 4), 'custo_brl', round(usd * (select v from cambio), 2)) order by usd desc), '[]'::jsonb)
                   from (select coalesce(m.ai_meta->>'agent_role', 'desconhecido') as agente, count(*) as n, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
                         from public.messages m, b where m.office_id = p_office and m.sender = 'ia' and m.created_at >= b.p_start and m.created_at < b.p_end group by 1) t),
    'dia_a_dia', (select coalesce(jsonb_agg(jsonb_build_object(
                    'dia', dia, 'ads_brl', ads_brl, 'tokens_anthropic_brl', tokens_anthropic_brl, 'tokens_openai_brl', tokens_openai_brl,
                    'tokens_brl', tokens_brl, 'investimento_brl', investimento_brl,
                    'contratos', contratos, 'custo_por_contrato_brl', case when contratos = 0 then null else round(investimento_brl / contratos, 2) end,
                    'protocolos', protocolos, 'custo_por_protocolo_brl', case when protocolos = 0 then null else round(investimento_brl / protocolos, 2) end
                  ) order by dia desc), '[]'::jsonb) from linha)
  )
  from b
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- 8. Consistência
-- -----------------------------------------------------------------------------
-- Soltar em "Peça" vindo de Saneamento/Revisão leva a peça a rascunho (antes o
-- card voltava para a coluna anterior).
create or replace function public.ui_move_to_column(p_lead uuid, p_coluna text, p_reason text default null)
returns public.leads language plpgsql security definer set search_path = public as $$
declare l public.leads; v_piece uuid; v_status text; v_target public.case_phase;
begin
  if auth.uid() is null then raise exception 'ui_move_to_column exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  v_target := case p_coluna
    when 'closer' then case when public.phase_order(l.phase) <= public.phase_order('contrato') then l.phase else 'qualificacao'::public.case_phase end
    when 'entrevista' then 'briefing' when 'viabilidade' then 'calculo' when 'coleta_docs' then 'provas'
    when 'saneamento' then 'peca' when 'revisao' then 'peca' when 'peca' then 'peca'
    else null end;
  if v_target is null then raise exception 'coluna desconhecida: %', p_coluna; end if;
  if v_target <> l.phase then
    l := public.advance_phase(p_lead, v_target, 'humano', auth.uid(), null, coalesce(p_reason, 'movido para ' || p_coluna));
  end if;
  if p_coluna in ('saneamento','revisao','peca') then
    select id, status into v_piece, v_status from public.pieces where lead_id = p_lead order by created_at desc limit 1;
    if v_piece is null then
      insert into public.pieces (office_id, lead_id, tese, status, generated_by_actor)
      values (l.office_id, p_lead, coalesce(l.tese, 'verbas_rescisorias'), 'rascunho', 'humano') returning id, status into v_piece, v_status;
    end if;
    if p_coluna = 'saneamento' then perform public.ui_set_piece_status(v_piece, 'saneamento');
    elsif p_coluna = 'revisao' then perform public.ui_set_piece_status(v_piece, 'revisao');
    elsif p_coluna = 'peca' and v_status in ('saneamento','revisao','aguardando') then perform public.ui_set_piece_status(v_piece, 'rascunho');
    end if;
  end if;
  return l;
end; $$;

-- Quem reivindica um lead com peça em revisão vira o revisor (pieces.responsavel).
create or replace function public.claim_intervention(p_id uuid)
returns public.human_interventions language plpgsql security definer set search_path = public as $$
declare h public.human_interventions;
begin
  if auth.uid() is null then raise exception 'claim_intervention exige usuário'; end if;
  select * into h from public.human_interventions where id = p_id for update;
  if h.id is null or not public.is_office_member(h.office_id) then raise exception 'intervenção não encontrada'; end if;
  if h.status <> 'pendente' then return h; end if;
  update public.human_interventions set status = 'em_atendimento', claimed_by = auth.uid(), claimed_at = now()
   where id = p_id returning * into h;
  if h.conversation_id is not null then perform public.take_over(h.conversation_id); end if;
  update public.pieces p set responsavel = auth.uid()
   where p.id = (select p2.id from public.pieces p2 where p2.lead_id = h.lead_id order by p2.created_at desc limit 1)
     and p.status in ('revisao','aguardando') and p.responsavel is distinct from auth.uid();
  perform public.log_event(h.office_id, h.lead_id, 'intervention_claimed', 'humano', auth.uid(), null,
    jsonb_build_object('intervention_id', h.id), h.conversation_id);
  return h;
end;
$$;

-- Régua: janela de 24h fechada e nenhum template aprovado para o passo. Antes
-- o n8n pulava e o lead ficava "vencido" para sempre; agora encerra a régua e
-- abre follow_up_esgotado para a equipe.
create or replace function public.followup_no_template(p_lead uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare l public.leads; h public.human_interventions;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  update public.leads set followup_next_at = null where id = p_lead;
  h := public.request_intervention(p_lead,
         (select id from public.conversations where lead_id = p_lead order by last_message_at desc nulls last limit 1),
         'follow_up_esgotado', 'Follow-up parado: janela de 24h fechada e sem template aprovado', 3, 'sistema', null,
         'O passo ' || (l.followup_step + 1) || ' da régua precisa de um template aprovado pela Meta. Cadastre o template em Configurações ou fale com o lead por ligação.',
         array['follow_up','sem_template']);
  return jsonb_build_object('step', l.followup_step + 1, 'exhausted', true, 'reason', 'sem_template', 'intervention_id', h.id);
end; $$;

-- -----------------------------------------------------------------------------
-- 9. Views novas (ver o cabeçalho: as antigas não podem ganhar colunas)
-- -----------------------------------------------------------------------------
create or replace view public.v_clientes with (security_invoker = true) as
select v.*,
  e.etapa, public.etapa_titulo(e.etapa) as etapa_titulo,
  (select x.ordem from public.etapas() x where x.codigo = e.etapa) as etapa_ordem,
  a.role as agente_role, a.name as agente_nome, a.persona_nome as agente_persona,
  public.agent_label(a.name, a.persona_nome) as agente_rotulo,
  d.cargo, l.paused, l.closed_kind, l.closed_code, l.closed_reason, l.closed_note,
  (select count(*) from public.human_interventions h where h.lead_id = v.lead_id and h.status in ('pendente','em_atendimento')) as intervencoes_abertas
from public.v_case_cards v
join public.leads l on l.id = v.lead_id
left join public.case_data d on d.lead_id = v.lead_id
cross join lateral (select public.lead_etapa(v.lead_id) as etapa) e
left join lateral (select * from public.agent_config_lead(v.lead_id)) a on true;

create or replace view public.v_fluxo_cards with (security_invoker = true) as
select w.*,
  e.etapa, public.etapa_titulo(e.etapa) as etapa_titulo,
  a.role as agente_role_lead, a.persona_nome as agente_persona,
  public.agent_label(a.name, a.persona_nome) as agente_rotulo,
  l.closed_code, l.closed_note
from public.v_workflow_cards w
join public.leads l on l.id = w.lead_id
cross join lateral (select public.lead_etapa(w.lead_id) as etapa) e
left join lateral (select * from public.agent_config_lead(w.lead_id)) a on true;

create or replace view public.v_juridico_cards with (security_invoker = true) as
select j.piece_id, j.lead_id, j.office_id, j.status,
  j.etapa as peca_etapa, j.etapa_ordem as peca_etapa_ordem,
  j.tese, j.alerta, j.protocolo, j.protocolado_em, j.responsavel, pr.full_name as responsavel_nome,
  j.assigned_to, j.generated_by_actor, j.reviewed_by, j.stage_changed_at, j.updated_at, j.created_at, j.horas_na_etapa,
  j.phase, j.contact_name, j.contact_phone, j.empresa, j.cargo, j.valor_causa, j.faixa, j.viavel, j.fragil,
  j.em_atendimento, j.intervencao_pendente, j.prescricao_em,
  j.prescricao_em - current_date as prescricao_dias,
  p.qualidade, p.versao, p.docx_url, p.resumo_executivo, p.documentos_anexar, p.aprovada_em,
  e.etapa, public.etapa_titulo(e.etapa) as etapa_titulo,
  a.role as agente_role, a.persona_nome as agente_persona, public.agent_label(a.name, a.persona_nome) as agente_rotulo
from public.v_legal_cards j
join public.pieces p on p.id = j.piece_id
left join public.profiles pr on pr.user_id = j.responsavel
cross join lateral (select public.lead_etapa(j.lead_id) as etapa) e
left join lateral (select * from public.agent_config_lead(j.lead_id)) a on true;

create or replace view public.v_fila_leads with (security_invoker = true) as
select f.*,
  e.etapa, public.etapa_titulo(e.etapa) as etapa_titulo,
  a.role as agente_role, a.persona_nome as agente_persona, public.agent_label(a.name, a.persona_nome) as agente_rotulo
from public.v_intervention_leads f
cross join lateral (select public.lead_etapa(f.lead_id) as etapa) e
left join lateral (select * from public.agent_config_lead(f.lead_id)) a on true;

-- -----------------------------------------------------------------------------
-- 10. Dossiê: bloco escritorio, etapa, agente por lead (com persona), motivos
-- -----------------------------------------------------------------------------
create or replace function public.lead_dossier(p_lead uuid)
returns jsonb language sql stable set search_path = public as $$
  select jsonb_build_object(
    'lead', (select to_jsonb(l) from public.leads l where l.id = p_lead),
    'card', (select to_jsonb(v) from public.v_case_cards v where v.lead_id = p_lead),
    'contact', (select to_jsonb(ct) from public.contacts ct join public.leads l on l.contact_id = ct.id where l.id = p_lead),
    'conversations', (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at), '[]'::jsonb) from public.conversations c where c.lead_id = p_lead),
    'case_data', (select to_jsonb(d) from public.case_data d where d.lead_id = p_lead),
    'qualification', (select to_jsonb(q) from public.lead_qualification q where q.lead_id = p_lead),
    'verbas', public.calc_verbas(p_lead),
    'evidences', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at), '[]'::jsonb) from public.evidences e where e.lead_id = p_lead),
    'contract', (select to_jsonb(k) from public.contracts k where k.lead_id = p_lead and k.status in ('rascunho','enviado','assinado') order by k.created_at desc limit 1),
    'briefing', (select to_jsonb(b) from public.briefings b where b.lead_id = p_lead limit 1),
    'pieces', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb) from public.pieces p where p.lead_id = p_lead),
    'interventions', (select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc), '[]'::jsonb) from public.human_interventions h where h.lead_id = p_lead),
    'tasks', (select coalesce(jsonb_agg(to_jsonb(t) order by t.due_at nulls last), '[]'::jsonb) from public.tasks t where t.lead_id = p_lead),
    'events', (select coalesce(jsonb_agg(
                 to_jsonb(ev) || jsonb_build_object('actor_name',
                   case ev.actor when 'humano' then coalesce(pr.full_name, 'Equipe')
                                 when 'ia' then coalesce(public.agent_label(ag.name, ag.persona_nome), 'IA')
                                 else 'Sistema' end)
                 order by ev.seq desc), '[]'::jsonb)
               from (select * from public.case_events where lead_id = p_lead order by seq desc limit 300) ev
               left join public.profiles pr on pr.user_id = ev.actor_user_id
               left join lateral (select g.name, g.persona_nome from public.agents g
                                   where g.role = ev.actor_agent and (g.office_id = ev.office_id or g.office_id is null)
                                   order by g.office_id nulls last limit 1) ag on true),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'role', m.role, 'full_name', pr.full_name)), '[]'::jsonb)
                from public.office_members m
                left join public.profiles pr on pr.user_id = m.user_id
                where m.office_id = (select office_id from public.leads where id = p_lead)),
    'cost', public.lead_cost(p_lead),
    'office', (select jsonb_build_object('name', o.name, 'whatsapp_comercial', o.whatsapp_comercial, 'whatsapp_juridico', o.whatsapp_juridico,
                                         'telefone_suporte', o.telefone_suporte, 'cidade', o.cidade, 'uf', o.uf, 'site', o.site)
               from public.offices o where o.id = (select office_id from public.leads where id = p_lead)),
    'escritorio', public.office_escritorio((select office_id from public.leads where id = p_lead)),
    'coluna', (select jsonb_build_object('coluna', w.coluna, 'titulo', w.coluna_titulo, 'ordem', w.coluna_ordem, 'fase_titulo', w.fase_titulo)
               from public.v_workflow_cards w where w.lead_id = p_lead),
    'etapa', (select jsonb_build_object('codigo', x.e, 'titulo', public.etapa_titulo(x.e)) from (select public.lead_etapa(p_lead) as e) x),
    'agent', (select jsonb_build_object('role', a.role, 'name', a.name, 'persona_nome', a.persona_nome,
                                        'label', public.agent_label(a.name, a.persona_nome), 'description', a.description)
              from public.agent_config_lead(p_lead) a),
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
                                         'faixas_ticket', p.faixas_ticket, 'vinculo_minimo', p.vinculo_minimo,
                                         'ignorar_tempo_acidente', p.ignorar_tempo_acidente,
                                         'vinculo_minimo_exigido', public.vinculo_minimo_exigido(p.office_id, d.tipo_rescisao, d.ctps_assinada, d.acidente_trabalho),
                                         'honorarios_percent', p.honorarios_percent)
               from public.leads l3 join public.office_params p on p.office_id = l3.office_id
               left join public.case_data d on d.lead_id = l3.id where l3.id = p_lead)
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
grant select on public.v_clientes, public.v_fluxo_cards, public.v_juridico_cards, public.v_fila_leads, public.v_marketing_dia to authenticated;
grant execute on function public.brl(numeric) to authenticated;
grant execute on function public.tipo_saida(text) to authenticated;
grant execute on function public.vinculo_minimo_exigido(uuid, text, boolean, boolean) to authenticated;
grant execute on function public.office_escritorio(uuid) to authenticated;
grant execute on function public.ui_save_empresa(uuid, jsonb, jsonb) to authenticated;
grant execute on function public.close_reasons() to authenticated;
grant execute on function public.ui_close_lead(uuid, text, text, text) to authenticated;
grant execute on function public.ui_reopen_lead(uuid, public.case_phase) to authenticated;
grant execute on function public.etapas() to authenticated;
grant execute on function public.etapa_titulo(text) to authenticated;
grant execute on function public.lead_etapa(uuid) to authenticated;
grant execute on function public.agent_label(text, text) to authenticated;
grant execute on function public.agent_for_lead(uuid) to authenticated;
grant execute on function public.agent_config_role(uuid, text) to authenticated;
grant execute on function public.agent_config_lead(uuid) to authenticated;
grant execute on function public.agent_label_lead(uuid) to authenticated;
grant execute on function public.ui_set_agent_persona(uuid, text, text) to authenticated;
grant execute on function public.journey_stages() to authenticated;
grant execute on function public.journey_stage_agents(text) to authenticated;
grant execute on function public.journey_stage_key(text) to authenticated;
grant execute on function public.lead_journey_stage(uuid) to authenticated;
grant execute on function public.lead_reached_stage(uuid, text) to authenticated;
grant execute on function public.lead_done_stage(uuid, text) to authenticated;
grant execute on function public.marketing_tokens_split(uuid, date, date) to authenticated;
grant execute on function public.marketing_dia_p(uuid, date, date) to authenticated;
grant execute on function public.marketing_lancar(uuid, date, numeric, numeric, text, numeric, numeric) to authenticated;
grant execute on function public.ui_move_to_column(uuid, text, text) to authenticated;
grant execute on function public.claim_intervention(uuid) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;

-- Só o banco/n8n.
revoke execute on function public.close_lead_with_reason(uuid, text, text, text, text, uuid, text) from public, anon, authenticated;
revoke execute on function public.agent_prompt_render(public.agents, uuid) from public, anon, authenticated;
revoke execute on function public.agent_config_full(uuid, public.case_phase) from public, anon, authenticated;
revoke execute on function public.agent_config_full_lead(uuid) from public, anon, authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.followup_no_template(uuid) from public, anon, authenticated;
revoke execute on function public.qualification_gate(uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.advance_phase(uuid, public.case_phase, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.close_lead_with_reason(uuid, text, text, text, text, uuid, text) to service_role;
grant execute on function public.agent_prompt_render(public.agents, uuid) to service_role;
grant execute on function public.agent_config_full(uuid, public.case_phase) to service_role;
grant execute on function public.agent_config_full_lead(uuid) to service_role;
grant execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) to service_role;
grant execute on function public.followup_no_template(uuid) to service_role;
grant execute on function public.qualification_gate(uuid, text, uuid) to service_role;
grant execute on function public.advance_phase(uuid, public.case_phase, text, uuid, text, text, text) to service_role;
