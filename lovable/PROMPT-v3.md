# Prompts de build — v3 (paridade com o concorrente: navegação, identidade e dashboard)

Objetivo: o app abrir como o concorrente abre. Mesma arquitetura de informação (nove itens de menu,
bloco da empresa, rodapé com usuário e ações), mesmo dashboard (filtro por mês e por agente, cinco
abas, os mesmos widgets), com identidade visual própria. Estrutura e função são copiadas; nome,
logotipo, paleta e textos não.

**Pré-requisitos**

- v1 concluído até o Prompt 2 (login, escritório ativo, inbox). Os demais prompts do v1 e todo o v2
  continuam válidos e entram depois; este v3 só reorganiza a casca e adiciona o dashboard.
- `supabase/004_dashboard.sql`, `005_funil.sql` e `006_dashboard_periodo.sql` aplicadas. Elas criam
  `contacts.uf`, `contracts.valor_causa/faixa`, `ad_spend`, `pieces.protocolado_em`,
  `human_interventions.outcome`, `office_params.cambio_usd_brl`, os triggers de contrato e peça, e
  as RPCs por período: `dashboard_geral_p`, `dashboard_funil_p`, `dashboard_funil_leads_p`,
  `dashboard_jornada_p`, `dashboard_jornada_leads_p`, `dashboard_produtividade_p`,
  `dashboard_investimento_p` (todas com `p_from`/`p_to`; as versões por mês continuam existindo).
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

## Prompt 3 — Filtro de período e as outras abas

Dividido em quatro entregas (3a a 3d). Uma por vez.

### 3a — Filtro de período (substitui o navegador de mês)

**Contexto.** Todas as RPCs `*_p` recebem `p_from date` e `p_to date` (inclusivo). `p_from` nulo
= "todo o período" (desde o primeiro lead). `p_to` nulo = hoje. Elas devolvem também
`periodo: { de, ate }`.

**Faça.**
1. Trocar o navegador de mês por um select de período com as opções, nesta ordem: Todo o período,
   Hoje, Ontem, Últimos 7 dias, Este mês (padrão), Personalizado (abre um range picker com dois
   calendários). O rótulo do botão mostra a opção ou "dd/MM a dd/MM" no personalizado.
2. Estado na URL: `?periodo=hoje|ontem|7d|mes|tudo|custom&de=YYYY-MM-DD&ate=YYYY-MM-DD`.
3. Um hook `usePeriodo()` que traduz a opção em `{ de, ate }` (nulos quando "tudo") e é a única
   fonte para todas as abas. Migrar as abas Geral e Funil para `dashboard_geral_p`,
   `dashboard_funil_p` e `dashboard_funil_leads_p` com `p_from`/`p_to`.
4. "Limpar tudo" volta para Este mês e Todos os agentes.
5. Na aba Geral, o widget "Contratos fechados" passa a ter quatro anéis: Hoje, Esta semana, Este
   mês e Período (o anel cheio é o do período; os outros proporcionais a ele).

**Critério de aceite.** "Hoje" mostra um único dia nos gráficos por dia; "Todo o período" mostra
desde o primeiro lead; "Personalizado" respeita as duas datas; o funil recalcula a coorte.

### 3b — Jornada do Cliente

**Contexto.** `dashboard_jornada_p(p_office, p_from, p_to, p_member)` →
```
{ leads,
  etapas: [ { ordem: 1..7, agente: 'recepcao'|'qualificacao'|'provas'|'calculo'|'contrato'|'briefing'|'redacao',
              titulo, fases: [...], n, pct_topo, concluido, em_fluxo, interv_humana, tempo_medio_horas } ],
  primeira_resposta_min, dias_ate_contrato, mensagens_por_lead }
```
`dashboard_jornada_leads_p(p_office, p_agente, p_from, p_to, p_member)` → linhas de `v_case_cards`
dos leads que chegaram àquela etapa.

**Faça.**
1. Uma linha horizontal rolável de sete cards numerados 01..07, um por etapa: ícone, título
   (nome do agente), número grande `n`, `pct_topo%`, barra de progresso, e três linhas de rodapé
   em caixa alta pequena: "CONCLUÍDO {concluido}", "EM FLUXO {em_fluxo}", "INTERV. HUMANA
   {interv_humana}". Entre um card e o seguinte, um conector "≫" com `tempo_medio_horas` da etapa
   anterior formatado como "8 min", "10 horas" ou "1d 18h". Card clicado fica com fundo primária.
2. Abaixo, painel "Clique em uma etapa acima para ver os clientes." que, ao clicar, chama
   `dashboard_jornada_leads_p` e lista em tabela (nome, telefone, fase atual, última mensagem,
   selo IA/Equipe, prescrição). Clique na linha abre `/casos?caso=<lead_id>`. Etapa em `?etapa=`.
3. Três KPIs pequenos acima dos cards: primeira resposta (min), dias até contrato, mensagens por
   lead.

**Critério de aceite.** Os sete cards mostram números decrescentes ou iguais; clicar em "Contrato"
lista os leads que chegaram a contrato; o conector entre Recepção e Qualificação mostra um tempo.

### 3c — Produtividade Humana

