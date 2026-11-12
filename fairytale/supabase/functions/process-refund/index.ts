// Owner-only. POST { refund_id } for a refund the owner already approved (status 'processing').
// Executes the refund at PayMongo, then records the result through complete_refund().
import { cors, json, pm, serviceClient, userClient } from "../_shared/common.ts";

Deno.serve(async (req) => {
  const h = cors(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  try {
    const { data: isOwner } = await userClient(req).rpc("is_owner");
    if (isOwner !== true) return json({ error: "FORBIDDEN" }, 403, h);
    const { refund_id } = await req.json();

    const db = serviceClient();
    const { data: r } = await db.from("refunds").select("*, payments(provider_payment_id, provider)").eq("id", refund_id).single();
    if (!r || r.status !== "processing") return json({ error: "NOT_PROCESSING" }, 409, h);
    if (r.payments?.provider !== "paymongo" || !r.payments.provider_payment_id) return json({ error: "NOT_ONLINE_PAYMENT" }, 409, h);

    try {
      const res = await pm("/refunds", {
        method: "POST",
        body: JSON.stringify({ data: { attributes: {
          amount: Math.round(Number(r.amount) * 100),
          payment_id: r.payments.provider_payment_id,
          reason: "others",
          notes: String(r.reason).slice(0, 200),
        } } }),
      });
      await db.rpc("complete_refund", { p_refund: r.id, p_provider_refund_id: res.data.id, p_ok: true });
      return json({ ok: true, provider_refund_id: res.data.id }, 200, h);
    } catch (e) {
      console.error("refund failed", e);
      await db.rpc("complete_refund", { p_refund: r.id, p_provider_refund_id: null, p_ok: false });
      return json({ error: "PROVIDER_REFUND_FAILED" }, 502, h);
    }
  } catch (e) {
    console.error("process-refund", e);
    return json({ error: "FAILED" }, 500, h);
  }
});
