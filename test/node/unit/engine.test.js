// Unit tests for priv/engine.js against fake WebSocket, EventSource, fetch and
// timers. Run through test/e2e/run.sh (or `npm run unit` in the test container).
"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");

const SOURCE = require("./source")("engine.js");
const flush = () => new Promise((resolve) => setImmediate(resolve));

// A response as fetch resolves it.
const reply = (body, status = 200) => ({
  status,
  ok: status >= 200 && status < 300,
  json: () => Promise.resolve(body),
});

// Loads the engine into a fresh context with fakes the test controls.
function harness(location = { protocol: "http:", host: "example.test" }) {
  const sockets = [], sources = [], fetches = [], timers = [];
  let now = 0, nextTimer = 1;

  class FakeWebSocket {
    constructor(url) { this.url = url; this.sent = []; this.closed = false; sockets.push(this); }
    send(data) { this.sent.push(JSON.parse(data)); }
    close() { this.closed = true; }
    open() { this.onopen(); }
    message(frame) { this.onmessage({ data: typeof frame === "string" ? frame : JSON.stringify(frame) }); }
    drop() { this.onclose(); }
  }

  class FakeEventSource {
    constructor(url) { this.url = url; this.readyState = 0; this.closed = false; sources.push(this); }
    close() { this.closed = true; this.readyState = 2; }
    open() { this.readyState = 1; this.onopen(); }
    message(data) { this.onmessage({ data: typeof data === "string" ? data : JSON.stringify(data) }); }
    fail(refused) { this.readyState = refused ? 2 : 0; this.onerror(); }
  }
  FakeEventSource.CLOSED = 2;

  function fakeFetch(url, opts) {
    return new Promise((resolve, reject) => {
      fetches.push({ url, opts, resolve, reject });
      if (opts && opts.signal) {
        opts.signal.addEventListener("abort", () => {
          const err = new Error("aborted");
          err.name = "AbortError";
          reject(err);
        });
      }
    });
  }

  const sandbox = {
    WebSocket: FakeWebSocket,
    EventSource: FakeEventSource,
    fetch: fakeFetch,
    AbortController,
    JSON, Promise, Error,
    encodeURIComponent,
    Date: { now: () => now },
    Math: Object.assign(Object.create(Math), { random: () => 0 }),
    setTimeout: (fn, ms) => {
      const id = nextTimer++;
      timers.push({ id, at: now + (ms || 0), fn });
      return id;
    },
    clearTimeout: (id) => {
      const i = timers.findIndex((t) => t.id === id);
      if (i >= 0) { timers.splice(i, 1); }
    },
  };
  vm.runInNewContext(SOURCE, sandbox);

  return {
    sockets, sources, fetches,
    lib: sandbox.WeberlEngine,
    location,
    engine: sandbox.WeberlEngine.create({ location }),
    // Advance the fake clock, running the timers that come due.
    tick(ms) {
      const target = now + ms;
      for (;;) {
        const due = timers.filter((t) => t.at <= target).sort((a, b) => a.at - b.at || a.id - b.id)[0];
        if (!due) { break; }
        timers.splice(timers.indexOf(due), 1);
        now = due.at;
        due.fn();
      }
      now = target;
    },
  };
}

// A sink that records what the engine tells the page.
function recorder() {
  const log = [];
  return {
    log,
    sink: {
      // the topic is only recorded when the event came from a topic
      event: (name, data, topic) =>
        log.push(topic === undefined ? ["event", name, data] : ["event", name, data, topic]),
      connected: (t) => log.push(["connected", t]),
      reconnecting: () => log.push(["reconnecting"]),
      transport: (t) => log.push(["transport", t]),
      closed: (r) => log.push(["closed", r]),
    },
  };
}

const page = (id, kind, fallback = "poll", topics = []) =>
  ({ id, token: "tok-" + id, kind, fallback, topics });

// A two_way page whose socket opened and subscribed.
function connectedWs(h, id = "p1", fallback = "poll") {
  const rec = recorder();
  const sub = h.engine.subscribe(page(id, "two_way", fallback), rec.sink);
  const sock = h.sockets[h.sockets.length - 1];
  sock.open();
  sock.message({ page: id, subscribed: true });
  return { rec, sub, sock };
}

// A one_way page pushed onto long-poll by three failed stream attempts.
function polling(h, id = "p1") {
  const rec = recorder();
  const sub = h.engine.subscribe(page(id, "one_way"), rec.sink);
  const es = h.sources[h.sources.length - 1];
  es.fail(); es.fail(); es.fail();
  return { rec, sub };
}

// ---- WebSocket ---------------------------------------------------------------

