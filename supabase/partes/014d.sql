-- =============================================================================
-- 014d — parte 4 de 5 de supabase/014_paridade_regras.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 014c. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- ---------- Verificação da parte 014d: deve voltar uma linha com resultado = OK
select '014d' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função claim_intervention', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'claim_intervention')),
    ('função dashboard_investimento_p', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'dashboard_investimento_p')),
    ('função followup_no_template', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'followup_no_template')),
    ('função lead_dossier', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'lead_dossier')),
    ('função marketing_lancar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'marketing_lancar')),
    ('função marketing_resumo_p', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'marketing_resumo_p')),
    ('função ui_move_to_column', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_move_to_column')),
    ('view v_clientes', to_regclass('public.v_clientes') is not null),
    ('view v_fila_leads', to_regclass('public.v_fila_leads') is not null),
    ('view v_fluxo_cards', to_regclass('public.v_fluxo_cards') is not null),
    ('view v_juridico_cards', to_regclass('public.v_juridico_cards') is not null)
) as v(item, ok);
