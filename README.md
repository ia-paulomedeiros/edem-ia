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

"Aplicada e testada" = `supabase/tests/run.sh` roda 001→003 duas vezes num PostgreSQL 16 limpo
(idempotência) e passa o smoke test: ingestão idempotente, isolamento entre escritórios para leads,
mensagens, tarefas, eventos e `lead_dossier`, trava do takeover, fase com autor, portão, prescrição,
fila e efeitos do agente.

## Decisões que não podem ser violadas

- A trava do takeover mora no banco (`conversations.ai_paused` + `ai_should_reply()`), nunca na UI.
- Nenhuma mensagem vai para o WhatsApp sem virar linha em `messages` primeiro.
- A fase é uma coluna só (`leads.phase`). Kanban, lista, funil e dashboard são projeções.
- Todo evento nomeia o autor (`case_events.actor`; `leads.closed_by`).
- Segredo não vai para tabela: token no Vault, no schema só o nome da referência.

Detalhes em `docs/01-blueprint.md`. Backlog em `docs/02-recalibragem-sprints.md`.

## Como aplicar no Supabase

1. SQL Editor: rodar `supabase/001_schema.sql`, depois `002_dominio_juridico.sql`, depois
   `003_caso_unico.sql`. Todas são idempotentes; nunca editar uma já aplicada.
2. Vault: criar o segredo com o token permanente da Meta (ex.: nome `wa_token_<escritorio>`).
3. Cadastrar escritório, membro e número:
   ```sql
   insert into public.offices (id, name, slug) values (gen_random_uuid(), 'Meu Escritório', 'meu') returning id;
   insert into public.office_members (office_id, user_id, role) values ('<office_id>', '<auth.users.id>', 'admin');
   insert into public.whatsapp_numbers (office_id, phone_number_id, waba_id, display_phone, token_secret_name)
   values ('<office_id>', '<phone_number_id da Meta>', '<waba_id>', '55119...', 'wa_token_meu');
   ```
4. Database Webhooks: INSERT em `public.messages` → `<n8n>/webhook/supabase/messages`, header
   `x-webhook-secret`.
5. n8n: importar os três JSON, criar credencial Postgres (connection string com `service_role`) e
   Anthropic, definir `WA_VERIFY_TOKEN`, `SUPABASE_WEBHOOK_SECRET`, `LLM_PRICE_IN_PER_MTOK`,
   `LLM_PRICE_OUT_PER_MTOK`. Ativar os três.
6. Meta: webhook `<n8n>/webhook/whatsapp` com o `WA_VERIFY_TOKEN`; assinar `messages`.
7. Lovable: conectar o Supabase e seguir `lovable/PROMPT-v1.md`, depois `PROMPT-v2.md`.

## Como testar localmente

Precisa de um PostgreSQL 16 acessível (não o Supabase de produção: o shim cria um `auth` falso).

```bash
supabase/tests/run.sh "-h localhost -p 5432 -U postgres"
```

Saída esperada termina em `SMOKE OK`.

## Estrutura

```
docs/       blueprint e recalibragem do backlog
supabase/   migrations 001..003 e tests/ (shim + smoke)
n8n/        três workflows exportados
lovable/    prompts de build v1 (monitor) e v2 (caso único)
```

## Pendências de produto

- Nome e domínio do produto.
- Modelo de cobrança (escritório, usuário ou volume).
- Conteúdo de `agents.system_prompt` dos sete agentes.