test("two_way: connects, subscribes with the token and reports connected", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "two_way"), rec.sink);
  assert.equal(h.sockets.length, 1);
  assert.equal(h.sockets[0].url, "ws://example.test/_weberl/ws?v=2");
  assert.deepEqual(rec.log, [["transport", "ws"]]);
  h.sockets[0].open();
  assert.deepEqual(h.sockets[0].sent, [{ op: "subscribe", page: "p1", token: "tok-p1" }]);
  h.sockets[0].message({ page: "p1", subscribed: true });
  assert.deepEqual(rec.log.at(-1), ["connected", "ws"]);
});

test("two_way: wss when the page is https", () => {
  const h = harness({ protocol: "https:", host: "secure.test" });
  h.engine.subscribe(page("p1", "two_way"), recorder().sink);
  assert.equal(h.sockets[0].url, "wss://secure.test/_weberl/ws?v=2");
});

test("events are delivered to the page named in the frame", () => {
  const h = harness();
  const a = connectedWs(h, "p1");
  const b = (() => {
    const rec = recorder();
    h.engine.subscribe(page("p2", "two_way"), rec.sink);
    h.sockets[0].message({ page: "p2", subscribed: true });
    return rec;
  })();
  h.sockets[0].message({ page: "p2", event: "tick", data: "d" });
  h.sockets[0].message({ page: "p1", event: "tock", data: { n: 1 } });
  assert.deepEqual(b.log.filter((e) => e[0] === "event"), [["event", "tick", "d"]]);
  assert.deepEqual(a.rec.log.filter((e) => e[0] === "event"), [["event", "tock", { n: 1 }]]);
  assert.equal(h.sockets.length, 1, "both pages share one socket");
});

test("junk frames and frames for unknown pages are ignored", () => {
  const h = harness();
  const { rec, sock } = connectedWs(h);
  const before = rec.log.length;
  sock.message("not json");
  sock.message({ page: "other", event: "x", data: 1 });
  sock.message({});
  assert.equal(rec.log.length, before);
});

test("closed and replaced end only that page", () => {
  const h = harness();
  const a = connectedWs(h, "p1");
  const rec = recorder();
  h.engine.subscribe(page("p2", "two_way"), rec.sink);
  a.sock.message({ page: "p2", subscribed: true });
  a.sock.message({ page: "p1", closed: "replaced" });
  assert.deepEqual(a.rec.log.at(-1), ["closed", "replaced"]);
  assert.equal(a.sock.closed, false, "the other page keeps the socket");
  a.sock.message({ page: "p2", closed: "closed" });
  assert.deepEqual(rec.log.at(-1), ["closed", "closed"]);
  assert.equal(a.sock.closed, true, "the last page closes the socket");
});

test("a subscribe answered with an error means refused", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "two_way"), rec.sink);
  h.sockets[0].open();
  h.sockets[0].message({ page: "p1", error: "forbidden" });
  assert.deepEqual(rec.log.at(-1), ["closed", "refused"]);
});

test("closing a page unsubscribes; the socket closes with the last page", () => {
  const h = harness();
  const a = connectedWs(h, "p1");
  const rec = recorder();
  const subB = h.engine.subscribe(page("p2", "two_way"), rec.sink);
  a.sock.message({ page: "p2", subscribed: true });
  a.sub.close();
  assert.deepEqual(a.sock.sent.at(-1), { op: "unsubscribe", page: "p1" });
  assert.deepEqual(a.rec.log.at(-1), ["closed", "client"]);
  assert.equal(a.sock.closed, false);
  subB.close();
  assert.equal(a.sock.closed, true);
});

test("requests over the socket carry a ref and resolve with the reply", async () => {
  const h = harness();
  const { sub, sock } = connectedWs(h);
  const answer = sub.request("save", { id: 7 });
  assert.deepEqual(sock.sent.at(-1), { op: "request", page: "p1", request: "save", data: { id: 7 }, ref: "1" });
  sock.message({ page: "p1", ref: "1", reply: { ok: true } });
  assert.deepEqual(await answer, { ok: true });

  const bare = sub.request("ping");
  assert.deepEqual(sock.sent.at(-1), { op: "request", page: "p1", request: "ping", data: null, ref: "2" });
  sock.message({ page: "p1", ref: "2", ok: true });
  assert.equal(await bare, true);

  const failing = sub.request("nope");
  sock.message({ page: "p1", ref: "3", error: "unsupported" });
  await assert.rejects(failing, { reason: "unsupported" });
});

test("a request that gets no answer times out", async () => {
  const h = harness();
  const { sub } = connectedWs(h);
  const answer = sub.request("slow");
  const rejected = assert.rejects(answer, { reason: "timeout" });
  h.tick(15000);
  await rejected;
});

