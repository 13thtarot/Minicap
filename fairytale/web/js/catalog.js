// Loads salon data and maps it to the SAME shapes the current portals already use (SV, TE, hours...),
// so existing render code keeps working with minimal edits.
import { sb, must } from "./client.js";

export async function loadCatalog() {
  const [settings, cats, svcs, techs, off, stations] = await Promise.all([
    sb.from("business_settings").select("*").single().then(must),
    sb.from("service_categories").select("*").order("sort_order").then(must),
    sb.from("services").select("*").order("sort_order").then(must),
    sb.from("technicians").select("*").order("id").then(must),
    sb.from("days_off").select("*").then(must),
    sb.from("stations").select("*").order("id").then((r) => (r.error ? { data: [] } : r)).then((r) => r.data),
  ]);
  const catName = Object.fromEntries(cats.map((c) => [c.id, c.name]));
  return {
    raw: { settings, cats, svcs, techs, off, stations },
    GR: cats.map((c) => c.name),
    GN: Object.fromEntries(cats.filter((c) => c.note).map((c) => [c.name, c.note])),
    SV: svcs.map((s) => ({
      id: s.id, n: s.name, g: catName[s.category_id], p: +s.price, px: +(s.price_max || 0),
      d: s.duration_min, dx: s.duration_max || 0, x: s.detail || "", on: s.active,
    })),
    TE: techs.filter((t) => t.active).map((t) => ({ id: t.id, n: t.name, sp: t.specialty, off: t.day_off, rate: +t.commission_rate })),
    hours: { o: settings.open_min, c: settings.close_min, ls: settings.lunch_start_min, le: settings.lunch_end_min },
    openDays: settings.open_days,
    off: off.map((d) => d.day),
    depositAmount: +settings.deposit_amount,
    taxRate: +settings.tax_rate,
    holdMinutes: settings.hold_minutes,
    testMode: !!settings.test_mode,
  };
}
