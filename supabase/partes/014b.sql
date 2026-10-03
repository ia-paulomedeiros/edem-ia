-- =============================================================================
-- 014b — parte 2 de 5 de supabase/014_paridade_regras.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 014a. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- ---------- Verificação da parte 014b: deve voltar uma linha com resultado = OK
select '014b' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função advance_phase', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'advance_phase')),
    ('função agent_config_full', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_config_full')),
    ('função agent_config_full_lead', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_config_full_lead')),
    ('função agent_config_lead', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_config_lead')),
    ('função agent_config_role', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_config_role')),
    ('função agent_for_lead', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_for_lead')),
    ('função agent_label', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_label')),
    ('função agent_label_lead', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_label_lead')),
    ('função agent_prompt_render', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_prompt_render')),
    ('função close_lead_with_reason', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'close_lead_with_reason')),
    ('função etapa_titulo', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'etapa_titulo')),
    ('função etapas', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'etapas')),
    ('função journey_stage_agents', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'journey_stage_agents')),
    ('função journey_stage_key', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'journey_stage_key')),
    ('função journey_stages', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'journey_stages')),
    ('função lead_etapa', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_etapa')),
    ('função lead_journey_stage', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_journey_stage')),
    ('função ui_close_lead', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_close_lead')),
    ('função ui_reopen_lead', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_reopen_lead')),
    ('função ui_set_agent_persona', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_set_agent_persona')),
    ('coluna agents.persona_nome', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'agents' and column_name = 'persona_nome'))
) as v(item, ok);
