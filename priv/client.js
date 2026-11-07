/*
 * Weberl beacon (per page).
 *
 * Injected into live pages, after the transport engine (engine.js), as
 *   <script src="/_weberl/client.js" data-weberl-page="ID" data-weberl-token="T"
 *           data-weberl-kind="one_way|two_way" data-weberl-fallback="poll|none"
 *           data-weberl-topics='["topic", ...]' (only when the page has topics) defer>
 *
 * The beacon is the page-side API; the connections belong to a hub (see the
 * header of engine.js for the hub interface and the transports). Today the hub
 * is a SharedWorker (hub.js) shared by the tabs, or an in-page engine (one
 * connection per tab) where that is not possible.
 *
 * Receive server events (the second argument is the topic of an event that was
 * published to a topic; a snapshot from the handler's handle_subscribe/2
 * arrives as a plain event, without one):
 *   Weberl.on("tick", function (data, topic) { ... });
 * (also dispatched on document as "weberl:<name>" CustomEvents, detail = data.)
 *
 * Weberl's own events: Weberl.on("weberl_connected" | "weberl_reconnecting" |
 * "weberl_transport" | "weberl_closed" | "weberl_stale", fn). The prefix is reserved:
 * the server cannot publish a name that starts with "weberl_". On document they are
 * "weberl:connected" (detail: transport), "weberl:reconnecting", "weberl:transport"
 * (detail: name), "weberl:closed" (detail: reason) and "weberl:stale".
 *
 * State and start-up: Weberl.state() is "connecting" (until the first connection is
 * up), "connected", "reconnecting" (a connection that was up dropped; retrying, ends in
 * connected or closed) or "closed" (ended for good). This script is inserted before the
 * last </body>, so a script of the layout (even with defer) runs BEFORE it and
 * window.Weberl does not exist yet. Such a script waits for the document event:
 *   if (window.Weberl) { start(); }
 *   else { document.addEventListener("weberl:ready", start, { once: true }); }
 * ("weberl:ready" fires once, after window.Weberl is set; Weberl.ready(fn) is the
 * same for code that already has Weberl: it calls fn(Weberl) at once.)
 *
 * Regions: the server can re-render a region of the page (weberl_live:update/3,
 * update_topic/4); the beacon swaps the content of <weberl-region name="x"> /
 * [data-weberl-region="x"] and dispatches "weberl:region" on document (detail:
 * {region, count}).
 *
 * Send a request to the page's handle_request/3 (a Promise: the reply, or true
 * when the handler had none; it rejects with an Error carrying .reason/.status):
 *   Weberl.request("save", { id: 7 }).then(function (reply) { ... });
 */
