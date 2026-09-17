# Prompts de build — v1 (Sprint 0: o monitor)

Cinco prompts, um por tela, na ordem. Cole um de cada vez no chat do Lovable e só passe ao
seguinte quando o critério de aceite do anterior estiver verde.

**Pré-requisitos**

- Projeto Lovable com a integração nativa do Supabase conectada.
- `supabase/001_schema.sql` e `supabase/002_dominio_juridico.sql` aplicados (SQL Editor).
- Em **Realtime**, as tabelas `conversations` e `messages` já estão na publicação (a migration cuida).
- Pelo menos um escritório, um membro e um número de WhatsApp cadastrados à mão (ver README).

**Formato de cada prompt:** Contexto → Faça → Não faça → Critério de aceite. O bloco
"Contexto" existe para o Lovable não inventar tabela nem coluna: ele descreve o que já está no banco.

---

## Prompt 1 — Fundação: auth, escritório ativo e casca do app

**Contexto.** O banco é multi-tenant. `offices` é o escritório; `office_members(office_id, user_id, role)`
liga usuários do Supabase Auth ao escritório com papel `admin | advogado | atendente`. Toda tabela
de negócio tem `office_id` e RLS: o usuário só enxerga linhas do escritório de que é membro.

**Faça.**
1. Autenticação com Supabase Auth (e-mail + senha). Tela de login e de "esqueci a senha". Sem cadastro
   aberto: usuário é criado por convite (fora do escopo desta tela).
2. Um `OfficeProvider` que, após login, carrega `office_members` do usuário. Se tiver um escritório,
   ele vira o escritório ativo. Se tiver mais de um, mostre um seletor no cabeçalho. Se não tiver
   nenhum, mostre uma tela "Você ainda não faz parte de um escritório".
3. Layout: barra lateral com Inbox, Casos, Fila, Configurações; cabeçalho com nome do escritório,
   seletor (quando houver) e avatar com sair. Rotas: `/inbox`, `/casos`, `/fila`, `/config`.
4. Um hook `useOffice()` que expõe `office`, `role` e `userId`. Todas as consultas das próximas
   telas filtram por `office.id`.
5. Gere os tipos do Supabase e use-os. Nenhum `any`.

**Não faça.** Não crie tabela nova. Não guarde escritório ativo em tabela; é estado do cliente
(localStorage para lembrar a escolha). Não coloque token, chave ou segredo no código.

**Critério de aceite.** Dois usuários de escritórios diferentes logam e cada um vê apenas o nome do
seu escritório. Um usuário sem `office_members` vê a tela de "sem escritório" e não consegue navegar.

---

## Prompt 2 — Inbox ao vivo

**Contexto.** `conversations` tem `office_id, lead_id, contact_id, status, ai_paused, paused_by,
last_message_at, last_message_preview, unread_count`. `contacts` tem `name, wa_id`. A tabela está na
publicação Realtime. `ai_paused = true` significa que a equipe assumiu e a IA está calada.

**Faça.**
1. Página `/inbox` em duas colunas: lista de conversas à esquerda, conversa aberta à direita
   (a direita fica para o Prompt 3; deixe um placeholder).
2. Lista ordenada por `last_message_at desc`, mostrando nome do contato (ou o telefone), prévia,
   horário relativo, badge com `unread_count` e um selo de estado: **IA** (verde, `ai_paused=false`)
   ou **Equipe** (âmbar, `ai_paused=true`).
3. Filtros no topo: Todas | Com IA | Com equipe | Não lidas. Busca por nome/telefone (client-side).
4. Realtime: assine `postgres_changes` em `conversations` com filtro `office_id=eq.<office.id>` para
   INSERT e UPDATE; atualize a lista sem refetch completo (upsert no estado local e reordenação).
5. Estado vazio bonito quando não há conversas.

**Não faça.** Não faça polling. Não derive "IA ou equipe" de outra coisa que não `ai_paused`.

**Critério de aceite.** Com a inbox aberta em uma aba, inserir uma mensagem de entrada pelo SQL
Editor (ou pelo n8n) faz a conversa subir para o topo e o contador de não lidas incrementar, sem
refresh. Um usuário de outro escritório não vê a conversa.

---

## Prompt 3 — Conversa aberta e o botão de assumir

