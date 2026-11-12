/*
 * Fairytale loading screen (classic script, no imports; load it BEFORE the module scripts).
 *
 * Idea: every call that talks to the database goes through Loader.wrap(FN). While ANY call is in flight a
 * full-screen loading screen blocks the page, and it only goes away after the code that awaited the data has
 * had time to render it. So the user never sees half-loaded or stale screens, and can't double-click while
 * something is processing.
 *
 *   window.FN = Loader.wrap({ ...api });   // every async function in the object is tracked automatically
 *   FN.raw.someCall()                      // same call WITHOUT a loading screen (silent background refresh)
 *   Loader.run("Saving…", async () => {})  // for non-FN work you also want covered
 *   Loader.endInitial()                    // call once, after the first render, to drop the start-up screen
 */
(function () {
  "use strict";

  // ---- tuning ---------------------------------------------------------------------------------------------
  var MIN_VISIBLE_MS = 320;   // once shown, stay at least this long (prevents a one-frame flash on fast calls)
  var HIDE_GRACE_MS = 140;    // wait after the last call settles so the caller can render before we reveal
  var FADE_MS = 220;
  var STICKY_MS = 8000;       // after a redirecting call (payment checkout) keep the screen up while the browser navigates

  // Friendly text per call; anything not listed shows DEFAULT_LABEL.
  var DEFAULT_LABEL = "Just a moment…";
  var LABELS = {
    loadCatalog: "Gathering services & prices…",
    getSlots: "Checking available times…",
    createHold: "Reserving your slot…",
    uploadReference: "Uploading your reference photo…",
    payDeposit: "Taking you to secure payment…",
    payDepositTest: "Confirming your deposit…",
    payBalanceOnline: "Taking you to secure payment…",
    myAppointments: "Loading your appointments…",
    cancelMyBooking: "Cancelling your appointment…",
    signIn: "Signing you in…",
    signUp: "Creating your account…",
    signOut: "Signing you out…",
    myProfile: "Loading your profile…",
    saveProfile: "Saving your details…",
    requirePortalRole: "Checking your access…",
    ownerAppointments: "Loading appointments…",
    profileNames: "Loading appointments…",
    dashboard: "Crunching the numbers…",
    exportAll: "Preparing your backup…",
    approveRefund: "Processing refund…",
    requestRefund: "Processing refund…",
    pendingRefunds: "Loading refunds…",
    listStaff: "Loading your team…",
    addStaffByEmail: "Adding team member…",
    appointmentHistory: "Loading history…",
    allPayments: "Loading payments…",
    auditLog: "Loading activity log…"
  };
  // Calls that end in a full-page redirect: keep the screen up instead of flashing the old page.
  var STICKY = { payDeposit: 1, payBalanceOnline: 1 };

  // ---- DOM ------------------------------------------------------------------------------------------------
  var CSS =
    "#fn-loader{position:fixed;inset:0;z-index:9999;display:grid;place-items:center;padding:1.5rem;" +
    "background:color-mix(in srgb,var(--bg,#faf8f3) 88%,transparent);" +
    "-webkit-backdrop-filter:blur(6px);backdrop-filter:blur(6px);" +
    "opacity:0;visibility:hidden;pointer-events:none;transition:opacity " + FADE_MS + "ms ease,visibility 0s linear " + FADE_MS + "ms;" +
    "font-family:Poppins,system-ui,sans-serif;color:var(--ink,#2e3328)}" +
    "#fn-loader.on{opacity:1;visibility:visible;pointer-events:auto;transition:opacity " + FADE_MS + "ms ease,visibility 0s}" +
    "#fn-loader .fn-box{display:flex;flex-direction:column;align-items:center;gap:1rem;text-align:center;max-width:280px}" +
    "#fn-loader .fn-orb{position:relative;width:88px;height:88px;display:grid;place-items:center}" +
    "#fn-loader .fn-ring{position:absolute;inset:0;border-radius:50%;border:2px solid var(--line,#e8e4d8);" +
    "border-top-color:var(--red,#c43d36);border-right-color:var(--deep,#4e6240);animation:fn-spin 1.1s linear infinite}" +
    "#fn-loader .fn-lg{width:58px;height:58px;border-radius:50%;background:var(--pink,#fbe6e6);display:grid;place-items:center;" +
    "font:italic 2rem 'DM Serif Display',serif;color:var(--red,#c43d36);animation:fn-pulse 1.8s ease-in-out infinite}" +
    "#fn-loader .fn-sp{position:absolute;width:7px;height:7px;border-radius:50%;background:var(--head,#7a6a48);opacity:.0;animation:fn-twinkle 1.8s ease-in-out infinite}" +
    "#fn-loader .fn-sp:nth-child(3){top:2px;right:6px}" +
    "#fn-loader .fn-sp:nth-child(4){bottom:6px;left:0;animation-delay:.6s;background:var(--deep,#4e6240)}" +
    "#fn-loader .fn-sp:nth-child(5){bottom:0;right:14px;animation-delay:1.2s;background:var(--red,#c43d36)}" +
    "#fn-loader .fn-name{font:italic 1.25rem 'DM Serif Display',serif;color:var(--head,#7a6a48);line-height:1}" +
    "#fn-loader .fn-msg{font-size:.85rem;color:var(--mute,#6f7466);min-height:1.3em}" +
    "@keyframes fn-spin{to{transform:rotate(360deg)}}" +
    "@keyframes fn-pulse{0%,100%{transform:scale(1)}50%{transform:scale(1.07)}}" +
    "@keyframes fn-twinkle{0%,100%{opacity:0;transform:scale(.4)}50%{opacity:.9;transform:scale(1)}}" +
    "@media print{#fn-loader{display:none!important}}" +
    "@media (prefers-reduced-motion:reduce){#fn-loader .fn-ring{animation-duration:2.6s}#fn-loader .fn-lg,#fn-loader .fn-sp{animation:none}#fn-loader .fn-sp{opacity:.5}}";

  var style = document.createElement("style");
  style.textContent = CSS;
  document.head.appendChild(style);

  var el = document.createElement("div");
  el.id = "fn-loader";
  el.className = "on";                               // visible from the very first paint (start-up)
  el.setAttribute("role", "status");
  el.setAttribute("aria-live", "polite");
  el.innerHTML =
    '<div class="fn-box"><div class="fn-orb"><span class="fn-ring"></span><span class="fn-lg">f</span>' +
    '<span class="fn-sp"></span><span class="fn-sp"></span><span class="fn-sp"></span></div>' +
    '<div class="fn-name">fairytale</div><div class="fn-msg">Opening the salon…</div></div>';
  var msg = el.querySelector(".fn-msg");

  function mount() { if (!el.parentNode) document.body.appendChild(el); }
  if (document.body) mount(); else document.addEventListener("DOMContentLoaded", mount);

  // ---- state ----------------------------------------------------------------------------------------------
  var pending = 1;            // 1 = the start-up screen, released by endInitial()
  var initial = true;
  var shownAt = Date.now();
  var hideTimer = null;
  var stickyUntil = 0;

  function show(label) {
    clearTimeout(hideTimer);
    if (label) msg.textContent = label;
    if (!el.classList.contains("on")) { shownAt = Date.now(); el.classList.add("on"); }
    document.body && document.body.setAttribute("aria-busy", "true");
  }
  function scheduleHide() {
    clearTimeout(hideTimer);
    var wait = Math.max(HIDE_GRACE_MS, MIN_VISIBLE_MS - (Date.now() - shownAt), stickyUntil - Date.now());
    hideTimer = setTimeout(function () {
      if (pending > 0) return;                       // another call started during the grace period
      el.classList.remove("on");
      document.body && document.body.removeAttribute("aria-busy");
    }, wait);
  }
  function begin(label) {
    pending++;
    show(label || DEFAULT_LABEL);
    var done = false;
    return function end() {
      if (done) return;
      done = true;
      pending = Math.max(0, pending - 1);
      if (pending === 0) scheduleHide();
    };
  }

  // ---- public API -----------------------------------------------------------------------------------------
  function run(label, fn) {
    var end = begin(label);
    var p;
    try { p = Promise.resolve(fn()); } catch (e) { end(); throw e; }
    return p.then(function (v) { end(); return v; }, function (e) { end(); throw e; });
  }

  function wrap(api) {
    var out = {};
    Object.keys(api).forEach(function (name) {
      var f = api[name];
      if (typeof f !== "function") { out[name] = f; return; }
      out[name] = function () {
        var r = f.apply(this, arguments);
        // Synchronous helpers (realtime subscriptions, key resets, ...) return non-promises: leave them alone.
        if (!r || typeof r.then !== "function") return r;
        var end = begin(LABELS[name]);
        return r.then(
          function (v) {
            if (STICKY[name]) stickyUntil = Date.now() + STICKY_MS;
            end(); return v;
          },
          function (e) { end(); throw e; }
        );
      };
    });
    out.raw = api;                                   // untracked access for silent background refreshes
    return out;
  }

  function endInitial() {
    if (!initial) return;
    initial = false;
    pending = Math.max(0, pending - 1);
    if (pending === 0) scheduleHide();
  }

  // Safety net: never leave a user staring at a spinner if something hangs.
  setInterval(function () {
    if (el.classList.contains("on") && Date.now() - shownAt > 60000) { pending = 0; initial = false; scheduleHide(); }
  }, 5000);

  window.Loader = { wrap: wrap, run: run, begin: begin, endInitial: endInitial, setLabel: function (t) { msg.textContent = t; } };
})();
