/*
 * Weberl transport engine.
 *
 * Owns every connection of live pages: one multiplexed WebSocket shared by all
 * the pages that use it, a Server-Sent Events stream per page, and long-poll
 * as the fallback, with reconnect/backoff. It never touches the DOM (only
 * WebSocket, EventSource, fetch, timers and location), so it runs in a window
 * or in a worker.
 *
 * The engine IS the "Hub" interface of the beacon (client.js): a hub hosts the
 * connections of the pages subscribed to it. WeberlEngine.create() is an
 * in-page hub (one connection per tab); WeberlEngine.shared() is the same
 * interface backed by a SharedWorker (hub.js, which runs one engine for all the
 * tabs of the origin with WeberlEngine.serve) and falls back to an in-page
 * engine when there is no SharedWorker, it fails, or it runs another version
 * (see the end of this file for the messages).
 *
 *   var hub = WeberlEngine.create();
 *   var sub = hub.subscribe(page, sink);
 *     page: { id, token, kind: "one_way" | "two_way", fallback: "poll" | "none",
 *             topics: [string] (optional: the topics the page subscribed to) }
 *     sink: callbacks, all optional:
 *       event(name, data, topic)  a server push; topic is set when it was published
 *                            to a topic (a snapshot from handle_subscribe/2 is a
 *                            plain page event)
 *       connected(transport) the page is receiving ("ws" | "sse" | "poll")
 *       transport(name)      the transport in use changed
 *       closed(reason)       the page ended and will not reconnect:
 *                            "closed" (session ended), "replaced" (another
 *                            connection took the page), "refused" (unknown
 *                            page or bad token), "client" (sub.close())
 *   sub.request(name, data)  Promise: the reply (true if the handler had none);
 *                            rejects with an Error carrying .reason/.status
 *   sub.close()              stop the page
 *   hub.close()              stop everything
 *
 * Transports: two_way pages use the shared WebSocket, one_way pages their own
 * SSE stream (create({oneWay: "ws"}), what the SharedWorker hub uses, puts
 * one_way pages on the shared socket too, so every page of every tab rides one
 * connection). After FAILURES failed connection attempts in a row a page whose
 * fallback is "poll" switches to long-poll. Reconnects back off exponentially
 * with jitter. Frame formats: see weberl_live_wire.erl.
 *
 * Topics: a published event is one frame per connection, tagged by topic; the
 * engine hands it to each WebSocket page whose `topics` contain it (a page that
 * has its own SSE stream or polls receives only its own events and topics, so
 * it needs no filter). Reconnecting makes the server send the snapshots again
 * (WebSocket resubscribe, new SSE stream); long-poll asks for them on its first
 * poll and on the first one after a failure.
 */
