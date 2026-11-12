// Shared helpers for Edge Functions. Secrets are read ONLY from Deno.env (set with `supabase secrets set`).
import { createClient, SupabaseClient } from "jsr:@supabase/supabase-js@2";

export const PM_API = "https://api.paymongo.com/v1";

export function cors(origin: string | null) {
  const allowed = (Deno.env.get("ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const ok = origin && (allowed.length === 0 || allowed.includes(origin));
  return {
    "Access-Control-Allow-Origin": ok ? origin! : (allowed[0] ?? ""),
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

export const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...extra } });

export const serviceClient = (): SupabaseClient =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

/** Client that acts AS the calling user (RLS + auth.uid() apply). */
export const userClient = (req: Request): SupabaseClient =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    auth: { persistSession: false },
  });

export const pmAuth = () => "Basic " + btoa(Deno.env.get("PAYMONGO_SECRET_KEY")! + ":");

export async function pm(path: string, init: RequestInit = {}) {
  const res = await fetch(PM_API + path, {
    ...init,
    headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: pmAuth(), ...(init.headers ?? {}) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error("PayMongo " + res.status + ": " + JSON.stringify(body?.errors ?? body));
  return body;
}
