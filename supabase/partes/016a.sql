-- =============================================================================
-- 016a — parte 1 de 2 de supabase/016_placeholders_laquila.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 015 inteira (todas as partes 015*). Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- =============================================================================
-- 016_placeholders_laquila.sql — placeholders dos modelos de petição da Láquila
--
-- Os 47 modelos que o escritório usava na Láquila (8 blocos obrigatórios + 39 teses)
-- entram em piece_templates por um SQL à parte (modelos_laquila.sql, fora do repo:
-- a autoria/licença dos textos ainda será confirmada antes de vender o Edem a outros
-- escritórios). Eles usam 133 placeholders em maiúsculas. Esta migration:
--
-- 1. piece_placeholders: cada placeholder → fonte de dados do Edem, caminho, formato
--    (data dd/mm/aaaa, moeda R$, extenso, texto...). fonte 'ia' = o Redator preenche a
--    partir do briefing; fonte 'manual' = fica [PREENCHER: CODE] para a equipe. Os
--    nomes antigos do Edem (blocos da 013: {{cliente_nome}}, {{admissao}}...) também
--    estão mapeados.
-- 2. piece_fill_context(lead): todas as chaves já formatadas para o lead. Qualquer
--    chave em case_data.extras (ou nas respostas do briefing) com o mesmo nome do
--    placeholder tem prioridade: é como a equipe/IA preenche RG, CID, CNAE etc.
-- 3. piece_fill_text / piece_render / piece_finalize / piece_sanitize: monta os
--    blocos obrigatórios na ordem + as teses escolhidas, substitui os dados, deixa
--    {{IA:CODE}} para o Redator e transforma qualquer sobra em [PREENCHER: CODE].
--    Aceita {{CODE}}, [[CODE]] e [CODE]; "R$ VALOR NUMERICO" e "(POR EXTENSO)"
--    também soltos no texto.
-- 4. piece_generation_fill (n8n 08): monta a peça no banco com os valores que o
--    Redator devolveu e grava em revisão. piece_generation_save passa a sanear o
--    conteúdo: nenhum placeholder cru chega à peça.
--
-- Idempotente. Rodar depois de 015.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Valor por extenso e data por extenso
-- -----------------------------------------------------------------------------
create or replace function public.extenso_centena(n int)
returns text language plpgsql immutable set search_path = public as $$
declare
  u text[] := array['um','dois','três','quatro','cinco','seis','sete','oito','nove','dez','onze','doze','treze',
                    'catorze','quinze','dezesseis','dezessete','dezoito','dezenove'];
  d text[] := array['dez','vinte','trinta','quarenta','cinquenta','sessenta','setenta','oitenta','noventa'];
  c text[] := array['cento','duzentos','trezentos','quatrocentos','quinhentos','seiscentos','setecentos','oitocentos','novecentos'];
  r int; partes text[] := '{}';
begin
  if n <= 0 then return ''; end if;
  if n = 100 then return 'cem'; end if;
  if n >= 100 then partes := array_append(partes, c[n / 100]); end if;
  r := n % 100;
  if r > 0 then
    if r < 20 then partes := array_append(partes, u[r]);
    else partes := array_append(partes, d[r / 10] || case when r % 10 > 0 then ' e ' || u[r % 10] else '' end);
    end if;
  end if;
  return array_to_string(partes, ' e ');
end; $$;

create or replace function public.extenso_inteiro(p bigint)
returns text language plpgsql immutable set search_path = public as $$
declare
  g int[] := array[(p / 1000000000) % 1000, (p / 1000000) % 1000, (p / 1000) % 1000, p % 1000]::int[];
  partes text[] := '{}'; vals int[] := '{}'; s text; i int; n int;
