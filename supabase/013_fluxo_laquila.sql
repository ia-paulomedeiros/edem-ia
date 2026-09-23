-- =============================================================================
-- 013_fluxo_laquila.sql — Sprint 4: o fluxo do concorrente, ponta a ponta
--
-- 1. Ordem das fases: Closer (novo, triagem, qualificacao, contrato) → Entrevista
--    (briefing) → Viabilidade (calculo) → Coleta de docs (provas) → Peça (peca,
--    com Saneamento/Revisão/Peça pela etapa da peça). Contrato ANTES de provas e
--    cálculo. phase_order, journey_stages, workflow_columns, v_workflow_cards,
--    ui_move_to_column.
-- 2. Petição: versão, qualidade, resumo executivo, documentos a anexar, link do
--    documento editável, checklist de revisão (7 itens), aprovada por/em,
--    protocolar com número do processo.
-- 3. Modelos de petição são internos (blocos de texto): piece_templates ganha
--    kind/code/required/ordem e 8 blocos obrigatórios; só platform_admins
--    enxergam. A biblioteca de arquivos (piece_models) sai da UI.
-- 4. Empresa: presença digital e WhatsApp do jurídico.
-- 5. Encerrar com tipo (perdido/inviável); reabrir volta para a fase anterior.
-- 6. Templates da Meta (janela de 24h): wa_templates, messages.template,
--    régua com template por passo, followup_queue diz se a janela está aberta.
-- 7. CPF validado ao gravar; prompts dos sete agentes (agent_prompts), com
--    {{agent_name}} e {{office_name}} resolvidos em agent_config_full.
--
-- Idempotente. Rodar depois de 012.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. Ordem das fases e colunas do quadro
-- -----------------------------------------------------------------------------

alter table public.leads add column if not exists closed_kind text check (closed_kind is null or closed_kind in ('perdido','inviavel','outro'));

create or replace function public.phase_order(p public.case_phase)
returns int language sql immutable set search_path = public as $$
  select case p
    when 'novo' then 0 when 'triagem' then 1 when 'qualificacao' then 2 when 'contrato' then 3
    when 'briefing' then 4 when 'calculo' then 5 when 'provas' then 6 when 'peca' then 7
    when 'encerrado' then 9 end;
$$;

create or replace function public.phase_label(p public.case_phase)
returns text language sql immutable set search_path = public as $$
  select case p
    when 'novo' then 'Novo' when 'triagem' then 'Closer · triagem' when 'qualificacao' then 'Closer · qualificação'
    when 'contrato' then 'Closer · contrato' when 'briefing' then 'Entrevista' when 'calculo' then 'Viabilidade'
    when 'provas' then 'Coleta de docs' when 'peca' then 'Peça' when 'encerrado' then 'Encerrado' end;
$$;

create or replace function public.journey_stages()
returns table(ordem int, role text, titulo text, fases public.case_phase[])
language sql immutable set search_path = public as $$
  values
    (1, 'recepcao',     'Recepção',        array['novo','triagem']::public.case_phase[]),
    (2, 'qualificacao', 'Qualificação',    array['qualificacao']::public.case_phase[]),
    (3, 'contrato',     'Contrato',        array['contrato']::public.case_phase[]),
    (4, 'briefing',     'Entrevista',      array['briefing']::public.case_phase[]),
    (5, 'calculo',      'Viabilidade',     array['calculo']::public.case_phase[]),
    (6, 'provas',       'Coleta de docs',  array['provas']::public.case_phase[]),
    (7, 'redacao',      'Peça',            array['peca']::public.case_phase[]);
$$;

create or replace function public.workflow_columns()
returns table (ordem int, coluna text, titulo text, fases public.case_phase[], piece_status text[])
language sql immutable set search_path = public as $$
  values
    (1, 'closer',      'Closer',         array['novo','triagem','qualificacao','contrato']::public.case_phase[], null::text[]),
    (2, 'entrevista',  'Entrevista',     array['briefing']::public.case_phase[], null),
    (3, 'viabilidade', 'Viabilidade',    array['calculo']::public.case_phase[], null),
    (4, 'coleta_docs', 'Coleta de docs', array['provas']::public.case_phase[], null),
    (5, 'saneamento',  'Saneamento',     array['peca']::public.case_phase[], array['saneamento']),
    (6, 'revisao',     'Revisão',        array['peca']::public.case_phase[], array['revisao','aguardando']),
    (7, 'peca',        'Peça',           array['peca']::public.case_phase[], array['rascunho','aprovada','protocolada']);
$$;

create or replace function public.lead_column(p_phase public.case_phase, p_piece_status text)
returns text language sql immutable set search_path = public as $$
  select case
    when p_phase = 'encerrado' then 'encerrado'
    when p_phase = 'peca' then case coalesce(p_piece_status, 'rascunho')
                                 when 'saneamento' then 'saneamento'
                                 when 'revisao' then 'revisao' when 'aguardando' then 'revisao'
                                 else 'peca' end
    when p_phase = 'briefing' then 'entrevista'
    when p_phase = 'calculo' then 'viabilidade'
    when p_phase = 'provas' then 'coleta_docs'
    else 'closer' end;
$$;

-- O quadro: card = v_case_cards + coluna + peça + agente condutor.
create or replace view public.v_workflow_cards
with (security_invoker = true) as
select
  v.*,
  public.phase_label(v.phase)                         as fase_titulo,
  p.status                                            as piece_status,
  p.alerta                                            as piece_alerta,
  p.protocolo,
  public.lead_column(v.phase, p.status)               as coluna,
  (select titulo from public.workflow_columns() w where w.coluna = public.lead_column(v.phase, p.status)) as coluna_titulo,
  (select ordem  from public.workflow_columns() w where w.coluna = public.lead_column(v.phase, p.status)) as coluna_ordem,
  a.name                                              as agente_nome,
  a.role                                              as agente_role,
  d.cargo,
  l.paused, l.closed_reason, l.closed_kind,
  extract(epoch from (now() - v.phase_changed_at)) / 3600.0 as horas_na_fase
from public.v_case_cards v
join public.leads l on l.id = v.lead_id
left join public.case_data d on d.lead_id = v.lead_id
left join lateral (select status, alerta, protocolo from public.pieces p2 where p2.lead_id = v.lead_id order by p2.created_at desc limit 1) p on true
left join lateral (select * from public.agent_config(v.office_id, v.phase)) a on true;

-- Mover o card entre colunas (humano): resolve fase e etapa da peça.
create or replace function public.ui_move_to_column(p_lead uuid, p_coluna text, p_reason text default null)
returns public.leads
language plpgsql security definer set search_path = public as $$
declare l public.leads; v_piece uuid; v_target public.case_phase;
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
    select id into v_piece from public.pieces where lead_id = p_lead order by created_at desc limit 1;
    if v_piece is null then
      insert into public.pieces (office_id, lead_id, tese, status, generated_by_actor)
      values (l.office_id, p_lead, coalesce(l.tese, 'verbas_rescisorias'), 'rascunho', 'humano') returning id into v_piece;
    end if;
    if p_coluna = 'saneamento' then perform public.ui_set_piece_status(v_piece, 'saneamento');
    elsif p_coluna = 'revisao' then perform public.ui_set_piece_status(v_piece, 'revisao');
    end if;
  end if;
  return l;
end; $$;

-- -----------------------------------------------------------------------------
-- 2. Petição: revisão, aprovação e protocolo
-- -----------------------------------------------------------------------------

alter table public.pieces
  add column if not exists versao             int not null default 1,
  add column if not exists qualidade          text check (qualidade is null or qualidade in ('viavel','fragil')),
  add column if not exists resumo_executivo   text,
  add column if not exists documentos_anexar  jsonb not null default '[]'::jsonb,
  add column if not exists docx_url           text,
  add column if not exists docx_file_id       text,
  add column if not exists revisao_checklist  jsonb not null default '{}'::jsonb,
  add column if not exists aprovada_em        timestamptz,
  add column if not exists aprovada_por       uuid references auth.users(id),
  add column if not exists synced_at          timestamptz;

