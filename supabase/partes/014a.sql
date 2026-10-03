-- =============================================================================
-- 014a — parte 1 de 5 de supabase/014_paridade_regras.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 013. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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
    v_motivos := array_append(v_motivos, 'dados_insuficientes');
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

-- ---------- Verificação da parte 014a: deve voltar uma linha com resultado = OK
select '014a' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função brl', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'brl')),
    ('função close_reasons', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'close_reasons')),
    ('função office_escritorio', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'office_escritorio')),
    ('função qualification_gate', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'qualification_gate')),
    ('função tipo_saida', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'tipo_saida')),
    ('função ui_save_empresa', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_save_empresa')),
    ('função vinculo_minimo_exigido', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'vinculo_minimo_exigido')),
    ('coluna office_params.ignorar_tempo_acidente', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'office_params' and column_name = 'ignorar_tempo_acidente')),
    ('coluna offices.exemplo_honorarios', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'exemplo_honorarios')),
    ('coluna offices.volume_processos', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'volume_processos')),
    ('coluna offices.clientes_representados', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'clientes_representados')),
    ('coluna offices.video_institucional_url', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'video_institucional_url')),
    ('coluna offices.plataforma_reviews', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'plataforma_reviews')),
    ('coluna offices.avaliacoes_5_estrelas', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'avaliacoes_5_estrelas')),
    ('coluna offices.cobra_taxa_manutencao', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'cobra_taxa_manutencao')),
    ('coluna offices.taxa_manutencao_valor', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'taxa_manutencao_valor')),
    ('coluna offices.taxa_manutencao_periodicidade', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'taxa_manutencao_periodicidade')),
    ('coluna offices.taxa_manutencao_obs', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'offices' and column_name = 'taxa_manutencao_obs')),
    ('coluna leads.closed_code', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'leads' and column_name = 'closed_code')),
    ('coluna leads.closed_note', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'leads' and column_name = 'closed_note')),
    ('coluna office_params.vinculo_minimo', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'office_params' and column_name = 'vinculo_minimo'))
) as v(item, ok);