begin
  if p is null then return null; end if;
  if p = 0 then return 'zero'; end if;
  if p >= 1000000000000 then return p::text; end if;
  for i in 1..4 loop
    n := g[i];
    continue when n = 0;
    s := case i
      when 1 then public.extenso_centena(n) || case when n = 1 then ' bilhão' else ' bilhões' end
      when 2 then public.extenso_centena(n) || case when n = 1 then ' milhão' else ' milhões' end
      when 3 then case when n = 1 then 'mil' else public.extenso_centena(n) || ' mil' end
      else public.extenso_centena(n) end;
    partes := array_append(partes, s); vals := array_append(vals, n);
  end loop;
  if cardinality(partes) = 1 then return partes[1]; end if;
  -- "mil e quinhentos", "dois mil e vinte"; senão vírgula: "doze mil, cento e um"
  s := array_to_string(partes[1:cardinality(partes) - 1], ', ');
  n := vals[cardinality(vals)];
  return s || case when n < 100 or n % 100 = 0 then ' e ' else ', ' end || partes[cardinality(partes)];
end; $$;

-- 12101 → "doze mil, cento e um reais"; 2000000 → "dois milhões de reais"; 0,50 → "cinquenta centavos"
create or replace function public.extenso_reais(p numeric)
returns text language plpgsql immutable set search_path = public as $$
declare v_int bigint; v_cent int; s text := '';
begin
  if p is null then return null; end if;
  v_int := trunc(abs(round(p, 2)))::bigint;
  v_cent := round((abs(round(p, 2)) - v_int) * 100)::int;
  if v_int > 0 then
    s := public.extenso_inteiro(v_int)
         || case when v_int % 1000000 = 0 then ' de' else '' end
         || case when v_int = 1 then ' real' else ' reais' end;
  end if;
  if v_cent > 0 then
    s := s || case when s <> '' then ' e ' else '' end || public.extenso_inteiro(v_cent) || case when v_cent = 1 then ' centavo' else ' centavos' end;
  end if;
  return case when s = '' then 'zero real' else s end;
end; $$;

create or replace function public.data_extenso(p date)
returns text language sql immutable set search_path = public as $$
  select case when p is null then null else
    extract(day from p)::int || ' de ' ||
    (array['janeiro','fevereiro','março','abril','maio','junho','julho','agosto','setembro','outubro','novembro','dezembro'])[extract(month from p)::int]
    || ' de ' || extract(year from p)::int end;
$$;

create or replace function public.data_br(p date)
returns text language sql immutable set search_path = public as $$
  select to_char(p, 'DD/MM/YYYY');
$$;

-- -----------------------------------------------------------------------------
-- 2. Catálogo de placeholders (interno: sem policy, como piece_templates)
-- -----------------------------------------------------------------------------
create table if not exists public.piece_placeholders (
  code       text primary key,
  fonte      text not null check (fonte in ('contato','caso','escritorio','qualificacao','calculo','sistema','ia','manual')),
  caminho    text not null,
  formato    text not null check (formato in ('texto','data','moeda','extenso','inteiro','numero','hora')),
  se_vazio   text not null default 'manual' check (se_vazio in ('ia','manual')),
  descricao  text not null,
  laquila    boolean not null default true
);
comment on table public.piece_placeholders is
  'Placeholders dos modelos de petição → fonte no Edem. fonte ia: o Redator preenche; manual: vira [PREENCHER: CODE]; se_vazio: o que fazer quando a fonte de dados não tem valor.';
alter table public.piece_placeholders enable row level security;

