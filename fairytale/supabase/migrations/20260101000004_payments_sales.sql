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

-- ---------------------------------------------------------------- prepare a checkout (called by Edge Function AS THE USER)
create function prepare_payment(p_kind payment_kind, p_ref uuid) returns payments
language plpgsql security definer set search_path = public as
$$
declare
  uid uuid := auth.uid();
  a appointments%rowtype; s sales%rowtype; pay payments%rowtype;
  n int; amt numeric; st business_settings%rowtype;
begin
  if uid is null then raise exception 'AUTH_REQUIRED' using errcode = '28000'; end if;
  select * into st from business_settings;

  if p_kind = 'deposit' then
    select * into a from appointments where id = p_ref for update;
    if not found or not (a.customer_id = uid or is_staff()) then raise exception 'NOT_FOUND'; end if;
    perform expire_holds();
    select * into a from appointments where id = p_ref;
    if _deposit_paid(a.id) > 0 then raise exception 'ALREADY_PAID'; end if;
    if a.status <> 'held' then raise exception 'HOLD_EXPIRED'; end if;
    amt := a.deposit_required;

    select * into pay from payments where appointment_id = a.id and kind = 'deposit' and status = 'pending';
    if found and (pay.checkout_expires_at is null or pay.checkout_expires_at > now() + interval '2 minutes') then
      return pay;                                                -- idempotent reuse
    end if;
    update payments set status = 'expired' where appointment_id = a.id and kind = 'deposit' and status = 'pending';
    select count(*) into n from payments where appointment_id = a.id and kind = 'deposit';
    if n >= 4 then raise exception 'TOO_MANY_ATTEMPTS'; end if;
    -- give the customer time to finish paying (bounded: only the first 2 attempts extend the hold)
    if n < 2 then
      update appointments set hold_expires_at = greatest(hold_expires_at, now() + make_interval(mins => st.hold_minutes)) where id = a.id;
    end if;
    insert into payments(appointment_id, kind, method, provider, amount, idempotency_key)
    values (a.id, 'deposit', 'pending_choice', 'paymongo', amt, 'dep:' || a.id || ':' || (n + 1))
    returning * into pay;
    return pay;
  else
    select * into s from sales where id = p_ref for update;
    if not found or not (s.customer_id = uid or is_staff()) then raise exception 'NOT_FOUND'; end if;
    if s.status <> 'open' then raise exception 'SALE_NOT_OPEN'; end if;
    amt := s.balance_due - _balance_paid(s.id);
    if amt <= 0 then raise exception 'ALREADY_PAID'; end if;
    select * into pay from payments where sale_id = s.id and kind = 'balance' and provider = 'paymongo' and status = 'pending';
    if found and (pay.checkout_expires_at is null or pay.checkout_expires_at > now() + interval '2 minutes') and pay.amount = amt then
      return pay;
    end if;
    update payments set status = 'expired' where sale_id = s.id and kind = 'balance' and provider = 'paymongo' and status = 'pending';
    select count(*) into n from payments where sale_id = s.id and kind = 'balance';
    insert into payments(appointment_id, sale_id, kind, method, provider, amount, idempotency_key)
    values (s.appointment_id, s.id, 'balance', 'pending_choice', 'paymongo', amt, 'bal:' || s.id || ':' || (n + 1))
    returning * into pay;
    return pay;
  end if;
end $$;
grant execute on function prepare_payment(payment_kind, uuid) to authenticated;

create function attach_checkout(p_payment uuid, p_checkout_id text, p_url text, p_expires timestamptz) returns void
language sql security definer set search_path = public as
$$ update payments set provider_checkout_id = p_checkout_id, checkout_url = p_url, checkout_expires_at = p_expires
   where id = p_payment and status = 'pending' $$;
revoke all on function attach_checkout(uuid,text,text,timestamptz) from public, anon, authenticated;
grant execute on function attach_checkout(uuid,text,text,timestamptz) to service_role;

-- ---------------------------------------------------------------- WEBHOOK PROCESSING (service role only)
create function process_payment_event(
  p_event_id text, p_type text, p_payload jsonb,
  p_checkout_id text, p_provider_payment_id text, p_amount numeric, p_method text, p_paid boolean)
