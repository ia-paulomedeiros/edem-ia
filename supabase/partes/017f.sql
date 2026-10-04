-- =============================================================================
-- 017f — parte 6 de 6 de supabase/017_mensageria.sql
-- GERADA por supabase/tools/split_migrations.py; não edite (edite o arquivo canônico).
-- Rode depois de: 017e. Idempotente: pode rodar de novo sem estragar nada.
-- No SQL Editor: Cmd+A, Run. Se aparecer o aviso de operação destrutiva (drop de
-- função/constraint antiga que esta parte recria), confirme. A última linha do
-- resultado tem que dizer resultado = OK.
-- =============================================================================

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
    ('função offices_after_insert', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'offices_after_insert')),
    ('função seed_office_defaults', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'seed_office_defaults')),
    ('função ui_modelo_preview', exists (select 1 from pg_proc where pronamespace = 'public'::regnamespace and proname = 'ui_modelo_preview'))
) as v(item, ok);
