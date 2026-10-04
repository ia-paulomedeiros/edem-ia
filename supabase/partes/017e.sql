-- =============================================================================
-- 017e — parte 5 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017d. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1b. Etiquetas na saída do agente: apply_agent_effects ganha p_tags (11º).
-- A versão de 10 parâmetros sai (a chamada com 10 continua valendo: p_tags tem default).
-- -----------------------------------------------------------------------------
drop function if exists public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb);
create or replace function public.apply_agent_effects(p_lead uuid, p_conversation uuid, p_agent_role text, p_case_data jsonb DEFAULT NULL::jsonb, p_advance_to text DEFAULT NULL::text, p_advance_reason text DEFAULT NULL::text, p_intervention jsonb DEFAULT NULL::jsonb, p_task jsonb DEFAULT NULL::jsonb, p_contract jsonb DEFAULT NULL::jsonb, p_briefing jsonb DEFAULT NULL::jsonb, p_tags jsonb DEFAULT NULL::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
  v_task uuid; k public.contracts; b public.briefings; pc public.pieces;
  v_role text;
  v_piece uuid;
  v_kind text;
  v_due timestamptz;
  t public.tags; v_tag text; v_tag_ok text[] := '{}'; v_tag_ign text[] := '{}';
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;
  v_role := coalesce(nullif(p_agent_role, ''), public.agent_for_lead(p_lead));

  if p_case_data is not null and jsonb_typeof(p_case_data) = 'object' and p_case_data <> '{}'::jsonb then
    insert into public.case_data (lead_id, office_id, updated_by_actor) values (p_lead, l.office_id, 'ia') on conflict (lead_id) do nothing;
    update public.case_data d set
      empresa               = coalesce(p_case_data->>'empresa', d.empresa),
      cargo                 = coalesce(p_case_data->>'cargo', d.cargo),
      admissao              = coalesce((p_case_data->>'admissao')::date, d.admissao),
      demissao              = coalesce((p_case_data->>'demissao')::date, d.demissao),
      salario               = coalesce((p_case_data->>'salario')::numeric, d.salario),
      tipo_rescisao         = coalesce(p_case_data->>'tipo_rescisao', d.tipo_rescisao),
      aviso_previo          = coalesce(p_case_data->>'aviso_previo', d.aviso_previo),
      ctps_assinada         = coalesce((p_case_data->>'ctps_assinada')::boolean, d.ctps_assinada),
      fgts_depositado       = coalesce((p_case_data->>'fgts_depositado')::boolean, d.fgts_depositado),
      ferias_vencidas       = coalesce((p_case_data->>'ferias_vencidas')::int, d.ferias_vencidas),
      horas_extras_semanais = coalesce((p_case_data->>'horas_extras_semanais')::numeric, d.horas_extras_semanais),
      verbas_pagas          = coalesce((p_case_data->>'verbas_pagas')::numeric, d.verbas_pagas),
      extras                = d.extras || coalesce(p_case_data->'extras', '{}'::jsonb),
      empresa_cnpj          = coalesce(p_case_data->>'empresa_cnpj', d.empresa_cnpj),
      motivo_saida          = coalesce(p_case_data->>'motivo_saida', d.motivo_saida),
      acidente_trabalho     = coalesce((p_case_data->>'acidente_trabalho')::boolean, d.acidente_trabalho),
      tem_caso              = coalesce((p_case_data->>'tem_caso')::boolean, d.tem_caso),
      objecao_principal     = coalesce(p_case_data->>'objecao_principal', d.objecao_principal),
      objecao_detalhe       = coalesce(p_case_data->>'objecao_detalhe', d.objecao_detalhe),
      updated_by_actor      = 'ia'
    where d.lead_id = p_lead;

    if p_case_data ? 'cpf' and not public.cpf_valido(p_case_data->>'cpf') then
      v_result := v_result || jsonb_build_object('cpf_invalido', true);
    end if;
    update public.contacts ct set
      cpf = case when public.cpf_valido(p_case_data->>'cpf') then public.cpf_formatado(p_case_data->>'cpf') else ct.cpf end,
      email = coalesce(p_case_data->>'email', ct.email),
      nascimento = coalesce((p_case_data->>'nascimento')::date, ct.nascimento), estado_civil = coalesce(p_case_data->>'estado_civil', ct.estado_civil),
      nacionalidade = coalesce(p_case_data->>'nacionalidade', ct.nacionalidade), endereco = coalesce(p_case_data->>'endereco', ct.endereco),
      cep = coalesce(p_case_data->>'cep', ct.cep), cidade = coalesce(p_case_data->>'cidade', ct.cidade), uf = coalesce(p_case_data->>'uf', ct.uf)
    where ct.id = l.contact_id;
    v_result := v_result || jsonb_build_object('case_data_updated', true);
  end if;

  if p_advance_to is not null and p_advance_to <> '' then
    if p_advance_to = 'encerrado' then
      l := public.close_lead_with_reason(p_lead, coalesce(nullif(p_advance_reason, ''), 'outro'), 'outro', null, 'ia', null, v_role);
      v_result := v_result || jsonb_build_object('phase', l.phase, 'closed_kind', l.closed_kind, 'closed_code', l.closed_code);
    elsif p_advance_to = 'revisao' then
      select id into v_piece from public.pieces where lead_id = p_lead and status = 'saneamento' order by created_at desc limit 1;
      if v_piece is not null then
        update public.pieces set status = 'revisao', generated_by_actor = 'ia', updated_at = now() where id = v_piece;
        perform public.log_event(l.office_id, p_lead, 'saneamento_concluido', 'ia', null, v_role,
          jsonb_build_object('piece_id', v_piece, 'reason', p_advance_reason), p_conversation);
        v_result := v_result || jsonb_build_object('piece_id', v_piece, 'piece_status', 'revisao');
      end if;
    elsif p_advance_to = 'peca' and l.phase = 'provas' then
      -- o Coletor terminou: vai para a peça e pede a geração (n8n 08)
      pc := public.request_piece_generation(p_lead, 'ia', null, v_role);
      v_result := v_result || jsonb_build_object('phase', 'peca', 'piece_id', pc.id, 'geracao', pc.geracao_status);
    else
      l := public.advance_phase(p_lead, p_advance_to::public.case_phase, 'ia', null, v_role, p_advance_reason);
      v_result := v_result || jsonb_build_object('phase', l.phase);
    end if;
  end if;

  if p_intervention is not null and jsonb_typeof(p_intervention) = 'object' then
    if jsonb_typeof(p_intervention->'tags') = 'array' then
      select array_agg(x) into v_tags from jsonb_array_elements_text(p_intervention->'tags') x;
    end if;
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', v_role,
           p_intervention->>'note', v_tags);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  if p_task is not null and jsonb_typeof(p_task) = 'object' and coalesce(p_task->>'title', '') <> '' then
    v_kind := case when p_task->>'kind' = 'agendamento' or (p_task ? 'due_at' and coalesce(p_task->>'kind', '') = '') then 'agendamento' else 'tarefa' end;
    v_due := coalesce((p_task->>'due_at')::timestamptz, (current_date + 1) + time '09:00');
    insert into public.tasks (office_id, lead_id, title, description, due_at, assigned_to, created_by_actor, kind, status, agent_role)
    values (l.office_id, p_lead, p_task->>'title', p_task->>'description', v_due, l.assigned_to, 'ia', v_kind, 'agendado', v_role)
    returning id into v_task;
    if v_kind = 'agendamento' then
      perform public.log_event(l.office_id, p_lead, 'agendamento_criado', 'ia', null, v_role,
        jsonb_build_object('task_id', v_task, 'due_at', v_due, 'description', coalesce(p_task->>'description', p_task->>'title'),
                           'texto', 'Agendamento criado para ' || to_char(v_due at time zone 'America/Sao_Paulo', 'DD/MM/YYYY HH24:MI')
                                    || ' — ' || coalesce(p_task->>'description', p_task->>'title')),
        p_conversation);
    end if;
    v_result := v_result || jsonb_build_object('task_id', v_task, 'task_kind', v_kind);
  end if;

  if p_contract is not null and jsonb_typeof(p_contract) = 'object' and p_contract->>'action' = 'send' then
    k := public.request_contract(p_lead, 'ia', null, (p_contract->>'honorarios_percent')::numeric);
    v_result := v_result || jsonb_build_object('contract_id', k.id);
  end if;

  if p_briefing is not null and jsonb_typeof(p_briefing) = 'object' and p_briefing <> '{}'::jsonb then
    b := public.upsert_briefing(p_lead, p_briefing, 'ia', null, coalesce(v_role, 'briefing'));
    v_result := v_result || jsonb_build_object('briefing_id', b.id, 'briefing_status', b.status);
  end if;

  -- 017: etiquetas. Só existentes e ativas; desconhecidas são ignoradas e
  -- registradas no ai_meta da última resposta da IA nesta conversa.
  if p_tags is not null and jsonb_typeof(p_tags) = 'array' and jsonb_array_length(p_tags) > 0 then
    for v_tag in select btrim(x) from jsonb_array_elements_text(p_tags) x where btrim(x) <> '' loop
      t := public.tag_find(l.office_id, v_tag);
      if t.id is not null and t.active then
        perform public.lead_tag_apply(p_lead, t, true, 'ia', null, v_role);
        v_tag_ok := array_append(v_tag_ok, t.name);
      else
        v_tag_ign := array_append(v_tag_ign, v_tag);
      end if;
    end loop;
    if cardinality(v_tag_ign) > 0 and p_conversation is not null then
      update public.messages m set ai_meta = coalesce(m.ai_meta, '{}'::jsonb) || jsonb_build_object('tags_ignoradas', to_jsonb(v_tag_ign))
       where m.id = (select m2.id from public.messages m2 where m2.conversation_id = p_conversation and m2.sender = 'ia'
                     order by m2.created_at desc limit 1);
    end if;
    v_result := v_result || jsonb_build_object('tags', to_jsonb(v_tag_ok), 'tags_ignoradas', to_jsonb(v_tag_ign));
  end if;

  return v_result || jsonb_build_object('agent_role', v_role);
