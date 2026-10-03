#!/usr/bin/env bash
# Reproduz o upgrade em produção: banco com 001..013 aplicadas UMA vez e o seed da época
# (60 leads), e então as partes 014a.. e 015a.. de supabase/partes/, na ordem, como o Paulo
# cola no SQL Editor. Cada parte tem que devolver resultado = OK. Depois reaplica todas
# (idempotência), roda o seed atual e confere o essencial.
# Uso: supabase/tests/run_upgrade.sh [conninfo]   ex.: "-h /tmp -p 5434 -U postgres" (PostgreSQL 17)
set -euo pipefail
cd "$(dirname "$0")/../.."

CONN="${1:--h /tmp -p 5433 -U postgres}"
DB="${EDEM_TEST_DB:-edem_upgrade}"
PSQL="psql $CONN -v ON_ERROR_STOP=1 -q"
export PGOPTIONS='-c client_min_messages=warning'

python3 supabase/tools/split_migrations.py --check

$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d "$DB" -f supabase/tests/00_supabase_shim.sql -o /dev/null
for f in supabase/0{01,02,03,04,05,06,07,08,09,10,11,12,13}_*.sql; do
  $PSQL -d "$DB" -f "$f" -o /dev/null
done
$PSQL -d "$DB" -o /dev/null <<'SQL'
insert into auth.users (id, email, raw_user_meta_data) values ('99999999-9999-9999-9999-999999999999', 'paulo@edem.test', '{"full_name":"Paulo"}');
insert into public.offices (id, name, slug) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'Edem (produção simulada)', 'edem');
insert into public.office_members (office_id, user_id, role) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', '99999999-9999-9999-9999-999999999999', 'admin');
insert into public.whatsapp_numbers (office_id, phone_number_id, display_phone, token_secret_name) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'PNID-PROD', '5511900000001', 'wa_prod');
SQL
$PSQL -d "$DB" -f supabase/tests/fixtures/seed_013.sql -o /dev/null
echo "estado de produção simulado: 001..013 + seed da 013 ($($PSQL -d "$DB" -Atc 'select count(*) from public.leads') leads)"

apply_parts() {
  for f in supabase/partes/014*.sql supabase/partes/015*.sql; do
    out=$($PSQL -d "$DB" -At -F ' | ' -f "$f" | tail -1)
    case "$out" in
      *"| OK |"*) echo "ok  [$1] $(basename "$f"): $out" ;;
      *) echo "FALHOU [$1] $(basename "$f"): $out"; exit 1 ;;
    esac
  done
}
apply_parts "1ª aplicação"
apply_parts "reaplicação"

$PSQL -d "$DB" -f supabase/seed_demo.sql -o /dev/null
$PSQL -d "$DB" <<'SQL'
do $$
begin
  assert (select count(*) from public.v_clientes) = 60, 'v_clientes com os 60 leads do seed';
  assert not exists (select 1 from public.v_clientes where etapa is null), 'toda linha com etapa';
  assert (select ticket_minimo from public.office_params where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = 2000, 'default antigo 5000 virou 2000';
  assert (select faixas_ticket->0->>'ate' from public.office_params where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = '30000', 'faixas novas';
  assert (select count(*) from public.agents where office_id is null) = 8, '8 agentes';
  assert (select count(*) from public.qualification_records) > 0, 'seed atual rodou depois da 015';
  assert (select count(*) from public.integrations i where i.active and i.kind = 'mensageria') <= 1, 'uma mensageria ativa';
end $$;
select 'UPGRADE OK' as status, version();
SQL
