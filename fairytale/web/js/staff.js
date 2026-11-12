import { sb, must, newKey } from "./client.js";

const APPT = "*, appointment_items(*), payments(id,kind,status,amount,method,provider,paid_at), sales(*, sale_items(*)), appointment_references(storage_path)";

/** All appointments for one calendar day (Asia/Manila). */
export async function appointmentsForDay(isoDate) {
  const from = new Date(isoDate + "T00:00:00+08:00").toISOString();
  const to = new Date(new Date(isoDate + "T00:00:00+08:00").getTime() + 864e5).toISOString();
  return must(await sb.from("appointments").select(APPT).gte("start_at", from).lt("start_at", to).order("start_at"));
}
export const appointmentHistory = async (id) =>
  must(await sb.from("appointment_history").select("*").eq("appointment_id", id).order("created_at"));
export const walkinQueue = async () =>
  must(await sb.from("walkin_queue").select("*").eq("status", "waiting").order("created_at"));
export const customers = async (q = "") =>
  must(await sb.from("profiles").select("*").or(`full_name.ilike.%${q}%,email.ilike.%${q}%,phone.ilike.%${q}%`).limit(100));
export const customerAppointments = async (customerId) =>
  must(await sb.from("appointments").select("*, appointment_items(name)").eq("customer_id", customerId).order("start_at", { ascending: false }));

export const setStatus = (id, status) => sb.rpc("staff_set_status", { p_appt: id, p_status: status }).then(must);
export const assign = (id, techId, stationId) => sb.rpc("staff_assign", { p_appt: id, p_tech: techId || null, p_station: stationId || null }).then(must);

export const addWalkin = (name, serviceId) => sb.rpc("walkin_add", { p_name: name, p_service: serviceId }).then(must);
export const checkinWalkin = (queueId) => sb.rpc("walkin_checkin", { p_queue: queueId }).then(must);
export const removeWalkin = (queueId) => sb.rpc("walkin_remove", { p_queue: queueId }).then(must);

/** lines: [{ service_id, unit_price?, technician_id }]; appointmentId null => manual walk-in sale. */
export const createInvoice = (appointmentId, walkinName, lines) =>
  sb.rpc("create_invoice", { p_appt: appointmentId || null, p_walkin_name: walkinName || null, p_lines: lines }).then(must);

let payKey = null;                                     // reuse the same key across retries of one click-flow
export const newPaymentAttempt = () => (payKey = newKey());
export const recordCounterPayment = (saleId, amount, method) =>
  sb.rpc("record_counter_payment", { p_sale: saleId, p_amount: amount, p_method: method, p_idem: (payKey ||= newKey()) })
    .then(must).finally(() => { /* key cleared by caller via newPaymentAttempt() after success */ });

export const voidOpenSale = (saleId, reason) => sb.rpc("void_open_sale", { p_sale: saleId, p_reason: reason }).then(must);
export const requestRefund = (paymentId, amount, reason) =>
  sb.rpc("request_refund", { p_payment: paymentId, p_amount: amount, p_reason: reason, p_idem: newKey() }).then(must);

export const receipt = async (saleId) =>
  must(await sb.from("sales").select("*, sale_items(*), appointments(code, start_at)").eq("id", saleId).single());
export const todaysSales = async (isoDate) => {
  const from = new Date(isoDate + "T00:00:00+08:00").toISOString();
  return must(await sb.from("sales").select("*, sale_items(*)").gte("created_at", from).order("created_at", { ascending: false }));
};