**Contexto.** `messages(conversation_id, direction 'in'|'out', sender 'contact'|'ia'|'humano'|'sistema',
body, media, status 'pending'|'sent'|'delivered'|'read'|'failed'|'received', error, sent_by, created_at)`.
RPCs: `take_over(p_conversation)` pausa a IA e grava evento com o autor; `release_to_ai(p_conversation)`
devolve; `mark_conversation_read(p_conversation)` zera não lidas. A trava mora no banco: a UI só chama
a RPC e reflete `conversations.ai_paused`.

**Faça.**
1. Painel direito do `/inbox`: cabeçalho com nome, telefone, selo IA/Equipe e o botão
   **Assumir conversa** (quando `ai_paused=false`) ou **Devolver para a IA** (quando `true`).
   O botão chama a RPC correspondente e mostra loading; o selo muda quando o UPDATE chegar pelo
   Realtime (não force o estado local antes).
2. Lista de mensagens: balões à esquerda para `direction='in'`, à direita para `'out'`. Em `'out'`,
   distinga visualmente `sender='ia'` (ícone de robô) de `'humano'` (nome de quem enviou, se
   disponível) e `'sistema'`. Ticks de status em `'out'`: pending (relógio), sent (1 tick),
   delivered (2), read (2 azuis), failed (vermelho, com `error` no tooltip).
3. Realtime em `messages` filtrado por `conversation_id=eq.<id>` (INSERT e UPDATE). Scroll para o fim
   ao chegar mensagem nova se o usuário já estava no fim.
4. Ao abrir a conversa, chame `mark_conversation_read`.
5. Mídia: se `media` existir, mostre um chip com o tipo e a legenda (download fica para depois).

**Não faça.** Não escreva em `conversations.ai_paused` diretamente. Não insira em `messages` (isso é o
Prompt 4). Não invente status.

**Critério de aceite.** Clicar em Assumir muda o selo para Equipe em outra aba aberta na mesma
conversa, sem refresh, e aparece um evento `takeover` em `case_events` com `actor='humano'` e
`actor_user_id` do usuário. Devolver faz o inverso e grava `ai_released`.

---

## Prompt 4 — Envio manual

**Contexto.** Nenhuma mensagem vai para o WhatsApp sem virar linha em `messages` primeiro. A UI chama
a RPC `send_manual_message(p_conversation, p_body)`, que insere a linha com `sender='humano'`,
`status='pending'` e `sent_by=auth.uid()`. O n8n reage ao INSERT, envia pela Cloud API e atualiza o
`status` para `sent` (ou `failed`, com `error`). Enviar manualmente pausa a IA automaticamente
(trigger no banco) e grava evento `takeover`.

**Faça.**
1. Caixa de texto no rodapé do painel da conversa, com Enter para enviar e Shift+Enter para quebrar
   linha. Desabilitada se `conversations.status='closed'`.
2. Ao enviar: chame a RPC, limpe a caixa, e deixe o Realtime trazer a linha (o INSERT chega pelo canal
   do Prompt 3). Se quiser otimismo, insira um balão temporário com status pending e substitua pelo
   real quando chegar o INSERT com o mesmo `id` retornado pela RPC.
3. Quando o `status` vira `failed`, mostre o balão em vermelho com botão **Tentar de novo** que chama
   `send_manual_message` de novo com o mesmo texto (nova linha; a antiga fica como histórico).
4. Se a IA estava ativa, mostre um aviso discreto acima da caixa: "Ao enviar, você assume esta
   conversa e a IA para de responder".

**Não faça.** Não chame a API da Meta do front. Não atualize `status` do lado do cliente.

**Critério de aceite.** Enviar cria a linha (`pending`), o selo vira Equipe, e em poucos segundos o
tick vira `sent` quando o n8n roda. Sem n8n ligado, a mensagem fica em `pending` e nada quebra.

---

## Prompt 5b — Fila como esteira (kanban por tipo de tarefa)

> Substitui a lista de três colunas do Prompt 5 pelo layout do concorrente. Exige `007_fila.sql`.

**Contexto.** `v_intervention_cards` (uma linha por intervenção): `id, lead_id, conversation_id,
category, grupo, grupo_titulo, grupo_ordem, reason, note, tags[], priority 1..4, status,
requested_by_actor, claimed_by, responsavel_nome, claimed_at, resolved_at, outcome, created_at,
contact_name, contact_phone, phase, faixa, verbas_total, prescricao_em, calls_count, msgs_count, dias`.
Grupos, na ordem: seguir_conversa "Seguir conversa", follow "Follow", agendamento "Agendamento",
saneamento "Saneamento", avisos "Avisos", suporte_spam "Suporte/Spam", escalados "Escalados".
RPCs: `claim_intervention(p_id)`, `assign_intervention(p_id, p_user)` (nulo devolve à fila),
`log_intervention_call(p_id, p_note)`, `resolve_intervention(p_id, p_resolution, p_release_ai,
p_outcome)`. `human_interventions` está no Realtime.

