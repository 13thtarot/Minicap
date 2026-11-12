#!/bin/bash
# Fires N truly parallel sessions at the same slot. Usage: race.sh <db> <N>
DB=${1:-ft}; N=${2:-12}
psql_() { su postgres -c "psql -d $DB -At -q $*"; }
psql_ "-c \"truncate appointments, payments, refunds, sales, payment_webhook_events cascade; delete from auth.users where email like 'race%';\"" >/dev/null
for i in $(seq 1 $N); do
  psql_ "-c \"insert into auth.users(id,email,raw_user_meta_data) values ('00000000-0000-0000-0000-00000000f0$(printf %02d $i)','race$i@x.com','{}')\"" >/dev/null
done
D=$(psql_ "-c \"select (manila_today()+3)\"")
run() { # $1=label $2=tech-or-null
  rm -f /tmp/race_$1.*
  for i in $(seq 1 $N); do
    ( su postgres -c "psql -d $DB -At -q" <<SQL > /tmp/race_$1.$i 2>&1
set role authenticated;
select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000f0$(printf %02d $i)',false);
select 'OK' from create_booking_hold(array[5], '$D', 600, $2, 'time','Racer $i','0917 000 00$(printf %02d $i)','race$i@x.com','','race-$1-$i');
SQL
    ) &
  done; wait
  ok=$(cat /tmp/race_$1.* | grep -c '^OK'); bad=$(cat /tmp/race_$1.* | grep -c 'SLOT_UNAVAILABLE')
  echo "$1: $N parallel attempts -> $ok succeeded, $bad rejected (SLOT_UNAVAILABLE), other: $((N-ok-bad))"
}
run same_tech 2
psql_ "-c \"truncate appointments, payments, refunds, sales cascade\"" >/dev/null
cap=$(psql_ "-c \"select least((select count(*) from technicians where active and coalesce(day_off,-1)<>extract(dow from date '$D')),(select count(*) from stations where active))\"")
echo "salon capacity that day = $cap"
run any_tech null
echo "double-booked assigned-tech rows: $(psql_ "-c \"select count(*) from appointments a join appointments b on a.id<b.id and a.technician_id=b.technician_id and tstzrange(a.start_at,a.end_at)&&tstzrange(b.start_at,b.end_at) where a.status='held' and b.status='held'\"")"
