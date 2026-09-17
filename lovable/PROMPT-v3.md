# Prompts de build — v3 (paridade com o concorrente: navegação, identidade e dashboard)

Objetivo: o app abrir como o concorrente abre. Mesma arquitetura de informação (nove itens de menu,
bloco da empresa, rodapé com usuário e ações), mesmo dashboard (filtro por mês e por agente, cinco
abas, os mesmos widgets), com identidade visual própria. Estrutura e função são copiadas; nome,
logotipo, paleta e textos não.

**Pré-requisitos**

- v1 concluído até o Prompt 2 (login, escritório ativo, inbox). Os demais prompts do v1 e todo o v2
  continuam válidos e entram depois; este v3 só reorganiza a casca e adiciona o dashboard.
- `supabase/004_dashboard.sql` e `005_funil.sql` aplicadas. Elas criam `contacts.uf`,
  `contracts.valor_causa/faixa`, o trigger de contrato e as RPCs `dashboard_geral`, `dashboard_funil`
  (com as quatro macro-etapas), `dashboard_funil_leads`, `dashboard_jornada`,
  `dashboard_produtividade`, `dashboard_investimento`.
- `supabase/seed_demo.sql` rodado uma vez, para o dashboard não nascer vazio.
- Tipos do Supabase regenerados.

**Regras da série**

- Nada de tabela, migration ou policy nova. Só leitura via RPC e tabelas existentes.
- Um componente por widget, um hook por RPC. React Query para dados; Recharts para gráficos.
- Todo número que aparece na tela vem do banco. Nenhum valor fixo de exemplo no código.

---

## Prompt 1 — Identidade visual e a casca igual à do concorrente

**Contexto.** Hoje o app tem barra lateral com Inbox, Casos, Fila, Configurações. O produto de
referência tem: bloco da empresa no topo da barra, nove itens de menu, rodapé com usuário, papel e
quatro ações (notificações, tema escuro, configurações, sair) e botão de recolher a barra. O
conteúdo abre com um cabeçalho de página com ícone e título em caixa alta.

**Faça.**
1. **Tokens de design** (em `index.css` e `tailwind.config`), tema claro por padrão:
   - fundo da aplicação `#F4F6F5`; superfícies (cards, barra) `#FFFFFF`; borda `#E4E9E7`
   - texto `#111827`; texto secundário `#6B7280`
   - primária `#0F5C4A` (verde-escuro), primária suave `#E6F2EE`, primária hover `#0B4A3B`
   - alerta `#B45309`, perigo `#B91C1C`, sucesso `#047857`, info `#1D4ED8`
   - série de gráficos: `#0F5C4A`, `#3B8C74`, `#86B8A6`, `#C9DED5`
   - fonte Inter; cards com raio 16px, sombra suave `0 1px 2px rgba(16,24,40,.06)`; inputs raio 10px
   - tema escuro: fundo `#0F1412`, superfícies `#161D1A`, borda `#243029`, texto `#E5E7EB`;
     primária vira `#3B8C74`. Toggle no rodapé da barra, persistido em localStorage.
2. **Barra lateral** (largura 260px, recolhível para 72px só com ícones, estado em localStorage):
   - topo: nome do produto em texto (deixe um `APP_NAME` em constante; sem logotipo por enquanto)
   - bloco "EMPRESA" com o nome do escritório ativo (`useOffice().office.name`) e o seletor quando
     houver mais de um
   - itens, nesta ordem e com estes rótulos e rotas:
     1. Dashboard → `/`
     2. Conversas → `/inbox` (é a inbox já construída)
     3. Fluxo de Trabalho → `/casos`
     4. Intervenção humana → `/fila`
     5. Jurídico → `/juridico`
     6. Agendamentos → `/agendamentos`
     7. Clientes → `/clientes`
     8. Finalizados → `/finalizados`
     9. Histórico → `/historico`
     10. Marketing → `/marketing`
     Item ativo com fundo primária suave, borda esquerda primária e ícone primário (lucide-react).
   - rodapé: avatar com iniciais, nome (`profiles.full_name` do usuário, fallback e-mail) e papel
     em português (Administrador / Advogado / Atendente); abaixo, quatro ícones: sino
     (notificações, Prompt 6), lua/sol (tema), engrenagem (`/config`), sair; e o botão de recolher.
3. **Cabeçalho de página**: componente `PageHeader({ icon, title })` que renderiza ícone + título
   em caixa alta, usado por todas as páginas.
4. **Rotas novas** com placeholder "Em construção" e o `PageHeader` correto: `/`, `/juridico`,
   `/agendamentos`, `/clientes`, `/finalizados`, `/historico`, `/marketing`. As existentes
   (`/inbox`, `/casos`, `/fila`, `/config`) continuam.