**Faça.**
1. Topo: busca por nome/telefone do lead, filtro por responsável como uma fileira de avatares
   ("Todos" + um círculo com iniciais por membro + "Sem responsável"), botão "Filtros" com
   prioridade, grupo, faixa e marcador.
2. Kanban horizontal com uma coluna por grupo (só os que têm cards, na ordem), cabeçalho colorido
   por grupo com o título e o contador. Cards de `status in ('pendente','em_atendimento')`.
3. Card: linha de chips (categoria com rótulo; prioridade "P1 · Urgente" vermelho, "P2 · Alta"
   laranja, "P3 · Normal" azul, "P4 · Baixa" cinza; faixa "HIGH/MID/LOW TICKET" quando houver;
   cada tag como chip âmbar, ex.: "Frágil"); nome do lead em negrito com o tempo relativo à
   direita; `reason` como título; `note` em itálico com cor secundária; linha de contadores "Lig
   {calls_count} · Msgs {msgs_count} · Dias {dias}"; rodapé com avatar e nome do responsável ou
   "Sem responsável". Borda esquerda na cor do grupo.
4. Clique no card abre um painel lateral com os detalhes, os botões Assumir / Atribuir a (select
   de membros) / Registrar ligação (com nota opcional) / Abrir conversa / Resolver (diálogo com
   forma, resolução e switch de devolver à IA) / Abrir caso (`/casos?caso=<lead_id>`).
5. Realtime em `human_interventions` (filtro `office_id`): cards entram, mudam de coluna e somem
   sem refresh. Contador de pendentes no menu continua.
6. Uma aba secundária "Resolvidas" com tabela dos últimos 7 dias (lead, tipo, forma, responsável,
   tempo até resolver).

**Critério de aceite.** Os cards do seed aparecem distribuídos por grupos, com prioridade,
ticket, marcadores e contadores. Atribuir um card a um membro move o card para "em atendimento"
com o avatar. Registrar ligação incrementa "Lig" sem refresh.

---

## Prompt 5 — Fila de intervenção e cadastro do número

**Contexto.** `human_interventions(office_id, lead_id, conversation_id, category, reason, priority 1..3,
status 'pendente'|'em_atendimento'|'resolvida'|'cancelada', claimed_by, created_at)`. RPCs:
`claim_intervention(p_id)` (assume o item e a conversa), `resolve_intervention(p_id, p_resolution,
p_release_ai)`. `whatsapp_numbers(phone_number_id, waba_id, display_phone, token_secret_name, active)`:
o token fica no Vault do Supabase; aqui só o **nome** do segredo. Só `admin` escreve nessa tabela.

**Faça.**
1. Página `/fila`: cards ordenados por prioridade e depois por `created_at`, com categoria, motivo,
   nome do lead e há quanto tempo espera. Botão **Assumir** (chama `claim_intervention` e navega para
   `/inbox?conversa=<conversation_id>`). Em itens `em_atendimento`, botão **Resolver** que abre um
   diálogo com campo de resolução e um switch "Devolver para a IA" (default ligado).
2. Contador de pendentes no item "Fila" da barra lateral, atualizado por Realtime na tabela
   `human_interventions` (filtro por `office_id`).
3. Página `/config` com a aba **WhatsApp**: lista de números do escritório e formulário para cadastrar
   (`phone_number_id`, `waba_id`, `display_phone`, `token_secret_name`). Texto de ajuda explicando que
   o token deve ser criado no Vault com esse nome e que nunca é digitado aqui. Só `admin` vê o
   formulário; os demais veem a lista.
4. Na mesma página, aba **Parâmetros**: formulário sobre `office_params` (`ticket_minimo`,
   `vinculo_minimo_meses`, `alerta_prescricao_dias`, `honorarios_percent`). Só `admin` edita.

**Não faça.** Não crie campo para o token. Não exponha `service_role`.

**Critério de aceite.** Um `request_intervention(...)` rodado no SQL Editor faz o card aparecer na
fila e o contador subir sem refresh. Assumir leva à conversa já com selo Equipe. Um `atendente` não
consegue salvar um número (a RLS recusa e a UI mostra o erro).
