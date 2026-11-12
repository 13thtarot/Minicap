import { sb } from "./client.js";
import { FUNCTIONS_URL, SUPABASE_ANON_KEY } from "./config.js";

/** Calls the create-checkout Edge Function with the user's JWT. The amount is decided server-side. */
export async function startCheckout(kind, refId) {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) throw new Error("Please log in first.");
  const res = await fetch(FUNCTIONS_URL + "/create-checkout", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: "Bearer " + session.access_token, apikey: SUPABASE_ANON_KEY },
    body: JSON.stringify({ kind, ref_id: refId }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.error === "HOLD_EXPIRED" || /HOLD_EXPIRED/.test(body.error || "")
    ? "Your reserved slot expired. Please book again." : "Could not start payment. Please try again.");
  return body; // { checkout_url, payment_id }
}

export const payBalanceOnline = async (saleId) => { location.href = (await startCheckout("balance", saleId)).checkout_url; };
