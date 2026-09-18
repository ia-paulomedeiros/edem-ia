-- =============================================================================
-- 009_marketing.sql — Sprint 3: Marketing (custos) igual ao concorrente
--
-- 1. ad_spend vira o livro de lançamentos de marketing: por dia, anúncios
--    (meta_ads, google_ads, ...) e tokens (tokens, tokens_anthropic,
--    tokens_openai), com origem manual ou importado.
-- 2. Tokens por dia: o lançamento (manual/importado) manda; sem lançamento,
--    vale a estimativa pelas mensagens da IA (messages.ai_meta × câmbio).
--    Uma função só (marketing_tokens_por_dia) alimenta Marketing e Dashboard.
-- 3. Custo por lead (lead_cost): tokens do próprio caso + rateio dos anúncios
--    do dia em que o lead chegou + média do mês. Entra no dossiê ('cost').
-- 4. Importação (n8n, service_role): Meta Ads (Marketing API), Anthropic Admin
--    (cost_report) e OpenAI Admin (organization/costs). Catálogo ganha meta_ads.
--
-- Idempotente. Rodar depois de 008.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Lançamentos
-- -----------------------------------------------------------------------------

alter table public.ad_spend
  add column if not exists origem     text not null default 'manual',
  add column if not exists valor_usd  numeric,
  add column if not exists updated_by uuid references auth.users(id),
  add column if not exists updated_at timestamptz not null default now();

alter table public.ad_spend drop constraint if exists ad_spend_canal_check;
alter table public.ad_spend add constraint ad_spend_canal_check
  check (canal in ('meta_ads','google_ads','tiktok_ads','outro','tokens','tokens_anthropic','tokens_openai'));
alter table public.ad_spend drop constraint if exists ad_spend_origem_check;
alter table public.ad_spend add constraint ad_spend_origem_check check (origem in ('manual','importado'));

drop trigger if exists ad_spend_touch on public.ad_spend;
create trigger ad_spend_touch before update on public.ad_spend
  for each row execute function public.touch_updated_at();

create or replace function public.canal_tipo(p_canal text)
returns text language sql immutable as $$
  select case when p_canal like 'tokens%' then 'tokens' else 'ads' end;
$$;

-- Um dia por linha: anúncios, tokens, total, origem e os itens.
create or replace view public.v_marketing_lancamentos
with (security_invoker = true) as
select
  a.office_id, a.dia,
  coalesce(sum(a.valor) filter (where public.canal_tipo(a.canal) = 'ads'), 0)    as ads_brl,
  coalesce(sum(a.valor) filter (where public.canal_tipo(a.canal) = 'tokens'), 0) as tokens_brl,
  coalesce(sum(a.valor), 0)                                                       as total_brl,
  bool_or(a.origem = 'importado')                                                 as tem_importado,
  bool_or(a.origem = 'manual')                                                    as tem_manual,
  string_agg(a.nota, ' · ' order by a.canal) filter (where a.nota is not null)    as observacao,
  jsonb_agg(jsonb_build_object('id', a.id, 'canal', a.canal, 'tipo', public.canal_tipo(a.canal), 'origem', a.origem,
                               'valor_brl', a.valor, 'valor_usd', a.valor_usd, 'nota', a.nota) order by a.canal) as itens,
  max(a.updated_at)                                                               as updated_at
from public.ad_spend a
group by a.office_id, a.dia;

-- Lançar/editar um dia (admin ou advogado; RLS de ad_spend decide).
create or replace function public.marketing_lancar(
  p_office uuid, p_dia date, p_ads_brl numeric default null, p_tokens_brl numeric default null, p_nota text default null)
