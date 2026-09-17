-- =============================================================================
-- 008_configuracoes.sql — Sprint 3: Configurações no layout do concorrente
--
-- 1. Empresa: dados cadastrais do escritório (CNPJ, OAB, fundador, endereço,
--    e-mail, telefone, WhatsApp comercial, telefone do suporte) e do perfil.
-- 2. Integrações por provedor (mensageria, assinatura, armazenamento, LLM,
--    transcrição). O segredo vai para o Vault; a tabela guarda só o nome.
--    Só RPCs escrevem (admin); o cliente nunca lê o segredo. O n8n resolve
--    com service_role e registra o resultado do teste.
-- 3. Modelos de petição = biblioteca de arquivos do escritório (bucket
--    'modelos'), sem limite de quantidade, com ATIVO e OBRIGATÓRIO.
-- 4. Prompts dos agentes e esqueletos internos ficam fora do alcance do
--    cliente: agents.system_prompt vai para agent_prompts (sem policy) e
--    piece_templates perde as policies. Só service_role (n8n) lê.
--
-- Idempotente. Rodar depois de 007.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Empresa e perfil
-- -----------------------------------------------------------------------------

alter table public.offices
  add column if not exists tipo               text not null default 'escritorio' check (tipo in ('escritorio','autonomo','departamento')),
  add column if not exists cnpj               text,
  add column if not exists oab_responsavel    text,
  add column if not exists fundador           text,
  add column if not exists fundacao           date,
  add column if not exists endereco           text,
  add column if not exists cidade             text,
  add column if not exists uf                 text,
  add column if not exists email              text,
  add column if not exists telefone           text,
  add column if not exists whatsapp_comercial text,
  add column if not exists telefone_suporte   text,
  add column if not exists site               text,
  add column if not exists logo_path          text,
  add column if not exists updated_at         timestamptz not null default now();

drop trigger if exists offices_touch on public.offices;
create trigger offices_touch before update on public.offices
  for each row execute function public.touch_updated_at();

alter table public.profiles
  add column if not exists phone text,
  add column if not exists oab   text,
  add column if not exists cargo text;

-- -----------------------------------------------------------------------------
-- 2. Integrações
-- -----------------------------------------------------------------------------

-- Catálogo (global): o que a tela de Integrações oferece e que campos avançados cada um tem.
create table if not exists public.integration_catalog (
  provider      text primary key,
  kind          text not null check (kind in ('mensageria','assinatura','armazenamento','llm','llm_admin','transcricao','transcricao_admin')),
  label         text not null,
  description   text not null default '',
  secret_label  text not null default 'Chave de API',
  config_fields jsonb not null default '[]'::jsonb,   -- [{key,label,type,placeholder,required}]
  docs_url      text,
  ordem         int not null default 100
);

insert into public.integration_catalog (provider, kind, label, description, secret_label, config_fields, docs_url, ordem) values
  ('meta_whatsapp', 'mensageria', 'WhatsApp Cloud API (Meta)', 'Número oficial do WhatsApp Business. Recebe e envia as mensagens dos leads.', 'Token permanente do sistema',
   '[{"key":"phone_number_id","label":"Phone number ID","type":"text","required":true},{"key":"waba_id","label":"WABA ID","type":"text","required":false},{"key":"display_phone","label":"Número exibido","type":"text","placeholder":"5511999999999","required":false}]',
   'https://developers.facebook.com/docs/whatsapp/cloud-api', 10),
  ('datacrazy', 'mensageria', 'Datacrazy', 'Mensageria alternativa por API. Uma mensageria ativa por vez.', 'Chave de API',
   '[{"key":"instance_url","label":"URL da instância","type":"url","required":true},{"key":"instance_name","label":"Nome da instância","type":"text","required":false}]',
   null, 20),
  ('autentique', 'assinatura', 'Autentique', 'Assinatura eletrônica do contrato de honorários.', 'Token da API',
   '[{"key":"sandbox","label":"Ambiente de testes","type":"boolean","required":false}]',
   'https://docs.autentique.com.br', 30),
  ('google_drive', 'armazenamento', 'Google Drive / Docs', 'Pasta do escritório para contratos, peças e provas exportadas.', 'Credencial (JSON da conta de serviço ou refresh token)',
   '[{"key":"folder_id","label":"ID da pasta raiz","type":"text","required":true}]',
   'https://developers.google.com/drive', 40),
  ('anthropic', 'llm', 'Anthropic', 'Modelo dos agentes de atendimento.', 'Chave de API',
   '[{"key":"model","label":"Modelo padrão","type":"text","placeholder":"claude-sonnet-5","required":false}]',
   'https://docs.anthropic.com', 50),
  ('anthropic_admin', 'llm_admin', 'Anthropic Admin', 'Chave administrativa para ler uso e custo por token.', 'Admin API key',
   '[]', 'https://docs.anthropic.com', 60),
  ('openai_whisper', 'transcricao', 'OpenAI Whisper', 'Transcrição dos áudios recebidos no WhatsApp.', 'Chave de API',
   '[{"key":"model","label":"Modelo","type":"text","placeholder":"whisper-1","required":false},{"key":"language","label":"Idioma","type":"text","placeholder":"pt","required":false}]',
   'https://platform.openai.com/docs', 70),
  ('openai_admin', 'transcricao_admin', 'OpenAI Admin', 'Chave administrativa para ler uso e custo da transcrição.', 'Admin API key',
   '[]', 'https://platform.openai.com/docs', 80)
