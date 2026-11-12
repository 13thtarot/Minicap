// POST { kind: 'deposit' | 'balance', ref_id: <appointment id | sale id> }
// Creates (or safely reuses) a PayMongo hosted checkout and returns its URL.
// Amounts come from the database, never from the browser.
import { cors, json, pm, userClient, serviceClient } from "../_shared/common.ts";

Deno.serve(async (req) => {
  const h = cors(req.headers.get("origin"));
  if (req.method === "OPTIONS") return new Response("ok", { headers: h });
  if (req.method !== "POST") return json({ error: "METHOD_NOT_ALLOWED" }, 405, h);

  try {
    const uc = userClient(req);
    const { data: u } = await uc.auth.getUser();
    if (!u?.user) return json({ error: "AUTH_REQUIRED" }, 401, h);

    const { kind, ref_id } = await req.json();
    if (!["deposit", "balance"].includes(kind) || !ref_id) return json({ error: "BAD_REQUEST" }, 400, h);

    // DB validates ownership, status, hold expiry, amount; returns an existing pending checkout when one is still live
    const { data: pay, error } = await uc.rpc("prepare_payment", { p_kind: kind, p_ref: ref_id });
    if (error) return json({ error: error.message }, 409, h);
    if (pay.checkout_url) return json({ checkout_url: pay.checkout_url, payment_id: pay.id, reused: true }, 200, h);

    const site = Deno.env.get("SITE_URL")!; // e.g. https://fairytale-nails.example.com
    const methods = (Deno.env.get("PAYMONGO_METHODS") ?? "gcash,paymaya,card,grab_pay").split(",");
    const label = kind === "deposit" ? "Fairytale Nails reservation deposit" : "Fairytale Nails service balance";

    const session = await pm("/checkout_sessions", {
      method: "POST",
      body: JSON.stringify({
        data: {
          attributes: {
            line_items: [{ currency: "PHP", amount: Math.round(Number(pay.amount) * 100), name: label, quantity: 1 }],
            payment_method_types: methods,
            description: label,
            reference_number: pay.id,
            send_email_receipt: true,
            show_description: true,
            show_line_items: true,
            success_url: `${site}/customer.html?checkout=return&payment=${pay.id}`,
            cancel_url: `${site}/customer.html?checkout=cancelled&payment=${pay.id}`,
            metadata: { payment_id: pay.id, kind, ref_id },
          },
        },
      }),
    });

    const checkoutId = session.data.id as string;
    const url = session.data.attributes.checkout_url as string;
    // our own conservative expiry; a late-but-real payment is still honoured by the webhook logic
    const expires = new Date(Date.now() + 30 * 60_000).toISOString();
    const { error: e2 } = await serviceClient().rpc("attach_checkout", {
      p_payment: pay.id, p_checkout_id: checkoutId, p_url: url, p_expires: expires,
    });
    if (e2) throw e2;
    return json({ checkout_url: url, payment_id: pay.id, reused: false }, 200, h);
  } catch (e) {
    console.error("create-checkout", e);
    return json({ error: "CHECKOUT_FAILED" }, 500, h);
  }
});