end;
$$;

-- Contexto de etiquetas para o agente (WA 02 põe no prompt): as disponíveis e as do lead.
create or replace function public.agent_tags_context(p_lead uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'disponiveis', coalesce((select jsonb_agg(t.name order by t.name) from public.tags t where t.office_id = l.office_id and t.active), '[]'::jsonb),
    'do_lead', coalesce((select jsonb_agg(t.name order by t.name) from public.lead_tags lt join public.tags t on t.id = lt.tag_id where lt.lead_id = l.id), '[]'::jsonb))
  from public.leads l where l.id = p_lead;
$$;

-- Prompts padrão (globais): uma linha sobre etiquetas. Prompts próprios do
-- escritório não mudam; o formato de saída (com "tags" opcional) vem do WA 02.
update public.agent_prompts p
   set system_prompt = replace(p.system_prompt, '- Saída: SOMENTE o JSON no formato que o sistema pede.',
         '- Etiquetas: se a conversa deixar claro, devolva "tags" com nomes da lista de etiquetas disponíveis (ex.: "Urgente", "Indicação", "Estrangeiro"). Nunca invente etiqueta e nunca use etiqueta para indicar etapa.' || chr(10) ||
         '- Saída: SOMENTE o JSON no formato que o sistema pede.'),
       updated_at = now()
  from public.agents a
 where a.id = p.agent_id and a.office_id is null
   and p.system_prompt like '%- Saída: SOMENTE o JSON no formato que o sistema pede.%'
   and p.system_prompt not like '%- Etiquetas: se a conversa deixar claro%';

