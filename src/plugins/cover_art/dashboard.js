// Cover art in the dashboard: the image next to the song playing, and uploads on the Settings tab.
(window.lurcastPlugins = window.lurcastPlugins || []).push((dashboard) => {
  const { h, icon, section, request, action } = dashboard;

  const settings = (m) => {
    const picker = (type, text) => {
      const input = h("input", { type: "file", accept: "image/jpeg,image/png,image/gif,image/webp", class: "sr-only" });
      input.addEventListener("change", () => {
        const file = input.files[0];
        input.value = "";
        if (file) action(() => request("POST", "/admin/artwork", { mount: m.mount, type }, file), type === "station" ? "Station logo saved" : "Cover saved");
      });
      return h("label", { class: "btn btn--sm" }, input, icon("upload"), text);
    };
    const remove = (type, text) => h("button", {
      class: "btn btn--sm", type: "button",
      onclick: () => action(() => request("POST", "/admin/artwork/remove", { mount: m.mount, type }), `${text} removed`),
    }, `Remove ${text.toLowerCase()}`);
    return section("artwork", h("div", { class: "panel panel--flat" },
      h("div", { class: "panel__head" }, h("h3", { class: "panel__title" }, "Cover art")),
      h("div", { class: "panel__body stack" },
        h("div", { class: "toolbar" },
          m.artwork ? h("img", { class: "thumb", src: m.artwork, alt: "Current cover art", width: "64", height: "64" }) : null,
          h("p", { class: "muted small" }, m.artwork
            ? "Players get this image from the status JSON. The song cover is shown when there is one, otherwise the station logo."
            : "SHOUTcast 2 encoders send cover art with the stream. For other encoders, upload a station logo here, or have your automation upload the cover of each song.")),
        h("div", { class: "row-actions" },
          picker("station", "Upload station logo"), m.artwork ? remove("station", "Logo") : null,
          picker("playing", "Upload song cover"), m.artwork ? remove("playing", "Cover") : null))));
  };

  dashboard.register("cover_art", { art: (m) => m.artwork || null, settings });
});
