// F. Regions: what a patch replaces, what it keeps, and where it finds regions.
"use strict";

const { test, expect } = require("@playwright/test");
const { idle, recordEvents, events } = require("./helpers");

test.beforeEach(async ({ request }) => { await idle(request); });

const bump = (page) => page.evaluate(() => Weberl.request("bump"));

test("the wrapper does not change the layout and every region that uses the assign updates",
  async ({ page }) => {
    await page.goto("/regions");
    const display = await page.locator('weberl-region[name="form"]')
      .evaluate((el) => getComputedStyle(el).display);
    expect(display).toBe("contents");

    await bump(page);
    await expect(page.locator("#n")).toHaveText("1");
    await expect(page.locator("#t td")).toHaveText("1");
    await expect(page.locator('weberl-region[name="extra"] em')).toHaveText("1");
  });

test("a field with an id keeps the focus when its region is replaced", async ({ page }) => {
  await page.goto("/regions");
  await page.locator("#q").focus();
  await bump(page);                       // not a click: the focus must stay where it is
  await expect(page.locator("#n")).toHaveText("1");
  await expect(page.locator("#q")).toBeFocused();
});

test("a region with tag= keeps a table valid", async ({ page }) => {
  await page.goto("/regions");
  // the browser did not move it out of the table
  await expect(page.locator('table#t > tbody[data-weberl-region="rows"]')).toHaveCount(1);
  await bump(page);
  await expect(page.locator('table#t > tbody[data-weberl-region="rows"] td')).toHaveText("1");
});

test("a region element added by a script after load is patched", async ({ page }) => {
  await page.goto("/regions");
  await page.evaluate(() => {
    document.querySelector('weberl-region[name="extra"]').remove();
    const fresh = document.createElement("div");
    fresh.setAttribute("data-weberl-region", "extra");
    fresh.id = "fresh";
    fresh.textContent = "old";
    document.body.append(fresh);
  });
  await bump(page);
  await expect(page.locator("#fresh em")).toHaveText("1");
});

test("a region that is not on the page is ignored without an error", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (e) => errors.push(e.message));
  page.on("console", (m) => { if (m.type() === "error") { errors.push(m.text()); } });
  await recordEvents(page, ["region"]);
  await page.goto("/regions");
  await page.evaluate(() => document.querySelector('weberl-region[name="extra"]').remove());
  await bump(page);
  await expect.poll(async () =>
    (await events(page, "region")).find((d) => d.region === "extra")).toEqual({ region: "extra", count: 0 });
  expect(errors).toEqual([]);
});