insert into public.piece_placeholders (code, fonte, caminho, formato, se_vazio, descricao, laquila) values
  ('NOME_RECLAMANTE', 'contato', 'contacts.name', 'texto', 'manual', 'Nome completo do reclamante', true),
  ('CPF', 'contato', 'contacts.cpf', 'texto', 'manual', 'CPF do reclamante', true),
  ('RG', 'manual', 'case_data.extras.RG', 'texto', 'manual', 'RG do reclamante (não é coletado hoje)', true),
  ('ESTADO_CIVIL', 'contato', 'contacts.estado_civil', 'texto', 'manual', 'Estado civil', true),
  ('NACIONALIDADE', 'contato', 'contacts.nacionalidade', 'texto', 'manual', 'Nacionalidade', true),
  ('DATA_NASCIMENTO', 'contato', 'contacts.nascimento', 'data', 'manual', 'Data de nascimento', true),
  ('ENDERECO_RECLAMANTE', 'contato', 'contacts.endereco + cidade/uf', 'texto', 'manual', 'Endereço do reclamante', true),
  ('CEP_RECLAMANTE', 'contato', 'contacts.cep', 'texto', 'manual', 'CEP do reclamante', true),
  ('NOME_RECLAMADA', 'caso', 'case_data.empresa', 'texto', 'manual', 'Razão social da reclamada', true),
  ('NOME_PRIMEIRA_RECLAMADA', 'caso', 'case_data.empresa', 'texto', 'manual', 'Razão social da primeira reclamada', true),
  ('CNPJ_RECLAMADA', 'caso', 'case_data.empresa_cnpj', 'texto', 'manual', 'CNPJ da reclamada', true),
  ('NUMERO_RECLAMADA', 'manual', 'case_data.extras.NUMERO_RECLAMADA', 'texto', 'manual', 'Número do endereço da reclamada', true),
  ('NUMERO_PRIMEIRA_RECLAMADA', 'manual', 'case_data.extras.NUMERO_PRIMEIRA_RECLAMADA', 'texto', 'manual', 'Número do endereço da primeira reclamada', true),
  ('ENDERECO_RECLAMADA', 'manual', 'case_data.extras.ENDERECO_RECLAMADA', 'texto', 'manual', 'Endereço da reclamada (consulta ao CNPJ)', true),
  ('CNAE_PRINCIPAL_RECLAMADA', 'manual', 'case_data.extras.CNAE_PRINCIPAL_RECLAMADA', 'texto', 'manual', 'CNAE principal da reclamada (cartão CNPJ)', true),
  ('CNAE_ATIVIDADE_REAL', 'manual', 'case_data.extras.CNAE_ATIVIDADE_REAL', 'texto', 'manual', 'CNAE da atividade efetivamente exercida', true),
  ('EMPRESA_GRUPO', 'ia', 'briefing', 'texto', 'manual', 'Empresa do mesmo grupo econômico citada pelo reclamante', true),
  ('CNPJ_EMPRESA_GRUPO', 'manual', 'case_data.extras.CNPJ_EMPRESA_GRUPO', 'texto', 'manual', 'CNPJ da empresa do grupo econômico', true),
  ('LISTA_EMPRESAS_GRUPO', 'ia', 'briefing', 'texto', 'manual', 'Empresas que formam o grupo econômico', true),
  ('DESCRICAO_VINCULO_GRUPO', 'ia', 'briefing', 'texto', 'manual', 'Como as empresas do grupo se relacionam (sócios, direção, atividade)', true),
  ('EMPRESA_REFERENCIA', 'manual', 'case_data.extras.EMPRESA_REFERENCIA', 'texto', 'manual', 'Empresa de referência (paradigma)', true),
  ('NUMERO_PROCESSO_REFERENCIA', 'manual', 'case_data.extras.NUMERO_PROCESSO_REFERENCIA', 'texto', 'manual', 'Número do processo de referência', true),
  ('DATA_ADMISSAO', 'caso', 'case_data.admissao', 'data', 'manual', 'Data de admissão', true),
  ('DATA_DEMISSAO', 'caso', 'case_data.demissao', 'data', 'manual', 'Data da dispensa', true),
  ('DATA_SAIDA', 'caso', 'case_data.demissao', 'data', 'manual', 'Data de saída', true),
  ('DATA_FIM_CONTRATO', 'caso', 'case_data.demissao', 'data', 'manual', 'Data de fim do contrato', true),
  ('DATA_PEDIDO_DEMISSAO', 'caso', 'case_data.demissao (quando pedido de demissão)', 'data', 'manual', 'Data do pedido de demissão', true),
  ('DATA_SAIDA_AVISO', 'sistema', 'case_data.demissao + DIAS_AVISO', 'data', 'manual', 'Data de saída projetada com o aviso prévio', true),
  ('DURACAO_CONTRATO', 'sistema', 'vinculo_meses(admissao, demissao)', 'texto', 'manual', 'Duração do contrato (anos e meses)', true),
  ('FUNCAO', 'caso', 'case_data.cargo', 'texto', 'manual', 'Função', true),
  ('FUNCAO_REGISTRADA', 'caso', 'case_data.cargo', 'texto', 'manual', 'Função registrada na CTPS', true),
  ('FUNCAO_CONTRATADA', 'caso', 'case_data.cargo', 'texto', 'manual', 'Função contratada', true),
  ('FUNCAO_REAL', 'ia', 'briefing', 'texto', 'ia', 'Função efetivamente exercida', true),
  ('FUNCAO_DESCRITA', 'ia', 'briefing', 'texto', 'manual', 'Função descrita pelo reclamante', true),
  ('FUNCAO_ACUMULADA', 'ia', 'briefing', 'texto', 'manual', 'Função acumulada', true),
  ('ATIVIDADE_REAL', 'ia', 'briefing', 'texto', 'manual', 'Atividade efetivamente exercida', true),
  ('ATIVIDADE_FUNCAO_REAL', 'ia', 'briefing', 'texto', 'manual', 'Atividades da função real', true),
  ('CBO_REGISTRADO', 'manual', 'case_data.extras.CBO_REGISTRADO', 'texto', 'manual', 'CBO registrado na CTPS', true),
  ('REGISTRO_CTPS', 'sistema', 'case_data.ctps_assinada', 'texto', 'manual', 'Com ou sem registro em CTPS', true),
  ('SALARIO', 'caso', 'case_data.salario', 'moeda', 'manual', 'Último salário', true),
  ('SALARIO_BASE', 'caso', 'case_data.salario', 'moeda', 'manual', 'Salário-base', true),
  ('SALARIO_EXTENSO', 'caso', 'case_data.salario', 'extenso', 'manual', 'Último salário por extenso', true),
  ('MOTIVO_SAIDA', 'caso', 'case_data.motivo_saida / tipo_rescisao', 'texto', 'manual', 'Forma de saída', true),
  ('DIAS_AVISO', 'sistema', '30 + 3 por ano (máx. 90)', 'inteiro', 'manual', 'Dias de aviso prévio (Lei 12.506/11)', true),
  ('DIAS_SALDO', 'sistema', 'dia da demissão', 'inteiro', 'manual', 'Dias de saldo de salário', true),
  ('AVOS_DECIMO', 'sistema', 'meses do ano com 15+ dias', 'inteiro', 'manual', 'Avos de 13º proporcional', true),
  ('AVOS_FERIAS', 'sistema', 'meses do período aquisitivo', 'inteiro', 'manual', 'Avos de férias proporcionais', true),
  ('ANOS_DECIMO', 'sistema', 'ano da demissão', 'texto', 'manual', 'Ano de referência do 13º', true),
  ('ANOS_FERIAS', 'caso', 'case_data.ferias_vencidas', 'inteiro', 'manual', 'Períodos de férias vencidas', true),
  ('CATEGORIA_DIFERENCIADA', 'ia', 'briefing', 'texto', 'manual', 'Categoria profissional diferenciada', true),
  ('SINDICATO_CORRETO', 'ia', 'briefing', 'texto', 'manual', 'Sindicato da categoria correta', true),
  ('CNPJ_SINDICATO_CORRETO', 'manual', 'case_data.extras.CNPJ_SINDICATO_CORRETO', 'texto', 'manual', 'CNPJ do sindicato correto', true),
  ('SINDICATO_TRCT', 'manual', 'case_data.extras.SINDICATO_TRCT', 'texto', 'manual', 'Sindicato que consta no TRCT', true),
  ('RUBRICA_SUPRIMIDA', 'ia', 'briefing', 'texto', 'manual', 'Rubrica salarial suprimida', true),
  ('TIPO_REDUCAO', 'ia', 'briefing', 'texto', 'manual', 'Tipo de redução salarial', true),
  ('DATA_CESSACAO_PREMIO', 'manual', 'case_data.extras.DATA_CESSACAO_PREMIO', 'data', 'manual', 'Data em que o prêmio deixou de ser pago', true),
  ('MES_ANO_CESSACAO', 'manual', 'case_data.extras.MES_ANO_CESSACAO', 'texto', 'manual', 'Mês/ano em que a parcela deixou de ser paga', true),
  ('DATA_CORTE', 'manual', 'case_data.extras.DATA_CORTE', 'data', 'manual', 'Data de corte', true),
  ('DESCRICAO_PAGAMENTO', 'ia', 'briefing', 'texto', 'manual', 'Como o pagamento era feito (por fora, comissões, prêmios)', true),
  ('DESCRICAO_ESTRUTURA_REAL', 'ia', 'briefing', 'texto', 'manual', 'Estrutura real de trabalho (subordinação, equipe, rotina)', true),
  ('DESCRICAO_SUBORDINACAO', 'ia', 'briefing', 'texto', 'manual', 'Elementos de subordinação', true),
  ('DESCRICAO_ORDENS', 'ia', 'briefing', 'texto', 'manual', 'Quem dava as ordens e como', true),
  ('DESCRICAO_VINCULO_REPRESENTANTE', 'ia', 'briefing', 'texto', 'manual', 'Relação com o representante/intermediário', true),
  ('DESCRICAO_ATIVIDADES_EXTRAS', 'ia', 'briefing', 'texto', 'manual', 'Atividades exercidas além da função', true),
  ('DESCRICAO_FALTAS_GRAVES', 'ia', 'briefing', 'texto', 'manual', 'Faltas graves do empregador (rescisão indireta)', true),
  ('DESCRICAO_FALTAS_QUE_MOTIVARAM', 'ia', 'briefing', 'texto', 'manual', 'Faltas que motivaram a saída', true),
  ('DESCRICAO_FATOS_DANO_MORAL', 'ia', 'briefing', 'texto', 'manual', 'Fatos que fundamentam o dano moral', true),
  ('HORA_ENTRADA', 'ia', 'briefing.dados_vinculo', 'hora', 'manual', 'Horário de entrada', true),
  ('HORA_SAIDA', 'ia', 'briefing.dados_vinculo', 'hora', 'manual', 'Horário de saída', true),
  ('INTERVALO_ALMOCO', 'ia', 'briefing.dados_vinculo', 'texto', 'manual', 'Intervalo para refeição usufruído', true),
  ('INTERVALO_CONCEDIDO', 'ia', 'briefing.dados_vinculo', 'texto', 'manual', 'Intervalo concedido', true),
  ('DIAS_SEMANA', 'ia', 'briefing.dados_vinculo', 'texto', 'manual', 'Dias trabalhados na semana', true),
  ('HORA_INICIO_NOTURNO', 'sistema', 'CLT art. 73 (22h)', 'hora', 'manual', 'Início do horário noturno', true),
  ('DATA_INICIO_PONTO', 'manual', 'case_data.extras.DATA_INICIO_PONTO', 'data', 'manual', 'Início do registro de ponto', true),
  ('DESCRICAO_JORNADA_HABITUAL', 'ia', 'briefing.dados_vinculo', 'texto', 'manual', 'Jornada habitual descrita', true),
  ('DESCRICAO_HE_100', 'ia', 'briefing', 'texto', 'manual', 'Horas extras a 100% (domingos e feriados)', true),
  ('QTD_DOMINGOS_TRABALHADOS', 'ia', 'briefing', 'inteiro', 'manual', 'Domingos trabalhados por mês', true),
  ('QTD_HE_50', 'caso', 'case_data.horas_extras_semanais', 'numero', 'manual', 'Horas extras semanais a 50%', true),
  ('CID', 'manual', 'case_data.extras.CID', 'texto', 'manual', 'CID da doença/lesão', true),
  ('NOME_DOENCA', 'ia', 'briefing', 'texto', 'manual', 'Doença ocupacional', true),
  ('DATA_ACIDENTE', 'manual', 'case_data.extras.DATA_ACIDENTE', 'data', 'manual', 'Data do acidente', true),
  ('DESCRICAO_ACIDENTE', 'ia', 'briefing', 'texto', 'manual', 'Como ocorreu o acidente', true),
  ('DESCRICAO_CONDICOES_TRABALHO_DOENCA', 'ia', 'briefing', 'texto', 'manual', 'Condições de trabalho que causaram a doença', true),
  ('DESCRICAO_SEQUELA_ESTETICA', 'ia', 'briefing', 'texto', 'manual', 'Sequela estética', true),
  ('LISTA_ATESTADOS', 'ia', 'evidences', 'texto', 'manual', 'Atestados e laudos juntados', true),
  ('DATA_FIM_ESTABILIDADE', 'manual', 'case_data.extras.DATA_FIM_ESTABILIDADE', 'data', 'manual', 'Fim da estabilidade', true),
  ('DATA_PARTO', 'manual', 'case_data.extras.DATA_PARTO', 'data', 'manual', 'Data do parto (ou prevista)', true),
  ('PRAZO_PENSIONAMENTO', 'ia', 'briefing', 'texto', 'manual', 'Prazo do pensionamento', true),
  ('PERCENTUAL_PENOSIDADE', 'manual', 'case_data.extras.PERCENTUAL_PENOSIDADE', 'texto', 'manual', 'Percentual do adicional de penosidade', true),
  ('VALOR_SALDO', 'calculo', 'qualificacao "saldo" / calc_verbas.saldo_salario', 'moeda', 'manual', 'Saldo de salário', true),
  ('VALOR_AVISO', 'calculo', 'qualificacao "aviso" / calc_verbas.aviso_previo', 'moeda', 'manual', 'Aviso prévio indenizado', true),
  ('VALOR_DECIMO', 'calculo', 'qualificacao "13" / calc_verbas.decimo_terceiro', 'moeda', 'manual', '13º proporcional', true),
  ('VALOR_FERIAS', 'calculo', 'qualificacao "férias" / calc_verbas.ferias', 'moeda', 'manual', 'Férias + 1/3', true),
  ('VALOR_FGTS', 'calculo', 'qualificacao "fgts" / calc_verbas.fgts + multa', 'moeda', 'manual', 'FGTS e multa de 40%', true),
  ('VALOR_HE', 'calculo', 'qualificacao "horas extras" / calc_verbas.horas_extras', 'moeda', 'manual', 'Horas extras', true),
  ('VALOR_HE_50', 'calculo', 'qualificacao "horas extras" / calc_verbas.horas_extras', 'moeda', 'manual', 'Horas extras a 50%', true),
  ('VALOR_HE_100', 'qualificacao', 'qualification_records.verbas "100%"', 'moeda', 'ia', 'Horas extras a 100%', true),
  ('VALOR_INTRAJORNADA', 'qualificacao', 'qualification_records.verbas "intrajornada"', 'moeda', 'ia', 'Intervalo intrajornada', true),
  ('VALOR_INTERJORNADA', 'qualificacao', 'qualification_records.verbas "interjornada"', 'moeda', 'ia', 'Intervalo interjornada', true),
  ('VALOR_DIFERENCA_SALARIAL', 'qualificacao', 'qualification_records.verbas "diferença salarial"', 'moeda', 'ia', 'Diferenças salariais', true),
  ('VALOR_DANO_MORAL', 'qualificacao', 'qualification_records.verbas "moral"', 'moeda', 'ia', 'Indenização por dano moral', true),
  ('VALOR_DANOS_MORAIS', 'qualificacao', 'qualification_records.verbas "moral"', 'moeda', 'ia', 'Indenização por danos morais', true),
  ('VALOR_DANOS_ESTETICOS', 'qualificacao', 'qualification_records.verbas "estético"', 'moeda', 'ia', 'Indenização por danos estéticos', true),
  ('VALOR_PENSIONAMENTO', 'qualificacao', 'qualification_records.verbas "pension"', 'moeda', 'ia', 'Pensionamento', true),
  ('VALOR_SEGURO_DESEMPREGO', 'qualificacao', 'qualification_records.verbas "seguro-desemprego"', 'moeda', 'ia', 'Indenização do seguro-desemprego', true),
  ('VALOR_MULTA_477', 'sistema', 'um salário (art. 477, § 8º)', 'moeda', 'manual', 'Multa do art. 477', true),
  ('VALOR_MULTA_467', 'sistema', '50% das verbas rescisórias (art. 467)', 'moeda', 'manual', 'Multa do art. 467', true),
  ('VALOR_MEDIA_SUPRIMIDA', 'ia', 'qualificacao/briefing', 'moeda', 'manual', 'Média mensal da parcela suprimida', true),
  ('VALOR_MEDIA_SUPRIMIDA_EXTENSO', 'ia', 'qualificacao/briefing', 'extenso', 'manual', 'Média suprimida por extenso', true),
  ('VALOR_MEDIO_PREMIO_1', 'ia', 'briefing', 'moeda', 'manual', 'Valor médio do prêmio (período 1)', true),
  ('VALOR_MEDIO_PREMIO_2', 'ia', 'briefing', 'moeda', 'manual', 'Valor médio do prêmio (período 2)', true),
  ('VALOR_MEDIO_PREMIO_PRESUMIDO', 'ia', 'briefing', 'moeda', 'manual', 'Valor médio presumido do prêmio', true),
  ('VALOR_MEDIO_TRANSPORTADO', 'ia', 'briefing', 'moeda', 'manual', 'Valor médio transportado (caminhoneiro)', true),
  ('DIFERENCA_MENSAL', 'ia', 'qualificacao/briefing', 'moeda', 'manual', 'Diferença mensal', true),
  ('MULTIPLICADOR', 'ia', 'qualificacao', 'texto', 'manual', 'Multiplicador usado no cálculo', true),
  ('REFLEXO_13_HE50', 'qualificacao', 'qualification_records.verbas "horas extras".reflexos.decimo_terceiro', 'moeda', 'ia', 'Reflexo das horas extras em 13º', true),
  ('REFLEXO_13', 'ia', 'qualification_records.verbas[*].reflexos.decimo_terceiro', 'moeda', 'manual', 'Reflexo em 13º da verba principal da tese', true),
  ('REFLEXO_477_HE50', 'qualificacao', 'qualification_records.verbas "horas extras".reflexos.multa_477', 'moeda', 'ia', 'Reflexo das horas extras em multa do art. 477', true),
  ('REFLEXO_477', 'ia', 'qualification_records.verbas[*].reflexos.multa_477', 'moeda', 'manual', 'Reflexo em multa do art. 477 da verba principal da tese', true),
  ('REFLEXO_AVISO_HE50', 'qualificacao', 'qualification_records.verbas "horas extras".reflexos.aviso_previo', 'moeda', 'ia', 'Reflexo das horas extras em aviso prévio', true),
  ('REFLEXO_AVISO', 'ia', 'qualification_records.verbas[*].reflexos.aviso_previo', 'moeda', 'manual', 'Reflexo em aviso prévio da verba principal da tese', true),
  ('REFLEXO_DSR_HE50', 'qualificacao', 'qualification_records.verbas "horas extras".reflexos.dsr', 'moeda', 'ia', 'Reflexo das horas extras em DSR', true),
  ('REFLEXO_DSR', 'ia', 'qualification_records.verbas[*].reflexos.dsr', 'moeda', 'manual', 'Reflexo em DSR da verba principal da tese', true),
  ('REFLEXO_FERIAS_HE50', 'qualificacao', 'qualification_records.verbas "horas extras".reflexos.ferias_terco', 'moeda', 'ia', 'Reflexo das horas extras em férias + 1/3', true),
  ('REFLEXO_FERIAS', 'ia', 'qualification_records.verbas[*].reflexos.ferias_terco', 'moeda', 'manual', 'Reflexo em férias + 1/3 da verba principal da tese', true),
  ('REFLEXO_FGTS_HE50', 'qualificacao', 'qualification_records.verbas "horas extras".reflexos.fgts', 'moeda', 'ia', 'Reflexo das horas extras em FGTS', true),
  ('REFLEXO_FGTS', 'ia', 'qualification_records.verbas[*].reflexos.fgts', 'moeda', 'manual', 'Reflexo em FGTS da verba principal da tese', true),
  ('VALOR_CAUSA', 'qualificacao', 'qualification_records.data.total / contracts.valor_causa', 'moeda', 'manual', 'Valor da causa', true),
  ('VALOR_CAUSA_EXTENSO', 'qualificacao', 'qualification_records.data.total', 'extenso', 'manual', 'Valor da causa por extenso', true),
  ('R$ VALOR NUMERICO', 'qualificacao', 'qualification_records.data.total', 'moeda', 'manual', 'Valor da causa (R$)', true),
  ('(POR EXTENSO)', 'qualificacao', 'qualification_records.data.total', 'extenso', 'manual', 'Valor da causa por extenso, entre parênteses', true),
  ('COMARCA', 'sistema', 'case_data.extras.COMARCA / contacts.cidade/uf', 'texto', 'manual', 'Comarca (cidade/UF)', true),
  ('EMAIL_ESCRITORIO', 'escritorio', 'offices.email', 'texto', 'manual', 'E-mail do escritório', true),
  ('cidade', 'sistema', 'comarca', 'texto', 'manual', 'Comarca', false),
  ('cliente_nome', 'contato', 'contacts.name', 'texto', 'manual', 'Nome do cliente', false),
  ('cliente_cpf', 'contato', 'contacts.cpf', 'texto', 'manual', 'CPF', false),
  ('cliente_nacionalidade', 'contato', 'contacts.nacionalidade', 'texto', 'manual', 'Nacionalidade', false),
  ('cliente_estado_civil', 'contato', 'contacts.estado_civil', 'texto', 'manual', 'Estado civil', false),
  ('cliente_endereco', 'contato', 'contacts.endereco', 'texto', 'manual', 'Endereço', false),
  ('cliente_email', 'contato', 'contacts.email', 'texto', 'manual', 'E-mail do cliente', false),
  ('cliente_telefone', 'contato', 'contacts.wa_id', 'texto', 'manual', 'Telefone do cliente', false),
  ('empresa', 'caso', 'case_data.empresa', 'texto', 'manual', 'Reclamada', false),
  ('empresa_cnpj', 'caso', 'case_data.empresa_cnpj', 'texto', 'manual', 'CNPJ da reclamada', false),
  ('cargo', 'caso', 'case_data.cargo', 'texto', 'manual', 'Cargo', false),
  ('admissao', 'caso', 'case_data.admissao', 'data', 'manual', 'Admissão', false),
  ('demissao', 'caso', 'case_data.demissao', 'data', 'manual', 'Demissão', false),
  ('salario', 'caso', 'case_data.salario', 'moeda', 'manual', 'Salário', false),
  ('tipo_rescisao', 'caso', 'case_data.tipo_rescisao', 'texto', 'manual', 'Forma de saída', false),
  ('valor_causa', 'qualificacao', 'qualification_records.data.total', 'moeda', 'manual', 'Valor da causa', false),
  ('data_extenso', 'sistema', 'data de hoje', 'texto', 'manual', 'Data de hoje por extenso', false),
  ('escritorio_oab', 'escritorio', 'offices.oab_responsavel', 'texto', 'manual', 'OAB do responsável', false)
