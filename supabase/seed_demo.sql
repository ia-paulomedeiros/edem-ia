-- =============================================================================
-- seed_demo.sql — dados de demonstração para ver o dashboard e o kanban cheios
--
-- Gera ~60 leads no mês corrente para o PRIMEIRO escritório cadastrado, com
-- conversas, mensagens (com ai_meta), dados do caso, qualificação, contratos
-- assinados espalhados pelos dias, UFs variadas e alguns encerrados.
-- Tudo marcado com wa_id começando em '5500' para poder apagar depois.
--
-- Rodar no SQL Editor depois de 001..004. Pode rodar mais de uma vez (apaga
-- e recria o demo). Para remover: rode só o bloco "LIMPEZA".
-- =============================================================================

-- ---------- LIMPEZA (apaga só o que é demo)
delete from public.leads where contact_id in (select id from public.contacts where wa_id like '5500%');
delete from public.contacts where wa_id like '5500%';

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

    -- algumas intervenções abertas para a fila
    if random() < 0.08 then
      perform public.request_intervention(v_lead, v_conv, 'duvida_juridica', 'Lead pergunta se pode fazer acordo direto com a empresa', 2, 'ia', 'calculo');
    end if;
  end loop;
end $$;

select 'demo criado' as status, count(*) as leads from public.leads l join public.contacts c on c.id = l.contact_id where c.wa_id like '5500%';