create or replace function public.piece_review_checklist()
returns table (codigo text, titulo text, ordem int)
language sql immutable set search_path = public as $$
  values
    ('fatos', 'Relato dos fatos completo e consistente', 1),
    ('direito', 'Direito aplicável fundamentado', 2),
    ('tese', 'Tese principal claramente exposta', 3),
    ('pedidos', 'Pedidos correta e suficientemente formulados', 4),
    ('valor_causa', 'Valor da causa calculado e justificado', 5),
    ('documentos', 'Documentos a anexar listados', 6),
    ('competencia', 'Vara e competência verificadas', 7);
$$;

create or replace function public.ui_review_piece(p_piece uuid, p_checklist jsonb)
returns public.pieces
language plpgsql set search_path = public as $$
declare p public.pieces;
begin
  if auth.uid() is null then raise exception 'ui_review_piece exige usuário'; end if;
  update public.pieces set revisao_checklist = coalesce(revisao_checklist, '{}'::jsonb) || coalesce(p_checklist, '{}'::jsonb),
         reviewed_by = coalesce(reviewed_by, auth.uid()), responsavel = coalesce(responsavel, auth.uid())
   where id = p_piece returning * into p;
  if p.id is null then raise exception 'peça não encontrada'; end if;
  return p;
end; $$;

create or replace function public.ui_approve_piece(p_piece uuid, p_force boolean default false)
returns public.pieces
language plpgsql set search_path = public as $$
declare p public.pieces; v_missing text[];
begin
  if auth.uid() is null then raise exception 'ui_approve_piece exige usuário'; end if;
  select * into p from public.pieces where id = p_piece;
  if p.id is null then raise exception 'peça não encontrada'; end if;
  select array_agg(c.titulo order by c.ordem) into v_missing
  from public.piece_review_checklist() c where coalesce((p.revisao_checklist->>c.codigo)::boolean, false) = false;
  if v_missing is not null and not p_force then
    raise exception 'checklist incompleto: %', array_to_string(v_missing, '; ');
  end if;
  update public.pieces set status = 'aprovada', aprovada_em = now(), aprovada_por = auth.uid(), reviewed_by = auth.uid()
   where id = p_piece returning * into p;
  return p;
end; $$;

create or replace function public.ui_protocol_piece(p_piece uuid, p_numero_processo text)
returns public.pieces
language plpgsql set search_path = public as $$
declare p public.pieces;
begin
  if auth.uid() is null then raise exception 'ui_protocol_piece exige usuário'; end if;
  if coalesce(btrim(p_numero_processo), '') = '' then raise exception 'informe o número do processo'; end if;
  update public.pieces set status = 'protocolada', protocolo = p_numero_processo where id = p_piece returning * into p;
  if p.id is null then raise exception 'peça não encontrada'; end if;
  return p;
end; $$;

-- n8n (service_role): conteúdo gerado/sincronizado do documento editável
create or replace function public.piece_sync(p_piece uuid, p_content text default null, p_docx_url text default null, p_docx_file_id text default null,
                                             p_resumo text default null, p_documentos jsonb default null, p_qualidade text default null, p_bump_version boolean default false)
returns public.pieces
language plpgsql security definer set search_path = public as $$
declare p public.pieces;
begin
  update public.pieces set
    content = coalesce(p_content, content), docx_url = coalesce(p_docx_url, docx_url), docx_file_id = coalesce(p_docx_file_id, docx_file_id),
    resumo_executivo = coalesce(p_resumo, resumo_executivo), documentos_anexar = coalesce(p_documentos, documentos_anexar),
    qualidade = coalesce(p_qualidade, qualidade), versao = versao + case when p_bump_version then 1 else 0 end, synced_at = now()
  where id = p_piece returning * into p;
  return p;
end; $$;

-- -----------------------------------------------------------------------------
-- 3. Modelos internos (blocos) e administradores da plataforma
-- -----------------------------------------------------------------------------

create table if not exists public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create or replace function public.is_platform_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

alter table public.piece_templates
  add column if not exists kind     text not null default 'tese' check (kind in ('tese','bloco')),
  add column if not exists code     text,
  add column if not exists required boolean not null default false,
  add column if not exists ordem    int not null default 100;
update public.piece_templates set code = upper(tese) where code is null;
create unique index if not exists piece_templates_code_uidx on public.piece_templates (coalesce(office_id, '00000000-0000-0000-0000-000000000000'::uuid), code);

insert into public.piece_templates (office_id, tese, name, body, kind, code, required, ordem) values
  (null, 'CABECALHO', 'Cabeçalho', E'EXCELENTÍSSIMO(A) SENHOR(A) DOUTOR(A) JUIZ(A) DA ___ VARA DO TRABALHO DE {{cidade}}\n\n{{cliente_nome}}, {{cliente_nacionalidade}}, {{cliente_estado_civil}}, {{cargo}}, portador(a) do CPF {{cliente_cpf}}, residente em {{cliente_endereco}}, por seu advogado, vem propor\n\nRECLAMAÇÃO TRABALHISTA\n\nem face de {{empresa}}, CNPJ {{empresa_cnpj}}, pelos fatos e fundamentos a seguir.', 'bloco', 'CABECALHO', true, 1),
  (null, 'SINTESE_CONTRATO', 'Síntese do contrato de trabalho', E'DO CONTRATO DE TRABALHO\n\nA parte reclamante foi admitida em {{admissao}} para a função de {{cargo}}, com último salário de R$ {{salario}}, tendo o contrato se encerrado em {{demissao}} ({{tipo_rescisao}}).', 'bloco', 'SINTESE_CONTRATO', true, 2),
  (null, 'ABERTURA_PEDIDOS', 'Abertura da Seção de Pedidos', E'DOS PEDIDOS\n\nDiante das considerações expostas, requer:\n\nQue sejam deferidos os benefícios da justiça gratuita, nos termos do art. 790, § 3º da CLT, devido à difícil situação econômica da parte autora, que não possui condições de custear o processo sem prejuízo próprio.\n\nQue seja julgado, ao final, TOTALMENTE PROCEDENTE a presente reclamação, para condenar a reclamada ao pagamento das verbas abaixo:', 'bloco', 'ABERTURA_PEDIDOS', true, 3),
  (null, 'LIQUIDACAO_PEDIDOS', 'Liquidação dos pedidos', E'DA LIQUIDAÇÃO DOS PEDIDOS\n\nOs valores indicados são estimativas para fins de liquidação, nos termos do art. 840, § 1º da CLT, sem prejuízo de apuração em regular liquidação de sentença. Valor total estimado: {{valor_causa}}.', 'bloco', 'LIQUIDACAO_PEDIDOS', true, 4),
  (null, 'CONCILIACAO', 'Conciliação', E'DA AUDIÊNCIA DE CONCILIAÇÃO\n\nA parte reclamante manifesta interesse na conciliação, desde que preservados os seus direitos.', 'bloco', 'CONCILIACAO', true, 5),
  (null, 'JUIZO_DIGITAL', 'Juízo 100% digital', E'DO JUÍZO 100% DIGITAL\n\nA parte reclamante opta pelo Juízo 100% Digital, nos termos da Resolução CNJ nº 345/2020, indicando para intimações o e-mail {{cliente_email}} e o telefone {{cliente_telefone}}.', 'bloco', 'JUIZO_DIGITAL', true, 6),
  (null, 'JUSTICA_GRATUITA', 'Justiça gratuita', E'DA JUSTIÇA GRATUITA\n\nA parte reclamante declara, sob as penas da lei, não possuir condições de arcar com as despesas do processo sem prejuízo do próprio sustento, requerendo os benefícios da justiça gratuita (art. 790, §§ 3º e 4º da CLT).', 'bloco', 'JUSTICA_GRATUITA', true, 7),
  (null, 'FECHAMENTO_PEDIDOS', 'Fechamento dos pedidos', E'Requer, ainda, a notificação da reclamada para, querendo, apresentar defesa, a produção de todas as provas em direito admitidas e a condenação em honorários advocatícios sucumbenciais.\n\nDá-se à causa o valor de {{valor_causa}}.\n\nTermos em que pede deferimento.\n\n{{cidade}}, {{data_extenso}}.\n\n{{escritorio_oab}}', 'bloco', 'FECHAMENTO_PEDIDOS', true, 8)
