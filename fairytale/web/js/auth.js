import { sb, must } from "./client.js";

export async function signUp({ email, password, username, phone, fullName = "" }) {
  const { data, error } = await sb.auth.signUp({
    email, password,
    options: { data: { username, phone, full_name: fullName } },
  });
  if (error) throw new Error(error.message);
  return data;            // { user, session } (session is null when email confirmation is required)
}

/** Accepts email OR username, like the existing portals. */
export async function signIn(identifier, password) {
  let email = identifier.trim();
  if (!email.includes("@")) {
    const { data } = await sb.rpc("email_for_username", { p_username: email });
    email = data || "";
  }
  if (!email) throw new Error("No account uses that username. Try your email address instead.");
  const { data, error } = await sb.auth.signInWithPassword({ email, password });
  if (error) {
    const m = (error.message || "").toLowerCase();
    if (m.includes("not confirmed")) throw new Error("This email is not confirmed yet. In Supabase, turn off Confirm email (Authentication > Providers > Email) or tick Auto Confirm User, then try again.");
    if (m.includes("invalid login")) throw new Error("Wrong email/username or password. (If you created this account in the Supabase dashboard, log in with the email, not a username.)");
    throw new Error(error.message);
  }
  return data.user;
}

export const signOut = () => sb.auth.signOut();
export const currentUser = async () => (await sb.auth.getSession()).data.session?.user ?? null;

export async function myRoles() {
  const u = await currentUser();
  if (!u) return [];
  return must(await sb.from("user_roles").select("role").eq("user_id", u.id)).map((r) => r.role);
}

/**
 * Portal gate. customer.html -> 'customer', staff.html -> 'staff' (owners may also enter), owner.html -> 'owner'.
 * Roles are enforced again by RLS and by every RPC; this only decides which screen to show.
 */
export async function requirePortalRole(portal) {
  const roles = await myRoles();
  const ok = portal === "customer" ? roles.includes("customer")
           : portal === "staff"    ? roles.includes("staff") || roles.includes("owner")
           : roles.includes("owner");
  if (!ok) { await signOut(); return null; }
  return currentUser();
}

export async function myProfile() {
  const u = await currentUser();
  return u ? must(await sb.from("profiles").select("*").eq("id", u.id).single()) : null;
}
export async function saveProfile(patch) {
  const u = await currentUser();
  return must(await sb.from("profiles").update(patch).eq("id", u.id).select().single());
}
