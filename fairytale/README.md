# Fairytale Nails Salon — Supabase backend (Phases 1–5) + shared JS modules

Status: database, security, booking engine, PayMongo integration, staff/owner operations and the
shared frontend modules are built and tested. **The three HTML portals are not yet rewired** (Phase 6, below).

## Layout
```
supabase/migrations/   001 schema · 002 RLS/Storage/Realtime · 003 booking engine · 004 payments/sales/refunds/reports · 005 seed + hardening
supabase/functions/    create-checkout · paymongo-webhook · process-refund · admin-create-staff (+ _shared)
supabase/tests/        behaviour.sql (78 assertions) · race.sh (parallel double-booking test)
web/js/                config · client · auth · catalog · booking · payments · realtime · staff · owner  (ES modules, no secrets)
```

## Deploy
1. Create a Supabase project. Enable extensions **pg_cron** (Database → Extensions) *before* running migration 003
   (otherwise run the `cron.schedule(...)` line printed by that migration afterwards).
2. `supabase link --project-ref <ref>` then `supabase db push` (runs the 5 migrations in order).
3. Create the owner user in Dashboard → Authentication, then run the bootstrap SQL at the bottom of migration 005.
4. Secrets (server-side only):
   ```
   supabase secrets set PAYMONGO_SECRET_KEY=sk_test_... PAYMONGO_WEBHOOK_SECRET=whsk_... \
       SITE_URL=https://your-site.example ALLOWED_ORIGINS=https://your-site.example
   supabase functions deploy create-checkout paymongo-webhook process-refund admin-create-staff
   ```
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are injected automatically.
5. Register the webhook in PayMongo (Dashboard → Developers → Webhooks):
   URL `https://<ref>.functions.supabase.co/paymongo-webhook`, event **`checkout_session.payment.paid`**.
   Copy its signing secret into `PAYMONGO_WEBHOOK_SECRET`. Confirm GCash/Maya/etc. are activated on your PayMongo account.
6. Put the project URL and **anon** key in `web/js/config.js` (the only keys that may appear in the browser).
7. Auth settings: enable email confirmations as you prefer; set Site URL / redirect URLs to your domain.

## How the guarantees are enforced
| Requirement | Mechanism |
|---|---|
| No double booking | `create_booking_hold` takes a per-day advisory lock and re-validates inside the transaction; GiST **exclusion constraints** on (technician, time) and (station, time) are the final backstop; salon capacity = min(working techs, active stations) |
| Temporary hold | booking row is `held` with `hold_expires_at`; extended once at checkout creation; `expire_holds()` runs every minute (pg_cron) and on every availability/payment call |
| Payment is only real via webhook | only `process_payment_event()` (service role) sets `paid`; the Edge Function verifies the HMAC signature **and** re-fetches the checkout from PayMongo's API; return URL changes nothing (`waitForConfirmation` watches the DB) |
| Duplicate submissions / repeated webhooks | idempotency keys on bookings and payments; unique `provider_event_id`; paid payments are no-ops on replay; one pending checkout per booking |
| Wrong amount | `amount_mismatch` → never confirmed |
| Paid after hold expired | re-confirmed if the slot is still free, otherwise a full refund is queued automatically for owner approval |
| Preserved history | `appointment_items` / `sale_items` snapshot name, price, duration, technician, commission rate |
| Receipts | unique `FN-YYYYMMDD-#####` assigned only when the balance reaches zero; deposits and balances are separate `payments` rows |
| Refunds | staff request → owner approves → cash refunds finish instantly, online ones execute at PayMongo via `process-refund`; payment/sale/appointment statuses update |
| Access control | RLS on every table; all writes to appointments/money go through role-checked SECURITY DEFINER functions; customers see only their rows; owner-only config, audit log and dashboard |
| Secrets | service-role key, PayMongo secret and webhook secret exist only as Edge Function secrets |

## Tests
```
createdb scratch && psql scratch -f <your supabase stubs or run on a Supabase branch DB>
psql scratch -f supabase/migrations/*.sql   # in order
psql scratch -f supabase/tests/behaviour.sql   # expect every line PASS
bash supabase/tests/race.sh scratch 12         # expect: same_tech => exactly 1 success; any_tech => capacity successes
```
Last run: 78/78 assertions pass; 12 parallel sessions on one technician/slot → exactly 1 booking; 12 on "any tech"
with capacity 6 → exactly 6. Not covered locally (needs a live project): Supabase Auth, Storage, Realtime delivery,
the Edge Functions against PayMongo's sandbox. Test those in PayMongo **test mode** before going live.

## Behaviour changes vs. the current demo (deliberate)
- Deposit is paid through PayMongo checkout; the screenshot-upload + "Verify deposit / Reject" staff step is replaced by automatic confirmation.
- Starting a service requires an assigned technician.
- Refunds need owner approval; staff can only void **unpaid** invoices.
- Customers must register to book (guest booking removed, since holds/payments are tied to an account).
- Tax stays 12% added on top of the subtotal, like your current billing screen (configurable in business_settings.tax_rate).

## Phase 6 — wiring the HTML portals (next)
Replace each portal's `seed()/DB/localStorage/save()` block with the modules in `web/js`, keeping all markup/CSS:
`loadCatalog()` already returns data in your existing `SV / TE / hours / openDays / off` shapes; `free()` becomes
`getSlots()`; `submitB()` becomes `createHold()` → `uploadReference()` → `payDeposit()`; staff `verify/reject` are removed,
`pay()` becomes `createInvoice()` + `recordCounterPayment()`; realtime subscriptions re-render on change.
