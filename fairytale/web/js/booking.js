import { sb, must, newKey } from "./client.js";
import { currentUser } from "./auth.js";
import { startCheckout } from "./payments.js";

/** Free start-minutes for a day. The SERVER computes this (hours, lunch, days off, tech days off, capacity, holds). */
export async function getSlots(date, durationMin, techId = null) {
  const { data, error } = await sb.rpc("get_available_slots", { p_date: date, p_duration: durationMin, p_tech: techId || null });
  if (error) throw error;
  return data || [];
}

// One idempotency key per DISTINCT booking request: retries/double-clicks of the same request replay the same
// appointment, but choosing a different slot/service/technician always gets a fresh key.
let attempt = { fp: null, key: null };
export const resetAttempt = () => (attempt = { fp: null, key: null });

/** Step 1: reserve the slot (status 'held') while payment is pending. */
export async function createHold({ serviceIds, date, startMin, techId, method, name, phone, email, notes }) {
  const fp = JSON.stringify([[...serviceIds].sort(), date, startMin, techId || 0, method, name, phone, email, notes || ""]);
  if (attempt.fp !== fp) attempt = { fp, key: newKey() };
  const out = must(await sb.rpc("create_booking_hold", {
    p_service_ids: serviceIds, p_date: date, p_start_min: startMin, p_tech: techId || null,
    p_method: method, p_name: name, p_phone: phone, p_email: email, p_notes: notes || "", p_idem: attempt.key,
  }));
  return out.appointment;
}

/** Optional nail reference image -> private bucket, path starts with the user's id (enforced by Storage RLS). */
export async function uploadReference(file, appointmentId) {
  if (!file) return null;
  if (!/^image\//.test(file.type) || file.size > 5 * 1024 * 1024) throw new Error("Use an image under 5 MB.");
  const u = await currentUser();
  const ext = (file.name.split(".").pop() || "jpg").toLowerCase().replace(/[^a-z0-9]/g, "");
  const path = `${u.id}/${appointmentId}/${crypto.randomUUID()}.${ext}`;
  const up = await sb.storage.from("nail-references").upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) throw up.error;
  must(await sb.from("appointment_references").insert({ appointment_id: appointmentId, owner_id: u.id, storage_path: path }));
  return path;
}

export async function referenceUrl(path, seconds = 300) {
  const { data, error } = await sb.storage.from("nail-references").createSignedUrl(path, seconds);
  if (error) throw error;
  return data.signedUrl;
}

/** Step 2: go to PayMongo. Confirmation arrives ONLY via the webhook; the return URL proves nothing. */
export async function payDeposit(appointmentId) {
  const { checkout_url } = await startCheckout("deposit", appointmentId);
  location.href = checkout_url;
}

export async function myAppointments() {
  return must(await sb.from("appointments")
    .select("*, appointment_items(*), payments(id,kind,status,amount,method,paid_at), sales(id,receipt_no,total,balance_due,status,paid_at)")
    .order("start_at", { ascending: false }));
}

export const cancelMyBooking = async (id) => must(await sb.rpc("cancel_my_booking", { p_appt: id }));

/** After returning from checkout: wait for the DATABASE (webhook-driven) to say 'confirmed'. */
export function waitForConfirmation(appointmentId, onChange, timeoutMs = 120000) {
  let done = false;
  const check = async () => {
    const { data } = await sb.from("appointments").select("status,hold_expires_at").eq("id", appointmentId).single();
    if (data && data.status !== "held") { finish(data.status); }
  };
  const ch = sb.channel("confirm-" + appointmentId)
    .on("postgres_changes", { event: "UPDATE", schema: "public", table: "appointments", filter: `id=eq.${appointmentId}` },
        (p) => { if (p.new.status !== "held") finish(p.new.status); })
    .subscribe();
  const poll = setInterval(check, 4000);       // fallback if the websocket is blocked
  const t = setTimeout(() => finish("timeout"), timeoutMs);
  function finish(s) { if (done) return; done = true; clearInterval(poll); clearTimeout(t); sb.removeChannel(ch); onChange(s); }
  check();
  return () => finish("cancelled");
}

/** TEST MODE (no gateway): records the deposit in the database and confirms the booking. */
export async function payDepositTest(appointmentId) {
  return must(await sb.rpc("simulate_deposit_payment", { p_appt: appointmentId, p_method: "test_gcash" }));
}