-- -----------------------------------------------------------------------------
-- 12. Modelos de petição editáveis pelo escritório
-- piece_templates continua interna (sem policy para o escritório). O escritório
-- edita por RPC: a edição vira uma linha própria (office_id, code) que sobrepõe
-- o padrão; restaurar apaga a sobreposição. Toda gravação gera uma versão.
-- -----------------------------------------------------------------------------
create table if not exists public.piece_template_versions (
  id        uuid primary key default gen_random_uuid(),
  office_id uuid not null references public.offices(id) on delete cascade,
  code      text not null,
  versao    int not null,
  acao      text not null default 'salvar' check (acao in ('salvar','restaurar')),
  name      text, tese text, kind text, body text, required boolean, ordem int, active boolean,
  saved_by  uuid references auth.users(id),
  saved_at  timestamptz not null default now(),
  unique (office_id, code, versao)
);
alter table public.piece_template_versions enable row level security;
drop policy if exists piece_template_versions_select on public.piece_template_versions;
create policy piece_template_versions_select on public.piece_template_versions for select to authenticated
  using (public.is_office_member(office_id) and public.member_role(office_id) in ('admin','advogado'));
-- escrita só pelas RPCs

-- Teses próprias do escritório: tese do briefing → código do modelo.
create table if not exists public.piece_tese_aliases (
  office_id uuid not null references public.offices(id) on delete cascade,
  tese      text not null,
  code      text not null,
  primary key (office_id, tese, code)
);
alter table public.piece_tese_aliases enable row level security;
drop policy if exists piece_tese_aliases_select on public.piece_tese_aliases;
create policy piece_tese_aliases_select on public.piece_tese_aliases for select to authenticated
  using (public.is_office_member(office_id));

create or replace function public.piece_tese_codes_office(p_office uuid, p_teses text[])
returns text[] language sql stable set search_path = public as $$
  select coalesce(array_agg(distinct c), '{}') from (
    select unnest(public.piece_tese_codes(p_teses)) as c
    union all
    select upper(a.code) from public.piece_tese_aliases a
    join unnest(coalesce(p_teses, '{}')) as u(tt) on lower(u.tt) = a.tese
    where a.office_id = p_office
  ) z where c is not null;
