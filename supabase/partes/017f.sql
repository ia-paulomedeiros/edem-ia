-- =============================================================================
-- 017f — parte 6 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017e. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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

-- Prévia com os dados de um lead do escritório; o que faltar sai [PREENCHER: X].
create or replace function public.ui_modelo_preview(p_office uuid, p_code text, p_lead uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t public.piece_templates; v_out text;
begin
  perform public.modelos_guard(p_office);
  if not exists (select 1 from public.leads l where l.id = p_lead and l.office_id = p_office) then raise exception 'caso não encontrado'; end if;
  select * into t from public.piece_templates_vigentes(p_office) x where x.code = upper(p_code);
  if t.id is null then raise exception 'modelo não encontrado: %', p_code; end if;
  v_out := public.piece_fill_text(t.body, public.piece_fill_context(p_lead));
  v_out := regexp_replace(v_out, '\{\{\s*(IA:)?([^{}]+?)\s*\}\}', '[PREENCHER: \2]', 'g');
  return jsonb_build_object('code', t.code, 'origem', case when t.office_id is null then 'padrao' else 'escritorio' end,
    'texto', v_out,
    'faltando', (select coalesce(jsonb_agg(distinct x[1]), '[]'::jsonb) from regexp_matches(v_out, '\[PREENCHER: ([^\]]+)\]', 'g') x));
end; $$;

-- -----------------------------------------------------------------------------
-- Seed por escritório (novo e existentes): etiquetas, departamentos, expediente,
-- templates. Só semeia o que o escritório ainda não tem.
-- -----------------------------------------------------------------------------
create or replace function public.seed_office_defaults(p_office uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.tags where office_id = p_office) then
    insert into public.tags (office_id, name, color, description, kind) values
      (p_office, 'Urgente',     '#DC2626', 'Precisa de atenção rápida', 'sistema'),
      (p_office, 'Indicação',   '#16A34A', 'Chegou por indicação', 'sistema'),
      (p_office, 'Reincidente', '#9333EA', 'Já foi atendido antes', 'sistema'),
      (p_office, 'Remarketing', '#EA580C', 'Retomado por campanha', 'sistema'),
      (p_office, 'Estrangeiro', '#0891B2', 'Trabalhador estrangeiro', 'sistema'),
      (p_office, 'Cliente VIP', '#CA8A04', 'Atendimento prioritário', 'sistema')
    on conflict do nothing;
  end if;
  if not exists (select 1 from public.departments where office_id = p_office) then
    insert into public.departments (office_id, name, color, ai_default) values
      (p_office, 'Triagem IA', '#2563EB', true),
      (p_office, 'Advogado',   '#0F766E', false)
    on conflict do nothing;
  end if;
  if not exists (select 1 from public.office_hours where office_id = p_office) then
    insert into public.office_hours (office_id, weekday, start_at, end_at)
    select p_office, d, '08:00', '18:00' from generate_series(1, 5) d
    on conflict do nothing;
  end if;
  insert into public.wa_templates (office_id, name, language, category, body, params, status) values
    (p_office, 'edem_followup', 'pt_BR', 'UTILITY',
     'Olá, {{1}}! Aqui é do {{2}}. Estamos dando continuidade ao seu atendimento. Podemos seguir com a conversa por aqui?', 2, 'pendente'),
    (p_office, 'edem_lembrete_documentos', 'pt_BR', 'UTILITY',
     'Olá, {{1}}! O {{2}} lembra que ainda faltam alguns documentos para darmos andamento ao seu caso. Pode enviá-los por aqui quando puder?', 2, 'pendente'),
    (p_office, 'edem_aviso_contrato', 'pt_BR', 'UTILITY',
     'Olá, {{1}}! O {{2}} enviou o contrato para sua assinatura digital. Se tiver qualquer dúvida, é só responder esta mensagem.', 2, 'pendente')
  on conflict (office_id, name, language) do nothing;
end; $$;

create or replace function public.offices_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.office_params (office_id) values (new.id) on conflict do nothing;
  perform public.seed_office_defaults(new.id);
  return new;
end; $$;

select public.seed_office_defaults(o.id) from public.offices o;

-- Conversas existentes sem departamento: IA ativa → Triagem IA; pausada → Advogado.
update public.conversations c
   set department_id = (select d.id from public.departments d
                         where d.office_id = c.office_id and d.active
                           and (case when c.ai_paused then not d.ai_default else d.ai_default end)
                         order by d.created_at limit 1)
 where c.department_id is null;

-- -----------------------------------------------------------------------------
-- Permissões. O 010 concede authenticated em tudo; aqui o que é só do n8n volta
-- para service_role.
-- -----------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.mensageria_envio(uuid)',
    'public.mensageria_destino(uuid)',
    'public.scheduled_dispatch(integer)',
    'public.templates_sync_targets()',
    'public.templates_sync_apply(uuid, jsonb)',
    'public.templates_pending_submit()',
    'public.template_submit_payload(uuid)',
    'public.template_submitted(uuid, text, text, text)',
    'public.lead_set_referral(uuid, jsonb, boolean)',
    'public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb, jsonb)',
    'public.agent_tags_context(uuid)',
    'public.lead_tag_apply(uuid, public.tags, boolean, text, uuid, text)',
    'public.conversation_event(uuid, text, text, text, uuid, jsonb, text)',
    'public.notify(uuid, text, jsonb)',
    'public.conversation_recipients(uuid)',
    'public.quick_reply_fill(text, uuid, uuid)',
    'public.seed_office_defaults(uuid)',
    'public.modelo_versionar(uuid, text, text)',
    'public.piece_templates_vigentes(uuid)'
  ] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;

-- ---------- Verificação da parte 017f: deve voltar uma linha com resultado = OK
select '017f' as parte,
       case when bool_and(ok) then 'OK' else 'FALTOU: ' || string_agg(item, ', ') filter (where not ok) end as resultado,
       count(*) filter (where ok) || ' de ' || count(*) || ' itens' as conferidos
from (values
    ('função modelo_placeholders', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'modelo_placeholders')),
    ('função modelo_versionar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'modelo_versionar')),
    ('função modelos_guard', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'modelos_guard')),
    ('função offices_after_insert', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'offices_after_insert')),
    ('função piece_render', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_render')),
    ('função piece_templates_vigentes', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_templates_vigentes')),
    ('função piece_tese_codes_office', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'piece_tese_codes_office')),
    ('função seed_office_defaults', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'seed_office_defaults')),
    ('função ui_modelo_preview', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_preview')),
    ('função ui_modelo_restaurar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_restaurar')),
    ('função ui_modelo_salvar', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_salvar')),
    ('função ui_modelo_versoes', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_versoes')),
    ('função ui_modelos', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelos')),
    ('função ui_placeholders', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_placeholders')),
    ('tabela piece_template_versions', to_regclass('public.piece_template_versions') is not null),
    ('tabela piece_tese_aliases', to_regclass('public.piece_tese_aliases') is not null)
) as v(item, ok);
