-- =====================================================================
-- Phase 3: booking engine
--  * server-side availability (hours, lunch, days off, tech day off, capacity)
--  * create_booking_hold(): transactional, advisory-locked, idempotent
--  * exclusion constraints (migration 001) are the last line of defence
--  * expire_holds(): releases unpaid slots (also run by pg_cron every minute)
-- =====================================================================

create function manila_ts(d date, m int) returns timestamptz language sql immutable as
$$ select (d::timestamp + make_interval(mins => m)) at time zone 'Asia/Manila' $$;

create function manila_today() returns date language sql stable as
$$ select (now() at time zone 'Asia/Manila')::date $$;

create function log_appt(p_appt uuid, p_action text, p_name text default null) returns void
language sql security definer set search_path = public as
$$ insert into appointment_history(appointment_id, action, actor_id, actor_name)
   values (p_appt, p_action, auth.uid(),
           coalesce(p_name, (select full_name from profiles where id = auth.uid()), 'System')) $$;
revoke all on function log_appt(uuid,text,text) from public, anon, authenticated;

-- ---------------------------------------------------------------- expiry
create function expire_holds() returns int language plpgsql security definer set search_path = public as
$$
declare n int;
begin
  with x as (
    update appointments set status = 'expired'
    where status = 'held' and hold_expires_at < now()
    returning id),
  pay as (
    update payments p set status = 'expired'
    from x where p.appointment_id = x.id and p.kind = 'deposit' and p.status = 'pending'
    returning p.id),
  hist as (
    insert into appointment_history(appointment_id, action, actor_name)
    select id, 'Hold expired: deposit not received in time, slot released', 'System' from x
    returning id)
  select count(*) into n from x;
  return n;
end $$;
revoke all on function expire_holds() from public, anon, authenticated;

-- ---------------------------------------------------------------- availability core
-- p_exclude lets a reschedule ignore the appointment itself.
create function _slot_ok(p_date date, p_start int, p_dur int, p_tech int, p_exclude uuid default null)
returns boolean language plpgsql stable security definer set search_path = public as
$$
declare
  s business_settings%rowtype;
  dow int := extract(dow from p_date);
  t_start timestamptz; t_end timestamptz;
  cap int; busy int;
begin
  select * into s from business_settings;
  if not (dow = any (s.open_days)) then return false; end if;
  if exists (select 1 from days_off where day = p_date) then return false; end if;
  if p_date < manila_today() or p_date > manila_today() + s.booking_window_days then return false; end if;
  if p_start < s.open_min or p_start + p_dur > s.close_min then return false; end if;
  if (p_start - s.open_min) % s.slot_step_min <> 0 then return false; end if;
  if p_start < s.lunch_end_min and s.lunch_start_min < p_start + p_dur then return false; end if;

  t_start := manila_ts(p_date, p_start);
  t_end   := manila_ts(p_date, p_start + p_dur);
  if t_start <= now() then return false; end if;

  if p_tech is not null then
    if not exists (select 1 from technicians
                   where id = p_tech and active and coalesce(day_off, -1) <> dow) then return false; end if;
    if exists (select 1 from appointments a
               where a.technician_id = p_tech and appt_blocking(a.status)
                 and (p_exclude is null or a.id <> p_exclude)
                 and tstzrange(a.start_at, a.end_at, '[)') && tstzrange(t_start, t_end, '[)')) then return false; end if;
  end if;

  -- salon-wide capacity: working technicians that day, limited by active stations
  select least(
           (select count(*) from technicians where active and coalesce(day_off,-1) <> dow),
           (select count(*) from stations where active)) into cap;
  select count(*) into busy from appointments a
   where appt_blocking(a.status) and (p_exclude is null or a.id <> p_exclude)
     and tstzrange(a.start_at, a.end_at, '[)') && tstzrange(t_start, t_end, '[)');
  return busy < cap;
end $$;
revoke all on function _slot_ok(date,int,int,int,uuid) from public, anon, authenticated;

create function get_available_slots(p_date date, p_duration int, p_tech int default null)
returns setof int language plpgsql security definer set search_path = public as
$$
declare s business_settings%rowtype; m int;
begin
  perform expire_holds();
  select * into s from business_settings;
  if p_duration is null or p_duration <= 0 or p_duration > 720 then return; end if;
  m := s.open_min;
  while m + p_duration <= s.close_min loop
    if _slot_ok(p_date, m, p_duration, p_tech) then return next m; end if;
    m := m + s.slot_step_min;
  end loop;
end $$;
grant execute on function get_available_slots(date,int,int) to anon, authenticated;

-- ---------------------------------------------------------------- create hold
create function create_booking_hold(
  p_service_ids int[], p_date date, p_start_min int, p_tech int,
  p_method text, p_name text, p_phone text, p_email text, p_notes text, p_idem text)
