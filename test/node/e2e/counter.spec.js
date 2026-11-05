// The /counter page of the app under test: a two-way live page with regions.
"use strict";

const { test, expect } = require("@playwright/test");

test("a request changes only its region and the ticker keeps updating another", async ({ page }) => {
  await page.goto("/counter");

  const clock = page.locator('weberl-region[name="clock"]');
  const count = page.locator('weberl-region[name="count"]');

  await expect(count).toHaveText("0");
  await expect(clock).toHaveText(/\d{4}-\d{2}-\d{2}T/);
  const before = await clock.textContent();

  await page.getByRole("button", { name: "Add 1" }).click();
  await expect(count).toHaveText("1");          // swapped in by the server's event
  await page.getByRole("button", { name: "Add 1" }).click();
  await expect(count).toHaveText("2");

  await expect(clock).not.toHaveText(before);   // the server's own ticker
});

test("the beacon reports patches on document", async ({ page }) => {
  await page.goto("/counter");
  await page.evaluate(() => {
    window.__patched = [];
    document.addEventListener("weberl:region", (e) => window.__patched.push(e.detail.region));
  });
  await page.getByRole("button", { name: "Add 1" }).click();
  await expect.poll(() => page.evaluate(() => window.__patched)).toContain("count");
});

test("the private view data answers requests the browser cannot forge", async ({ page }) => {
  await page.goto("/counter");
  // counter.js asks "age" every two seconds; the answer comes from private data
  await expect(page.locator("#age")).toHaveText(/^\d+$/);
});
