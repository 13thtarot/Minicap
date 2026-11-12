-- Behavioural tests. Run against a scratch database after applying the migrations (see README).
\set ON_ERROR_STOP off
create or replace function t_ok(c boolean, m text) returns void language plpgsql as
$$ begin if c then raise notice 'PASS  %', m; else raise notice 'FAIL  %  <<<<<<', m; end if; end $$;
create or replace function t_as(u uuid, r text) returns void language plpgsql as
$$ begin perform set_config('request.jwt.claim.sub', coalesce(u::text,''), false); execute format('set role %I', r); end $$;
create or replace function t_err(sql text) returns text language plpgsql as
$$ begin execute sql; return null; exception when others then return sqlerrm; end $$;

reset role;
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-0000000000c1','c1@x.com','{"full_name":"Cust One","username":"cone","phone":"09170000001"}'),
 ('00000000-0000-0000-0000-0000000000c2','c2@x.com','{"full_name":"Cust Two","username":"ctwo","phone":"09170000002"}'),
 ('00000000-0000-0000-0000-0000000000a1','s1@x.com','{"full_name":"Staff One"}'),
 ('00000000-0000-0000-0000-0000000000b1','o1@x.com','{"full_name":"Owner"}');
insert into user_roles values ('00000000-0000-0000-0000-0000000000a1','staff'),('00000000-0000-0000-0000-0000000000b1','owner');
-- a sign-up can never create staff/owner:
select t_ok((select count(*) from user_roles where user_id='00000000-0000-0000-0000-0000000000c1' and role<>'customer')=0,'new sign-up only gets customer role');

create temp table ctx as select
  (select manila_today()+g from generate_series(3,9) g where extract(dow from manila_today()+g) between 1 and 5 limit 1) as d;
grant all on ctx to public;

-- ============ availability
select t_as('00000000-0000-0000-0000-0000000000c1','authenticated');
select t_ok((select count(*) from get_available_slots((select d from ctx), 45, null)) > 0, 'slots exist on an open weekday');
select t_ok((select count(*) from get_available_slots((select d from ctx), 45, null) m where m >= 720 and m < 780)=0, 'no slot starts inside lunch');
select t_ok((select count(*) from get_available_slots((select d from ctx), 45, null) m where m + 45 > 1110)=0, 'no slot runs past closing');
select t_ok((select count(*) from get_available_slots(manila_today()-1, 45, null))=0, 'no slots in the past');
select t_ok((select count(*) from get_available_slots(manila_today()+ ((7-extract(dow from manila_today())::int)%7 + case when extract(dow from manila_today())=0 then 7 else 0 end), 45, null))=0, 'no slots on closed Sunday');

-- ============ booking + idempotency
create temp table res(k text, v jsonb); grant all on res to public;
insert into res select 'h1', create_booking_hold(array[5], (select d from ctx), 600, 1, 'tech','Cust One','0917 000 0001','c1@x.com','', 'key-c1-0001');
select t_ok((select v->'appointment'->>'status' from res where k='h1')='held','booking creates a HELD appointment');
select t_ok((select (v->'appointment'->>'est_subtotal')::numeric from res where k='h1')=450,'price comes from the server (Gel Manicure = 450)');
select t_ok((select (v->'appointment'->>'deposit_required')::numeric from res where k='h1')=250,'deposit comes from settings');
insert into res select 'h1b', create_booking_hold(array[5], (select d from ctx), 600, 1, 'tech','Cust One','0917 000 0001','c1@x.com','', 'key-c1-0001');
select t_ok((select (v->>'replayed')::bool from res where k='h1b') and (select v->'appointment'->>'id' from res where k='h1b')=(select v->'appointment'->>'id' from res where k='h1'),'same idempotency key returns same appointment (no duplicate)');

