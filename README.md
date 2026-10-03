# edem-ia — plataforma jurídica com IA

CRM conversacional para escritórios de advocacia trabalhista: agentes de IA atendem leads no
WhatsApp, a equipe monitora em tempo real e assume quando quiser, e o caso anda por fases até virar
contrato e peça.

Stack: Lovable (React/Vite/TS/Tailwind/shadcn) + Supabase (Postgres, Auth, Realtime, RLS, Storage,
Vault) + n8n + WhatsApp Cloud API.

## O que está pronto e verificado

| Entrega | Onde | Estado |
|---|---|---|
| Sprint 0 — fundação multi-tenant, inbox Realtime, takeover no banco | `supabase/001_schema.sql` | Aplicada e testada |
| Sprint 0 — workflows n8n (verificação, inbound com agente, envio manual) | `n8n/*.json` | JSON válido; importar e configurar credenciais |
| Sprint 0 — prompts de build do monitor | `lovable/PROMPT-v1.md` | 5 prompts |
| Sprint 1 — domínio jurídico (fases, agentes, portão, verbas, prescrição, provas, contrato, briefing, peça, fila, custo, dossiê) | `supabase/002_dominio_juridico.sql` | Aplicada e testada |
| Sprint 2 — caso único (profiles, cards, `ui_advance_phase`, eventos automáticos, Realtime, dossiê v2, bucket) | `supabase/003_caso_unico.sql` | Aplicada e testada |
| Sprint 2 — prompts de build do modal de caso, kanban, lista, abas | `lovable/PROMPT-v2.md` | 8 prompts |
| Sprint 3 — dashboard (5 abas), UF, valor de causa, trigger de contrato | `supabase/004_dashboard.sql` | Aplicada e testada |
| Sprint 3 — funil de venda em quatro macro-etapas com lista de leads por etapa | `supabase/005_funil.sql` | Aplicada e testada |
| Sprint 3 — período livre, jornada por agente, produtividade da fila (desfecho), investimento Ads + tokens em BRL, protocolos | `supabase/006_dashboard_periodo.sql` | Aplicada e testada |
| Sprint 3 — fila como esteira: grupos por tipo, P1..P4, observação, marcadores, ligações, atribuição, `v_intervention_cards` | `supabase/007_fila.sql` | Aplicada e testada |
| Sprint 3 — configurações no layout do concorrente: dados da empresa, integrações com segredo no Vault, modelos de petição como biblioteca de arquivos, prompts dos agentes ocultos | `supabase/008_configuracoes.sql` | Aplicada e testada |
| Sprint 3 — Marketing: lançamentos por dia (anúncios + tokens, manual ou importado), tokens lançado > estimado, custo por lead, importação Meta Ads / Anthropic Admin / OpenAI Admin | `supabase/009_marketing.sql` + `n8n/04_marketing_import.json` | Aplicada e testada; n8n JSON válido |
| Sprint 3 — Jurídico como esteira (Revisão, Aguardando, Saneamento, Pronto p/ protocolo, Protocolado) com alerta e responsável, agenda por dia com tarefas do agente, limpeza do linter (search_path, execução só authenticated/service_role) | `supabase/010_juridico_agenda.sql` | Aplicada e testada |
| Sprint 4 — caso completo: CPF/endereço, CNPJ/objeções, encerrar com motivo, pausa, supervisor/protocolador, Drive, ações da intervenção, contrato com assinatura eletrônica (Autentique via n8n), briefing estruturado, régua de follow-up | `supabase/011_caso_completo.sql` + `n8n/05_contract_signature.json` + `n8n/06_followup.json` | Aplicada e testada; n8n JSON válido |
| Sprint 4 — fila por lead e conclusão em lote (`v_intervention_leads`, `resolve_lead_interventions`) | `supabase/012_fila_por_lead.sql` | Aplicada e testada |
| Sprint 4 — fluxo do concorrente: contrato antes de cálculo/provas, quadro de 7 colunas, Petição com checklist/aprovação/protocolo, modelos internos (platform_admins), presença digital e WhatsApp do jurídico, encerrar com tipo, templates da Meta, CPF validado, prompts dos 7 agentes, áudio transcrito | `supabase/013_fluxo_laquila.sql` + n8n 02/03/06 | Aplicada e testada |
| Sprint 3/4 — prompts de paridade: navegação, identidade, dashboard, Clientes, Finalizados, Histórico, Jurídico, Agendamentos, Configurações, Marketing, caso completo, fila por lead, fluxo do concorrente | `lovable/PROMPT-v3.md` | 13 prompts |
| Dados de demonstração (60 leads no mês, contratos, custos, empresa, integrações, 47 modelos; desde a 014/015 também persona, métricas, cálculo versionado, documentos e agendamentos) | `supabase/seed_demo.sql` | Testado; reversível |
| Sprint 4c — paridade de regras com a Láquila: faixas LOW/MID/HIGH, vínculo mínimo por tipo de saída, métricas comerciais e taxa de manutenção (`ui_save_empresa`), encerramento por motivo (Inviável/Insanável), etapa detalhada do lead, agentes com persona + Saneador e agente por lead, jornada de 5 etapas, Marketing Claude/OpenAI, views novas (`v_clientes`, `v_fluxo_cards`, `v_juridico_cards`, `v_fila_leads`, `v_marketing_dia`) | `supabase/014_paridade_regras.sql` + n8n 02/06 | Testada localmente (`run.sh`); aplicar no Supabase |
| Sprint 4c — automações: documentos do WhatsApp no caso (`ingest_media`), agendamentos que a IA retoma, monitores da fila, Calculista com qualificação versionada, geração da peça, mensageria/assinatura por provedor | `supabase/015_paridade_automacoes.sql` + `n8n/08..11` + n8n 02/03/05 | Testada localmente (`run.sh`); n8n JSON válido; Datacrazy pendente |
| Sprint 4c — prompts de paridade de regras (etapa, persona, Empresa, Finalizados por tipo, Histórico de tarefas, Documentos, Qualificação, Agendamentos, alertas da fila) | `lovable/PROMPT-v4.md` | 7 prompts (14–20) |

