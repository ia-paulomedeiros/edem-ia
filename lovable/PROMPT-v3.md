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
generated_by_actor, reviewed_by, protocolo`), `piece_models` (biblioteca de arquivos do
escritório; ver Prompt 7), `tasks` (`title, description, due_at,
done_at, assigned_to, lead_id, created_by_actor`). Mudar `contracts.status` dispara efeitos no
banco (evento com autor; assinar avança a fase). Só `admin` e `advogado` escrevem em `contracts`
e `pieces`.

**Atenção.** O Prompt 9 substitui esta página por um quadro único de peças e uma agenda por dia,
igual ao concorrente. Se o 9 já rodou, ignore este prompt.

**Faça.**
1. `/juridico` com duas abas:
   - **Contratos**: kanban por status (Rascunho, Enviado, Assinado, Recusado/Cancelado) com cards
     (lead, honorários %, valor da causa, faixa, datas). Botão "Novo contrato" (lead em fase
     `contrato` sem contrato ativo; honorários pré-preenchidos de `office_params.honorarios_percent`).
     Mover o card entre colunas faz `update contracts set status`. "Anexar PDF" sobe no bucket
     `provas` em `<office_id>/<lead_id>/contrato-<uuid>.pdf` e grava `document_path`.
   - **Peças**: lista por status com tese, lead, gerada por (IA/humano), revisor. Abrir mostra
     `content` num editor de texto simples com botões Enviar para revisão / Aprovar / Marcar
     protocolada (pede o número). Link "Modelos de petição" leva a `/config/modelos` (Prompt 7).
     Não leia `piece_templates` nem `agent_prompts`: são internos e o cliente não enxerga.
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
2. `/marketing`: substituída pelo Prompt 8 (custos de marketing). Se este prompt rodar antes do
   8, deixe uma página "Em breve" sem dado inventado.
3. **Página `/config`**: substituída pelo Prompt 7 (layout do concorrente). Se este prompt rodar
   antes do 7, deixe `/config` como está.
4. **Polimento**: estados vazios com ilustração leve e chamada para ação; esqueletos em toda
   carga; toasts de erro com a mensagem do Supabase; foco visível em tudo; título da aba do
   navegador por página.

**Critério de aceite.** Um `request_intervention` no SQL Editor faz o badge do sino subir sem
refresh.

---

## Prompt 7 — Configurações no layout do concorrente (Meu perfil, Empresa, Integrações, Modelos)

**Pré-requisito.** `supabase/008_configuracoes.sql` aplicada e tipos regenerados. Ela cria:
`offices` com `tipo, cnpj, oab_responsavel, fundador, fundacao, endereco, cidade, uf, email,
telefone, whatsapp_comercial, telefone_suporte, site, logo_path`; `profiles.phone, oab, cargo`;
`integration_catalog` (8 provedores, com `kind, label, description, secret_label, config_fields,
docs_url, ordem`); `integrations` (somente leitura no cliente: `provider, kind, active, secret_name,
secret_set_at, config, status nao_testado|teste_solicitado|validado|falhou, tested_at, last_error`);
as RPCs `set_integration(p_office, p_provider, p_secret, p_config, p_active)` → jsonb,
`remove_integration(p_office, p_provider)`, `request_integration_test(p_office, p_provider)`,
`active_integration(p_office, p_kind)`; `piece_models` (biblioteca de arquivos: `name, category,
description, file_path, mime_type, size_bytes, required, active, uploaded_by, updated_at`) e o
bucket privado `modelos`.

**Regras.**
- O segredo (token, chave de API) só vai para o banco por `set_integration`. Nunca grave em
  tabela, nunca leia de volta, nunca mostre. Depois de salvo, o campo mostra `••••••••` e o texto
  "Segredo salvo em <secret_set_at>"; digitar um novo substitui.
- Não existe tela de prompt de agente nem de `piece_templates`/`agent_prompts`. Se alguma tela
  antiga mostrava `system_prompt`, remova. A aba Agentes lista só nome, papel, descrição, modelo e
  o interruptor Ativo.
- Só `admin` salva em Empresa, Integrações e Equipe. `advogado` e `admin` gerenciam Modelos.
  Os demais só leem. Botões desabilitados com tooltip explicando.

**Faça.** `/config` com sub-navegação à esquerda (lista vertical, item ativo em destaque) e o
conteúdo à direita, como o concorrente. Rotas: `/config/perfil`, `/config/empresa`,
`/config/integracoes`, `/config/modelos`, `/config/agentes`. `/config` redireciona para `perfil`.

1. **Meu perfil.** Card com avatar (upload para o bucket `provas` em `<office_id>/avatars/<user_id>`
   ou manter o atual), nome completo, e-mail (somente leitura, do Auth), telefone, OAB, cargo.
   Salvar faz `update profiles`. Abaixo, card "Senha" com trocar senha (`supabase.auth.updateUser`).
2. **Empresa.** Quatro seções em cards, na ordem: **Identificação** (tipo: Escritório / Autônomo /
   Departamento jurídico; nome; CNPJ com máscara; OAB do responsável; fundador(a); data de fundação;
   site; logotipo com upload para `modelos/<office_id>/logo.<ext>` gravando `logo_path`),
   **Contato** (endereço, cidade, UF, e-mail, telefone, WhatsApp comercial, telefone do suporte),
   **Parâmetros** (o conteúdo atual de `office_params`: ticket mínimo, faixas, vínculo mínimo,
   alerta de prescrição, honorários %, horário de atendimento, câmbio) e **Equipe** (o conteúdo
   atual: membros, papéis, convite). Cada card com o próprio botão Salvar e toast.
3. **Integrações.** Uma linha de card por provedor de `integration_catalog`, ordenada por `ordem`,
   agrupada por `kind` com títulos: Mensageria, Assinatura eletrônica, Armazenamento, Modelo de
   linguagem, Transcrição. Cada card:
   - Cabeçalho: `label`, `description`, link "Documentação" (`docs_url`), interruptor **Ativo**
     (chama `set_integration(office, provider, null, null, ativo)`; em Mensageria e Assinatura
     ligar um desliga o outro, o banco garante, a UI refaz a lista).
   - Chip de status a partir de `integrations.status`: "Não testado" (cinza), "Teste solicitado"
     (âmbar, com spinner), "Validado" (verde, com `tested_at`), "Falhou" (vermelho, com
     `last_error` num tooltip). Sem linha em `integrations` = "Não configurado".
   - Campo do segredo com `secret_label` como rótulo, tipo password, olho para revelar só o que
     está sendo digitado. Placeholder `••••••••` quando `secret_name` não é nulo.
   - "Configurações avançadas" recolhível, gerando os campos a partir de `config_fields`
     (`type: text|url|boolean`, `required`) e gravando em `config`.
   - Rodapé com três botões: **Testar** (`request_integration_test`; desabilitado sem segredo
     salvo; o status vira "Teste solicitado" e a UI observa `integrations` por Realtime ou refetch
     a cada 5 s até mudar), **Remover** (confirmação; `remove_integration`) e **Salvar**
     (`set_integration` com o segredo digitado, se houver, e o `config`).
   - Mensageria: no card **WhatsApp Cloud API (Meta)** os avançados são `phone_number_id`,
     `waba_id`, `display_phone`. Salvar com segredo já cadastra/atualiza o número em
     `whatsapp_numbers` (o banco faz). Remova a aba WhatsApp antiga; a lista de números fica como
     tabela somente leitura dentro deste card.
4. **Modelos de petição.** Cabeçalho "Modelos de petição" + subtítulo "Arquivos que a IA usa como
   base das peças. Sem limite de quantidade." Barra com busca por nome (`ilike`), filtro por
   categoria (Geral + as teses existentes em `piece_models.category` do escritório), filtro
   Ativos/Todos, contador "N resultados" e botão **Novo modelo**. Tabela: Nome (com ícone pelo
   `mime_type`), Categoria, chips **ATIVO**/inativo e **OBRIGATÓRIO** quando `required`, Atualizado
   em (`updated_at`, relativo), Tamanho, ações Baixar (`createSignedUrl` 5 min), Editar, Excluir.
   Novo/Editar em diálogo: nome, categoria (select com "Geral" e teses, permitindo digitar nova),
   descrição, interruptores Ativo e Obrigatório, arquivo (upload para
   `modelos/<office_id>/<uuid>-<nome>`; aceitar .docx, .pdf, .txt, .md; limite 25 MB; grava
   `file_path, mime_type, size_bytes`). Excluir apaga a linha e o objeto do bucket. Ordenação
   padrão: obrigatórios primeiro, depois nome.
5. **Agentes.** Lista dos sete agentes (`agents` com `office_id` nulo) com nome, papel, descrição e
   modelo; interruptor Ativo por escritório (cria/atualiza a linha de override em `agents` com
   `office_id` do escritório e `enabled`). Nada de prompt.

**Não faça.** Não leia nem exiba `secret_name`. Não crie campo de segredo em nenhuma tabela. Não
mostre `piece_templates`, `agent_prompts` nem `system_prompt`. Não torne o bucket `modelos` público.

**Critério de aceite.** Admin salva a chave da Anthropic: o campo vira `••••••••`, o status "Não
testado", e no SQL Editor `select * from public.integrations` não tem a chave (só
`secret_name`), enquanto `select public.integration_secret('<office>', 'anthropic')` como
service_role devolve o valor. Testar muda o chip para "Teste solicitado". Um atendente abre
Integrações e vê tudo desabilitado. Subir 3 arquivos em Modelos mostra "3 resultados"; marcar um
como obrigatório mostra o chip OBRIGATÓRIO; a busca filtra pelo nome.

---

## Prompt 8 — Marketing (custos) e o custo por lead no caso

**Pré-requisito.** `supabase/009_marketing.sql` aplicada e tipos regenerados. Ela cria a view
`v_marketing_lancamentos` (um dia por linha: `dia, ads_brl, tokens_brl, total_brl, tem_manual,
tem_importado, observacao, itens, updated_at`), as RPCs `marketing_resumo_p(p_office, p_from,
p_to)` → jsonb (`ads_brl, tokens_brl, total_brl, lancamentos, leads, custo_medio_por_lead_brl,
contratos, custo_por_contrato_brl, periodo`), `marketing_lancamentos_p(p_office, p_from, p_to)`
→ linhas da view, `marketing_lancar(p_office, p_dia, p_ads_brl, p_tokens_brl, p_nota)` → linha
do dia, `marketing_remover(p_office, p_dia)` → n, e `lead_cost(p_lead)` → jsonb (`tokens_brl,
tokens_usd, ads_rateio_brl, custo_lead_brl, mes.custo_medio_lead_brl, cambio_usd_brl`), que já vem
dentro de `lead_dossier().cost`. O catálogo de integrações ganhou **Meta Ads** (`kind = ads`).

**Faça.**
1. `/marketing` substitui o "Em breve", no layout do concorrente:
   - Cabeçalho "Custos de Marketing" com "N lançamentos" e três números à direita: Investimento
     Ads, Investimento Tokens, Total (de `marketing_resumo_p`). Abaixo deles, em texto menor:
     "N leads no período · custo médio por lead R$ X · custo por contrato R$ Y". Mesmo filtro de
     período do dashboard (Prompt 3a), padrão mês atual.
   - Card **Novo lançamento**: Data (padrão hoje), Investimento Ads (R$, opcional), Custo tokens
     (R$, opcional), Observação (opcional), botão "Lançar custo" → `marketing_lancar`. Ao lançar
     numa data que já tem linha, a linha é atualizada (o banco faz upsert).
   - Tabela **Lançamentos** (mais recente primeiro): Data, Ads, Tokens, Total (negrito),
     Observação, chip "importado" quando `tem_importado` (tooltip listando `itens` com canal e
     valor), ações Editar (abre o card preenchido) e Remover (confirma; `marketing_remover`; se a
     linha tiver só itens importados, o botão fica desabilitado com tooltip "importado pela
     integração; edite em Integrações"). Contador no cabeçalho da tabela.
   - Rodapé discreto: "Dias sem lançamento de tokens usam a estimativa pelas mensagens da IA."
     Só `admin` e `advogado` lançam e removem; os demais só leem.
2. No **modal do caso**, o rodapé passa a mostrar `dossier.cost`: "Custo do lead R$ X" (=
   `custo_lead_brl`, tooltip: "tokens R$ a + rateio de anúncios do dia R$ b (c leads no dia)") e ao
   lado "média do mês R$ Y por lead" (= `mes.custo_medio_lead_brl`). O resumo da aba Histórico
   usa os mesmos dois números. Nada em dólar na tela; dólar só no tooltip.
3. Em `/config/integracoes`, o card **Meta Ads** aparece no grupo "Anúncios" com os avançados
   `ad_account_id` e `currency`. Nada mais muda ali: a importação é do n8n, uma vez por dia.

**Não faça.** Não calcule custo no front: tudo vem de `marketing_resumo_p`, da view e de
`lead_cost`. Não some tokens estimados com tokens lançados no mesmo dia (o banco já escolhe).

**Critério de aceite.** Lançar R$ 100 de Ads e R$ 20 de tokens para hoje mostra a linha com total
R$ 120 e os cards do topo sobem na hora. O rodapé de um caso criado hoje mostra o rateio dos
R$ 100 entre os leads de hoje. Remover a linha volta os cards. `select * from
public.marketing_import_targets()` no SQL Editor (como service_role) lista a Meta Ads depois de
salvar o token e ativar em Integrações.

---

## Prompt 9 — Jurídico como esteira e Agendamentos por dia (igual ao concorrente)

**Pré-requisito.** `supabase/010_juridico_agenda.sql` aplicada e tipos regenerados. Ela cria:
`v_legal_cards` (um card por peça: `piece_id, lead_id, status, etapa, etapa_ordem, tese, alerta,
protocolo, responsavel, assigned_to, stage_changed_at, horas_na_etapa, contact_name,
contact_phone, empresa, cargo, valor_causa, faixa, viavel, fragil, em_atendimento,
intervencao_pendente, prescricao_em`), `piece_stages()` (6 etapas na ordem: Em redação, Revisão,
Aguardando, Saneamento, Pronto p/ protocolo, Protocolado), `ui_set_piece_status(p_piece,
p_status, p_alerta, p_protocolo)`, `v_tasks` (tarefa + `contact_name, contact_phone, assigned_name,
situacao pendente|atrasado|realizado, dia`). `pieces` e `tasks` já estão no Realtime.

**Faça.**
1. **`/juridico` vira um quadro só**, sem abas. Barra do topo: busca (nome, telefone, empresa),
   filtro por responsável como avatares clicáveis (iniciais dos membros, `responsavel` ou
   `assigned_to`; "Todos" selecionado por padrão; mostrar os 6 primeiros e "+N"), botão Filtros
   (faixa, viável/frágil, em atendimento, tese). Colunas com rolagem horizontal, uma por etapa de
   `piece_stages()`, cabeçalho colorido com o título e o contador. Cores dos cabeçalhos: Em
   redação cinza, Revisão terracota, Aguardando âmbar, Saneamento roxo-acinzentado, Pronto p/
   protocolo verde, Protocolado verde-azulado (tons suaves, texto escuro). Card: nome em negrito,
   "há X horas/dias" à direita (`horas_na_etapa`), telefone em cinza, "empresa · cargo", "Valor da
   causa: R$ X" com o valor em negrito, chips: faixa como `LOW TICKET` / `MID TICKET` / `HIGH
   TICKET` (baixo/medio/alto), `Viável` (verde) ou `Frágil` (âmbar), `Em atendimento` quando
   `em_atendimento`. Se `alerta` não for nulo, uma faixa amarela no topo do card com ícone de
   aviso e o texto. Clicar no card abre o modal do caso (`?caso=`). Arrastar entre colunas chama
   `ui_set_piece_status(piece_id, status)`; soltar em Protocolado pede o número do protocolo;
   soltar em Aguardando ou Saneamento pergunta (opcional) o alerta. Menu "…" no card: editar
   alerta, limpar alerta (`p_alerta = ''`), trocar responsável (`update pieces set responsavel`).
   Contratos saem desta página: a lista de contratos fica dentro do modal do caso (aba Dados,
   card "Contrato" com status, honorários, valor e datas). "Novo contrato" também vai para lá.
2. **`/agendamentos` vira uma agenda por dia**, sem grade semanal. Barra: busca por lead, seletor
   de data com botão "Hoje" (setas para o dia anterior/seguinte), select "Ativos e realizados |
   Só ativos | Só realizados", botão Atualizar. Título do grupo: "HOJE · QUINTA-FEIRA, 17 DE
   SETEMBRO" com o contador em chip; para outros dias, "AMANHÃ · …" ou a data por extenso.
   Cada item: hora à esquerda em negrito, nome do lead, `description` em cinza (o combinado),
   chip à direita: `REALIZADO` (cinza), `ATRASADO` (vermelho) ou `PENDENTE` (verde). Clicar no
   nome abre o modal do caso; um botão de check marca `done_at = now()`. "Nova tarefa" continua
   (título, descrição, data/hora, responsável, lead por busca). Dados de `v_tasks` filtrados por
   `dia`; Realtime em `tasks` atualiza a lista. Contador do menu = tarefas de hoje não realizadas.
3. Menu: ao lado de Jurídico, contador de cards em Revisão + Saneamento (o que exige advogado).

**Não faça.** Não recrie o kanban de contratos. Não calcule "Viável/Frágil" no front: vem da
view. Não mude `pieces.status` direto por `update`; use `ui_set_piece_status` (o banco grava o
evento com o autor).

**Critério de aceite.** Com o seed, o quadro mostra a coluna Revisão como a maior, alguns cards
com faixa amarela de alerta e Protocolado com números de protocolo. Arrastar um card de Revisão
para Aguardando e escrever um alerta faz o card mostrar a faixa amarela e o Histórico do caso
ganhar "moveu a peça de Revisão para Aguardando" com o seu nome. Em Agendamentos, hoje mostra os
retornos do seed com os realizados em cinza e os atrasados em vermelho; marcar um como feito muda
o chip sem recarregar.

---

## Prompt 10 — Clientes igual ao concorrente e sino em português

**Contexto.** `v_case_cards` (`lead_id, phase, assigned_to, contact_name, contact_phone, empresa,
prescricao_alerta, prescricao_vencida, prescricao_dias`), `v_legal_cards` (`lead_id, etapa,
etapa_ordem, status`), `contracts` (`signed_at, valor_causa, faixa`), `contacts.uf/cidade`,
`profiles.full_name`, `v_intervention_cards` (`lead_id, contact_name, title, category, grupo,
priority`), `v_tasks` (`situacao, contact_name, title, due_at`).

**Faça.**
1. **`/clientes`** (contatos com contrato assinado) no layout do concorrente:
   - Topo: busca (nome, telefone), botão **Filtros** (UF, etapa atual, responsável, faixa) e o
     contador "N clientes" à direita.
   - Tabela com as colunas, nesta ordem: **Cliente** (avatar com a inicial, nome em negrito,
     telefone com ícone embaixo), **Etapa atual** (chip), **Responsável** (nome de
     `profiles` via `assigned_to`, ou "—"), **Empresa**, **Valor da causa**, **Cliente desde**
     (tempo relativo desde `signed_at`, ex.: "há 2 dias"; tooltip com a data completa).
   - Etapa atual: se o lead tiver linha em `v_legal_cards`, use `etapa` ("Revisão",
     "Aguardando", "Saneamento", "Pronto p/ protocolo", "Protocolado"); senão, pela fase:
     `briefing` → "Em entrevista", `peca` → "Em redação", `encerrado` → "Encerrado", outras →
     o nome da fase. Cores: Em entrevista azul-claro, Protocolado roxo-claro, demais cinza.
   - Paginação no rodapé: "1–50 de N", "Por página 50 | 100", Anterior / Próxima.
   - Clicar na linha abre o modal do caso.
2. **Sino de notificações**: três seções, cada uma com link para a página certa:
   - **Intervenção humana (N)**: cada item mostra `title` (texto legível, nunca a categoria
     crua), o nome do lead em cinza e o chip P1..P4; clicar abre o caso. Máximo 6 itens e
     "ver todas".
   - **Prescrição em alerta (N)**: leads de `v_case_cards` com `prescricao_alerta` ou
     `prescricao_vencida`; item = nome do lead e "prescreve em X dias" (vermelho se vencida).
   - **Tarefas atrasadas (N)**: `v_tasks` com `situacao = 'atrasado'`; item = título, nome do
     lead e hora.
   - Badge = soma das três. Se uma seção estiver vazia, mostre "Nada por aqui".
3. Nada de código de categoria (`snake_case`) visível em lugar nenhum do app. Onde aparecer,
   troque por rótulo em português.

**Critério de aceite.** Com o seed, Clientes mostra 33 clientes com etapas variadas (não só
"Briefing"), responsável preenchido e "há N dias". O sino lista títulos legíveis com o nome do
lead e uma seção de prescrição.

---

## Prompt 11 — O caso completo (modal igual ao do concorrente)

**Pré-requisito.** `supabase/011_caso_completo.sql` aplicada e tipos regenerados. `lead_dossier()`
agora traz também `agent` (quem conduz: `role, name`), `roles` (responsável, supervisor,
protocolador com nomes), `contracts` (todos), `actions` (ações da intervenção com
`resultado_titulo` e `created_by_name`), e `lead` com `closed_reason, paused, paused_at, retorno_em,
drive_folder_url, notas_internas, last_inbound_at, last_outbound_at, followup_step,
followup_next_at`. `contact` ganhou `cpf, email, nascimento, estado_civil, nacionalidade, endereco,
cep`; `case_data` ganhou `empresa_cnpj, motivo_saida, acidente_trabalho, tem_caso,
objecao_principal, objecao_detalhe`; `briefing` ganhou as seções (`dados_pessoais, dados_vinculo,
verbas, timeline, inconsistencias, gaps, teses, fatos, alertas, testemunhas, conteudo, agent_role`).
RPCs novas: `ui_close_lead(p_lead, p_reason)`, `ui_reopen_lead(p_lead, p_to)`,
`ui_pause_lead(p_lead, p_paused, p_retorno)`, `ui_set_lead_roles(p_lead, p_assigned,
p_supervisor, p_protocolador)`, `intervention_results()` (catálogo de resultados),
`log_intervention_action(p_intervention, p_tipo, p_resultado, p_notas, p_retorno_em)`,
`ui_request_contract(p_lead, p_honorarios)`, `ui_confirm_contract_data(p_contract, p_confirmed)`,
`ui_manual_signature(p_contract, p_document_path)`, `contract_fill_data(p_lead)` (prévia),
`ui_upsert_briefing(p_lead, p_data)`. Realtime em `contracts`, `briefings`, `intervention_actions`.

**Faça.** Refaça o modal do caso com este layout:

1. **Cabeçalho.** Nome em negrito; abaixo "telefone · CPF"; chip "Conduzido por: {agent.name}"
   (o agente de IA da fase) ou "Equipe: {nome}" quando a conversa está assumida. À direita os
   botões: **Encerrar** (vermelho claro; diálogo com motivo obrigatório em select + texto livre:
   "Sem resposta / não atende mais", "Fora do escopo", "Já tem advogado", "Prescrito",
   "Desistiu", "Outro"; chama `ui_close_lead`), **pausa** (ícone ⏸/▶; diálogo com data de retorno
   opcional; `ui_pause_lead`), **Pegar** (claim da intervenção pendente do lead, se houver; senão
   Assumir conversa), **Drive** (abre `drive_folder_url` em nova aba; desabilitado sem URL),
   **Arquivo** (vai para a aba Documentos), fechar.
   Faixa de status quando `phase = encerrado`: fundo rosa claro, "ENCERRADO · {closed_reason} ·
   encerrado por {nome ou IA} · {Contrato fechado se houver assinado}" com botão "Reabrir"
   (`ui_reopen_lead`). Quando `paused`: faixa âmbar "PAUSADO até {retorno_em}".
   Faixa de resumo em cinco colunas: EMPRESA, CARGO, SALÁRIO, PERÍODO (admissão–demissão ou
   "—"), PRESCRIÇÃO (data + "em N dias", vermelho se vencida).
2. **Abas, nesta ordem:** Histórico, Conversa, Dados, Qualificação, Briefing, Contrato, Petição,
   Documentos, Atualizações, Tarefa. As já existentes ficam; ajustes:
   - **Histórico**: intercalar os marcadores de fase e de contrato como no concorrente ("Mudança
     de fase: Triagem → Qualificação"), com o filtro "Histórico de tarefas" mostrando só
     `intervention_*`, `task_*` e `intervention_action`.
   - **Conversa**: entre as mensagens, mostrar marcadores centralizados dos eventos de fase
     ("INICIOU QUALIFICAÇÃO · 17/09 15:51") e das mensagens `sender = sistema` com um rótulo
     ("Sistema · contrato" ou "Sistema · follow-up passo 2", vindo de `ai_meta.kind/step`).
   - **Dados**: quatro blocos recolhíveis com contador de campos: **Identificação** (nome,
     telefone, CPF, e-mail, nascimento, estado civil, nacionalidade, endereço, cidade, UF, CEP),
     **Caso jurídico** (empresa, CNPJ, cargo, salário, admissão, demissão, motivo da saída, tipo
     de rescisão, meses trabalhados, acidente de trabalho, CTPS assinada, tem caso, objeção
     principal, objeção detalhe, prescrição, valor estimado), **Atribuição & status** (fase atual,
     fase anterior via último `phase_changed`, responsável, supervisor, protocolador com select de
     membros e `ui_set_lead_roles`, humano assumiu SIM/NÃO e quando, lead pausado, data de
     retorno, ID e URL da pasta do Drive, notas internas editáveis), **Sistema** (agente condutor,
     última mudança de fase, última entrada, última saída, criado em, atualizado em). Booleans
     como chips SIM (verde) / NÃO (vermelho). Editar salva em `contacts`/`case_data`/`leads`.
   - **Briefing**: cabeçalho "Briefing" com o status ("Em andamento"/"Concluído", data) e botão
     **Baixar DOCX** (gerar no front com a lib `docx` a partir de `conteudo`, sem novo backend).
     Lista de campos: Agente autor, Status, Dados pessoais, Dados de vínculo, Verbas, Timeline,
     Inconsistências, Gaps, Teses identificadas (chips), Fatos aprofundados, Alertas (faixa
     amarela quando houver), Testemunhas, e **Conteúdo completo** renderizado como markdown.
     Botão "Editar" abre os campos de texto e salva com `ui_upsert_briefing`; "Concluir briefing"
     manda `{status:'concluido'}`.
   - **Contrato**: cabeçalho "Contrato" + botão **Enviar contrato** (ou **Regerar contrato** se já
     houver um) → `ui_request_contract` com honorários pré-preenchidos de `office_params`. Card do
     contrato ativo com: status (chip), link de assinatura (`sign_url`), PDF assinado (`pdf_url`),
     Dados confirmados (toggle → `ui_confirm_contract_data`), criado em, enviado em, assinatura
     (data), atualizado em, assinatura manual (SIM/NÃO) e botão "Anexar assinado em papel"
     (upload em `provas/<office>/<lead>/contrato-assinado.pdf` e `ui_manual_signature`). Antes de
     enviar, "Prévia" mostra `contract_fill_data` renderizado no `template_html`. Quando
     `provider_payload.error` existir, mostrar a falha em vermelho.
   - **Petição**: a peça atual (de `pieces`) com etapa, alerta, protocolo e conteúdo; botões
     **Devolver para saneamento** (`ui_set_piece_status(..., 'saneamento', alerta)`) e
     **Cadastrar peça manual** (insere `pieces` com `generated_by_actor = humano`).
   - **Documentos**: a aba Provas atual, renomeada, mais os arquivos do contrato e da peça.
   - **Atualizações**: "Documentos recebidos durante saneamento": `evidences` criadas depois da
     última entrada da peça em `saneamento`; vazio com texto "Nenhuma atualização registrada".
   - **Tarefa**: a intervenção pendente/em atendimento do lead (a mais recente): "Sobre a tarefa"
     (título), "Instruções para solucionar" (faixa amarela com `note`), "Histórico de ações"
     (lista de `actions`: tipo, resultado, notas, quem, quando), **Registrar ação** (tipo em três
     botões Ligação/Mensagem/Nota; select Resultado de `intervention_results()` filtrado por
     tipo; Notas com contador "0/20" e botão desabilitado abaixo de 20; campo opcional "Retorno
     em" com data/hora) → `log_intervention_action`; botão **Concluir tarefa** →
     `resolve_intervention` com desfecho. Sem intervenção: "Nenhuma tarefa aberta para este caso".
3. **Fila (`/fila`)**: clicar num card abre este modal já na aba Tarefa.

**Não faça.** Não grave motivo de encerramento, pausa ou papéis com `update` direto: use as RPCs
(elas gravam o evento com o autor). Não calcule prescrição, valor ou "fase anterior" no front.

**Critério de aceite.** Abrir um caso da fila mostra o cabeçalho com "Conduzido por", a faixa de
resumo e a aba Tarefa com o registro de ação; registrar uma ligação com resultado "Atendeu — quer
fechar" e 25 caracteres de nota aparece no Histórico de ações e no Histórico do caso com o seu
nome, e o contador de ligações da fila sobe. "Enviar contrato" muda a fase para Contrato e o card
mostra "enviado"; encerrar com motivo mostra a faixa rosa com o texto e o seu nome.

---

## Prompt 12 — Fila: visão "Por lead" e "Concluir lead" (resolução em lote)

**Pré-requisito.** `supabase/012_fila_por_lead.sql` aplicada e tipos regenerados. Ela cria
`v_intervention_leads` (um card por lead com pendências abertas: `lead_id, priority` (a mais
urgente), `pendencias, em_atendimento, categorias, grupos, tags, titulos, mais_antiga_em, dias,
ligacoes, claimed_by, responsavel_nome, contact_name, contact_phone, phase, paused, faixa,
verbas_total, prescricao_em, em_atendimento_humano`) e `resolve_lead_interventions(p_lead,
p_resolution, p_release_ai, p_outcome)` → número de pendências resolvidas.

**Faça.**
1. Em `/fila`, no canto superior direito, um alternador **Por tarefa | Por lead** (lembrar a
   escolha em `localStorage`). "Por tarefa" é o quadro atual, sem mudanças.
2. **Por lead**: quatro colunas por prioridade, com cabeçalho colorido e contador: **P1 Urgente**
   (vermelho), **P2 Alta** (laranja), **P3 Normal** (azul), **P4 Baixa** (cinza). Um card por
   linha de `v_intervention_leads`, na coluna da `priority`. Card: nome em negrito, "há N dias"
   à direita, telefone, linha "**N tarefas abertas**" (singular quando 1) em destaque, chips dos
   `grupos` (até 3, "+N"), `tags` (Frágil em âmbar), chip "Em atendimento" quando
   `em_atendimento_humano`, faixa e responsável (avatar) quando houver. Ordenar por `dias` desc.
   Mesma busca e filtros da visão por tarefa (responsável, grupo, tags). Realtime em
   `human_interventions` refaz a lista.
3. Clicar no card abre o modal do caso **na aba Tarefa**, que passa a listar **todas** as
   pendências abertas do lead (não só a mais recente), cada uma como um bloco recolhível com:
   título, prioridade, grupo, "Instruções para solucionar" (`note`), Histórico de ações e o
   formulário Registrar ação (Prompt 11). No rodapé da aba, botão verde **Concluir lead (N
   pendências)**: diálogo com Desfecho (select dos `outcome` existentes: sanado, cliente perdido,
   follow-up agendado, cliente retomado, reativado para o agente, assumido pelo humano, outro),
   Resolução (texto, opcional, padrão "Concluído em lote") e a caixa "Devolver a conversa para
   a IA" (marcada por padrão) → `resolve_lead_interventions`. Toast "N pendências resolvidas" e o
   modal volta para a aba Histórico, que mostra o evento "Concluiu N pendências" com o seu nome.
   Na visão "Por tarefa", cada card continua sendo resolvido individualmente.
4. Contador do menu "Intervenção humana" não muda (continua contando tarefas).

**Não faça.** Não resolva em lote no front com N chamadas a `resolve_intervention`: é uma chamada
só, para o Histórico ter um evento único.

**Critério de aceite.** Com o seed, a visão "Por lead" mostra leads com "2 tarefas abertas" ou
mais. Abrir um deles e clicar em "Concluir lead (2 pendências)" tira o card das duas visões e o
Histórico do caso ganha um único evento com o seu nome e o desfecho escolhido.

---

## Prompt 13 — O fluxo do concorrente: quadro de 7 colunas, Petição com revisão e protocolo, Empresa e Finalizados

**Pré-requisito.** `supabase/013_fluxo_laquila.sql` aplicada e tipos regenerados. A ordem das
fases mudou: contrato vem ANTES de cálculo e provas. O banco expõe `workflow_columns()` (7
colunas na ordem: closer, entrevista, viabilidade, coleta_docs, saneamento, revisao, peca),
`v_workflow_cards` (tudo de `v_case_cards` + `coluna, coluna_titulo, coluna_ordem, fase_titulo,
piece_status, piece_alerta, protocolo, agente_nome, cargo, paused, closed_reason, closed_kind,
horas_na_fase`), `ui_move_to_column(p_lead, p_coluna, p_reason)`, `phase_label(phase)`,
`piece_review_checklist()` (7 itens), `ui_review_piece(p_piece, p_checklist)`,
`ui_approve_piece(p_piece, p_force)`, `ui_protocol_piece(p_piece, p_numero_processo)`,
`ui_close_lead(p_lead, p_reason, p_kind)` (`perdido|inviavel|outro`), `ui_reopen_lead(p_lead)` (sem
fase = volta para a anterior), `cpf_valido(text)`. `pieces` ganhou `versao, qualidade,
resumo_executivo, documentos_anexar, docx_url, revisao_checklist, aprovada_em, aprovada_por`.
`offices` ganhou `instagram, facebook, linkedin, seguidores_instagram, whatsapp_juridico,
descricao_comercial`. `piece_templates` e `piece_models` NÃO aparecem mais para o escritório.

**Faça.**
1. **Fluxo de Trabalho (`/casos`)**: o kanban passa a ter as 7 colunas de `workflow_columns()`,
   nesta ordem e com estas cores de cabeçalho: Closer (roxo), Entrevista (azul), Viabilidade
   (verde), Coleta de docs (verde-água), Saneamento (âmbar), Revisão (terracota), Peça (cinza-azul).
   Dados de `v_workflow_cards`; card na coluna `coluna`. Card: nome, telefone, "empresa · cargo",
   linha "Agente: {agente_nome}", chips faixa (LOW/MID/HIGH TICKET), alerta amarelo quando
   `piece_alerta`, "há N h/dias" (`horas_na_fase`). Arrastar chama `ui_move_to_column`; soltar em
   Saneamento ou Revisão pergunta o alerta (opcional). O seletor de fase do modal mostra
   `phase_label`. A lista (`Kanban | Lista`) ganha a coluna "Etapa" com `coluna_titulo`.
   Encerrados não aparecem no quadro (ficam em Finalizados).
2. **Cabeçalho do caso, botões por etapa** (substitui os fixos do Prompt 11):
   - Coluna Closer/Entrevista/Viabilidade/Coleta: **Encerrar** (diálogo: tipo Perdido |
     Inviável | Outro + motivo) e **Pausar**.
   - Saneamento/Revisão: **Próximo passo ▾** com três itens: "Aprovar peça · segue para
     protocolo" (abre o modal Revisão da peça), "Devolver para saneamento · peça segue viva; abre
     tarefa" (`ui_set_piece_status(..., 'saneamento', alerta)` e `request_intervention` via
     `log_intervention_action`? não: apenas o status + alerta), "Encerrar caso · exige motivo;
     define perdido ou inviável". Ao lado, **Aguardar cliente** (`ui_set_piece_status(...,
     'aguardando')`).
   - Peça aprovada: botão **Protocolar** (modal "Marcar como protocolada": Número do processo com
     placeholder `0001234-56.2026.8.26.0100`, texto "Após confirmar, a peça vira protocolada";
     `ui_protocol_piece`).
   - Sempre: Pegar, Drive, Arquivo, fechar.
3. **Modal "Revisão da peça"**: título, "Petição {8 primeiros chars do id}", chips "Qualidade:
   {qualidade}" e "Aguardando revisão"; bloco "Detalhes processuais" (valor da causa, versão
   "v{versao}", qualidade, tipo principal = tese, status, criada em); "Checklist de revisão (7
   itens)" de `piece_review_checklist()` com caixas ligadas a `revisao_checklist` (cada clique
   salva com `ui_review_piece`); "Revisor responsável" (nome de `responsavel` ou "Reivindique o
   lead no header para se tornar o revisor responsável"); botão **Aprovar peça** (desabilitado até
   as 7 caixas; `ui_approve_piece`).
4. **Aba Petição**: cabeçalho "Petição" com contador, botões **Devolver para saneamento** e
   **Cadastrar peça manual**. Card da peça: status e data, "N campos", **Sincronizar** (chama a
   RPC `piece_sync` via n8n no futuro; por ora desabilitado com tooltip "em breve"), **Baixar
   DOCX** (gera do `content` com a lib `docx`), lápis para editar. Linhas: Criado em, Aprovada em,
   Aprovada por, Revisão aprovada (SIM/NÃO), Protocolada em, Nº do processo, Status, Valor da
   causa, Qualidade caso, Conteúdo Docx Url (link, se houver), **Resumo executivo** (caixa com
   "Expandir (N caracteres)" e "Copiar"), **Documentos a anexar** (lista de itens de
   `documentos_anexar`).
5. **Empresa**: no card Identificação, seção **Presença digital**: site, Instagram, Facebook,
   LinkedIn, seguidores no Instagram, descrição comercial. No card Contato: **WhatsApp do
   jurídico** com a ajuda "Número que o agente informa para quem pergunta andamento de processo".
6. **Configurações**: remova a aba Modelos para usuários do escritório (só quem tem linha em
   `platform_admins` a vê, e nela edita `piece_templates`: nome, código, conteúdo, ativo,
   obrigatório, sem botão de baixar).
7. **Finalizados**: filtro "Perdidos | Inviáveis | Todos" por `closed_kind`, coluna Motivo e
   botão "Reabrir" (volta para a fase anterior automaticamente).
8. **Dados**: ao editar CPF, valide com `cpf_valido` antes de salvar e mostre "CPF inválido".

**Não faça.** Não mude `pieces.status` ou `leads.phase` com `update`; só pelas RPCs. Não exiba
`piece_templates` nem `agent_prompts` para o escritório.

**Critério de aceite.** Com o seed, o quadro mostra as 7 colunas com cards em Closer,
Entrevista, Viabilidade, Coleta de docs e Peça. Arrastar um card de Entrevista para Viabilidade
grava "Entrevista → Viabilidade" no Histórico com o nome do usuário. Num caso em Revisão, marcar
os 7 itens e aprovar move o card para Peça e habilita Protocolar; informar o número protocola.
Encerrar como Inviável aparece em Finalizados no filtro Inviáveis; Reabrir devolve o caso para
a coluna de onde saiu.
