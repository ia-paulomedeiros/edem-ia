-- =============================================================================
-- seed_demo.sql — dados de demonstração para ver o dashboard e o kanban cheios
--
-- Gera ~60 leads no mês corrente para o PRIMEIRO escritório cadastrado, com
-- conversas, mensagens (com ai_meta), dados do caso, qualificação, contratos
-- assinados espalhados pelos dias, UFs variadas e alguns encerrados.
-- Tudo marcado com wa_id começando em '5500' para poder apagar depois.
--
-- Rodar no SQL Editor depois de 001..010. Pode rodar mais de uma vez (apaga
-- e recria o demo). Para remover: rode só o bloco "LIMPEZA".
-- =============================================================================

-- ---------- LIMPEZA (apaga só o que é demo)
delete from public.leads where contact_id in (select id from public.contacts where wa_id like '5500%');
delete from public.contacts where wa_id like '5500%';
delete from public.ad_spend where canal = 'meta_ads' and nota is null and office_id = (select id from public.offices order by created_at limit 1);
delete from public.piece_models where file_path like '%/demo/%';
delete from public.integrations where config->>'demo' = 'true';

-- ---------- GERAÇÃO
do $$
declare
  v_office uuid;
  v_number uuid;
  v_member uuid;
  v_contact uuid; v_lead uuid; v_conv uuid;
  i int;
  v_dia date;
  v_uf text;
  v_nome text;
  v_salario numeric;
  v_fase public.case_phase;
  v_etapa text; v_hora time; v_task_dia date;
  v_ufs text[] := array['SP','SP','SP','SP','SP','RJ','RJ','BA','BA','PR','PR','ES','MG','PE','RS'];
  v_nomes text[] := array['Ana','Bruno','Carla','Diego','Elaine','Fábio','Gisele','Henrique','Isabela','João','Karina','Leandro','Marina','Nelson','Olívia','Paulo','Renata','Sérgio','Tatiane','Vinícius'];
  v_sobren text[] := array['Silva','Souza','Oliveira','Santos','Pereira','Lima','Costa','Ferreira','Almeida','Rocha'];
  v_fases public.case_phase[] := array['triagem','qualificacao','provas','calculo','contrato','briefing','peca'];
  v_inicio date := date_trunc('month', current_date)::date;
  v_fim date := least(current_date, (date_trunc('month', current_date) + interval '1 month - 1 day')::date);