returns jsonb language plpgsql security definer set search_path = public as
$$
declare
  uid uuid := auth.uid();
  s business_settings%rowtype;
  existing appointments%rowtype;
  v_dur int; v_price numeric; v_n int;
  a appointments%rowtype;
begin
  if uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if p_idem is null or length(p_idem) < 8 then raise exception 'IDEMPOTENCY_KEY_REQUIRED'; end if;
  if coalesce(array_length(p_service_ids,1),0) not between 1 and 8 then raise exception 'INVALID_SERVICES'; end if;
  if length(trim(coalesce(p_name,''))) < 2 or length(regexp_replace(coalesce(p_phone,''),'\D','','g')) < 7
     or p_email !~ '^\S+@\S+\.\S+$' then raise exception 'INVALID_CONTACT'; end if;

  -- idempotent replay: same customer + key returns the same appointment
  select * into existing from appointments where customer_id = uid and idempotency_key = p_idem;
  if found then
    return jsonb_build_object('appointment', to_jsonb(existing), 'replayed', true);
  end if;

  perform expire_holds();
  select * into s from business_settings;

  select count(*) into v_n from appointments where customer_id = uid and status = 'held';
  if v_n >= 3 then raise exception 'TOO_MANY_HOLDS'; end if;

  select count(*), coalesce(sum(coalesce(duration_max, duration_min)),0), coalesce(sum(price),0)
    into v_n, v_dur, v_price
    from services where id = any (p_service_ids) and active;
  if v_n <> (select count(distinct x) from unnest(p_service_ids) x) then raise exception 'INVALID_SERVICES'; end if;

  -- serialise all booking attempts for the same calendar day
  perform pg_advisory_xact_lock(hashtextextended('slots:' || p_date::text, 0));

  if not _slot_ok(p_date, p_start_min, v_dur, p_tech) then raise exception 'SLOT_UNAVAILABLE'; end if;

  begin
    insert into appointments(code, customer_id, customer_name, customer_phone, customer_email, notes,
                             book_method, start_at, end_at, technician_id, status, hold_expires_at,
                             est_subtotal, deposit_required, idempotency_key, created_by)
    values ('FN-' || upper(substr(encode(gen_random_bytes(6),'hex'),1,7)), uid, trim(p_name), trim(p_phone),
            trim(p_email), left(coalesce(p_notes,''),500), p_method,
            manila_ts(p_date, p_start_min), manila_ts(p_date, p_start_min + v_dur), p_tech,
            'held', now() + make_interval(mins => s.hold_minutes), v_price, s.deposit_amount, p_idem, uid)
    returning * into a;
  exception when exclusion_violation then
    raise exception 'SLOT_UNAVAILABLE';
  end;

  insert into appointment_items(appointment_id, service_id, name, category, unit_price, price_max, duration_min, duration_max)
  select a.id, sv.id, sv.name, c.name, sv.price, sv.price_max, sv.duration_min, sv.duration_max
  from services sv join service_categories c on c.id = sv.category_id
  where sv.id = any (p_service_ids);

  perform log_appt(a.id, 'Booked online (' || coalesce(p_method,'?') || '), slot held for deposit', 'Customer: ' || trim(p_name));
  return jsonb_build_object('appointment', to_jsonb(a), 'replayed', false);
end $$;
grant execute on function create_booking_hold(int[],date,int,int,text,text,text,text,text,text) to authenticated;

-- ---------------------------------------------------------------- customer cancel
create function cancel_my_booking(p_appt uuid) returns void language plpgsql security definer
set search_path = public as
$$
declare a appointments%rowtype;
begin
  select * into a from appointments where id = p_appt and customer_id = auth.uid() for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.status not in ('held','confirmed') then raise exception 'NOT_CANCELLABLE'; end if;
  update appointments set status = 'cancelled' where id = p_appt;
  update payments set status = 'expired' where appointment_id = p_appt and kind = 'deposit' and status = 'pending';
  perform log_appt(p_appt, case when a.status = 'held' then 'Customer cancelled before paying the deposit'
                                else 'Customer cancelled (deposit not refunded automatically)' end);
end $$;
grant execute on function cancel_my_booking(uuid) to authenticated;

