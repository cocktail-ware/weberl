// H. The browser side of the server's checks: origin and token.
"use strict";

const { test, expect } = require("@playwright/test");
const { BASE, idle, recordEvents, events, pageCredentials } = require("./helpers");

const OTHER = BASE.replace("app.test", "other.test");

test.beforeEach(async ({ request }) => { await idle(request); });

// "open" when the WebSocket connects, otherwise "error" / "closed".
const socketOutcome = (page, url) => page.evaluate((url) => new Promise((resolve) => {
  const ws = new WebSocket(url);
  ws.onopen = () => { ws.close(); resolve("open"); };
  ws.onerror = () => resolve("error");
  ws.onclose = () => resolve("closed");
  setTimeout(() => resolve("timeout"), 8000);
}), url);

const streamOutcome = (page, url) => page.evaluate((url) => new Promise((resolve) => {
  const es = new EventSource(url);
  es.onopen = () => { es.close(); resolve("open"); };
  es.onerror = () => { es.close(); resolve("error"); };
  setTimeout(() => { es.close(); resolve("timeout"); }, 8000);
}), url);

test("a page of another origin cannot open the socket", async ({ page }) => {
  const url = BASE.replace("https", "wss") + "/_weberl/ws";
  await page.goto(BASE + "/health");
  expect(await socketOutcome(page, url)).toBe("open");               // same origin: fine
  await page.goto(OTHER + "/health");
  expect(await socketOutcome(page, url)).not.toBe("open");           // another origin: refused
});

test("a page of another origin cannot open a stream even with a valid token", async ({ page, request }) => {
  const same = await pageCredentials(request, "/clock");
  await page.goto(BASE + "/health");
  expect(await streamOutcome(page, `${BASE}/_weberl/sse/${same.id}?t=${same.token}`)).toBe("open");

  const other = await pageCredentials(request, "/clock");
  await page.goto(OTHER + "/health");
  expect(await streamOutcome(page, `${BASE}/_weberl/sse/${other.id}?t=${other.token}`)).toBe("error");
});

test("tampered, foreign and missing tokens are refused", async ({ request }) => {
  const a = await pageCredentials(request, "/clock");
  const b = await pageCredentials(request, "/clock");
  const flip = (t) => t.slice(0, -2) + (t.endsWith("AA") ? "BB" : "AA");

  const status = async (id, token) =>
    (await request.get(`/_weberl/poll/${id}` + (token ? `?t=${encodeURIComponent(token)}` : ""),
                       { failOnStatusCode: false, maxRedirects: 0 })).status();
  expect(await status(a.id, flip(a.token))).toBe(403);   // tampered
  expect(await status(a.id, b.token)).toBe(403);         // another page's token
  expect(await status(a.id, null)).toBe(403);            // none
  expect(await status("nosuchpage", a.token)).toBe(403); // unknown page: indistinguishable
});

test("the beacon gives up on a refused token", async ({ page }) => {
  await recordEvents(page, ["closed"]);
  await page.route("**/clock", async (route) => {
    const response = await route.fetch();
    const body = (await response.text()).replace(/data-weberl-token="[^"]+"/, 'data-weberl-token="AAAA"');
    await route.fulfill({ response, body });
  });
  await page.goto("/clock");
  await expect.poll(() => events(page, "closed")).toEqual(["refused"]);
});