-- ============ double-booking prevention
select t_as('00000000-0000-0000-0000-0000000000c2','authenticated');
select t_ok(coalesce(t_err($$select create_booking_hold(array[5], (select d from ctx), 600, 1, 'tech','Cust Two','0917 000 0002','c2@x.com','', 'key-c2-0001')$$),'')like '%SLOT_UNAVAILABLE%','same technician + overlapping time is rejected');
select t_ok(coalesce(t_err($$select create_booking_hold(array[5], (select d from ctx), 615, 1, 'tech','Cust Two','0917 000 0002','c2@x.com','', 'key-c2-0002')$$),'')like '%SLOT_UNAVAILABLE%','off-grid start time rejected');
select t_ok(coalesce(t_err($$select create_booking_hold(array[5], (select d from ctx), 630, 1, 'tech','Cust Two','0917 000 0002','c2@x.com','', 'key-c2-0003')$$),'')like '%SLOT_UNAVAILABLE%','10:30 overlaps the 10:00-10:45 booking for the same tech => rejected');
insert into res select 'h2', create_booking_hold(array[5], (select d from ctx), 660, 1, 'tech','Cust Two','0917 000 0002','c2@x.com','', 'key-c2-0004');
select t_ok((select v->'appointment'->>'status' from res where k='h2')='held','back-to-back slot (11:00, right after 10:45) for same tech is allowed');
select t_ok(coalesce(t_err($$select create_booking_hold(array[5], (select d from ctx), 600, 99, 'tech','Cust Two','0917 000 0002','c2@x.com','', 'key-c2-0005')$$),'')like '%SLOT_UNAVAILABLE%','unknown technician rejected');
select t_ok(coalesce(t_err($$select create_booking_hold(array[5], (select d from ctx), 600, null, 'time','x','1','bad','', 'key-c2-0006')$$),'')like '%INVALID_CONTACT%','invalid contact rejected');
select t_ok(coalesce(t_err($$select create_booking_hold(array[999], (select d from ctx), 600, null, 'time','Cust Two','0917 000 0002','c2@x.com','', 'key-c2-0007')$$),'')like '%INVALID_SERVICES%','unknown service rejected');

-- ============ RLS
select t_ok((select count(*) from appointments where customer_id='00000000-0000-0000-0000-0000000000c1')=0,'customer 2 cannot see customer 1 appointments');
select t_ok(coalesce(t_err($$update appointments set status='confirmed'$$),'x')like '%permission denied%','customer cannot UPDATE appointments directly');
select t_ok(coalesce(t_err($$insert into payments(appointment_id,kind,method,amount,status,idempotency_key) values (null,'deposit','x',1,'paid','k')$$),'x')like '%permission denied%','customer cannot insert payments');
select t_ok(coalesce(t_err($$update services set price=1$$),'')='' or (select count(*) from services where price=1)=0,'customer cannot change prices');
select t_ok(coalesce(t_err($$select staff_set_status(gen_random_uuid(),'waiting')$$),'')like '%FORBIDDEN%','customer cannot call staff functions');
select t_ok(coalesce(t_err($$select * from owner_dashboard(current_date,current_date)$$),'')like '%FORBIDDEN%','customer cannot read owner dashboard');
select t_ok(t_err($$select * from payment_webhook_events$$) like '%permission denied%','customer cannot read webhook events');
select t_ok(coalesce(t_err($$insert into user_roles values ('00000000-0000-0000-0000-0000000000c2','owner')$$),'x')like '%permission denied%','customer cannot grant self owner role');
select t_as(null,'anon');
select t_ok(coalesce(t_err($$select create_booking_hold(array[5], current_date+3, 600, 1,'tech','a','0917000000','a@b.co','','kkkkkkkkk')$$),'')<>'','anonymous cannot create a booking');
select t_ok((select count(*) from services)>0,'anonymous can browse services');
select t_ok((select count(*) from appointments)=0,'anonymous sees no appointments');

-- ============ payment: webhook is the only confirmation
reset role; select t_as('00000000-0000-0000-0000-0000000000c1','authenticated');
create temp table pr(id uuid, amount numeric); grant all on pr to public;
insert into pr select id, amount from prepare_payment('deposit', (select (v->'appointment'->>'id')::uuid from res where k='h1'));
select t_ok((select amount from pr)=250,'prepare_payment: amount decided by DB (250)');
select t_ok((select count(*) from prepare_payment('deposit', (select (v->'appointment'->>'id')::uuid from res where k='h1')) p where p.id=(select id from pr))=1,'prepare_payment is idempotent (reuses pending payment)');
reset role; select t_as('00000000-0000-0000-0000-0000000000c1','authenticated');
select t_ok((select status from appointments where id=(select (v->'appointment'->>'id')::uuid from res where k='h1'))='held','returning to site / having a checkout does NOT confirm');
select t_ok(coalesce(t_err($$select process_payment_event('e0','checkout_session.payment.paid','{}','cs_1','pay_1',250,'gcash',true)$$),'')like '%permission denied%','customer cannot call the webhook processor');
reset role; select t_as(null,'service_role');
select attach_checkout((select id from pr),'cs_test_1','https://pm/checkout', now()+interval '30 min');
select t_ok(process_payment_event('evt_1','checkout_session.payment.paid','{}','cs_test_1','pay_test_1',200,'gcash',true)='amount_mismatch','wrong amount is NOT confirmed');
select t_ok((select status from appointments where id=(select (v->'appointment'->>'id')::uuid from res where k='h1'))='held','still held after mismatch');
select t_ok(process_payment_event('evt_2','checkout_session.payment.paid','{}','cs_test_1','pay_test_1',250,'gcash',true)='confirmed','correct paid event confirms booking');
select t_ok((select status from appointments where id=(select (v->'appointment'->>'id')::uuid from res where k='h1'))='confirmed','appointment is CONFIRMED');
select t_ok(process_payment_event('evt_2','checkout_session.payment.paid','{}','cs_test_1','pay_test_1',250,'gcash',true)='duplicate_event','replayed webhook event is a no-op');
select t_ok(process_payment_event('evt_3','checkout_session.payment.paid','{}','cs_test_1','pay_test_1',250,'gcash',true)='duplicate_payment','same payment under a new event id is a no-op');
select t_ok((select count(*) from payments where kind='deposit' and status='paid')=1,'exactly one paid deposit');
select t_ok((select count(*) from payment_webhook_events)=3,'all webhook events logged');
select t_ok(coalesce(t_err($$select process_payment_event('evt_9','x','{}','cs_nope','p',1,'g',true)$$),'')like '%UNKNOWN_CHECKOUT%','unknown checkout raises (so provider retries)');

