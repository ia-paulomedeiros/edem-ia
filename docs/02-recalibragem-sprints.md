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
| Intervenção humana (por tarefa e por lead, concluir lead em lote) | `/fila` sobre `v_intervention_cards` e `v_intervention_leads` (012) | `PROMPT-v1` + Prompt 12 |
| Jurídico (esteira: Revisão, Aguardando, Saneamento, Pronto p/ protocolo, Protocolado) | `pieces.status` + `alerta` + `responsavel`, `v_legal_cards`, `ui_set_piece_status` (010) | 010; UI em `PROMPT-v3` Prompt 9 |
| Configurações (Meu perfil, Empresa, Integrações, Modelos de petição) | `offices` cadastral, `integrations` + Vault, `piece_models` + bucket `modelos` (008) | 008; UI em `PROMPT-v3` Prompt 7 |
| Agendamentos (agenda por dia, retornos marcados pela IA) | `v_tasks`, `apply_agent_effects(p_task)` (010) | 010; UI em `PROMPT-v3` Prompt 9 |
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
Jurídico e agenda (`010_juridico_agenda.sql`): a peça anda numa esteira própria depois do contrato,
com alerta no card e responsável; o agente marca retornos como tarefas (autor IA); funções com
`search_path` fixo e execução só para authenticated/service_role.

### Sprint 3b — Assinatura eletrônica e mídia
Feito na 011 + `n8n/05`: pedido de envio (UI ou agente) → n8n preenche o modelo HTML, converte em
PDF, cria o documento na Autentique e manda o link; webhook de assinado → `contract_mark_signed` →
briefing. Régua de follow-up (`followup_rules`, `followup_due`, `n8n/06`). Ações da intervenção
(`intervention_actions`). Pendente: mídia recebida no WhatsApp baixada para o bucket `provas`.

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

### Sprint 4 — Fluxo do concorrente (`013_fluxo_laquila.sql`)
Contrato antes de cálculo e provas; quadro de 7 colunas; petição com checklist de revisão,
aprovação e protocolo; modelos de petição internos (só `platform_admins`); presença digital e
WhatsApp do jurídico; encerrar com tipo e reabrir para a fase anterior; templates da Meta para a
régua fora da janela de 24h; CPF validado; áudio transcrito (n8n 02). Pendente: n8n 07 (peça como
Google Doc com Sincronizar) e n8n 08 (geração da peça pelos blocos + modelos da tese).

## Pendências de produto (não de código)

- Nome e domínio. Trava identidade visual, e-mail transacional e onboarding.
- Modelo de cobrança: por escritório, por usuário ou por volume de conversa.
- Prompts dos sete agentes: v1 na 013 (roteiro do concorrente: recepção → fatos → viabilidade e proposta → dados e contrato → entrevista → viabilidade → coleta → peça). Revisar tom por escritório.
