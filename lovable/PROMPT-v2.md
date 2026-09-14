# Prompts de build — v2 (Sprint 2: o caso como objeto único)

Um único modal de caso serve o kanban, a lista e a busca, alimentado por **uma** chamada a
`lead_dossier()`. Abas: Histórico, Conversa, Dados, Qualificação, Provas. Prescrição visível no
card antes de o advogado perguntar.

Mesmo formato do v1: um prompt por tela, na ordem, esperando o critério de aceite de cada um.

**Pré-requisitos**

- v1 concluído (auth, escritório ativo, inbox, conversa, envio manual, fila).
- `supabase/003_caso_unico.sql` aplicado. Ela cria `profiles`, `v_case_cards`, `ui_advance_phase()`,
  `ui_qualification_gate()`, `search_cases()`, o bucket `provas`, coloca `leads`, `case_events`,
  `tasks`, `human_interventions` e `evidences` no Realtime e amplia `lead_dossier()`.
- Regenere os tipos do Supabase depois de aplicar a 003.

**Regras que valem para todos os prompts desta série**

- A fase é `leads.phase` e só muda por `ui_advance_phase(p_lead, p_to, p_reason)`. Nunca `update leads`.
- O modal não guarda estado próprio do caso: ele renderiza o JSON de `lead_dossier(p_lead)` e
  refaz a chamada quando o Realtime avisa. Nada de "cópia local" que possa divergir.
- Todo evento nomeia o autor. A UI nunca insere em `case_events`; os eventos nascem no banco.

---

## Prompt 1 — O modal de caso (casca) e o hook do dossiê

**Contexto.** `lead_dossier(p_lead uuid) returns jsonb` devolve, numa chamada, o caso inteiro:

```
{
  lead:          { id, office_id, phase, phase_changed_at, tese, assigned_to, closed_at, closed_by, closed_reason, prescricao_em, created_at },
  card:          { ...linha de v_case_cards: contact_name, contact_phone, empresa, conversation_id, ai_paused,
                   last_message_at, unread_count, qualificado, faixa, verbas_total,
                   prescricao_em, prescricao_dias, prescricao_alerta, prescricao_vencida, intervencao_pendente, tarefas_abertas },
  contact:       { id, name, wa_id },
  conversations: [ ... ],
  case_data:     { empresa, cargo, admissao, demissao, salario, tipo_rescisao, aviso_previo, ctps_assinada,
                   fgts_depositado, ferias_vencidas, horas_extras_semanais, verbas_pagas, extras, updated_by_actor } | null,
  qualification: { passed, faixa, verbas_total, vinculo_meses, motivos[], evaluated_by_actor, evaluated_at } | null,
  verbas:        { calculado, vinculo_meses, itens{...}, verbas_pagas, total, aviso } ,
  evidences:     [ { id, kind, title, description, storage_path, status, requested_by_actor, created_at } ],
  contract, briefing, pieces, interventions, tasks,
  events:        [ { id, seq, type, actor 'ia'|'humano'|'sistema', actor_name, actor_agent, payload, created_at } ]  // mais recente primeiro
  members:       [ { user_id, role, full_name } ],
  cost:          { mensagens_ia, mensagens_humano, tokens_in, tokens_out, cost_usd },
  params:        { alerta_prescricao_dias, ticket_minimo, vinculo_minimo_meses, honorarios_percent }
}
```

Retorna `null` se o usuário não tem acesso ao lead (RLS).

**Faça.**
1. Um hook `useDossier(leadId)` com React Query: `supabase.rpc('lead_dossier', { p_lead: leadId })`.
   Tipar o retorno com uma interface `Dossier` fiel ao JSON acima.
2. Dentro do hook, assinar Realtime enquanto o modal estiver aberto e invalidar a query em qualquer
   evento de: `case_events` (filtro `lead_id=eq.<id>`), `leads` (`id=eq.<id>`), `messages`
   (`conversation_id=eq.<card.conversation_id>`), `evidences` (`lead_id=eq.<id>`), `tasks`
   (`lead_id=eq.<id>`). Um canal só, vários `.on(...)`. Remover o canal ao fechar.