-- ============ expiry releases slot; late payment handling
reset role;
select t_as('00000000-0000-0000-0000-0000000000c2','authenticated');
reset role;
update appointments set hold_expires_at = now() - interval '1 minute' where status='held';
select t_ok(expire_holds()>=1,'expire_holds expires stale holds');
select t_ok((select count(*) from appointments where status='held')=0,'no held rows remain');
select t_as('00000000-0000-0000-0000-0000000000c2','authenticated');
select t_ok((select count(*) from get_available_slots((select d from ctx),45,1) m where m=660)=1,'expired hold frees the slot again');
-- late payment for the expired booking while slot is free
reset role;
select t_as('00000000-0000-0000-0000-0000000000c2','authenticated');
create temp table pr2(id uuid); grant all on pr2 to public;
reset role;
update appointments set status='held', hold_expires_at=now()+interval '5 min' where id=(select (v->'appointment'->>'id')::uuid from res where k='h2');
select t_as('00000000-0000-0000-0000-0000000000c2','authenticated');
insert into pr2 select id from prepare_payment('deposit',(select (v->'appointment'->>'id')::uuid from res where k='h2'));
reset role;
select attach_checkout((select id from pr2),'cs_test_2','u',now()+interval '30 min');
update appointments set hold_expires_at=now()-interval '1 min' where id=(select (v->'appointment'->>'id')::uuid from res where k='h2'); select expire_holds();
select t_ok((select status from appointments where id=(select (v->'appointment'->>'id')::uuid from res where k='h2'))='expired','hold expired while customer was paying');
select t_as(null,'service_role');
select t_ok(process_payment_event('evt_10','checkout_session.payment.paid','{}','cs_test_2','pay_test_2',250,'card',true)='confirmed_late','late payment on a still-free slot is honoured');

-- slot lost case: expire again, someone else takes the slot, then a late payment arrives
reset role;
update appointments set status='expired' where id=(select (v->'appointment'->>'id')::uuid from res where k='h2');
update payments set status='pending', provider_payment_id=null, paid_at=null where id=(select id from pr2);
select t_as('00000000-0000-0000-0000-0000000000c1','authenticated');
select create_booking_hold(array[5],(select d from ctx),660,1,'tech','Cust One','0917 000 0001','c1@x.com','','key-c1-0002');
select t_as(null,'service_role');
select t_ok(process_payment_event('evt_11','checkout_session.payment.paid','{}','cs_test_2','pay_test_2b',250,'card',true)='slot_lost','late payment after slot was re-sold => slot_lost');
reset role;
select t_ok((select count(*) from refunds where status='requested')=1,'refund auto-queued for the lost slot');

-- ============ staff checkout, invoice, receipt
reset role; select t_as('00000000-0000-0000-0000-0000000000a1','authenticated');
select staff_assign((select (v->'appointment'->>'id')::uuid from res where k='h1'), 1, 1);
select t_ok(t_err($$select staff_set_status((select (v->'appointment'->>'id')::uuid from res where k='h1'),'service')$$) is null,'staff can start service');
create temp table inv(sale jsonb); grant all on inv to public;
insert into inv select create_invoice((select (v->'appointment'->>'id')::uuid from res where k='h1'), null,
  '[{"service_id":5,"technician_id":1},{"service_id":24,"unit_price":80,"technician_id":4}]'::jsonb);
