// Public status page: one-button players and live now-playing updates from /api/v1/stations.
(() => {
  "use strict";

  const POLL_MS = 15000;
  const HISTORY_LIMIT = 10;
  const stations = new Map();
  let current = null;

  const localTime = (iso) => {
    const date = new Date(iso);
    return Number.isNaN(date.getTime()) ? "" : date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  };

  const setMediaSession = (station) => {
    if (!("mediaSession" in navigator)) return;
    const song = station.el.querySelector("[data-song]").textContent;
    navigator.mediaSession.metadata = new MediaMetadata({ title: song || station.name, artist: song ? station.name : "Live" });
  };

  const stop = (station) => {
    station.el.classList.remove("is-playing", "is-loading");
    station.button.setAttribute("aria-label", `Play ${station.name}`);
    station.audio.pause();
    // Drop the connection; resuming a paused live stream would replay stale audio.
    station.audio.removeAttribute("src");
    station.audio.load();
    if (current === station) current = null;
  };

  const play = (station) => {
    if (current && current !== station) stop(current);
    current = station;
    station.el.classList.add("is-loading");
    station.button.setAttribute("aria-label", `Pause ${station.name}`);
    station.audio.src = `${station.mount}?t=${Date.now()}`;
    station.audio.volume = station.volume;
    station.audio.play().catch(() => stop(station));
  };

  const enhance = (el) => {
    const audio = el.querySelector("audio");
    const button = el.querySelector(".station__play");
    if (!audio || !button) return;
    const station = { el, audio, button, mount: el.dataset.mount, name: el.dataset.name, volume: 1 };
    try {
      const saved = Number(localStorage.getItem("lurcast-volume"));
      if (saved >= 0 && saved <= 1 && localStorage.getItem("lurcast-volume") !== null) station.volume = saved;
    } catch (_) { /* storage blocked */ }

    audio.removeAttribute("controls");
    audio.removeAttribute("src");
    audio.hidden = true;
    button.hidden = false;
    el.classList.add("has-player");

    const meta = el.querySelector(".station__meta");
    const vol = document.createElement("label");
    vol.className = "station__vol";
    const volText = document.createElement("span");
    volText.className = "sr-only";
    volText.textContent = `Volume for ${station.name}`;
    const range = document.createElement("input");
    range.type = "range";
    range.min = "0";
    range.max = "1";
    range.step = "0.05";
    range.value = String(station.volume);
    range.addEventListener("input", () => {
      station.volume = Number(range.value);
      audio.volume = station.volume;
      try { localStorage.setItem("lurcast-volume", range.value); } catch (_) { /* storage blocked */ }
    });
    vol.append(volText, range);
    meta.prepend(vol);

    button.addEventListener("click", () => (current === station ? stop(station) : play(station)));
    audio.addEventListener("playing", () => {
      el.classList.remove("is-loading");
      el.classList.add("is-playing");
      setMediaSession(station);
    });
    audio.addEventListener("error", () => { if (audio.getAttribute("src")) stop(station); });
    stations.set(station.mount, station);
  };

  const update = (data) => {
    let total = 0;
    for (const info of data.stations || []) {
      total += info.listeners.current;
      const station = stations.get(info.mount);
      if (!station) continue;
      const { el } = station;
      el.querySelector("[data-listeners]").textContent = `${info.listeners.current} listening`;

      const status = el.querySelector("[data-status]");
      const pill = document.createElement("span");
      pill.className = info.online ? "pill pill--live" : "pill";
      if (info.online) {
        const dot = document.createElement("span");
        dot.className = "dot";
        pill.append(dot);
      }
      pill.append(info.online ? "Live" : "Offline");
      status.replaceChildren(pill);
      station.button.disabled = !info.online;

      const songEl = el.querySelector("[data-song]");
      const song = (info.now_playing && info.now_playing.song) || "";
      const previous = songEl.textContent;
      if (song !== previous) {
        if (previous) {
          const history = el.querySelector("[data-history]");
          const list = history.querySelector("ol");
          const item = document.createElement("li");
          const time = document.createElement("time");
          time.textContent = localTime(new Date().toISOString());
          const title = document.createElement("span");
          title.textContent = previous;
          item.append(time, title);
          list.prepend(item);
          while (list.children.length > HISTORY_LIMIT) list.lastElementChild.remove();
          history.hidden = false;
        }
        songEl.textContent = song;
        songEl.classList.remove("is-new");
        void songEl.offsetWidth;
        songEl.classList.add("is-new");
        el.querySelector("[data-now]").hidden = !song;
        if (current === station) setMediaSession(station);
      }
    }
    const totalEl = document.querySelector("[data-total-listeners]");
    if (totalEl) totalEl.textContent = String(total);
  };

  const poll = async () => {
    if (document.visibilityState !== "visible") return;
    try {
      const response = await fetch("/api/v1/stations", { headers: { Accept: "application/json" }, cache: "no-store" });
      if (response.ok) update(await response.json());
    } catch (_) { /* offline; try again next time */ }
  };

  document.querySelectorAll(".history time[datetime]").forEach((time) => {
    const text = localTime(time.getAttribute("datetime"));
    if (text) time.textContent = text;
  });

  if (!document.querySelector("[data-stations]")) return;
  document.querySelectorAll(".station").forEach(enhance);
  if (stations.size === 0) return;
  setInterval(poll, POLL_MS);
  document.addEventListener("visibilitychange", poll);
})();