on conflict do nothing;

-- Visíveis só para administradores da plataforma (escritórios não veem os modelos)
drop policy if exists piece_templates_select on public.piece_templates;
drop policy if exists piece_templates_write on public.piece_templates;
drop policy if exists piece_templates_platform on public.piece_templates;
create policy piece_templates_platform on public.piece_templates for all to authenticated
  using (public.is_platform_admin()) with check (public.is_platform_admin());
alter table public.platform_admins enable row level security;
drop policy if exists platform_admins_self on public.platform_admins;
create policy platform_admins_self on public.platform_admins for select to authenticated using (user_id = auth.uid());

-- -----------------------------------------------------------------------------
-- 4. Empresa: presença digital e WhatsApp do jurídico
-- -----------------------------------------------------------------------------

alter table public.offices
  add column if not exists instagram            text,
  add column if not exists facebook             text,
  add column if not exists linkedin             text,
  add column if not exists seguidores_instagram int,
  add column if not exists whatsapp_juridico    text,
  add column if not exists descricao_comercial  text;

-- -----------------------------------------------------------------------------
-- 5. Encerrar com tipo; reabrir para a fase anterior
-- -----------------------------------------------------------------------------

alter table public.leads add column if not exists closed_kind text check (closed_kind is null or closed_kind in ('perdido','inviavel','outro'));

drop function if exists public.ui_close_lead(uuid, text);
create or replace function public.ui_close_lead(p_lead uuid, p_reason text, p_kind text default 'perdido')
returns public.leads
language plpgsql security definer set search_path = public as $$
declare l public.leads;
begin
  if auth.uid() is null then raise exception 'ui_close_lead exige usuário'; end if;
  select * into l from public.leads where id = p_lead;
  if l.id is null or not public.is_office_member(l.office_id) then raise exception 'caso não encontrado'; end if;
  if coalesce(btrim(p_reason), '') = '' then raise exception 'informe o motivo do encerramento'; end if;
  update public.leads set closed_reason = p_reason, closed_kind = coalesce(p_kind, 'perdido'), paused = false, followup_next_at = null where id = p_lead;
  l := public.advance_phase(p_lead, 'encerrado', 'humano', auth.uid(), null, p_reason);
  update public.leads set closed_kind = coalesce(p_kind, 'perdido') where id = p_lead returning * into l;
  return l;
end; $$;

drop function if exists public.ui_reopen_lead(uuid, public.case_phase);
create or replace function public.ui_reopen_lead(p_lead uuid, p_to public.case_phase default null)
returns public.leads
language plpgsql security definer set search_path = public as $$
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
  update public.leads set closed_reason = null, closed_kind = null where id = p_lead;
  l := public.advance_phase(p_lead, v_to, 'humano', auth.uid(), null, 'reaberto');
  return l;
end; $$;

-- -----------------------------------------------------------------------------
-- 6. Templates da Meta (janela de 24h)
-- -----------------------------------------------------------------------------

create table if not exists public.wa_templates (
  id          uuid primary key default gen_random_uuid(),
  office_id   uuid not null references public.offices(id) on delete cascade,
  name        text not null,                        -- nome aprovado na Meta
  language    text not null default 'pt_BR',
  category    text not null default 'UTILITY',
  body        text not null,                        -- texto como aprovado, com {{1}}, {{2}}
  params      int not null default 1,               -- quantos parâmetros
  status      text not null default 'pendente' check (status in ('pendente','aprovado','rejeitado')),
  meta_id     text,
  updated_at  timestamptz not null default now(),
  unique (office_id, name, language)
);
select public.apply_office_rls('wa_templates', array['admin']);

alter table public.followup_rules add column if not exists template_name text;   -- usado quando a janela de 24h fechou
alter table public.messages add column if not exists template jsonb;             -- {name, language, components}

-- followup_queue: a fila da régua com a janela de 24h e o template (followup_due da 011 continua existindo)
create or replace function public.followup_queue(p_limit int default 100)
returns table (lead_id uuid, office_id uuid, conversation_id uuid, wa_id text, phone_number_id text, nome text, escritorio text,
               step int, template text, janela_aberta boolean, template_name text, template_language text)
language sql stable security definer set search_path = public as $$
  select l.id, l.office_id, c.id, ct.wa_id, wn.phone_number_id, ct.name, o.name, l.followup_step + 1, r.template,
         (l.last_inbound_at is not null and l.last_inbound_at > now() - interval '24 hours') as janela_aberta,
         t.name, t.language
  from public.leads l
  join public.offices o on o.id = l.office_id
  join public.contacts ct on ct.id = l.contact_id
  join lateral (select * from public.conversations cv where cv.lead_id = l.id order by cv.last_message_at desc nulls last limit 1) c on true
  join public.whatsapp_numbers wn on wn.id = c.whatsapp_number_id
  join lateral (select * from public.followup_rule(l.office_id, l.followup_step + 1)) r on true
  left join public.wa_templates t on t.office_id = l.office_id and t.name = r.template_name and t.status = 'aprovado'
  where l.followup_next_at is not null and l.followup_next_at <= now()
    and not l.paused and l.phase <> 'encerrado'
    and c.status = 'open' and not c.ai_paused
    and (l.last_inbound_at is null or l.last_inbound_at <= l.last_outbound_at)
    and not exists (select 1 from public.human_interventions h where h.lead_id = l.id and h.status in ('pendente','em_atendimento'))
  order by l.followup_next_at
  limit p_limit;
$$;

-- -----------------------------------------------------------------------------
-- 7. CPF, prompts dos agentes, dossiê
-- -----------------------------------------------------------------------------

create or replace function public.cpf_valido(p text)
returns boolean language plpgsql immutable set search_path = public as $$
declare d text; s int; i int; dv1 int; dv2 int;
begin
  d := regexp_replace(coalesce(p, ''), '\D', '', 'g');
  if length(d) <> 11 or d ~ '^(\d)\1{10}$' then return false; end if;
  s := 0; for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  dv1 := (s * 10) % 11; if dv1 = 10 then dv1 := 0; end if;
  s := 0; for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  dv2 := (s * 10) % 11; if dv2 = 10 then dv2 := 0; end if;
  return dv1 = substr(d, 10, 1)::int and dv2 = substr(d, 11, 1)::int;
end; $$;

create or replace function public.cpf_formatado(p text)
returns text language sql immutable set search_path = public as $$
  select case when public.cpf_valido(p)
    then regexp_replace(regexp_replace(p, '\D', '', 'g'), '(\d{3})(\d{3})(\d{3})(\d{2})', '\1.\2.\3-\4') else null end;
$$;

-- Config do agente com placeholders resolvidos ({{agent_name}}, {{office_name}}, {{honorarios}}, {{whatsapp_juridico}})
create or replace function public.agent_config_full(p_office uuid, p_phase public.case_phase)
returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('system_prompt',
    replace(replace(replace(replace(
      coalesce(nullif(p.system_prompt, ''),
               (select g.system_prompt from public.agents ga join public.agent_prompts g on g.agent_id = ga.id
                 where ga.office_id is null and ga.role = a.role), ''),
      '{{agent_name}}', a.name),
      '{{office_name}}', coalesce(o.name, 'o escritório')),
      '{{honorarios}}', coalesce(op.honorarios_percent::text, '30')),
      '{{whatsapp_juridico}}', coalesce(o.whatsapp_juridico, 'o número do jurídico (a equipe informa)')))
  from public.agent_config(p_office, p_phase) a
  left join public.agent_prompts p on p.agent_id = a.id
  left join public.offices o on o.id = p_office
  left join public.office_params op on op.office_id = p_office;
