-- Fairytale Nails Salon — TEST DATABASE (no payment gateway). FRESH PROJECT ONLY: paste into Supabase > SQL Editor and run once.
-- Enable the pg_cron extension first (Database > Extensions).

-- ######## 20260101000001_schema.sql ########
-- =====================================================================
-- Fairytale Nails Salon — Phase 1: core schema
-- Times are timestamptz, interpreted in Asia/Manila. Money is numeric(12,2) PHP.
-- =====================================================================
create extension if not exists btree_gist;
create extension if not exists pgcrypto;

create type app_role      as enum ('customer','staff','owner');
create type appt_status   as enum ('held','confirmed','waiting','service','completed',
                                   'cancelled','noshow','expired','refunded','voided');
create type payment_kind  as enum ('deposit','balance');
create type payment_state as enum ('pending','paid','failed','expired','refunded','partially_refunded');
create type sale_state    as enum ('open','paid','voided','refunded','partially_refunded');
create type refund_state  as enum ('requested','processing','succeeded','failed');

-- ---------------------------------------------------------------- identity
create table profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  full_name   text not null default '',
  username    text unique,
  email       text,
  phone       text,
  address     text,
  created_at  timestamptz not null default now()
);

create table user_roles (
  user_id uuid not null references auth.users(id) on delete cascade,
  role    app_role not null,
  primary key (user_id, role)
);

-- ---------------------------------------------------------------- salon setup
create table business_settings (
  id              boolean primary key default true check (id),          -- single row
  salon_name      text    not null default 'Fairytale Nails Salon',
  open_min        int     not null default 600,    -- minutes from midnight
  close_min       int     not null default 1110,
  lunch_start_min int     not null default 720,
  lunch_end_min   int     not null default 780,
  open_days       smallint[] not null default '{1,2,3,4,5,6}',          -- 0=Sun
  slot_step_min   int     not null default 30,
  tax_rate        numeric(5,4) not null default 0.12,
  deposit_amount  numeric(12,2) not null default 250,
  hold_minutes    int     not null default 15,
  booking_window_days int not null default 60,
  updated_at      timestamptz not null default now()
);
insert into business_settings default values;

create table days_off (
  day    date primary key,
  reason text
);

create table stations (
  id     serial primary key,
  name   text not null unique,
  active boolean not null default true
);

create table technicians (
  id              serial primary key,
  user_id         uuid unique references auth.users(id) on delete set null,
  name            text not null,
  specialty       text not null default '',
  day_off         smallint,                       -- weekly day off, 0=Sun
  commission_rate numeric(5,4) not null default 0.30,
  active          boolean not null default true
);

create table service_categories (
  id         serial primary key,
  name       text not null unique,
  note       text,
  sort_order int not null default 0
);

create table services (
  id            serial primary key,
  category_id   int not null references service_categories(id),
  name          text not null,
  detail        text not null default '',
  price         numeric(12,2) not null check (price >= 0),
  price_max     numeric(12,2) check (price_max is null or price_max >= price),
  duration_min  int not null check (duration_min > 0),
  duration_max  int check (duration_max is null or duration_max >= duration_min),
  active        boolean not null default true,
  sort_order    int not null default 0
);

-- ---------------------------------------------------------------- appointments
create function appt_blocking(s appt_status) returns boolean language sql immutable as
$$ select s in ('held','confirmed','waiting','service') $$;

create table appointments (
  id               uuid primary key default gen_random_uuid(),
  code             text not null unique,
  customer_id      uuid references profiles(id),
  customer_name    text not null,
  customer_phone   text not null default '',
  customer_email   text not null default '',
  notes            text not null default '',
  book_method      text check (book_method in ('tech','time','walkin')),
  start_at         timestamptz not null,
  end_at           timestamptz not null,
  technician_id    int references technicians(id),
  station_id       int references stations(id),
  status           appt_status not null default 'held',
  is_walkin        boolean not null default false,
  hold_expires_at  timestamptz,
  est_subtotal     numeric(12,2) not null default 0,   -- snapshot at booking time
  deposit_required numeric(12,2) not null default 0,
  idempotency_key  text,
  created_by       uuid,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint appt_time_ok check (end_at > start_at),
  constraint appt_hold_ok check (status <> 'held' or hold_expires_at is not null),
  unique (customer_id, idempotency_key)
);
create index on appointments (start_at);
create index on appointments (customer_id);
create index on appointments (status, hold_expires_at);

-- Hard database guarantee against double-booking an ASSIGNED technician or station.
-- Occupying statuses: held, confirmed, waiting, service. Released statuses drop out automatically.
alter table appointments
  add constraint no_tech_overlap
  exclude using gist (technician_id with =, tstzrange(start_at, end_at, '[)') with &&)
  where (technician_id is not null and appt_blocking(status)),
  add constraint no_station_overlap
  exclude using gist (station_id with =, tstzrange(start_at, end_at, '[)') with &&)
  where (station_id is not null and appt_blocking(status));

-- Frozen snapshot lines: names/prices/durations never follow later services edits.
create table appointment_items (
  id             bigserial primary key,
  appointment_id uuid not null references appointments(id) on delete cascade,
  service_id     int references services(id) on delete set null,
  name           text not null,
  category       text not null default '',
  unit_price     numeric(12,2) not null,
  price_max      numeric(12,2),
  duration_min   int not null,
  duration_max   int
);
create index on appointment_items (appointment_id);