"Aplicada e testada" = `supabase/tests/run.sh` roda 001→015 duas vezes num PostgreSQL 16 limpo
(idempotência) e passa três testes: o smoke (ingestão idempotente, isolamento entre escritórios, trava do
takeover, fase com autor, portão, prescrição, fila, efeitos do agente, integrações com Vault, prompts
invisíveis), o de dashboard (seed de 60 leads, RPCs como membro, marketing e custo por lead) e o de
paridade (`30_paridade.sql`: faixas, vínculo por tipo de saída, Empresa, motivos de encerramento, etapa em
cada estado, agente por lead e Saneador, Marketing Claude/OpenAI, documentos, agendamentos, monitores
idempotentes, Calculista, geração da peça, provedor de mensageria e privilégios).

Por que existem views novas na 014: o `run.sh` reaplica tudo duas vezes e o Postgres não deixa um
`create or replace view` tirar colunas; se a 014 acrescentasse colunas em `v_case_cards`,
`v_workflow_cards`, `v_legal_cards`, `v_intervention_leads` ou `v_marketing_lancamentos`, a reaplicação
de 003/009/010/012/013 quebraria. As antigas continuam iguais; as telas passam a ler as novas.

## Decisões que não podem ser violadas

- A trava do takeover mora no banco (`conversations.ai_paused` + `ai_should_reply()`), nunca na UI.
- Nenhuma mensagem vai para o WhatsApp sem virar linha em `messages` primeiro.
- A fase é uma coluna só (`leads.phase`). Kanban, lista, funil e dashboard são projeções. Ordem (013):
  Closer (novo, triagem, qualificacao, contrato) → Entrevista (briefing) → Viabilidade (calculo) →
  Coleta de docs (provas) → Peça (peca; Saneamento/Revisão/Peça pela etapa da peça).
- Todo evento nomeia o autor (`case_events.actor`; `leads.closed_by`). Etapa detalhada do lead
  (`lead_etapa`) é projeção de fase + contrato + briefing + qualificação + peça + takeover, nunca coluna.
- Todo envio de saída passa pelo WA 03 (Database Webhook em `messages`): os outros fluxos só gravam a linha.
- Segredo não vai para tabela: token no Vault, no schema só o nome da referência. O cliente grava
  por `set_integration()` e nunca lê de volta; só o n8n (service_role) resolve o valor.
- Prompts dos agentes (`agent_prompts`) e esqueletos internos (`piece_templates`) não têm policy:
  invisíveis para qualquer usuário do produto.

Detalhes em `docs/01-blueprint.md`. Backlog em `docs/02-recalibragem-sprints.md`.

## Como aplicar no Supabase

1. SQL Editor: colar `supabase/apply_all.sql` (001..015 juntas) e executar. Ou rodar
   `001_schema.sql`, `002_dominio_juridico.sql`, `003_caso_unico.sql`, `004_dashboard.sql`,
   `005_funil.sql`, `006_dashboard_periodo.sql`, `007_fila.sql`, `008_configuracoes.sql`,
   `009_marketing.sql`, `010_juridico_agenda.sql`, `011_caso_completo.sql`, `012_fila_por_lead.sql`, `013_fluxo_laquila.sql`, `014_paridade_regras.sql` e `015_paridade_automacoes.sql` nessa ordem. Todas são idempotentes; nunca editar uma já aplicada. `apply_all.sql` é gerado a partir
   das individuais (`supabase/tests/run.sh` não o usa); regenere quando criar uma migration nova.
   Opcional: `seed_demo.sql` cria 60 leads de demonstração (reversível pelo bloco LIMPEZA).