**Contexto.** `dashboard_produtividade_p(p_office, p_from, p_to, p_member)` →
```
{ concluidas, em_andamento, pendentes, tempo_medio_horas, pessoas, tipos,
  maior_produtor: { user_id, nome, concluidas } | null,
  por_forma: [ { forma, n, pct } ], por_tipo: [ { tipo, n, pct } ],
  ranking: [ { user_id, nome, concluidas, tempo_medio_horas } ],
  por_dia: [ { dia, concluidas } ],
  membros: [ { user_id, nome, takeovers, mensagens, fases_movidas, contratos_assinados } ],
  ia: { mensagens, fases_movidas, intervencoes_pedidas } }
```
Nesta aba o filtro de agente vira "Todos os usuários" e passa `p_member` = quem resolveu.
Rótulos das formas: `sanado` Sanado, `cliente_perdido` Cliente perdido, `follow_up_agendado`
Agendar follow-up, `cliente_retomado` Cliente retomado, `reativado_para_agente` Reativado para o
agente, `assumido_pelo_humano` Assumido pelo humano, `tarefa_cancelada` Tarefa cancelada, `outro`
Outro, `nao_informada` Não informada. Tipos: `agendamento` Agendamento, `caso_escalado` Caso
escalado, `follow_up_esgotado` Follow-up esgotado, `seguir_conversa` Seguir conversa,
`contrato_nao_assinado_24h` Contrato não assinado (24h), `ia_sem_resposta` IA sem resposta,
`cliente_ja_existente` Cliente já existente, `duvida_juridica` Dúvida jurídica, `fora_de_escopo`
Fora de escopo, `cliente_insatisfeito` Cliente insatisfeito, `pedido_de_humano` Pedido de humano,
`erro_ia` Erro da IA, `prescricao` Prescrição, `outro` Outro.

**Faça.**
1. Quatro cards no topo: "Intervenções concluídas" (número grande com ícone), "Em andamento
   (agora)" com legenda "assumidas e não concluídas", "Tempo médio" formatado "1d 18h" com legenda
   "abertura → conclusão · {pessoas} pessoas · {tipos} tipos", "Maior produtor" com nome e
   "{concluidas} intervenções".
2. Três colunas: "Por forma" (lista com barra, % e n, ordenada por n), "Por tipo de tarefa"
   (idem, com clique para filtrar a lista de ranking), "Ranking por pessoa" (avatar com posição,
   nome, barra, "{concluidas} concluídas · {tempo} médio").
3. "Linha do tempo — conclusões por dia": barras finas com o número em cima de cada dia.
4. Um acordeão "Outras atividades" com a tabela `membros` e o card `ia`.
5. Na página `/fila` (v1), o diálogo de Resolver ganha o select "Forma de resolução" com as
   formas acima, enviado como `p_outcome` para `resolve_intervention`.

**Critério de aceite.** Com o seed, aparecem várias formas e tipos, o ranking tem o usuário do
escritório e a linha do tempo tem barras. Resolver uma intervenção na fila com uma forma faz o
número "Por forma" subir.

### 3d — Investimento Financeiro

**Contexto.** `dashboard_investimento_p(p_office, p_from, p_to)` →
```
{ cambio_usd_brl, investimento_total_brl, ads_brl, tokens_brl, tokens_usd, tokens_in, tokens_out,
  mensagens_ia, contratos_fechados, custo_por_contrato_brl, protocolos, custo_por_protocolo_brl,
  valor_causa_gerado, por_agente: [ { agente, mensagens, custo_usd, custo_brl } ],
  dia_a_dia: [ { dia, ads_brl, tokens_brl, investimento_brl, contratos, custo_por_contrato_brl,
                 protocolos, custo_por_protocolo_brl } ]  // mais recente primeiro
}
```
`ad_spend(office_id, dia, canal 'meta_ads'|'google_ads'|'tiktok_ads'|'outro', valor, nota)` é onde o
escritório lança o gasto com anúncios (admin e advogado escrevem). `office_params.cambio_usd_brl`
converte o custo de tokens.

**Faça.**
1. Cabeçalho da aba com título e a frase "Custo de aquisição dia a dia: investimento total
   (Ads + Tokens) cruzado com os contratos fechados e os protocolos no dia. O custo é o investimento
   dividido pela quantidade — por contrato e por protocolo."
2. Cinco cards: Investimento total (BRL), Contratos fechados, Custo / contrato, Protocolos, Custo /
   protocolo. Valores nulos aparecem como "—".
3. Tabela "Dia a dia": Dia, Ads, Tokens, Investimento (com uma mini barra proporcional ao maior
   do período), Contratos, Custo / contrato, Protocolos, Custo / protocolo. Mais recente primeiro.
4. Botão "Lançar gasto com anúncios" (admin/advogado): diálogo com dia, canal e valor; `upsert`
   em `ad_spend` por (office_id, dia, canal). A tabela atualiza por Realtime em `ad_spend`.
5. Rodapé: "Tokens convertidos a R$ {cambio_usd_brl} por USD (Configurações → Parâmetros)" e um
   card pequeno "Por agente" com custo em BRL.

**Critério de aceite.** Lançar R$ 100 em anúncios para hoje muda o Investimento total e o custo por
contrato do dia sem refresh. Os totais dos cards batem com a soma da tabela.

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