(function (global) {
  "use strict";

  if (global.WeberlEngine) { return; }

  // Protocol/build version the client declares to the server (`v' query
  // parameter on every connection start) and a hub announces to the tabs that
  // join it. The server logs a connection whose version it does not know.
  var VERSION = 1;
  var FAILURES = 3;            // failed connection attempts before falling back
  var BASE_DELAY = 500;        // ms, first reconnect delay
  var MAX_DELAY = 30000;       // ms
  var REQUEST_TIMEOUT = 15000; // ms, for requests over the socket
  var enc = encodeURIComponent;

  function backoff(attempt) {
    var d = Math.min(MAX_DELAY, BASE_DELAY * Math.pow(2, attempt - 1));
    return d / 2 + Math.random() * d / 2;
  }

  function requestError(reason, status) {
    var err = new Error("weberl request failed: " + reason);
    err.reason = reason;
    err.status = status;
    return err;
  }

  function noop() {}

  function create(options) {
    options = options || {};
    var base = options.base || "/_weberl/";
    var loc = options.location || global.location;
    // The transport of one_way pages: their own SSE stream, or (a hub shared by
    // several tabs: options.oneWay = "ws") the one socket every page shares.
    var oneWay = options.oneWay === "ws" ? "ws" : "sse";

    var pages = {};          // id -> page record
    var sock = null;         // the shared WebSocket
    var sockOpen = false;
    var sockFailures = 0;    // consecutive socket failures, reset on a subscribe
    var sockTimer = null;    // pending reconnect of the socket
    var shut = false;

    // ---- helpers --------------------------------------------------------

    function pageList() {
      return Object.keys(pages).map(function (id) { return pages[id]; });
    }

    function wsPages() {
      return pageList().filter(function (p) { return p.transport === "ws"; });
    }

    function send(obj) {
      if (sock && sockOpen) { sock.send(JSON.stringify(obj)); }
    }

    function rejectPending(p, err) {
      Object.keys(p.pending).forEach(function (ref) {
        var pend = p.pending[ref];
        delete p.pending[ref];
        clearTimeout(pend.timer);
        pend.reject(err);
      });
    }

    // ---- switching a page between transports ---------------------------

    function teardown(p) {
      clearTimeout(p.timer);
      p.timer = null;
      if (p.source) {
        p.source.onopen = p.source.onerror = p.source.onmessage = null;
        p.source.close();
        p.source = null;
      }
      if (p.abort) { p.abort.abort(); p.abort = null; }
      if (p.transport === "ws") {
        if (p.subscribed) { send({ op: "unsubscribe", page: p.page.id }); }
        p.subscribed = false;
        rejectPending(p, new Error("weberl transport changed"));
      }
    }

    function use(p, name) {
      teardown(p);
      p.transport = name;
      p.failures = 0;
      p.sink.transport(name);
      if (name === "ws") {
        if (!sock && !sockTimer) { openSocket(); }
        if (sockOpen) { subscribeFrame(p); }
      } else if (name === "sse") {
        openSource(p);
      } else {
        p.needSnapshot = true;
        poll(p);
      }
      if (name !== "ws") { maybeCloseSocket(); }
    }

    function stopPage(p, reason) {
      if (p.stopped) { return; }
      p.stopped = true;
      teardown(p);
      delete pages[p.page.id];
      rejectPending(p, new Error("weberl closed"));
      maybeCloseSocket();
      p.sink.closed(reason);
    }

    // ---- the shared WebSocket -------------------------------------------

    function subscribeFrame(p) {
      send({ op: "subscribe", page: p.page.id, token: p.page.token });
    }

    function openSocket() {
      sockTimer = null;
      if (sock || shut || wsPages().length === 0) { return; }
      var scheme = loc.protocol === "https:" ? "wss://" : "ws://";
      var ws;
      try { ws = new WebSocket(scheme + loc.host + base + "ws?v=" + VERSION); }
      catch (e) { socketDown(); return; }
      sock = ws;
      ws.onopen = function () {
        if (sock !== ws) { return; }
        sockOpen = true;
        wsPages().forEach(subscribeFrame);
      };
      ws.onmessage = function (ev) {
        if (sock === ws) { onFrame(ev.data); }
      };
      ws.onclose = function () {
        if (sock === ws) { socketDown(); }
      };
    }

    // The socket is gone (closed, or never opened): its pages are no longer
    // subscribed. Fall back where allowed, otherwise reconnect with backoff.
    function socketDown() {
      sock = null;
      sockOpen = false;
      wsPages().forEach(function (p) {
        p.subscribed = false;
        rejectPending(p, new Error("weberl socket closed"));
      });
      if (shut) { return; }
      sockFailures += 1;
      if (sockFailures >= FAILURES) {
        wsPages().forEach(function (p) {
          if (p.page.fallback === "poll") { use(p, "poll"); }
        });
      }
      if (wsPages().length > 0) {
        clearTimeout(sockTimer);
        sockTimer = setTimeout(openSocket, backoff(sockFailures));
      }
    }

    function maybeCloseSocket() {
      if (wsPages().length > 0) { return; }
      clearTimeout(sockTimer);
      sockTimer = null;
      if (sock) {
        var s = sock;
        sock = null;
        sockOpen = false;
        s.onopen = s.onmessage = s.onclose = null;
        try { s.close(); } catch (e) { /* already closed */ }
      }
    }

    // A topic event names no page: it arrives once per connection and goes to
    // every page of this engine that subscribed to the topic.
    function topicEvent(f) {
      pageList().forEach(function (p) {
        if (!p.stopped && p.transport === "ws" && p.subscribed &&
            (p.page.topics || []).indexOf(f.topic) >= 0) {
          p.sink.event(f.event, f.data, f.topic);
        }
      });
    }

    function onFrame(text) {
      var f;
      try { f = JSON.parse(text); } catch (e) { return; }
      if (f && f.topic !== undefined && f.page === undefined) { topicEvent(f); return; }
      var p = f && pages[f.page];
      if (!p || p.stopped || p.transport !== "ws") { return; }
      if (f.subscribed) {
        p.subscribed = true;
        p.failures = 0;
        sockFailures = 0;
        p.sink.connected("ws");
      } else if (f.event !== undefined) {
        p.sink.event(f.event, f.data);
      } else if (f.closed !== undefined) {
        stopPage(p, f.closed);
      } else if (f.error !== undefined && f.ref === undefined) {
        stopPage(p, "refused");                 // answer to a subscribe
      } else if (f.ref !== undefined) {
        answer(p, f);
      }
    }

    function answer(p, f) {
      var pend = p.pending[f.ref];
      if (!pend) { return; }
      delete p.pending[f.ref];
      clearTimeout(pend.timer);
      if (f.error !== undefined) { pend.reject(requestError(f.error, null)); }
      else if (f.reply !== undefined) { pend.resolve(f.reply); }
      else { pend.resolve(true); }
    }

    // ---- Server-Sent Events (one stream per page) ----------------------

    function openSource(p) {
      var es = new EventSource(base + "sse/" + enc(p.page.id) + "?t=" + enc(p.page.token) + "&v=" + VERSION);
      var opened = false;
      p.source = es;
      es.onopen = function () {
        opened = true;
        p.failures = 0;
        p.sink.connected("sse");
      };
      es.onmessage = function (ev) {
        var m;
        try { m = JSON.parse(ev.data); } catch (e) { return; }
        if (m && m.event !== undefined) { p.sink.event(m.event, m.data, m.topic); }
      };
      es.onerror = function () {
        if (p.source !== es) { return; }
        // CLOSED: the browser gave up on the stream. That is what a refusal by the
        // server looks like (page ended or unknown, bad token), but Firefox also
        // closes a stream whose connection failed, and the EventSource does not say
        // which. With long-poll allowed, ask it: a refusal answers 403/404 there and
        // ends the page as refused, a network failure just goes on polling.
        if (es.readyState === EventSource.CLOSED) {
          if (p.page.fallback === "poll") { use(p, "poll"); } else { stopPage(p, "refused"); }
          return;
        }
        // CONNECTING: EventSource retries by itself; count the attempts that
        // never connected so a broken path can fall back to long-poll.
        if (!opened) {
          p.failures += 1;
          if (p.failures >= FAILURES && p.page.fallback === "poll") { use(p, "poll"); }
        } else {
          opened = false;
        }
      };
    }

    // ---- long-poll ------------------------------------------------------

    function poll(p) {
      if (p.stopped || p.transport !== "poll") { return; }
      var abort = new AbortController();
      var started = Date.now();
      p.abort = abort;
      // The first poll, and the first one after a failed poll, asks for the
      // snapshots of the page's topics (events published between two polls are
      // lost, so a poll that follows a gap starts from a fresh state).
      // That poll also declares the client version (a poll that starts a
      // connection, as far as the server is concerned).
      var snapshot = p.needSnapshot ? "?snapshot=1&v=" + VERSION : "";
      fetch(base + "poll/" + enc(p.page.id) + snapshot, {
        headers: { "x-weberl-token": p.page.token },
        cache: "no-store",
        signal: abort.signal
      }).then(function (res) {
        if (res.status === 403 || res.status === 404) { stopPage(p, "refused"); return null; }
        if (!res.ok) { throw new Error("poll " + res.status); }
        return res.json();
      }).then(function (body) {
        if (body === null || p.stopped || p.abort !== abort) { return; }
        p.failures = 0;
        p.needSnapshot = false;
        if (!p.polled) { p.polled = true; p.sink.connected("poll"); }
        (body.events || []).forEach(function (e) { p.sink.event(e.event, e.data, e.topic); });
        if (body.closed) { stopPage(p, "closed"); return; }
        // A quick empty answer means this poll was replaced: do not spin.
        var quick = Date.now() - started < 250 && !(body.events || []).length;
        p.timer = setTimeout(function () { poll(p); }, quick ? 1000 : 0);
      }).catch(function (err) {
        if ((err && err.name === "AbortError") || p.stopped || p.abort !== abort) { return; }
        p.polled = false;
        p.needSnapshot = true;
        p.failures += 1;
        p.timer = setTimeout(function () { poll(p); }, backoff(p.failures));
      });
    }

    // ---- requests -------------------------------------------------------

    function request(p, name, data) {
      if (p.stopped || shut) { return Promise.reject(new Error("weberl closed")); }
      var body = data === undefined ? null : data;
      if (p.transport === "ws" && p.subscribed && sockOpen) {
        return new Promise(function (resolve, reject) {
          var ref = String(p.nextRef++);
          var timer = setTimeout(function () {
            delete p.pending[ref];
            reject(requestError("timeout", null));
          }, REQUEST_TIMEOUT);
          p.pending[ref] = { resolve: resolve, reject: reject, timer: timer };
          send({ op: "request", page: p.page.id, request: name, data: body, ref: ref });
        });
      }
      return fetch(base + "request/" + enc(p.page.id), {
        method: "POST",
        headers: { "content-type": "application/json", "x-weberl-token": p.page.token },
        body: JSON.stringify({ request: name, data: body })
      }).then(function (res) {
        return res.json().catch(function () { return {}; }).then(function (answerBody) {
          if (!res.ok) {
            throw requestError(answerBody.error || "http_" + res.status, res.status);
          }
          return answerBody.reply !== undefined ? answerBody.reply : true;
        });
      });
    }

    // ---- the hub interface ---------------------------------------------

    return {
      subscribe: function (page, sink) {
        if (shut) { throw new Error("weberl engine closed"); }
        if (pages[page.id]) { throw new Error("weberl page already subscribed"); }
        var s = sink || {};
        var p = {
          page: page,
          sink: {
            event: s.event || noop,
            connected: s.connected || noop,
            transport: s.transport || noop,
            closed: s.closed || noop
          },
          transport: null, failures: 0, subscribed: false, stopped: false,
          pending: {}, nextRef: 1, source: null, abort: null, timer: null, polled: false,
          needSnapshot: false
        };
        pages[page.id] = p;
        use(p, page.kind === "two_way" ? "ws" : oneWay);
        return {
          request: function (name, data) { return request(p, name, data); },
          close: function () { stopPage(p, "client"); },
          get transport() { return p.transport; }
        };
      },
      close: function () {
        shut = true;
        pageList().forEach(function (p) { stopPage(p, "client"); });
        clearTimeout(sockTimer);
        maybeCloseSocket();
      }
    };
  }

  // ---- sharing an engine between tabs (SharedWorker) -----------------------
  //
  // Worker side: serve(engine, port) lets the tab at the other end of `port'
  // use `engine' through messages. Tab side: shared(options) is a hub with the
  // same interface that talks to the SharedWorker (priv/hub.js) and, when that
  // is not possible, is an in-page engine.
  //
  // Messages, tab -> hub:
  //   {op: "subscribe", page}  {op: "request", page: id, name, data, ref}
  //   {op: "close", page: id}  {op: "bye"} (the tab is going away)
  // hub -> tab:
  //   {hello: VERSION}  sent once, first: the tab compares it with its own
  //   {page: id, sink: "event"|"connected"|"transport"|"closed", args: [...]}
  //   {ref, reply} | {ref, error: {reason, status}}   answer to a request
  // A page ends with its tab's "bye" (or "close"): a SharedWorker is not told
  // when a tab disappears without sending one, so those pages live on in the
  // worker until the server ends them.

  var SINKS = ["event", "connected", "transport", "closed"];

  function serve(engine, port) {
    var subs = {};
    function out(msg) {
      try { port.postMessage(msg); } catch (e) { /* the port is gone */ }
    }
    function sinkFor(id) {
      var sink = {};
      SINKS.forEach(function (name) {
        sink[name] = function () {
          if (name === "closed") { delete subs[id]; }
          out({ page: id, sink: name, args: Array.prototype.slice.call(arguments) });
        };
      });
      return sink;
    }
    function release() {
      Object.keys(subs).forEach(function (id) {
        var s = subs[id];
        delete subs[id];
        s.close();
      });
    }
    port.onmessage = function (ev) {
      var m = ev.data || {};
      var s = subs[m.page];
      if (m.op === "subscribe" && m.page && m.page.id) {
        var id = m.page.id;
        if (subs[id]) { return; }
        try { subs[id] = engine.subscribe(m.page, sinkFor(id)); }
        catch (e) { out({ page: id, sink: "closed", args: ["refused"] }); }
      } else if (m.op === "request") {
        if (!s) { out({ ref: m.ref, error: { reason: "closed", status: null } }); return; }
        s.request(m.name, m.data).then(
          function (reply) { out({ ref: m.ref, reply: reply }); },
          function (err) {
            out({ ref: m.ref, error: { reason: (err && err.reason) || String(err && err.message),
                                       status: (err && err.status) || null } });
          });
      } else if (m.op === "close") {
        if (s) { delete subs[m.page]; s.close(); }
      } else if (m.op === "bye") {
        release();
      }
    };
    out({ hello: VERSION });
  }

  function shared(options) {
    options = options || {};
    var base = options.base || "/_weberl/";
    var Ctor = options.SharedWorker || global.SharedWorker;
    var log = options.console || global.console;
    var recs = {};        // page id -> {page, sink, sub (the fallback engine's)}
    var pending = {};     // ref -> {resolve, reject, msg, sent}
    var queue = [];       // messages for the hub until it said hello
    var nextRef = 1;
    var local = null;     // the in-page engine once the hub is given up on
    var port = null, ready = false, shut = false, timer = null;

    function post(msg) {
      if (ready) { port.postMessage(msg); } else { queue.push(msg); }
    }

    function hello() {
      ready = true;
      clearTimeout(timer);
      queue.splice(0).forEach(function (msg) {
        if (msg.ref !== undefined && pending[msg.ref]) { pending[msg.ref].sent = true; }
        port.postMessage(msg);
      });
    }

    // Give the hub up: from now on this tab runs its own engine. `reason' is
    // "unsupported" (no SharedWorker, silent), "version" (the worker runs
    // another build: also reported to the page through options.stale),
    // "error" or "timeout".
    function fallback(reason, detail) {
      if (local || shut) { return; }
      clearTimeout(timer);
      if (port) {
        try { port.postMessage({ op: "bye" }); } catch (e) { /* gone */ }
        port.onmessage = null;
        try { port.close(); } catch (e) { /* gone */ }
        port = null;
      }
      ready = false;
      queue = [];
      if (reason !== "unsupported" && log) {
        log.warn("weberl: not using the shared hub (" + reason + ")" +
                 (detail ? " " + JSON.stringify(detail) : "") +
                 "; this tab keeps its own connection");
      }
      if (reason === "version" && options.stale) { options.stale(detail); }
      local = create(options);
      Object.keys(recs).forEach(function (id) {
        recs[id].sub = local.subscribe(recs[id].page, recs[id].sink);
      });
      // Requests the hub never got are asked again here, the others are lost.
      Object.keys(pending).forEach(function (ref) {
        var pend = pending[ref];
        delete pending[ref];
        var rec = recs[pend.msg.page];
        if (!pend.sent && rec && rec.sub) {
          rec.sub.request(pend.msg.name, pend.msg.data).then(pend.resolve, pend.reject);
        } else {
          pend.reject(requestError("hub_unavailable", null));
        }
      });
    }

    function onMessage(ev) {
      var m = ev.data || {};
      if (m.hello !== undefined) {
        if (m.hello === VERSION) { hello(); }
        else { fallback("version", { hub: m.hello, page: VERSION }); }
        return;
      }
      if (!ready) { return; }
      if (m.ref !== undefined) {
        var pend = pending[m.ref];
        if (!pend) { return; }
        delete pending[m.ref];
        if (m.error) { pend.reject(requestError(m.error.reason, m.error.status)); }
        else { pend.resolve(m.reply === undefined ? true : m.reply); }
        return;
      }
      var rec = recs[m.page];
      if (!rec || SINKS.indexOf(m.sink) < 0) { return; }
      if (m.sink === "closed") { delete recs[m.page]; }
      rec.sink[m.sink].apply(null, m.args || []);
    }

    if (typeof Ctor !== "function") {
      local = create(options);
    } else {
      try {
        var worker = new Ctor(options.workerUrl || base + "hub.js", { name: "weberl-hub" });
        port = worker.port;
        worker.onerror = function () { fallback("error"); };
        port.onmessage = onMessage;
        if (port.start) { port.start(); }
        timer = setTimeout(function () { fallback("timeout"); }, options.helloTimeout || 5000);
      } catch (e) {
        port = null;
        fallback("unsupported");
      }
    }

    return {
      subscribe: function (page, sink) {
        if (shut) { throw new Error("weberl engine closed"); }
        if (local) { return local.subscribe(page, sink); }
        if (recs[page.id]) { throw new Error("weberl page already subscribed"); }
        var s = sink || {};
        var rec = { page: page, sub: null, sink: {} };
        SINKS.forEach(function (name) { rec.sink[name] = s[name] || noop; });
        recs[page.id] = rec;
        // keep the transport the hub reported readable on the subscription
        var transport = null;
        var original = rec.sink.transport;
        rec.sink.transport = function (name) { transport = name; original(name); };
        post({ op: "subscribe", page: page });
        var sub = {
          request: function (name, data) {
            if (rec.sub) { return rec.sub.request(name, data); }
            if (shut || !recs[page.id]) { return Promise.reject(new Error("weberl closed")); }
            return new Promise(function (resolve, reject) {
              var msg = { op: "request", page: page.id, name: name,
                          data: data === undefined ? null : data, ref: nextRef++ };
              pending[msg.ref] = { resolve: resolve, reject: reject, msg: msg, sent: ready };
              post(msg);
            });
          },
          close: function () {
            if (rec.sub) { rec.sub.close(); return; }
            if (!recs[page.id]) { return; }
            delete recs[page.id];
            post({ op: "close", page: page.id });
            rec.sink.closed("client");
          },
          get transport() { return rec.sub ? rec.sub.transport : transport; }
        };
        return sub;
      },
      close: function () {
        if (shut) { return; }
        if (local) { shut = true; local.close(); return; }
        shut = true;
        clearTimeout(timer);
        if (port) {
          try { port.postMessage({ op: "bye" }); port.close(); } catch (e) { /* gone */ }
        }
        Object.keys(recs).forEach(function (id) {
          var rec = recs[id];
          delete recs[id];
          rec.sink.closed("client");
        });
        Object.keys(pending).forEach(function (ref) {
          pending[ref].reject(new Error("weberl closed"));
          delete pending[ref];
        });
      }
    };
  }

  global.WeberlEngine = { create: create, serve: serve, shared: shared, version: VERSION };
})(typeof self !== "undefined" ? self : this);