begin
  select id into v_office from public.offices order by created_at limit 1;
  if v_office is null then raise exception 'cadastre um escritório antes'; end if;
  select id into v_number from public.whatsapp_numbers where office_id = v_office limit 1;
  if v_number is null then raise exception 'cadastre um whatsapp_number antes'; end if;
  select user_id into v_member from public.office_members where office_id = v_office limit 1;

  for i in 1..60 loop
    v_dia := v_inicio + ((random() * (v_fim - v_inicio))::int);
    v_uf := v_ufs[1 + (random() * (array_length(v_ufs, 1) - 1))::int];
    v_nome := v_nomes[1 + (random() * 19)::int] || ' ' || v_sobren[1 + (random() * 9)::int];
    v_salario := 1500 + (random() * 6000)::int;

    insert into public.contacts (office_id, wa_id, name, uf)
    values (v_office, '5500' || lpad(i::text, 9, '0'), v_nome, v_uf) returning id into v_contact;

    insert into public.leads (office_id, contact_id, source, assigned_to, created_at, phase)
    values (v_office, v_contact, 'whatsapp', case when random() < 0.6 then v_member else null end, v_dia + time '09:00' + (random() * interval '10 hours'), 'novo')
    returning id into v_lead;

    insert into public.conversations (office_id, lead_id, contact_id, whatsapp_number_id, last_message_at, last_message_preview, unread_count)
    values (v_office, v_lead, v_contact, v_number, v_dia + time '10:00', 'Olá, preciso de ajuda com a minha demissão', (random() * 3)::int)
    returning id into v_conv;

    -- mensagens: lead escreve, IA responde com ai_meta (custo), às vezes humano assume
    insert into public.messages (office_id, conversation_id, direction, sender, body, status, created_at)
    values (v_office, v_conv, 'in', 'contact', 'Olá, fui demitido e não recebi tudo', 'received', v_dia + time '09:30');
    insert into public.messages (office_id, conversation_id, direction, sender, body, status, ai_meta, created_at)
    values (v_office, v_conv, 'out', 'ia', 'Sinto muito. Vou te ajudar: em que empresa você trabalhava e quando foi a demissão?', 'read',
            jsonb_build_object('agent_role', 'recepcao', 'model', 'claude-sonnet-5', 'tokens_in', 800 + (random()*400)::int, 'tokens_out', 120 + (random()*80)::int, 'cost_usd', round((0.004 + random() * 0.006)::numeric, 5)),
            v_dia + time '09:31');
    insert into public.messages (office_id, conversation_id, direction, sender, body, status, ai_meta, created_at)
    values (v_office, v_conv, 'out', 'ia', 'Certo. Qual era o seu salário e você tinha carteira assinada?', 'read',
            jsonb_build_object('agent_role', 'qualificacao', 'model', 'claude-sonnet-5', 'tokens_in', 1200 + (random()*400)::int, 'tokens_out', 90 + (random()*60)::int, 'cost_usd', round((0.005 + random() * 0.006)::numeric, 5)),
            v_dia + time '09:40');
    -- ~78% respondem de novo (entram na "taxa de abertura": régua de 2+ mensagens)
    if random() < 0.78 then
      insert into public.messages (office_id, conversation_id, direction, sender, body, status, created_at)
      values (v_office, v_conv, 'in', 'contact', 'Trabalhei na Empresa uns 3 anos, salário de ' || v_salario::int || ', com carteira', 'received', v_dia + time '09:45');
    end if;
    if v_member is not null and random() < 0.3 then
      insert into public.messages (office_id, conversation_id, direction, sender, body, status, sent_by, created_at)
      values (v_office, v_conv, 'out', 'humano', 'Oi, aqui é do escritório. Vou continuar seu atendimento.', 'read', v_member, v_dia + time '11:00');
    end if;

    -- dados do caso e qualificação
    insert into public.case_data (lead_id, office_id, empresa, cargo, admissao, demissao, salario, tipo_rescisao, aviso_previo, fgts_depositado, horas_extras_semanais, updated_by_actor)
    values (v_lead, v_office, 'Empresa ' || chr(65 + (random()*25)::int) || ' Ltda', 'Operador', v_dia - ((365 + random() * 1500)::int), v_dia - ((10 + random() * 300)::int),
            v_salario, (array['sem_justa_causa','sem_justa_causa','sem_justa_causa','pedido_demissao','rescisao_indireta'])[1 + (random()*4)::int],
            'indenizado', random() < 0.7, (random() * 10)::int, 'ia');
    perform public.qualification_gate(v_lead, 'ia');

    -- fase: distribui pelo funil; ~40% viram contrato assinado
    if random() < 0.12 then
      perform public.advance_phase(v_lead, 'encerrado', 'ia', null, 'qualificacao', 'fora do escopo');
    else
      v_fase := v_fases[1 + (random() * 6)::int];
      perform public.advance_phase(v_lead, v_fase, 'ia', null, public.agent_for_phase(v_fase), 'demo');
      if random() < 0.45 then
        insert into public.contracts (office_id, lead_id, status, honorarios_percent, created_at)
        values (v_office, v_lead, 'rascunho', 30, v_dia + time '12:00');
        update public.contracts set status = 'enviado' where lead_id = v_lead;
        update public.contracts set status = 'assinado', signed_at = v_dia + time '15:00' + (random() * interval '5 hours') where lead_id = v_lead;
      end if;
    end if;

    -- peça para parte dos contratados, espalhada pela esteira jurídica (Revisão é a maior)
    if exists (select 1 from public.contracts where lead_id = v_lead and status = 'assinado') and random() < 0.9 then
      insert into public.pieces (office_id, lead_id, tese, content, status, generated_by_actor, responsavel)
      values (v_office, v_lead, (array['verbas_rescisorias','horas_extras','rescisao_indireta','vinculo_empregaticio'])[1 + (random()*3)::int],
              'Minuta gerada (demo)', 'rascunho', 'ia', v_member);
      v_etapa := (array['revisao','revisao','revisao','revisao','revisao','revisao','aguardando','aguardando','saneamento','aprovada','protocolada','protocolada','protocolada'])[1 + (i % 13)];
      if v_etapa = 'protocolada' then
        update public.pieces set status = 'protocolada', protocolo = 'ATSum ' || (1000 + i)::text || '-2026',
               protocolado_em = v_dia + interval '2 days' + time '11:00'
         where lead_id = v_lead;
      else
        update public.pieces set status = v_etapa where lead_id = v_lead;
      end if;
      update public.pieces set stage_changed_at = now() - (random() * interval '20 days'),
             alerta = case when random() < 0.15 then (array['Confirmar com o cliente antes de protocolar','Aguardando CTPS digital do cliente','Revisor pediu prova do PIX'])[1 + (random()*2)::int] else null end
       where lead_id = v_lead;
    end if;

    -- agenda: retornos combinados (a maioria marcada pela IA), alguns realizados, alguns atrasados
    if i % 3 = 0 then
      v_hora := time '08:30' + ((i / 3) % 10) * interval '1 hour';                      -- 08:30 .. 17:30
      v_task_dia := (array[current_date, current_date, current_date, current_date + 1, current_date - 1])[1 + ((i / 3) % 5)];
      insert into public.tasks (office_id, lead_id, title, description, due_at, assigned_to, created_by_actor, done_at)
      values (v_office, v_lead,
              (array['Retorno combinado','Retomar atendimento','Acompanhar assinatura','Receber documentos'])[1 + (random()*3)::int],
              (array['Retorno combinado para receber documentos e CPF do cliente e gerar o contrato.',
                     'Cliente sinalizou que já estava tarde. Retomar às 09:00. Faltam ~3 perguntas da varredura de teses + resumo final para confirmação.',
                     'Cliente trocou de celular e precisa instalar o WhatsApp no novo. Documentos pendentes: RG/CNH, comprovante de residência, CTPS digital.',
                     'Retorno combinado para acompanhar a assinatura do contrato após o almoço, conforme pedido pelo cliente.',
                     'Cliente está no plantão e não pode continuar agora. Retomar com o argumento de que precisa estar protegido antes da resposta da empresa.',
                     'Cliente vai procurar mais comprovantes de PIX de outros meses. Pendente: comprovante de endereço e CTPS digital.'])[1 + (random()*5)::int],
              (v_task_dia + v_hora) at time zone 'America/Sao_Paulo', v_member, 'ia',
              -- realizados: os de ontem (menos um em cada três, que fica atrasado) e os de hoje antes das 14h
              case when (v_task_dia < current_date and (i / 3) % 3 <> 0) or (v_task_dia = current_date and v_hora < time '14:00')
                   then (v_task_dia + v_hora) at time zone 'America/Sao_Paulo' + interval '15 minutes' else null end);
    end if;

    -- intervenções: ~35% dos leads; a maioria resolvida com desfecho e responsável
    if random() < 0.35 then
      perform public.request_intervention(v_lead, v_conv,
        (array['agendamento','caso_escalado','follow_up_esgotado','seguir_conversa','contrato_nao_assinado_24h','ia_sem_resposta','duvida_juridica','cliente_ja_existente','saneamento_juridico','caso_parado','spam'])[1 + (random()*10)::int],
        (array['Contrato pendente >24h','Caso parado >48h','Retorno combinado para continuar o cadastro','IA não respondeu há 30+ min','Corrigir peça: revisor devolveu','Cliente existente chegou no número comercial','Escalado para humano pelo agente','Lead sem atividade >96h'])[1 + (random()*7)::int],
        1 + (random()*3)::int, 'ia',
        (array['recepcao','qualificacao','provas','calculo','contrato'])[1 + (random()*4)::int],
        (array['Cliente pediu para retomar no dia seguinte.', 'Revisor devolveu a peça para correção. Veja a observação no detalhe.', 'Verificar lead: IA travada há +30 min.', 'Cliente disse que já é atendido pelo escritório e perguntou pelo andamento.', null, null])[1 + (random()*5)::int],
        case when random() < 0.2 then array['fragil'] else '{}'::text[] end);
      update public.human_interventions h
         set created_at = v_dia + time '10:00', calls_count = (random() * 2)::int
       where h.lead_id = v_lead and h.status = 'pendente';
      if random() < 0.7 then
        update public.human_interventions h
           set status = 'resolvida', claimed_by = v_member, claimed_at = v_dia + time '11:00',
               resolved_at = v_dia + time '11:00' + (random() * interval '40 hours'),
               resolution = 'Demo', outcome = (array['sanado','cliente_perdido','follow_up_agendado','cliente_retomado','reativado_para_agente','assumido_pelo_humano','outro'])[1 + (random()*6)::int]
         where h.lead_id = v_lead and h.status = 'pendente';
        update public.conversations set ai_paused = false where id = v_conv;
      end if;
    end if;
  end loop;

  -- gasto com anúncios: um valor por dia do mês
  insert into public.ad_spend (office_id, dia, canal, valor)
  select v_office, d::date, 'meta_ads', (80 + random() * 220)::int
  from generate_series(v_inicio, v_fim, interval '1 day') d
  on conflict (office_id, dia, canal) do update set valor = excluded.valor;
