// A "hub" of another version, for the browser tests: it only says hello with a
// version the page's scripts do not have (see WeberlEngine.shared in engine.js).
importScripts("/_weberl/engine.js");
self.onconnect = function (event) {
  event.ports[0].postMessage({ hello: 3 });
};