5. Responsivo: abaixo de 1024px a barra vira drawer com botão hambúrguer no cabeçalho.

**Não faça.** Não copie nome, logotipo, cores ou textos do produto de referência. Não invente
dados. Não mexa na lógica da inbox.

**Critério de aceite.** Login abre em `/` com a barra de dez itens, bloco da empresa, rodapé com
nome e papel. Recolher a barra e trocar o tema persistem após recarregar. Todas as rotas abrem sem
erro.

---

## Prompt 2 — Dashboard, aba Geral

**Contexto.** `dashboard_geral(p_office uuid, p_month date, p_member uuid)` devolve:

```
{
  mes: "2026-09",
  fechados: { hoje, semana, mes },
  por_dia:   [ { dia: "2026-09-01", contratos, valor_causa }, ... um por dia do mês ],
  por_uf:    [ { uf: "SP", contratos }, ... ordenado desc ],
  por_faixa: [ { faixa: "alto"|"medio"|"baixo"|"indefinida", contratos, valor }, ... ],
  total:     { contratos, valor }
}
```

`p_month` é qualquer dia do mês desejado. `p_member` filtra por responsável (`leads.assigned_to`);
`null` = todos. Os membros vêm de `office_members` + `profiles` (nome). Retorna `null` se o usuário
não é membro do escritório.

**Faça.**
1. Página `/` com `PageHeader` "Dashboard". Barra de filtros num card: navegador de mês
   (‹ Setembro 2026 ›, com o mês em português), select "Todos os agentes" listando os membros do
   escritório (label "agente" é o nome do filtro; o valor é `user_id`). Estado dos filtros na URL
   (`?mes=2026-09&agente=<uuid>`).
2. Abas num card: Geral | Funil de Venda | Jornada do Cliente | Produtividade Humana |
   Investimento Financeiro (ícones lucide). Só Geral funciona neste prompt; as outras mostram
   esqueleto.
3. Aba Geral, grade de dois terços / um terço:
   - **Contratos fechados**: três anéis (Recharts `RadialBarChart` ou SVG próprio) para Hoje,
     Esta semana, Este mês. O anel de "hoje" e "semana" preenche proporcional ao total do mês; o do
     mês fica cheio. Número grande no centro.
   - **Contratos fechados por dia**: `BarChart` com barras arredondadas, um dia por barra, eixo X
     `dd/MM` a cada dois dias, tooltip com contratos e valor.
   - **Regiões que mais fecham — por UF**: barras horizontais (`BarChart layout="vertical"`),
     ordenadas da menor para a maior de cima para baixo, gradiente na série.
   - **Contratos por tipo (ticket)**: barras horizontais com rótulos HT (alto), MT (médio),
     LT (baixo) e o número ao lado; embaixo uma tabela com chip do tipo, quantidade, valor em BRL
     e a linha de total (Σ). "indefinida" aparece só se houver.
   - **Valor de causa gerado por dia**: `AreaChart` com curva suave, preenchimento em gradiente
     da primária, eixo Y em "R$ 90 mil" etc.
4. Formatação: BRL com `Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })`;
   datas com `date-fns` e locale `ptBR`.
5. Estados: esqueleto enquanto carrega; "Sem contratos neste mês" quando `total.contratos = 0`.
6. Hook `useDashboardGeral(mes, agente)` com React Query, chave `['dashboard','geral',office,mes,agente]`.

**Não faça.** Não calcule agregados no front. Não use dados fictícios.

**Critério de aceite.** Com o seed rodado, a aba Geral mostra números e cinco gráficos
preenchidos. Mudar o mês para o anterior zera tudo (sem erro). Escolher um agente reduz os números.

---

## Prompt 3 — Dashboard, as outras quatro abas

**Contexto.** Quatro RPCs, mesma assinatura de mês (e `p_member` nas duas primeiras):

`dashboard_funil` →
```
{ leads,
  macro: [ { ordem: 1..4, etapa: 'novos_leads'|'abertura'|'links_enviados'|'contratos',
             titulo, regua: null|'2+ msgs', n, pct_topo, conv_etapa: null|número, interv_humana } ],
  etapas: [ { fase, alcancaram, taxa } ... 8 fases sem 'encerrado' ],
  atual: [ { fase, leads } ], encerrados: { ia, equipe },
  qualificacao: { aprovados, reprovados }, contratos }
```
`dashboard_funil_leads(p_office, p_etapa, p_month, p_member)` → linhas de `v_case_cards` dos leads
daquela macro-etapa (para o clique no card).
`dashboard_jornada` →
```
{ horas_por_fase: [ { fase, media_horas, n } ], primeira_resposta_min, dias_ate_contrato, mensagens_por_lead }
```
`dashboard_produtividade` →
```
{ membros: [ { user_id, nome, role, takeovers, mensagens, fases_movidas, intervencoes_resolvidas,
               contratos_assinados, provas_validadas } ],
  ia: { mensagens, fases_movidas, intervencoes_pedidas } }
```
`dashboard_investimento` →
```
{ custo_usd, tokens_in, tokens_out, mensagens_ia, leads_atendidos, custo_por_lead_usd,
  contratos_assinados, custo_por_contrato_usd, valor_causa_gerado,
  por_agente: [ { agente, mensagens, custo_usd } ], por_dia: [ { dia, custo_usd } ] }
```