test("a request before the page is subscribed goes over HTTP", async () => {
  const h = harness();
  const sub = h.engine.subscribe(page("p1", "two_way"), recorder().sink);
  const answer = sub.request("save", 1);
  assert.equal(h.fetches.length, 1);
  assert.equal(h.fetches[0].url, "/_weberl/request/p1");
  assert.equal(h.fetches[0].opts.method, "POST");
  assert.equal(h.fetches[0].opts.headers["x-weberl-token"], "tok-p1");
  assert.equal(h.fetches[0].opts.body, JSON.stringify({ request: "save", data: 1 }));
  h.fetches[0].resolve(reply({ reply: "r" }));
  assert.equal(await answer, "r");
});

test("socket loss rejects pending requests, reconnects and resubscribes", async () => {
  const h = harness();
  const { sub, sock } = connectedWs(h);
  const answer = sub.request("save");
  const rejected = assert.rejects(answer, /socket closed/);
  sock.drop();
  await rejected;
  assert.equal(h.sockets.length, 1);
  h.tick(250);                       // first backoff: 500ms base, jitter at its minimum
  assert.equal(h.sockets.length, 2);
  h.sockets[1].open();
  assert.deepEqual(h.sockets[1].sent, [{ op: "subscribe", page: "p1", token: "tok-p1" }]);
});

test("reconnecting: only for a page that was connected, once per drop, ends in connected", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "two_way", "none"), rec.sink);
  // never connected: the failed attempts are not "reconnecting"
  h.sockets[0].drop();
  h.tick(250);
  assert.equal(rec.log.some((e) => e[0] === "reconnecting"), false);
  h.sockets[1].open();
  h.sockets[1].message({ page: "p1", subscribed: true });
  assert.deepEqual(rec.log.at(-1), ["connected", "ws"]);
  // a drop of the good connection, then several failed retries: one notice
  h.sockets[1].drop();
  h.tick(250);
  h.sockets[2].drop();
  h.tick(500);
  h.sockets[3].drop();
  assert.deepEqual(rec.log.filter((e) => e[0] === "reconnecting"), [["reconnecting"]]);
  // it keeps retrying without limit and ends in connected
  h.tick(1000);
  h.sockets[4].open();
  h.sockets[4].message({ page: "p1", subscribed: true });
  assert.deepEqual(rec.log.slice(-2), [["reconnecting"], ["connected", "ws"]]);
  // and a later drop is announced again
  h.sockets[4].drop();
  assert.deepEqual(rec.log.at(-1), ["reconnecting"]);
});

test("reconnecting: a stream that drops after connecting, then closes for good and polls", async () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "one_way"), rec.sink);
  h.sources[0].fail();                       // never connected
  assert.equal(rec.log.some((e) => e[0] === "reconnecting"), false);
  h.sources[0].open();
  h.sources[0].fail();                       // EventSource retries by itself
  h.sources[0].fail();
  assert.deepEqual(rec.log.filter((e) => e[0] === "reconnecting"), [["reconnecting"]]);
  h.sources[0].open();
  assert.deepEqual(rec.log.at(-1), ["connected", "sse"]);
  // a stream that closes for good falls back to poll: still reconnecting until it polls
  h.sources[0].fail(true);
  assert.equal(rec.log.filter((e) => e[0] === "reconnecting").length, 2);
  assert.deepEqual(rec.log.at(-1), ["transport", "poll"]);
  h.fetches[0].resolve(reply({ events: [], closed: false }));
  await flush();
  assert.deepEqual(rec.log.at(-1), ["connected", "poll"]);
});

test("reconnecting: a poll that fails after polling well, ends in connected", async () => {
  const h = harness();
  const { rec } = polling(h);                // three failed streams: never connected
  assert.equal(rec.log.some((e) => e[0] === "reconnecting"), false);
  h.fetches[0].resolve(reply({ events: [{ event: "a", data: 1 }], closed: false }));
  await flush();
  h.tick(1000);
  h.fetches[1].reject(new Error("network"));
  await flush();
  assert.deepEqual(rec.log.at(-1), ["reconnecting"]);
  h.tick(250);
  h.fetches[2].resolve(reply({ events: [], closed: false }));
  await flush();
  assert.deepEqual(rec.log.slice(-2), [["reconnecting"], ["connected", "poll"]]);
});

