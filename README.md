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
| Sprint 3 — prompts de paridade: navegação, identidade, dashboard, Clientes, Finalizados, Histórico, Jurídico, Agendamentos, Configurações, Marketing | `lovable/PROMPT-v3.md` | 9 prompts |
| Dados de demonstração (60 leads no mês, contratos, custos, empresa, integrações, 47 modelos) | `supabase/seed_demo.sql` | Testado; reversível |

"Aplicada e testada" = `supabase/tests/run.sh` roda 001→010 duas vezes num PostgreSQL 16 limpo
(idempotência) e passa dois testes: o smoke (ingestão idempotente, isolamento entre escritórios para
leads, mensagens, tarefas, eventos e `lead_dossier`, trava do takeover, fase com autor, portão,
prescrição, fila, efeitos do agente, integrações com Vault, modelos, prompts invisíveis) e o de dashboard
(seed de 60 leads, as cinco RPCs como membro, marketing e custo por lead) (seed de 60 leads e as cinco RPCs como membro).

## Decisões que não podem ser violadas

- A trava do takeover mora no banco (`conversations.ai_paused` + `ai_should_reply()`), nunca na UI.
- Nenhuma mensagem vai para o WhatsApp sem virar linha em `messages` primeiro.
- A fase é uma coluna só (`leads.phase`). Kanban, lista, funil e dashboard são projeções.
- Todo evento nomeia o autor (`case_events.actor`; `leads.closed_by`).
- Segredo não vai para tabela: token no Vault, no schema só o nome da referência. O cliente grava
  por `set_integration()` e nunca lê de volta; só o n8n (service_role) resolve o valor.
- Prompts dos agentes (`agent_prompts`) e esqueletos internos (`piece_templates`) não têm policy:
  invisíveis para qualquer usuário do produto.

Detalhes em `docs/01-blueprint.md`. Backlog em `docs/02-recalibragem-sprints.md`.

## Como aplicar no Supabase

1. SQL Editor: colar `supabase/apply_all.sql` (001..010 juntas) e executar. Ou rodar
   `001_schema.sql`, `002_dominio_juridico.sql`, `003_caso_unico.sql`, `004_dashboard.sql`,
   `005_funil.sql`, `006_dashboard_periodo.sql`, `007_fila.sql`, `008_configuracoes.sql`,
   `009_marketing.sql` e `010_juridico_agenda.sql` nessa ordem. Todas são idempotentes; nunca editar uma já aplicada. `apply_all.sql` é gerado a partir
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
4. Database Webhooks: INSERT em `public.messages` → `<n8n>/webhook/supabase/messages`, header
   `x-webhook-secret`.
5. n8n: importar os quatro JSON (o 04 importa custos de marketing uma vez por dia), criar credencial Postgres (connection string com `service_role`) e
   Anthropic, definir `WA_VERIFY_TOKEN`, `SUPABASE_WEBHOOK_SECRET`, `LLM_PRICE_IN_PER_MTOK`,
   `LLM_PRICE_OUT_PER_MTOK`. Ativar os três.
6. Meta: webhook `<n8n>/webhook/whatsapp` com o `WA_VERIFY_TOKEN`; assinar `messages`.
7. Lovable: conectar o Supabase e seguir `lovable/PROMPT-v1.md` (prompts 1 e 2), depois
   `PROMPT-v3.md` (casca e dashboard), depois o restante do v1 e o `PROMPT-v2.md`.

## Como testar localmente

Precisa de um PostgreSQL 16 acessível (não o Supabase de produção: o shim cria um `auth` falso).

```bash
supabase/tests/run.sh "-h localhost -p 5432 -U postgres"
```

Saída esperada termina em `SMOKE OK`.

## Estrutura

```
docs/       blueprint e recalibragem do backlog
supabase/   migrations 001..010, apply_all.sql, seed_demo.sql e tests/ (shim + smoke + dashboard)
n8n/        quatro workflows exportados (verificação, inbound com agente, envio manual, importação de custos)
lovable/    prompts de build v1 (monitor), v2 (caso único) e v3 (paridade e dashboard)
```

## Pendências de produto

- Nome e domínio do produto.
- Modelo de cobrança (escritório, usuário ou volume).
- Conteúdo de `agent_prompts.system_prompt` dos sete agentes (por SQL, com service_role; não há tela).
