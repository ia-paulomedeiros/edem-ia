# Recalibragem — o concorrente por dentro e o backlog refeito

## Por que recalibrar

O blueprint original tratava o produto como "inbox com IA". Olhando o concorrente em uso, o que
prende o escritório não é a inbox: é o **caso como objeto**. A conversa é só uma das lentes sobre
ele. Isso muda a ordem do backlog: o domínio jurídico entra antes de qualquer tela bonita, e a UI
do caso vem antes de contrato, peça e dashboard.

## O concorrente, por função (não por tela)

Descrito por estrutura, sem nome, logotipo, identidade ou texto copiados. Só o que o produto faz.

| Função | O que entrega | O que fazemos igual | O que fazemos diferente |
|---|---|---|---|
| Atendimento por IA no WhatsApp | Agente responde 24h, coleta dados, agenda | Sim, com um agente por fase | Agente muda com a fase; o prompt de cada um é versionado em `agents` |
| Monitor em tempo real | Equipe vê todas as conversas e assume | Sim | Trava no banco, não na UI; enviar manual já assume |
| Funil / kanban | Lead anda por etapas | Sim | Etapas são um enum tipado; IA não retrocede; todo movimento tem autor |
| Qualificação | Filtra lead sem caso | Sim | Portão explícito e parametrizável por escritório (ticket, vínculo, prescrição) |
| Cálculo | Estimativa de verbas na triagem | Sim | Função no banco, auditável, com aviso de que não é perícia |
| Prescrição | Alerta | Sim | Coluna indexada, alerta no card antes de perguntar |
| Provas | Coleta de documentos | Sim | Checklist por tese; bucket privado por escritório |
| Contrato | Envio e assinatura | Sprint 3 | Provedor de assinatura plugável (`signature_provider`) |
| Peça | Minuta a partir do caso | Sprint 4 | Modelo por tese com placeholders; revisão humana obrigatória |
| Fila de humano | Escalação | Sim | Fila com prioridade; IA cala enquanto há item aberto |
| Custo | Relatório | Sprint 5 | Custo por lead derivado de `ai_meta`, nunca digitado |

## Backlog por sprint

### Sprint 0 — Fundação (feito)
Schema multi-tenant com RLS por escritório, inbox em Realtime, takeover travado no banco, três
workflows n8n (verificação do webhook, inbound com agente, envio manual), cinco prompts de build do
monitor (`lovable/PROMPT-v1.md`).

### Sprint 1 — Domínio jurídico (feito: `supabase/002_dominio_juridico.sql`)
Máquina de fases (`case_phase`, `advance_phase`), sete agentes (`agent_for_phase`), portão
(`qualification_gate`), verbas (`calc_verbas`), prescrição (`leads.prescricao_em`), provas,
contrato, briefing, peça com modelos por tese, fila de intervenção, custo de aquisição,
`lead_dossier()`, `apply_agent_effects()` para o n8n.
**Pendente do Sprint 1:** o conteúdo de `agents.system_prompt` dos sete agentes.

### Sprint 2 — O caso como objeto único (este: `003_caso_unico.sql` + `lovable/PROMPT-v2.md`)
Modal de caso único (kanban, lista e busca), alimentado por `lead_dossier()`. Abas Histórico,
Conversa, Dados, Qualificação, Provas. Prescrição no card com alerta pela janela do escritório.
Aceite: mover a fase no kanban grava evento com autor e a linha do tempo reflete em outra aba sem
refresh.

### Sprint 3 — Contrato e assinatura
Geração do contrato de honorários a partir de `office_params.honorarios_percent` e do dossiê;
integração com um provedor de assinatura (webhook de assinado → `contracts.signed_at` →
`advance_phase('briefing','sistema')`). Mídia recebida no WhatsApp baixada para o bucket `provas`
e ligada a `evidences.message_id`.

### Sprint 4 — Briefing e peça
Agente de briefing conduz a entrevista e preenche `briefings.answers`; agente de redação monta
`pieces.content` a partir de `piece_templates` da tese; tela de revisão com diff e aprovação por
advogado (`reviewed_by`), status `protocolada` com número de protocolo.

### Sprint 5 — Dashboard, custo e cobrança
Funil por fase (projeção de `leads.phase`), tempo médio por fase (`case_events`), custo por lead e
por contrato assinado (`lead_acquisition_cost`), taxa do portão. Modelo de cobrança (pendência de
produto) e medição do que for escolhido (escritório, usuário ou volume).

### Sprint 6 — Onboarding e identidade
Nome e domínio (pendência), e-mail transacional, convite de membros, cadastro guiado do número da
Meta, criação do segredo no Vault pelo painel.

## Pendências de produto (não de código)

- Nome e domínio. Trava identidade visual, e-mail transacional e onboarding.
- Modelo de cobrança: por escritório, por usuário ou por volume de conversa.
- Prompt de cada um dos sete agentes.