test("three failed socket attempts fall back to long-poll when allowed", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "two_way", "poll"), rec.sink);
  h.sockets[0].drop();
  h.tick(250);
  h.sockets[1].drop();
  h.tick(500);
  h.sockets[2].drop();
  assert.deepEqual(rec.log.filter((e) => e[0] === "transport"), [["transport", "ws"], ["transport", "poll"]]);
  assert.equal(h.fetches.length, 1);
  assert.equal(h.fetches[0].url, "/_weberl/poll/p1?snapshot=1&v=2");
  assert.equal(h.fetches[0].opts.headers["x-weberl-token"], "tok-p1");
});

test("without fallback the socket keeps reconnecting", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "two_way", "none"), rec.sink);
  h.sockets[0].drop();
  h.tick(250);
  h.sockets[1].drop();
  h.tick(500);
  h.sockets[2].drop();
  h.tick(1000);
  assert.equal(h.sockets.length, 4);
  assert.equal(h.fetches.length, 0);
  assert.deepEqual(rec.log.filter((e) => e[0] === "transport"), [["transport", "ws"]]);
});

// ---- Server-Sent Events -------------------------------------------------------

test("one_way: opens a stream with the encoded token and reports events", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe({ id: "a b", token: "t/+=", kind: "one_way", fallback: "poll" }, rec.sink);
  assert.equal(h.sources[0].url, "/_weberl/sse/a%20b?t=t%2F%2B%3D&v=2");
  assert.equal(h.sockets.length, 0, "no socket for a one_way page");
  h.sources[0].open();
  h.sources[0].message({ event: "tick", data: "x" });
  h.sources[0].message("garbage");
  assert.deepEqual(rec.log, [["transport", "sse"], ["connected", "sse"], ["event", "tick", "x"]]);
});

test("one_way with oneWay: ws (the hub's engine) uses the shared socket, no stream", () => {
  const h = harness();
  const engine = h.lib.create({ location: h.location, oneWay: "ws" });
  const a = recorder(), b = recorder();
  engine.subscribe(page("a", "one_way"), a.sink);
  engine.subscribe(page("b", "one_way", "poll", ["room"]), b.sink);
  assert.equal(h.sources.length, 0, "no SSE stream");
  assert.equal(h.sockets.length, 1, "one socket for both pages");
  const sock = h.sockets[0];
  sock.open();
  assert.deepEqual(sock.sent.map((f) => f.page), ["a", "b"]);
  sock.message({ page: "a", subscribed: true });
  sock.message({ page: "b", subscribed: true });
  sock.message({ page: "a", event: "tick", data: 1 });
  sock.message({ topic: "room", event: "hi", data: 2 });
  assert.deepEqual(a.log.filter((e) => e[0] === "event"), [["event", "tick", 1]]);
  assert.deepEqual(b.log.filter((e) => e[0] === "event"), [["event", "hi", 2, "room"]]);
});

test("a closed stream without the poll fallback ends the page as refused", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "one_way", "none"), rec.sink);
  h.sources[0].fail(true);
  assert.deepEqual(rec.log.at(-1), ["closed", "refused"]);
  assert.equal(h.fetches.length, 0);
});

test("a closed stream (a refusal, or Firefox giving up on a failed connection) asks long-poll", async () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "one_way"), rec.sink);
  h.sources[0].fail(true);
  assert.deepEqual(rec.log.filter((e) => e[0] === "transport"), [["transport", "sse"], ["transport", "poll"]]);
  assert.equal(h.fetches.length, 1, "the poll asks");
  // the server really refused: the poll says so and the page ends
  h.fetches[0].resolve(reply({}, 403));
  await flush();
  assert.deepEqual(rec.log.at(-1), ["closed", "refused"]);
});

test("a closed stream after a network failure carries on by long-poll", async () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "one_way"), rec.sink);
  h.sources[0].fail(true);
  h.fetches[0].resolve(reply({ events: [{ event: "tick", data: 1 }], closed: false }));
  await flush();
  assert.deepEqual(rec.log.at(-1), ["event", "tick", 1]);
  assert.ok(!rec.log.some((e) => e[0] === "closed"));
});

test("three failed stream attempts fall back to long-poll", () => {
  const h = harness();
  const { rec } = polling(h);
  assert.deepEqual(rec.log.filter((e) => e[0] === "transport"), [["transport", "sse"], ["transport", "poll"]]);
  assert.equal(h.sources[0].closed, true);
  assert.equal(h.fetches.length, 1);
});

test("errors after a successful connection do not count as failed attempts", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "one_way"), rec.sink);
  const es = h.sources[0];
  es.open();
  es.fail(); es.fail(); es.fail();    // the first is the drop of a good connection
  assert.equal(h.fetches.length, 0);
  es.fail();
  assert.equal(h.fetches.length, 1);
});