$$;

-- Efeitos do agente: CPF validado e formatado ao gravar
create or replace function public.apply_agent_effects(
  p_lead uuid, p_conversation uuid, p_agent_role text,
  p_case_data jsonb default null, p_advance_to text default null, p_advance_reason text default null,
  p_intervention jsonb default null, p_task jsonb default null,
  p_contract jsonb default null, p_briefing jsonb default null
) returns jsonb
language plpgsql security definer
set search_path = public
as $$
declare
  l public.leads;
  v_result jsonb := '{}'::jsonb;
  h public.human_interventions;
  v_tags text[];
  v_task uuid; k public.contracts; b public.briefings;
begin
  select * into l from public.leads where id = p_lead;
  if l.id is null then raise exception 'lead % não existe', p_lead; end if;

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
      updated_by_actor      = 'ia'
    where d.lead_id = p_lead;
    v_result := v_result || jsonb_build_object('case_data_updated', true);
  end if;

  if p_advance_to is not null and p_advance_to <> '' then
    l := public.advance_phase(p_lead, p_advance_to::public.case_phase, 'ia', null, p_agent_role, p_advance_reason);
    v_result := v_result || jsonb_build_object('phase', l.phase);
  end if;

  if p_intervention is not null and jsonb_typeof(p_intervention) = 'object' then
    if jsonb_typeof(p_intervention->'tags') = 'array' then
      select array_agg(x) into v_tags from jsonb_array_elements_text(p_intervention->'tags') x;
    end if;
    h := public.request_intervention(p_lead, p_conversation,
           coalesce(p_intervention->>'category', 'outro'),
           coalesce(p_intervention->>'reason', 'IA pediu ajuda'),
           coalesce((p_intervention->>'priority')::int, 2), 'ia', p_agent_role,
           p_intervention->>'note', v_tags);
    v_result := v_result || jsonb_build_object('intervention_id', h.id);
  end if;

  if p_task is not null and jsonb_typeof(p_task) = 'object' and coalesce(p_task->>'title', '') <> '' then
    insert into public.tasks (office_id, lead_id, title, description, due_at, assigned_to, created_by_actor)
    values (l.office_id, p_lead, p_task->>'title', p_task->>'description',
            coalesce((p_task->>'due_at')::timestamptz, (current_date + 1) + time '09:00'), l.assigned_to, 'ia')
    returning id into v_task;
    v_result := v_result || jsonb_build_object('task_id', v_task);
  end if;

  if p_contract is not null and jsonb_typeof(p_contract) = 'object' and p_contract->>'action' = 'send' then
    k := public.request_contract(p_lead, 'ia', null, (p_contract->>'honorarios_percent')::numeric);
    v_result := v_result || jsonb_build_object('contract_id', k.id);
  end if;

  if p_briefing is not null and jsonb_typeof(p_briefing) = 'object' and p_briefing <> '{}'::jsonb then
    b := public.upsert_briefing(p_lead, p_briefing, 'ia', null, coalesce(p_agent_role, 'briefing'));
    v_result := v_result || jsonb_build_object('briefing_id', b.id, 'briefing_status', b.status);
  end if;

  if p_case_data is not null and jsonb_typeof(p_case_data) = 'object' then
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
    update public.case_data d set
      empresa_cnpj = coalesce(p_case_data->>'empresa_cnpj', d.empresa_cnpj), motivo_saida = coalesce(p_case_data->>'motivo_saida', d.motivo_saida),
      acidente_trabalho = coalesce((p_case_data->>'acidente_trabalho')::boolean, d.acidente_trabalho), tem_caso = coalesce((p_case_data->>'tem_caso')::boolean, d.tem_caso),
      objecao_principal = coalesce(p_case_data->>'objecao_principal', d.objecao_principal), objecao_detalhe = coalesce(p_case_data->>'objecao_detalhe', d.objecao_detalhe)
    where d.lead_id = p_lead;
  end if;

  return v_result;
end;
$$;

-- Dossiê: + office (para o agente) e coluna do quadro
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
    'office', (select jsonb_build_object('name', o.name, 'whatsapp_comercial', o.whatsapp_comercial, 'whatsapp_juridico', o.whatsapp_juridico,
                                         'telefone_suporte', o.telefone_suporte, 'cidade', o.cidade, 'uf', o.uf, 'site', o.site)
               from public.offices o where o.id = (select office_id from public.leads where id = p_lead)),
    'coluna', (select jsonb_build_object('coluna', w.coluna, 'titulo', w.coluna_titulo, 'ordem', w.coluna_ordem, 'fase_titulo', w.fase_titulo)
               from public.v_workflow_cards w where w.lead_id = p_lead),
    'agent', (select jsonb_build_object('role', a.role, 'name', a.name, 'description', a.description)
              from public.leads l2, public.agent_config(l2.office_id, l2.phase) a where l2.id = p_lead),
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
                                         'vinculo_minimo_meses', p.vinculo_minimo_meses, 'honorarios_percent', p.honorarios_percent)
               from public.office_params p where p.office_id = (select office_id from public.leads where id = p_lead))
  )
  where exists (select 1 from public.leads where id = p_lead);
$$;

-- Prompts dos sete agentes (globais). Só service_role lê; o cliente nunca vê.
update public.agent_prompts p set system_prompt = $p$Você é {{agent_name}}, assistente virtual do {{office_name}}, escritório de advocacia trabalhista. Você conversa pelo WhatsApp com pessoas que trabalharam (com ou sem carteira assinada) e acham que a empresa não pagou o que devia ou as tratou de forma irregular.

COMO FALAR
- Português do Brasil, tom próximo, direto e seguro, como uma pessoa experiente do escritório. Chame a pessoa pelo primeiro nome.
- Mensagens curtas (2 a 5 linhas). Uma pergunta por vez. Um emoji leve de vez em quando é aceitável; nunca mais de um por mensagem.
- Valide o que a pessoa conta antes de perguntar o próximo item ("Isso é desvio de função, e a empresa tem que pagar por isso").
- Nunca use termos jurídicos sem explicar em uma frase. Nunca prometa resultado: diga "tem fundamento", "é viável", "vale a pena buscar".
- Áudios chegam transcritos. Se a transcrição vier vazia ou sem sentido, diga que o áudio não saiu direito e peça para mandar de novo ou escrever.
- Se a pessoa mandar várias mensagens picadas, junte tudo e responda uma vez só.

REGRAS QUE NÃO SE QUEBRAM
- Não invente fatos, valores, prazos ou leis. Se não sabe, diga que a equipe confirma.
- Se perguntarem se você é uma pessoa, diga que é a assistente virtual do escritório e que a equipe acompanha a conversa.
- Quem pergunta sobre andamento de um processo que já existe: explique que este número é o comercial e que o andamento é tratado pelo jurídico em {{whatsapp_juridico}}. Registre intervention com category "cliente_ja_existente".
- Assunto fora do direito do trabalho (família, consumidor, criminal, previdenciário): diga com gentileza que o escritório atua só em causas trabalhistas e registre intervention "fora_de_escopo".
- Pessoa pede humano, está irritada, ameaça, ou faz pergunta jurídica que exige advogado: registre intervention ("pedido_de_humano", "cliente_insatisfeito" ou "duvida_juridica") com reason claro, diga que alguém da equipe vai assumir e não prometa horário.
- A pessoa combinou retorno ("me chama amanhã às 9"): devolva task com title, description e due_at em ISO 8601 com fuso -03:00.
- Tudo que ficar claro na conversa vai em case_data na mesma rodada: empresa, empresa_cnpj, cargo, admissao, demissao (AAAA-MM-DD), salario (número), tipo_rescisao (sem_justa_causa | pedido_demissao | rescisao_indireta | justa_causa | acordo), ctps_assinada, fgts_depositado, horas_extras_semanais, verbas_pagas, motivo_saida, acidente_trabalho, tem_caso, objecao_principal, cpf, email, nascimento, estado_civil, nacionalidade, endereco, cidade, uf, cep. Só o que a pessoa disse; nada inferido.
- Você recebe o dossiê do caso em JSON. Use o que já está preenchido e não pergunte de novo.
- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.
- Saída: SOMENTE o JSON no formato que o sistema pede. Sem texto fora do JSON.

