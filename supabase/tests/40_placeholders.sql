-- Placeholders dos modelos de petição (016). Modelos de teste com texto inventado no formato
-- da Láquila (os modelos reais não ficam no repositório). Tudo desfeito no fim.

\set ON_ERROR_STOP on
set client_min_messages = warning;
begin;

insert into auth.users (id, email, raw_user_meta_data) values ('66666666-6666-6666-6666-666666666666', 'fia@escritorio-f.test', '{"full_name":"Fia F"}');
insert into public.offices (id, name, slug, email, cidade, uf, oab_responsavel)
values ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'Escritório F', 'f', 'contato@f.adv.br', 'Campinas', 'SP', 'OAB/SP 1');
insert into public.office_members (office_id, user_id, role) values ('ffffffff-ffff-ffff-ffff-ffffffffffff', '66666666-6666-6666-6666-666666666666', 'admin');
insert into public.whatsapp_numbers (office_id, phone_number_id, display_phone, token_secret_name) values ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'PNID-F', '5519900000000', 'wa_f');

-- Modelos de teste: substituem os blocos da 013 (mesmos códigos) só dentro desta transação.
delete from public.piece_templates where office_id is null and kind = 'bloco';
insert into public.piece_templates (office_id, tese, name, body, kind, code, required, ordem, active) values
  (null, 'CABECALHO', 'Cabeçalho', 'EXMO. JUÍZO DA VARA DO TRABALHO DE [COMARCA]. [NOME_RECLAMANTE], [NACIONALIDADE], [ESTADO_CIVIL], CPF [CPF], RG [RG], vem propor ação contra [NOME_RECLAMADA].', 'bloco', 'CABECALHO', true, 1, true),
  (null, 'SINTESE_CONTRATO', 'Síntese', 'Admitido em {{DATA_ADMISSAO}} como {{FUNCAO_REGISTRADA}}, salário de {{SALARIO}} ({{SALARIO_EXTENSO}}), saída em [[DATA_SAIDA]] ({{MOTIVO_SAIDA}}), aviso de [DIAS_AVISO] dias até [DATA_SAIDA_AVISO].', 'bloco', 'SINTESE_CONTRATO', true, 2, true),
  (null, 'ABERTURA_PEDIDOS', 'Pedidos', 'DOS PEDIDOS', 'bloco', 'ABERTURA_PEDIDOS', true, 3, true),
  (null, 'FECHAMENTO_PEDIDOS', 'Fechamento', 'Dá-se à causa o valor de R$ VALOR NUMERICO (POR EXTENSO). Valor por extenso: [VALOR_CAUSA_EXTENSO]. Contato: [EMAIL_ESCRITORIO]. [CAMPO_DESCONHECIDO] e {{outro_campo}}.', 'bloco', 'FECHAMENTO_PEDIDOS', true, 9, true),
  (null, 'HORAS_EXTRAS', 'Horas extras', 'DAS HORAS EXTRAS. Jornada das [HORA_ENTRADA] às [HORA_SAIDA], {{QTD_HE_50}} horas extras semanais. Função real: [FUNCAO_REAL]. CID [CID].', 'tese', 'HORAS_EXTRAS', false, 100, true),
  (null, 'DANOS_MORAIS', 'Danos morais', 'DOS DANOS MORAIS. [DESCRICAO_FATOS_DANO_MORAL]', 'tese', 'DANOS_MORAIS', false, 100, true),
  (null, 'ACIDENTE_TIPICO', 'Acidente', 'NÃO DEVE ENTRAR', 'tese', 'ACIDENTE_TIPICO', false, 100, true)
on conflict (coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), code) do update
  set body = excluded.body, kind = excluded.kind, required = excluded.required, ordem = excluded.ordem, active = true, tese = excluded.tese;