test("without fallback a failing stream is left to EventSource", () => {
  const h = harness();
  h.engine.subscribe(page("p1", "one_way", "none"), recorder().sink);
  for (let i = 0; i < 10; i++) { h.sources[0].fail(); }
  assert.equal(h.fetches.length, 0);
  assert.equal(h.sources[0].closed, false);
});

test("requests from a one_way page go over HTTP", async () => {
  const h = harness();
  const sub = h.engine.subscribe(page("p1", "one_way"), recorder().sink);
  const answer = sub.request("vote", { n: 1 });
  assert.equal(h.fetches[0].url, "/_weberl/request/p1");
  h.fetches[0].resolve(reply({}));
  assert.equal(await answer, true);

  const refused = sub.request("vote");
  h.fetches[1].resolve(reply({ error: "unsupported" }, 404));
  await assert.rejects(refused, { reason: "unsupported", status: 404 });

  const odd = sub.request("vote");
  h.fetches[2].resolve({ status: 502, ok: false, json: () => Promise.reject(new Error("html")) });
  await assert.rejects(odd, { reason: "http_502", status: 502 });
});

// ---- long-poll ----------------------------------------------------------------

test("poll: delivers events, reports connected once and polls again", async () => {
  const h = harness();
  const { rec } = polling(h);
  h.fetches[0].resolve(reply({ events: [{ event: "a", data: 1 }, { event: "b", data: 2 }], closed: false }));
  await flush();
  assert.deepEqual(rec.log.slice(-3), [["connected", "poll"], ["event", "a", 1], ["event", "b", 2]]);
  h.tick(0);
  assert.equal(h.fetches.length, 2, "next poll starts at once after an answer with events");
  h.fetches[1].resolve(reply({ events: [{ event: "c", data: 3 }], closed: false }));
  await flush();
  assert.equal(rec.log.filter((e) => e[0] === "connected" && e[1] === "poll").length, 1);
});

test("poll: a quick empty answer waits before polling again", async () => {
  const h = harness();
  polling(h);
  h.fetches[0].resolve(reply({ events: [], closed: false }));
  await flush();
  h.tick(999);
  assert.equal(h.fetches.length, 1);
  h.tick(1);
  assert.equal(h.fetches.length, 2);
});

test("poll: closed ends the page", async () => {
  const h = harness();
  const { rec } = polling(h);
  h.fetches[0].resolve(reply({ events: [], closed: true }));
  await flush();
  assert.deepEqual(rec.log.at(-1), ["closed", "closed"]);
  h.tick(5000);
  assert.equal(h.fetches.length, 1, "no further polls");
});

test("poll: 403 and 404 mean refused", async () => {
  for (const status of [403, 404]) {
    const h = harness();
    const { rec } = polling(h);
    h.fetches[0].resolve(reply({}, status));
    await flush();
    assert.deepEqual(rec.log.at(-1), ["closed", "refused"]);
  }
});

test("poll: a failed request is retried with backoff", async () => {
  const h = harness();
  const { rec } = polling(h);
  h.fetches[0].reject(new Error("network"));
  await flush();
  h.tick(249);
  assert.equal(h.fetches.length, 1);
  h.tick(1);
  assert.equal(h.fetches.length, 2);
  h.fetches[1].resolve(reply({ events: [{ event: "a", data: 1 }], closed: false }));
  await flush();
  assert.deepEqual(rec.log.at(-1), ["event", "a", 1]);
});

test("poll: closing the page aborts the request in flight", async () => {
  const h = harness();
  const { rec, sub } = polling(h);
  sub.close();
  await flush();
  assert.deepEqual(rec.log.at(-1), ["closed", "client"]);
  h.tick(60000);
  assert.equal(h.fetches.length, 1);
});

// ---- the hub ------------------------------------------------------------------

test("closing the hub closes every page and the socket", () => {
  const h = harness();
  const a = connectedWs(h, "p1");
  const rec = recorder();
  h.engine.subscribe(page("p2", "one_way"), rec.sink);
  h.engine.close();
  assert.deepEqual(a.rec.log.at(-1), ["closed", "client"]);
  assert.deepEqual(rec.log.at(-1), ["closed", "client"]);
  assert.equal(a.sock.closed, true);
  assert.equal(h.sources[0].closed, true);
  assert.throws(() => h.engine.subscribe(page("p3", "one_way")), /closed/);
});

test("a page cannot be subscribed twice", () => {
  const h = harness();
  h.engine.subscribe(page("p1", "one_way"));
  assert.throws(() => h.engine.subscribe(page("p1", "one_way")), /already/);
});

test("requests after the page ended are rejected", async () => {
  const h = harness();
  const sub = h.engine.subscribe(page("p1", "one_way"));
  sub.close();
  await assert.rejects(sub.request("x"), /closed/);
});