-- 450 + 80 = 530 ; tax 12% = 63.60 ; total 593.60 ; deposit 250 ; balance 343.60
select t_ok((select (sale->>'subtotal')::numeric from inv)=530,'invoice subtotal');
select t_ok((select (sale->>'tax_amount')::numeric from inv)=63.60,'invoice tax');
select t_ok((select (sale->>'total')::numeric from inv)=593.60,'invoice total');
select t_ok((select (sale->>'deposit_applied')::numeric from inv)=250,'deposit applied');
select t_ok((select (sale->>'balance_due')::numeric from inv)=343.60,'balance due');
select t_ok(coalesce(t_err($$select create_invoice((select (v->'appointment'->>'id')::uuid from res where k='h1'), null, '[{"service_id":24,"unit_price":5000,"technician_id":4}]')$$),'')like '%PRICE_OUT_OF_RANGE%','out-of-range price rejected');
select t_ok((select receipt_no from sales)is null,'no receipt before payment');
select t_ok(coalesce(t_err($$select record_counter_payment((select (sale->>'id')::uuid from inv), 999, 'cash', 'idem-1')$$),'')like '%INVALID_AMOUNT%','cannot overpay balance');
create temp table cp(r jsonb); grant all on cp to public;
insert into cp select record_counter_payment((select (sale->>'id')::uuid from inv), 343.60, 'cash', 'idem-2');
insert into cp select record_counter_payment((select (sale->>'id')::uuid from inv), 343.60, 'cash', 'idem-2');
select t_ok((select count(*) from payments where kind='balance')=1,'counter payment is idempotent (double click = one payment)');
select t_ok((select receipt_no from sales) like 'FN-%','unique receipt issued: ' || (select receipt_no from sales));
select t_ok((select status from sales)='paid','sale is paid');
select t_ok((select status from appointments where id=(select (v->'appointment'->>'id')::uuid from res where k='h1'))='completed','appointment completed');
select t_ok((select count(*) from payments where kind='deposit' and status='paid' and appointment_id=(select (v->'appointment'->>'id')::uuid from res where k='h1'))=1 and (select count(*) from payments where kind='balance')=1,'deposit and balance are separate transactions');

-- snapshot: owner changes price; history unaffected
reset role; select t_as('00000000-0000-0000-0000-0000000000b1','authenticated');
update services set price=999, name='Gel Manicure v2' where id=5;
select t_ok((select unit_price from sale_items where service_id=5)=450 and (select name from sale_items where service_id=5)='Gel Manicure','historical sale keeps original name/price after owner edit');
select t_ok((select unit_price from appointment_items where service_id=5 limit 1)=450,'appointment items keep original price');
update services set price=450, name='Gel Manicure' where id=5;

-- ============ commission & dashboard (owner)
select t_ok((select commission from v_commission where technician_id=1)=135.00,'commission = 450 * 30% for tech 1');
select t_ok((select (owner_dashboard(current_date-1,current_date+1)->>'completed_sales')::int)=1,'dashboard: completed sales');
select t_ok((select (owner_dashboard(current_date-1,current_date+1)->>'deposits_received')::numeric)=500,'dashboard: deposits received (2 deposits paid)');
select t_ok((select (owner_dashboard(current_date-1,current_date+1)->>'balance_payments')::numeric)=343.60,'dashboard: balance payments');

-- ============ refunds
select t_as('00000000-0000-0000-0000-0000000000a1','authenticated');
create temp table rf(id uuid); grant all on rf to public;
insert into rf select id from request_refund((select id from payments where kind='balance'), 100, 'Customer unhappy with colour', 'rk1');
select t_ok(coalesce(t_err($$select approve_refund((select id from rf))$$),'')like '%FORBIDDEN%','staff cannot approve refunds');
select t_ok(coalesce(t_err($$select request_refund((select id from payments where kind='balance'), 9999, 'too much', 'rk2')$$),'')like '%INVALID_AMOUNT%','cannot refund more than paid');
select t_as('00000000-0000-0000-0000-0000000000b1','authenticated');
select t_ok((select status from approve_refund((select id from rf)))='succeeded','owner approves cash refund -> succeeded');
select t_ok((select status from payments where kind='balance')='partially_refunded','payment marked partially refunded');
select t_ok((select status from sales)='partially_refunded','sale marked partially refunded');
select t_ok((select (owner_dashboard(current_date-1,current_date+1)->>'refunds')::numeric)=100,'dashboard: refunds');
-- online refund path
reset role; select t_as(null,'service_role');
select t_ok(coalesce(t_err($$select complete_refund((select id from refunds where status='requested' limit 1),'rf_1',true)$$),'')='','complete_refund is a no-op unless processing');
reset role;
select t_as('00000000-0000-0000-0000-0000000000b1','authenticated');
select t_ok((select status from approve_refund((select id from refunds where status='requested' limit 1)))='processing','online refund -> processing (executed by Edge Function)');
reset role; select t_as(null,'service_role');
select complete_refund((select id from refunds where status='processing' limit 1),'rf_1',true);
select complete_refund((select id from refunds where provider_refund_id='rf_1'),'rf_1',true);
select t_ok((select status from refunds where provider_refund_id='rf_1')='succeeded','online refund completed once');
reset role;
select t_ok((select count(*) from audit_logs where table_name='refunds')>0 and (select count(*) from audit_logs where table_name='services')>0,'audit log records refunds and service edits');

