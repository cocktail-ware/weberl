/*
 * Weberl shared hub: the SharedWorker script. One instance per origin runs a
 * single transport engine (engine.js) for every tab, so all the live pages of
 * the browser share one WebSocket. Tabs reach it through WeberlEngine.shared()
 * (see engine.js); it never touches the DOM.
 *
 * Needs `worker-src 'self'' where a Content-Security-Policy is set.
 */
"use strict";

importScripts("/_weberl/engine.js");

// one_way pages too ride the shared socket: one connection for all the tabs
var weberlHubEngine = WeberlEngine.create({ oneWay: "ws" });

self.onconnect = function (ev) {
  WeberlEngine.serve(weberlHubEngine, ev.ports[0]);
};