do $$
declare f uuid := 'ffffffff-ffff-ffff-ffff-ffffffffffff'; v uuid; c jsonb; r jsonb; t text; pc public.pieces; n int;
begin
  v := (public.ingest_inbound('PNID-F', '5519955551234', 'Maria da Silva', 'wamid.f1', 'oi')->>'lead_id')::uuid;
  update public.contacts set cpf = '020.383.999-48', nacionalidade = 'brasileira', estado_civil = 'solteira', cidade = 'Campinas', uf = 'SP'
   where id = (select contact_id from public.leads where id = v);
  insert into public.case_data (lead_id, office_id, empresa, cargo, admissao, demissao, salario, tipo_rescisao, aviso_previo, ctps_assinada,
                                fgts_depositado, horas_extras_semanais, extras)
  values (v, f, 'Transportes Z Ltda', 'Motorista', '2021-03-01', '2025-02-10', 3200, 'sem_justa_causa', 'indenizado', true, true, 10.5,
          '{"COMARCA": "Campinas/SP", "DATA_ACIDENTE": "2024-06-15"}');
  insert into public.briefings (office_id, lead_id, status, teses) values (f, v, 'concluido', array['horas_extras','dano_moral']);
  insert into public.qualification_records (lead_id, office_id, versao, data)
  values (v, f, 1, '{"total": 12101, "verbas": [{"verba": "Horas extras", "total": 9000, "reflexos": {"dsr": 1500, "fgts": 720}}, {"verba": "Saldo de salário", "total": 1066.67}]}');

  -- contexto: todas as chaves, já formatadas
  c := public.piece_fill_context(v);
  assert (select count(*) from jsonb_object_keys(c)) = (select count(*) from public.piece_placeholders), 'todas as chaves presentes';
  assert (select count(*) from public.piece_placeholders where laquila) = 133, 'os 133 placeholders da Láquila';
  assert c->>'DATA_ADMISSAO' = '01/03/2021' and c->>'DATA_DEMISSAO' = '10/02/2025', 'data dd/mm/aaaa: ' || coalesce(c->>'DATA_ADMISSAO', 'null');
  assert c->>'SALARIO' = 'R$ 3.200,00', 'moeda: ' || coalesce(c->>'SALARIO', 'null');
  assert c->>'SALARIO_EXTENSO' = 'três mil e duzentos reais', 'extenso: ' || coalesce(c->>'SALARIO_EXTENSO', 'null');
  assert c->>'VALOR_CAUSA' = 'R$ 12.101,00' and c->>'R$ VALOR NUMERICO' = 'R$ 12.101,00', 'valor da causa vem da qualificação';
  assert c->>'VALOR_CAUSA_EXTENSO' = 'doze mil, cento e um reais' and c->>'(POR EXTENSO)' = 'doze mil, cento e um reais', 'valor da causa por extenso';
  assert c->>'VALOR_HE_50' = 'R$ 9.000,00' and c->>'REFLEXO_DSR_HE50' = 'R$ 1.500,00' and c->>'VALOR_SALDO' = 'R$ 1.066,67', 'valores da qualificação';
  assert c->>'DIAS_AVISO' = '39' and c->>'DATA_SAIDA_AVISO' = '21/03/2025' and c->>'DURACAO_CONTRATO' = '3 anos e 11 meses', 'aviso e duração calculados';
  assert c->>'QTD_HE_50' = '10.5' and c->>'REGISTRO_CTPS' = 'com registro em CTPS' and c->>'MOTIVO_SAIDA' = 'dispensa sem justa causa', 'texto';
  assert c->>'DATA_ACIDENTE' = '15/06/2024', 'case_data.extras preenche e formata';
  assert c->>'RG' is null and c->>'FUNCAO_REAL' is null, 'sem dado = null';
  assert public.extenso_reais(1500000) = 'um milhão e quinhentos mil reais' and public.extenso_reais(2000000) = 'dois milhões de reais'
     and public.extenso_reais(0.5) = 'cinquenta centavos' and public.extenso_reais(1001.01) = 'mil e um reais e um centavo', 'extenso: casos de borda';

  -- substituição: [X], {{X}}, [[X]] e os dois códigos soltos
  t := public.piece_fill_text('[DATA_ADMISSAO] {{SALARIO}} [[SALARIO_EXTENSO]] { { nada } } R$ VALOR NUMERICO (POR EXTENSO) [RG] {{ FUNCAO_REAL }}', c);
  assert t = '01/03/2021 R$ 3.200,00 três mil e duzentos reais { { nada } } R$ 12.101,00 (doze mil, cento e um reais) [PREENCHER: RG] {{IA:FUNCAO_REAL}}', 'fill_text: ' || t;
  assert public.piece_sanitize('a {{IA:X}} b {{foo}} c [[bar]] d [CAMPO_X] e [OK] f R$ VALOR NUMERICO') =
         'a [PREENCHER: X] b [PREENCHER: foo] c [PREENCHER: bar] d [PREENCHER: CAMPO_X] e [OK] f [PREENCHER: R$ VALOR NUMERICO]', 'sanitize';

  -- peça montada: blocos na ordem + teses do briefing antes dos pedidos; acidente não pedido fica de fora
  insert into public.pieces (office_id, lead_id, tese, status, generated_by_actor, geracao_status) values (f, v, 'horas_extras', 'rascunho', 'ia', 'pendente') returning * into pc;
  r := public.piece_render(pc.id);
  assert r->'blocos' = '["CABECALHO","SINTESE_CONTRATO","ABERTURA_PEDIDOS","FECHAMENTO_PEDIDOS"]'::jsonb, 'blocos na ordem: ' || (r->'blocos')::text;
  assert r->'teses' = '["DANOS_MORAIS","HORAS_EXTRAS"]'::jsonb, 'teses do briefing (dano_moral → DANOS_MORAIS): ' || (r->'teses')::text;
  assert position('DAS HORAS EXTRAS' in r->>'texto') between position('Admitido em' in r->>'texto') and position('DOS PEDIDOS' in r->>'texto'), 'teses antes dos pedidos';
  assert position('NÃO DEVE ENTRAR' in r->>'texto') = 0, 'tese não pedida fica de fora';
  assert (select array_agg(x->>'code' order by x->>'code') from jsonb_array_elements(r->'ia') x) = array['DESCRICAO_FATOS_DANO_MORAL','FUNCAO_REAL','HORA_ENTRADA','HORA_SAIDA'], 'só os de IA vão para o Redator: ' || (r->'ia')::text;
  assert (select array_agg(x->>'code' order by x->>'code') from jsonb_array_elements(r->'manual') x) = array['CID','RG'], 'manuais pendentes: ' || (r->'manual')::text;

  -- Redator devolve parte dos valores; o resto vira [PREENCHER]; nada cru na peça final
  perform set_config('request.jwt.claim.sub', '', false);   -- como o n8n
  pc := public.piece_generation_fill(pc.id, '{"HORA_ENTRADA": "7h", "HORA_SAIDA": "19h", "DESCRICAO_FATOS_DANO_MORAL": "Humilhações públicas do gerente."}',
                                     'Resumo de teste', '["CTPS"]', 'viavel', '{"tokens_out": 100}');
  assert pc.status = 'revisao' and pc.geracao_status = 'gerada', 'peça em revisão';
  assert pc.content like '%Jornada das 7h às 19h, 10.5 horas extras semanais.%' and pc.content like '%Humilhações públicas do gerente.%', 'valores do Redator entram';
  assert pc.content like '%Função real: [PREENCHER: FUNCAO_REAL]%' and pc.content like '%RG [PREENCHER: RG]%' and pc.content like '%CID [PREENCHER: CID]%', 'sem dado vira [PREENCHER: ...]';
  assert pc.content like '%Dá-se à causa o valor de R$ 12.101,00 (doze mil, cento e um reais).%', 'valor numérico e por extenso';
  assert pc.content like '%Admitido em 01/03/2021 como Motorista, salário de R$ 3.200,00 (três mil e duzentos reais), saída em 10/02/2025%', 'data, moeda e extenso no texto';
  assert pc.content like '%[PREENCHER: CAMPO_DESCONHECIDO] e [PREENCHER: outro_campo]%', 'placeholder desconhecido também vira [PREENCHER]';
  assert pc.content !~ '\{\{|\}\}|\[\[|\]\]' and pc.content !~ '\[[A-Z][A-Z0-9]*_[A-Z0-9_]+\]', 'nenhum placeholder cru: ' || pc.content;
  assert (select (payload->>'pendencias')::int from public.case_events where lead_id = v and type = 'piece_generated' order by seq desc limit 1) = 5, 'pendências contadas no evento';
  -- o save direto (n8n antigo) também saneia
  pc := public.piece_generation_save(pc.id, 'Texto com {{IA:X}} e [DATA_Y]');
  assert pc.content = 'Texto com [PREENCHER: X] e [PREENCHER: DATA_Y]', 'save saneia: ' || pc.content;
  perform set_config('request.jwt.claim.sub', '66666666-6666-6666-6666-666666666666', false);
end $$;

-- privilégios: o catálogo e as funções com dados são internos
set role authenticated;
set request.jwt.claim.sub = '66666666-6666-6666-6666-666666666666';
do $$ begin
  assert not has_function_privilege('authenticated', 'public.piece_fill_context(uuid)', 'execute'), 'contexto só n8n';
  assert not has_function_privilege('authenticated', 'public.piece_generation_fill(uuid, jsonb, text, jsonb, text, jsonb)', 'execute'), 'gravação só n8n';
  assert not has_table_privilege('authenticated', 'public.piece_placeholders', 'select'), 'catálogo invisível';
  assert public.extenso_reais(12101) = 'doze mil, cento e um reais', 'extenso disponível para o front';
end $$;
reset role; reset request.jwt.claim.sub;

rollback;
\echo PLACEHOLDERS OK
