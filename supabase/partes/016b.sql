-- =============================================================================
-- 016b — parte 2 de 2 de supabase/016_placeholders_laquila.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 016a. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- Formata um valor vindo de case_data.extras / briefing / Redator conforme o formato do placeholder.
create or replace function public.piece_format(p_val text, p_formato text)
returns text language sql immutable set search_path = public as $$
  select case
    when nullif(btrim(p_val), '') is null then null
    when p_formato = 'data' and p_val ~ '^\d{4}-\d{2}-\d{2}' then public.data_br(left(p_val, 10)::date)
    when p_formato = 'moeda' and p_val !~ 'R\$' and public.to_num(p_val) is not null and p_val ~ '^[\s\d.,-]+$' then public.brl(public.to_num(p_val))
    when p_formato = 'extenso' and p_val ~ '^[R$\s\d.,]+$' and public.to_num(p_val) is not null then public.extenso_reais(public.to_num(p_val))
    else btrim(p_val) end;
$$;

-- Todas as chaves de piece_placeholders, já formatadas para o lead (null = sem dado).
-- Prioridade: case_data.extras[CODE] > briefing (answers, dados_vinculo, dados_pessoais)[CODE] > fonte de dados.
create or replace function public.piece_fill_context(p_lead uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  l public.leads; d public.case_data; ct public.contacts; o public.offices; b public.briefings;
  k public.contracts; lq public.lead_qualification;
  q jsonb; cv jsonb; it jsonb; v_he jsonb; raw jsonb; out jsonb := '{}'::jsonb; r record; v text;
  v_causa numeric; v_meses int; v_aviso int; v_avos13 int; v_tipo text; v_comarca text;
  saldo numeric; aviso numeric; decimo numeric; ferias numeric; fgts numeric; he numeric;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  select * into d from public.case_data where lead_id = p_lead;
  select * into ct from public.contacts where id = l.contact_id;
  select * into o from public.offices where id = l.office_id;
  select * into b from public.briefings where lead_id = p_lead limit 1;
  select * into k from public.contracts where lead_id = p_lead and status in ('assinado','enviado','rascunho')
   order by (status = 'assinado') desc, created_at desc limit 1;
  select * into lq from public.lead_qualification where lead_id = p_lead;
  select data into q from public.qualification_records where lead_id = p_lead order by versao desc limit 1;
  cv := public.calc_verbas(p_lead);
  it := coalesce(cv->'itens', '{}'::jsonb);

  v_causa := coalesce(public.to_num(q->>'total'), k.valor_causa, lq.verbas_total,
                      case when (cv->>'calculado')::boolean then (cv->>'total')::numeric end);
  v_meses := public.vinculo_meses(d.admissao, d.demissao);
  v_aviso := case when d.admissao is not null then least(30 + 3 * (v_meses / 12), 90) end;
  if d.demissao is not null then
    v_avos13 := extract(month from d.demissao)::int - case when extract(day from d.demissao) >= 15 then 0 else 1 end;
    if d.admissao is not null and extract(year from d.admissao) = extract(year from d.demissao) then
      v_avos13 := v_avos13 - (extract(month from d.admissao)::int - 1);
    end if;
    v_avos13 := greatest(v_avos13, 0);
  end if;
  v_tipo := case d.tipo_rescisao
    when 'sem_justa_causa' then 'dispensa sem justa causa' when 'justa_causa' then 'dispensa por justa causa'
    when 'pedido_demissao' then 'pedido de demissão' when 'rescisao_indireta' then 'rescisão indireta'
    when 'acordo' then 'rescisão por acordo (art. 484-A da CLT)' when 'termino_contrato' then 'término do contrato'
    when 'sem_registro' then 'encerramento do vínculo sem registro' when 'ainda_empregado' then 'contrato em curso' end;
  v_comarca := nullif(concat_ws('/', coalesce(ct.cidade, o.cidade), coalesce(ct.uf, o.uf)), '');

  v_he   := public.piece_qual_verba(q, '%hora%extra%', '%100%');
  saldo  := coalesce(public.piece_verba_total(public.piece_qual_verba(q, '%saldo%')), nullif((it->>'saldo_salario')::numeric, 0));
  aviso  := coalesce(public.piece_verba_total(public.piece_qual_verba(q, '%aviso%')), nullif((it->>'aviso_previo')::numeric, 0));
  decimo := coalesce(public.piece_verba_total(public.piece_qual_verba(q, '%13%')), nullif((it->>'decimo_terceiro')::numeric, 0));
  ferias := coalesce(public.piece_verba_total(public.piece_qual_verba(q, '%f_rias%')),
                     nullif(coalesce((it->>'ferias_proporcionais')::numeric, 0) + coalesce((it->>'ferias_vencidas')::numeric, 0), 0));
  fgts   := coalesce(public.piece_verba_total(public.piece_qual_verba(q, '%fgts%')),
                     nullif(coalesce((it->>'fgts_nao_depositado')::numeric, 0) + coalesce((it->>'multa_fgts_40')::numeric, 0), 0));
  he     := coalesce(public.piece_verba_total(v_he), nullif((it->>'horas_extras')::numeric, 0));

  raw := jsonb_build_object(
    'NOME_RECLAMANTE', ct.name, 'CPF', ct.cpf, 'ESTADO_CIVIL', ct.estado_civil, 'NACIONALIDADE', ct.nacionalidade,
    'DATA_NASCIMENTO', public.data_br(ct.nascimento),
    'ENDERECO_RECLAMANTE', nullif(concat_ws(', ', ct.endereco, nullif(concat_ws('/', ct.cidade, ct.uf), '')), ''),
    'CEP_RECLAMANTE', ct.cep,
    'NOME_RECLAMADA', d.empresa, 'NOME_PRIMEIRA_RECLAMADA', d.empresa, 'CNPJ_RECLAMADA', d.empresa_cnpj,
    'DATA_ADMISSAO', public.data_br(d.admissao), 'DATA_DEMISSAO', public.data_br(d.demissao),
    'DATA_SAIDA', public.data_br(d.demissao), 'DATA_FIM_CONTRATO', public.data_br(d.demissao),
    'DATA_PEDIDO_DEMISSAO', case when d.tipo_rescisao = 'pedido_demissao' then public.data_br(d.demissao) end,
    'DATA_SAIDA_AVISO', case when d.demissao is not null and v_aviso is not null then public.data_br(d.demissao + v_aviso) end,
    'DURACAO_CONTRATO', case when v_meses is not null then nullif(concat_ws(' e ',
        case when v_meses / 12 = 1 then '1 ano' when v_meses / 12 > 1 then (v_meses / 12) || ' anos' end,
        case when v_meses % 12 = 1 then '1 mês' when v_meses % 12 > 1 then (v_meses % 12) || ' meses' end), '') end,
    'FUNCAO', d.cargo, 'FUNCAO_REGISTRADA', d.cargo, 'FUNCAO_CONTRATADA', d.cargo,
    'REGISTRO_CTPS', case d.ctps_assinada when true then 'com registro em CTPS' when false then 'sem registro em CTPS' end,
    'SALARIO', public.brl(d.salario), 'SALARIO_BASE', public.brl(d.salario), 'SALARIO_EXTENSO', public.extenso_reais(d.salario),
    'MOTIVO_SAIDA', coalesce(nullif(btrim(d.motivo_saida), ''), v_tipo)
  ) || jsonb_build_object(
    'DIAS_AVISO', v_aviso::text, 'DIAS_SALDO', extract(day from d.demissao)::int::text,
    'AVOS_DECIMO', v_avos13::text, 'AVOS_FERIAS', case when d.demissao is not null then (v_meses % 12)::text end,
    'ANOS_DECIMO', extract(year from d.demissao)::int::text,
    'ANOS_FERIAS', case when d.ferias_vencidas > 0 then d.ferias_vencidas::text end,
    'QTD_HE_50', case when d.horas_extras_semanais > 0 then trim_scale(d.horas_extras_semanais)::text end,
    'HORA_INICIO_NOTURNO', '22h',
    'VALOR_SALDO', public.brl(saldo), 'VALOR_AVISO', public.brl(aviso), 'VALOR_DECIMO', public.brl(decimo),
    'VALOR_FERIAS', public.brl(ferias), 'VALOR_FGTS', public.brl(fgts), 'VALOR_HE', public.brl(he), 'VALOR_HE_50', public.brl(he),
    'VALOR_HE_100', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%100%'))),
    'VALOR_INTRAJORNADA', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%intrajornada%'))),
    'VALOR_INTERJORNADA', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%interjornada%'))),
    'VALOR_DIFERENCA_SALARIAL', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%diferen%salari%'))),
    'VALOR_DANO_MORAL', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%moral%'))),
    'VALOR_DANOS_MORAIS', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%moral%'))),
    'VALOR_DANOS_ESTETICOS', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%est_tic%'))),
    'VALOR_PENSIONAMENTO', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%pension%'))),
    'VALOR_SEGURO_DESEMPREGO', public.brl(public.piece_verba_total(public.piece_qual_verba(q, '%seguro%desemprego%'))),
    'VALOR_MULTA_477', case when d.demissao is not null then public.brl(d.salario) end,
    'VALOR_MULTA_467', public.brl(nullif(round(0.5 * (coalesce(saldo, 0) + coalesce(aviso, 0) + coalesce(decimo, 0) + coalesce(ferias, 0)), 2), 0))
  ) || jsonb_build_object(
    'REFLEXO_13_HE50', public.brl(public.to_num(v_he->'reflexos'->>'decimo_terceiro')),
    'REFLEXO_477_HE50', public.brl(public.to_num(v_he->'reflexos'->>'multa_477')),
    'REFLEXO_AVISO_HE50', public.brl(public.to_num(v_he->'reflexos'->>'aviso_previo')),
    'REFLEXO_DSR_HE50', public.brl(public.to_num(v_he->'reflexos'->>'dsr')),
    'REFLEXO_FERIAS_HE50', public.brl(public.to_num(v_he->'reflexos'->>'ferias_terco')),
    'REFLEXO_FGTS_HE50', public.brl(public.to_num(v_he->'reflexos'->>'fgts')),
    'VALOR_CAUSA', public.brl(v_causa), 'VALOR_CAUSA_EXTENSO', public.extenso_reais(v_causa),
    'R$ VALOR NUMERICO', public.brl(v_causa), '(POR EXTENSO)', public.extenso_reais(v_causa),
    'COMARCA', v_comarca, 'EMAIL_ESCRITORIO', o.email,
    -- nomes antigos do Edem (blocos da 013)
    'cidade', v_comarca, 'cliente_nome', ct.name, 'cliente_cpf', ct.cpf, 'cliente_nacionalidade', ct.nacionalidade,
    'cliente_estado_civil', ct.estado_civil, 'cliente_endereco', ct.endereco, 'cliente_email', ct.email, 'cliente_telefone', ct.wa_id,
    'empresa', d.empresa, 'empresa_cnpj', d.empresa_cnpj, 'cargo', d.cargo, 'admissao', public.data_br(d.admissao),
    'demissao', public.data_br(d.demissao), 'salario', public.brl(d.salario), 'tipo_rescisao', v_tipo,
    'valor_causa', public.brl(v_causa), 'data_extenso', public.data_extenso(current_date), 'escritorio_oab', o.oab_responsavel
  );

  for r in select p.code, p.formato from public.piece_placeholders p loop
    v := coalesce(public.piece_format(d.extras->>r.code, r.formato),
                  public.piece_format(b.answers->>r.code, r.formato),
                  public.piece_format(b.dados_vinculo->>r.code, r.formato),
                  public.piece_format(b.dados_pessoais->>r.code, r.formato),
                  nullif(btrim(raw->>r.code), ''));
    out := out || jsonb_build_object(r.code, v);
  end loop;
  return out;
end; $$;

-- -----------------------------------------------------------------------------
-- 4. Substituição, montagem e saneamento
-- -----------------------------------------------------------------------------
create or replace function public.piece_re_escape(p text)
returns text language sql immutable set search_path = public as $$
  select regexp_replace(p, '([.^$|?*+(){}\[\]\\])', '\\\1', 'g');
$$;

-- Troca os placeholders conhecidos: dado → valor formatado; sem dado e fonte/se_vazio 'ia'
-- → {{IA:CODE}} (o Redator preenche); senão → [PREENCHER: CODE].
create or replace function public.piece_fill_text(p_text text, p_ctx jsonb)
returns text language plpgsql stable set search_path = public as $$
declare s text := coalesce(p_text, ''); r record; e text; v text; rep text;
begin
  for r in select p.code, p.fonte, p.se_vazio from public.piece_placeholders p order by length(p.code) desc, p.code loop
    if position(r.code in s) = 0 then continue; end if;
    e := public.piece_re_escape(r.code);
    v := nullif(btrim(p_ctx->>r.code), '');
    rep := coalesce(v, case when r.fonte = 'ia' or r.se_vazio = 'ia' then '{{IA:' || r.code || '}}' else '[PREENCHER: ' || r.code || ']' end);
    s := regexp_replace(s, '\{\{\s*' || e || '\s*\}\}|\[\[\s*' || e || '\s*\]\]|\[\s*' || e || '\s*\]', replace(rep, '\', '\\'), 'g');
    if r.code ~ '[^A-Za-z0-9_]' then
      -- "R$ VALOR NUMERICO" e "(POR EXTENSO)" aparecem soltos no texto
      rep := case when v is null then rep when r.code like '(%)' then '(' || v || ')' else v end;
      s := regexp_replace(s, '(?<!PREENCHER: )(?<!IA:)' || e, replace(rep, '\', '\\'), 'g');
    end if;
  end loop;
  return s;
end; $$;

-- Nenhum placeholder cru sai daqui: o que sobrar vira [PREENCHER: NOME].
create or replace function public.piece_sanitize(p_text text)
returns text language plpgsql stable set search_path = public as $$
declare s text := coalesce(p_text, ''); r record;
begin
  s := regexp_replace(s, '\{\{\s*IA:\s*([^{}]+?)\s*\}\}', '[PREENCHER: \1]', 'g');
  s := regexp_replace(s, '\{\{\s*([^{}]+?)\s*\}\}', '[PREENCHER: \1]', 'g');
  s := regexp_replace(s, '\[\[\s*([^\[\]]+?)\s*\]\]', '[PREENCHER: \1]', 'g');
  s := regexp_replace(s, '\[([A-Z][A-Z0-9]*_[A-Z0-9_]+)\]', '[PREENCHER: \1]', 'g');
  for r in select p.code from public.piece_placeholders p where p.code ~ '[^A-Za-z0-9_]' loop
    s := regexp_replace(s, '(?<!PREENCHER: )' || public.piece_re_escape(r.code), '[PREENCHER: ' || replace(r.code, '\', '\\') || ']', 'g');
  end loop;
  return s;
end; $$;

-- Valores que o Redator devolveu para os {{IA:CODE}}; o que ele não souber vira [PREENCHER: CODE].
create or replace function public.piece_finalize(p_text text, p_valores jsonb)
returns text language plpgsql stable set search_path = public as $$
declare s text := coalesce(p_text, ''); m record; v text;
begin
  for m in select distinct x[1] as code from regexp_matches(s, '\{\{IA:([^{}]+)\}\}', 'g') x loop
    v := public.piece_format(coalesce(p_valores, '{}'::jsonb)->>m.code,
                             coalesce((select p.formato from public.piece_placeholders p where p.code = m.code), 'texto'));
    s := replace(s, '{{IA:' || m.code || '}}', coalesce(v, '[PREENCHER: ' || m.code || ']'));
  end loop;
  return public.piece_sanitize(s);
end; $$;

-- Tese do briefing (minúsculas, nomes do Edem) → códigos dos modelos.
create or replace function public.piece_tese_codes(p_teses text[])
returns text[] language sql immutable set search_path = public as $$
  select coalesce(array_agg(distinct c), '{}') from (
    select upper(u.tt) as c from unnest(coalesce(p_teses, '{}')) as u(tt)
    union all
    select a.c from unnest(coalesce(p_teses, '{}')) as u(tt)
    join (values ('vinculo_empregaticio','VINCULO'), ('reconhecimento_vinculo','VINCULO'), ('dano_moral','DANOS_MORAIS'),
                 ('danos_morais','DANOS_MORAIS'), ('dano_estetico','DANOS_ESTETICOS'), ('desvio_funcao','ACUMULO_FUNCAO'),
                 ('acumulo_de_funcao','ACUMULO_FUNCAO'), ('estabilidade_gestante','GESTANTE_DEMITIDA'), ('gestante','GESTANTE_DEMITIDA'),
                 ('acidente_de_trabalho','ACIDENTE_TIPICO'), ('acidente_trabalho','ACIDENTE_TIPICO'), ('doenca_ocupacional','DOENCA_OCUPACIONAL_SEM_NTEP'),
                 ('verbas_rescisorias','MULTAS_467_477'), ('intervalo','INTERVALO_INTRAJORNADA'), ('interjornada','INTERVALO_INTERJORNADA'),
                 ('adicional_noturno','ADICIONAL_NOTURNO'), ('equiparacao_salarial','DIFERENCA_SALARIAL'), ('diferenca_salarial','DIFERENCA_SALARIAL'),
                 ('fgts_nao_depositado','DEPOSITOS_FGTS_AFASTAMENTO'), ('grupo_economico','GRUPO_ECONOMICO'), ('seguro_desemprego','SEGURO_DESEMPREGO'),
                 ('domingos_feriados','DSR_DOMINGOS_FERIADOS'), ('pedido_demissao_nulo','NULIDADE_PEDIDO_DEMISSAO'), ('jornada_12x36','NULIDADE_12X36'))
         as a(t, c) on a.t = lower(u.tt)
  ) z where c is not null;
$$;

-- Monta a peça: blocos obrigatórios na ordem; as teses escolhidas entram antes da
-- abertura dos pedidos (ou antes do último bloco). Esqueletos antigos com
-- {{cabecalho}} (pedem redação livre) ficam de fora.
create or replace function public.piece_render(p_piece uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  pc public.pieces; v_teses text[]; v_codes text[]; v_texto text; v_ctx jsonb; v_out text;
  v_blocos text[]; v_tpl_teses text[];
begin
  select * into pc from public.pieces where id = p_piece;
  if pc.id is null then raise exception 'peça % não existe', p_piece; end if;
  select array(select distinct x from unnest(coalesce(b.teses, '{}') || array[pc.tese]) x where x is not null)
    into v_teses from (select 1) z left join public.briefings b on b.lead_id = pc.lead_id;
  v_codes := public.piece_tese_codes(v_teses);

  with tpl as (
    select t.kind, t.code, t.ordem, t.body from (
      select distinct on (pt.code) pt.* from public.piece_templates pt
      where pt.active and (pt.office_id = pc.office_id or pt.office_id is null) and pt.code is not null
      order by pt.code, pt.office_id nulls last) t
    where (t.kind = 'bloco' and t.required)
       or (t.kind = 'tese' and upper(t.code) = any (v_codes) and t.body not like '%{{cabecalho}}%')
  ), corte as (
    select coalesce((select ordem from tpl where kind = 'bloco' and code = 'ABERTURA_PEDIDOS'),
                    (select max(ordem) from tpl where kind = 'bloco')) as v
  ), x as (
    select tpl.*, case when kind = 'tese' then 2 when corte.v is null or ordem < corte.v then 1 else 3 end as grupo from tpl, corte
  )
  select string_agg(body, E'\n\n' order by grupo, ordem, code),
         array_agg(code order by grupo, ordem, code) filter (where kind = 'bloco'),
         array_agg(code order by grupo, ordem, code) filter (where kind = 'tese')
    into v_texto, v_blocos, v_tpl_teses
  from x;

  v_ctx := public.piece_fill_context(pc.lead_id);
  v_out := public.piece_fill_text(v_texto, v_ctx);
  return jsonb_build_object(
    'piece_id', pc.id, 'lead_id', pc.lead_id,
    'texto', v_out,
    'blocos', to_jsonb(coalesce(v_blocos, '{}')), 'teses', to_jsonb(coalesce(v_tpl_teses, '{}')), 'teses_pedidas', to_jsonb(v_teses),
    'ia', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'descricao', p.descricao, 'formato', p.formato) order by m.code), '[]'::jsonb)
             from (select distinct x[1] as code from regexp_matches(v_out, '\{\{IA:([^{}]+)\}\}', 'g') x) m
             left join public.piece_placeholders p on p.code = m.code),
    'manual', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'descricao', p.descricao) order by m.code), '[]'::jsonb)
                 from (select distinct x[1] as code from regexp_matches(v_out, '\[PREENCHER: ([^\]]+)\]', 'g') x) m
                 left join public.piece_placeholders p on p.code = m.code));