2. Token da Meta: pelo painel, Configurações → Integrações → WhatsApp Cloud API (Meta), que chama
   `set_integration()` e cria o segredo no Vault e o número em `whatsapp_numbers`. Alternativa manual:
   criar o segredo no Vault e cadastrar o número como abaixo.
3. Cadastrar escritório, membro e número:
   ```sql
   insert into public.offices (id, name, slug) values (gen_random_uuid(), 'Meu Escritório', 'meu') returning id;
   insert into public.office_members (office_id, user_id, role) values ('<office_id>', '<auth.users.id>', 'admin');
   insert into public.whatsapp_numbers (office_id, phone_number_id, waba_id, display_phone, token_secret_name)
   values ('<office_id>', '<phone_number_id da Meta>', '<waba_id>', '55119...', 'wa_token_meu');
   ```
4. Database Webhooks: INSERT em `public.messages` → `<n8n>/webhook/supabase/messages`; INSERT e UPDATE
   em `public.contracts` → `<n8n>/webhook/supabase/contracts`; ambos com o header `x-webhook-secret`.
5. n8n: importar os dez JSON e ativar todos.
   - 01 verificação da Meta; 02 inbound com agente (agente por lead, documentos recebidos viram prova);
     03 envio de toda mensagem pendente pelo provedor ativo; 04 custos de marketing (diário);
     05 contrato/assinatura (precisa do Gotenberg); 06 régua de follow-up (30 min).
   - Novos na 014/015: 08 geração da peça (2 min), 09 agendamentos que a IA retoma (5 min),
     10 monitores da fila (10 min), 11 Calculista (5 min). São agendados: nenhum Database Webhook novo.
   - Credenciais: Postgres `Supabase (service_role)` (session pooler), `Anthropic`, e, para subir os
     documentos no bucket `provas`, `Supabase API (service_role)` (tipo Supabase: host do projeto +
     service_role key).
   - Variáveis (no main e no worker): `WA_VERIFY_TOKEN`, `SUPABASE_WEBHOOK_SECRET`,
     `LLM_PRICE_IN_PER_MTOK`, `LLM_PRICE_OUT_PER_MTOK`, `MARKETING_IMPORT_DAYS`, `GOTENBERG_URL`,
     `SUPABASE_URL` (ex.: `https://<projeto>.supabase.co`) e `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`.
6. Meta: webhook `<n8n>/webhook/whatsapp` com o `WA_VERIFY_TOKEN`; assinar `messages`.
7. Lovable: conectar o Supabase e seguir `lovable/PROMPT-v1.md` (prompts 1 e 2), depois
   `PROMPT-v3.md` (casca e dashboard), depois o restante do v1 e o `PROMPT-v2.md`. Depois da 014/015,
   `PROMPT-v4.md` (prompts 14–20), sempre regenerando os tipos antes.

## Como testar localmente

Precisa de um PostgreSQL 16 acessível (não o Supabase de produção: o shim cria um `auth` falso).

```bash
supabase/tests/run.sh "-h localhost -p 5432 -U postgres"
```

Saída esperada: `SMOKE OK`, `DASHBOARD OK` e `PARIDADE OK`.

## Estrutura

```
docs/       blueprint e recalibragem do backlog
supabase/   migrations 001..015, apply_all.sql, seed_demo.sql e tests/ (shim + smoke + dashboard + paridade)
n8n/        dez workflows exportados (01 verificação, 02 inbound com agente, 03 envio, 04 custos, 05 contrato/assinatura, 06 régua, 08 peça, 09 agendamentos, 10 monitores, 11 Calculista)
lovable/    prompts de build v1 (monitor), v2 (caso único), v3 (paridade e dashboard) e v4 (paridade de regras)
```

## Pendências de produto

- Nome e domínio do produto.
- Modelo de cobrança (escritório, usuário ou volume).
- Prompts dos oito agentes: versão 1 carregada pela 013 (o Saneador entrou na 014) a partir do roteiro real do concorrente; ajustar tom por escritório.
- Datacrazy: envio e recebimento ainda não implementados. A documentação oficial (docs.datacrazy.io) é bloqueada pela rede da sessão de desenvolvimento; o WA 02/03 já têm o ramo do provedor esperando os nós.
- ZapSign e Clicksign: ramos com TODO no n8n 05 (registram a falha no contrato).
- Modelos de petição visíveis/editáveis pelo escritório (como na Láquila) ou só internos (hoje, 013): decisão do Paulo.
