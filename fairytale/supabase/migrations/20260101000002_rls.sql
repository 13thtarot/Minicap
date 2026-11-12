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
