// Lurcast admin dashboard. Signs in with its own form, polls /admin/api/overview, and calls the
// existing admin endpoints for actions. Every value from the server is inserted as text, never as
// HTML, because song titles, station names, and user agents come from sources and listeners.
(() => {
  "use strict";

  const POLL_MS = 3000;
  const SPARK_POINTS = 120;
  const STORE_KEY = "lurcast-admin-auth";
  const app = document.getElementById("app");

  const state = {
    auth: null,
    data: null,
    mount: null,
    tab: "overview",
    filter: "",
    spark: [],
    peak: 0,
    lastBytes: null,
    lastAt: 0,
    bandwidth: null,
    updatedAt: 0,
    failed: false,
    renderedKey: null,
    timer: null,
  };
  const ui = {};

  // ---------- DOM helpers ----------

  const h = (tag, props, ...children) => {
    const el = document.createElement(tag);
    if (props) {
      for (const [key, value] of Object.entries(props)) {
        if (value === null || value === undefined || value === false) continue;
        if (key === "class") el.className = value;
        else if (key.startsWith("on") && typeof value === "function") el.addEventListener(key.slice(2), value);
        else if (key === "value") el.value = value;
        else if (key === "checked") el.checked = Boolean(value);
        else el.setAttribute(key, value === true ? "" : String(value));
      }
    }
    append(el, children);
    return el;
  };

  const append = (el, children) => {
    for (const child of children.flat(Infinity)) {
      if (child === null || child === undefined || child === false) continue;
      el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return el;
  };

  const ICONS = {
    headphones: "M3 14v-2a9 9 0 0 1 18 0v2M3 14h3v6H4a1 1 0 0 1-1-1v-5Zm18 0h-3v6h2a1 1 0 0 0 1-1v-5Z",
    copy: "M9 9h10v10H9zM5 15V5h10",
    external: "M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5",
    warn: "M12 3 2 20h20L12 3Zm0 6v5m0 3v.5",
    out: "M15 4h4a1 1 0 0 1 1 1v14a1 1 0 0 1-1 1h-4M10 16l4-4-4-4M14 12H4",
    play: "M8 5v14l11-7z",
    reload: "M20 11a8 8 0 1 0-2.3 5.7M20 4v7h-7",
    download: "M12 4v11m0 0-4-4m4 4 4-4M5 20h14",
    upload: "M12 16V5m0 0-4 4m4-4 4 4M5 20h14",
  };

  const icon = (name) => {
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
    path.setAttribute("d", ICONS[name]);
    path.setAttribute("fill", "none");
    path.setAttribute("stroke", "currentColor");
    path.setAttribute("stroke-width", "1.8");
    path.setAttribute("stroke-linecap", "round");
    path.setAttribute("stroke-linejoin", "round");
    svg.append(path);
    return svg;
  };

  // The Lurcast logo mark, as on lurcast.com: text-coloured horn with copper sound waves.
  const logoMark = () => {
    const ns = "http://www.w3.org/2000/svg";
    const node = (tag, attrs, children = []) => {
      const el = document.createElementNS(ns, tag);
      for (const [key, value] of Object.entries(attrs)) el.setAttribute(key, value);
      el.append(...children);
      return el;
    };
    return node("svg", { class: "brand__mark", viewBox: "0 0 32 32", fill: "none", "stroke-linecap": "round", "aria-hidden": "true" }, [
      node("circle", { cx: "4.5", cy: "28", r: "1.6", fill: "currentColor" }),
      node("path", { d: "M4.5 28C8.5 27.5 9.5 23 12 20.2S17 15 19 13", stroke: "currentColor", "stroke-width": "2.4" }),
      node("path", { d: "M16.2 10.2 21.8 15.8", stroke: "currentColor", "stroke-width": "2.4" }),
      node("g", { stroke: "#d89c60", "stroke-width": "2" }, [
        node("path", { d: "M20 7.4A5.6 5.6 0 0 1 24.6 12" }),
        node("path", { d: "M20.4 3.2A9.6 9.6 0 0 1 28.8 11.6" }),
      ]),
    ]);
  };

  // ---------- Formatting ----------

  const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;

  const duration = (seconds) => {
    const s = Math.max(0, Math.floor(seconds || 0));
    if (s < 60) return `${s}s`;
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ${s % 60}s`;
    const hrs = Math.floor(m / 60);
    if (hrs < 24) return `${hrs}h ${m % 60}m`;
    return `${Math.floor(hrs / 24)}d ${hrs % 24}h`;
  };

  const bytes = (n) => {
    const units = ["B", "KB", "MB", "GB", "TB"];
    let value = Number(n) || 0;
    let unit = 0;
    while (value >= 1000 && unit < units.length - 1) {
      value /= 1000;
      unit += 1;
    }
    return `${value >= 100 || unit === 0 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
  };

  const bitrate = (bitsPerSecond) => {
    if (bitsPerSecond === null) return "–";
    if (bitsPerSecond < 1e6) return `${Math.round(bitsPerSecond / 1e3)} kbit/s`;
    return `${(bitsPerSecond / 1e6).toFixed(bitsPerSecond < 1e7 ? 2 : 1)} Mbit/s`;
  };

  const ago = (iso) => {
    if (!iso) return "";
    const seconds = (Date.now() - new Date(iso).getTime()) / 1000;
    if (seconds < 10) return "just now";
    if (seconds < 60) return `${Math.floor(seconds)}s ago`;
    if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
    return `${duration(seconds)} ago`;
  };

  const clock = (iso) => new Date(iso).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });

  const player = (agent) => {
    if (!agent) return "Unknown";
    const known = [
      [/VLC\/([\d.]+)/i, "VLC"], [/Edg\/([\d]+)/, "Edge"], [/Firefox\/([\d]+)/, "Firefox"],
      [/Chrome\/([\d]+)/, "Chrome"], [/Version\/([\d.]+).*Safari/, "Safari"], [/iTunes\/([\d.]+)/, "iTunes"],
      [/AppleCoreMedia\/([\d.]+)/, "Apple Music"], [/Winamp/i, "Winamp"], [/foobar2000/i, "foobar2000"],
      [/Lavf\/([\d.]+)/, "FFmpeg"], [/mpv/i, "mpv"], [/curl\/([\d.]+)/, "curl"], [/Windows-Media-Player/i, "Windows Media Player"],
    ];
    for (const [pattern, name] of known) {
      const match = agent.match(pattern);
      if (match) return match[1] ? `${name} ${match[1].split(".").slice(0, 2).join(".")}` : name;
    }
    return agent.split(/[\s/(]/)[0] || agent;
  };

  const PROTOCOLS = { icecast: "Icecast source", shoutcast_v1: "SHOUTcast v1", shoutcast_v2: "SHOUTcast v2", relay: "Relay", file: "Fallback file", internal: "Transcoded", unknown: "Source" };

  const regionNames = (() => {
    try { return new Intl.DisplayNames([navigator.language || "en"], { type: "region" }); } catch (_) { return null; }
  })();
  const flag = (code) => (code && /^[A-Z]{2}$/.test(code) ? String.fromCodePoint(...[...code].map((c) => 0x1f1a5 + c.charCodeAt(0))) : "");
  const countryName = (code) => {
    if (!code) return "Unknown";
    try { return (regionNames && regionNames.of(code)) || code; } catch (_) { return code; }
  };
  // Adds up per-country listener counts ({"SE": 3, "": 1}) from one or more mounts, biggest first.
  const countryCounts = (maps) => {
    const counts = new Map();
    for (const map of maps) for (const [code, n] of Object.entries(map || {})) counts.set(code, (counts.get(code) || 0) + n);
    return [...counts.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  };

  const label = (mount) => (mount.name ? mount.name : mount.mount);
  const mountPath = (mount) => mount.mount;
  const optionLabel = (mount) => (mount.name ? `${mount.name} (${mount.mount})` : mount.mount);
  const currentMount = () => state.data && state.data.mounts.find((m) => m.mount === state.mount);

  // ---------- Network ----------

  class AuthError extends Error {}

  // `body` is sent as JSON, or as it is when it is a file (a Blob).
  const request = async (method, path, params, body) => {
    const query = params ? `?${new URLSearchParams(params)}` : "";
    const headers = { Authorization: state.auth, "X-Lurcast-Admin": "1" };
    const raw = body instanceof Blob;
    if (raw) headers["Content-Type"] = body.type || "application/octet-stream";
    else if (body !== undefined) headers["Content-Type"] = "application/json";
    const response = await fetch(`${path}${query}`, {
      method, headers, cache: "no-store", credentials: "omit",
      body: raw || body === undefined ? body : JSON.stringify(body),
    });
    if (response.status === 401) throw new AuthError("Sign in again");
    const text = await response.text();
    let message = text.trim();
    if (message.startsWith("<")) {
      const doc = new DOMParser().parseFromString(message, "application/xml");
      message = (doc.querySelector("message") || doc.documentElement).textContent.trim();
    } else if (message.startsWith("{")) {
      try { message = JSON.parse(message).error || message; } catch (_) { /* keep text */ }
    }
    if (!response.ok) throw new Error(message || `Request failed (${response.status})`);
    return { text, message };
  };

  // Runs an admin request, then `done` (which may unlock a form for redrawing), then refreshes.
  const action = async (run, success, done) => {
    try {
      const result = await run();
      if (done) done();
      toast(success || result.message || "Done");
      await refresh();
      return true;
    } catch (error) {
      if (error instanceof AuthError) return signOut("Your session ended. Sign in again.");
      toast(error.message, true);
      return false;
    }
  };

  const loadAuth = () => {
    try { return sessionStorage.getItem(STORE_KEY) || localStorage.getItem(STORE_KEY); } catch (_) { return null; }
  };
  const saveAuth = (value, remember) => {
    try {
      sessionStorage.setItem(STORE_KEY, value);
      if (remember) localStorage.setItem(STORE_KEY, value);
    } catch (_) { /* storage blocked: stay signed in for this page only */ }
  };
  const clearAuth = () => {
    try { sessionStorage.removeItem(STORE_KEY); localStorage.removeItem(STORE_KEY); } catch (_) { /* ignore */ }
  };

  // ---------- Toasts and dialogs ----------

  const toast = (message, error = false) => {
    if (!ui.toasts) return;
    const el = h("div", { class: error ? "toast toast--error" : "toast", role: error ? "alert" : "status" }, message);
    ui.toasts.append(el);
    setTimeout(() => el.remove(), error ? 6000 : 3200);
  };

  const modal = (build) => new Promise((resolve) => {
    const dialog = h("dialog", { class: "modal" });
    const close = (value) => { dialog.close(); dialog.remove(); resolve(value); };
    dialog.addEventListener("cancel", (event) => { event.preventDefault(); close(null); });
    append(dialog, build(close));
    document.body.append(dialog);
    dialog.showModal();
    const focus = dialog.querySelector("[autofocus]") || dialog.querySelector("button");
    if (focus) focus.focus();
  });

  const confirmAction = (title, text, confirmLabel, danger = true) => modal((close) => [
    h("div", { class: "modal__body" }, h("h2", { class: "modal__title" }, title), h("p", { class: "modal__text" }, text)),
    h("div", { class: "modal__foot" },
      h("button", { class: "btn", type: "button", onclick: () => close(false) }, "Cancel"),
      h("button", { class: danger ? "btn btn--danger" : "btn btn--primary", type: "button", autofocus: true, onclick: () => close(true) }, confirmLabel)),
  ]);

  const chooseMount = (title, text, options, confirmLabel) => modal((close) => {
    const select = h("select", { class: "select", autofocus: true },
      options.map((m) => h("option", { value: m.mount }, optionLabel(m))));
    return [
      h("div", { class: "modal__body" },
        h("h2", { class: "modal__title" }, title),
        h("p", { class: "modal__text" }, text),
        options.length ? select : h("p", { class: "modal__text" }, "No other live mount has the same stream format.")),
      h("div", { class: "modal__foot" },
        h("button", { class: "btn", type: "button", onclick: () => close(null) }, "Cancel"),
        h("button", { class: "btn btn--primary", type: "button", disabled: !options.length, onclick: () => close(select.value) }, confirmLabel)),
    ];
  });

  const copyButton = (value) => h("button", {
    class: "btn btn--ghost btn--sm copy", type: "button", title: "Copy", "aria-label": "Copy",
    onclick: async () => {
      try {
        await navigator.clipboard.writeText(value);
        toast("Copied");
      } catch (_) {
        toast("Copying is blocked in this browser", true);
      }
    },
  }, icon("copy"));

  // ---------- Sign in ----------

  const showLogin = (message) => {
    clearTimeout(state.timer);
    state.data = null;
    state.renderedKey = null;
    const username = h("input", { class: "input", name: "username", autocomplete: "username", required: true, value: "admin", autocapitalize: "none", spellcheck: "false" });
    const password = h("input", { class: "input", type: "password", name: "password", autocomplete: "current-password", required: true, autofocus: true });
    const remember = h("input", { type: "checkbox" });
    const error = h("p", { class: "field__error", role: "alert" }, message || "");
    const submit = h("button", { class: "btn btn--primary", type: "submit" }, "Sign in");
    const form = h("form", {
      class: "panel login",
      onsubmit: async (event) => {
        event.preventDefault();
        submit.disabled = true;
        error.textContent = "";
        const value = `Basic ${btoa(unescape(encodeURIComponent(`${username.value.trim()}:${password.value}`)))}`;
        try {
          const response = await fetch("/admin/api/overview", { headers: { Authorization: value, "X-Lurcast-Admin": "1" }, cache: "no-store", credentials: "omit" });
          if (response.status === 401) throw new Error("That username or password is not right.");
          if (!response.ok) throw new Error(`The server answered ${response.status}.`);
          state.auth = value;
          saveAuth(value, remember.checked);
          start(await response.json());
        } catch (err) {
          error.textContent = err.message;
          submit.disabled = false;
          password.select();
        }
      },
    },
    h("div", { class: "panel__body login__body" },
      h("div", { class: "brand" }, logoMark(), "Lurcast"),
      h("div", null, h("h1", { class: "login__title" }, "Sign in to the admin"),
        h("p", { class: "login__lead" }, "Server admins sign in as admin with the admin_password from the configuration. Station owners use the login their provider gave them.")),
      h("label", { class: "field" }, h("span", { class: "field__label" }, "Username"), username),
      h("label", { class: "field" }, h("span", { class: "field__label" }, "Password"), password),
      h("label", { class: "check check--sm" }, remember, h("span", null, "Keep me signed in on this device")),
      error,
      submit));
    app.replaceChildren(h("div", { class: "wrap" }, form));
    password.focus();
  };

  const signOut = (message) => {
    clearAuth();
    state.auth = null;
    showLogin(message);
  };

  // ---------- Layout ----------

  const buildShell = () => {
    ui.status = h("span", { class: "topbar__status" });
    ui.host = h("span", { class: "topbar__host" });
    ui.banner = h("div");
    ui.kpis = h("div", { class: "kpis" });
    ui.user = h("span", { class: "chip topbar__user" });
    ui.serverChart = h("div");
    ui.mounts = h("ul", { class: "mounts", "aria-label": "Mount points" });
    ui.locations = h("section", { class: "panel", "aria-label": "Listener locations" });
    ui.reload = h("button", { class: "btn btn--ghost btn--sm", type: "button", title: "Reload config.yml", onclick: reloadConfig }, icon("reload"), h("span", { class: "btn__label" }, "Reload config"));
    ui.detail = h("section", { class: "panel detail", "aria-live": "polite" });
    ui.toasts = h("div", { class: "toasts" });
    app.replaceChildren(
      h("header", { class: "topbar" },
        h("a", { class: "brand", href: "/admin/" }, logoMark(), "Lurcast"),
        ui.host,
        h("span", { class: "topbar__spacer" }),
        ui.status,
        ui.user,
        ui.reload,
        h("a", { class: "btn btn--ghost btn--sm", href: "/", target: "_blank", rel: "noopener", title: "Public page" }, icon("external"), h("span", { class: "btn__label" }, "Public page")),
        h("button", { class: "btn btn--ghost btn--sm", type: "button", title: "Sign out", onclick: () => signOut("You signed out.") }, icon("out"), h("span", { class: "btn__label" }, "Sign out"))),
      h("div", { class: "wrap" },
        ui.banner,
        ui.kpis,
        ui.serverChart,
        h("div", { class: "layout" }, h("div", { class: "sidebar" }, h("nav", { class: "panel" }, ui.mounts), ui.locations), ui.detail)),
      ui.toasts);
  };

  const renderStatus = () => {
    const stale = state.failed;
    ui.status.className = stale ? "topbar__status is-stale" : "topbar__status";
    ui.status.replaceChildren(h("span", { class: "dot" }), h("span", { class: "topbar__status-text" }, stale ? "Connection lost, retrying" : `Live · ${state.data.server.id}`));
    ui.status.title = stale ? "Connection lost, retrying" : "Updating live";
    const { server } = state.data;
    ui.host.textContent = server.hostname === "localhost" ? server.public_url : server.hostname;
  };

  const renderBanner = () => {
    const defaults = state.data.server.default_passwords;
    ui.banner.replaceChildren(defaults.length
      ? h("div", { class: "banner", role: "note" }, icon("warn"),
        h("span", null, `${defaults.join(", ")} still ${defaults.length === 1 ? "uses" : "use"} the default password. Change ${defaults.length === 1 ? "it" : "them"} in config.yml before you expose this server.`))
      : "");
  };

  const sparkline = (points) => {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("class", "kpi__spark");
    svg.setAttribute("viewBox", "0 0 100 40");
    svg.setAttribute("preserveAspectRatio", "none");
    svg.setAttribute("aria-hidden", "true");
    if (points.length < 2) return svg;
    const max = Math.max(1, ...points);
    const xy = points.map((value, i) => [(i / (points.length - 1)) * 100, 38 - (value / max) * 30]);
    const line = xy.map(([x, y], i) => `${i ? "L" : "M"}${x.toFixed(2)},${y.toFixed(2)}`).join("");
    const area = document.createElementNS(ns, "path");
    area.setAttribute("class", "area");
    area.setAttribute("d", `${line}L100,40L0,40Z`);
    const stroke = document.createElementNS(ns, "path");
    stroke.setAttribute("class", "line");
    stroke.setAttribute("d", line);
    svg.append(area, stroke);
    return svg;
  };

  const kpi = (title, value, unit, sub, extra) => h("div", { class: "kpi" },
    h("span", { class: "kpi__label" }, title),
    h("span", { class: "kpi__value" }, value, unit ? h("small", null, ` ${unit}`) : null),
    h("span", { class: "kpi__sub" }, sub),
    extra || null);

  const renderKpis = () => {
    const { server, mounts } = state.data;
    const live = mounts.filter((m) => m.online);
    const sent = live.reduce((sum, m) => sum + (m.bytes_sent || 0), 0);
    ui.kpis.replaceChildren(
      kpi("Listeners", server.listeners.toLocaleString(), `/ ${server.max_listeners.toLocaleString()}`,
        `Peak ${state.peak.toLocaleString()} since you opened this page`, sparkline(state.spark)),
      kpi("On air", live.length, `/ ${server.max_sources}`, `${plural(mounts.length, "mount")} known`),
      kpi("Outgoing", bitrate(state.bandwidth), null, `${bytes(sent)} sent by live mounts`),
      kpi("Uptime", duration(server.uptime_seconds), null, `Since ${new Date(server.started_at).toLocaleString()}`));
  };

  const renderMountList = () => {
    const { mounts } = state.data;
    if (!mounts.length) {
      ui.mounts.replaceChildren(h("li", { class: "empty-row" }, "No mounts yet. Point an encoder at this server to go live."));
      return;
    }
    ui.mounts.replaceChildren(...mounts.map((m) => h("li", null,
      h("button", {
        class: "mount", type: "button", "aria-current": m.mount === state.mount ? "true" : "false",
        onclick: () => select(m.mount, state.tab, true),
      },
      h("span", { class: "mount__row" },
        h("span", { class: m.online ? "status-dot is-live" : "status-dot", title: m.online ? "Live" : "Offline" }),
        h("span", { class: "mount__name" }, label(m)),
        m.online ? h("span", { class: "mount__count", title: "Listeners" }, icon("headphones"), String(m.listeners)) : h("span", { class: "mount__count" }, "Offline")),
      h("span", { class: "mount__path" }, [mountPath(m), m.hidden ? " · hidden" : "", m.relay_url ? " · relay" : ""].join(""), m.recording ? h("span", { class: "rec", title: "Recording" }, " ● REC") : null),
      m.online && m.song ? h("span", { class: "mount__song" }, m.song) : null))));
  };

  const locationBars = (counts, limit) => {
    const total = counts.reduce((sum, [, n]) => sum + n, 0) || 1;
    const shown = counts.slice(0, limit);
    const rest = counts.slice(limit).reduce((sum, [, n]) => sum + n, 0);
    const row = (name, mark, n) => {
      const fill = h("span", { class: "bar__fill" });
      fill.style.width = `${Math.max(2, (n / total) * 100)}%`;
      return h("li", { class: "bar" },
        h("span", { class: "bar__label" }, mark ? h("span", { class: "bar__flag", "aria-hidden": "true" }, mark) : null, name),
        h("span", { class: "bar__value" }, String(n)),
        h("span", { class: "bar__track", "aria-hidden": "true" }, fill));
    };
    return h("ol", { class: "bars" },
      shown.map(([code, n]) => row(countryName(code), flag(code), n)),
      rest ? row(`${plural(counts.length - limit, "other country")}`, "", rest) : null);
  };

  const renderLocations = () => {
    const { server, mounts } = state.data;
    if (!server.features.locations) {
      ui.locations.hidden = true;
      return;
    }
    ui.locations.hidden = false;
    const counts = countryCounts(mounts.map((m) => m.countries));
    ui.locations.replaceChildren(
      h("div", { class: "panel__head" }, h("h2", { class: "panel__title" }, "Listener locations"), h("span", { class: "muted small" }, "all mounts")),
      h("div", { class: "panel__body" }, counts.length ? locationBars(counts, 8) : h("p", { class: "muted small" }, "Nobody is listening right now.")));
  };

  const reloadConfig = async () => {
    ui.reload.disabled = true;
    try {
      const response = await fetch("/admin/reload", { method: "POST", headers: { Authorization: state.auth, "X-Lurcast-Admin": "1" }, credentials: "omit" });
      if (response.status === 401) return signOut("Your session ended. Sign in again.");
      const result = await response.json().catch(() => ({ ok: false, error: `HTTP ${response.status}` }));
      if (!result.ok) toast(`Reload failed: ${result.error}`, true);
      else if (result.restart_required.length) toast(`Configuration reloaded. Restart to apply ${result.restart_required.join(", ")}.`);
      else toast("Configuration reloaded");
      await refresh();
    } catch (error) {
      toast(error.message, true);
    } finally {
      ui.reload.disabled = false;
    }
  };

  // ---------- Mount detail ----------

  const TABS = [["overview", "Overview"], ["listeners", "Listeners"], ["history", "Songs"], ["bans", "Bans"], ["settings", "Settings"]];

  // The tabs plugins add for mount `m`.
  const pluginTabs = (m) => fromPlugins("tabs", m).flat().filter((tab) => tab && tab.id && typeof tab.sections === "function");

  // The tab to show for `m`: the selected one, or the Overview when `m` has no such tab.
  const activeTab = (m) => (TABS.some(([id]) => id === state.tab) || pluginTabs(m).some((tab) => tab.id === state.tab) ? state.tab : "overview");

  // A section keeps its state across polls while it has focus, unsaved input, or (for charts,
  // which load their own data) until `data-until`.
  const preserved = (el) => el && (el.contains(document.activeElement) || el.dataset.dirty === "1" || Number(el.dataset.until || 0) > Date.now());

  const markDirty = (el) => {
    el.addEventListener("input", () => { el.dataset.dirty = "1"; });
    return el;
  };

  const renderDetail = () => {
    const m = currentMount();
    if (!m) {
      ui.detail.replaceChildren(h("div", { class: "empty-row" }, "Select a mount to see its details."));
      state.renderedKey = null;
      return;
    }
    const key = `${m.mount}\n${state.tab}`;
    const sections = buildSections(m);
    if (state.renderedKey !== key) {
      state.renderedKey = key;
      ui.body = h("div", { class: "detail__body" }, sections);
      ui.detail.replaceChildren(buildDetailHead(m), ui.body);
      return;
    }
    ui.detail.firstElementChild.replaceWith(buildDetailHead(m));
    for (const fresh of sections) {
      const old = ui.body.querySelector(`[data-section="${fresh.dataset.section}"]`);
      if (!old) ui.body.append(fresh);
      else if (!preserved(old)) old.replaceWith(fresh);
    }
  };

  const buildDetailHead = (m) => h("div", { class: "detail__head" },
    h("div", { class: "detail__title-row" },
      h("h2", { class: "detail__title" }, label(m)),
      m.online ? h("span", { class: "pill pill--live" }, h("span", { class: "dot" }), "Live") : h("span", { class: "pill" }, "Offline"),
      m.hidden ? h("span", { class: "pill" }, "Hidden") : null,
      m.recording ? h("span", { class: "pill pill--danger" }, h("span", { class: "dot" }), "Recording") : null,
      fromPlugins("chips", m),
      m.online ? h("span", { class: "chip" }, m.format) : null,
      h("span", { class: "detail__actions" },
        m.online ? h("a", { class: "btn btn--sm", href: m.mount, target: "_blank", rel: "noopener" }, icon("play"), "Listen") : null)),
    h("p", { class: "mount__path" }, m.mount, m.online ? ` · ${PROTOCOLS[m.protocol] || m.protocol} · on air for ${duration(m.uptime_seconds)}` : ""),
    h("div", { class: "tabs", role: "tablist" },
      TABS.map(([id, text]) => h("button", {
        class: "tab", type: "button", role: "tab", "aria-selected": activeTab(m) === id ? "true" : "false",
        onclick: () => select(m.mount, id, false),
      }, text,
      id === "listeners" && m.online ? h("span", { class: "count" }, String(m.listeners)) : null,
      id === "history" && m.history && m.history.length ? h("span", { class: "count" }, String(m.history.length)) : null)),
      pluginTabs(m).map((tab) => h("button", {
        class: "tab", type: "button", role: "tab", "aria-selected": state.tab === tab.id ? "true" : "false",
        onclick: () => select(m.mount, tab.id, false),
      }, tab.label, tab.count ? h("span", { class: "count" }, String(tab.count)) : null))));

  const buildSections = (m) => {
    switch (activeTab(m)) {
      case "listeners": return [listenersToolbar(m), listenersTable(m)];
      case "history": return [historySection(m)];
      case "bans": return [bansList(m), banForm(m)];
      case "settings": return [recordingSection(m), stationForm(m), ...fromPlugins("settings", m).flat(), fallbackForm(m), dangerZone(m)];
      default: {
        const tab = pluginTabs(m).find((t) => t.id === activeTab(m));
        if (tab) {
          try { return tab.sections(m); } catch (error) { console.error(`The ${tab.id} tab failed to draw`, error); }
        }
        return [nowPlaying(m), statsSection(m), historyPanel(m.mount), mountLocations(m), connectSection(m)];
      }
    }
  };

  const section = (name, ...children) => h("div", { "data-section": name }, children);

  // ---------- Plugins ----------

  // Plugins add to the dashboard from their own scripts, which run before this one and queue a
  // function that gets the dashboard API:
  //
  //   (window.lurcastPlugins = window.lurcastPlugins || []).push((dashboard) => {
  //     dashboard.register("my_plugin", { stats: (m) => dashboard.stat("Thing", m.my_thing) });
  //   });
  //
  // A plugin's parts are used only while it is on (listed in `features.plugins`). Each gets the
  // mount `m`, which carries the plugin's own fields from `mount_fields`:
  //
  // - chips(m): small labels next to the mount's title
  // - stats(m): `stat` cards on the Overview tab
  // - links(m): [label, URL] pairs for the listen links
  // - art(m): an image URL to show next to the song playing
  // - settings(m): `section`s for the Settings tab
  // - tabs(m): tabs of its own, as { id, label, count, sections: (m) => [section, ...] }. The id
  //   goes in the address (#/live/autodj), so keep it short, lowercase and stable.
  // - offline(m): what to show instead of "This mount is offline", for example when the plugin
  //   plays something on the mount's fallback
  const pluginParts = [];

  const fromPlugins = (part, m) => {
    const on = state.data.server.features.plugins || [];
    const results = [];
    for (const { name, parts } of pluginParts) {
      if (!on.includes(name) || typeof parts[part] !== "function") continue;
      try {
        const result = parts[part](m);
        if (result !== null && result !== undefined) results.push(result);
      } catch (error) {
        console.error(`The ${name} plugin failed to draw ${part}`, error);
      }
    }
    return results;
  };

  // Draws the section *name* of the open mount again with *build*, unless someone is using it.
  const updateSection = (name, build) => {
    const old = ui.body && ui.body.querySelector(`[data-section="${name}"]`);
    const m = currentMount();
    if (old && m && !preserved(old)) old.replaceWith(build(m));
  };

  const loadPlugins = () => {
    const dashboard = {
      register: (name, parts) => { pluginParts.push({ name, parts }); },
      h, icon, section, stat, field, request, action, toast, confirmAction, markDirty, updateSection, duration, bytes, modal,
      // The Authorization header value, for requests `request` can't make, such as uploads that
      // report their progress.
      auth: () => state.auth,
      // Signs out and returns true when *error* means the admin login is no longer valid.
      sessionEnded: (error) => {
        if (!(error instanceof AuthError)) return false;
        signOut("Your session ended. Sign in again.");
        return true;
      },
    };
    for (const install of window.lurcastPlugins || []) {
      try { install(dashboard); } catch (error) { console.error("A dashboard plugin failed to load", error); }
    }
  };

  const nowPlaying = (m) => {
    const replacement = m.online ? null : fromPlugins("offline", m)[0];
    if (replacement) return section("now", replacement);
    if (!m.online) {
      return section("now", h("div", { class: "nowplaying" },
        h("p", { class: "nowplaying__song is-empty" }, "This mount is offline"),
        h("p", { class: "nowplaying__since" }, m.relay_url
          ? "It is a relay; it connects when the upstream server is live or a listener tunes in."
          : "It goes live as soon as an encoder connects with the settings below.")));
    }
    const input = h("input", { class: "input", name: "song", placeholder: "Artist - Title", maxlength: "4096", "aria-label": "New song title" });
    const form = h("form", {
      class: "inline-form",
      onsubmit: async (event) => {
        event.preventDefault();
        const song = input.value.trim();
        if (!song) return;
        await action(() => request("POST", "/admin/metadata", { mount: m.mount, song }), "Song title updated", () => {
          input.value = "";
          input.blur();
          wrapper.dataset.dirty = "";
        });
      },
    }, input, h("button", { class: "btn", type: "submit" }, "Update title"));
    const art = fromPlugins("art", m)[0];
    const wrapper = section("now", h("div", { class: art ? "nowplaying nowplaying--art" : "nowplaying" },
      art ? h("img", { class: "nowplaying__art", src: art, alt: "", width: "96", height: "96" }) : null,
      h("span", { class: "now__label" }, "Now playing"),
      h("p", { class: m.song ? "nowplaying__song" : "nowplaying__song is-empty" }, m.song || "The source has not sent a song title"),
      m.song_updated_at ? h("p", { class: "nowplaying__since" }, `Changed ${ago(m.song_updated_at)}`) : null,
      form));
    markDirty(wrapper);
    return wrapper;
  };

  const stat = (title, value) => h("div", { class: "stat" }, h("span", { class: "stat__label" }, title), h("span", { class: "stat__value" }, value));

  const statsSection = (m) => {
    if (!m.online) return section("stats");
    const audio = [m.sample_rate ? `${(m.sample_rate / 1000).toFixed(1)} kHz` : null, m.channels === 1 ? "mono" : m.channels === 2 ? "stereo" : null].filter(Boolean).join(" ");
    return section("stats", h("div", { class: "stats" },
      stat("Listeners", m.max_listeners ? `${m.listeners} / ${m.max_listeners}` : String(m.listeners)),
      stat("Peak", String(m.peak_listeners)),
      stat("Unique addresses", String(m.unique_listeners)),
      stat("Average listen", duration(m.average_listen_seconds)),
      stat("Connections", String(m.total_connections)),
      stat("Data sent", bytes(m.bytes_sent)),
      stat("Format", m.format),
      audio ? stat("Audio", audio) : null,
      fromPlugins("stats", m),
      stat("Directory", m.listed ? "Listed" : "Not listed")));
  };

  const kv = (rows) => h("dl", { class: "kv" }, rows.filter(Boolean).map(([term, value, copy]) => [
    h("dt", null, term), h("dd", null, value), copy === false ? h("span") : copyButton(String(value)),
  ]));

  const mountLocations = (m) => {
    const counts = countryCounts([m.countries]);
    if (!state.data.server.features.locations || !m.online || !counts.length) return section("locations");
    return section("locations", h("h3", { class: "section-title" }, "Where listeners are"), locationBars(counts, 6));
  };

  const connectSection = (m) => {
    const { server } = state.data;
    const host = (() => { try { return new URL(server.public_url).hostname; } catch (_) { return server.hostname; } })();
    const base = server.public_url.replace(/\/$/, "");
    const encoder = [["Server", host], ["Port", String(server.port)], ["Mount", m.mount], ["Username", m.source_username], ["Password", "Your source password", false]];
    if (server.shoutcast_port && m.shoutcast_sid) encoder.push(["SHOUTcast port", String(server.shoutcast_port)], ["Stream ID", String(m.shoutcast_sid)]);
    if (m.relay_url) encoder.push(["Relays from", m.relay_url]);
    const links = [["Stream", `${base}${m.mount}`], ["Playlist", `${base}${m.mount}.m3u`]];
    if (m.shoutcast_sid) links.push(["SHOUTcast", `${base}/stream/${m.shoutcast_sid}`]);
    for (const more of fromPlugins("links", m)) links.push(...more);
    if (m.fallback) links.push(["Fallback", m.fallback]);
    return section("connect", h("div", { class: "two-col" },
      h("div", null, h("h3", { class: "section-title" }, "Encoder settings"), kv(encoder)),
      h("div", null, h("h3", { class: "section-title" }, "Listen links"), kv(links))));
  };

  const moveTargets = (m) => state.data.mounts.filter((other) => other.online && other.mount !== m.mount && other.content_type === m.content_type);

  const moveListeners = async (m, id) => {
    const destination = await chooseMount(id ? `Move listener ${id}` : "Move all listeners",
      "Listeners switch without reconnecting. The destination must carry the same stream format.", moveTargets(m), "Move");
    if (!destination) return;
    const params = { mount: m.mount, destination };
    if (id) params.id = String(id);
    await action(() => request("POST", "/admin/moveclients", params));
  };

  const listenersToolbar = (m) => {
    const filter = h("input", {
      class: "input", type: "search", placeholder: "Filter by address or player", value: state.filter, "aria-label": "Filter listeners",
      oninput: () => {
        state.filter = filter.value;
        const table = ui.body.querySelector('[data-section="clients"]');
        if (table) table.replaceWith(listenersTable(currentMount()));
      },
    });
    return section("clients-toolbar", h("div", { class: "toolbar" },
      filter,
      h("span", { class: "toolbar__spacer" }),
      h("button", { class: "btn btn--sm", type: "button", disabled: !m.online || !m.listeners, onclick: () => moveListeners(m) }, "Move all…")));
  };

  const listenersTable = (m) => {
    const query = state.filter.trim().toLowerCase();
    const matches = (c) => [c.address, c.user_agent, c.country || "", countryName(c.country)].some((text) => text.toLowerCase().includes(query));
    const clients = (m.clients || []).filter((c) => !query || matches(c));
    const geo = state.data.server.features.locations;
    if (m.online && m.listeners && !m.clients) {
      return section("clients", h("div", { class: "table-wrap" }, h("p", { class: "empty-row" }, "Loading listeners…")));
    }
    if (!clients.length) {
      return section("clients", h("div", { class: "table-wrap" }, h("p", { class: "empty-row" },
        !m.online ? "This mount is offline." : query ? "No listeners match the filter." : "Nobody is listening right now.")));
    }
    return section("clients", h("div", { class: "table-wrap" }, h("table", { class: "table" },
      h("thead", null, h("tr", null, h("th", null, "ID"), h("th", null, "Address"), geo ? h("th", null, "Country") : null, h("th", null, "Player"), h("th", null, "Connected"), h("th", null, h("span", { class: "sr-only" }, "Actions")))),
      h("tbody", null, clients.map((c) => h("tr", null,
        h("td", { class: "mono" }, String(c.id)),
        h("td", { class: "mono" }, c.address),
        geo ? h("td", { title: countryName(c.country) }, c.country ? `${flag(c.country)} ${c.country}` : "–") : null,
        h("td", null, h("div", { class: "ua", title: c.user_agent }, player(c.user_agent))),
        h("td", null, duration(c.connected_seconds)),
        h("td", null, h("div", { class: "row-actions" },
          h("button", { class: "btn btn--sm", type: "button", onclick: () => moveListeners(m, c.id) }, "Move"),
          h("button", { class: "btn btn--sm", type: "button", onclick: () => banListener(m, c) }, "Ban"),
          h("button", {
            class: "btn btn--sm btn--danger", type: "button",
            onclick: () => action(() => request("POST", "/admin/killclient", { mount: m.mount, id: String(c.id) }), `Listener ${c.id} disconnected`),
          }, "Kick")))))))));
  };

  const historySection = (m) => {
    const history = m.history || [];
    if (!history.length) {
      return section("history", h("div", { class: "table-wrap" }, h("p", { class: "empty-row" }, m.online ? "No songs have played yet." : "This mount is offline.")));
    }
    return section("history", h("div", { class: "table-wrap" }, h("table", { class: "table" },
      h("thead", null, h("tr", null, h("th", null, "Played at"), h("th", null, "Title"))),
      h("tbody", null, history.map((song) => h("tr", null, h("td", { class: "mono" }, clock(song.played_at)), h("td", null, song.title)))))));
  };

  const field = (title, control, hint) => h("label", { class: "field" }, h("span", { class: "field__label" }, title), control, hint ? h("span", { class: "field__hint" }, hint) : null);

  const stationForm = (m) => {
    if (!m.online) {
      return section("station", h("p", { class: "muted" }, "Station details can be edited while the mount is live."));
    }
    const name = h("input", { class: "input", name: "name", value: m.name || "", maxlength: "4096" });
    const genre = h("input", { class: "input", name: "genre", value: m.genre || "", maxlength: "4096" });
    const url = h("input", { class: "input", name: "url", type: "url", value: m.url || "", placeholder: "https://", maxlength: "4096" });
    const description = h("textarea", { class: "input", name: "description", maxlength: "4096" });
    description.value = m.description || "";
    const listed = h("input", { type: "checkbox", checked: m.listed });
    const wrapper = section("station", h("form", {
      class: "panel panel--flat",
      onsubmit: async (event) => {
        event.preventDefault();
        const body = { name: name.value, genre: genre.value, url: url.value, description: description.value, listed: listed.checked };
        const path = `/api/v1/stations/${m.mount.slice(1).split("/").map(encodeURIComponent).join("/")}`;
        await action(() => request("PATCH", path, null, body), "Station details saved", () => {
          document.activeElement.blur();
          wrapper.dataset.dirty = "";
        });
      },
    },
    h("div", { class: "panel__head" }, h("h3", { class: "panel__title" }, "Station details")),
    h("div", { class: "panel__body stack" },
      h("div", { class: "form-grid" },
        field("Name", name), field("Genre", genre),
        h("div", { class: "span-2" }, field("Website", url)),
        h("div", { class: "span-2" }, field("Description", description))),
      h("label", { class: "check" }, listed, h("span", null, "List this station in the public directories (YP)")),
      h("div", { class: "form-actions" },
        h("span", { class: "field__hint form-actions__hint" }, "The encoder's own values return when it reconnects."),
        h("button", { class: "btn btn--primary", type: "submit" }, "Save details")))));
    markDirty(wrapper);
    return wrapper;
  };

  const fallbackForm = (m) => {
    const others = state.data.mounts.filter((other) => other.mount !== m.mount);
    const select = h("select", { class: "select", "aria-label": "Fallback mount" },
      h("option", { value: "" }, "No fallback"),
      others.map((other) => h("option", { value: other.mount }, optionLabel(other))));
    select.value = m.fallback || "";
    const wrapper = section("fallback", h("form", {
      class: "panel panel--flat",
      onsubmit: async (event) => {
        event.preventDefault();
        const fallback = select.value;
        await action(() => request("POST", "/admin/fallbacks", { mount: m.mount, fallback }), fallback ? `Fallback set to ${fallback}` : "Fallback removed", () => {
          document.activeElement.blur();
          wrapper.dataset.dirty = "";
        });
      },
    },
    h("div", { class: "panel__head" }, h("h3", { class: "panel__title" }, "Fallback")),
    h("div", { class: "panel__body stack" },
      h("p", { class: "muted small" }, "When the source disconnects, listeners move to the fallback mount instead of being dropped. A fallback from config.yml applies again after you remove this one or restart."),
      h("div", { class: "inline-form" }, select, h("button", { class: "btn", type: "submit" }, "Save fallback")))));
    markDirty(wrapper);
    select.addEventListener("change", () => { wrapper.dataset.dirty = "1"; });
    return wrapper;
  };

  const recordingFiles = new Map();
  const recordingsLoadedAt = new Map();

  const loadRecordings = async (mount) => {
    try {
      const response = await fetch(`/admin/api/recordings?${new URLSearchParams({ mount })}`, { headers: { Authorization: state.auth, "X-Lurcast-Admin": "1" }, cache: "no-store", credentials: "omit" });
      if (!response.ok) return;
      recordingFiles.set(mount, (await response.json()).files);
      if (state.mount === mount && state.tab === "settings") {
        const old = ui.body.querySelector('[data-section="recording"]');
        if (old) old.replaceWith(recordingSection(currentMount()));
      }
    } catch (_) { /* try again on the next visit */ }
  };

  const downloadRecording = async (mount, name) => {
    try {
      const slug = mount.replace(/^\//, "").replaceAll("/", "_").replace(/[^A-Za-z0-9._-]/g, "") || "_";
      const response = await fetch(`/admin/recordings/${encodeURIComponent(slug)}/${encodeURIComponent(name)}`, { headers: { Authorization: state.auth, "X-Lurcast-Admin": "1" }, credentials: "omit" });
      if (!response.ok) throw new Error(`Download failed (${response.status})`);
      const url = URL.createObjectURL(await response.blob());
      const link = h("a", { href: url, download: name });
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    } catch (error) {
      toast(error.message, true);
    }
  };

  const recordingSection = (m) => {
    const head = h("div", { class: "panel__head" }, h("h3", { class: "panel__title" }, "Recording"),
      m.recording ? h("span", { class: "pill pill--danger" }, h("span", { class: "dot" }), `Since ${new Date(m.recording.started_at).toLocaleTimeString()}`) : null);
    if (!state.data.server.features.recordings) {
      return section("recording", h("div", { class: "panel panel--flat" }, head,
        h("div", { class: "panel__body" }, h("p", { class: "muted small" }, "Set recordings_dir in config.yml to record mounts to disk."))));
    }
    const now = Date.now();
    if (now - (recordingsLoadedAt.get(m.mount) || 0) > 5000) {
      recordingsLoadedAt.set(m.mount, now);
      loadRecordings(m.mount);
    }
    const files = recordingFiles.get(m.mount) || [];
    const toggle = (verb) => action(() => request("POST", "/admin/record", { mount: m.mount, action: verb }), null, () => loadRecordings(m.mount));
    const note = m.record
      ? "This mount records every time its source connects (record: true in config.yml)."
      : "Start a recording now; it stops when you stop it or the source disconnects.";
    return section("recording", h("div", { class: "panel panel--flat" }, head,
      h("div", { class: "panel__body stack" },
        h("div", { class: "toolbar" },
          h("p", { class: "muted small" }, note),
          h("span", { class: "toolbar__spacer" }),
          m.recording
            ? h("button", { class: "btn btn--danger", type: "button", onclick: () => toggle("stop") }, "Stop recording")
            : h("button", { class: "btn btn--primary", type: "button", disabled: !m.online, onclick: () => toggle("start") }, "Start recording")),
        files.length
          ? h("div", { class: "table-wrap" }, h("table", { class: "table" },
            h("thead", null, h("tr", null, h("th", null, "File"), h("th", null, "Size"), h("th", null, h("span", { class: "sr-only" }, "Download")))),
            h("tbody", null, files.slice(0, 20).map((file) => h("tr", null,
              h("td", { class: "mono" }, file.name, file.recording ? h("span", { class: "rec" }, " ● recording") : null),
              h("td", null, bytes(file.bytes)),
              h("td", null, h("div", { class: "row-actions" },
                h("button", { class: "btn btn--sm", type: "button", onclick: () => downloadRecording(m.mount, file.name) }, icon("download"), "Download"))))))))
          : h("p", { class: "muted small" }, "No recordings yet."))));
  };

  const dangerZone = (m) => section("danger", h("div", { class: "danger-zone" },
    h("p", null, h("strong", null, "Disconnect the source"),
      m.fallback ? `Listeners move to ${m.fallback}. Most encoders reconnect by themselves.` : "Listeners are disconnected unless a fallback is set. Most encoders reconnect by themselves."),
    h("button", {
      class: "btn btn--danger", type: "button", disabled: !m.online,
      onclick: async () => {
        if (await confirmAction(`Disconnect ${label(m)}?`, "The encoder connected to this mount is cut off right away.", "Disconnect source")) {
          await action(() => request("POST", "/admin/killsource", { mount: m.mount }), "Source disconnected");
        }
      },
    }, "Disconnect source")));

  // ---------- Listener history chart ----------

  const RANGES = [["day", "24 hours"], ["week", "7 days"], ["month", "30 days"], ["year", "12 months"]];
  const CHART_TTL = 60000;
  const SVG_NS = "http://www.w3.org/2000/svg";
  const historyCache = new Map();
  const chartRange = new Map();

  const svgNode = (tag, attrs) => {
    const el = document.createElementNS(SVG_NS, tag);
    for (const [key, value] of Object.entries(attrs || {})) el.setAttribute(key, String(value));
    return el;
  };

  const loadHistory = async (mount, range) => {
    const key = `${mount || ""}\n${range}`;
    const cached = historyCache.get(key);
    if (cached && Date.now() - cached.at < CHART_TTL) return cached.data;
    const params = mount ? { mount, range } : { range };
    const { text } = await request("GET", "/admin/api/history", params);
    const data = JSON.parse(text);
    historyCache.set(key, { at: Date.now(), data });
    return data;
  };

  // A round axis maximum and step for values up to `value`: 1, 2, or 5 times a power of ten.
  const niceScale = (value) => {
    if (value <= 4) return { max: 4, step: 1 };
    const rough = value / 4;
    const power = 10 ** Math.floor(Math.log10(rough));
    const step = [1, 2, 5, 10].map((n) => n * power).find((n) => n >= rough);
    return { max: Math.ceil(value / step) * step, step };
  };

  const timeLabel = (seconds, range, long) => {
    const date = new Date(seconds * 1000);
    if (range === "day") return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    if (range === "year") return date.toLocaleDateString([], long ? { day: "numeric", month: "short", year: "numeric" } : { month: "short" });
    if (range === "week" && !long) return date.toLocaleDateString([], { weekday: "short", day: "numeric" });
    return long
      ? date.toLocaleString([], { weekday: "short", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" })
      : date.toLocaleDateString([], { day: "numeric", month: "short" });
  };

  // Splits points into runs without gaps (nulls are periods when the server was not running).
  const runs = (points, index) => {
    const result = [];
    let current = [];
    points.forEach((point, i) => {
      if (point[index] === null) {
        if (current.length) result.push(current);
        current = [];
      } else current.push(i);
    });
    if (current.length) result.push(current);
    return result;
  };

  const drawChart = (holder, data) => {
    const { points, range } = data;
    const width = Math.max(260, holder.clientWidth);
    const height = 200;
    const pad = { top: 10, right: 8, bottom: 24, left: 40 };
    const innerW = width - pad.left - pad.right;
    const innerH = height - pad.top - pad.bottom;
    const n = points.length;
    const peak = Math.max(0, ...points.map((p) => p[2] || 0));
    const { max, step } = niceScale(peak);
    const x = (i) => pad.left + (n > 1 ? (i / (n - 1)) * innerW : innerW / 2);
    const y = (v) => pad.top + innerH - (v / max) * innerH;
    const svg = svgNode("svg", { class: "chart__svg", width, height, viewBox: `0 0 ${width} ${height}`, role: "img" });

    for (let v = 0; v <= max; v += step) {
      svg.append(svgNode("line", { class: v === 0 ? "chart__base" : "chart__grid", x1: pad.left, x2: width - pad.right, y1: y(v), y2: y(v) }));
      const tick = svgNode("text", { class: "chart__tick", x: pad.left - 8, y: y(v) + 4, "text-anchor": "end" });
      tick.textContent = v.toLocaleString();
      svg.append(tick);
    }
    const labels = Math.max(2, Math.min(6, Math.floor(innerW / 90)));
    for (let k = 0; k < labels; k += 1) {
      const i = Math.round((k / (labels - 1)) * (n - 1));
      const anchor = k === 0 ? "start" : k === labels - 1 ? "end" : "middle";
      const tick = svgNode("text", { class: "chart__tick", x: x(i), y: height - 6, "text-anchor": anchor });
      tick.textContent = timeLabel(points[i][0], range, false);
      svg.append(tick);
    }

    for (const run of runs(points, 1)) {
      const line = run.map((i, k) => `${k ? "L" : "M"}${x(i).toFixed(1)},${y(points[i][1]).toFixed(1)}`).join("");
      if (run.length > 1) svg.append(svgNode("path", { class: "chart__area", d: `${line}L${x(run[run.length - 1]).toFixed(1)},${y(0)}L${x(run[0]).toFixed(1)},${y(0)}Z` }));
      svg.append(svgNode("path", { class: "chart__line", d: run.length > 1 ? line : `${line}h0.1` }));
      const peakLine = run.map((i, k) => `${k ? "L" : "M"}${x(i).toFixed(1)},${y(points[i][2]).toFixed(1)}`).join("");
      svg.append(svgNode("path", { class: "chart__peak", d: run.length > 1 ? peakLine : `${peakLine}h0.1` }));
    }

    const cross = svgNode("line", { class: "chart__cross", y1: pad.top, y2: pad.top + innerH, visibility: "hidden" });
    const dotAvg = svgNode("circle", { class: "chart__dot", r: 4, visibility: "hidden" });
    const dotPeak = svgNode("circle", { class: "chart__dot chart__dot--peak", r: 4, visibility: "hidden" });
    const hit = svgNode("rect", { class: "chart__hit", x: pad.left, y: 0, width: innerW, height: pad.top + innerH });
    svg.append(cross, dotPeak, dotAvg, hit);
    const tip = h("div", { class: "chart__tip", hidden: true });
    const hide = () => {
      tip.hidden = true;
      for (const el of [cross, dotAvg, dotPeak]) el.setAttribute("visibility", "hidden");
    };
    hit.addEventListener("pointerleave", hide);
    hit.addEventListener("pointermove", (event) => {
      const box = svg.getBoundingClientRect();
      const i = Math.max(0, Math.min(n - 1, Math.round(((event.clientX - box.left - pad.left) / innerW) * (n - 1))));
      const [at, average, top] = points[i];
      cross.setAttribute("x1", x(i));
      cross.setAttribute("x2", x(i));
      cross.setAttribute("visibility", "visible");
      if (average === null) {
        dotAvg.setAttribute("visibility", "hidden");
        dotPeak.setAttribute("visibility", "hidden");
      } else {
        dotAvg.setAttribute("cx", x(i));
        dotAvg.setAttribute("cy", y(average));
        dotPeak.setAttribute("cx", x(i));
        dotPeak.setAttribute("cy", y(top));
        dotAvg.setAttribute("visibility", "visible");
        dotPeak.setAttribute("visibility", "visible");
      }
      tip.replaceChildren();
      append(tip, [
        h("span", { class: "chart__tip-time" }, timeLabel(at, range, true)),
        average === null
          ? h("span", { class: "muted" }, "Server not running")
          : [h("span", null, h("span", { class: "key key--avg" }), `Average ${average.toLocaleString()}`),
            h("span", null, h("span", { class: "key key--peak" }), `Peak ${top.toLocaleString()}`)]]);
      tip.hidden = false;
      const right = x(i) + 12;
      tip.style.left = `${right + tip.offsetWidth > width ? Math.max(0, x(i) - 12 - tip.offsetWidth) : right}px`;
    });
    holder.replaceChildren(svg, tip);
    return svg;
  };

  // The "Listeners over time" panel for one mount, or for the whole server when `mount` is null.
  const historyPanel = (mount) => {
    const key = mount || "";
    const range = chartRange.get(key) || "day";
    const holder = h("div", { class: "chart__plot" }, h("p", { class: "muted small chart__empty" }, "Loading…"));
    const summary = h("span", { class: "muted small" });
    const buttons = RANGES.map(([id, text]) => h("button", {
      class: "seg__btn", type: "button", "aria-pressed": id === range ? "true" : "false",
      onclick: () => {
        chartRange.set(key, id);
        const fresh = historyPanel(mount);
        panel.replaceWith(fresh);
        const again = fresh.querySelector(`[aria-pressed="true"]`);
        if (again) again.focus();
      },
    }, text));
    const panel = h("div", { class: mount ? "chart" : "panel chart chart--server", "data-section": "chart", "data-until": String(Date.now() + CHART_TTL) },
      h("div", { class: mount ? "chart__head" : "chart__head panel__head" },
        h(mount ? "h3" : "h2", { class: mount ? "section-title" : "panel__title" }, mount ? "Listeners over time" : "Listeners over time · all mounts"),
        h("span", { class: "chart__legend", "aria-hidden": "true" },
          h("span", null, h("span", { class: "key key--avg" }), "Average"), h("span", null, h("span", { class: "key key--peak" }), "Peak")),
        h("span", { class: "toolbar__spacer" }),
        h("div", { class: "seg", role: "group", "aria-label": "Time range" }, buttons)),
      h("div", { class: mount ? "" : "panel__body" }, holder, summary));

    loadHistory(mount, range).then((data) => {
      const known = data.points.filter((p) => p[1] !== null);
      if (!known.length) {
        holder.replaceChildren(h("p", { class: "muted small chart__empty" }, "No listener data yet. Lurcast takes a sample every minute."));
        return;
      }
      const top = Math.max(...known.map((p) => p[2]));
      const mean = known.reduce((sum, p) => sum + p[1], 0) / known.length;
      const label = RANGES.find(([id]) => id === range)[1];
      summary.textContent = `Last ${label}: peak ${top.toLocaleString()}, average ${mean.toFixed(1)}.${state.data.server.features.history_saved ? "" : " History starts again when the server restarts; set data_dir to keep it."}`;
      let lastWidth = 0;
      const observer = new ResizeObserver(() => {
        if (!holder.isConnected) return observer.disconnect();
        if (Math.abs(holder.clientWidth - lastWidth) < 4) return;
        lastWidth = holder.clientWidth;
        drawChart(holder, data).setAttribute("aria-label", `Listeners over the last ${label}: peak ${top}, average ${mean.toFixed(1)}`);
      });
      observer.observe(holder);
    }).catch((error) => {
      if (error instanceof AuthError) return signOut("Your session ended. Sign in again.");
      holder.replaceChildren(h("p", { class: "muted small chart__empty" }, `Could not load the history: ${error.message}`));
    });
    return panel;
  };

  // ---------- Bans ----------

  const DURATIONS = [["60", "1 hour"], ["1440", "1 day"], ["10080", "7 days"], ["43200", "30 days"], ["", "Forever"]];
  const bansCache = new Map();
  const bansLoadedAt = new Map();

  const loadBans = async (mount) => {
    try {
      const { text } = await request("GET", "/admin/api/bans", { mount });
      bansCache.set(mount, JSON.parse(text));
      if (state.mount === mount && state.tab === "bans") {
        const old = ui.body.querySelector('[data-section="bans-list"]');
        if (old) old.replaceWith(bansList(currentMount()));
      }
    } catch (error) {
      if (error instanceof AuthError) signOut("Your session ended. Sign in again.");
    }
  };

  const addBan = async (m, params) => {
    try {
      const { text } = await request("POST", "/admin/bans", params);
      const result = JSON.parse(text);
      toast(`Banned ${result.ban.value}${result.disconnected ? `; ${plural(result.disconnected, "listener")} disconnected` : ""}`);
      bansLoadedAt.delete(m.mount);
      await loadBans(m.mount);
      await refresh();
      return true;
    } catch (error) {
      if (error instanceof AuthError) signOut("Your session ended. Sign in again.");
      else toast(error.message, true);
      return false;
    }
  };

  // Form controls shared by the ban dialog and the Bans tab.
  const banControls = (m, kind, value) => {
    const controls = {
      kind: h("select", { class: "select", "aria-label": "What to ban" },
        h("option", { value: "address" }, "Address or range"), h("option", { value: "user_agent" }, "Player")),
      value: h("input", { class: "input mono", required: true, maxlength: "512", value: value || "", placeholder: "203.0.113.7 or 203.0.113.0/24" }),
      duration: h("select", { class: "select", "aria-label": "How long" }, DURATIONS.map(([minutes, text]) => h("option", { value: minutes }, text))),
      scope: h("select", { class: "select", "aria-label": "Where", disabled: !state.data.access.full },
        h("option", { value: m.mount }, `This mount (${m.mount})`), state.data.access.full ? h("option", { value: "" }, "Every mount") : null),
      reason: h("input", { class: "input", maxlength: "200", placeholder: "Optional, for other admins" }),
    };
    controls.kind.value = kind || "address";
    controls.duration.value = "1440";
    const placeholder = () => {
      controls.value.placeholder = controls.kind.value === "address" ? "203.0.113.7 or 203.0.113.0/24" : "Text in the player name, such as StreamRipper";
    };
    controls.kind.addEventListener("change", placeholder);
    placeholder();
    controls.params = () => {
      const params = { kind: controls.kind.value, value: controls.value.value.trim(), mount: controls.scope.value, minutes: controls.duration.value, reason: controls.reason.value.trim() };
      for (const key of ["mount", "minutes", "reason"]) if (!params[key]) delete params[key];
      return params;
    };
    return controls;
  };

  const banListener = async (m, c) => {
    const params = await modal((close) => {
      const controls = banControls(m, "address", c.address);
      controls.kind.addEventListener("change", () => {
        controls.value.value = controls.kind.value === "address" ? c.address : c.user_agent;
      });
      return [
        h("form", {
          class: "modal__form",
          onsubmit: (event) => {
            event.preventDefault();
            close(controls.params());
          },
        },
        h("div", { class: "modal__body" },
          h("h2", { class: "modal__title" }, `Ban listener ${c.id}`),
          h("p", { class: "modal__text" }, "Matching listeners are disconnected now and refused when they try again."),
          field("Ban by", controls.kind),
          field("Value", controls.value),
          h("div", { class: "form-grid" }, field("For", controls.duration), field("Where", controls.scope)),
          field("Reason", controls.reason)),
        h("div", { class: "modal__foot" },
          h("button", { class: "btn", type: "button", onclick: () => close(null) }, "Cancel"),
          h("button", { class: "btn btn--danger", type: "submit", autofocus: true }, "Ban"))),
      ];
    });
    if (params) await addBan(m, params);
  };

  const expiry = (iso) => {
    if (!iso) return "Never";
    const seconds = (new Date(iso).getTime() - Date.now()) / 1000;
    return seconds <= 0 ? "Now" : `In ${duration(seconds)}`;
  };

  const bansList = (m) => {
    const now = Date.now();
    if (now - (bansLoadedAt.get(m.mount) || 0) > 10000) {
      bansLoadedAt.set(m.mount, now);
      loadBans(m.mount);
    }
    const loaded = bansCache.get(m.mount);
    const note = state.data.server.features.bans_saved ? null
      : h("p", { class: "muted small" }, "Bans last until the server restarts. Set data_dir in config.yml to keep them.");
    if (!loaded) return section("bans-list", h("p", { class: "muted small" }, "Loading bans…"));
    if (!loaded.bans.length) return section("bans-list", h("div", { class: "stack" }, note, h("p", { class: "muted small" }, "Nobody is banned from this mount.")));
    const lift = async (ban) => {
      try {
        await request("POST", "/admin/bans/remove", { id: ban.id });
        toast(`Ban on ${ban.value} lifted`);
        await loadBans(m.mount);
      } catch (error) {
        if (error instanceof AuthError) signOut("Your session ended. Sign in again.");
        else toast(error.message, true);
      }
    };
    return section("bans-list", h("div", { class: "stack" }, note, h("div", { class: "table-wrap" }, h("table", { class: "table" },
      h("thead", null, h("tr", null, h("th", null, "Banned"), h("th", null, "Where"), h("th", null, "Ends"), h("th", null, "Reason"), h("th", null, h("span", { class: "sr-only" }, "Actions")))),
      h("tbody", null, loaded.bans.map((ban) => h("tr", null,
        h("td", null, h("span", { class: "muted small" }, ban.kind === "address" ? "Address " : "Player "), h("span", { class: "mono" }, ban.value)),
        h("td", null, ban.mount ? ban.mount : "Every mount"),
        h("td", { title: ban.expires_at ? new Date(ban.expires_at).toLocaleString() : "" }, expiry(ban.expires_at)),
        h("td", null, h("div", { class: "ua", title: `By ${ban.created_by}, ${new Date(ban.created_at).toLocaleString()}` }, ban.reason || "–")),
        h("td", null, h("div", { class: "row-actions" },
          h("button", { class: "btn btn--sm", type: "button", onclick: () => lift(ban) }, "Lift ban"))))))))));
  };

  const banForm = (m) => {
    const controls = banControls(m, "address", "");
    const wrapper = section("ban-form", h("form", {
      class: "panel panel--flat",
      onsubmit: async (event) => {
        event.preventDefault();
        if (await addBan(m, controls.params())) {
          document.activeElement.blur();
          wrapper.replaceWith(banForm(currentMount()));
        }
      },
    },
    h("div", { class: "panel__head" }, h("h3", { class: "panel__title" }, "Add a ban")),
    h("div", { class: "panel__body stack" },
      h("div", { class: "form-grid" },
        field("Ban by", controls.kind), field("Value", controls.value),
        field("For", controls.duration), field("Where", controls.scope),
        h("div", { class: "span-2" }, field("Reason", controls.reason))),
      h("div", { class: "form-actions" },
        h("span", { class: "field__hint form-actions__hint" }, "A player ban matches every player whose name contains the text, ignoring case."),
        h("button", { class: "btn btn--danger", type: "submit" }, "Add ban")))));
    markDirty(wrapper);
    for (const select of [controls.kind, controls.duration, controls.scope]) select.addEventListener("change", () => { wrapper.dataset.dirty = "1"; });
    return wrapper;
  };

  // ---------- Navigation and polling ----------

  // The overview carries the listener list only for the mount whose Listeners tab is open.
  const overviewUrl = () => (state.tab === "listeners" && state.mount
    ? `/admin/api/overview?${new URLSearchParams({ clients: state.mount })}`
    : "/admin/api/overview");

  const select = (mount, tab, scroll) => {
    const needsClients = tab === "listeners" && (state.tab !== "listeners" || state.mount !== mount);
    state.mount = mount;
    state.tab = tab;
    const hash = `#${encodeURIComponent(mount)}${tab === "overview" ? "" : `/${tab}`}`;
    if (location.hash !== hash) history.replaceState(null, "", hash);
    renderMountList();
    renderDetail();
    if (needsClients) refresh();
    if (scroll && window.matchMedia("(max-width: 900px)").matches) ui.detail.scrollIntoView({ behavior: "smooth", block: "start" });
  };

  const readHash = () => {
    const raw = location.hash.slice(1);
    if (!raw) return;
    const [mount, tab] = raw.split("/");
    state.mount = decodeURIComponent(mount);
    // Plugin tabs are known only once the data has loaded; an unknown tab shows the Overview.
    state.tab = tab && /^[a-z0-9_-]+$/.test(tab) ? tab : "overview";
  };

  const ingest = (data) => {
    const now = performance.now();
    const sent = data.mounts.reduce((sum, m) => sum + (m.online ? m.bytes_sent || 0 : 0), 0);
    if (state.lastBytes !== null && sent >= state.lastBytes && now > state.lastAt) {
      state.bandwidth = ((sent - state.lastBytes) * 8) / ((now - state.lastAt) / 1000);
    }
    state.lastBytes = sent;
    state.lastAt = now;
    state.spark.push(data.server.listeners);
    if (state.spark.length > SPARK_POINTS) state.spark.shift();
    state.peak = Math.max(state.peak, data.server.listeners);
    state.data = data;
    state.updatedAt = Date.now();
    if (!data.mounts.some((m) => m.mount === state.mount)) {
      const first = data.mounts.find((m) => m.online) || data.mounts[0];
      state.mount = first ? first.mount : null;
    }
  };

  const render = () => {
    const { access } = state.data;
    ui.reload.hidden = !state.data.server.features.reload;
    ui.user.hidden = access.full;
    ui.user.textContent = access.user;
    ui.user.title = `Signed in as ${access.user}`;
    if (!access.full) ui.serverChart.replaceChildren();
    else if (!preserved(ui.serverChart.firstElementChild)) ui.serverChart.replaceChildren(historyPanel(null));
    renderLocations();
    renderStatus();
    renderBanner();
    renderKpis();
    renderMountList();
    renderDetail();
  };

  const refresh = async () => {
    clearTimeout(state.timer);
    try {
      const response = await fetch(overviewUrl(), { headers: { Authorization: state.auth, "X-Lurcast-Admin": "1" }, cache: "no-store", credentials: "omit" });
      if (response.status === 401) return signOut("Your password changed. Sign in again.");
      if (!response.ok) throw new Error(String(response.status));
      state.failed = false;
      ingest(await response.json());
      render();
    } catch (_) {
      state.failed = true;
      if (state.data) renderStatus();
    }
    schedule();
  };

  const schedule = () => {
    clearTimeout(state.timer);
    if (state.auth && document.visibilityState === "visible") state.timer = setTimeout(refresh, POLL_MS);
  };

  const start = (data) => {
    buildShell();
    readHash();
    ingest(data);
    render();
    if (state.tab === "listeners" && !(currentMount() || {}).clients) refresh();
    else schedule();
  };

  document.addEventListener("visibilitychange", () => {
    if (!state.auth || !state.data) return;
    if (document.visibilityState === "visible") refresh();
    else clearTimeout(state.timer);
  });
  window.addEventListener("hashchange", () => {
    if (!state.data) return;
    readHash();
    renderMountList();
    renderDetail();
    if (state.tab === "listeners") refresh();
  });

  const boot = async () => {
    loadPlugins();
    state.auth = loadAuth();
    if (!state.auth) return showLogin();
    readHash();
    try {
      const response = await fetch(overviewUrl(), { headers: { Authorization: state.auth, "X-Lurcast-Admin": "1" }, cache: "no-store", credentials: "omit" });
      if (response.status === 401) return signOut();
      if (!response.ok) throw new Error(String(response.status));
      start(await response.json());
    } catch (_) {
      showLogin("The server did not answer. Check that it is running and try again.");
    }
  };

  boot();
})();