returns text language plpgsql security definer set search_path = public as
$$
declare
  ev_id bigint; ev payment_webhook_events%rowtype;
  pay payments%rowtype; a appointments%rowtype;
  v_outcome text; a_start int; a_dur int;
begin
  insert into payment_webhook_events(provider_event_id, event_type, payload)
  values (p_event_id, p_type, p_payload)
  on conflict (provider, provider_event_id) do nothing returning id into ev_id;

  if ev_id is null then
    select * into ev from payment_webhook_events where provider = 'paymongo' and provider_event_id = p_event_id for update;
    if ev.processed_at is not null then return 'duplicate_event'; end if;   -- replay: already handled
    ev_id := ev.id;
  end if;

  if not p_paid then
    update payment_webhook_events set outcome = 'ignored_not_paid', processed_at = now() where id = ev_id;
    return 'ignored_not_paid';
  end if;

  select * into pay from payments where provider_checkout_id = p_checkout_id for update;
  if not found then
    -- attach_checkout may not have committed yet: roll back so PayMongo retries this event
    raise exception 'UNKNOWN_CHECKOUT %', p_checkout_id;
  end if;

  if pay.status in ('paid','partially_refunded','refunded') then
    v_outcome := 'duplicate_payment';
  elsif p_amount is distinct from pay.amount then
    v_outcome := 'amount_mismatch';                 -- never confirm on a wrong amount; owner reviews
  else
    update payments set status = 'paid', paid_at = now(), provider_payment_id = p_provider_payment_id,
           method = coalesce(nullif(p_method,''), method)
     where id = pay.id;

    if pay.kind = 'deposit' then
      select * into a from appointments where id = pay.appointment_id for update;
      if a.status = 'held' then
        update appointments set status = 'confirmed', hold_expires_at = null where id = a.id;
        perform log_appt(a.id, 'Deposit of PHP ' || pay.amount || ' received via ' || coalesce(p_method,'PayMongo') || ', booking confirmed', 'System');
        perform _notify(a.customer_id, a.id, 'confirmed', 'Payment received. Your booking ' || a.code || ' is confirmed.');
        v_outcome := 'confirmed';
      elsif a.status = 'expired' then
        a_start := extract(hour from a.start_at at time zone 'Asia/Manila')*60 + extract(minute from a.start_at at time zone 'Asia/Manila');
        a_dur   := extract(epoch from a.end_at - a.start_at)/60;
        perform pg_advisory_xact_lock(hashtextextended('slots:' || (a.start_at at time zone 'Asia/Manila')::date::text, 0));
        if _slot_ok((a.start_at at time zone 'Asia/Manila')::date, a_start, a_dur, a.technician_id, a.id) then
          begin
            update appointments set status = 'confirmed', hold_expires_at = null where id = a.id;
            perform log_appt(a.id, 'Late deposit received; slot was still free, booking confirmed', 'System');
            perform _notify(a.customer_id, a.id, 'confirmed', 'Payment received. Your booking ' || a.code || ' is confirmed.');
            v_outcome := 'confirmed_late';
          exception when exclusion_violation then
            v_outcome := 'slot_lost';
          end;
        else
          v_outcome := 'slot_lost';
        end if;
      else
        v_outcome := 'paid_booking_not_held';       -- e.g. customer cancelled meanwhile
      end if;

      if v_outcome in ('slot_lost','paid_booking_not_held') then
        insert into refunds(payment_id, appointment_id, amount, reason, idempotency_key)
        values (pay.id, a.id, pay.amount, 'Auto: payment arrived but the booking could not be honoured (' || v_outcome || ')', 'auto:' || pay.id)
        on conflict do nothing;
        perform log_appt(a.id, 'Deposit received but slot unavailable; refund queued for owner approval', 'System');
        perform _notify(a.customer_id, a.id, 'refund', 'We could not keep your slot after payment. A full refund is being processed.');
      end if;
    else
      perform _finalize_sale_if_paid(pay.sale_id);
      v_outcome := 'balance_paid';
    end if;
  end if;

  update payment_webhook_events set outcome = v_outcome, processed_at = now() where id = ev_id;
  return v_outcome;
end $$;
revoke all on function process_payment_event(text,text,jsonb,text,text,numeric,text,boolean) from public, anon, authenticated;
grant execute on function process_payment_event(text,text,jsonb,text,text,numeric,text,boolean) to service_role;

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