on conflict (provider) do update set
  kind = excluded.kind, label = excluded.label, description = excluded.description,
  secret_label = excluded.secret_label, config_fields = excluded.config_fields, docs_url = excluded.docs_url, ordem = excluded.ordem;

create table if not exists public.integrations (
  id                 uuid primary key default gen_random_uuid(),
  office_id          uuid not null references public.offices(id) on delete cascade,
  provider           text not null references public.integration_catalog(provider),
  kind               text not null,
  active             boolean not null default false,
  -- Nome do segredo no Vault (vault.secrets.name). O valor NUNCA passa por aqui.
  secret_name        text,
  secret_set_at      timestamptz,
  config             jsonb not null default '{}'::jsonb,
  status             text not null default 'nao_testado' check (status in ('nao_testado','teste_solicitado','validado','falhou')),
  test_requested_at  timestamptz,
  tested_at          timestamptz,
  last_error         text,
  updated_by         uuid references auth.users(id),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (office_id, provider)
);
create index if not exists integrations_office_idx on public.integrations(office_id, kind);
-- Uma mensageria e uma assinatura ativas por escritório.
create unique index if not exists integrations_one_active_uidx
  on public.integrations (office_id, kind) where active and kind in ('mensageria','assinatura');
drop trigger if exists integrations_touch on public.integrations;
create trigger integrations_touch before update on public.integrations
  for each row execute function public.touch_updated_at();

-- Projeção pública da integração (sem nome nem valor do segredo).
create or replace function public.integration_public(i public.integrations)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'id', i.id, 'office_id', i.office_id, 'provider', i.provider, 'kind', i.kind,
    'active', i.active, 'has_secret', i.secret_name is not null, 'secret_set_at', i.secret_set_at,
    'config', i.config, 'status', i.status, 'tested_at', i.tested_at, 'last_error', i.last_error,
    'updated_at', i.updated_at);
$$;

create or replace function public.integration_secret_name(p_office uuid, p_provider text)
returns text language sql immutable as $$
  select 'int_' || p_provider || '_' || replace(p_office::text, '-', '');
$$;

-- Salvar (admin): cria/atualiza a integração; segredo vai para o Vault.
create or replace function public.set_integration(
  p_office uuid, p_provider text, p_secret text default null, p_config jsonb default null, p_active boolean default null)
returns jsonb
language plpgsql security definer set search_path = public, vault
as $$
declare
  v_kind text; v_name text; v_vault uuid; i public.integrations;
begin
  if public.member_role(p_office) is distinct from 'admin' then
    raise exception 'apenas admin do escritório altera integrações' using errcode = '42501';
  end if;
  select kind into v_kind from public.integration_catalog where provider = p_provider;
  if v_kind is null then raise exception 'provedor desconhecido: %', p_provider; end if;

  insert into public.integrations (office_id, provider, kind, updated_by)
  values (p_office, p_provider, v_kind, auth.uid())
  on conflict (office_id, provider) do update set updated_by = auth.uid()
  returning * into i;

  if p_secret is not null and length(trim(p_secret)) > 0 then
    v_name := public.integration_secret_name(p_office, p_provider);
    select id into v_vault from vault.secrets where name = v_name;
    if v_vault is null then
      perform vault.create_secret(p_secret, v_name, 'integração ' || p_provider || ' do escritório ' || p_office::text);
    else
      perform vault.update_secret(v_vault, p_secret);
    end if;
    update public.integrations set secret_name = v_name, secret_set_at = now(), status = 'nao_testado', last_error = null
     where id = i.id;
  end if;

  if p_config is not null then
    update public.integrations set config = p_config where id = i.id;
  end if;

  if p_active is not null then
    if p_active and v_kind in ('mensageria','assinatura') then
      update public.integrations set active = false where office_id = p_office and kind = v_kind and id <> i.id and active;
    end if;
    update public.integrations set active = p_active where id = i.id;
  end if;

  select * into i from public.integrations where id = i.id;

  -- Meta: o número passa a apontar para este segredo (whatsapp_numbers continua a fonte do webhook)
  if p_provider = 'meta_whatsapp' and i.secret_name is not null and coalesce(i.config->>'phone_number_id', '') <> '' then
    insert into public.whatsapp_numbers (office_id, phone_number_id, waba_id, display_phone, token_secret_name, active)
    values (p_office, i.config->>'phone_number_id', i.config->>'waba_id', i.config->>'display_phone', i.secret_name, i.active)
    on conflict (phone_number_id) do update set
      office_id = excluded.office_id, waba_id = coalesce(excluded.waba_id, public.whatsapp_numbers.waba_id),
      display_phone = coalesce(excluded.display_phone, public.whatsapp_numbers.display_phone),
      token_secret_name = excluded.token_secret_name, active = excluded.active;
  end if;

  return public.integration_public(i);