end $$;

-- ---------- CONFIGURAÇÕES (empresa, integrações sem segredo, 47 modelos de petição)
do $$
declare
  v_office uuid; v_member uuid; t text; b text; i int := 0;
  v_blocos text[] := array['Cabeçalho','Síntese do contrato','Abertura dos pedidos','Liquidação dos pedidos','Conciliação','Juízo 100% digital','Justiça gratuita','Fechamento dos pedidos'];
  v_teses text[] := array['verbas_rescisorias','horas_extras','rescisao_indireta','vinculo_empregaticio','adicional_insalubridade','adicional_periculosidade','dano_moral','equiparacao_salarial','acumulo_de_funcao','estabilidade_gestante','acidente_de_trabalho','intervalo_intrajornada','fgts_nao_depositado'];
  v_partes text[] := array['Pedido','Fundamentação','Provas e jurisprudência'];
begin
  select id into v_office from public.offices order by created_at limit 1;
  select user_id into v_member from public.office_members where office_id = v_office limit 1;

  update public.offices set
    tipo = 'escritorio', cnpj = coalesce(cnpj, '12.345.678/0001-90'), oab_responsavel = coalesce(oab_responsavel, 'OAB/SP 123.456'),
    fundador = coalesce(fundador, 'Dra. Bruna Medeiros'), fundacao = coalesce(fundacao, date '2018-03-01'),
    endereco = coalesce(endereco, 'Av. Paulista, 1000, cj. 101'), cidade = coalesce(cidade, 'São Paulo'), uf = coalesce(uf, 'SP'),
    email = coalesce(email, 'contato@escritorio.adv.br'), telefone = coalesce(telefone, '(11) 3000-0000'),
    whatsapp_comercial = coalesce(whatsapp_comercial, '5511999999999'), telefone_suporte = coalesce(telefone_suporte, '(11) 90000-0000')
  where id = v_office;

  -- integrações de demonstração: só a linha, sem segredo (status "não testado"); o real entra por set_integration()
  insert into public.integrations (office_id, provider, kind, active, config, status)
  select v_office, c.provider, c.kind, c.provider in ('meta_whatsapp','autentique','anthropic','openai_whisper'),
         jsonb_build_object('demo', 'true'), 'nao_testado'
  from public.integration_catalog c
  on conflict (office_id, provider) do nothing;

  -- 8 blocos obrigatórios (geral) + 13 teses × 3 partes = 47 modelos
  foreach b in array v_blocos loop
    i := i + 1;
    insert into public.piece_models (office_id, name, category, description, file_path, mime_type, size_bytes, required, uploaded_by, updated_at)
    values (v_office, b, 'geral', 'Bloco obrigatório de toda peça (demo, sem arquivo no bucket)',
            v_office::text || '/demo/' || lpad(i::text, 2, '0') || '-' || lower(regexp_replace(b, '[^a-zA-Z0-9]+', '-', 'g')) || '.docx',
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 12000 + (random()*40000)::int, true, v_member,
            now() - (random() * interval '120 days'));
  end loop;
  foreach t in array v_teses loop
    foreach b in array v_partes loop
      i := i + 1;
      insert into public.piece_models (office_id, name, category, description, file_path, mime_type, size_bytes, required, active, uploaded_by, updated_at)
      values (v_office, initcap(replace(t, '_', ' ')) || ' — ' || b, t, 'Modelo da tese (demo, sem arquivo no bucket)',
              v_office::text || '/demo/' || lpad(i::text, 2, '0') || '-' || t || '-' || lower(regexp_replace(b, '[^a-zA-Z0-9]+', '-', 'g')) || '.docx',
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 20000 + (random()*80000)::int, false, random() < 0.9, v_member,
              now() - (random() * interval '300 days'));
    end loop;
  end loop;
end $$;

select 'demo criado' as status, count(*) as leads from public.leads l join public.contacts c on c.id = l.contact_id where c.wa_id like '5500%';