returns jsonb
language plpgsql set search_path = public as $$
begin
  if p_ads_brl is not null then
    insert into public.ad_spend (office_id, dia, canal, valor, nota, origem, created_by, updated_by)
    values (p_office, p_dia, 'meta_ads', p_ads_brl, p_nota, 'manual', auth.uid(), auth.uid())
    on conflict (office_id, dia, canal) do update
      set valor = excluded.valor, nota = coalesce(excluded.nota, public.ad_spend.nota), origem = 'manual', updated_by = auth.uid();
  end if;
  if p_tokens_brl is not null then
    insert into public.ad_spend (office_id, dia, canal, valor, nota, origem, created_by, updated_by)
    values (p_office, p_dia, 'tokens', p_tokens_brl, p_nota, 'manual', auth.uid(), auth.uid())
    on conflict (office_id, dia, canal) do update
      set valor = excluded.valor, nota = coalesce(excluded.nota, public.ad_spend.nota), origem = 'manual', updated_by = auth.uid();
  end if;
  if p_ads_brl is null and p_tokens_brl is null and p_nota is not null then
    update public.ad_spend set nota = p_nota, updated_by = auth.uid() where office_id = p_office and dia = p_dia;
  end if;
  return (select to_jsonb(v) from public.v_marketing_lancamentos v where v.office_id = p_office and v.dia = p_dia);
end; $$;

-- Remover os lançamentos manuais do dia (os importados ficam).
create or replace function public.marketing_remover(p_office uuid, p_dia date)
returns int
language plpgsql set search_path = public as $$
declare n int;
begin
  delete from public.ad_spend where office_id = p_office and dia = p_dia and origem = 'manual';
  get diagnostics n = row_count;
  return n;
end; $$;

-- -----------------------------------------------------------------------------
-- 2. Tokens por dia: lançamento manda; senão, estimativa pelas mensagens
-- -----------------------------------------------------------------------------

create or replace function public.marketing_tokens_por_dia(p_office uuid, p_from date, p_to date)
returns table (dia date, tokens_brl numeric, tokens_usd numeric, origem text)
language sql stable set search_path = public as $$
  with cambio as (select coalesce((select cambio_usd_brl from public.office_params where office_id = p_office), 5.5) as v),
  lanc as (
    select a.dia, sum(a.valor) as brl, sum(a.valor_usd) as usd
    from public.ad_spend a
    where a.office_id = p_office and public.canal_tipo(a.canal) = 'tokens' and a.dia >= p_from and a.dia <= p_to
    group by a.dia
  ),
  est as (
    select m.created_at::date as dia, coalesce(sum((m.ai_meta->>'cost_usd')::numeric), 0) as usd
    from public.messages m
    where m.office_id = p_office and m.sender = 'ia' and m.created_at >= p_from::timestamptz and m.created_at < (p_to + 1)::timestamptz
    group by 1
  )
  select d.dia::date,
         coalesce(l.brl, round(coalesce(e.usd, 0) * cambio.v, 2)) as tokens_brl,
         coalesce(l.usd, e.usd, 0) as tokens_usd,
         case when l.dia is not null then 'lancado' when e.dia is not null then 'estimado' else 'nenhum' end as origem
  from generate_series(p_from, p_to, interval '1 day') as d(dia)
  cross join cambio
  left join lanc l on l.dia = d.dia::date
  left join est e on e.dia = d.dia::date;
$$;

-- Resumo do período (cards do topo da página Marketing).
create or replace function public.marketing_resumo_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb
language sql stable set search_path = public as $$
  with b as (select p_start::date as d0, (p_end - interval '1 day')::date as d1 from public.period_bounds(p_office, p_from, p_to)),
  ads as (select coalesce(sum(a.valor), 0) as brl from public.ad_spend a, b
          where a.office_id = p_office and public.canal_tipo(a.canal) = 'ads' and a.dia between b.d0 and b.d1),
  tok as (select coalesce(sum(t.tokens_brl), 0) as brl, count(*) filter (where t.origem = 'lancado') as lancados
          from b, public.marketing_tokens_por_dia(p_office, b.d0, b.d1) t),
  leads as (select count(*) as n from public.leads l, b where l.office_id = p_office and l.created_at >= b.d0 and l.created_at < b.d1 + 1),
  ctr as (select count(*) as n from public.contracts k, b where k.office_id = p_office and k.status = 'assinado' and k.signed_at >= b.d0 and k.signed_at < b.d1 + 1),
  lanc as (select count(*) as n from public.v_marketing_lancamentos v, b where v.office_id = p_office and v.dia between b.d0 and b.d1)
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.d0, 'ate', b.d1),
    'ads_brl', round(ads.brl, 2),
    'tokens_brl', round(tok.brl, 2),
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

