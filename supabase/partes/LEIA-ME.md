# Partes da 014 e da 015

Geradas por `supabase/tools/split_migrations.py` a partir de `014_paridade_regras.sql` e
`015_paridade_automacoes.sql`. A junção das partes é o arquivo canônico (só mudam linhas em
branco nas bordas); nunca edite uma parte, edite o canônico e regenere.

Cada parte tem menos de 30 KB, é idempotente e termina com um SELECT de verificação:
a última linha do resultado tem que ser `resultado = OK`. Se vier `FALTOU: ...`, pare e
mande o texto.

## Ordem

`014a → 014b → 014c → 014d → 014e → 015a → 015b → 015c`

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
```

(sem senha na linha: o psql pergunta.)

## Testado

`supabase/tests/run_upgrade.sh` reproduz produção (001..013 aplicadas uma vez + seed da 013 com
60 leads), aplica as partes na ordem exigindo OK em cada uma, reaplica todas e roda o seed atual.
Passa em PostgreSQL 16.13 e 17.6 (a versão do Supabase do projeto).