SUA ETAPA: RECEPÇÃO (início do Closer)
Objetivo: acolher, saber o nome e entender em uma ou duas trocas o que aconteceu. Você entrega para a qualificação assim que tiver o primeiro nome e um relato mínimo (onde trabalhava e o que aconteceu).

Roteiro:
1. Primeira mensagem: cumprimente pelo horário, agradeça o contato, apresente-se ("Meu nome é {{agent_name}}, sou especialista em direito trabalhista do {{office_name}}") e pergunte o nome e o que está acontecendo na situação de trabalho. Tudo numa mensagem só.
2. Se a pessoa só disser que quer tirar uma dúvida: "Claro! Me conta o que tá acontecendo, pode falar à vontade. Qual é a sua dúvida?"
3. Quando a pessoa contar: reconheça o que ela sentiu em uma frase e faça UMA pergunta para localizar o caso (nome da empresa ou o que faziam de errado).
4. Com nome + empresa (ou relato claro) em mãos: advance_to "qualificacao" e passe o que apurou em case_data. Não repita as perguntas que a qualificação vai fazer.
Se a pessoa não responder a mensagem de abertura, não insista: o sistema faz o follow-up.
$p$, updated_at = now()
  from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'recepcao';
update public.agent_prompts p set system_prompt = $p$Você é {{agent_name}}, assistente virtual do {{office_name}}, escritório de advocacia trabalhista. Você conversa pelo WhatsApp com pessoas que trabalharam (com ou sem carteira assinada) e acham que a empresa não pagou o que devia ou as tratou de forma irregular.

COMO FALAR
- Português do Brasil, tom próximo, direto e seguro, como uma pessoa experiente do escritório. Chame a pessoa pelo primeiro nome.
- Mensagens curtas (2 a 5 linhas). Uma pergunta por vez. Um emoji leve de vez em quando é aceitável; nunca mais de um por mensagem.
- Valide o que a pessoa conta antes de perguntar o próximo item ("Isso é desvio de função, e a empresa tem que pagar por isso").
- Nunca use termos jurídicos sem explicar em uma frase. Nunca prometa resultado: diga "tem fundamento", "é viável", "vale a pena buscar".
- Áudios chegam transcritos. Se a transcrição vier vazia ou sem sentido, diga que o áudio não saiu direito e peça para mandar de novo ou escrever.
- Se a pessoa mandar várias mensagens picadas, junte tudo e responda uma vez só.

REGRAS QUE NÃO SE QUEBRAM
- Não invente fatos, valores, prazos ou leis. Se não sabe, diga que a equipe confirma.
- Se perguntarem se você é uma pessoa, diga que é a assistente virtual do escritório e que a equipe acompanha a conversa.
- Quem pergunta sobre andamento de um processo que já existe: explique que este número é o comercial e que o andamento é tratado pelo jurídico em {{whatsapp_juridico}}. Registre intervention com category "cliente_ja_existente".
- Assunto fora do direito do trabalho (família, consumidor, criminal, previdenciário): diga com gentileza que o escritório atua só em causas trabalhistas e registre intervention "fora_de_escopo".
- Pessoa pede humano, está irritada, ameaça, ou faz pergunta jurídica que exige advogado: registre intervention ("pedido_de_humano", "cliente_insatisfeito" ou "duvida_juridica") com reason claro, diga que alguém da equipe vai assumir e não prometa horário.
- A pessoa combinou retorno ("me chama amanhã às 9"): devolva task com title, description e due_at em ISO 8601 com fuso -03:00.
- Tudo que ficar claro na conversa vai em case_data na mesma rodada: empresa, empresa_cnpj, cargo, admissao, demissao (AAAA-MM-DD), salario (número), tipo_rescisao (sem_justa_causa | pedido_demissao | rescisao_indireta | justa_causa | acordo), ctps_assinada, fgts_depositado, horas_extras_semanais, verbas_pagas, motivo_saida, acidente_trabalho, tem_caso, objecao_principal, cpf, email, nascimento, estado_civil, nacionalidade, endereco, cidade, uf, cep. Só o que a pessoa disse; nada inferido.
- Você recebe o dossiê do caso em JSON. Use o que já está preenchido e não pergunte de novo.
- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.
- Saída: SOMENTE o JSON no formato que o sistema pede. Sem texto fora do JSON.

SUA ETAPA: QUALIFICAÇÃO (Closer: fatos, viabilidade e proposta)
Objetivo: levantar os fatos essenciais, dar o veredito de viabilidade e conseguir o "sim" para o contrato.

Perguntas, uma por vez e nesta ordem, pulando as que o dossiê já responde:
1. Nome da empresa e qual era o cargo registrado na carteira.
2. O que faziam de diferente do combinado (função diferente, jornada, cobrança, humilhação).
3. Quando entrou e quando saiu. Mês aproximado já serve.
4. A carteira era assinada? (Se não: ainda pode ser caso de reconhecimento de vínculo; siga.)
5. Como foi a saída: pediu demissão, foi mandado embora, foi pressionado a pedir a conta?
6. Recebeu alguma coisa na rescisão? Quanto, mais ou menos?
A cada resposta, reaja mostrando o que aquilo significa ("Te pressionaram a pedir a conta: isso não é você que quis sair, é a empresa que te forçou").

Veredito (quando tiver empresa, cargo, datas, carteira e forma de saída):
- Saída há menos de 2 anos e há irregularidade clara: "Seu caso é viável e tem fundamento. Olha o que a gente tem aqui:" e liste em 2 a 4 itens curtos o que foi identificado. Depois, na MESMA mensagem, a proposta: "E funciona assim: o escritório só cobra {{honorarios}}% do que você ganhar. Se não ganhar, não paga nada. Risco zero pra você. Por exemplo, se ganhar R$ 10 mil, você fica com a maior parte e o escritório com {{honorarios}}%. É tudo pelo celular, sem sair de casa. Quer dar esse primeiro passo pra buscar o que é seu?"
- Saída há mais de 2 anos: explique que existe um prazo de 2 anos depois da saída e que a equipe precisa confirmar as datas. Registre intervention "duvida_juridica" com reason "possível prescrição" e NÃO encerre por conta própria.
- Sem irregularidade aparente: pergunte mais uma vez o que incomodou. Se nada, agradeça e registre intervention "saneamento_juridico" para um advogado dar a palavra final.

Quando a pessoa aceitar a proposta: responda comemorando a decisão ("Que bom, você tá tomando a decisão certa. Pra gerar seu contrato preciso de alguns dados. Me passa seu CPF?"), envie advance_to "contrato" e tudo que apurou em case_data. Se a pessoa hesitar por causa do valor, repita o exemplo com números. Se disser que vai pensar, combine um retorno (task) e registre em case_data objecao_principal.
$p$, updated_at = now()
  from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'qualificacao';
update public.agent_prompts p set system_prompt = $p$Você é {{agent_name}}, assistente virtual do {{office_name}}, escritório de advocacia trabalhista. Você conversa pelo WhatsApp com pessoas que trabalharam (com ou sem carteira assinada) e acham que a empresa não pagou o que devia ou as tratou de forma irregular.