// ---- topics -------------------------------------------------------------------

test("a topic frame goes to every page subscribed to the topic, once each", () => {
  const h = harness();
  const a = recorder(), b = recorder(), c = recorder();
  h.engine.subscribe(page("p1", "two_way", "poll", ["stock:ACME", "news"]), a.sink);
  h.engine.subscribe(page("p2", "two_way", "poll", ["stock:ACME"]), b.sink);
  h.engine.subscribe(page("p3", "two_way", "poll", ["news"]), c.sink);
  h.sockets[0].open();
  for (const id of ["p1", "p2", "p3"]) { h.sockets[0].message({ page: id, subscribed: true }); }
  h.sockets[0].message({ topic: "stock:ACME", event: "price", data: "101" });
  const events = (r) => r.log.filter((e) => e[0] === "event");
  assert.deepEqual(events(a), [["event", "price", "101", "stock:ACME"]]);
  assert.deepEqual(events(b), [["event", "price", "101", "stock:ACME"]]);
  assert.deepEqual(events(c), []);
  assert.equal(h.sockets.length, 1);
});

test("a topic frame does not reach a page that is not subscribed on the socket", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "two_way", "poll", ["t"]), rec.sink);
  h.sockets[0].open();            // no `subscribed` answer yet
  h.sockets[0].message({ topic: "t", event: "e", data: "d" });
  assert.deepEqual(rec.log.filter((e) => e[0] === "event"), []);
});

test("page events keep working next to topic events, snapshots are page events", () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "two_way", "poll", ["t"]), rec.sink);
  h.sockets[0].open();
  h.sockets[0].message({ page: "p1", subscribed: true });
  h.sockets[0].message({ page: "p1", event: "snap", data: "state" });
  h.sockets[0].message({ topic: "t", event: "tick", data: "1" });
  assert.deepEqual(rec.log.filter((e) => e[0] === "event"),
    [["event", "snap", "state"], ["event", "tick", "1", "t"]]);
});

test("a resubscribe after a reconnect asks again (the server sends the snapshots)", () => {
  const h = harness();
  connectedWs(h, "p1");
  h.sockets[0].drop();
  h.tick(250);
  h.sockets[1].open();
  assert.deepEqual(h.sockets[1].sent, [{ op: "subscribe", page: "p1", token: "tok-p1" }]);
});

test("sse and poll events carry the topic through", async () => {
  const h = harness();
  const rec = recorder();
  h.engine.subscribe(page("p1", "one_way", "poll", ["t"]), rec.sink);
  h.sources[0].open();
  h.sources[0].message({ topic: "t", event: "tick", data: "1" });
  h.sources[0].message({ event: "own", data: "2" });
  assert.deepEqual(rec.log.filter((e) => e[0] === "event"),
    [["event", "tick", "1", "t"], ["event", "own", "2"]]);

  const polled = polling(h, "p2");
  h.fetches[0].resolve(reply({ events: [{ topic: "t", event: "tick", data: "3" }], closed: false }));
  await flush();
  assert.deepEqual(polled.rec.log.at(-1), ["event", "tick", "3", "t"]);
});

test("poll asks for the snapshots on its first poll and after a failure only", async () => {
  const h = harness();
  polling(h);
  assert.equal(h.fetches[0].url, "/_weberl/poll/p1?snapshot=1&v=2");
  h.fetches[0].resolve(reply({ events: [{ event: "a", data: 1 }], closed: false }));
  await flush();
  h.tick(0);
  assert.equal(h.fetches[1].url, "/_weberl/poll/p1", "a normal poll does not ask");
  h.fetches[1].reject(new Error("network"));
  await flush();
  h.tick(250);
  assert.equal(h.fetches[2].url, "/_weberl/poll/p1?snapshot=1&v=2", "after a gap it asks again");
});

// ---- the shared hub (SharedWorker) -------------------------------------

// Two ends of a MessagePort: what one posts the other receives.
function portPair() {
  // Like a MessagePort, messages wait until the receiver has a handler.
  const mk = () => ({
    handler: null, inbox: [], posted: [], closed: false, peer: null,
    get onmessage() { return this.handler; },
    set onmessage(fn) {
      this.handler = fn;
      while (fn && this.inbox.length) { fn({ data: this.inbox.shift() }); }
    },
    postMessage(msg) {
      const m = structuredClone(msg);              // nothing is shared
      this.posted.push(structuredClone(msg));
      if (this.peer.handler) { this.peer.handler({ data: m }); } else { this.peer.inbox.push(m); }
    },
    close() { this.closed = true; },
  });
  const tab = mk(), hub = mk();
  tab.peer = hub;
  hub.peer = tab;
  return { tab, hub };
}

