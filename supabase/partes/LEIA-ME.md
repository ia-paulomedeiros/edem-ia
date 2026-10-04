# Partes da 014, 015, 016 e 017

Geradas por `supabase/tools/split_migrations.py` a partir de `014_paridade_regras.sql`,
`015_paridade_automacoes.sql`, `016_placeholders_laquila.sql` e `017_mensageria.sql`. A junção das partes é o arquivo canônico (só mudam linhas em
branco nas bordas); nunca edite uma parte, edite o canônico e regenere.

Cada parte tem menos de 30 KB, é idempotente e termina com um SELECT de verificação:
a última linha do resultado tem que ser `resultado = OK`. Se vier `FALTOU: ...`, pare e
mande o texto.

## Ordem

`014a → 014b → 014c → 014d → 014e → 015a → 015b → 015c → 016a → 016b → 017a → 017b → 017c → 017d → 017e → 017f`

Quem já está na 016 (produção hoje) roda só `017a → 017f`.

| Parte | Tamanho | O que cria |
|---|---|---|
| 017a | 27,8 KB | `messages.kind`, colunas e status novos de `conversations` (migra open→waiting/in_service), etiquetas, departamentos, acesso por número, `can_see_conversation` nas policies, expediente, notificações |
| 017b | 27,0 KB | gatilho de mensagens, trava da IA, `followup_queue`, `send_manual_message`, `ingest_inbound`, monitor "Cliente esperando", RPCs de atendimento |
| 017c | 24,1 KB | `v_conversas`, `conversas_counts`; contexto da IA e métricas só com `kind = 'chat'` (`conversation_context`, jornada, produtividade, `v_intervention_cards`, `lead_acquisition_cost`, `mensageria_destino`) |
| 017d | 27,2 KB | respostas rápidas e buckets `respostas`/`pecas`/`contratos`, `conversation_send`, `mensageria_envio` (mídia + janela de 24h), agendadas |
| 017e | 28,5 KB | templates da Meta, mesclar conversas, origem do anúncio + `v_marketing_anuncios`, `apply_agent_effects` com etiquetas |
| 017f | 22,2 KB | modelos de petição editáveis, seed por escritório (etiquetas, departamentos, expediente, 3 templates), departamento das conversas antigas, permissões |

Depois da 017, se por algum motivo reaplicar 014, 015 ou 016, reaplique a 017 em seguida: as partes
antigas recriam funções que a 017 redefine (`run_monitors`, `ingest_inbound`, `apply_agent_effects`...).

Os modelos de petição (`modelos_laquila.sql`, fora do repositório) podem ser rodados antes ou
depois da 016: a 016 só lê `piece_templates`. Sem modelos, a geração da peça falha com aviso claro.

## Opção 1 — SQL Editor do Supabase

Uma aba por parte: abrir o arquivo, copiar tudo, colar, Cmd+A, Run. Confira que o projeto aberto
é o `edem-ia` (ifxrdywzrtqknyvnxnnp). Algumas partes recriam funções/constraints antigas
(`drop function if exists`, `drop constraint if exists`, `drop trigger if exists`) e o editor mostra
um aviso de operação destrutiva: é esperado, confirme. Se der erro, copie a mensagem inteira
(com a linha) e mande.

## Opção 2 — psql (sem colar nada)

Na raiz do repositório, com o psql instalado:

```bash
PGHOST=<host do Session pooler> supabase/tools/aplicar_partes.sh
```

O host está em Supabase → Connect → Session pooler. O script pede a senha sem mostrar na tela,
aplica as partes na ordem e para na primeira que não devolver OK. Também dá para aplicar o
arquivo inteiro de uma vez:

```bash
psql "host=<host> port=5432 dbname=postgres user=postgres.ifxrdywzrtqknyvnxnnp sslmode=require" \
  -v ON_ERROR_STOP=1 -f supabase/014_paridade_regras.sql
psql "host=<host> port=5432 dbname=postgres user=postgres.ifxrdywzrtqknyvnxnnp sslmode=require" \
  -v ON_ERROR_STOP=1 -f supabase/015_paridade_automacoes.sql
psql "host=<host> port=5432 dbname=postgres user=postgres.ifxrdywzrtqknyvnxnnp sslmode=require" \
  -v ON_ERROR_STOP=1 -f supabase/016_placeholders_laquila.sql
psql "host=<host> port=5432 dbname=postgres user=postgres.ifxrdywzrtqknyvnxnnp sslmode=require" \
  -v ON_ERROR_STOP=1 -f supabase/017_mensageria.sql
```

Só a 017 pelo script: `PGHOST=<host> supabase/tools/aplicar_partes.sh 017`.

(sem senha na linha: o psql pergunta.)

## Testado

`supabase/tests/run_upgrade.sh` reproduz produção (001..013 aplicadas uma vez + seed da 013 com
60 leads), aplica 014–016 exigindo OK em cada parte (estado de produção na 016, com uma conversa
assumida e mensagem do contato pendente), aplica as partes da 017 sobre esse estado, reaplica todas
e roda o seed atual. `supabase/tests/run.sh` aplica 001..017 do zero, duas vezes, e roda os testes
(inclusive `50_mensageria.sql`).
Passa em PostgreSQL 16.13 e 17.6 (a versão do Supabase do projeto).
