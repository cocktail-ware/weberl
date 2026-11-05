// Shared helpers of the browser specs.
"use strict";

const { expect } = require("@playwright/test");

const BASE = process.env.BASE_URL || "https://app.test:8443";

// What the app under test holds (sessions, websockets, streams).
async function stats(request) {
  const response = await request.get("/_test/stats");
  return response.json();
}

// Wait until the app holds no connection (the pages of earlier specs are gone).
async function idle(request) {
  await expect.poll(async () => {
    const s = await stats(request);
    return s.websockets + s.streams;
  }).toBe(0);
}

// Record the page's weberl:<name> DOM events (name, detail) in window.__events,
// from before the page's own scripts run, so nothing arrives unseen.
async function recordEvents(target, names) {
  await target.addInitScript((names) => {
    window.__events = [];
    for (const name of names) {
      document.addEventListener("weberl:" + name, (e) => window.__events.push([name, e.detail]));
    }
  }, names);
}

const events = (page, name) =>
  page.evaluate((name) => window.__events.filter((e) => e[0] === name).map((e) => e[1]), name);

// Browsers without SharedWorker: every tab keeps its own connection.
async function withoutSharedWorker(target) {
  await target.addInitScript(() => { delete window.SharedWorker; });
}

// Make the page's scripts ask for another worker script than /_weberl/hub.js.
async function hubScript(target, url) {
  await target.addInitScript((url) => {
    const Original = window.SharedWorker;
    if (!Original) { return; }
    window.SharedWorker = class extends Original {
      constructor(_url, options) { super(url, options); }
    };
  }, url);
}

// The page id and token of a live page, as its HTML carries them.
async function pageCredentials(request, path) {
  const html = await (await request.get(path)).text();
  const id = /data-weberl-page="([^"]+)"/.exec(html);
  const token = /data-weberl-token="([^"]+)"/.exec(html);
  expect(id && token, "the page carries the beacon").toBeTruthy();
  return { id: id[1], token: token[1] };
}

module.exports = { BASE, stats, idle, recordEvents, events, withoutSharedWorker, hubScript,
                   pageCredentials };