(function () {
  "use strict";

  var script = document.querySelector("script[data-weberl-page]");
  if (!script || window.Weberl) { return; }
  if (!window.WeberlEngine) {
    console.error("weberl: engine.js did not load, the page is not live");
    return;
  }

  function topicsOf(attr) {
    if (!attr) { return []; }
    try {
      var list = JSON.parse(attr);
      return Array.isArray(list) ? list : [];
    } catch (e) {
      console.error("weberl: bad data-weberl-topics", e);
      return [];
    }
  }

  var page = {
    id: script.getAttribute("data-weberl-page"),
    token: script.getAttribute("data-weberl-token"),
    kind: script.getAttribute("data-weberl-kind"),
    fallback: script.getAttribute("data-weberl-fallback") === "poll" ? "poll" : "none",
    topics: topicsOf(script.getAttribute("data-weberl-topics"))
  };
  var handlers = {};
  var transport = null;
  var done = false;
  var connected = false;       // up now
  var reconnecting = false;    // was up, dropped, the hub is retrying

  // topic is set for events published to a topic (undefined for the page's own
  // events and for snapshots).
  function emit(name, data, topic) {
    (handlers[name] || []).forEach(function (fn) {
      try { fn(data, topic); } catch (e) { console.error("weberl handler failed", e); }
    });
    document.dispatchEvent(new CustomEvent("weberl:" + name, { detail: data }));
  }

  // The events of Weberl itself. Weberl.on knows them as "weberl_<name>" (the
  // server cannot publish a name with that prefix, so they never clash with the
  // app's events); the document events keep the plain "weberl:<name>".
  function emitOwn(name, data) {
    (handlers["weberl_" + name] || []).forEach(function (fn) {
      try { fn(data); } catch (e) { console.error("weberl handler failed", e); }
    });
    document.dispatchEvent(new CustomEvent("weberl:" + name, { detail: data }));
  }

  // The hub that hosts this page's connection: the SharedWorker shared by the
  // tabs of the origin, or this tab's own engine when that is not possible
  // (WeberlEngine.shared() decides). A worker running another version of the
  // scripts is reported (console warning and the "weberl:stale" event, detail:
  // {hub, page} versions) and this tab runs its own engine.
  function chooseHub() {
    return window.WeberlEngine.shared({
      stale: function (info) {
        console.warn("weberl: the shared hub runs another version of the scripts " +
                     "(hub " + info.hub + ", page " + info.page + "); reload the page");
        emitOwn("stale", info);
      }
    });
  }

  // ---- regions ---------------------------------------------------------
  //
  // The server re-renders a region of the page (weberl_live:update/3) and
  // sends the event "weberl:region" with data {"region": name, "html": ...}.
  // The regions are found when the event arrives, so ones added to the page
  // later (by other scripts) work too: <weberl-region name="x"> (what
  // {: region x :} renders) or any element with data-weberl-region="x"
  // ({: region x tag=tbody :} or hand-written). Their content is replaced.

  // The default wrapper: shows its children as if it were not there.
  if (window.customElements && !window.customElements.get("weberl-region")) {
    window.customElements.define("weberl-region", class extends HTMLElement {
      connectedCallback() { this.style.display = "contents"; }
    });
  }

  function regionTargets(name) {
    var q = (window.CSS && CSS.escape) ? CSS.escape(name) : name.replace(/["\\]/g, "\\$&");
    return document.querySelectorAll(
      'weberl-region[name="' + q + '"], [data-weberl-region="' + q + '"]');
  }

  // Replace the content of a region, keeping the focus (and the selection in
  // a text field) on the element that had it when that element has an id.
  function replaceContent(el, html) {
    var active = document.activeElement;
    var keep = active && active.id && el.contains(active) ? {
      id: active.id,
      start: active.selectionStart,
      end: active.selectionEnd
    } : null;
    el.innerHTML = html;
    if (keep) {
      var again = document.getElementById(keep.id);
      if (again) {
        again.focus();
        if (keep.start != null && again.setSelectionRange) {
          try { again.setSelectionRange(keep.start, keep.end); } catch (e) { /* not a text field */ }
        }
      }
    }
  }

  function patchRegion(data) {
    var update;
    try { update = JSON.parse(data); } catch (e) { update = null; }
    if (!update || typeof update.region !== "string" || typeof update.html !== "string") {
      console.error("weberl: bad region update", data);
      return;
    }
    var targets = regionTargets(update.region);
    for (var i = 0; i < targets.length; i++) { replaceContent(targets[i], update.html); }
    // "weberl:region" (detail: {region, count}) tells the app a patch happened
    document.dispatchEvent(new CustomEvent("weberl:region", {
      detail: { region: update.region, count: targets.length }
    }));
  }

  function onEvent(name, data, topic) {
    if (name === "weberl:region") { patchRegion(data); } else { emit(name, data, topic); }
  }

  var hub = chooseHub();
  // The tab leaving tells the hub (a worker is not told when a tab goes away);
  // a page kept in the back/forward cache keeps its subscription.
  window.addEventListener("pagehide", function (ev) {
    if (!ev.persisted) { hub.close(); }
  });
  var sub = hub.subscribe(page, {
    event: onEvent,
    connected: function (name) { connected = true; reconnecting = false; emitOwn("connected", name); },
    reconnecting: function () { connected = false; reconnecting = true; emitOwn("reconnecting"); },
    transport: function (name) { transport = name; emitOwn("transport", name); },
    closed: function (reason) { done = true; connected = false; reconnecting = false; emitOwn("closed", reason); }
  });

  window.Weberl = {
    pageId: page.id,
    kind: page.kind,
    get transport() { return transport; },
    on: function (name, fn) {
      (handlers[name] = handlers[name] || []).push(fn);
    },
    request: function (name, data) {
      return done ? Promise.reject(new Error("weberl closed")) : sub.request(name, data);
    },
    close: function () { sub.close(); },
    // "connecting" until the first connection is up, "connected" while the page
    // receives, "reconnecting" after a connection that was up dropped (the hub
    // retries without a limit; it ends in connected or closed), "closed" once the
    // page ended for good.
    state: function () {
      return done ? "closed" : reconnecting ? "reconnecting" : connected ? "connected" : "connecting";
    },
    // Runs fn(Weberl) now. Scripts that may run before this one (a layout script
    // with defer) cannot call it: they listen for "weberl:ready" instead, see above.
    ready: function (fn) { fn(window.Weberl); }
  };
  document.dispatchEvent(new CustomEvent("weberl:ready"));
})();
