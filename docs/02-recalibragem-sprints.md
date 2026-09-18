# Recalibragem — o concorrente por dentro e o backlog refeito

## Por que recalibrar

O blueprint original tratava o produto como "inbox com IA". Olhando o concorrente em uso, o que
prende o escritório não é a inbox: é o **caso como objeto**. A conversa é só uma das lentes sobre
ele. Isso muda a ordem do backlog: o domínio jurídico entra antes de qualquer tela bonita, e a UI
do caso vem antes de contrato, peça e dashboard.

## O concorrente, por dentro

Observado no produto em uso (setembro/2026). Descrito por estrutura, sem nome, logotipo,
identidade ou texto copiados.

**Navegação (barra lateral).** Bloco "Empresa" com o nome do escritório; nove itens: Dashboard,
Fluxo de Trabalho, Intervenção humana, Jurídico, Agendamentos, Clientes, Finalizados, Histórico,
Marketing. Rodapé com usuário, papel e ações: notificações, tema escuro, configurações, sair,
recolher.

**Dashboard.** Filtro de período (Todo o período, Hoje, Ontem, Últimos 7 dias, Este mês,
Personalizado) e por agente/usuário; "Limpar tudo". Cinco abas:
- *Geral*: contratos fechados (hoje, semana, mês, em anéis), contratos por dia (barras), regiões
  por UF (barras horizontais), contratos por tipo de ticket (HT/MT/LT com quantidade e valor,
  total), valor de causa por dia (área).
- *Funil de Venda*: quatro macro-etapas (novos leads, taxa de abertura com régua de 2+ msgs, links
  enviados, contratos fechados) em funil e em cards com % do topo, conversão da etapa e intervenção
  humana; clique lista os leads; contratos por ticket ao lado.
- *Jornada do Cliente*: cards por agente (concluído, em fluxo, intervenção humana) com o tempo médio
  entre etapas; clique lista os clientes.
- *Produtividade Humana*: intervenções concluídas, em andamento, tempo médio, maior produtor; "por
  forma" (desfecho), "por tipo de tarefa", ranking por pessoa, conclusões por dia.
- *Investimento Financeiro*: Ads + tokens em BRL cruzado com contratos e protocolos, total e dia a
  dia, custo por contrato e por protocolo.

**Mapa para o nosso schema.**

| Item do concorrente | Nosso | Estado |
|---|---|---|
| Dashboard (5 abas, período livre) | `dashboard_*_p` (004..006) | RPCs prontas; UI em `PROMPT-v3` |
| Gasto com anúncios | `ad_spend` (006) | 006 |
| Desfecho da intervenção (por forma) | `human_interventions.outcome` (006) | 006 |
| Protocolos | `pieces.protocolado_em` (006) | 006 |
| Fluxo de Trabalho | `/casos` (kanban + lista sobre `v_case_cards`) | `PROMPT-v2` |
| Intervenção humana | `/fila` sobre `human_interventions` | `PROMPT-v1` |
| Jurídico | `/juridico`: `contracts` + `pieces` | `PROMPT-v3` |
| Configurações (Meu perfil, Empresa, Integrações, Modelos de petição) | `offices` cadastral, `integrations` + Vault, `piece_models` + bucket `modelos` (008) | 008; UI em `PROMPT-v3` Prompt 7 |
| Agendamentos | `/agendamentos` sobre `tasks.due_at` | `PROMPT-v3` |
| Clientes | `/clientes`: contatos com contrato assinado (`contacts.uf`) | `PROMPT-v3` |
| Finalizados | `/finalizados`: `leads.phase='encerrado'` + `closed_by` | `PROMPT-v3` |
| Histórico | `/historico`: feed de `case_events` | `PROMPT-v3` |
| Marketing (custos: Ads + tokens por dia, importação) | `ad_spend` como lançamentos, `v_marketing_lancamentos`, `marketing_*_p`, `lead_cost` (009) + `n8n/04` | 009; UI em `PROMPT-v3` Prompt 8 |
| Contratos por ticket (HT/MT/LT) | `contracts.faixa` (alto/medio/baixo) via `faixa_ticket()` | 004 |
| Regiões por UF | `contacts.uf` | 004 |
| Valor de causa | `contracts.valor_causa` (default: `lead_qualification.verbas_total`) | 004 |
| Filtro "agentes" do dashboard | `leads.assigned_to` (membro humano) | 004 |

O que fazemos diferente, de propósito: trava do takeover no banco; fase como enum com autor em todo
movimento; portão de qualificação parametrizável; custo de IA derivado de `ai_meta`, nunca digitado;
IA cala enquanto há intervenção aberta.

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

### Sprint 3 — Paridade com o concorrente (antecipado: `004_dashboard.sql` + `lovable/PROMPT-v3.md`)
Navegação igual (dez itens: os nove do concorrente mais Conversas), identidade própria, dashboard
com as cinco abas sobre RPCs de agregação, páginas Clientes, Finalizados, Histórico, Jurídico
(contratos e peças), Agendamentos (tarefas), notificações. `seed_demo.sql` para ver tudo cheio.
Trigger de contrato: assinar preenche valor/faixa, grava evento e avança para briefing.
Configurações no layout do concorrente (`008_configuracoes.sql`): dados cadastrais da empresa,
integrações por provedor com segredo no Vault (só RPC escreve; n8n resolve com service_role e
registra o teste), modelos de petição como biblioteca de arquivos sem limite (bucket `modelos`),
e prompts dos agentes fora do alcance do cliente (`agent_prompts` sem policy; `piece_templates`
idem). Ninguém que usa o produto vê como os agentes são montados.
Marketing (`009_marketing.sql`): lançamentos por dia com anúncios e tokens, manual ou importado
(Meta Ads, Anthropic Admin, OpenAI Admin via `n8n/04`); nos dias sem lançamento de tokens vale a
estimativa pelas mensagens; custo por lead = tokens do caso + rateio dos anúncios do dia, e média
do mês, dentro do dossiê.

### Sprint 3b — Assinatura eletrônica e mídia
Integração com um provedor de assinatura (webhook de assinado → `contracts.status='assinado'`, que
já dispara o resto). Mídia recebida no WhatsApp baixada para o bucket `provas` e ligada a
`evidences.message_id`.

### Sprint 4 — Briefing e peça
Agente de briefing conduz a entrevista e preenche `briefings.answers`; agente de redação monta
`pieces.content` a partir de `piece_templates` da tese (interno) e dos arquivos de `piece_models`
(obrigatórios + tese, via `piece_models_for()`); tela de revisão com diff e aprovação por
advogado (`reviewed_by`), status `protocolada` com número de protocolo.

### Sprint 5 — Dashboard, custo e cobrança
Funil por fase (projeção de `leads.phase`), tempo médio por fase (`case_events`), custo por lead e
por contrato assinado (`lead_acquisition_cost`), taxa do portão. Modelo de cobrança (pendência de
produto) e medição do que for escolhido (escritório, usuário ou volume).

### Sprint 6 — Onboarding e identidade
Nome e domínio (pendência), e-mail transacional, convite de membros. (Cadastro do número da Meta e
segredo no Vault pelo painel: feito na 008.)

## Pendências de produto (não de código)

- Nome e domínio. Trava identidade visual, e-mail transacional e onboarding.
- Modelo de cobrança: por escritório, por usuário ou por volume de conversa.
- Prompt de cada um dos sete agentes (entra em `agent_prompts` por SQL/service_role; não há tela).
