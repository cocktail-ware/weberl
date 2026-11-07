// Unit tests for priv/client.js (the page beacon) against a fake DOM and a fake
// hub. Real browsers are for the e2e suite; this covers the logic: the page
// attributes, event routing, region patching and the hub wiring.
// Run through test/e2e/run.sh (or `npm run unit` in the test container).
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");

const SOURCE = require("./source")("client.js");

// An element that remembers what was done to it.
function element(extra = {}) {
  return Object.assign({
    innerHTML: "", style: {}, children: [],
    contains(other) { return this.children.includes(other); },
  }, extra);
}

function setup(attributes = {}, { engine = true } = {}) {
  const attrs = Object.assign({
    "data-weberl-page": "p1", "data-weberl-token": "tok", "data-weberl-kind": "one_way",
    "data-weberl-fallback": "poll", "data-weberl-topics": '["room"]',
  }, attributes);
  const script = { getAttribute: (n) => (n in attrs ? attrs[n] : null) };

  const subscribed = [];
  const sharedOptions = [];
  const hub = {
    closed: 0,
    subscribe(page, sink) {
      subscribed.push({ page, sink });
      return { request: (n, d) => Promise.resolve([n, d]), close() { hub.subCloses = (hub.subCloses || 0) + 1; } };
    },
    close() { hub.closed += 1; },
  };

  const regions = {};            // name -> [elements]
  const documentEvents = [];
  const startup = [];            // the "weberl:ready" event, kept apart from the rest
  const windowListeners = {};
  const elements = {};           // id -> element (for getElementById)
  const defined = {};
  const errors = [], warnings = [];

  const document = {
    activeElement: null,
    querySelector: (sel) => (sel === "script[data-weberl-page]" ? script : null),
    querySelectorAll: (sel) => regions[/name="([^"]+)"/.exec(sel)[1]] || [],
    getElementById: (id) => elements[id] || null,
    dispatchEvent: (ev) => (ev.type === "weberl:ready" ? startup : documentEvents).push(ev),
  };

  const sandbox = {
    document,
    console: { error: (...a) => errors.push(a), warn: (...a) => warnings.push(a.join(" ")) },
    JSON, Promise, Error, Array, Object,
    HTMLElement: class {},
    CustomEvent: class { constructor(type, init) { this.type = type; this.detail = init && init.detail; } },
    customElements: {
      get: (n) => defined[n],
      define: (n, cls) => { defined[n] = cls; },
    },
  };
  sandbox.window = sandbox;
  sandbox.addEventListener = (type, fn) => { (windowListeners[type] = windowListeners[type] || []).push(fn); };
  if (engine) {
    sandbox.WeberlEngine = { shared: (opts) => { sharedOptions.push(opts); return hub; } };
  }
  vm.runInNewContext(SOURCE, sandbox);

  return {
    sandbox, hub, subscribed, sharedOptions, regions, documentEvents, windowListeners,
    elements, defined, errors, warnings, document,
    sink: () => subscribed[0].sink,
    types: () => documentEvents.map((e) => e.type),
    startup,
  };
}

test("subscribes with the page attributes", () => {
  const t = setup();
  assert.equal(t.subscribed.length, 1);
  assert.deepEqual(JSON.parse(JSON.stringify(t.subscribed[0].page)),
    { id: "p1", token: "tok", kind: "one_way", fallback: "poll", topics: ["room"] });
  assert.equal(t.sandbox.Weberl.pageId, "p1");
  assert.equal(t.sandbox.Weberl.kind, "one_way");
});

test("without a script tag or without the engine it does nothing / says so", () => {
  const t = setup({}, { engine: false });
  assert.equal(t.subscribed.length, 0);
  assert.equal(t.errors.length, 1);
  assert.match(String(t.errors[0][0]), /engine\.js did not load/);
});

test("events reach Weberl.on handlers and document events, with the topic", () => {
  const t = setup();
  const seen = [];
  t.sandbox.Weberl.on("tick", (data, topic) => seen.push([data, topic]));
  t.sink().event("tick", "1");
  t.sink().event("tick", "2", "room");
  assert.deepEqual(seen, [["1", undefined], ["2", "room"]]);
  assert.deepEqual(t.types(), ["weberl:tick", "weberl:tick"]);
});

test("the hub's state is reported as events and kept on Weberl", () => {
  const t = setup();
  t.sink().transport("sse");
  t.sink().connected("sse");
  assert.equal(t.sandbox.Weberl.transport, "sse");
  t.sink().closed("closed");
  assert.deepEqual(t.types(), ["weberl:transport", "weberl:connected", "weberl:closed"]);
  return assert.rejects(t.sandbox.Weberl.request("x", 1), /weberl closed/);
});

test("Weberl.on knows the framework events by their weberl_ names; app events keep theirs", () => {
  const t = setup();
  const seen = [];
  const W = t.sandbox.Weberl;
  W.on("weberl_connected", (d) => seen.push(["weberl_connected", d]));
  W.on("weberl_reconnecting", () => seen.push(["weberl_reconnecting"]));
  W.on("weberl_closed", (d) => seen.push(["weberl_closed", d]));
  W.on("connected", (d) => seen.push(["app connected", d]));     // an app event that happens to be called so
  t.sink().connected("ws");
  t.sink().reconnecting();
  t.sink().event("connected", "mine");
  t.sink().closed("closed");
  assert.deepEqual(seen, [["weberl_connected", "ws"], ["weberl_reconnecting"], ["app connected", "mine"],
                          ["weberl_closed", "closed"]]);
  // the document events keep the plain names
  assert.deepEqual(t.types().slice(0, 2), ["weberl:connected", "weberl:reconnecting"]);
});

