# Blueprint — arquitetura e decisões

> A seção de roadmap deste documento está superada por `docs/02-recalibragem-sprints.md`.

## O produto

CRM conversacional vertical para escritórios de advocacia trabalhista. Agentes de IA atendem leads
no WhatsApp (Cloud API oficial da Meta); a equipe monitora tudo em tempo real e pode assumir
qualquer conversa. O caso anda por fases até virar contrato e peça.

## Stack

| Camada | Escolha | Por quê |
|---|---|---|
| Front | Lovable (React, Vite, TS, Tailwind, shadcn) | Velocidade de UI; integração nativa com Supabase |
| Dados | Supabase (Postgres 16, Auth, Realtime, RLS, Storage, Vault) | Multi-tenant por RLS; Realtime pronto; segredo no Vault |
| Orquestração | n8n | Webhook da Meta, agentes, envio; fácil de auditar por execução |
| Canal | WhatsApp Cloud API (Meta) | Oficial; sem risco de banimento por API não oficial |
| LLM | Anthropic (Claude), via nó do n8n | Modelo por agente em `agents.model` |

## Decisões que não podem ser violadas

1. **A trava do takeover mora no banco.** `conversations.ai_paused` + `ai_should_reply()`. O n8n
   consulta o Postgres antes de gerar qualquer resposta. A UI só chama `take_over()` /
   `release_to_ai()`. Enviar mensagem manual também pausa (trigger).
2. **Nenhuma mensagem vai para o WhatsApp sem virar linha em `messages` primeiro.** O envio é
   consequência da linha: o n8n insere (IA) ou reage ao insert (humano), chama a Graph API e
   atualiza `status`. Se a Meta falhar, a linha fica `failed` com `error`.
3. **A fase é uma coluna só.** `leads.phase` (enum `case_phase`). Kanban, lista, funil e dashboard
   são projeções (`v_case_cards`). Só `advance_phase()` muda; a UI usa `ui_advance_phase()`, que
   força `actor='humano'` e `auth.uid()`.
4. **Todo evento nomeia o autor.** `case_events.actor in ('ia','humano','sistema')`, com
   `actor_user_id` obrigatório para humano e `actor_agent` para IA. Encerramento carrega
   `leads.closed_by ('ia'|'equipe')`. A UI não consegue inserir evento em nome da IA (policy).
5. **Segredo não vai para tabela.** `whatsapp_numbers.token_secret_name` guarda o nome do segredo no
   Vault. O n8n (service_role) resolve `vault.decrypted_secrets` na hora de enviar.

## Fluxos

### Inbound (lead escreve)

```
Meta → n8n 02 (POST /whatsapp) → ingest_inbound()  [contato, lead aberto, conversa, linha 'in']
     → ai_should_reply(conversation)?  não → fim (equipe está com a conversa, ou caso encerrado, ou fila aberta)
     → agent_config(office, phase) + conversation_context() + lead_dossier()
     → LLM (system_prompt do agente + dossiê) → JSON {reply, advance_to, intervention, case_data}
     → insert messages ('out','ia','pending', ai_meta)        ← a linha nasce antes do envio
     → apply_agent_effects()  [case_data com autor IA, advance_phase('ia'), request_intervention]
     → token do Vault → Graph API → update messages status 'sent'|'failed'
```

Status de entrega (`sent/delivered/read/failed`) chegam pelo mesmo webhook e atualizam a linha por
`wa_message_id`.

### Outbound manual (equipe escreve)

```
UI → send_manual_message(conversation, body)  [linha 'out','humano','pending', sent_by; trigger pausa IA + evento takeover]
   → Supabase Database Webhook (INSERT em messages) → n8n 03 → Vault → Graph API → status
```

### Fase

```
Kanban/modal → ui_advance_phase(lead, fase, motivo) → advance_phase(..., 'humano', auth.uid())
n8n          → apply_agent_effects(...)              → advance_phase(..., 'ia', agente)
                                                      → case_events 'phase_changed' {from,to,reason}
                                                      → Realtime (leads, case_events) → todas as abas abertas
```

## Modelo de dados (resumo)

- **Tenant:** `offices`, `office_members(role admin|advogado|atendente)`, `office_params`, `profiles`.
- **Canal:** `whatsapp_numbers`, `contacts`, `conversations`, `messages(ai_meta)`.
- **Caso:** `leads(phase, tese, prescricao_em, closed_by)`, `case_data`, `lead_qualification`,
  `evidences`, `contracts`, `briefings`, `piece_templates`, `pieces`, `tasks`, `case_events`,
  `human_interventions`.
- **Agentes:** `agents(role, system_prompt, model)`; `agent_for_phase()`, `agent_config()`.
- **Projeções:** `v_case_cards`, `lead_acquisition_cost`, `lead_dossier()`.

Detalhe e comentários: `supabase/001_schema.sql`, `002_dominio_juridico.sql`, `003_caso_unico.sql`.

## Segurança

- RLS em todas as tabelas; helper `is_office_member(office_id)` (security definer para não recursionar).
- `service_role` só no n8n. O front nunca vê essa chave.
- Funções chamadas pelo cliente são `security definer` com verificação explícita de membro e usam
  `auth.uid()` como autor; funções do n8n têm `execute` revogado de `anon`/`authenticated`.
- Storage: bucket `provas` privado, caminho `<office_id>/<lead_id>/...`, policy pelo primeiro segmento.
- Realtime com RLS: `replica identity full` em `leads`, `conversations`, `case_events` para o filtro
  por linha funcionar em UPDATE.

## Ambientes

- **Supabase:** um projeto por ambiente (dev, prod). Migrations aplicadas na ordem pelo SQL Editor
  ou `supabase db push`. Nunca editar migration aplicada: escrever `00N_*.sql` nova.
- **n8n:** variáveis `WA_VERIFY_TOKEN`, `SUPABASE_WEBHOOK_SECRET`, `LLM_PRICE_IN_PER_MTOK`,
  `LLM_PRICE_OUT_PER_MTOK`; credenciais Postgres (service_role) e Anthropic.
- **Meta:** app com produto WhatsApp; webhook apontando para `<n8n>/webhook/whatsapp` com o
  `WA_VERIFY_TOKEN`; token permanente do System User guardado no Vault com o nome que está em
  `whatsapp_numbers.token_secret_name`.

## Custo de aquisição

Cada mensagem da IA carrega `ai_meta {agent_role, model, tokens_in, tokens_out, cost_usd}` calculado
no n8n a partir do uso reportado pelo modelo e dos preços em variável de ambiente. A view
`lead_acquisition_cost` soma por lead; o dashboard cruza com contratos assinados (Sprint 5).

## Roadmap (superado — ver 02-recalibragem-sprints.md)

Mantido só como histórico: Sprint 0 fundação → Sprint 1 domínio → Sprint 2 caso único →
Sprint 3 contrato e assinatura → Sprint 4 briefing e peça → Sprint 5 dashboard e cobrança.
