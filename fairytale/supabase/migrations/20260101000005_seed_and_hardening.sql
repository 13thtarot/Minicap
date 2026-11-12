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
