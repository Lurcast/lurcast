// HLS in the dashboard: a chip, the HLS listeners, and the playlist among the listen links.
(window.lurcastPlugins = window.lurcastPlugins || []).push((dashboard) => {
  const { h, stat } = dashboard;
  dashboard.register("hls", {
    chips: (m) => (m.hls_url ? h("span", { class: "chip" }, "HLS") : null),
    stats: (m) => (m.hls_url ? stat("HLS listeners", String(m.hls_listeners)) : null),
    links: (m) => (m.hls_url ? [["HLS", m.hls_url]] : null),
  });
});
