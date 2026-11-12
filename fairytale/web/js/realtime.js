import { sb } from "./client.js";

/** Subscribe to one or more tables; RLS decides which rows this user may receive. Returns an unsubscribe fn. */
export function watch(name, tables, onChange, filter = {}) {
  const ch = sb.channel(name);
  const debounced = debounce(onChange, 250);                        // bursts => one refresh
  tables.forEach((table) =>
    ch.on("postgres_changes", { event: "*", schema: "public", table, ...(filter[table] ? { filter: filter[table] } : {}) },
      (payload) => debounced(table, payload)));
  ch.subscribe();
  return () => sb.removeChannel(ch);
}

export const watchStaffBoard = (cb) => watch("staff-board", ["appointments", "payments", "walkin_queue", "sales"], cb);
export const watchOwnerBoard = (cb) => watch("owner-board", ["appointments", "payments", "sales", "refunds"], cb);
export const watchMyBookings = (uid, cb) =>
  watch("my-" + uid, ["appointments", "payments", "notifications", "sales"], cb,
        { appointments: `customer_id=eq.${uid}`, notifications: `user_id=eq.${uid}` });

function debounce(fn, ms) { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; }