Nomes das fases em português na UI: novo → Novo, triagem → Triagem, qualificacao → Qualificação,
provas → Provas, calculo → Cálculo, contrato → Contrato, briefing → Briefing, peca → Peça,
encerrado → Encerrado. Centralize num `PHASE_LABELS`.

**Faça.**
1. **Funil de Venda** (layout do concorrente): à esquerda um card com o funil em trapézio (SVG,
   quatro degraus com `n` e `pct_topo`) e a legenda das quatro etapas de `macro`; à direita quatro
   cards numerados 01..04 (título, número grande, `pct_topo`, barra de progresso, e duas linhas de
   rodapé: "TOPO DO FUNIL 100%" no primeiro, "RÉGUA 2+ msgs" no segundo, "CONV. DA ETAPA x%" nos
   demais; em todos "INTERV. HUMANA n"). O card clicado fica destacado com fundo primária e texto
   branco. Abaixo à esquerda, o widget "Contratos por tipo (ticket)" reaproveitado da aba Geral
   (mesmo componente, dados de `dashboard_geral.por_faixa`). Abaixo à direita, painel "Clique em
   uma etapa acima para ver os leads": ao clicar, chama `dashboard_funil_leads` e lista os leads em
   tabela (nome, telefone, fase, última mensagem, UF, selo IA/Equipe); clique na linha abre
   `?caso=<lead_id>` (ou `/casos?caso=` enquanto o modal do v2 não existir). Etapa escolhida em
   `?etapa=`. Mantenha, num acordeão recolhido "Detalhe por fase", os dados de `etapas`, `atual`,
   `encerrados` e `qualificacao` como barras simples.
2. **Jornada do Cliente**: quatro cards de KPI (primeira resposta em minutos, dias até contrato,
   mensagens por lead, fases com dado) e um gráfico de barras "Horas médias por fase" na ordem
   das fases.
3. **Produtividade Humana**: tabela por membro (avatar, nome, papel, e as seis métricas), com
   ordenação por coluna, e um card à direita "IA no mês" com as três métricas da IA. Barra
   empilhada comparando mensagens humano vs IA.
4. **Investimento Financeiro**: cards custo total (USD, 2 casas), custo por lead, custo por contrato,
   valor de causa gerado (BRL); gráfico de linha "Custo por dia"; barras "Custo por agente" com o
   nome do agente traduzido (recepcao → Recepção, qualificacao → Qualificação, provas → Provas,
   calculo → Cálculo, contrato → Contrato, briefing → Briefing, redacao → Redação). Nota de rodapé:
   "Custo derivado do uso reportado pelo modelo; câmbio não aplicado".
5. Um hook por RPC, mesma convenção de chave do Prompt 2. A aba ativa fica em `?aba=`.

**Critério de aceite.** As cinco abas trocam sem recarregar, respeitam o mês e o agente, e
nenhuma mostra número fixo. Mudar de escritório (se houver mais de um) recarrega tudo.

---

## Prompt 4 — Clientes, Finalizados, Histórico

**Contexto.** `v_case_cards` (uma linha por lead, já usada no kanban), `contacts` (`name, wa_id,
uf, cidade`), `contracts` (`status, signed_at, valor_causa, faixa`), `case_events` (`type, actor,
actor_user_id, actor_agent, payload, created_at, seq`), `profiles` (nomes). Tudo filtrado por
`office_id`. Os eventos têm os tipos listados no Prompt 4 do v2; use a mesma função
`describeEvent` (crie-a agora se o v2 ainda não rodou).

**Faça.**
1. `/clientes`: tabela de contatos com contrato assinado (join `contracts.status='assinado'`):
   nome, telefone formatado, UF/cidade, empresa (`case_data.empresa`), valor da causa, assinado em,
   fase atual. Busca por nome/telefone, filtro por UF. Clique abre `?caso=<lead_id>` (o modal do
   v2; se ainda não existir, navega para `/casos?caso=<lead_id>`).