test("state() tells connecting, connected, reconnecting and closed", () => {
  const t = setup();
  assert.equal(t.sandbox.Weberl.state(), "connecting");
  t.sink().transport("sse");
  assert.equal(t.sandbox.Weberl.state(), "connecting");
  t.sink().connected("sse");
  assert.equal(t.sandbox.Weberl.state(), "connected");
  t.sink().reconnecting();
  assert.equal(t.sandbox.Weberl.state(), "reconnecting");
  t.sink().connected("ws");
  assert.equal(t.sandbox.Weberl.state(), "connected");
  t.sink().reconnecting();
  t.sink().closed("closed");
  assert.equal(t.sandbox.Weberl.state(), "closed");
});

test("weberl:ready fires once Weberl exists; ready(fn) calls at once", () => {
  const t = setup();
  assert.deepEqual(t.startup.map((e) => e.type), ["weberl:ready"]);
  const seen = [];
  t.sandbox.Weberl.ready((w) => seen.push(w === t.sandbox.Weberl));
  assert.deepEqual(seen, [true]);
});

test("without the engine there is no ready event either", () => {
  const t = setup({}, { engine: false });
  assert.deepEqual(t.startup, []);
});

test("requests go to the hub's subscription", async () => {
  const t = setup();
  assert.deepEqual(await t.sandbox.Weberl.request("save", { a: 1 }), ["save", { a: 1 }]);
});

// ---- regions ---------------------------------------------------------

const region = (name, html) => JSON.stringify({ region: name, html });

test("a region event replaces the content of every element of that name", () => {
  const t = setup();
  const a = element(), b = element(), other = element({ innerHTML: "keep" });
  t.regions.cart = [a, b];
  t.regions.other = [other];
  t.sink().event("weberl:region", region("cart", "<ul>new</ul>"));
  assert.equal(a.innerHTML, "<ul>new</ul>");
  assert.equal(b.innerHTML, "<ul>new</ul>");
  assert.equal(other.innerHTML, "keep");
  assert.equal(t.documentEvents.length, 1);
  assert.equal(t.documentEvents[0].type, "weberl:region");
  assert.deepEqual(JSON.parse(JSON.stringify(t.documentEvents[0].detail)), { region: "cart", count: 2 });
});

test("a region event is not an app event", () => {
  const t = setup();
  const seen = [];
  t.sandbox.Weberl.on("weberl:region", (d) => seen.push(d));
  t.sink().event("weberl:region", region("cart", "x"));
  assert.deepEqual(seen, []);
  assert.deepEqual(t.types(), ["weberl:region"], "only the patch notification");
});

test("regions that are not on the page are fine (count 0), also on topic events", () => {
  const t = setup();
  t.sink().event("weberl:region", region("gone", "x"), "room");
  assert.deepEqual(JSON.parse(JSON.stringify(t.documentEvents[0].detail)), { region: "gone", count: 0 });
});

test("a bad region update is reported and patches nothing", () => {
  const t = setup();
  const a = element({ innerHTML: "keep" });
  t.regions.cart = [a];
  t.sink().event("weberl:region", "not json");
  t.sink().event("weberl:region", JSON.stringify({ region: "cart" }));
  t.sink().event("weberl:region", JSON.stringify({ region: 5, html: "x" }));
  assert.equal(a.innerHTML, "keep");
  assert.equal(t.errors.length, 3);
  assert.deepEqual(t.documentEvents, []);
});

test("the focused field inside a region keeps focus and selection", () => {
  const t = setup();
  const input = element({ id: "q", selectionStart: 2, selectionEnd: 4 });
  const region1 = element({ children: [input] });
  t.regions.search = [region1];
  t.document.activeElement = input;
  const fresh = element({ id: "q", focused: false, range: null,
    focus() { this.focused = true; },
    setSelectionRange(s, e) { this.range = [s, e]; } });
  t.elements.q = fresh;
  t.sink().event("weberl:region", region("search", "<input id=q>"));
  assert.equal(fresh.focused, true);
  assert.deepEqual(fresh.range, [2, 4]);
});

test("focus outside the region is left alone", () => {
  const t = setup();
  const outside = element({ id: "o" });
  t.regions.r = [element()];
  t.document.activeElement = outside;
  t.elements.o = element({ focus() { throw new Error("must not move focus"); } });
  t.sink().event("weberl:region", region("r", "x"));
});

test("the weberl-region element shows its children", () => {
  const t = setup();
  assert.ok(t.defined["weberl-region"], "defined");
  const el = element();
  t.defined["weberl-region"].prototype.connectedCallback.call(el);
  assert.equal(el.style.display, "contents");
});

// ---- the hub ------------------------------------------------------------

test("a stale hub is warned about and reported as an event", () => {
  const t = setup();
  const seen = [];
  t.sandbox.Weberl.on("weberl_stale", (d) => seen.push(d));
  t.sharedOptions[0].stale({ hub: 2, page: 1 });
  assert.equal(t.warnings.length, 1);
  assert.match(t.warnings[0], /hub 2, page 1/);
  assert.deepEqual(JSON.parse(JSON.stringify(seen)), [{ hub: 2, page: 1 }]);
  assert.deepEqual(t.types(), ["weberl:stale"]);
});

test("leaving the page tells the hub, unless the page goes to the back/forward cache", () => {
  const t = setup();
  const [onHide] = t.windowListeners.pagehide;
  onHide({ persisted: true });
  assert.equal(t.hub.closed, 0);
  onHide({ persisted: false });
  assert.equal(t.hub.closed, 1);
});
