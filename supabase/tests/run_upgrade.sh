#!/usr/bin/env bash
# Reproduz o upgrade em produção: banco com 001..013 aplicadas UMA vez e o seed da época
# (60 leads), e então as partes 014a.., 015a.. e 016a.. de supabase/partes/, na ordem, como o Paulo
# cola no SQL Editor (= produção na 016, com conversas e mensagens antigas). Sobre esse estado aplica
# as partes 017a.. (upgrade sobre a 016). Cada parte tem que devolver resultado = OK. Depois reaplica
# todas (idempotência), roda o seed atual e confere o essencial.
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
  local rodada="$1"; shift
  for m in "$@"; do
    for f in supabase/partes/"$m"*.sql; do
      out=$($PSQL -d "$DB" -At -F ' | ' -f "$f" | tail -1)
      case "$out" in
        *"| OK |"*) echo "ok  [$rodada] $(basename "$f"): $out" ;;
        *) echo "FALHOU [$rodada] $(basename "$f"): $out"; exit 1 ;;
      esac
    done
  done
}
apply_parts "1ª aplicação" 014 015 016
# estado da 016 em produção: conversa assumida com a última mensagem do contato (vira waiting na 017)
$PSQL -d "$DB" -o /dev/null <<'SQL'
update public.conversations set ai_paused = true where id = (select c.id from public.conversations c order by c.created_at limit 1);
insert into public.messages (office_id, conversation_id, direction, sender, body, status)
select c.office_id, c.id, 'in', 'contact', 'Alguém aí?', 'received' from public.conversations c order by c.created_at limit 1;
SQL
echo "estado da 016: $($PSQL -d "$DB" -Atc "select count(*) || ' conversas, ' || count(*) filter (where status = 'open') || ' open' from public.conversations")"
apply_parts "upgrade sobre a 016" 017
apply_parts "reaplicação" 014 015 016 017

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
  assert (select count(*) from public.piece_placeholders where laquila) = 133, '016: 133 placeholders da Láquila';
  assert (select count(*) from jsonb_object_keys(public.piece_fill_context((select id from public.leads limit 1)))) = (select count(*) from public.piece_placeholders), '016: contexto completo';
  -- 017
  assert (select count(*) from public.v_conversas) = (select count(*) from public.conversations), '017: v_conversas cobre todas as conversas';
  assert not exists (select 1 from public.conversations where department_id is null), '017: toda conversa com departamento';
  assert (select count(*) from public.conversations where status = 'waiting' and waiting_since is not null) >= 1, '017: assumida com mensagem do contato virou waiting';
  assert not exists (select 1 from public.conversations c where window_expires_at is null
                     and exists (select 1 from public.messages m where m.conversation_id = c.id and m.direction = 'in')), '017: janela calculada';
  assert (select count(*) from public.tags where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and kind = 'sistema') = 6, '017: etiquetas padrão';
  assert (select count(*) from public.departments where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = 2, '017: departamentos padrão';
  assert (select count(*) from public.wa_templates where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and name like 'edem_%') = 3, '017: templates semeados';
  assert (select count(*) from public.office_hours where office_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') = 5, '017: expediente';
  assert (select count(*) from public.messages where kind <> 'chat') >= 1, '017: seed atual gravou nota';
  assert (select count(*) from public.v_marketing_anuncios) >= 1, '017: anúncios do seed';
  assert not exists (select 1 from pg_proc where proname = 'apply_agent_effects' and pronargs = 10), '017: apply_agent_effects só com 11 parâmetros';
end $$;
select 'UPGRADE OK' as status, version();
SQL
