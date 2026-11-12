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
