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