end; $$;

-- Remover (admin): apaga a linha e o segredo do Vault.
create or replace function public.remove_integration(p_office uuid, p_provider text)
returns void
language plpgsql security definer set search_path = public, vault
as $$
declare i public.integrations;
begin
  if public.member_role(p_office) is distinct from 'admin' then
    raise exception 'apenas admin do escritório altera integrações' using errcode = '42501';
  end if;
  select * into i from public.integrations where office_id = p_office and provider = p_provider;
  if i.id is null then return; end if;
  if i.secret_name is not null then
    update public.whatsapp_numbers set active = false where office_id = p_office and token_secret_name = i.secret_name;
    delete from vault.secrets where name = i.secret_name;
  end if;
  delete from public.integrations where id = i.id;
end; $$;

-- Testar (admin): marca o pedido; o n8n (webhook em integrations UPDATE) executa e responde.
create or replace function public.request_integration_test(p_office uuid, p_provider text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
  if public.member_role(p_office) is distinct from 'admin' then
    raise exception 'apenas admin do escritório altera integrações' using errcode = '42501';
  end if;
  update public.integrations set status = 'teste_solicitado', test_requested_at = now(), last_error = null
   where office_id = p_office and provider = p_provider and secret_name is not null
  returning id into v_id;
  if v_id is null then raise exception 'salve o segredo antes de testar'; end if;
  return v_id;
end; $$;

-- Resultado do teste (n8n, service_role).
create or replace function public.integration_tested(p_id uuid, p_ok boolean, p_error text default null)
returns void
language sql security definer set search_path = public
as $$
  update public.integrations
     set status = case when p_ok then 'validado' else 'falhou' end,
         tested_at = now(), last_error = case when p_ok then null else left(p_error, 500) end
   where id = p_id;
$$;

-- Segredo em claro (n8n, service_role). Nunca para o cliente.
create or replace function public.integration_secret(p_office uuid, p_provider text)
returns text
language sql stable security definer set search_path = public, vault
as $$
  select d.decrypted_secret
  from public.integrations i
  join vault.decrypted_secrets d on d.name = i.secret_name
  where i.office_id = p_office and i.provider = p_provider;
$$;

-- Provedor ativo de um tipo (UI e n8n).
create or replace function public.active_integration(p_office uuid, p_kind text)
returns text language sql stable set search_path = public as $$
  select provider from public.integrations where office_id = p_office and kind = p_kind and active
  order by updated_at desc limit 1;
$$;

-- -----------------------------------------------------------------------------
-- 3. Modelos de petição: biblioteca de arquivos
-- -----------------------------------------------------------------------------

create table if not exists public.piece_models (
  id           uuid primary key default gen_random_uuid(),
  office_id    uuid not null references public.offices(id) on delete cascade,
  name         text not null,
  category     text not null default 'geral',      -- 'geral' ou a tese (verbas_rescisorias, horas_extras, ...)
  description  text,
  file_path    text not null,                      -- bucket 'modelos': <office_id>/<uuid>-<arquivo>
  mime_type    text,
  size_bytes   bigint,
  required     boolean not null default false,     -- OBRIGATÓRIO: entra em toda peça
  active       boolean not null default true,      -- ATIVO
  uploaded_by  uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists piece_models_office_idx on public.piece_models(office_id, active, category);
drop trigger if exists piece_models_touch on public.piece_models;
create trigger piece_models_touch before update on public.piece_models
  for each row execute function public.touch_updated_at();

-- Modelos que entram numa peça: os obrigatórios + os da tese (+ 'geral' quando a tese não tem nenhum).
create or replace function public.piece_models_for(p_office uuid, p_tese text)
returns setof public.piece_models
language sql stable set search_path = public as $$
  select * from public.piece_models
  where office_id = p_office and active
    and (required or category = p_tese
         or (category = 'geral' and not exists (select 1 from public.piece_models m2 where m2.office_id = p_office and m2.active and m2.category = p_tese)))
  order by required desc, name;
$$;

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'storage')
     and exists (select 1 from pg_tables where schemaname = 'storage' and tablename = 'buckets') then
    insert into storage.buckets (id, name, public) values ('modelos', 'modelos', false) on conflict (id) do nothing;
    execute 'drop policy if exists modelos_select on storage.objects';
    execute $p$create policy modelos_select on storage.objects for select to authenticated
      using (bucket_id = 'modelos' and public.is_office_member((storage.foldername(name))[1]::uuid))$p$;
    execute 'drop policy if exists modelos_insert on storage.objects';
    execute $p$create policy modelos_insert on storage.objects for insert to authenticated
      with check (bucket_id = 'modelos' and public.member_role((storage.foldername(name))[1]::uuid) in ('admin','advogado'))$p$;
    execute 'drop policy if exists modelos_update on storage.objects';
    execute $p$create policy modelos_update on storage.objects for update to authenticated
      using (bucket_id = 'modelos' and public.member_role((storage.foldername(name))[1]::uuid) in ('admin','advogado'))$p$;
    execute 'drop policy if exists modelos_delete on storage.objects';
    execute $p$create policy modelos_delete on storage.objects for delete to authenticated
      using (bucket_id = 'modelos' and public.member_role((storage.foldername(name))[1]::uuid) in ('admin','advogado'))$p$;
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- 4. Prompts e esqueletos internos fora do alcance do cliente
-- -----------------------------------------------------------------------------

create table if not exists public.agent_prompts (
  agent_id      uuid primary key references public.agents(id) on delete cascade,
  system_prompt text not null default '',
  updated_at    timestamptz not null default now()
);

-- migra o que existir na coluna antiga e a remove
do $$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'agents' and column_name = 'system_prompt') then
    insert into public.agent_prompts (agent_id, system_prompt)
    select id, system_prompt from public.agents
    on conflict (agent_id) do update set system_prompt = excluded.system_prompt;
    alter table public.agents drop column system_prompt;
  end if;