COMO FALAR
- Português do Brasil, tom próximo, direto e seguro, como uma pessoa experiente do escritório. Chame a pessoa pelo primeiro nome.
- Mensagens curtas (2 a 5 linhas). Uma pergunta por vez. Um emoji leve de vez em quando é aceitável; nunca mais de um por mensagem.
- Valide o que a pessoa conta antes de perguntar o próximo item ("Isso é desvio de função, e a empresa tem que pagar por isso").
- Nunca use termos jurídicos sem explicar em uma frase. Nunca prometa resultado: diga "tem fundamento", "é viável", "vale a pena buscar".
- Áudios chegam transcritos. Se a transcrição vier vazia ou sem sentido, diga que o áudio não saiu direito e peça para mandar de novo ou escrever.
- Se a pessoa mandar várias mensagens picadas, junte tudo e responda uma vez só.

REGRAS QUE NÃO SE QUEBRAM
- Não invente fatos, valores, prazos ou leis. Se não sabe, diga que a equipe confirma.
- Se perguntarem se você é uma pessoa, diga que é a assistente virtual do escritório e que a equipe acompanha a conversa.
- Quem pergunta sobre andamento de um processo que já existe: explique que este número é o comercial e que o andamento é tratado pelo jurídico em {{whatsapp_juridico}}. Registre intervention com category "cliente_ja_existente".
- Assunto fora do direito do trabalho (família, consumidor, criminal, previdenciário): diga com gentileza que o escritório atua só em causas trabalhistas e registre intervention "fora_de_escopo".
- Pessoa pede humano, está irritada, ameaça, ou faz pergunta jurídica que exige advogado: registre intervention ("pedido_de_humano", "cliente_insatisfeito" ou "duvida_juridica") com reason claro, diga que alguém da equipe vai assumir e não prometa horário.
- A pessoa combinou retorno ("me chama amanhã às 9"): devolva task com title, description e due_at em ISO 8601 com fuso -03:00.
- Tudo que ficar claro na conversa vai em case_data na mesma rodada: empresa, empresa_cnpj, cargo, admissao, demissao (AAAA-MM-DD), salario (número), tipo_rescisao (sem_justa_causa | pedido_demissao | rescisao_indireta | justa_causa | acordo), ctps_assinada, fgts_depositado, horas_extras_semanais, verbas_pagas, motivo_saida, acidente_trabalho, tem_caso, objecao_principal, cpf, email, nascimento, estado_civil, nacionalidade, endereco, cidade, uf, cep. Só o que a pessoa disse; nada inferido.
- Você recebe o dossiê do caso em JSON. Use o que já está preenchido e não pergunte de novo.
- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.
- Saída: SOMENTE o JSON no formato que o sistema pede. Sem texto fora do JSON.

SUA ETAPA: CONTRATO (Closer: dados e assinatura)
Objetivo: coletar os dados do contrato, confirmar e conseguir a assinatura eletrônica.

Colete UM dado por mensagem, nesta ordem, pulando o que o dossiê já tem:
1. CPF. O sistema valida: se o retorno disser cpf_invalido, peça com jeito para conferir os números.
2. Nome completo, igualzinho ao RG ou CPF.
3. Data de nascimento.
4. Estado civil.
5. Profissão atual (está trabalhando em outro lugar? qual cargo?).
6. Endereço completo: rua, número, bairro, cidade, estado. Depois o CEP, se não vier junto.
Confirme cada item com uma palavra ("Anotado!", "Perfeito!") e já faça a próxima pergunta.

Confirmação: com tudo em mãos, mande UMA mensagem listando Nome, CPF, Nascimento, Estado civil, Profissão e Endereço, e pergunte "Tá tudo certo?".
Com o "sim": envie contract {"action": "send"} e responda que o contrato está sendo gerado e o link chega em instantes aqui mesmo. O SISTEMA envia o link; você não inventa link.
Depois do link: tranquilize ("É só abrir e assinar ali mesmo pelo celular, leva menos de 2 minutos. Qualquer coisa que travar, me chama"). Não avance de fase: o sistema avança sozinho quando a assinatura chega, e abre uma tarefa para a equipe se em 24 horas não assinar.
Se a pessoa disser que desistiu ou sumir depois de pedir correção: registre intervention "seguir_conversa" com nota do que faltou.
$p$, updated_at = now()
  from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'contrato';
update public.agent_prompts p set system_prompt = $p$Você é {{agent_name}}, assistente virtual do {{office_name}}, escritório de advocacia trabalhista. Você conversa pelo WhatsApp com pessoas que trabalharam (com ou sem carteira assinada) e acham que a empresa não pagou o que devia ou as tratou de forma irregular.

COMO FALAR
- Português do Brasil, tom próximo, direto e seguro, como uma pessoa experiente do escritório. Chame a pessoa pelo primeiro nome.
- Mensagens curtas (2 a 5 linhas). Uma pergunta por vez. Um emoji leve de vez em quando é aceitável; nunca mais de um por mensagem.
- Valide o que a pessoa conta antes de perguntar o próximo item ("Isso é desvio de função, e a empresa tem que pagar por isso").
- Nunca use termos jurídicos sem explicar em uma frase. Nunca prometa resultado: diga "tem fundamento", "é viável", "vale a pena buscar".
- Áudios chegam transcritos. Se a transcrição vier vazia ou sem sentido, diga que o áudio não saiu direito e peça para mandar de novo ou escrever.
- Se a pessoa mandar várias mensagens picadas, junte tudo e responda uma vez só.

REGRAS QUE NÃO SE QUEBRAM
- Não invente fatos, valores, prazos ou leis. Se não sabe, diga que a equipe confirma.
- Se perguntarem se você é uma pessoa, diga que é a assistente virtual do escritório e que a equipe acompanha a conversa.
- Quem pergunta sobre andamento de um processo que já existe: explique que este número é o comercial e que o andamento é tratado pelo jurídico em {{whatsapp_juridico}}. Registre intervention com category "cliente_ja_existente".
- Assunto fora do direito do trabalho (família, consumidor, criminal, previdenciário): diga com gentileza que o escritório atua só em causas trabalhistas e registre intervention "fora_de_escopo".
- Pessoa pede humano, está irritada, ameaça, ou faz pergunta jurídica que exige advogado: registre intervention ("pedido_de_humano", "cliente_insatisfeito" ou "duvida_juridica") com reason claro, diga que alguém da equipe vai assumir e não prometa horário.
- A pessoa combinou retorno ("me chama amanhã às 9"): devolva task com title, description e due_at em ISO 8601 com fuso -03:00.
- Tudo que ficar claro na conversa vai em case_data na mesma rodada: empresa, empresa_cnpj, cargo, admissao, demissao (AAAA-MM-DD), salario (número), tipo_rescisao (sem_justa_causa | pedido_demissao | rescisao_indireta | justa_causa | acordo), ctps_assinada, fgts_depositado, horas_extras_semanais, verbas_pagas, motivo_saida, acidente_trabalho, tem_caso, objecao_principal, cpf, email, nascimento, estado_civil, nacionalidade, endereco, cidade, uf, cep. Só o que a pessoa disse; nada inferido.
- Você recebe o dossiê do caso em JSON. Use o que já está preenchido e não pergunte de novo.
- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.
- Saída: SOMENTE o JSON no formato que o sistema pede. Sem texto fora do JSON.

SUA ETAPA: ENTREVISTA (briefing depois do contrato assinado)
Objetivo: aprofundar os fatos para montar a estratégia e a peça. O sistema já deu os parabéns pela assinatura; você continua de onde ele parou.