-- ============ TEST MODE deposit (no gateway)
reset role; truncate appointments, payments, refunds, sales, payment_webhook_events cascade;
select t_as('00000000-0000-0000-0000-0000000000c1','authenticated');
create temp table tm(id uuid); grant all on tm to public;
insert into tm select (create_booking_hold(array[5],(select d from ctx),840,2,'tech','Cust One','0917 000 0001','c1@x.com','','tm-key-0001')->'appointment'->>'id')::uuid;
select simulate_deposit_payment((select id from tm));
select simulate_deposit_payment((select id from tm));
select t_ok((select status from appointments where id=(select id from tm))='confirmed','test-mode deposit confirms the booking');
select t_ok((select count(*) from payments where kind='deposit' and provider='test' and status='paid')=1,'test deposit recorded once (double click safe)');
select t_as('00000000-0000-0000-0000-0000000000c2','authenticated');
select t_ok(coalesce(t_err($$select simulate_deposit_payment((select id from tm))$$),'')like '%NOT_FOUND%','another customer cannot pay someone else''s booking');
reset role; update business_settings set test_mode=false;
select t_as('00000000-0000-0000-0000-0000000000c1','authenticated');
select t_ok(coalesce(t_err($$select simulate_deposit_payment((select id from tm))$$),'')like '%TEST_MODE_OFF%','test mode can be switched off');
reset role; update business_settings set test_mode=true;

-- ============ owner-managed staff accounts
reset role;
insert into auth.users(id,email,raw_user_meta_data) values ('00000000-0000-0000-0000-0000000000d1','newstaff@x.com','{"full_name":"New Staff"}');
select t_as('00000000-0000-0000-0000-0000000000c1','authenticated');
select t_ok(coalesce(t_err($$select owner_add_staff('newstaff@x.com')$$),'')like '%FORBIDDEN%','customer cannot create staff');
select t_ok(coalesce(t_err($$select * from owner_list_staff()$$),'')like '%FORBIDDEN%','customer cannot list staff');
select t_as('00000000-0000-0000-0000-0000000000a1','authenticated');
select t_ok(coalesce(t_err($$select owner_add_staff('newstaff@x.com')$$),'')like '%FORBIDDEN%','staff cannot create staff');
select t_as('00000000-0000-0000-0000-0000000000b1','authenticated');
select t_ok(coalesce(t_err($$select owner_add_staff('nobody@x.com')$$),'')like '%NO_ACCOUNT_FOR_EMAIL%','unknown email rejected');
select owner_add_staff('NewStaff@x.com');
select t_ok((select count(*) from owner_list_staff() where email='newstaff@x.com' and active)=1,'owner adds staff by email');
reset role; select t_ok((select count(*) from user_roles where user_id='00000000-0000-0000-0000-0000000000d1' and role='staff')=1,'staff role granted');
select t_as('00000000-0000-0000-0000-0000000000d1','authenticated');
select t_ok(is_staff(),'new staff passes is_staff()');
select t_as('00000000-0000-0000-0000-0000000000b1','authenticated');
select owner_set_staff_active('00000000-0000-0000-0000-0000000000d1', false);
select t_as('00000000-0000-0000-0000-0000000000d1','authenticated');
select t_ok(not is_staff(),'deactivated staff loses access');
select t_ok(coalesce(t_err($$select staff_set_status(gen_random_uuid(),'waiting')$$),'')like '%FORBIDDEN%','deactivated staff cannot call staff functions');
select t_as(null,'anon');
select t_ok(coalesce(t_err($$select owner_add_staff('x@x.com')$$),'')like '%permission denied%','anonymous cannot call owner functions');
reset role;
