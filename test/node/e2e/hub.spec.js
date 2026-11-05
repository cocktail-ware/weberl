// The shared hub (SharedWorker): tabs of one browser context share a connection.
// The server counts its connections (/_test/stats, only in the app under test).
"use strict";

const { test, expect } = require("@playwright/test");

async function stats(request) {
  const response = await request.get("/_test/stats");
  return response.json();
}

// Wait until the app holds no websocket (pages of earlier tests are gone).
async function idle(request) {
  await expect.poll(async () => (await stats(request)).websockets).toBe(0);
}

test("two tabs of one context use one WebSocket", async ({ context, request }) => {
  await idle(request);
  const a = await context.newPage();
  await a.goto("/counter");
  const b = await context.newPage();
  await b.goto("/counter");

  // both pages are live ...
  await a.getByRole("button", { name: "Add 1" }).click();
  await expect(a.locator('weberl-region[name="count"]')).toHaveText("1");
  await expect(b.locator('weberl-region[name="count"]')).toHaveText("0");
  // ... on a single connection
  await expect.poll(async () => (await stats(request)).websockets).toBe(1);
  expect((await stats(request)).sessions).toBeGreaterThanOrEqual(2);

  // the connection lasts until the last tab goes
  await a.close();
  await b.getByRole("button", { name: "Add 1" }).click();
  await expect(b.locator('weberl-region[name="count"]')).toHaveText("1");
  await b.close();
  await idle(request);
});

test("without SharedWorker each tab keeps its own connection", async ({ context, request }) => {
  await idle(request);
  await context.addInitScript(() => { delete window.SharedWorker; });
  const a = await context.newPage();
  await a.goto("/counter");
  const b = await context.newPage();
  await b.goto("/counter");

  await a.getByRole("button", { name: "Add 1" }).click();
  await expect(a.locator('weberl-region[name="count"]')).toHaveText("1");
  await expect.poll(async () => (await stats(request)).websockets).toBe(2);
  await a.close();
  await b.close();
  await idle(request);
});

test("separate contexts (users) never share a connection", async ({ browser, request }, testInfo) => {
  await idle(request);
  const options = { ignoreHTTPSErrors: testInfo.project.use.ignoreHTTPSErrors };
  const u1 = await browser.newContext(options);
  const u2 = await browser.newContext(options);
  const base = process.env.BASE_URL || "https://app.test:8443";
  const a = await u1.newPage();
  await a.goto(base + "/counter");
  const b = await u2.newPage();
  await b.goto(base + "/counter");
  await expect(a.locator('weberl-region[name="clock"]')).toHaveText(/\d{4}/);
  await expect(b.locator('weberl-region[name="clock"]')).toHaveText(/\d{4}/);
  await expect.poll(async () => (await stats(request)).websockets).toBe(2);
  await u1.close();
  await u2.close();
  await idle(request);
});
