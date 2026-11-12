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