on conflict (code) do update
  set fonte = excluded.fonte, caminho = excluded.caminho, formato = excluded.formato,
      se_vazio = excluded.se_vazio, descricao = excluded.descricao, laquila = excluded.laquila;

-- -----------------------------------------------------------------------------
-- 3. Contexto de preenchimento do lead
-- -----------------------------------------------------------------------------
-- Verba da qualificação detalhada (qualification_records.data.verbas) pelo nome.
create or replace function public.piece_qual_verba(p_data jsonb, p_like text, p_not_like text default null)
returns jsonb language sql immutable set search_path = public as $$
  select v from jsonb_array_elements(coalesce(p_data->'verbas', '[]'::jsonb)) v
  where lower(coalesce(v->>'verba', '') || ' ' || coalesce(v->>'descricao', '')) like p_like
    and (p_not_like is null or lower(coalesce(v->>'verba', '')) not like p_not_like)
  limit 1;
$$;

create or replace function public.piece_verba_total(v jsonb)
returns numeric language sql immutable set search_path = public as $$
  select case when v is null then null
    else coalesce(public.to_num(v->>'total'), public.to_num(v->>'valor_calculado') - coalesce(public.to_num(v->>'ja_recebido'), 0)) end;
$$;

-- ---------- Verificação da parte 016a: deve voltar uma linha com resultado = OK
select '016a' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função data_br', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'data_br')),
    ('função data_extenso', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'data_extenso')),
    ('função extenso_centena', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'extenso_centena')),
    ('função extenso_inteiro', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'extenso_inteiro')),
    ('função extenso_reais', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'extenso_reais')),
    ('função piece_qual_verba', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_qual_verba')),
    ('função piece_verba_total', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_verba_total')),
    ('tabela piece_placeholders', to_regclass('public.piece_placeholders') is not null)
) as v(item, ok);
