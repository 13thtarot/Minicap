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