-- Lista do período (tabela da página Marketing), mais recente primeiro.
create or replace function public.marketing_lancamentos_p(p_office uuid, p_from date default null, p_to date default null)
returns setof public.v_marketing_lancamentos
language sql stable set search_path = public as $$
  select v.* from public.v_marketing_lancamentos v, public.period_bounds(p_office, p_from, p_to) b
  where v.office_id = p_office and v.dia >= b.p_start::date and v.dia < b.p_end::date
  order by v.dia desc;
$$;

-- -----------------------------------------------------------------------------
-- 3. Custo por lead
-- -----------------------------------------------------------------------------

create or replace function public.lead_cost(p_lead uuid)
returns jsonb
language sql stable set search_path = public as $$
  with l as (select id, office_id, created_at::date as dia from public.leads where id = p_lead),
  cambio as (select coalesce((select cambio_usd_brl from public.office_params p, l where p.office_id = l.office_id), 5.5) as v),
  ac as (select * from public.lead_acquisition_cost where lead_id = p_lead),
  ads_dia as (select coalesce(sum(a.valor), 0) as brl from public.ad_spend a, l
              where a.office_id = l.office_id and a.dia = l.dia and public.canal_tipo(a.canal) = 'ads'),
  leads_dia as (select count(*) as n from public.leads x, l where x.office_id = l.office_id and x.created_at::date = l.dia),
  mes as (select date_trunc('month', l.dia)::date as d0, (date_trunc('month', l.dia) + interval '1 month - 1 day')::date as d1 from l),
  mes_tot as (
    select (select coalesce(sum(a.valor), 0) from public.ad_spend a, l, mes
             where a.office_id = l.office_id and public.canal_tipo(a.canal) = 'ads' and a.dia between mes.d0 and mes.d1)
         + (select coalesce(sum(t.tokens_brl), 0) from l, mes, public.marketing_tokens_por_dia(l.office_id, mes.d0, mes.d1) t) as brl,
           (select count(*) from public.leads x, l, mes where x.office_id = l.office_id and x.created_at::date between mes.d0 and mes.d1) as leads
  )
  select jsonb_build_object(
    'mensagens_ia', coalesce(ac.mensagens_ia, 0),
    'tokens_in', coalesce(ac.tokens_in, 0),
    'tokens_out', coalesce(ac.tokens_out, 0),
    'tokens_usd', round(coalesce(ac.cost_usd, 0), 4),
    'tokens_brl', round(coalesce(ac.cost_usd, 0) * cambio.v, 2),
    'ads_dia_brl', round(ads_dia.brl, 2),
    'leads_no_dia', leads_dia.n,
    'ads_rateio_brl', case when leads_dia.n = 0 then 0 else round(ads_dia.brl / leads_dia.n, 2) end,
    'custo_lead_brl', round(coalesce(ac.cost_usd, 0) * cambio.v + case when leads_dia.n = 0 then 0 else ads_dia.brl / leads_dia.n end, 2),
    'mes', jsonb_build_object('de', mes.d0, 'ate', mes.d1, 'marketing_brl', round(mes_tot.brl, 2), 'leads', mes_tot.leads,
                              'custo_medio_lead_brl', case when mes_tot.leads = 0 then null else round(mes_tot.brl / mes_tot.leads, 2) end),
    'cambio_usd_brl', cambio.v
  )
  from l, cambio, ads_dia, leads_dia, mes, mes_tot
  left join ac on true;
$$;

-- Dossiê: 'cost' passa a ser lead_cost (contém os campos antigos + rateio + média do mês)

