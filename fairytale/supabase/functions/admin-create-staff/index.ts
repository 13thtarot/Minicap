// Owner-only account administration. Uses the service role INSIDE the function; the key never reaches the browser.
// POST { action: 'create', email, password, full_name, technician_id? }
//      { action: 'set_active', user_id, active }
//      { action: 'reset_password', user_id, password }
import { cors, json, serviceClient, userClient } from "../_shared/common.ts";

Deno.serve(async (req) => {
  const h = cors(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  try {
    const uc = userClient(req);
    const { data: isOwner } = await uc.rpc("is_owner");
    if (isOwner !== true) return json({ error: "FORBIDDEN" }, 403, h);

    const b = await req.json();
    const admin = serviceClient();

    if (b.action === "create") {
      if (!/^\S+@\S+\.\S+$/.test(b.email ?? "") || (b.password ?? "").length < 10) return json({ error: "INVALID_INPUT" }, 400, h);
      const { data, error } = await admin.auth.admin.createUser({
        email: b.email, password: b.password, email_confirm: true, user_metadata: { full_name: b.full_name ?? "" },
      });
      if (error) return json({ error: error.message }, 400, h);
      const id = data.user.id;
      await admin.from("user_roles").delete().eq("user_id", id).eq("role", "customer");
      await admin.from("user_roles").insert({ user_id: id, role: "staff" });
      if (b.technician_id) await admin.from("technicians").update({ user_id: id }).eq("id", b.technician_id);
      return json({ user_id: id }, 200, h);
    }
    if (b.action === "set_active") {
      const { error } = await admin.auth.admin.updateUserById(b.user_id, { ban_duration: b.active ? "none" : "876000h" });
      if (error) return json({ error: error.message }, 400, h);
      return json({ ok: true }, 200, h);
    }
    if (b.action === "reset_password") {
      if ((b.password ?? "").length < 10) return json({ error: "WEAK_PASSWORD" }, 400, h);
      const { error } = await admin.auth.admin.updateUserById(b.user_id, { password: b.password });
      if (error) return json({ error: error.message }, 400, h);
      return json({ ok: true }, 200, h);
    }
    return json({ error: "UNKNOWN_ACTION" }, 400, h);
  } catch (e) {
    console.error("admin-create-staff", e);
    return json({ error: "FAILED" }, 500, h);
  }
});