end; $$;

-- -----------------------------------------------------------------------------
-- 5. Gravação da peça (n8n 08)
-- -----------------------------------------------------------------------------
-- Mesma assinatura da 015; agora saneia: nenhum placeholder cru chega à peça.
create or replace function public.piece_generation_save(p_piece uuid, p_content text, p_resumo_executivo text default null,
                                                        p_documentos_anexar jsonb default '[]'::jsonb, p_qualidade text default null,
                                                        p_ai_meta jsonb default null)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare pc public.pieces; v_content text := public.piece_sanitize(p_content);
begin
  if coalesce(btrim(v_content), '') = '' then raise exception 'conteúdo vazio'; end if;
  update public.pieces
     set content = v_content,
         resumo_executivo = coalesce(p_resumo_executivo, resumo_executivo),
         documentos_anexar = case when jsonb_typeof(p_documentos_anexar) = 'array' then p_documentos_anexar else documentos_anexar end,
         qualidade = case when p_qualidade in ('viavel','fragil') then p_qualidade else qualidade end,
         generated_by_actor = 'ia', status = 'revisao', geracao_status = 'gerada', geracao_erro = null
   where id = p_piece returning * into pc;
  if pc.id is null then raise exception 'peça % não existe', p_piece; end if;
  perform public.log_event(pc.office_id, pc.lead_id, 'piece_generated', 'ia', null, 'redacao',
    jsonb_build_object('piece_id', pc.id, 'tese', pc.tese, 'versao', pc.versao, 'qualidade', pc.qualidade,
                       'caracteres', length(v_content),
                       'pendencias', (select count(distinct x[1]) from regexp_matches(v_content, '\[PREENCHER: ([^\]]+)\]', 'g') x),
                       'ai_meta', p_ai_meta));
  return pc;