-- ---------------------------------------------------------------- staff operations
create function staff_set_status(p_appt uuid, p_status appt_status) returns void
language plpgsql security definer set search_path = public as
$$
declare a appointments%rowtype;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_status not in ('confirmed','waiting','service','cancelled','noshow') then raise exception 'INVALID_STATUS'; end if;
  select * into a from appointments where id = p_appt for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if a.status not in ('confirmed','waiting','service') then raise exception 'STATUS_LOCKED'; end if;
  if p_status = 'service' and a.technician_id is null then raise exception 'ASSIGN_TECHNICIAN_FIRST'; end if;
  begin
    update appointments set status = p_status where id = p_appt;
  exception when exclusion_violation then raise exception 'TECH_OR_STATION_BUSY'; end;
  perform log_appt(p_appt, case p_status when 'service' then 'Started service'
                                         when 'cancelled' then 'Cancelled' else 'Status changed to ' || p_status end);
  if p_status = 'cancelled' and a.customer_id is not null then
    insert into notifications(user_id, appointment_id, type, message)
    values (a.customer_id, p_appt, 'cancelled', 'Your booking ' || a.code || ' was cancelled by the salon.');
  end if;
end $$;
grant execute on function staff_set_status(uuid, appt_status) to authenticated;

create function staff_assign(p_appt uuid, p_tech int, p_station int) returns void
language plpgsql security definer set search_path = public as
$$
declare a appointments%rowtype;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into a from appointments where id = p_appt for update;
  if not found or a.status not in ('held','confirmed','waiting','service') then raise exception 'NOT_ASSIGNABLE'; end if;
  if p_tech is not null and not exists (select 1 from technicians where id = p_tech and active
        and coalesce(day_off,-1) <> extract(dow from a.start_at at time zone 'Asia/Manila')) then
    raise exception 'TECH_DAY_OFF'; end if;
  begin
    update appointments set technician_id = p_tech, station_id = p_station,
           status = case when a.status = 'waiting' and (a.start_at at time zone 'Asia/Manila')::date = manila_today()
                         and p_tech is not null then 'service' else a.status end
     where id = p_appt;
  exception when exclusion_violation then raise exception 'TECH_OR_STATION_BUSY'; end;
  perform log_appt(p_appt, 'Assigned technician #' || coalesce(p_tech::text,'-') || ' to station ' || coalesce(p_station::text,'-'));
end $$;
grant execute on function staff_assign(uuid,int,int) to authenticated;

create function walkin_add(p_name text, p_service int) returns bigint
language plpgsql security definer set search_path = public as
$$
declare sv services%rowtype; qid bigint;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(trim(coalesce(p_name,''))) < 1 then raise exception 'NAME_REQUIRED'; end if;
  select * into sv from services where id = p_service and active;
  if not found then raise exception 'INVALID_SERVICE'; end if;
  insert into walkin_queue(guest_name, service_id, service_name, created_by)
  values (trim(p_name), sv.id, sv.name, auth.uid()) returning id into qid;
  return qid;
end $$;
grant execute on function walkin_add(text,int) to authenticated;

create function walkin_checkin(p_queue bigint) returns uuid
language plpgsql security definer set search_path = public as
$$
declare q walkin_queue%rowtype; sv services%rowtype; a_id uuid; st timestamptz;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into q from walkin_queue where id = p_queue and status = 'waiting' for update;
  if not found then raise exception 'NOT_IN_QUEUE'; end if;
  select * into sv from services where id = q.service_id;
  st := date_trunc('minute', now());
  insert into appointments(code, customer_name, book_method, start_at, end_at, status, is_walkin,
                           est_subtotal, created_by)
  values ('FN-W' || upper(substr(encode(gen_random_bytes(4),'hex'),1,5)), q.guest_name, 'walkin', st,
          st + make_interval(mins => coalesce(sv.duration_max, sv.duration_min, 30)), 'waiting', true,
          coalesce(sv.price,0), auth.uid())
  returning id into a_id;
  insert into appointment_items(appointment_id, service_id, name, category, unit_price, price_max, duration_min, duration_max)
  select a_id, sv.id, sv.name, c.name, sv.price, sv.price_max, sv.duration_min, sv.duration_max
  from service_categories c where c.id = sv.category_id;
  update walkin_queue set status = 'assigned', appointment_id = a_id where id = p_queue;
  perform log_appt(a_id, 'Walk-in checked in');
  return a_id;
end $$;
grant execute on function walkin_checkin(bigint) to authenticated;

create function walkin_remove(p_queue bigint) returns void language plpgsql security definer set search_path = public as
$$ begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  update walkin_queue set status = 'left' where id = p_queue and status = 'waiting';
end $$;
grant execute on function walkin_remove(bigint) to authenticated;

-- Auto-expire unpaid holds every minute (enable pg_cron in Dashboard > Database > Extensions)
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('expire-unpaid-holds', '* * * * *', 'select public.expire_holds()');
  else
    raise notice 'pg_cron not enabled: enable it, then run: select cron.schedule(''expire-unpaid-holds'',''* * * * *'',''select public.expire_holds()'');';
  end if;
end $$;