create or replace function public.lead_dossier(p_lead uuid)
returns jsonb
language sql stable
set search_path = public
as $$
  select jsonb_build_object(
    'lead', (select to_jsonb(l) from public.leads l where l.id = p_lead),
    'card', (select to_jsonb(v) from public.v_case_cards v where v.lead_id = p_lead),
    'contact', (select to_jsonb(ct) from public.contacts ct join public.leads l on l.contact_id = ct.id where l.id = p_lead),
    'conversations', (select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at), '[]'::jsonb) from public.conversations c where c.lead_id = p_lead),
    'case_data', (select to_jsonb(d) from public.case_data d where d.lead_id = p_lead),
    'qualification', (select to_jsonb(q) from public.lead_qualification q where q.lead_id = p_lead),
    'verbas', public.calc_verbas(p_lead),
    'evidences', (select coalesce(jsonb_agg(to_jsonb(e) order by e.created_at), '[]'::jsonb) from public.evidences e where e.lead_id = p_lead),
    'contract', (select to_jsonb(k) from public.contracts k where k.lead_id = p_lead and k.status in ('rascunho','enviado','assinado') limit 1),
    'briefing', (select to_jsonb(b) from public.briefings b where b.lead_id = p_lead),
    'pieces', (select coalesce(jsonb_agg(to_jsonb(p) order by p.created_at desc), '[]'::jsonb) from public.pieces p where p.lead_id = p_lead),
    'interventions', (select coalesce(jsonb_agg(to_jsonb(h) order by h.created_at desc), '[]'::jsonb) from public.human_interventions h where h.lead_id = p_lead),
    'tasks', (select coalesce(jsonb_agg(to_jsonb(t) order by t.due_at nulls last), '[]'::jsonb) from public.tasks t where t.lead_id = p_lead),
    'events', (select coalesce(jsonb_agg(
                 to_jsonb(ev) || jsonb_build_object('actor_name',
                   case ev.actor when 'humano' then coalesce(pr.full_name, 'Equipe')
                                 when 'ia' then coalesce(ag.name, 'IA')
                                 else 'Sistema' end)
                 order by ev.seq desc), '[]'::jsonb)
               from (select * from public.case_events where lead_id = p_lead order by seq desc limit 300) ev
               left join public.profiles pr on pr.user_id = ev.actor_user_id
               left join public.agents ag on ag.role = ev.actor_agent and ag.office_id is null),
    'members', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.user_id, 'role', m.role, 'full_name', pr.full_name)), '[]'::jsonb)
                from public.office_members m
                left join public.profiles pr on pr.user_id = m.user_id
                where m.office_id = (select office_id from public.leads where id = p_lead)),
    'cost', public.lead_cost(p_lead),
    'params', (select jsonb_build_object('alerta_prescricao_dias', p.alerta_prescricao_dias, 'ticket_minimo', p.ticket_minimo,
                                         'vinculo_minimo_meses', p.vinculo_minimo_meses, 'honorarios_percent', p.honorarios_percent)
               from public.office_params p where p.office_id = (select office_id from public.leads where id = p_lead))
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- Dashboard Investimento: tokens por dia vêm de marketing_tokens_por_dia (lançado > estimado)
create or replace function public.dashboard_investimento_p(p_office uuid, p_from date default null, p_to date default null)
returns jsonb
language sql stable
set search_path = public
as $$
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
    select t.dia, t.tokens_brl, t.tokens_usd from b, public.marketing_tokens_por_dia(p_office, b.p_start::date, (b.p_end - interval '1 day')::date) t
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
           coalesce(k.tokens_brl, 0) as tokens_brl,
           coalesce(a.brl, 0) + coalesce(k.tokens_brl, 0) as investimento_brl,
           coalesce(c.n, 0) as contratos,
           coalesce(p.n, 0) as protocolos
    from dias d
    cross join cambio
    left join ads a on a.dia = d.dia
    left join tk k on k.dia = d.dia
    left join ctr c on c.dia = d.dia
    left join prot p on p.dia = d.dia
  ),
  tot as (
    select sum(ads_brl) as ads, sum(tokens_brl) as tokens, sum(investimento_brl) as inv, sum(contratos) as contratos, sum(protocolos) as protocolos
    from linha
  )
  select jsonb_build_object(
    'periodo', jsonb_build_object('de', b.p_start::date, 'ate', (b.p_end - interval '1 day')::date),
    'cambio_usd_brl', (select v from cambio),
    'investimento_total_brl', (select round(inv, 2) from tot),
    'ads_brl', (select round(ads, 2) from tot),
    'tokens_brl', (select round(tokens, 2) from tot),
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
                    'dia', dia, 'ads_brl', ads_brl, 'tokens_brl', tokens_brl, 'investimento_brl', investimento_brl,
                    'contratos', contratos, 'custo_por_contrato_brl', case when contratos = 0 then null else round(investimento_brl / contratos, 2) end,
                    'protocolos', protocolos, 'custo_por_protocolo_brl', case when protocolos = 0 then null else round(investimento_brl / protocolos, 2) end
                  ) order by dia desc), '[]'::jsonb) from linha)
  )
  from b
  where public.is_office_member(p_office);