3. O componente `CaseModal` abre quando a URL tem `?caso=<lead_id>` (search param), de qualquer rota.
   Fechar remove o param. Isso permite que kanban, lista, busca, inbox e fila abram o mesmo modal.
4. Cabeçalho do modal: nome do contato, telefone, `empresa`, badge da fase (cores fixas por fase),
   badge **Prescrição** (regras no Prompt 8: dias restantes; âmbar se `prescricao_alerta`, vermelho
   se `prescricao_vencida`; oculto se `prescricao_em` nulo), selo IA/Equipe da conversa, e o botão
   **Assumir / Devolver** (reaproveite do v1, chama `take_over`/`release_to_ai` com `card.conversation_id`).
5. Um seletor de fase no cabeçalho (dropdown com as 9 fases, na ordem de `case_phase`), que chama
   `ui_advance_phase`. Ao escolher `encerrado`, abrir diálogo pedindo o motivo (vai em `p_reason`).
6. Abas: Histórico, Conversa, Dados, Qualificação, Provas. Só a casca; o conteúdo vem nos próximos
   prompts. Lembrar a última aba aberta no search param `?aba=`.
7. Skeleton enquanto carrega; estado "sem acesso" se o RPC devolver `null`.

**Não faça.** Não busque tabela por tabela. Não copie o dossiê para um estado editável.

**Critério de aceite.** `/casos?caso=<id>` abre o modal com cabeçalho preenchido. Mudar a fase pelo
seletor troca o badge e, em outra aba do navegador com o mesmo modal aberto, o badge muda sem refresh.

---

## Prompt 2 — Kanban de fases

**Contexto.** `v_case_cards` é a projeção de `leads.phase` para cards: uma linha por lead com
`lead_id, office_id, phase, contact_name, contact_phone, empresa, last_message_at, last_message_preview,
unread_count, ai_paused, qualificado, faixa, verbas_total, prescricao_em, prescricao_dias,
prescricao_alerta, prescricao_vencida, intervencao_pendente, tarefas_abertas, closed_by`.
Fases, na ordem: `novo, triagem, qualificacao, provas, calculo, contrato, briefing, peca, encerrado`.
`ui_advance_phase(p_lead, p_to, p_reason)` muda a fase e grava `case_events` com `actor='humano'` e o
usuário logado. `leads` está no Realtime.

**Faça.**
1. Página `/casos` com um toggle Kanban | Lista (Lista é o Prompt 3). Kanban com 9 colunas na ordem
   acima, rolagem horizontal, contador por coluna. Coluna `encerrado` recolhida por padrão.
2. Card: nome (ou telefone), `empresa`, prévia da última mensagem, tempo desde `last_message_at`,
   selo IA/Equipe, badge de prescrição (mesma regra do cabeçalho do modal), ícone de alerta se
   `intervencao_pendente`, chip `faixa` quando `qualificado=true`. Clique abre `?caso=<lead_id>`.
3. Drag and drop entre colunas com `@dnd-kit`. Ao soltar: mova o card otimisticamente e chame
   `ui_advance_phase(lead_id, coluna_destino)`. Se falhar, volte o card e mostre o erro. Soltar em
   `encerrado` abre o diálogo de motivo antes de chamar a RPC.
4. Realtime em `leads` (filtro `office_id=eq.<office.id>`, UPDATE e INSERT): quando `phase` mudar,
   mova o card para a coluna nova (refetch da linha em `v_case_cards` pelo `lead_id`). Assim a mudança
   feita por outra pessoa ou pela IA aparece sem refresh.
5. Filtros no topo: responsável (`assigned_to`, com nomes de `profiles` via join na query da view ou
   do dossiê), só com alerta de prescrição, só com intervenção pendente.

**Não faça.** Não mantenha "coluna" em estado separado da `phase`. Não `update leads`.