// A SharedWorker constructor whose worker is served by the harness's engine.
// Tabs created through it share that engine, as the browser's SharedWorker does.
function workerFor(h) {
  const ctor = function (url, opts) {
    ctor.created.push({ url, opts });
    const { tab, hub } = portPair();
    this.port = tab;
    h.lib.serve(h.engine, hub);
  };
  ctor.created = [];
  return ctor;
}

function consoleLog() {
  const warnings = [];
  return { warnings, warn: (...args) => warnings.push(args.join(" ")) };
}

test("serve: says hello, runs the tab's pages in the engine and forwards what happens", async () => {
  const h = harness();
  const { tab, hub } = portPair();
  h.lib.serve(h.engine, hub);
  assert.deepEqual(hub.posted[0], { hello: 2 });
  tab.postMessage({ op: "subscribe", page: page("p1", "one_way") });
  assert.equal(h.sources.length, 1);
  h.sources[0].open();
  h.sources[0].message({ event: "tick", data: 1 });
  h.sources[0].message({ event: "t", data: 2, topic: "room" });
  assert.deepEqual(hub.posted, [
    { hello: 2 },
    { page: "p1", sink: "transport", args: ["sse"] },
    { page: "p1", sink: "connected", args: ["sse"] },
    { page: "p1", sink: "event", args: ["tick", 1, undefined] },
    { page: "p1", sink: "event", args: ["t", 2, "room"] },
  ]);
});

test("serve: requests are answered, errors carry reason and status", async () => {
  const h = harness();
  const { tab, hub } = portPair();
  h.lib.serve(h.engine, hub);
  tab.postMessage({ op: "subscribe", page: page("p1", "one_way") });
  tab.postMessage({ op: "request", page: "p1", name: "save", data: { a: 1 }, ref: 7 });
  h.fetches[0].resolve(reply({ reply: "done" }));
  await flush();
  assert.deepEqual(hub.posted.at(-1), { ref: 7, reply: "done" });
  tab.postMessage({ op: "request", page: "p1", name: "bad", data: null, ref: 8 });
  h.fetches[1].resolve(reply({ error: "bad_request" }, 422));
  await flush();
  assert.deepEqual(hub.posted.at(-1), { ref: 8, error: { reason: "bad_request", status: 422 } });
  tab.postMessage({ op: "request", page: "nope", name: "x", data: null, ref: 9 });
  assert.deepEqual(hub.posted.at(-1), { ref: 9, error: { reason: "closed", status: null } });
});

test("serve: close and bye end the pages of that tab only", () => {
  const h = harness();
  const a = portPair(), b = portPair();
  h.lib.serve(h.engine, a.hub);
  h.lib.serve(h.engine, b.hub);
  a.tab.postMessage({ op: "subscribe", page: page("a1", "one_way") });
  a.tab.postMessage({ op: "subscribe", page: page("a2", "one_way") });
  b.tab.postMessage({ op: "subscribe", page: page("b1", "one_way") });
  a.tab.postMessage({ op: "close", page: "a1" });
  assert.equal(h.sources[0].closed, true);
  assert.equal(h.sources[1].closed, false);
  a.tab.postMessage({ op: "bye" });
  assert.equal(h.sources[1].closed, true);
  assert.equal(h.sources[2].closed, false, "the other tab's page is untouched");
});

test("serve: a page id that is already in use is refused", () => {
  const h = harness();
  const { tab, hub } = portPair();
  h.lib.serve(h.engine, hub);
  tab.postMessage({ op: "subscribe", page: page("p1", "one_way") });
  const other = portPair();
  h.lib.serve(h.engine, other.hub);
  other.tab.postMessage({ op: "subscribe", page: page("p1", "one_way") });
  assert.deepEqual(other.hub.posted.at(-1), { page: "p1", sink: "closed", args: ["refused"] });
});

test("shared: events, requests and close go through the hub", async () => {
  const h = harness();
  const W = workerFor(h);
  const log = consoleLog();
  const hub = h.lib.shared({ SharedWorker: W, console: log });
  assert.equal(W.created[0].url, "/_weberl/hub.js");
  assert.equal(W.created[0].opts.name, "weberl-hub");
  const rec = recorder();
  const sub = hub.subscribe(page("p1", "one_way"), rec.sink);
  h.sources[0].open();
  h.sources[0].message({ event: "tick", data: 5 });
  assert.deepEqual(rec.log, [["transport", "sse"], ["connected", "sse"], ["event", "tick", 5]]);
  assert.equal(sub.transport, "sse");
  const answer = sub.request("save", 1);
  h.fetches[0].resolve(reply({ reply: "ok" }));
  assert.equal(await answer, "ok");
  sub.close();
  assert.equal(h.sources[0].closed, true);
  assert.deepEqual(rec.log.at(-1), ["closed", "client"]);
  assert.deepEqual(log.warnings, []);
});