end $$;
insert into public.agent_prompts (agent_id) select id from public.agents on conflict do nothing;

-- Config completa do agente (n8n): linha de agents + prompt. Service_role apenas.
create or replace function public.agent_config_full(p_office uuid, p_phase public.case_phase)
returns jsonb
language sql stable security definer set search_path = public as $$
  -- override do escritório sem prompt próprio herda o prompt do agente global do mesmo papel
  select to_jsonb(a) || jsonb_build_object('system_prompt',
           coalesce(nullif(p.system_prompt, ''),
                    (select g.system_prompt from public.agents ga join public.agent_prompts g on g.agent_id = ga.id
                      where ga.office_id is null and ga.role = a.role),
                    ''))
  from public.agent_config(p_office, p_phase) a
  left join public.agent_prompts p on p.agent_id = a.id;
$$;

-- RLS ligado e sem policy = invisível para o cliente; service_role passa por cima.
alter table public.agent_prompts enable row level security;
drop policy if exists piece_templates_select on public.piece_templates;
drop policy if exists piece_templates_write on public.piece_templates;
alter table public.piece_templates enable row level security;

-- -----------------------------------------------------------------------------
-- RLS e grants
-- -----------------------------------------------------------------------------

alter table public.integration_catalog enable row level security;
drop policy if exists integration_catalog_select on public.integration_catalog;
create policy integration_catalog_select on public.integration_catalog for select to authenticated using (true);

-- integrations: membros leem (sem segredo); escrita só pelas RPCs acima
alter table public.integrations enable row level security;
drop policy if exists integrations_select on public.integrations;
create policy integrations_select on public.integrations for select to authenticated
  using (public.is_office_member(office_id));
drop policy if exists integrations_insert on public.integrations;
drop policy if exists integrations_update on public.integrations;
drop policy if exists integrations_delete on public.integrations;

select public.apply_office_rls('piece_models', array['admin','advogado']);

grant execute on function public.set_integration(uuid, text, text, jsonb, boolean) to authenticated;
grant execute on function public.remove_integration(uuid, text) to authenticated;
grant execute on function public.request_integration_test(uuid, text) to authenticated;
grant execute on function public.active_integration(uuid, text) to authenticated;
grant execute on function public.piece_models_for(uuid, text) to authenticated;
grant execute on function public.integration_public(public.integrations) to authenticated;

revoke execute on function public.integration_secret(uuid, text) from public, anon, authenticated;
revoke execute on function public.integration_tested(uuid, boolean, text) from public, anon, authenticated;
revoke execute on function public.agent_config_full(uuid, public.case_phase) from public, anon, authenticated;
grant execute on function public.integration_secret(uuid, text) to service_role;
grant execute on function public.integration_tested(uuid, boolean, text) to service_role;
grant execute on function public.agent_config_full(uuid, public.case_phase) to service_role;
