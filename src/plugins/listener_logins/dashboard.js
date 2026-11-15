// Listener logins in the dashboard: the logins of a mount on its Settings tab.
(window.lurcastPlugins = window.lurcastPlugins || []).push((dashboard) => {
  const { h, section, field, request, action, confirmAction, markDirty } = dashboard;
  const NAME = "listener-logins";
  const logins = new Map();
  const loadedAt = new Map();

  const load = async (mount) => {
    try {
      const { text } = await request("GET", "/admin/api/listener-logins", { mount });
      logins.set(mount, JSON.parse(text));
    } catch (error) {
      if (dashboard.sessionEnded(error)) return;
      logins.set(mount, null);
    }
    dashboard.updateSection(NAME, settings);
  };

  const panel = (...body) => section(NAME, h("div", { class: "panel panel--flat" },
    h("div", { class: "panel__head" }, h("h3", { class: "panel__title" }, "Listener logins")), ...body));

  const settings = (m) => {
    const now = Date.now();
    if (now - (loadedAt.get(m.mount) || 0) > 15000) {
      loadedAt.set(m.mount, now);
      load(m.mount);
    }
    const list = logins.get(m.mount);
    if (list === undefined) return panel(h("div", { class: "panel__body" }, h("p", { class: "muted small" }, "Loading…")));
    if (list === null) {
      return panel(h("div", { class: "panel__body" },
        h("p", { class: "muted small" }, "Anyone can listen to this mount. To require a login, list it under plugins.listener_logins.mounts in config.yml.")));
    }
    const user = h("input", { class: "input", name: "user", autocomplete: "off", required: "", maxlength: "255" });
    const password = h("input", { class: "input", name: "password", type: "password", autocomplete: "new-password", required: "", minlength: "4" });
    const reload = () => { loadedAt.set(m.mount, 0); load(m.mount); };
    const wrapper = panel(h("div", { class: "panel__body stack" },
      h("p", { class: "muted small" }, `Listeners sign in with one of these logins, for example with ${m.listen_url.replace("://", "://user:password@")}. They are kept in ${list.file}.`),
      list.users.length
        ? h("div", { class: "table-wrap" }, h("table", { class: "table" },
          h("thead", null, h("tr", null, h("th", null, "User"), h("th", null, h("span", { class: "sr-only" }, "Remove")))),
          h("tbody", null, list.users.map((name) => h("tr", null,
            h("td", { class: "mono" }, name),
            h("td", null, h("div", { class: "row-actions" }, h("button", {
              class: "btn btn--sm", type: "button",
              onclick: async () => {
                if (await confirmAction(`Remove ${name}?`, "They can no longer listen to this mount. Players that are already connected keep playing until they reconnect.", "Remove login")) {
                  await action(() => request("POST", "/admin/listener-logins/remove", { mount: m.mount, user: name }), "Login removed", reload);
                }
              },
            }, "Remove"))))))))
        : h("p", { class: "muted small" }, "No logins yet, so nobody can listen."),
      h("form", {
        class: "form-grid",
        onsubmit: async (event) => {
          event.preventDefault();
          const ok = await action(() => request("POST", "/admin/listener-logins", { mount: m.mount, user: user.value.trim(), password: password.value }), "Login saved", () => { wrapper.dataset.dirty = ""; document.activeElement.blur(); });
          if (ok) reload();
        },
      },
      field("User", user), field("Password", password, "Saving an existing user changes their password."),
      h("div", { class: "form-actions span-2" }, h("button", { class: "btn btn--primary", type: "submit" }, "Save login")))));
    markDirty(wrapper);
    return wrapper;
  };

  dashboard.register("listener_logins", { settings });
});
