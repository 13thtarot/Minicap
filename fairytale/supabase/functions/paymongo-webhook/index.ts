// PayMongo -> this function. The ONLY code path that can mark a payment as paid.
//  1. verify Paymongo-Signature (HMAC-SHA256 of `${t}.${rawBody}` with the webhook secret)
//  2. re-fetch the checkout session from PayMongo's API (never trust the body alone)
//  3. hand off to process_payment_event(): idempotent, row-locked, amount-checked
import { json, pm, serviceClient } from "../_shared/common.ts";

const enc = new TextEncoder();

async function hmacHex(secret: string, msg: string) {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", key, enc.encode(msg)));
  return Array.from(sig).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string) {
  if (!a || !b || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

async function verify(raw: string, header: string | null, secret: string) {
  if (!header) return false;
  const parts: Record<string, string> = {};
  for (const p of header.split(",")) { const i = p.indexOf("="); if (i > 0) parts[p.slice(0, i).trim()] = p.slice(i + 1).trim(); }
  if (!parts.t) return false;
  // Replay protection comes from event-id idempotency + API re-verification below, so we do not
  // reject on timestamp age (PayMongo retries could otherwise be dropped).
  const expected = await hmacHex(secret, `${parts.t}.${raw}`);
  return safeEqual(expected, parts.te ?? "") || safeEqual(expected, parts.li ?? "");
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405);
  const raw = await req.text();

  const secret = Deno.env.get("PAYMONGO_WEBHOOK_SECRET")!;
  if (!(await verify(raw, req.headers.get("paymongo-signature"), secret))) {
    console.warn("webhook: bad signature");
    return json({ error: "INVALID_SIGNATURE" }, 400);
  }

  let evt: any;
  try { evt = JSON.parse(raw).data; } catch { return json({ error: "BAD_JSON" }, 400); }
  const eventId: string = evt?.id;
  const type: string = evt?.attributes?.type;
  const livemode: boolean = !!evt?.attributes?.livemode;
  if (!eventId || !type) return json({ error: "BAD_EVENT" }, 400);

  // a live secret key must never act on test events (and vice versa is harmless)
  if ((Deno.env.get("PAYMONGO_SECRET_KEY") ?? "").startsWith("sk_live") && !livemode) {
    return json({ ok: true, ignored: "test_event_on_live" });
  }

  const db = serviceClient();
  try {
    if (type !== "checkout_session.payment.paid") {
      // record for audit, take no financial action
      await db.rpc("process_payment_event", {
        p_event_id: eventId, p_type: type, p_payload: JSON.parse(raw),
        p_checkout_id: null, p_provider_payment_id: null, p_amount: null, p_method: null, p_paid: false,
      });
      return json({ ok: true, ignored: type });
    }

    const checkoutId: string = evt.attributes.data.id;
    // Independent confirmation straight from PayMongo
    const cs = await pm(`/checkout_sessions/${checkoutId}`);
    const paid = (cs.data.attributes.payments ?? []).find((p: any) => p?.attributes?.status === "paid");
    if (!paid) {
      console.warn("webhook: API shows no paid payment for", checkoutId);
      return json({ error: "NOT_CONFIRMED_BY_API" }, 500); // non-2xx => PayMongo retries
    }

    const { data, error } = await db.rpc("process_payment_event", {
      p_event_id: eventId,
      p_type: type,
      p_payload: JSON.parse(raw),
      p_checkout_id: checkoutId,
      p_provider_payment_id: paid.id,
      p_amount: Number(paid.attributes.amount) / 100,
      p_method: paid.attributes.source?.type ?? cs.data.attributes.payment_method_used ?? "paymongo",
      p_paid: true,
    });
    if (error) throw error;
    return json({ ok: true, outcome: data });
  } catch (e) {
    console.error("webhook processing failed", e);
    return json({ error: "PROCESSING_FAILED" }, 500); // PayMongo will retry; processing is idempotent
  }
});
