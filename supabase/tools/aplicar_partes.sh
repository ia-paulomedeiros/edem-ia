#!/usr/bin/env bash
# Aplica as partes 014a.., 015a.. e 016a.. no Supabase pelo psql, na ordem, parando na primeira que
# não devolver resultado = OK. A senha é pedida sem eco e não fica no histórico.
#
# Uso (na raiz do repositório):
#   PGHOST=<host do Session pooler> supabase/tools/aplicar_partes.sh
# O host está em Supabase → Connect → Session pooler (ex.: aws-1-sa-east-1.pooler.supabase.com).
set -euo pipefail
cd "$(dirname "$0")/../.."

: "${PGHOST:?defina PGHOST com o host do Session pooler (Supabase → Connect → Session pooler)}"
export PGPORT="${PGPORT:-5432}" PGDATABASE="${PGDATABASE:-postgres}"
export PGUSER="${PGUSER:-postgres.ifxrdywzrtqknyvnxnnp}" PGSSLMODE="${PGSSLMODE:-require}"
if [ -z "${PGPASSWORD:-}" ]; then
  read -r -s -p "Senha do banco (Settings → Database): " PGPASSWORD; echo; export PGPASSWORD
fi

psql -v ON_ERROR_STOP=1 -At -c "select 'conectado em ' || current_database() || ' · ' || version()"
for f in supabase/partes/014*.sql supabase/partes/015*.sql supabase/partes/016*.sql; do
  out=$(psql -v ON_ERROR_STOP=1 -q -At -F ' | ' -f "$f" | tail -1)
  case "$out" in
    *"| OK |"*) echo "ok  $(basename "$f"): $out" ;;
    *) echo "PAROU em $(basename "$f"): $out"; exit 1 ;;
  esac
done
psql -At -c "select 'v_clientes: ' || coalesce(to_regclass('public.v_clientes')::text, 'NÃO EXISTE') || ' · leads: ' || (select count(*) from public.v_clientes)"