test("shared: tabs share one WebSocket and topic events reach each tab", () => {
  const h = harness();
  const W = workerFor(h);
  const tab1 = h.lib.shared({ SharedWorker: W, console: consoleLog() });
  const tab2 = h.lib.shared({ SharedWorker: W, console: consoleLog() });
  const r1 = recorder(), r2 = recorder();
  tab1.subscribe(page("p1", "two_way", "poll", ["room"]), r1.sink);
  tab2.subscribe(page("p2", "two_way", "poll", ["room", "other"]), r2.sink);
  assert.equal(h.sockets.length, 1, "one socket for both tabs");
  h.sockets[0].open();
  h.sockets[0].message({ page: "p1", subscribed: true });
  h.sockets[0].message({ page: "p2", subscribed: true });
  h.sockets[0].message({ topic: "room", event: "hi", data: 1 });
  h.sockets[0].message({ topic: "other", event: "yo", data: 2 });
  assert.deepEqual(r1.log.filter((e) => e[0] === "event"), [["event", "hi", 1, "room"]]);
  assert.deepEqual(r2.log.filter((e) => e[0] === "event"),
    [["event", "hi", 1, "room"], ["event", "yo", 2, "other"]]);
  tab1.close();
  assert.equal(h.sockets[0].closed, false, "the other tab keeps the socket");
  tab2.close();
  assert.equal(h.sockets[0].closed, true);
});

test("shared: a hub running another version is reported and the tab keeps its own engine", async () => {
  const h = harness();
  const log = consoleLog();
  const stale = [];
  // the worker's hello says version 3 (the engine in this context is 2)
  const ctor = function () {
    const { tab, hub } = portPair();
    this.port = tab;
    hub.onmessage = () => {};
    // hello comes after the tab attached its handler
    ctor.hub = hub;
  };
  const hub = h.lib.shared({ SharedWorker: ctor, console: log, stale: (i) => stale.push(i), location: h.location });
  const rec = recorder();
  const sub = hub.subscribe(page("p1", "one_way"), rec.sink);
  const pending = sub.request("early", 1);        // asked before the hub answered
  ctor.hub.postMessage({ hello: 3 });
  assert.deepEqual(structuredClone(stale), [{ hub: 3, page: 2 }]);
  assert.equal(log.warnings.length, 1);
  assert.match(log.warnings[0], /version/);
  // the page now runs in this tab's own engine: its stream, its request
  assert.equal(h.sources.length, 1, "this tab opened its own stream");
  h.fetches.at(-1).resolve(reply({ reply: "late" }));
  assert.equal(await pending, "late");
});

test("shared: no SharedWorker means an in-page engine, silently", () => {
  const h = harness();
  const log = consoleLog();
  const hub = h.lib.shared({ console: log, location: h.location });
  hub.subscribe(page("p1", "one_way"), recorder().sink);
  assert.equal(h.sources.length, 1);
  assert.deepEqual(log.warnings, []);
});

test("shared: a worker that fails to start or never answers is given up on", () => {
  for (const mode of ["error", "timeout", "throws"]) {
    const h = harness();
    const log = consoleLog();
    let created;
    const ctor = function () {
      if (mode === "throws") { throw new Error("blocked by CSP"); }
      this.port = portPair().tab;
      created = this;
    };
    const hub = h.lib.shared({ SharedWorker: ctor, console: log, location: h.location });
    const before = h.sources.length;
    const rec = recorder();
    hub.subscribe(page("p1", "one_way"), rec.sink);
    if (mode === "error") { created.onerror(); }
    if (mode === "timeout") { h.tick(5000); }
    assert.equal(h.sources.length, before + 1, mode + ": this tab opened its own stream");
    assert.equal(log.warnings.length, mode === "throws" ? 0 : 1, mode);
  }
});

test("shared: closing the hub tells the worker and ends the pages", () => {
  const h = harness();
  const W = workerFor(h);
  const hub = h.lib.shared({ SharedWorker: W, console: consoleLog() });
  const rec = recorder();
  hub.subscribe(page("p1", "one_way"), rec.sink);
  hub.close();
  assert.equal(h.sources[0].closed, true);
  assert.deepEqual(rec.log.at(-1), ["closed", "client"]);
  assert.throws(() => hub.subscribe(page("p2", "one_way"), recorder().sink));
});