$$;

-- Modelo vigente por código (escritório sobrepõe o padrão; a sobreposição
-- inativa desliga o padrão para o escritório).
create or replace function public.piece_templates_vigentes(p_office uuid)
returns setof public.piece_templates language sql stable security definer set search_path = public as $$
  select distinct on (pt.code) pt.* from public.piece_templates pt
  where (pt.office_id = p_office or pt.office_id is null) and pt.code is not null
  order by pt.code, pt.office_id nulls last;
$$;

-- piece_render (016) com teses do escritório e sobreposição inativa. Mesma assinatura.
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
  v_codes := public.piece_tese_codes_office(pc.office_id, v_teses);

  with tpl as (
    select t.kind, t.code, t.ordem, t.body from public.piece_templates_vigentes(pc.office_id) t
    where t.active
      and ((t.kind = 'bloco' and t.required)
        or (t.kind = 'tese' and upper(t.code) = any (v_codes) and t.body not like '%{{cabecalho}}%'))
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

-- {{X}} usados no texto e os que o sistema não conhece ({{IA:...}} é campo da IA).
create or replace function public.modelo_placeholders(p_body text)
returns table(usados text[], desconhecidos text[]) language sql stable set search_path = public as $$
  with u as (select distinct x[1] as code from regexp_matches(coalesce(p_body, ''), '\{\{\s*([^{}]+?)\s*\}\}', 'g') x)
  select coalesce(array_agg(code order by code), '{}'),
         coalesce(array_agg(code order by code) filter (where code not like 'IA:%'
                    and not exists (select 1 from public.piece_placeholders p where p.code = u.code)), '{}')
  from u;
$$;

create or replace function public.modelos_guard(p_office uuid)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or coalesce(public.member_role(p_office), '') not in ('admin','advogado') then
    raise exception 'só admin ou advogado do escritório edita modelos';
  end if;
end; $$;

create or replace function public.ui_placeholders()
returns table(code text, fonte text, formato text, se_vazio text, descricao text, laquila boolean)
language sql stable security definer set search_path = public as $$
  select p.code, p.fonte, p.formato, p.se_vazio, p.descricao, p.laquila from public.piece_placeholders p order by p.laquila desc, p.code;
$$;

create or replace function public.ui_modelos(p_office uuid)
returns table(code text, name text, tese text, kind text, required boolean, ordem int, active boolean, body text, origem text,
              tem_padrao boolean, placeholders text[], desconhecidos text[], updated_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.modelos_guard(p_office);
  return query
  select t.code, t.name, t.tese, t.kind, t.required, t.ordem, t.active, t.body,
         case when t.office_id is null then 'padrao' else 'escritorio' end,
         exists (select 1 from public.piece_templates g where g.office_id is null and g.code = t.code),
         mp.usados, mp.desconhecidos, t.updated_at
  from public.piece_templates_vigentes(p_office) t
  cross join lateral public.modelo_placeholders(t.body) mp
  order by t.kind, t.ordem, t.code;
end; $$;

create or replace function public.modelo_versionar(p_office uuid, p_code text, p_acao text)
returns int language plpgsql security definer set search_path = public as $$
declare t public.piece_templates; v int;
begin
  select * into t from public.piece_templates_vigentes(p_office) x where x.code = p_code;
  select coalesce(max(versao), 0) + 1 into v from public.piece_template_versions where office_id = p_office and code = p_code;
  insert into public.piece_template_versions (office_id, code, versao, acao, name, tese, kind, body, required, ordem, active, saved_by)
  values (p_office, p_code, v, p_acao, t.name, t.tese, t.kind, t.body, t.required, t.ordem, t.active, auth.uid());
  return v;
end; $$;

create or replace function public.ui_modelo_salvar(p_office uuid, p_code text, p_name text, p_tese text, p_kind text, p_body text,
                                                   p_required boolean default null, p_ordem int default null, p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_code text := upper(regexp_replace(btrim(coalesce(p_code, '')), '[^A-Za-z0-9_]+', '_', 'g'));
  g public.piece_templates; o public.piece_templates; v_novo boolean; v int; mp record; v_tese text;
begin
  perform public.modelos_guard(p_office);
  if v_code = '' then raise exception 'informe o código do modelo'; end if;
  if coalesce(btrim(p_body), '') = '' then raise exception 'o texto do modelo está vazio'; end if;
  select * into g from public.piece_templates where office_id is null and code = v_code;
  select * into o from public.piece_templates where office_id = p_office and code = v_code;
  v_novo := g.id is null and o.id is null;
  if coalesce(p_kind, g.kind, o.kind, 'tese') not in ('tese','bloco') then raise exception 'tipo inválido: use tese ou bloco'; end if;
  v_tese := lower(btrim(coalesce(nullif(btrim(p_tese), ''), o.tese, g.tese, v_code)));

  if o.id is null then
    insert into public.piece_templates (office_id, code, name, tese, kind, body, required, ordem, active, required_evidence)
    values (p_office, v_code, coalesce(nullif(btrim(p_name), ''), g.name, v_code), v_tese, coalesce(p_kind, g.kind, 'tese'), p_body,
            coalesce(p_required, g.required, false), coalesce(p_ordem, g.ordem, 100), coalesce(p_active, true),
            coalesce(g.required_evidence, '[]'::jsonb))
    returning * into o;
  else
    update public.piece_templates
       set name = coalesce(nullif(btrim(p_name), ''), name), tese = v_tese, kind = coalesce(p_kind, kind), body = p_body,
           required = coalesce(p_required, required), ordem = coalesce(p_ordem, ordem), active = coalesce(p_active, active), updated_at = now()
     where id = o.id returning * into o;
  end if;

  if o.kind = 'tese' and g.id is null then
    insert into public.piece_tese_aliases (office_id, tese, code) values (p_office, v_tese, v_code) on conflict do nothing;
  end if;
  v := public.modelo_versionar(p_office, v_code, 'salvar');
  select * into mp from public.modelo_placeholders(p_body);
  return jsonb_build_object('ok', true, 'code', v_code, 'origem', 'escritorio', 'novo', v_novo, 'versao', v,
    'placeholders', to_jsonb(mp.usados), 'desconhecidos', to_jsonb(mp.desconhecidos),
    'avisos', (select coalesce(jsonb_agg('Placeholder desconhecido: {{' || d || '}} (vai sair como está na peça)'), '[]'::jsonb)
                 from unnest(mp.desconhecidos) d));
end; $$;

create or replace function public.ui_modelo_restaurar(p_office uuid, p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare g public.piece_templates; o public.piece_templates; v int;
begin
  perform public.modelos_guard(p_office);
  select * into g from public.piece_templates where office_id is null and code = upper(p_code);
  select * into o from public.piece_templates where office_id = p_office and code = upper(p_code);
  if o.id is null then return jsonb_build_object('ok', true, 'code', upper(p_code), 'origem', 'padrao', 'alterado', false); end if;
  if g.id is null then raise exception 'modelo próprio do escritório, sem padrão para restaurar: desative-o'; end if;
  update public.pieces set template_id = g.id where template_id = o.id;
  delete from public.piece_templates where id = o.id;
  v := public.modelo_versionar(p_office, g.code, 'restaurar');
  return jsonb_build_object('ok', true, 'code', g.code, 'origem', 'padrao', 'alterado', true, 'versao', v);
end; $$;

create or replace function public.ui_modelo_versoes(p_office uuid, p_code text)
returns table(versao int, acao text, name text, tese text, kind text, body text, required boolean, ordem int, active boolean,
              saved_by uuid, saved_by_nome text, saved_at timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.modelos_guard(p_office);
  return query
  select v.versao, v.acao, v.name, v.tese, v.kind, v.body, v.required, v.ordem, v.active, v.saved_by,
         case when v.saved_by is not null then public.user_nome(v.saved_by) end, v.saved_at
  from public.piece_template_versions v where v.office_id = p_office and v.code = upper(p_code)
  order by v.versao desc;
end; $$;

-- ---------- Verificação da parte 017e: deve voltar uma linha com resultado = OK
select '017e' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função agent_tags_context', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'agent_tags_context')),
    ('função apply_agent_effects', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'apply_agent_effects')),
    ('função modelo_placeholders', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'modelo_placeholders')),
    ('função modelo_versionar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'modelo_versionar')),
    ('função modelos_guard', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'modelos_guard')),
    ('função piece_render', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_render')),
    ('função piece_templates_vigentes', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_templates_vigentes')),
    ('função piece_tese_codes_office', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_tese_codes_office')),
    ('função ui_modelo_restaurar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_restaurar')),
    ('função ui_modelo_salvar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_salvar')),
    ('função ui_modelo_versoes', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_versoes')),
    ('função ui_modelos', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelos')),
    ('função ui_placeholders', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_placeholders')),
    ('tabela piece_template_versions', to_regclass('public.piece_template_versions') is not null),
    ('tabela piece_tese_aliases', to_regclass('public.piece_tese_aliases') is not null)
) as v(item, ok);