end; $$;

-- O n8n 08 manda só os valores dos {{IA:CODE}}; o banco monta, preenche, saneia e grava.
-- O texto da peça não passa pelo n8n.
create or replace function public.piece_generation_fill(p_piece uuid, p_valores jsonb default '{}'::jsonb, p_resumo_executivo text default null,
                                                        p_documentos_anexar jsonb default '[]'::jsonb, p_qualidade text default null,
                                                        p_ai_meta jsonb default null)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare r jsonb; v_content text;
begin
  r := public.piece_render(p_piece);
  if coalesce(btrim(r->>'texto'), '') = '' then
    raise exception 'nenhum modelo de petição ativo para esta peça (blocos obrigatórios ou teses): carregue os modelos';
  end if;
  v_content := public.piece_finalize(r->>'texto', coalesce(p_valores, '{}'::jsonb));
  return public.piece_generation_save(p_piece, v_content, p_resumo_executivo, p_documentos_anexar, p_qualidade,
    coalesce(p_ai_meta, '{}'::jsonb) || jsonb_build_object('blocos', r->'blocos', 'teses', r->'teses'));
end; $$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------
grant execute on function public.extenso_centena(int) to authenticated;
grant execute on function public.extenso_inteiro(bigint) to authenticated;
grant execute on function public.extenso_reais(numeric) to authenticated;
grant execute on function public.data_extenso(date) to authenticated;
grant execute on function public.data_br(date) to authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.piece_fill_context(uuid)', 'public.piece_render(uuid)',
    'public.piece_fill_text(text, jsonb)', 'public.piece_sanitize(text)', 'public.piece_finalize(text, jsonb)',
    'public.piece_qual_verba(jsonb, text, text)', 'public.piece_verba_total(jsonb)', 'public.piece_format(text, text)',
    'public.piece_re_escape(text)', 'public.piece_tese_codes(text[])',
    'public.piece_generation_save(uuid, text, text, jsonb, text, jsonb)',
    'public.piece_generation_fill(uuid, jsonb, text, jsonb, text, jsonb)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
revoke all on public.piece_placeholders from anon, authenticated;
grant select on public.piece_placeholders to service_role;

-- ---------- Verificação da parte 016b: deve voltar uma linha com resultado = OK
select '016b' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função piece_fill_context', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_fill_context')),
    ('função piece_fill_text', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_fill_text')),
    ('função piece_finalize', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_finalize')),
    ('função piece_format', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_format')),
    ('função piece_generation_fill', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_generation_fill')),
    ('função piece_generation_save', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_generation_save')),
    ('função piece_re_escape', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_re_escape')),
    ('função piece_render', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_render')),
    ('função piece_sanitize', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_sanitize')),
    ('função piece_tese_codes', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_tese_codes'))
) as v(item, ok);