**Critério de aceite (o do sprint).** Arrastar um card de `triagem` para `qualificacao` grava em
`case_events` um `phase_changed` com `actor='humano'`, `actor_user_id` do usuário e
`payload.from/to`. Com o modal desse caso aberto em **outra aba**, a aba Histórico mostra o evento
na hora, sem refresh (Prompt 4 completa a aba; aqui basta o refetch do dossiê acontecer).

---

## Prompt 3 — Lista e busca

**Contexto.** Mesma view `v_case_cards`. `search_cases(p_office, p_q, p_limit)` busca por nome,
telefone (aceita formatado), empresa e tese e devolve linhas de `v_case_cards`.

**Faça.**
1. Modo Lista em `/casos`: tabela com colunas Contato, Empresa, Fase (badge), Última mensagem,
   Prescrição (dias, com a mesma cor do badge), Qualificado (faixa), Responsável, Alertas (ícones de
   intervenção e tarefas abertas). Ordenação por última mensagem e por prescrição. Paginação de 50.
2. Campo de busca global no cabeçalho do app (atalho `/`): ao digitar 2+ caracteres, chama
   `search_cases` com debounce de 300 ms e mostra até 8 resultados num popover; Enter no resultado
   abre `?caso=<lead_id>` mantendo a rota atual.
3. Clique na linha abre o mesmo modal. Nenhuma outra tela de detalhe.
4. Filtros de fase (multi), prescrição (alerta | vencida), intervenção pendente, encerrados
   (ocultos por padrão).

**Não faça.** Não crie página `/casos/:id`. Não busque no cliente contra a lista inteira.

**Critério de aceite.** Buscar `(11) 98888` acha o lead com `wa_id` 5511988887777. A lista e o kanban
mostram os mesmos casos (só muda a projeção).

---

## Prompt 4 — Aba Histórico (linha do tempo com autor)

**Contexto.** `dossier.events` vem ordenado do mais recente ao mais antigo, cada um com `type`,
`actor` (`ia|humano|sistema`), `actor_name` (nome da pessoa, do agente ou "Sistema"), `actor_agent`
(papel do agente quando IA), `payload` e `created_at`. Tipos existentes hoje: `lead_created`,
`phase_changed {from,to,reason,closed_by}`, `takeover {via?}`, `ai_released`,
`qualification_evaluated {passed,faixa,total,motivos}`, `case_data_updated {fields}`,
`evidence_added {kind,title,status}`, `evidence_status_changed {title,from,to}`,
`intervention_requested {category,reason,priority}`, `intervention_claimed`, `intervention_resolved {resolution}`,
`task_created {title,due_at}`, `task_done {title}`. `case_events` está no Realtime.