$$;

-- -----------------------------------------------------------------------------
-- 4. Importação automática (n8n, service_role)
-- -----------------------------------------------------------------------------

alter table public.integration_catalog drop constraint if exists integration_catalog_kind_check;
alter table public.integration_catalog add constraint integration_catalog_kind_check
  check (kind in ('mensageria','ads','assinatura','armazenamento','llm','llm_admin','transcricao','transcricao_admin'));

insert into public.integration_catalog (provider, kind, label, description, secret_label, config_fields, docs_url, ordem) values
  ('meta_ads', 'ads', 'Meta Ads', 'Importa o gasto diário da conta de anúncios para a página Marketing.', 'Token de acesso (Marketing API)',
   '[{"key":"ad_account_id","label":"ID da conta de anúncios","type":"text","placeholder":"act_123456789","required":true},{"key":"currency","label":"Moeda da conta","type":"text","placeholder":"BRL","required":false}]',
   'https://developers.facebook.com/docs/marketing-api/insights', 25)
on conflict (provider) do update set
  kind = excluded.kind, label = excluded.label, description = excluded.description,
  secret_label = excluded.secret_label, config_fields = excluded.config_fields, docs_url = excluded.docs_url, ordem = excluded.ordem;

-- Alvos da importação: integrações ativas com segredo. O n8n resolve o segredo com integration_secret().
create or replace function public.marketing_import_targets()
returns table (office_id uuid, provider text, config jsonb, cambio_usd_brl numeric)
language sql stable security definer set search_path = public as $$
  select i.office_id, i.provider, i.config, coalesce(p.cambio_usd_brl, 5.5)
  from public.integrations i
  left join public.office_params p on p.office_id = i.office_id
  where i.active and i.secret_name is not null and i.provider in ('meta_ads','anthropic_admin','openai_admin');
$$;

create or replace function public.marketing_import(
  p_office uuid, p_dia date, p_canal text, p_valor_brl numeric, p_valor_usd numeric default null, p_nota text default null)
returns void
language sql security definer set search_path = public as $$
  insert into public.ad_spend (office_id, dia, canal, valor, valor_usd, nota, origem)
  values (p_office, p_dia, p_canal, greatest(p_valor_brl, 0), p_valor_usd, p_nota, 'importado')
  on conflict (office_id, dia, canal) do update
    set valor = excluded.valor, valor_usd = excluded.valor_usd, nota = excluded.nota, origem = 'importado';
$$;

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant select on public.v_marketing_lancamentos to authenticated;
grant execute on function public.canal_tipo(text) to authenticated;
grant execute on function public.marketing_lancar(uuid, date, numeric, numeric, text) to authenticated;
grant execute on function public.marketing_remover(uuid, date) to authenticated;
grant execute on function public.marketing_tokens_por_dia(uuid, date, date) to authenticated;
grant execute on function public.marketing_resumo_p(uuid, date, date) to authenticated;
grant execute on function public.marketing_lancamentos_p(uuid, date, date) to authenticated;
grant execute on function public.lead_cost(uuid) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;
grant execute on function public.dashboard_investimento_p(uuid, date, date) to authenticated;

revoke execute on function public.marketing_import_targets() from public, anon, authenticated;
revoke execute on function public.marketing_import(uuid, date, text, numeric, numeric, text) from public, anon, authenticated;
grant execute on function public.marketing_import_targets() to service_role;
grant execute on function public.marketing_import(uuid, date, text, numeric, numeric, text) to service_role;