2. `/finalizados`: leads com `phase='encerrado'`: nome, encerrado em, encerrado por (chip IA /
   Equipe), motivo (`closed_reason`), fase anterior (último `phase_changed.payload.from`). Filtro
   por quem encerrou. Botão "Reabrir" chama `ui_advance_phase(lead_id, 'triagem', 'reaberto')`.
3. `/historico`: feed de `case_events` do escritório, mais recente primeiro, paginado por `seq`
   (50 por página, "carregar mais"). Cada linha: horário, chip do autor (IA / nome do humano /
   Sistema), frase de `describeEvent`, nome do lead (join `leads` → `contacts`), link para o caso.
   Filtros: tipo (grupo: fase, conversa, dados e provas, fila, contrato), autor (IA / equipe /
   sistema), período. Realtime em `case_events` (filtro `office_id`) faz prepend ao vivo.

**Critério de aceite.** Com o seed, Clientes lista os contratos assinados com UF, Finalizados
lista os encerrados pela IA com motivo, e o Histórico cresce ao vivo quando um evento novo entra.

---

## Prompt 5 — Jurídico e Agendamentos

**Contexto.** `contracts` (`status: rascunho|enviado|assinado|recusado|cancelado`,
`honorarios_percent, document_path, signature_provider, signature_ref, sent_at, signed_at,
valor_causa, faixa`), `pieces` (`tese, status: rascunho|revisao|aprovada|protocolada, content,
generated_by_actor, reviewed_by, protocolo`), `piece_templates` (`tese, name, body,
required_evidence`, globais quando `office_id` nulo), `tasks` (`title, description, due_at,
done_at, assigned_to, lead_id, created_by_actor`). Mudar `contracts.status` dispara efeitos no
banco (evento com autor; assinar avança a fase). Só `admin` e `advogado` escrevem em `contracts`
e `pieces`.

**Faça.**
1. `/juridico` com duas abas:
   - **Contratos**: kanban por status (Rascunho, Enviado, Assinado, Recusado/Cancelado) com cards
     (lead, honorários %, valor da causa, faixa, datas). Botão "Novo contrato" (lead em fase
     `contrato` sem contrato ativo; honorários pré-preenchidos de `office_params.honorarios_percent`).
     Mover o card entre colunas faz `update contracts set status`. "Anexar PDF" sobe no bucket
     `provas` em `<office_id>/<lead_id>/contrato-<uuid>.pdf` e grava `document_path`.
   - **Peças**: lista por status com tese, lead, gerada por (IA/humano), revisor. Abrir mostra
     `content` num editor de texto simples com botões Enviar para revisão / Aprovar / Marcar
     protocolada (pede o número). Aba secundária "Modelos" lista `piece_templates` (globais em
     leitura; do escritório editáveis por admin/advogado).
2. `/agendamentos`: visão semanal (7 colunas) e lista das `tasks` com `due_at`, do escritório.
   Criar tarefa (título, descrição, data/hora, responsável entre os membros, lead opcional via
   busca `search_cases`). Concluir marca `done_at`. Atrasadas em vermelho. Realtime em `tasks`.
   Contador de tarefas de hoje no item do menu.

**Critério de aceite.** Criar um contrato e movê-lo para Assinado gera `contract_signed` no
Histórico com o nome do usuário e o caso vai para Briefing no kanban. Criar uma tarefa para amanhã
aparece na semana e no contador.

---

## Prompt 6 — Notificações, Marketing e o polimento final

**Contexto.** `human_interventions` (`status pendente|em_atendimento`), `v_case_cards`
(`prescricao_alerta`, `prescricao_vencida`), `tasks` (`due_at`, `done_at`). Todas com Realtime.

**Faça.**
1. **Sino de notificações** no rodapé da barra: badge com a soma de intervenções pendentes +
   casos com prescrição em alerta + tarefas atrasadas. Popover com três seções e link para a página
   certa. Contagem atualizada por Realtime nas três tabelas.
2. `/marketing`: página "Em breve" com uma descrição honesta do que virá (origem dos leads e
   campanhas). Não há dado no banco para isso ainda; não invente.
3. **Página `/config`** reorganizada em abas: Escritório (nome; admin), Equipe (membros e papéis;
   admin), WhatsApp (v1 Prompt 5), Parâmetros (v1 Prompt 5), Agentes (lista de `agents` globais com
   nome, papel e descrição; override do escritório editável por admin: `system_prompt`, `model`,
   `temperature`, `enabled`).
4. **Polimento**: estados vazios com ilustração leve e chamada para ação; esqueletos em toda
   carga; toasts de erro com a mensagem do Supabase; foco visível em tudo; título da aba do
   navegador por página.

**Critério de aceite.** Um `request_intervention` no SQL Editor faz o badge do sino subir sem
refresh. Um admin edita o prompt do agente de Recepção do seu escritório e um atendente só lê.