**Faça.**
1. Linha do tempo vertical, agrupada por dia, mais recente em cima. Cada item: ícone por tipo, frase
   humana gerada por uma função `describeEvent(event)` (ex.: "Ana A moveu de Triagem para
   Qualificação — 'arrastado no kanban'"; "Agente Provas pediu intervenção: pedido de humano"),
   chip do autor com cor por `actor` (IA roxo, humano azul, sistema cinza) e horário.
2. `describeEvent` cobre todos os tipos acima e tem um fallback legível para tipos desconhecidos
   (mostra `type` e o payload em `<details>`).
3. Filtro rápido: Tudo | Fase | Conversa | Dados e provas | Fila e tarefas.
4. Além do refetch do dossiê (Prompt 1), trate o INSERT em `case_events` de forma otimista: prepend
   do evento recebido (resolvendo `actor_name` via `dossier.members` quando `actor='humano'`), e o
   refetch corrige em seguida.
5. Um mini-resumo no topo: criado em, dias na fase atual (`phase_changed_at`), custo de aquisição
   (`cost.cost_usd`, formatado em USD com 4 casas; tokens no tooltip).

**Não faça.** Não insira eventos pela UI. Não invente tipos.

**Critério de aceite.** Com o modal aberto em duas abas, mover a fase em uma delas faz a outra
mostrar "Fulano moveu de X para Y" em menos de dois segundos. O mesmo para "assumiu a conversa".

---

## Prompt 5 — Aba Conversa (inbox ao vivo dentro do caso)

**Contexto.** O painel de conversa do v1 (mensagens em Realtime, ticks de status, botão Assumir /
Devolver, caixa de envio manual via `send_manual_message`) já existe. `dossier.card.conversation_id`
aponta a conversa mais recente do lead; `dossier.conversations` lista todas.

**Faça.**
1. Extraia o painel de conversa do v1 para um componente `ConversationPanel({ conversationId })`
   reutilizável, sem depender da rota `/inbox`. Use-o na aba Conversa com `card.conversation_id`.
2. Se o lead tiver mais de uma conversa (números diferentes), um seletor no topo da aba.
3. O botão Assumir / Devolver do cabeçalho do modal e o do painel devem refletir o mesmo
   `ai_paused` (fonte única: `conversations` via Realtime).
4. Chame `mark_conversation_read` ao abrir a aba.
5. Quando a conversa estiver `closed` (caso encerrado), mostre a caixa desabilitada com a mensagem
   "Caso encerrado por <closed_by>. Reabra pela fase para conversar".

**Não faça.** Não duplique lógica do v1; refatore para reutilizar.

**Critério de aceite.** Enviar mensagem pela aba Conversa aparece também em `/inbox` na mesma
conversa, e a aba Histórico ganha o evento `takeover` se a IA estava ativa.

---

## Prompt 6 — Abas Dados e Qualificação

**Contexto.** `case_data` (uma linha por lead, PK `lead_id`) guarda o vínculo. A UI pode fazer
`upsert` direto (RLS permite ao membro), gravando `updated_by_actor='humano'`; um trigger registra
`case_data_updated` com o usuário logado e só os campos alterados. `calc_verbas(p_lead)` devolve a
estimativa (`itens`, `total`, `aviso`). `ui_qualification_gate(p_lead)` roda o portão como humano e
persiste em `lead_qualification` (`passed, faixa, verbas_total, vinculo_meses, motivos[]`). Os
parâmetros do portão estão em `dossier.params`. `leads.prescricao_em` é derivada de
`case_data.demissao` por trigger (dois anos).

**Faça — aba Dados.**
1. Formulário com react-hook-form + zod sobre `case_data`: empresa, cargo, admissão, demissão,
   salário (máscara BRL), tipo de rescisão (select com os valores do check), aviso prévio, CTPS
   assinada, FGTS depositado, férias vencidas (períodos), horas extras semanais, verbas já pagas.
   Campo `tese` (texto livre com sugestões: verbas_rescisorias, horas_extras, rescisao_indireta,
   vinculo_empregaticio) salva em `leads.tese` via `update leads set tese` (é o único campo de
   `leads` que a UI escreve).
2. Salvar faz `upsert` em `case_data` com `office_id` e `updated_by_actor='humano'`. Mostrar "Editado
   por IA / por Fulano em ..." a partir de `updated_by_actor` e do último `case_data_updated`.
3. Ao lado do campo Demissão, mostrar a prescrição resultante (`prescricao_em` do lead) e os dias.

**Faça — aba Qualificação.**
4. Painel "Verbas estimadas": tabela `itens` de `dossier.verbas` com os valores formatados, o
   `total`, `verbas_pagas` e o texto de `aviso` em destaque. Se `calculado=false`, mostrar o motivo e
   um link para a aba Dados.
5. Painel "Portão": resultado atual (`passed` verde / reprovado vermelho), `faixa`, `vinculo_meses`,
   lista de `motivos` traduzida (`vinculo_curto:6<12` → "Vínculo de 6 meses, mínimo 12"; `ticket_baixo`,
   `prescrito_em`, `dados_insuficientes`), "avaliado por X em Y". Botão **Reavaliar** chama
   `ui_qualification_gate`.
6. Rodapé com os parâmetros usados (`params`) e link para `/config`.

**Não faça.** Não calcule verbas no front. Não grave `prescricao_em` nem `phase`.

**Critério de aceite.** Preencher salário e datas e salvar atualiza `prescricao_em` no cabeçalho e
gera `case_data_updated` com `actor='humano'` no Histórico. Reavaliar muda o resultado do portão e
grava `qualification_evaluated`.

---

## Prompt 7 — Aba Provas

**Contexto.** `evidences(lead_id, kind 'documento'|'foto'|'audio'|'video'|'print'|'testemunha'|'outro',
title, description, storage_path, message_id, status 'solicitada'|'recebida'|'validada'|'rejeitada',
requested_by_actor, validated_by)`. Bucket privado `provas`, caminho obrigatório
`<office_id>/<lead_id>/<arquivo>` (a policy usa o primeiro segmento). Inserts e mudanças de status
geram eventos por trigger. `evidences` está no Realtime.

**Faça.**
1. Lista agrupada por status, com ícone por `kind`, título, descrição, quem pediu
   (`requested_by_actor`) e data. Para `testemunha`, não há arquivo: mostrar `description`.
2. Botão **Solicitar prova**: diálogo com `kind`, título e descrição; insere com
   `status='solicitada'`, `requested_by_actor='humano'`. Isso é o que a IA vai cobrar do lead na fase
   `provas` (o dossiê chega ao agente).
3. Botão **Anexar** em cada item: upload para `provas/<office_id>/<lead_id>/<uuid>-<nome>`; depois
   `update evidences set storage_path, status='recebida'`. Barra de progresso. Limite 25 MB.
4. Ações **Validar** / **Rejeitar** (mudam `status` e `validated_by=auth.uid()`). Preview: para
   imagem e PDF, `createSignedUrl` de 5 minutos e abrir em diálogo; para áudio, `<audio>`.
5. Checklist da tese: se `lead.tese` bater com um `piece_templates.tese`, mostrar
   `required_evidence` como itens pendentes com botão de solicitar cada um.

**Não faça.** Não torne o bucket público. Não salve URL assinada no banco.

**Critério de aceite.** Solicitar e anexar uma prova gera `evidence_added` e depois
`evidence_status_changed` no Histórico, ambos com o nome do usuário. Um usuário de outro escritório
não consegue baixar o arquivo pelo caminho.

---

## Prompt 8 — Prescrição em todo lugar e verificação final

**Contexto.** `v_case_cards.prescricao_dias` = dias até `prescricao_em`; `prescricao_alerta` = dentro
da janela `office_params.alerta_prescricao_dias`; `prescricao_vencida` = passou. O parâmetro é
editável em `/config` (v1, Prompt 5).

**Faça.**
1. Componente único `PrescricaoBadge({ dias, alerta, vencida })`: oculto se `dias` nulo; neutro
   ("prescreve em 400 d") fora da janela; âmbar com ícone quando `alerta`; vermelho "prescrito há N d"
   quando `vencida`. Use no card do kanban, na coluna da lista, no cabeçalho do modal e na inbox
   (ao lado do nome, quando `alerta` ou `vencida`).
2. Widget na home (`/`): "Prescrevendo" com os casos `prescricao_alerta=true` ordenados por
   `prescricao_dias`, e "Prescritos em aberto" (`prescricao_vencida=true and closed_at is null`).
   Clique abre o modal.
3. Ao mudar `alerta_prescricao_dias` em `/config`, invalidar as queries de `v_case_cards` para a
   janela nova refletir na hora.
4. **Roteiro de verificação** (adicione uma página `/dev/aceite` visível só em desenvolvimento com
   este checklist):
   - Abrir `/casos` (kanban) na aba A e `/casos?caso=<id>&aba=historico` na aba B.
   - Na aba A, arrastar o card para outra coluna.
   - Na aba B, sem refresh: badge de fase muda; Histórico ganha "Fulano moveu de X para Y".
   - Em `case_events`: linha `phase_changed`, `actor='humano'`, `actor_user_id` do usuário.
   - Ajustar `alerta_prescricao_dias` para um valor que inclua o caso; o badge fica âmbar no card, na
     lista, no modal e na inbox.

**Não faça.** Não calcule prescrição no front; use os campos da view.

**Critério de aceite.** O roteiro acima passa de ponta a ponta.