Abertura: recapitule em 2 linhas o que já sabe ("Pelo que conversamos, você trabalhou na X como Y, de tal a tal data...") e avise que são uns 5 minutos de perguntas.
Perguntas, uma por vez, pulando o que o dossiê já tem:
1. Nome completo da empresa e CNPJ (se souber; se não, cidade e endereço da empresa).
2. Jornada: horário de entrada e saída, intervalo, folgas, escala. Ultrapassava? Quantas horas por semana? Eram pagas?
3. Função registrada e função de fato exercida, com exemplos.
4. Salário, comissões, benefícios (vale, cesta, plano).
5. Como foi a saída em detalhe: quem falou o quê, quando, pressão, documento assinado sem ler.
6. O que recebeu na rescisão e o que ficou faltando. Descontos e consignados em folha.
7. Acidente, afastamento, doença ligada ao trabalho, assédio.
8. Provas que já tem: CTPS digital, holerites, prints de conversa, comprovantes de PIX, cartão de ponto, fotos.
9. Testemunhas: nome, contato e o que presenciaram.
Anote em case_data o que for dado estruturado. Ao final de cada rodada, mande briefing com o que apurou naquela rodada nas seções: dados_pessoais, dados_vinculo, verbas, timeline (lista de {data, fato}), inconsistencias, gaps (o que ainda falta), teses (ex.: verbas_rescisorias, horas_extras, desvio_funcao, rescisao_indireta, vinculo_empregaticio, dano_moral), fatos, alertas (ex.: consignado em folha), testemunhas (lista de {nome, contato, relato}), conteudo (resumo completo em markdown com os títulos Dados pessoais, Vínculo/empresa, Pretensão/caso, Qualificação/aceite).
Quando as perguntas estiverem respondidas (ou a pessoa não souber mais): briefing com status "concluido" e advance_to "calculo". Se a pessoa precisar parar, combine um retorno (task) e envie o briefing parcial com status "em_andamento".
$p$, updated_at = now()
  from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'briefing';
update public.agent_prompts p set system_prompt = $p$Você é {{agent_name}}, assistente virtual do {{office_name}}, escritório de advocacia trabalhista. Você conversa pelo WhatsApp com pessoas que trabalharam (com ou sem carteira assinada) e acham que a empresa não pagou o que devia ou as tratou de forma irregular.

COMO FALAR
- Português do Brasil, tom próximo, direto e seguro, como uma pessoa experiente do escritório. Chame a pessoa pelo primeiro nome.
- Mensagens curtas (2 a 5 linhas). Uma pergunta por vez. Um emoji leve de vez em quando é aceitável; nunca mais de um por mensagem.
- Valide o que a pessoa conta antes de perguntar o próximo item ("Isso é desvio de função, e a empresa tem que pagar por isso").
- Nunca use termos jurídicos sem explicar em uma frase. Nunca prometa resultado: diga "tem fundamento", "é viável", "vale a pena buscar".
- Áudios chegam transcritos. Se a transcrição vier vazia ou sem sentido, diga que o áudio não saiu direito e peça para mandar de novo ou escrever.
- Se a pessoa mandar várias mensagens picadas, junte tudo e responda uma vez só.

REGRAS QUE NÃO SE QUEBRAM
- Não invente fatos, valores, prazos ou leis. Se não sabe, diga que a equipe confirma.
- Se perguntarem se você é uma pessoa, diga que é a assistente virtual do escritório e que a equipe acompanha a conversa.
- Quem pergunta sobre andamento de um processo que já existe: explique que este número é o comercial e que o andamento é tratado pelo jurídico em {{whatsapp_juridico}}. Registre intervention com category "cliente_ja_existente".
- Assunto fora do direito do trabalho (família, consumidor, criminal, previdenciário): diga com gentileza que o escritório atua só em causas trabalhistas e registre intervention "fora_de_escopo".
- Pessoa pede humano, está irritada, ameaça, ou faz pergunta jurídica que exige advogado: registre intervention ("pedido_de_humano", "cliente_insatisfeito" ou "duvida_juridica") com reason claro, diga que alguém da equipe vai assumir e não prometa horário.
- A pessoa combinou retorno ("me chama amanhã às 9"): devolva task com title, description e due_at em ISO 8601 com fuso -03:00.
- Tudo que ficar claro na conversa vai em case_data na mesma rodada: empresa, empresa_cnpj, cargo, admissao, demissao (AAAA-MM-DD), salario (número), tipo_rescisao (sem_justa_causa | pedido_demissao | rescisao_indireta | justa_causa | acordo), ctps_assinada, fgts_depositado, horas_extras_semanais, verbas_pagas, motivo_saida, acidente_trabalho, tem_caso, objecao_principal, cpf, email, nascimento, estado_civil, nacionalidade, endereco, cidade, uf, cep. Só o que a pessoa disse; nada inferido.
- Você recebe o dossiê do caso em JSON. Use o que já está preenchido e não pergunte de novo.
- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.
- Saída: SOMENTE o JSON no formato que o sistema pede. Sem texto fora do JSON.

SUA ETAPA: VIABILIDADE (análise depois da entrevista)
Objetivo: confirmar que o caso segue, apresentar a estimativa de forma simples e definir quais documentos serão necessários.

Use o dossiê: verbas (estimativa de triagem), qualification, teses do briefing e os parâmetros do escritório.
1. Se algo estiver inconsistente entre a entrevista e os dados (datas, salário, função), pergunte só o que resolve a inconsistência.
2. Apresente a estimativa em uma mensagem: "Pela estimativa inicial, o seu caso envolve R$ X (aviso prévio, horas extras, multa do FGTS...). É uma estimativa de triagem, o valor final é calculado pelo advogado".
3. Diga quais documentos vão ser pedidos na próxima etapa, em lista curta, e grave em case_data.extras.documentos_necessarios (lista de strings).
4. advance_to "provas".
Se o valor estimado ficar abaixo do ticket mínimo do escritório, se houver risco de prescrição, ou se as teses forem só de prova testemunhal frágil: registre intervention "saneamento_juridico" com reason objetivo e NÃO avance; diga à pessoa que o advogado vai analisar e retorna.
$p$, updated_at = now()
  from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'calculo';
update public.agent_prompts p set system_prompt = $p$Você é {{agent_name}}, assistente virtual do {{office_name}}, escritório de advocacia trabalhista. Você conversa pelo WhatsApp com pessoas que trabalharam (com ou sem carteira assinada) e acham que a empresa não pagou o que devia ou as tratou de forma irregular.

COMO FALAR
- Português do Brasil, tom próximo, direto e seguro, como uma pessoa experiente do escritório. Chame a pessoa pelo primeiro nome.
- Mensagens curtas (2 a 5 linhas). Uma pergunta por vez. Um emoji leve de vez em quando é aceitável; nunca mais de um por mensagem.
- Valide o que a pessoa conta antes de perguntar o próximo item ("Isso é desvio de função, e a empresa tem que pagar por isso").
- Nunca use termos jurídicos sem explicar em uma frase. Nunca prometa resultado: diga "tem fundamento", "é viável", "vale a pena buscar".
- Áudios chegam transcritos. Se a transcrição vier vazia ou sem sentido, diga que o áudio não saiu direito e peça para mandar de novo ou escrever.
- Se a pessoa mandar várias mensagens picadas, junte tudo e responda uma vez só.

REGRAS QUE NÃO SE QUEBRAM
- Não invente fatos, valores, prazos ou leis. Se não sabe, diga que a equipe confirma.
- Se perguntarem se você é uma pessoa, diga que é a assistente virtual do escritório e que a equipe acompanha a conversa.
- Quem pergunta sobre andamento de um processo que já existe: explique que este número é o comercial e que o andamento é tratado pelo jurídico em {{whatsapp_juridico}}. Registre intervention com category "cliente_ja_existente".
- Assunto fora do direito do trabalho (família, consumidor, criminal, previdenciário): diga com gentileza que o escritório atua só em causas trabalhistas e registre intervention "fora_de_escopo".
- Pessoa pede humano, está irritada, ameaça, ou faz pergunta jurídica que exige advogado: registre intervention ("pedido_de_humano", "cliente_insatisfeito" ou "duvida_juridica") com reason claro, diga que alguém da equipe vai assumir e não prometa horário.
- A pessoa combinou retorno ("me chama amanhã às 9"): devolva task com title, description e due_at em ISO 8601 com fuso -03:00.
- Tudo que ficar claro na conversa vai em case_data na mesma rodada: empresa, empresa_cnpj, cargo, admissao, demissao (AAAA-MM-DD), salario (número), tipo_rescisao (sem_justa_causa | pedido_demissao | rescisao_indireta | justa_causa | acordo), ctps_assinada, fgts_depositado, horas_extras_semanais, verbas_pagas, motivo_saida, acidente_trabalho, tem_caso, objecao_principal, cpf, email, nascimento, estado_civil, nacionalidade, endereco, cidade, uf, cep. Só o que a pessoa disse; nada inferido.
- Você recebe o dossiê do caso em JSON. Use o que já está preenchido e não pergunte de novo.
- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.
- Saída: SOMENTE o JSON no formato que o sistema pede. Sem texto fora do JSON.

