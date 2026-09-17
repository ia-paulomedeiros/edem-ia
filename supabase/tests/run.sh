#!/usr/bin/env bash
# Aplica 001..003 duas vezes (idempotência) num PostgreSQL 16 local e roda o smoke test.
# Uso: supabase/tests/run.sh [conninfo]   ex.: supabase/tests/run.sh "-h localhost -p 5432 -U postgres"
# Não aponte para o Supabase de produção: o shim cria um schema auth de mentira.
set -euo pipefail
cd "$(dirname "$0")/../.."

CONN="${1:--h /tmp -p 5433 -U postgres}"
DB="${EDEM_TEST_DB:-edem_test}"
PSQL="psql $CONN -v ON_ERROR_STOP=1 -q"
export PGOPTIONS='-c client_min_messages=warning'

$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d "$DB" -f supabase/tests/00_supabase_shim.sql -o /dev/null

for round in 1 2; do
  for f in supabase/001_schema.sql supabase/002_dominio_juridico.sql supabase/003_caso_unico.sql supabase/004_dashboard.sql supabase/005_funil.sql supabase/006_dashboard_periodo.sql supabase/007_fila.sql; do
    $PSQL -d "$DB" -f "$f" -o /dev/null
    echo "ok  [rodada $round] $f"
  done
done

$PSQL -d "$DB" -f supabase/tests/10_smoke.sql
$PSQL -d "$DB" -f supabase/tests/20_dashboard.sql
