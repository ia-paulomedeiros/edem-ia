-- =============================================================================
-- 015b — parte 2 de 3 de supabase/015_paridade_automacoes.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 015a. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- ingest_inbound (001) + alerta de cliente já existente quando um telefone com
-- caso assinado abre um lead novo. Mesma assinatura.
create or replace function public.ingest_inbound(p_phone_number_id text, p_wa_id text, p_name text, p_wa_message_id text, p_body text,
                                                 p_media jsonb default null, p_ts timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_num   public.whatsapp_numbers;
  v_contact_id uuid;
  v_lead_id uuid;
  v_conv_id uuid;
  v_msg_id uuid;
  v_new_lead boolean := false;
  v_outro uuid;
begin
  select * into v_num from public.whatsapp_numbers where phone_number_id = p_phone_number_id and active;
  if v_num.id is null then
    raise exception 'phone_number_id % não cadastrado/ativo', p_phone_number_id;
  end if;

  if p_wa_message_id is not null and exists (select 1 from public.messages where wa_message_id = p_wa_message_id) then
    select m.id, m.conversation_id, c.lead_id into v_msg_id, v_conv_id, v_lead_id
      from public.messages m join public.conversations c on c.id = m.conversation_id
     where m.wa_message_id = p_wa_message_id;
    return jsonb_build_object('duplicate', true, 'office_id', v_num.office_id, 'lead_id', v_lead_id,
                              'conversation_id', v_conv_id, 'message_id', v_msg_id, 'ai_should_reply', false);
  end if;

  insert into public.contacts (office_id, wa_id, name)
  values (v_num.office_id, p_wa_id, nullif(p_name, ''))
  on conflict (office_id, wa_id) do update
    set name = coalesce(public.contacts.name, excluded.name)
  returning id into v_contact_id;

  select id into v_lead_id from public.leads where contact_id = v_contact_id and closed_at is null;
  if v_lead_id is null then
    insert into public.leads (office_id, contact_id, source) values (v_num.office_id, v_contact_id, 'whatsapp')
    returning id into v_lead_id;
    v_new_lead := true;
    perform public.log_event(v_num.office_id, v_lead_id, 'lead_created', 'sistema', null, null,
                             jsonb_build_object('source', 'whatsapp', 'wa_id', p_wa_id));
  end if;

  insert into public.conversations (office_id, lead_id, contact_id, whatsapp_number_id)
  values (v_num.office_id, v_lead_id, v_contact_id, v_num.id)
  on conflict (lead_id, whatsapp_number_id) do update set status = 'open'
  returning id into v_conv_id;

  insert into public.messages (office_id, conversation_id, direction, sender, body, media, wa_message_id, status, created_at)
  values (v_num.office_id, v_conv_id, 'in', 'contact', p_body, p_media, p_wa_message_id, 'received', coalesce(p_ts, now()))
  returning id into v_msg_id;

  if v_new_lead then
    select l2.id into v_outro from public.leads l2 join public.contracts k on k.lead_id = l2.id and k.status = 'assinado'
     where l2.contact_id = v_contact_id and l2.id <> v_lead_id limit 1;
    if v_outro is not null then
      perform public.request_intervention(v_lead_id, v_conv_id, 'cliente_ja_existente', 'Cliente já existente', 2, 'sistema', null,
        'Este telefone já tem caso assinado em outro atendimento. Confira se é andamento de processo (jurídico) ou um caso novo.',
        array['monitor', 'lead:' || v_outro]);
    end if;
  end if;

  return jsonb_build_object(
    'duplicate', false,
    'new_lead', v_new_lead,
    'office_id', v_num.office_id,
    'contact_id', v_contact_id,
    'lead_id', v_lead_id,
    'conversation_id', v_conv_id,
    'message_id', v_msg_id,
    'ai_should_reply', public.ai_should_reply(v_conv_id)
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- 11. Calculista: qualificação detalhada e versionada
-- -----------------------------------------------------------------------------
create table if not exists public.qualification_records (
  id          uuid primary key default gen_random_uuid(),
  lead_id     uuid not null references public.leads(id) on delete cascade,
  office_id   uuid not null references public.offices(id) on delete cascade,
  versao      int not null,
  data        jsonb not null default '{}'::jsonb,
  agent_role  text not null default 'calculo',
  ai_meta     jsonb,
  created_at  timestamptz not null default now(),
  unique (lead_id, versao)
);
create index if not exists qualification_records_lead_idx on public.qualification_records (lead_id, versao desc);
alter table public.qualification_records enable row level security;
drop policy if exists qualification_records_select on public.qualification_records;
create policy qualification_records_select on public.qualification_records for select to authenticated
  using (public.is_office_member(office_id));
-- sem insert/update/delete para o front: só save_qualification_record (n8n)
select public.add_to_realtime('qualification_records');
grant select on public.qualification_records to authenticated;

-- Prescrição calculada pelo banco (nunca pelo LLM).
create or replace function public.prescricao_info(p_lead uuid)
returns jsonb language plpgsql stable set search_path = public as $$
declare
  d public.case_data; p public.office_params; l public.leads;
  v_prazo date; v_dias int; v_status text; v_ajuiz date; v_quinq date; v_inicio date; v_exc text[] := '{}';
begin
  select * into l from public.leads where id = p_lead;
  select * into d from public.case_data where lead_id = p_lead;
  select * into p from public.office_params where office_id = l.office_id;
  if d.demissao is null then
    v_status := 'nao_iniciado';
    v_exc := array_append(v_exc, 'Contrato em curso ou sem data de saída: o prazo de 2 anos ainda não começou.'::text);
  else
    v_prazo := (d.demissao + interval '2 years')::date;
    v_dias := v_prazo - current_date;
    v_status := case when v_dias < 0 then 'vencido' when v_dias <= coalesce(p.alerta_prescricao_dias, 90) then 'alerta' else 'ok' end;
  end if;
  v_ajuiz := case when v_prazo is null then current_date + 15 else least(current_date + 15, greatest(v_prazo, current_date)) end;
  v_quinq := (v_ajuiz - interval '5 years')::date;
  v_inicio := greatest(coalesce(d.admissao, v_quinq), v_quinq);
  if coalesce(d.acidente_trabalho, false) then
    v_exc := array_append(v_exc, 'Acidente de trabalho: conferir estabilidade (art. 118 da Lei 8.213/91) e eventuais prazos próprios.'::text);
  end if;
  if d.fgts_depositado = false then
    v_exc := array_append(v_exc, 'FGTS não depositado: cobrança limitada aos últimos 5 anos (STF, ARE 709.212).'::text);
  end if;
  if d.tipo_rescisao = 'rescisao_indireta' then
    v_exc := array_append(v_exc, 'Rescisão indireta: a data de saída depende do reconhecimento em juízo.'::text);
  end if;
  return jsonb_build_object(
    'data_saida', d.demissao,
    'prazo_bienal', v_prazo,
    'status_bienal', v_status,
    'dias_restantes', v_dias,
    'data_provavel_ajuizamento', v_ajuiz,
    'limite_quinquenal', v_quinq,
    'inicio_periodo_nao_prescrito', v_inicio,
    'meses_nao_prescritos', public.vinculo_meses(v_inicio, coalesce(d.demissao, current_date)),
    'excecoes', to_jsonb(v_exc));
end; $$;

-- Leads com a entrevista concluída esperando o Calculista (n8n 11).
create or replace function public.calculista_queue(p_limit int default 10)
returns table (lead_id uuid, office_id uuid, nome text, briefing jsonb, case_data jsonb, prescricao jsonb, estimativa jsonb,
               params jsonb, versao_atual int, model text)
language sql stable security definer set search_path = public as $$
  select l.id, l.office_id, ct.name, to_jsonb(b), to_jsonb(d), public.prescricao_info(l.id), public.calc_verbas(l.id),
         jsonb_build_object('ticket_minimo', p.ticket_minimo, 'faixas_ticket', p.faixas_ticket, 'honorarios_percent', p.honorarios_percent,
                            'cambio_usd_brl', p.cambio_usd_brl),
         (select max(r.versao) from public.qualification_records r where r.lead_id = l.id),
         (select a.model from public.agent_config_role(l.office_id, 'calculo') a)
  from public.leads l
  join public.briefings b on b.lead_id = l.id and b.status = 'concluido'
  join public.contacts ct on ct.id = l.contact_id
  left join public.case_data d on d.lead_id = l.id
  left join public.office_params p on p.office_id = l.office_id
  where l.phase = 'calculo'
    and not exists (select 1 from public.qualification_records r where r.lead_id = l.id and r.created_at >= coalesce(b.completed_at, b.updated_at))
    and not exists (select 1 from public.case_events e where e.lead_id = l.id and e.type = 'calculista_falhou' and e.created_at > now() - interval '1 hour')
  order by coalesce(b.completed_at, b.updated_at)
  limit p_limit;
$$;

create or replace function public.faixa_label(p_faixa text, p_passou_minimo boolean default true)
returns text language sql immutable set search_path = public as $$
  select case when not coalesce(p_passou_minimo, true) then 'INVIAVEL'
    else case p_faixa when 'baixo' then 'LOW_TICKET' when 'medio' then 'MID_TICKET' when 'alto' then 'HIGH_TICKET' else upper(coalesce(p_faixa, 'indefinida')) end end;
$$;

-- Número vindo do LLM: aceita 1234.56, "1234,56", "R$ 1.234,56"; lixo vira null.
create or replace function public.to_num(p text)
returns numeric language plpgsql immutable set search_path = public as $$
declare s text := regexp_replace(coalesce(p, ''), '[^0-9,.\-]', '', 'g');
begin
  if s = '' then return null; end if;
  if s ~ ',\d{1,2}$' then s := replace(replace(s, '.', ''), ',', '.');   -- 1.234,56
  else s := replace(s, ',', ''); end if;                                -- 1,234.56 ou 1234.56
  return s::numeric;
exception when others then return null;
end; $$;

-- Grava a versão nova do cálculo. data: {dados_base, verbas[], ...}; a
-- prescrição do banco substitui qualquer prescrição que venha no JSON.
create or replace function public.save_qualification_record(p_lead uuid, p_data jsonb, p_agent_role text default 'calculo', p_ai_meta jsonb default null)
returns public.qualification_records language plpgsql security definer set search_path = public as $$
declare
  l public.leads; p public.office_params; r public.qualification_records;
  v_versao int; v_total numeric; v_faixa text; v_motivos text[] := '{}'; v_presc jsonb; v_data jsonb; v_label text; v_passed boolean;
begin
  select * into l from public.leads where id = p_lead for update;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then raise exception 'data precisa ser um objeto JSON'; end if;
  if jsonb_typeof(coalesce(p_data->'verbas', 'null'::jsonb)) <> 'array' then raise exception 'data.verbas precisa ser uma lista'; end if;
  select * into p from public.office_params where office_id = l.office_id;

  v_presc := public.prescricao_info(p_lead);
  select coalesce(sum(coalesce(public.to_num(v->>'total'),
                               coalesce(public.to_num(v->>'valor_calculado'), 0) - coalesce(public.to_num(v->>'ja_recebido'), 0))), 0)
    into v_total from jsonb_array_elements(p_data->'verbas') v;
  v_faixa := public.faixa_ticket(l.office_id, v_total);
  if v_total < p.ticket_minimo then v_motivos := v_motivos || format('ticket_baixo:%s<%s', v_total, p.ticket_minimo); end if;
  if v_presc->>'status_bienal' = 'vencido' then v_motivos := v_motivos || format('prescrito_em:%s', v_presc->>'prazo_bienal'); end if;
  v_passed := cardinality(v_motivos) = 0;
  v_label := public.faixa_label(v_faixa, v_total >= p.ticket_minimo);

  select coalesce(max(versao), 0) + 1 into v_versao from public.qualification_records where lead_id = p_lead;
  v_data := (p_data - 'prescricao') || jsonb_build_object('prescricao', v_presc, 'total', v_total, 'faixa', v_faixa, 'faixa_label', v_label,
                                                          'passed', v_passed, 'motivos', to_jsonb(v_motivos));
  insert into public.qualification_records (lead_id, office_id, versao, data, agent_role, ai_meta)
  values (p_lead, l.office_id, v_versao, v_data, coalesce(p_agent_role, 'calculo'), p_ai_meta)
  returning * into r;

  insert into public.lead_qualification (lead_id, office_id, passed, faixa, verbas, verbas_total, vinculo_meses, motivos, evaluated_by_actor, evaluated_at)
  values (p_lead, l.office_id, v_passed, v_faixa, p_data->'verbas', v_total,
          round(public.to_num(p_data->'dados_base'->>'meses_contrato'))::int, v_motivos, 'ia', now())
  on conflict (lead_id) do update
    set passed = excluded.passed, faixa = excluded.faixa, verbas = excluded.verbas, verbas_total = excluded.verbas_total,
        vinculo_meses = coalesce(excluded.vinculo_meses, public.lead_qualification.vinculo_meses), motivos = excluded.motivos,
        evaluated_by_actor = 'ia', evaluated_at = now();

  perform public.log_event(l.office_id, p_lead, 'qualificacao_gerada', 'ia', null, coalesce(p_agent_role, 'calculo'),
    jsonb_build_object('record_id', r.id, 'versao', v_versao, 'total', v_total, 'faixa', v_faixa, 'faixa_label', v_label, 'passed', v_passed,
                       'motivos', to_jsonb(v_motivos), 'texto', 'Qualificação (cálculo) gerada — ' || v_label || ' ' || public.brl(v_total)));

  if l.phase = 'calculo' then
    if v_passed then
      perform public.advance_phase(p_lead, 'provas', 'ia', null, coalesce(p_agent_role, 'calculo'), 'qualificação gerada — ' || v_label);
    else
      -- inviável ou prescrito: a equipe decide (encerrar como Inviável ou seguir)
      perform public.request_intervention(p_lead,
        (select id from public.conversations where lead_id = p_lead order by last_message_at desc nulls last limit 1),
        'saneamento_juridico', 'Cálculo pede revisão: ' || array_to_string(v_motivos, ', '), 2, 'ia', coalesce(p_agent_role, 'calculo'),
        'Qualificação v' || v_versao || ' — ' || v_label || ' ' || public.brl(v_total) || '. Avalie encerrar como Inviável ou seguir.',
        array['calculista']);
    end if;
  end if;
  return r;
end; $$;

create or replace function public.calculista_failed(p_lead uuid, p_error text)
returns void language sql security definer set search_path = public as $$
  select public.log_event(l.office_id, l.id, 'calculista_falhou', 'sistema', null, 'calculo', jsonb_build_object('error', left(p_error, 500)))
  from public.leads l where l.id = p_lead;
$$;

-- -----------------------------------------------------------------------------
-- 12. Geração da peça
-- -----------------------------------------------------------------------------
alter table public.pieces
  add column if not exists geracao_status text,
  add column if not exists geracao_solicitada_em timestamptz,
  add column if not exists geracao_iniciada_em timestamptz,
  add column if not exists geracao_erro text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'pieces_geracao_status_check') then
    alter table public.pieces add constraint pieces_geracao_status_check
      check (geracao_status is null or geracao_status in ('pendente','gerando','gerada','falhou'));
  end if;
end $$;

-- Coleta terminou: lead vai para a peça e a peça fica pendente de geração.
create or replace function public.request_piece_generation(p_lead uuid, p_actor text, p_actor_user uuid default null, p_agent text default null)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare l public.leads; pc public.pieces; v_tese text;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  if l.phase = 'provas' then
    l := public.advance_phase(p_lead, 'peca', p_actor, p_actor_user, p_agent, 'coleta de documentos finalizada');
  elsif l.phase <> 'peca' then
    raise exception 'a peça só é gerada depois da coleta de documentos (fase atual: %)', public.phase_label(l.phase);
  end if;

  select * into pc from public.pieces where lead_id = p_lead order by created_at desc limit 1;
  if pc.id is not null and pc.status <> 'rascunho' then
    return pc;   -- já está em revisão/saneamento/protocolo: não gera outra por cima
  end if;
  if pc.id is null then
    v_tese := coalesce(l.tese, (select b.teses[1] from public.briefings b where b.lead_id = p_lead limit 1), 'verbas_rescisorias');
    insert into public.pieces (office_id, lead_id, tese, status, generated_by_actor, geracao_status, geracao_solicitada_em)
    values (l.office_id, p_lead, v_tese, 'rascunho', 'ia', 'pendente', now())
    returning * into pc;
  elsif coalesce(pc.geracao_status, '') not in ('pendente','gerando') then
    update public.pieces set geracao_status = 'pendente', geracao_solicitada_em = now(), geracao_erro = null
     where id = pc.id returning * into pc;
  end if;
  perform public.log_event(l.office_id, p_lead, 'piece_generation_requested', p_actor, p_actor_user, p_agent,
    jsonb_build_object('piece_id', pc.id, 'tese', pc.tese));
  return pc;
end; $$;

create or replace function public.ui_finish_collection(p_lead uuid)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_finish_collection exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  return public.request_piece_generation(p_lead, 'humano', auth.uid(), null);
end; $$;

-- n8n 08 pega as peças pendentes (e as que travaram em "gerando" há 30+ min).
create or replace function public.piece_generation_claim(p_limit int default 5)
returns table (piece_id uuid, lead_id uuid, office_id uuid, tese text, teses text[], blocos jsonb, briefing jsonb, qualificacao jsonb,
               evidencias jsonb, case_data jsonb, contato jsonb, escritorio jsonb, model text)
language plpgsql security definer set search_path = public as $$
begin
  return query
  with alvo as (
    select p.id from public.pieces p
    where p.geracao_status = 'pendente' or (p.geracao_status = 'gerando' and p.geracao_iniciada_em < now() - interval '30 minutes')
    order by p.geracao_solicitada_em nulls last
    limit p_limit
    for update skip locked
  ), c as (
    update public.pieces p set geracao_status = 'gerando', geracao_iniciada_em = now()
    from alvo where p.id = alvo.id
    returning p.*
  )
  select c.id, c.lead_id, c.office_id, c.tese, t.teses,
    (select coalesce(jsonb_agg(jsonb_build_object('kind', x.kind, 'code', x.code, 'nome', x.name, 'tese', x.tese, 'obrigatorio', x.required,
                                                  'ordem', x.ordem, 'texto', x.body, 'provas_exigidas', x.required_evidence)
                               order by case x.kind when 'bloco' then 0 else 1 end, x.ordem), '[]'::jsonb)
       from (select distinct on (coalesce(pt.code, pt.tese || ':' || pt.name)) pt.*
               from public.piece_templates pt
              where pt.active and (pt.office_id = c.office_id or pt.office_id is null)
                and ((pt.kind = 'bloco' and pt.required) or (pt.kind = 'tese' and pt.tese = any (t.teses)))
              order by coalesce(pt.code, pt.tese || ':' || pt.name), pt.office_id nulls last) x),
    (select to_jsonb(b) from public.briefings b where b.lead_id = c.lead_id limit 1),
    coalesce((select r.data || jsonb_build_object('versao', r.versao) from public.qualification_records r where r.lead_id = c.lead_id order by r.versao desc limit 1),
             (select to_jsonb(q) from public.lead_qualification q where q.lead_id = c.lead_id)),
    (select coalesce(jsonb_agg(jsonb_build_object('titulo', e.title, 'doc_tipo', e.doc_tipo, 'status', e.status, 'descricao', e.description)
                               order by e.created_at), '[]'::jsonb)
       from public.evidences e where e.lead_id = c.lead_id and e.status in ('recebida','validada')),
    (select to_jsonb(d) from public.case_data d where d.lead_id = c.lead_id),
    (select jsonb_build_object('nome', ct.name, 'cpf', ct.cpf, 'nascimento', ct.nascimento, 'estado_civil', ct.estado_civil,
                               'nacionalidade', ct.nacionalidade, 'endereco', ct.endereco, 'cidade', ct.cidade, 'uf', ct.uf, 'cep', ct.cep)
       from public.leads l join public.contacts ct on ct.id = l.contact_id where l.id = c.lead_id),
    public.office_escritorio(c.office_id) || (select jsonb_build_object('oab_responsavel', o.oab_responsavel, 'cidade', o.cidade, 'uf', o.uf)
                                              from public.offices o where o.id = c.office_id),
    (select a.model from public.agent_config_role(c.office_id, 'redacao') a)
  from c
  cross join lateral (select coalesce(nullif((select b.teses from public.briefings b where b.lead_id = c.lead_id limit 1), '{}'::text[]),
                                      array[c.tese]) as teses) t;
end; $$;

create or replace function public.piece_generation_save(p_piece uuid, p_content text, p_resumo_executivo text default null,
                                                        p_documentos_anexar jsonb default '[]'::jsonb, p_qualidade text default null,
                                                        p_ai_meta jsonb default null)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare pc public.pieces;
begin
  if coalesce(btrim(p_content), '') = '' then raise exception 'conteúdo vazio'; end if;
  update public.pieces
     set content = p_content,
         resumo_executivo = coalesce(p_resumo_executivo, resumo_executivo),
         documentos_anexar = case when jsonb_typeof(p_documentos_anexar) = 'array' then p_documentos_anexar else documentos_anexar end,
         qualidade = case when p_qualidade in ('viavel','fragil') then p_qualidade else qualidade end,
         generated_by_actor = 'ia', status = 'revisao', geracao_status = 'gerada', geracao_erro = null
   where id = p_piece returning * into pc;
  if pc.id is null then raise exception 'peça % não existe', p_piece; end if;
  perform public.log_event(pc.office_id, pc.lead_id, 'piece_generated', 'ia', null, 'redacao',
    jsonb_build_object('piece_id', pc.id, 'tese', pc.tese, 'versao', pc.versao, 'qualidade', pc.qualidade,
                       'caracteres', length(p_content), 'ai_meta', p_ai_meta));
  return pc;
end; $$;

create or replace function public.piece_generation_failed(p_piece uuid, p_error text)
returns public.pieces language plpgsql security definer set search_path = public as $$
declare pc public.pieces;
begin
  update public.pieces set geracao_status = 'falhou', geracao_erro = left(p_error, 500) where id = p_piece returning * into pc;
  if pc.id is null then raise exception 'peça % não existe', p_piece; end if;
  perform public.log_event(pc.office_id, pc.lead_id, 'piece_generation_failed', 'sistema', null, 'redacao',
    jsonb_build_object('piece_id', pc.id, 'error', left(p_error, 500)));
  perform public.request_intervention(pc.lead_id, null, 'erro_ia', 'Falha ao gerar a peça', 2, 'sistema', 'redacao',
    left(p_error, 300), array['peca']);
  return pc;
end; $$;

-- ---------- Verificação da parte 015b: deve voltar uma linha com resultado = OK
select '015b' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função calculista_failed', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'calculista_failed')),
    ('função calculista_queue', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'calculista_queue')),
    ('função faixa_label', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'faixa_label')),
    ('função ingest_inbound', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ingest_inbound')),
    ('função piece_generation_claim', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_generation_claim')),
    ('função piece_generation_failed', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_generation_failed')),
    ('função piece_generation_save', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_generation_save')),
    ('função prescricao_info', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'prescricao_info')),
    ('função request_piece_generation', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'request_piece_generation')),
    ('função save_qualification_record', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'save_qualification_record')),
    ('função to_num', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'to_num')),
    ('função ui_finish_collection', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_finish_collection')),
    ('tabela qualification_records', to_regclass('public.qualification_records') is not null),
    ('coluna pieces.geracao_status', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pieces' and column_name = 'geracao_status')),
    ('coluna pieces.geracao_solicitada_em', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pieces' and column_name = 'geracao_solicitada_em')),
    ('coluna pieces.geracao_iniciada_em', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pieces' and column_name = 'geracao_iniciada_em')),
    ('coluna pieces.geracao_erro', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'pieces' and column_name = 'geracao_erro'))
) as v(item, ok);