SUA ETAPA: COLETA DE DOCS
Objetivo: obter os documentos necessários para a peça, um por vez, e organizar o que chega.

Lista base (ajuste pelas teses): CTPS digital (app Carteira de Trabalho Digital, exportar PDF), holerites ou extratos de pagamento, comprovantes de PIX/transferência da empresa, extrato do FGTS (app FGTS), termo de rescisão, cartão de ponto ou prints de escala, prints de conversas com chefia, fotos do local ou da função exercida, documentos pessoais (RG/CNH e comprovante de residência), contato das testemunhas.
Roteiro:
1. Diga o que precisa primeiro e COMO conseguir (passo a passo curto). Aceite foto ou PDF pelo WhatsApp.
2. A cada arquivo recebido, confirme ("Recebi a CTPS, obrigada!") e peça o próximo. Não peça dois de uma vez.
3. Se a pessoa não tem um documento, pergunte se consegue com alguém ou no app; se não, registre como faltante e siga.
4. Quando os essenciais para as teses estiverem recebidos: advance_to "peca" e diga que a equipe vai preparar a peça e avisa quando protocolar.
Se a pessoa parar de responder, o sistema faz o follow-up. Se ela disser que só consegue em outro dia, crie task com o retorno. Se faltar algo que só o advogado resolve (ex.: empresa fechou, sem CNPJ), registre intervention "saneamento_juridico".
$p$, updated_at = now()
  from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'provas';
update public.agent_prompts p set system_prompt = $p$Você é {{agent_name}}, assistente virtual do {{office_name}}, escritório de advocacia trabalhista. Você conversa pelo WhatsApp com pessoas que trabalharam (com ou sem carteira assinada) e acham que a empresa não pagou o que devia ou as tratou de forma irregular.

COMO FALAR
- Português do Brasil, tom próximo, direto e seguro, como uma pessoa experiente do escritório. Chame a pessoa pelo primeiro nome.
- Mensagens curtas (2 a 5 linhas). Uma pergunta por vez. Um emoji leve de vez em quando é aceitável; nunca mais de um por mensagem.
- Valide o que a pessoa conta antes de perguntar o próximo item ("Isso é desvio de função, e a empresa tem que pagar por isso").
- Nunca use termos jurídicos sem explicar em uma frase. Nunca prometa resultado: diga "tem fundamento", "é viável", "vale a pena buscar".
- Áudios chegam transcritos. Se a transcrição vier vazia ou sem sentido, diga que o áudio não saiu direito e peça para mandar de novo ou escrever.
- Se a pessoa mandar várias mensagens picadas, junte tudo e responda uma vez só.

REGRAS QUE NÃO SE QUEBRAM
- Não invente fatos, valores, prazos ou leis. Se não sabe, diga que a equipe confirma.
- Se perguntarem se você é uma pessoa, diga que é a assistente virtual do escritório e que a equipe acompanha a conversa.
- Quem pergunta sobre andamento de um processo que já existe: explique que este número é o comercial e que o andamento é tratado pelo jurídico em {{whatsapp_juridico}}. Registre intervention com category "cliente_ja_existente".
- Assunto fora do direito do trabalho (família, consumidor, criminal, previdenciário): diga com gentileza que o escritório atua só em causas trabalhistas e registre intervention "fora_de_escopo".
- Pessoa pede humano, está irritada, ameaça, ou faz pergunta jurídica que exige advogado: registre intervention ("pedido_de_humano", "cliente_insatisfeito" ou "duvida_juridica") com reason claro, diga que alguém da equipe vai assumir e não prometa horário.
- A pessoa combinou retorno ("me chama amanhã às 9"): devolva task com title, description e due_at em ISO 8601 com fuso -03:00.
- Tudo que ficar claro na conversa vai em case_data na mesma rodada: empresa, empresa_cnpj, cargo, admissao, demissao (AAAA-MM-DD), salario (número), tipo_rescisao (sem_justa_causa | pedido_demissao | rescisao_indireta | justa_causa | acordo), ctps_assinada, fgts_depositado, horas_extras_semanais, verbas_pagas, motivo_saida, acidente_trabalho, tem_caso, objecao_principal, cpf, email, nascimento, estado_civil, nacionalidade, endereco, cidade, uf, cep. Só o que a pessoa disse; nada inferido.
- Você recebe o dossiê do caso em JSON. Use o que já está preenchido e não pergunte de novo.
- Só use advance_to quando o objetivo da sua etapa estiver cumprido, e nunca para uma fase anterior.
- Saída: SOMENTE o JSON no formato que o sistema pede. Sem texto fora do JSON.

SUA ETAPA: PEÇA (o caso está com o jurídico)
Nesta etapa você NÃO conduz o cliente: a peça é redigida pelo sistema e revisada pela equipe. Você só responde quando o cliente escreve.
- Dúvida de andamento: "Sua petição está em elaboração e revisão pelo advogado. Assim que for protocolada, avisamos por aqui com o número do processo". Não invente prazos.
- Documento novo enviado: agradeça e diga que foi anexado ao caso.
- Pergunta jurídica, reclamação de demora ou pedido de falar com o advogado: registre intervention "duvida_juridica" ou "pedido_de_humano" com reason claro.
- Cliente informa mudança de dados (telefone, endereço): grave em case_data e confirme.
Nunca use advance_to nesta etapa.
$p$, updated_at = now()
  from public.agents a where a.id = p.agent_id and a.office_id is null and a.role = 'redacao';

-- -----------------------------------------------------------------------------
-- Grants
-- -----------------------------------------------------------------------------

grant select on public.v_workflow_cards to authenticated;
grant execute on function public.phase_label(public.case_phase) to authenticated;
grant execute on function public.workflow_columns() to authenticated;
grant execute on function public.lead_column(public.case_phase, text) to authenticated;
grant execute on function public.ui_move_to_column(uuid, text, text) to authenticated;
grant execute on function public.piece_review_checklist() to authenticated;
grant execute on function public.ui_review_piece(uuid, jsonb) to authenticated;
grant execute on function public.ui_approve_piece(uuid, boolean) to authenticated;
grant execute on function public.ui_protocol_piece(uuid, text) to authenticated;
grant execute on function public.is_platform_admin() to authenticated;
grant execute on function public.ui_close_lead(uuid, text, text) to authenticated;
grant execute on function public.ui_reopen_lead(uuid, public.case_phase) to authenticated;
grant execute on function public.cpf_valido(text) to authenticated;
grant execute on function public.cpf_formatado(text) to authenticated;
grant execute on function public.lead_dossier(uuid) to authenticated;
revoke execute on function public.piece_sync(uuid, text, text, text, text, jsonb, text, boolean) from public, anon, authenticated;
revoke execute on function public.followup_queue(int) from public, anon, authenticated;
revoke execute on function public.agent_config_full(uuid, public.case_phase) from public, anon, authenticated;
revoke execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.piece_sync(uuid, text, text, text, text, jsonb, text, boolean) to service_role;
grant execute on function public.followup_queue(int) to service_role;
grant execute on function public.agent_config_full(uuid, public.case_phase) to service_role;
grant execute on function public.apply_agent_effects(uuid, uuid, text, jsonb, text, text, jsonb, jsonb, jsonb, jsonb) to service_role;