create table appointment_references (            -- private nail-reference images
  id             bigserial primary key,
  appointment_id uuid references appointments(id) on delete cascade,
  owner_id       uuid not null references auth.users(id) on delete cascade,
  storage_path   text not null unique,
  created_at     timestamptz not null default now()
);

create table appointment_history (
  id             bigserial primary key,
  appointment_id uuid not null references appointments(id) on delete cascade,
  action         text not null,
  actor_id       uuid,
  actor_name     text,
  created_at     timestamptz not null default now()
);
create index on appointment_history (appointment_id);

create table walkin_queue (
  id             bigserial primary key,
  guest_name     text not null,
  service_id     int references services(id),
  service_name   text not null,
  status         text not null default 'waiting' check (status in ('waiting','assigned','left')),
  appointment_id uuid references appointments(id),
  created_by     uuid,
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------- sales & money
create sequence receipt_seq start 1000;

create table sales (
  id              uuid primary key default gen_random_uuid(),
  receipt_no      text unique,                         -- assigned only when fully paid
  appointment_id  uuid references appointments(id),
  customer_id     uuid references profiles(id),
  customer_name   text not null,
  subtotal        numeric(12,2) not null,
  tax_rate        numeric(5,4)  not null,
  tax_amount      numeric(12,2) not null,
  total           numeric(12,2) not null,
  deposit_applied numeric(12,2) not null default 0,
  balance_due     numeric(12,2) not null,
  status          sale_state not null default 'open',
  created_by      uuid,
  created_at      timestamptz not null default now(),
  paid_at         timestamptz,
  unique (appointment_id)
);

create table sale_items (
  id              bigserial primary key,
  sale_id         uuid not null references sales(id) on delete cascade,
  service_id      int references services(id) on delete set null,
  name            text not null,
  unit_price      numeric(12,2) not null,
  quantity        int not null default 1,
  duration_min    int,
  technician_id   int references technicians(id),
  technician_name text,
  commission_rate numeric(5,4) not null default 0      -- snapshot for commission reports
);
create index on sale_items (sale_id);

create table payments (
  id                   uuid primary key default gen_random_uuid(),
  appointment_id       uuid references appointments(id),
  sale_id              uuid references sales(id),
  kind                 payment_kind not null,
  method               text not null,                  -- gcash, paymaya, card, grab_pay, cash ...
  provider             text not null default 'paymongo' check (provider in ('paymongo','cash','manual')),
  amount               numeric(12,2) not null check (amount > 0),
  status               payment_state not null default 'pending',
  idempotency_key      text not null unique,
  provider_checkout_id text unique,
  provider_payment_id  text unique,
  checkout_url         text,
  checkout_expires_at  timestamptz,
  paid_at              timestamptz,
  received_by          uuid,
  created_at           timestamptz not null default now(),
  check (appointment_id is not null or sale_id is not null)
);
create index on payments (appointment_id);
create index on payments (sale_id);
-- at most one live (pending) checkout per appointment+kind
create unique index one_pending_deposit on payments (appointment_id) where kind = 'deposit' and status = 'pending';
create unique index one_pending_balance on payments (sale_id)        where kind = 'balance' and status = 'pending' and provider = 'paymongo';

create table payment_webhook_events (
  id                bigserial primary key,
  provider          text not null default 'paymongo',
  provider_event_id text not null,
  event_type        text not null,
  payload           jsonb not null,
  outcome           text,
  received_at       timestamptz not null default now(),
  processed_at      timestamptz,
  unique (provider, provider_event_id)
);

create table refunds (
  id                 uuid primary key default gen_random_uuid(),
  payment_id         uuid not null references payments(id),
  sale_id            uuid references sales(id),
  appointment_id     uuid references appointments(id),
  amount             numeric(12,2) not null check (amount > 0),
  reason             text not null,
  status             refund_state not null default 'requested',
  provider_refund_id text unique,
  idempotency_key    text not null unique,
  requested_by       uuid,
  created_at         timestamptz not null default now(),
  completed_at       timestamptz
);

create table notifications (
  id             bigserial primary key,
  user_id        uuid references auth.users(id) on delete cascade,
  appointment_id uuid references appointments(id) on delete cascade,
  type           text not null,
  message        text not null,
  read_at        timestamptz,
  created_at     timestamptz not null default now()
);
create index on notifications (user_id, created_at desc);

create table audit_logs (
  id         bigserial primary key,
  actor_id   uuid,
  table_name text not null,
  row_pk     text,
  action     text not null,
  old_data   jsonb,
  new_data   jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------- triggers
create function touch_updated_at() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;
create trigger trg_appt_touch before update on appointments for each row execute function touch_updated_at();
create trigger trg_settings_touch before update on business_settings for each row execute function touch_updated_at();

create function audit_row() returns trigger language plpgsql security definer set search_path = public as
$$
declare r jsonb := to_jsonb(coalesce(new, old));
begin
  insert into audit_logs(actor_id, table_name, row_pk, action, old_data, new_data)
  values (auth.uid(), tg_table_name, coalesce(r->>'id', r->>'day', r->>'user_id'), tg_op,
          case when tg_op <> 'INSERT' then to_jsonb(old) end,
          case when tg_op <> 'DELETE' then to_jsonb(new) end);
  return coalesce(new, old);
end $$;
create trigger aud_services after insert or update or delete on services           for each row execute function audit_row();
create trigger aud_cats     after insert or update or delete on service_categories for each row execute function audit_row();
create trigger aud_techs    after insert or update or delete on technicians        for each row execute function audit_row();
create trigger aud_settings after update                     on business_settings  for each row execute function audit_row();
create trigger aud_daysoff  after insert or update or delete on days_off           for each row execute function audit_row();
create trigger aud_roles    after insert or update or delete on user_roles         for each row execute function audit_row();
create trigger aud_refunds  after insert or update           on refunds            for each row execute function audit_row();
create trigger aud_sales    after update                     on sales              for each row execute function audit_row();

-- New auth user => profile + customer role only. Staff/owner roles are granted by an owner
-- (admin-create-staff function) or the one-time owner bootstrap — never by sign-up metadata.
create function handle_new_user() returns trigger language plpgsql security definer set search_path = public as
$$
begin
  insert into profiles(id, full_name, username, email, phone)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name',''),
          nullif(lower(new.raw_user_meta_data->>'username'),''), new.email,
          new.raw_user_meta_data->>'phone');
  insert into user_roles(user_id, role) values (new.id, 'customer') on conflict do nothing;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- ######## 20260101000002_rls.sql ########
-- =====================================================================
-- Phase 2: role helpers, Row Level Security, Storage, Realtime
-- Principle: clients READ through RLS; every WRITE to appointments / money tables
-- goes through SECURITY DEFINER functions (migration 003/004) that validate the caller.
-- =====================================================================

create function has_role(r app_role) returns boolean language sql stable security definer
set search_path = public as
$$ select exists (select 1 from user_roles where user_id = auth.uid() and role = r) $$;

create function is_owner() returns boolean language sql stable security definer set search_path = public as
$$ select has_role('owner') $$;

create function is_staff() returns boolean language sql stable security definer set search_path = public as
$$ select has_role('staff') or has_role('owner') $$;

revoke all on function has_role(app_role), is_owner(), is_staff() from public;
-- anon needs these too: catalogue policies evaluate is_staff(); it simply returns false for logged-out visitors
grant execute on function has_role(app_role), is_owner(), is_staff() to anon, authenticated;

-- enable RLS everywhere
do $$ declare t text; begin
  foreach t in array array['profiles','user_roles','business_settings','days_off','stations','technicians',
    'service_categories','services','appointments','appointment_items','appointment_references',
    'appointment_history','walkin_queue','sales','sale_items','payments','payment_webhook_events',
    'refunds','notifications','audit_logs'] loop
    execute format('alter table %I enable row level security', t);
  end loop;
end $$;

-- default: browser roles get no direct write on protected tables
revoke insert, update, delete on appointments, appointment_items, appointment_history, sales, sale_items,
  payments, payment_webhook_events, refunds, audit_logs, walkin_queue, user_roles, notifications from anon, authenticated;
grant update (read_at) on notifications to authenticated;
revoke all on payment_webhook_events, audit_logs from anon, authenticated;

-- ---------------------------------------------------------------- public catalogue (read by everyone, incl. logged-out visitors)
create policy "catalogue read"   on business_settings   for select using (true);
create policy "catalogue read"   on days_off            for select using (true);
create policy "catalogue read"   on service_categories for select using (true);
create policy "catalogue read"   on services            for select using (active or is_staff());
create policy "catalogue read"   on technicians         for select using (active or is_staff());
create policy "stations staff"   on stations            for select using (is_staff());

-- owner-only configuration writes
create policy "owner write" on business_settings   for update using (is_owner()) with check (is_owner());
create policy "owner write" on days_off            for all    using (is_owner()) with check (is_owner());
create policy "owner write" on stations            for all    using (is_owner()) with check (is_owner());
create policy "owner write" on technicians         for all    using (is_owner()) with check (is_owner());
create policy "owner write" on service_categories  for all    using (is_owner()) with check (is_owner());
create policy "owner write" on services            for all    using (is_owner()) with check (is_owner());

-- ---------------------------------------------------------------- profiles / roles
create policy "own profile read"   on profiles for select using (id = auth.uid() or is_staff());
create policy "own profile update" on profiles for update using (id = auth.uid() or is_owner())
                                                          with check (id = auth.uid() or is_owner());
create policy "own roles read"     on user_roles for select using (user_id = auth.uid() or is_owner());

-- ---------------------------------------------------------------- appointments & children
create policy "appt read" on appointments for select
  using (customer_id = auth.uid() or is_staff());

create policy "items read" on appointment_items for select
  using (exists (select 1 from appointments a where a.id = appointment_id
                 and (a.customer_id = auth.uid() or is_staff())));

create policy "history read" on appointment_history for select
  using (exists (select 1 from appointments a where a.id = appointment_id
                 and (a.customer_id = auth.uid() or is_staff())));

create policy "refs read" on appointment_references for select
  using (owner_id = auth.uid() or is_staff());
create policy "refs insert own" on appointment_references for insert
  with check (owner_id = auth.uid() and storage_path like auth.uid()::text || '/%');
grant insert on appointment_references to authenticated;

create policy "queue read" on walkin_queue for select using (is_staff());

-- ---------------------------------------------------------------- money
create policy "payments read" on payments for select
  using (is_staff() or exists (select 1 from appointments a where a.id = payments.appointment_id and a.customer_id = auth.uid()));

create policy "sales read" on sales for select
  using (is_staff() or customer_id = auth.uid());

create policy "sale items read" on sale_items for select
  using (exists (select 1 from sales s where s.id = sale_id and (is_staff() or s.customer_id = auth.uid())));

create policy "refunds read" on refunds for select using (is_staff());

create policy "notif read" on notifications for select using (user_id = auth.uid());
create policy "notif mark read" on notifications for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy "audit owner" on audit_logs for select using (is_owner());
-- payment_webhook_events: no policies => unreachable from the browser; service role only.

-- ---------------------------------------------------------------- Storage (private nail references)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('nail-references', 'nail-references', false, 5242880, array['image/jpeg','image/png','image/webp','image/heic'])
on conflict (id) do nothing;

create policy "refs upload own folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'nail-references' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "refs read own or staff" on storage.objects for select to authenticated
  using (bucket_id = 'nail-references' and ((storage.foldername(name))[1] = auth.uid()::text or is_staff()));
create policy "refs delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'nail-references' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------- Realtime
-- Realtime applies RLS to these tables, so each portal only receives rows it may read.
alter publication supabase_realtime add table appointments, payments, walkin_queue, notifications, sales;
alter table appointments replica identity full;
alter table payments     replica identity full;

-- ######## 20260101000003_booking.sql ########
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

-- ######## 20260101000004_payments_sales.sql ########
-- =====================================================================
-- Phase 4/5: payments, webhook processing, invoicing, receipts, refunds, reports
-- Payment truth comes ONLY from process_payment_event() (called by the verified webhook
-- Edge Function with the service role). A customer returning to the site changes nothing.
-- =====================================================================

-- ---------------------------------------------------------------- helpers
create function _balance_paid(p_sale uuid) returns numeric language sql stable as
$$ select coalesce(sum(amount),0) from payments
   where sale_id = p_sale and kind = 'balance' and status in ('paid','partially_refunded','refunded') $$;

create function _deposit_paid(p_appt uuid) returns numeric language sql stable as
$$ select coalesce(sum(amount),0) from payments
   where appointment_id = p_appt and kind = 'deposit' and status in ('paid','partially_refunded','refunded') $$;

create function _notify(p_user uuid, p_appt uuid, p_type text, p_msg text) returns void
language sql security definer set search_path = public as
$$ insert into notifications(user_id, appointment_id, type, message)
   select p_user, p_appt, p_type, p_msg where p_user is not null $$;

create function _finalize_sale_if_paid(p_sale uuid) returns void
language plpgsql security definer set search_path = public as
$$
declare s sales%rowtype;
begin
  select * into s from sales where id = p_sale for update;
  if not found or s.status <> 'open' then return; end if;
  if s.balance_due - _balance_paid(p_sale) > 0 then return; end if;

  update sales set status = 'paid', paid_at = now(),
         receipt_no = 'FN-' || to_char(now() at time zone 'Asia/Manila','YYYYMMDD') || '-' || lpad(nextval('receipt_seq')::text, 5, '0')
   where id = p_sale;
  update appointments set status = 'completed' where id = s.appointment_id and status in ('service','waiting','confirmed');
  perform log_appt(s.appointment_id, 'Payment complete, receipt issued', 'System');
  perform _notify(s.customer_id, s.appointment_id, 'receipt', 'Thank you! Your payment is complete. Receipt is available in your account.');
end $$;
revoke all on function _finalize_sale_if_paid(uuid), _notify(uuid,uuid,text,text) from public, anon, authenticated;

-- ---------------------------------------------------------------- invoicing (staff checkout)
-- p_lines: [{"service_id":12,"unit_price":600,"technician_id":3}, ...]
create function create_invoice(p_appt uuid, p_walkin_name text, p_lines jsonb) returns jsonb
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
    values ('FN-W' || upper(substr(encode(gen_random_bytes(4),'hex'),1,5)), trim(p_walkin_name), 'walkin',
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
grant execute on function create_invoice(uuid,text,jsonb) to authenticated;

-- ---------------------------------------------------------------- counter payments (cash / staff-attested)
create function record_counter_payment(p_sale uuid, p_amount numeric, p_method text, p_idem text) returns jsonb
language plpgsql security definer set search_path = public as
$$
declare s sales%rowtype; owed numeric; pay payments%rowtype;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if p_method not in ('cash','card_terminal','gcash_counter','maya_counter','bank_transfer') then raise exception 'INVALID_METHOD'; end if;
  select * into pay from payments where idempotency_key = 'ctr:' || p_idem;
  if found then return jsonb_build_object('payment', to_jsonb(pay), 'replayed', true); end if;

  select * into s from sales where id = p_sale for update;
  if not found or s.status <> 'open' then raise exception 'SALE_NOT_OPEN'; end if;
  owed := s.balance_due - _balance_paid(s.id);
  if p_amount is null or p_amount <= 0 or p_amount > owed then raise exception 'INVALID_AMOUNT'; end if;

  -- a pending online checkout for this sale is now stale
  update payments set status = 'expired' where sale_id = s.id and kind = 'balance' and provider = 'paymongo' and status = 'pending';

  insert into payments(appointment_id, sale_id, kind, method, provider, amount, status, idempotency_key, paid_at, received_by)
  values (s.appointment_id, s.id, 'balance', p_method, case when p_method = 'cash' then 'cash' else 'manual' end,
          p_amount, 'paid', 'ctr:' || p_idem, now(), auth.uid())
  returning * into pay;
  perform log_appt(s.appointment_id, 'Balance payment PHP ' || p_amount || ' received (' || p_method || ')');
  perform _finalize_sale_if_paid(s.id);
  return jsonb_build_object('payment', to_jsonb(pay), 'replayed', false, 'sale', (select to_jsonb(x) from sales x where x.id = s.id));
end $$;
grant execute on function record_counter_payment(uuid,numeric,text,text) to authenticated;

-- ---------------------------------------------------------------- void an UNPAID invoice
create function void_open_sale(p_sale uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as
$$
declare s sales%rowtype;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into s from sales where id = p_sale for update;
  if not found or s.status <> 'open' or _balance_paid(p_sale) > 0 then raise exception 'CANNOT_VOID'; end if;
  update sales set status = 'voided' where id = p_sale;
  update payments set status = 'expired' where sale_id = p_sale and status = 'pending';
  perform log_appt(s.appointment_id, 'Invoice voided: ' || coalesce(p_reason,''));
end $$;
grant execute on function void_open_sale(uuid,text) to authenticated;

-- ---------------------------------------------------------------- refunds
create function request_refund(p_payment uuid, p_amount numeric, p_reason text, p_idem text) returns refunds
language plpgsql security definer set search_path = public as
$$
declare pay payments%rowtype; already numeric; r refunds%rowtype;
begin
  if not is_staff() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(trim(coalesce(p_reason,''))) < 3 then raise exception 'REASON_REQUIRED'; end if;
  select * into r from refunds where idempotency_key = 'req:' || p_idem;
  if found then return r; end if;
  select * into pay from payments where id = p_payment for update;
  if not found or pay.status not in ('paid','partially_refunded') then raise exception 'NOT_REFUNDABLE'; end if;
  select coalesce(sum(amount),0) into already from refunds where payment_id = p_payment and status in ('requested','processing','succeeded');
  if p_amount <= 0 or p_amount > pay.amount - already then raise exception 'INVALID_AMOUNT'; end if;
  insert into refunds(payment_id, sale_id, appointment_id, amount, reason, idempotency_key, requested_by)
  values (pay.id, pay.sale_id, pay.appointment_id, p_amount, trim(p_reason), 'req:' || p_idem, auth.uid())
  returning * into r;
  return r;
end $$;
grant execute on function request_refund(uuid,numeric,text,text) to authenticated;

create function _apply_refund_effects(p_refund uuid) returns void
language plpgsql security definer set search_path = public as
$$
declare r refunds%rowtype; pay payments%rowtype; done numeric; tot_paid numeric; tot_ref numeric; appt uuid;
begin
  select * into r from refunds where id = p_refund;
  select * into pay from payments where id = r.payment_id for update;
  select coalesce(sum(amount),0) into done from refunds where payment_id = pay.id and status = 'succeeded';
  update payments set status = (case when done >= pay.amount then 'refunded' else 'partially_refunded' end)::payment_state where id = pay.id;
  appt := coalesce(pay.appointment_id, r.appointment_id);
  if r.sale_id is not null then
    select coalesce(sum(p.amount),0) into tot_paid from payments p
      where (p.sale_id = r.sale_id or (p.appointment_id = appt and p.kind = 'deposit'))
        and p.status in ('paid','partially_refunded','refunded');
    select coalesce(sum(f.amount),0) into tot_ref from refunds f join payments p on p.id = f.payment_id
      where (p.sale_id = r.sale_id or (p.appointment_id = appt and p.kind = 'deposit')) and f.status = 'succeeded';
    update sales set status = (case when tot_ref >= tot_paid then 'refunded' else 'partially_refunded' end)::sale_state where id = r.sale_id;
    if tot_ref >= tot_paid then update appointments set status = 'refunded' where id = appt and status = 'completed'; end if;
  end if;
  perform log_appt(appt, 'Refund of PHP ' || r.amount || ' completed: ' || r.reason);
end $$;
revoke all on function _apply_refund_effects(uuid) from public, anon, authenticated;

-- Owner approves. Cash/manual refunds complete immediately (money handed back at the counter);
-- PayMongo refunds move to 'processing' and are executed by the process-refund Edge Function.
create function approve_refund(p_refund uuid) returns refunds
language plpgsql security definer set search_path = public as
$$
declare r refunds%rowtype; pay payments%rowtype;
begin
  if not is_owner() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into r from refunds where id = p_refund for update;
  if not found or r.status <> 'requested' then raise exception 'NOT_APPROVABLE'; end if;
  select * into pay from payments where id = r.payment_id;
  if pay.provider = 'paymongo' then
    update refunds set status = 'processing' where id = r.id returning * into r;
  else
    update refunds set status = 'succeeded', completed_at = now() where id = r.id returning * into r;
    perform _apply_refund_effects(r.id);
  end if;
  return r;
end $$;
grant execute on function approve_refund(uuid) to authenticated;

create function complete_refund(p_refund uuid, p_provider_refund_id text, p_ok boolean) returns void
language plpgsql security definer set search_path = public as
$$
declare r refunds%rowtype;
begin
  select * into r from refunds where id = p_refund for update;
  if not found or r.status <> 'processing' then return; end if;     -- idempotent
  if p_ok then
    update refunds set status = 'succeeded', provider_refund_id = p_provider_refund_id, completed_at = now() where id = r.id;
    perform _apply_refund_effects(r.id);
  else
    update refunds set status = 'failed' where id = r.id;
  end if;
end $$;
revoke all on function complete_refund(uuid,text,boolean) from public, anon, authenticated;
grant execute on function complete_refund(uuid,text,boolean) to service_role;

-- ---------------------------------------------------------------- reports (read from the single source of truth)
create view v_sales_detail with (security_invoker = true) as
select s.id, s.receipt_no, s.appointment_id, s.customer_name, s.status, s.subtotal, s.tax_amount, s.total,
       s.deposit_applied, s.balance_due, s.paid_at, s.created_at,
       (s.paid_at at time zone 'Asia/Manila')::date as sale_day
from sales s;

create view v_commission with (security_invoker = true) as
select (s.paid_at at time zone 'Asia/Manila')::date as sale_day,
       si.technician_id, si.technician_name,
       count(*) as services_done,
       sum(si.unit_price * si.quantity) as service_revenue,
       round(sum(si.unit_price * si.quantity * si.commission_rate), 2) as commission
from sale_items si join sales s on s.id = si.sale_id
where s.status in ('paid','partially_refunded')
group by 1, 2, 3;

create function owner_dashboard(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as
$$
declare r jsonb;
begin
  if not is_owner() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select jsonb_build_object(
    'completed_sales',   (select count(*) from sales where status in ('paid','partially_refunded') and (paid_at at time zone 'Asia/Manila')::date between p_from and p_to),
    'sales_total',       (select coalesce(sum(total),0) from sales where status in ('paid','partially_refunded') and (paid_at at time zone 'Asia/Manila')::date between p_from and p_to),
    'tax_collected',     (select coalesce(sum(tax_amount),0) from sales where status in ('paid','partially_refunded') and (paid_at at time zone 'Asia/Manila')::date between p_from and p_to),
    'deposits_received', (select coalesce(sum(amount),0) from payments where kind = 'deposit' and status in ('paid','partially_refunded','refunded') and (paid_at at time zone 'Asia/Manila')::date between p_from and p_to),
    'balance_payments',  (select coalesce(sum(amount),0) from payments where kind = 'balance' and status in ('paid','partially_refunded','refunded') and (paid_at at time zone 'Asia/Manila')::date between p_from and p_to),
    'refunds',           (select coalesce(sum(amount),0) from refunds where status = 'succeeded' and (completed_at at time zone 'Asia/Manila')::date between p_from and p_to),
    'outstanding_balance', (select coalesce(sum(s.balance_due - _balance_paid(s.id)),0) from sales s where s.status = 'open'),
    'forfeited_deposits', (select coalesce(sum(p.amount),0) from payments p join appointments a on a.id = p.appointment_id
                            where p.kind = 'deposit' and p.status = 'paid' and a.status in ('cancelled','noshow')
                              and (p.paid_at at time zone 'Asia/Manila')::date between p_from and p_to),
    'by_method', coalesce((select jsonb_object_agg(method, amt) from (
                   select method, sum(amount) amt from payments
                   where status in ('paid','partially_refunded') and (paid_at at time zone 'Asia/Manila')::date between p_from and p_to
                   group by method) m), '{}'::jsonb)
  ) into r;
  return r;
end $$;
grant execute on function owner_dashboard(date,date) to authenticated;

-- ######## 20260101000005_seed_and_hardening.sql ########
-- =====================================================================
-- Phase 5: seed data (mirrors the prices/durations in your current portals) + hardening
-- =====================================================================
insert into service_categories(name, note, sort_order) values
  ('Basic Care', null, 0),
  ('Gel Services', null, 1),
  ('Relaxation', null, 2),
  ('Nail Enhancements', null, 3),
  ('Packages', null, 4),
  ('Removal', null, 5),
  ('Nail Art Add-Ons', null, 6),
  ('Per Nail Add-Ons', 'Price per nail. Only applies if you prefer not to get a full set of nail art.', 7);

insert into services(category_id, name, detail, price, price_max, duration_min, duration_max, sort_order)
select c.id, v.name, v.detail, v.price, v.pmax, v.dmin, v.dmax, v.ord
from (values
  ('Kids Manicure', 'Basic Care', '', 100::numeric, null::numeric, 30, null::int, 0),
  ('Regular Manicure', 'Basic Care', '', 180::numeric, null::numeric, 30, null::int, 1),
  ('Regular Pedicure', 'Basic Care', '', 200::numeric, null::numeric, 45, null::int, 2),
  ('Regular Mani + Pedi', 'Basic Care', '', 380::numeric, null::numeric, 75, null::int, 3),
  ('Gel Manicure', 'Gel Services', '', 450::numeric, null::numeric, 45, null::int, 4),
  ('Gel Pedicure', 'Gel Services', '', 500::numeric, null::numeric, 45, null::int, 5),
  ('Gel Mani + Gel Pedi', 'Gel Services', 'Save ₱50', 900::numeric, null::numeric, 90, null::int, 6),
  ('Footspa + Gel Pedi', 'Gel Services', 'Save ₱30', 850::numeric, null::numeric, 90, null::int, 7),
  ('Footspa + Gel Mani + Gel Pedi', 'Gel Services', 'Save ₱50', 1280::numeric, null::numeric, 135, null::int, 8),
  ('Footspa', 'Relaxation', '', 380::numeric, null::numeric, 45, null::int, 9),
  ('Footspa + Regular Pedi', 'Relaxation', '', 580::numeric, null::numeric, 75, null::int, 10),
  ('Softgel Extensions', 'Nail Enhancements', '', 1000::numeric, null::numeric, 120, null::int, 11),
  ('BIAB Overlay', 'Nail Enhancements', '', 900::numeric, null::numeric, 90, null::int, 12),
  ('Self-Care Day', 'Packages', 'Footspa + Gel Mani', 820::numeric, null::numeric, 90, null::int, 13),
  ('Pamper Me', 'Packages', 'Footspa + Gel Pedi', 850::numeric, null::numeric, 90, null::int, 14),
  ('Full Glam', 'Packages', 'Footspa + Gel Mani + Gel Pedi', 1280::numeric, null::numeric, 135, null::int, 15),
  ('Luxury Set', 'Packages', 'Plain Softgel Extensions + Footspa + Gel Pedi', 1800::numeric, null::numeric, 180, null::int, 16),
  ('Gel Polish Removal', 'Removal', 'Free for returning clients', 0::numeric, null::numeric, 15, null::int, 17),
  ('Foreign Gel Polish Removal', 'Removal', '', 100::numeric, null::numeric, 20, null::int, 18),
  ('Extension Removal', 'Removal', '', 150::numeric, null::numeric, 30, null::int, 19),
  ('BIAB Removal', 'Removal', '', 150::numeric, null::numeric, 30, null::int, 20),
  ('Foreign Nail Enhancements Removal', 'Removal', '', 300::numeric, null::numeric, 45, null::int, 21),
  ('Glitter Accent', 'Nail Art Add-Ons', 'Free', 0::numeric, null::numeric, 10, null::int, 22),
  ('Simple Nail Art', 'Nail Art Add-Ons', '1-2 nails', 50::numeric, 100::numeric, 30, 60::int, 23),
  ('Full Nail Art', 'Nail Art Add-Ons', '3 nails to full set', 300::numeric, null::numeric, 60, null::int, 24),
  ('Complex', 'Nail Art Add-Ons', 'Detailed, multiple techniques', 500::numeric, null::numeric, 90, null::int, 25),
  ('Super', 'Nail Art Add-Ons', 'Full set of intricate designs', 800::numeric, null::numeric, 120, null::int, 26),
  ('EXTRA', 'Nail Art Add-Ons', 'Time-intensive, premium techniques', 1000::numeric, 2000::numeric, 150, 180::int, 27),
  ('Pet Portraits', 'Per Nail Add-Ons', '', 100::numeric, 200::numeric, 15, 30::int, 28),
  ('3D Flowers', 'Per Nail Add-Ons', '', 100::numeric, null::numeric, 15, null::int, 29),
  ('3D Embossed Lines, drops, etc.', 'Per Nail Add-Ons', '', 100::numeric, null::numeric, 15, null::int, 30),
  ('Character Drawing', 'Per Nail Add-Ons', '', 100::numeric, 200::numeric, 15, 30::int, 31)
) as v(name, cat, detail, price, pmax, dmin, dmax, ord)
join service_categories c on c.name = v.cat
order by v.ord;   -- explicit: service ids must match the portals' numbering (1..33)

insert into technicians(name, specialty, day_off) values
  ('Nina', 'Gel & extensions', 1),
  ('Koye', 'Pedicure & spa', 2),
  ('Joy', 'Extensions', 3),
  ('Mina', 'Nail art', 4),
  ('Bea', 'Gel manicure', 5),
  ('Ria', 'Nail art', 1),
  ('Cathy', 'Spa treatments', 2),
  ('Lea', 'Basics & removal', 3);

insert into stations(name) select 'Station ' || g from generate_series(1,7) g;

-- ---------------------------------------------------------------- hardening
-- Supabase grants EXECUTE on new functions to anon/authenticated by default. Reset, then grant deliberately.
revoke execute on all functions in schema public from anon;
grant  execute on function public.get_available_slots(date,int,int) to anon;
grant  execute on function public.has_role(app_role), public.is_owner(), public.is_staff() to anon;
grant  usage on schema public to anon, authenticated;
grant  select on all tables in schema public to authenticated;
grant  select on services, service_categories, technicians, business_settings, days_off to anon;
revoke select on payment_webhook_events, audit_logs from authenticated;
grant  select on audit_logs to authenticated;   -- RLS limits this to owners

-- ---------------------------------------------------------------- OWNER BOOTSTRAP (run once, manually)
-- 1. In Dashboard > Authentication > Users, create the owner account (email + password).
-- 2. Run (replace the email):
--    insert into user_roles(user_id, role)
--    select id, 'owner' from auth.users where email = 'owner@yoursalon.com' on conflict do nothing;
-- Further staff accounts are created from the owner portal via the admin-create-staff Edge Function.

-- ---------------------------------------------------------------- username login helper
-- Your portals log in with "username or email". Supabase Auth needs an email, so this resolves it.
-- (Trade-off: it lets a visitor test whether a username exists. Remove it to require email-only login.)
create or replace function public.email_for_username(p_username text) returns text
language sql stable security definer set search_path = public as
$$ select email from profiles where username = lower(trim(p_username)) limit 1 $$;
revoke all on function public.email_for_username(text) from public;
grant execute on function public.email_for_username(text) to anon, authenticated;

-- ######## 20260101000006_test_mode.sql ########
-- =====================================================================
-- TEST MODE: no payment gateway. A customer "pays" the deposit with a button; the database records it
-- as a provider='test' payment and confirms the booking. Turn off before going live:
--   update business_settings set test_mode = false;
-- =====================================================================
alter table payments drop constraint if exists payments_provider_check;
alter table payments add  constraint payments_provider_check check (provider in ('paymongo','cash','manual','test'));
alter table business_settings add column if not exists test_mode boolean not null default true;

create or replace function simulate_deposit_payment(p_appt uuid, p_method text default 'test_gcash') returns jsonb
language plpgsql security definer set search_path = public as
$$
declare a appointments%rowtype; pay payments%rowtype;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  if not (select test_mode from business_settings) then raise exception 'TEST_MODE_OFF'; end if;
  select * into a from appointments where id = p_appt for update;
  if not found or not (a.customer_id = auth.uid() or is_staff()) then raise exception 'NOT_FOUND'; end if;

  select * into pay from payments where appointment_id = a.id and kind = 'deposit' and status = 'paid';
  if found then return jsonb_build_object('payment', to_jsonb(pay), 'replayed', true); end if;   -- idempotent

  perform expire_holds();
  select * into a from appointments where id = p_appt;
  if a.status <> 'held' then raise exception 'HOLD_EXPIRED'; end if;

  insert into payments(appointment_id, kind, method, provider, amount, status, idempotency_key, paid_at, received_by)
  values (a.id, 'deposit', p_method, 'test', a.deposit_required, 'paid', 'sim:' || a.id, now(), auth.uid())
  returning * into pay;
  update appointments set status = 'confirmed', hold_expires_at = null where id = a.id;
  perform log_appt(a.id, 'TEST deposit of PHP ' || pay.amount || ' recorded, booking confirmed', 'System');
  perform _notify(a.customer_id, a.id, 'confirmed', 'Deposit received. Your booking ' || a.code || ' is confirmed.');
  return jsonb_build_object('payment', to_jsonb(pay), 'replayed', false);
end $$;
revoke all on function simulate_deposit_payment(uuid,text) from public, anon;
grant execute on function simulate_deposit_payment(uuid,text) to authenticated;

-- ######## 20260101000007_owner_staff.sql ########
-- =====================================================================
-- Owner-managed staff accounts WITHOUT an Edge Function.
-- Flow: the person signs up normally (customer site) -> the owner enters their email in the owner portal
-- -> they receive the 'staff' role. Deactivating removes the role again. Only owners can call these.
-- =====================================================================
create table if not exists staff_accounts (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table staff_accounts enable row level security;
create policy "owner reads staff accounts" on staff_accounts for select using (is_owner());
revoke insert, update, delete on staff_accounts from anon, authenticated;

create function owner_list_staff() returns table(user_id uuid, full_name text, email text, active boolean)
language plpgsql stable security definer set search_path = public as
$$ begin
  if not is_owner() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return query select sa.user_id, p.full_name, p.email, sa.active
               from staff_accounts sa join profiles p on p.id = sa.user_id order by p.full_name;
end $$;

create function owner_add_staff(p_email text) returns uuid
language plpgsql security definer set search_path = public as
$$ declare uid uuid;
begin
  if not is_owner() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select id into uid from profiles where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'NO_ACCOUNT_FOR_EMAIL'; end if;
  if exists (select 1 from user_roles where user_id = uid and role = 'owner') then raise exception 'ALREADY_OWNER'; end if;
  insert into user_roles(user_id, role) values (uid, 'staff') on conflict do nothing;
  delete from user_roles where user_id = uid and role = 'customer';
  insert into staff_accounts(user_id, active) values (uid, true) on conflict (user_id) do update set active = true;
  return uid;
end $$;

create function owner_set_staff_active(p_user uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public as
$$ begin
  if not is_owner() then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if not exists (select 1 from staff_accounts where user_id = p_user) then raise exception 'NOT_STAFF'; end if;
  update staff_accounts set active = p_active where user_id = p_user;
  if p_active then
    insert into user_roles(user_id, role) values (p_user, 'staff') on conflict do nothing;
    delete from user_roles where user_id = p_user and role = 'customer';
  else
    delete from user_roles where user_id = p_user and role = 'staff';
    insert into user_roles(user_id, role) values (p_user, 'customer') on conflict do nothing;
  end if;
end $$;

revoke all on function owner_list_staff(), owner_add_staff(text), owner_set_staff_active(uuid,boolean) from public, anon;
grant execute on function owner_list_staff(), owner_add_staff(text), owner_set_staff_active(uuid,boolean) to authenticated;

-- Backfill: accounts created in the Dashboard BEFORE the first SQL run have no profile/role rows.
insert into profiles(id, email, full_name)
select u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', '') from auth.users u
where not exists (select 1 from profiles p where p.id = u.id);
insert into user_roles(user_id, role)
select p.id, 'customer' from profiles p
where not exists (select 1 from user_roles r where r.user_id = p.id);
