// A. The beacon per tab: transports, requests, fallback to long-poll.
"use strict";

const { test, expect } = require("@playwright/test");
const { stats, idle, recordEvents, events, withoutSharedWorker } = require("./helpers");

test.beforeEach(async ({ request }) => { await idle(request); });

test("a one_way page without SharedWorker uses its own SSE stream", async ({ page, request }) => {
  await withoutSharedWorker(page);
  await page.goto("/clock");
  const first = await page.locator("#time").textContent();
  await expect(page.locator("#time")).not.toHaveText(first);        // the server pushes ticks
  const s = await stats(request);
  expect(s.streams).toBe(1);
  expect(s.websockets).toBe(0);
});

test("one_way pages of two tabs ride the hub's one socket", async ({ context, request }) => {
  const a = await context.newPage();
  await a.goto("/clock");
  const b = await context.newPage();
  await b.goto("/clock");
  for (const tab of [a, b]) {
    const t = await tab.locator("#time").textContent();
    await expect(tab.locator("#time")).not.toHaveText(t);
  }
  await expect.poll(async () => (await stats(request)).websockets).toBe(1);
  expect((await stats(request)).streams).toBe(0);
});

test("a request to a handler without handle_request/3 is rejected as unsupported", async ({ page }) => {
  await page.goto("/clock");
  const reason = await page.evaluate(() =>
    Weberl.request("anything", 1).then(() => null, (err) => err.reason));
  expect(reason).toBe("unsupported");
});

test("a request over a socket gets its reply", async ({ page }) => {
  await page.goto("/counter");
  const reply = await page.evaluate(() => Weberl.request("add", 5));
  expect(reply).toBe(5);
});

test("when the stream keeps failing the page falls back to long-poll and still gets events",
  async ({ page }) => {
    test.setTimeout(60_000);
    await withoutSharedWorker(page);
    await recordEvents(page, ["transport", "connected", "closed", "tick"]);
    const polls = [];
    page.on("response", (r) => {
      if (r.url().includes("/_weberl/poll/")) { polls.push(`${r.status()} ${r.url().split("/").pop()}`); }
    });
    // the stream never opens, whatever the browser's retry timing
    await page.route("**/_weberl/sse/**", (route) => route.abort());
    await page.goto("/clock");

    try {
      await expect.poll(async () => (await events(page, "transport")).includes("poll"),
                        { timeout: 40_000 }).toBe(true);
    } catch (err) {
      throw new Error(`no fallback to poll; transports ${JSON.stringify(await events(page, "transport"))}; ` +
                      `closed ${JSON.stringify(await events(page, "closed"))}`);
    }
    // events arrive by long-poll (the diagnostics say what happened if they do not)
    try {
      await expect.poll(async () => (await events(page, "tick")).length, { timeout: 15_000 })
        .toBeGreaterThan(0);
    } catch (err) {
      const closed = await events(page, "closed");
      throw new Error(`no tick after the fallback; polls ${JSON.stringify(polls)}; closed ${JSON.stringify(closed)}`);
    }
    const first = await page.locator("#time").textContent();
    await expect(page.locator("#time")).not.toHaveText(first);
    expect(await events(page, "connected")).toContain("poll");
  });
