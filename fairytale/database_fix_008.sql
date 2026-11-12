-- Fairytale Nails FIX: removes the dependency on gen_random_bytes() (not visible on Supabase's search path).
-- Run ONCE in the SQL Editor on a project that already ran database_test_mode.sql. Permissions are unchanged.

create or replace function create_booking_hold(
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
    values ('FN-' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,7)), uid, trim(p_name), trim(p_phone),
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

create or replace function walkin_checkin(p_queue bigint) returns uuid
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
  values ('FN-W' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,5)), q.guest_name, 'walkin', st,
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

create or replace function create_invoice(p_appt uuid, p_walkin_name text, p_lines jsonb) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare
  st business_settings%rowtype; a appointments%rowtype; s sales%rowtype;
  ln jsonb; sv services%rowtype; tc technicians%rowtype;
  v_price numeric; v_sub numeric := 0; v_tax numeric; v_tot numeric; v_dep numeric := 0;
  v_dur int := 0; appt_id uuid := p_appt;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'NO_LINES'; end if;
  select * into st from business_settings;

  if appt_id is null then
    if length(trim(coalesce(p_walkin_name,''))) < 2 then raise exception 'NAME_REQUIRED'; end if;
    insert into appointments(code, customer_name, book_method, start_at, end_at, status, is_walkin, created_by)
    values ('FN-W' || upper(substr(replace(gen_random_uuid()::text,'-',''),1,5)), trim(p_walkin_name), 'walkin',
            date_trunc('minute', now()), date_trunc('minute', now()) + interval '30 minutes', 'service', true, auth.uid())
    returning id into appt_id;
  end if;

  select * into a from appointments where id = appt_id for update;
  if not found or a.status not in ('confirmed','waiting','service') then raise exception 'NOT_BILLABLE'; end if;

  select * into s from sales where appointment_id = appt_id for update;
  if found then
    if s.status <> 'open' or _balance_paid(s.id) > 0 then raise exception 'INVOICE_LOCKED'; end if;
    delete from sale_items where sale_id = s.id;
  end if;

  -- compute lines first
  create temp table if not exists _il (service_id int, name text, price numeric, dur int, tech int, tname text, rate numeric) on commit drop;
  truncate _il;
  for ln in select * from jsonb_array_elements(p_lines) loop
    select * into sv from services where id = (ln->>'service_id')::int;
    if not found then raise exception 'INVALID_SERVICE'; end if;
    select * into tc from technicians where id = (ln->>'technician_id')::int;
    if not found then raise exception 'TECHNICIAN_REQUIRED'; end if;
    v_price := coalesce((ln->>'unit_price')::numeric, sv.price);
    if v_price < sv.price or v_price > coalesce(sv.price_max, sv.price) then raise exception 'PRICE_OUT_OF_RANGE'; end if;
    insert into _il values (sv.id, sv.name, v_price, coalesce(sv.duration_max, sv.duration_min), tc.id, tc.name, tc.commission_rate);
    v_sub := v_sub + v_price; v_dur := v_dur + coalesce(sv.duration_max, sv.duration_min);
  end loop;

  v_tax := round(v_sub * st.tax_rate, 2);
  v_tot := v_sub + v_tax;
  v_dep := least(_deposit_paid(appt_id), v_tot);

  if s.id is null then
    insert into sales(appointment_id, customer_id, customer_name, subtotal, tax_rate, tax_amount, total, deposit_applied, balance_due, created_by)
    values (appt_id, a.customer_id, a.customer_name, v_sub, st.tax_rate, v_tax, v_tot, v_dep, v_tot - v_dep, auth.uid())
    returning * into s;
  else
    update sales set subtotal = v_sub, tax_rate = st.tax_rate, tax_amount = v_tax, total = v_tot,
           deposit_applied = v_dep, balance_due = v_tot - v_dep where id = s.id returning * into s;
  end if;

  insert into sale_items(sale_id, service_id, name, unit_price, duration_min, technician_id, technician_name, commission_rate)
  select s.id, service_id, name, price, dur, tech, tname, rate from _il;

  update appointments set status = 'service' where id = appt_id and status in ('confirmed','waiting');
  perform log_appt(appt_id, 'Invoice generated: total PHP ' || v_tot || ', deposit applied PHP ' || v_dep || ', balance PHP ' || (v_tot - v_dep));

  if s.balance_due = 0 then perform _finalize_sale_if_paid(s.id); end if;
  select * into s from sales where id = s.id;
  return to_jsonb(s);
end $$;
