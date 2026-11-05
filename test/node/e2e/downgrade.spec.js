// D. Downgrade and E. caching.
"use strict";

const { test, expect } = require("@playwright/test");
const { stats, idle, withoutSharedWorker } = require("./helpers");

test.beforeEach(async ({ request }) => { await idle(request); });

test("narrowed to normal: no beacon, no session left, kept out of shared caches", async ({ page, request }) => {
  const response = await page.goto("/downgrade?kind=normal");
  expect(response.status()).toBe(200);
  expect(response.headers()["cache-control"]).toBe("private, no-store");
  await expect(page.locator("script[data-weberl-page]")).toHaveCount(0);
  // the session opened for the render was closed (other specs' sessions may still be
  // running down, so count the ones of this handler)
  await expect.poll(async () => {
    const response = await request.get("/_test/stats?handler=downgrade_view");
    return (await response.json()).sessions_of;
  }).toBe(0);
});

test("narrowed to one_way: the beacon says so and no WebSocket is used", async ({ page, request }) => {
  await withoutSharedWorker(page);
  await page.goto("/downgrade?kind=one_way");
  await expect(page.locator("script[data-weberl-page]")).toHaveAttribute("data-weberl-kind", "one_way");
  await expect.poll(async () => (await stats(request)).streams).toBe(1);
  expect((await stats(request)).websockets).toBe(0);
});

test("without a marker the route's kind is served", async ({ page }) => {
  await page.goto("/downgrade");
  await expect(page.locator("script[data-weberl-page]")).toHaveAttribute("data-weberl-kind", "two_way");
});

test("asking for a wider kind than the route's is a 500", async ({ page }) => {
  const response = await page.goto("/widen");
  expect(response.status()).toBe(500);
});

test("live pages are not cached by shared caches unless the handler said otherwise", async ({ request }) => {
  const live = await request.get("/clock");
  expect(live.headers()["cache-control"]).toBe("private, no-store");
  const own = await request.get("/cached");
  expect(own.headers()["cache-control"]).toBe("public, max-age=60");   // kept (and logged)
});
