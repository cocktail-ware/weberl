// B. The hub and its worker: a worker of another version, a worker that fails.
"use strict";

const { test, expect } = require("@playwright/test");
const { stats, idle, recordEvents, events, hubScript } = require("./helpers");

test.beforeEach(async ({ request }) => { await idle(request); });

test("a hub of another version is reported and the tab keeps working on its own connection",
  async ({ page, request }) => {
    const warnings = [];
    page.on("console", (m) => { if (m.type() === "warning") { warnings.push(m.text()); } });
    await recordEvents(page, ["stale"]);
    await hubScript(page, "/static/hub-v2.js");        // says hello with version 2

    await page.goto("/counter");
    await expect.poll(() => events(page, "stale")).toEqual([{ hub: 3, page: 2 }]);
    expect(warnings.some((w) => /another version/.test(w) || /version/.test(w))).toBe(true);

    // the page works anyway, on a connection of its own
    await page.getByRole("button", { name: "Add 1" }).click();
    await expect(page.locator('weberl-region[name="count"]')).toHaveText("1");
    await expect.poll(async () => (await stats(request)).websockets).toBe(1);
  });

test("a worker that fails to start is given up on, with a warning", async ({ page }) => {
  const warnings = [];
  page.on("console", (m) => { if (m.type() === "warning") { warnings.push(m.text()); } });
  await hubScript(page, "/static/no-such-worker.js");

  await page.goto("/counter");
  await page.getByRole("button", { name: "Add 1" }).click();
  await expect(page.locator('weberl-region[name="count"]')).toHaveText("1");
  await expect.poll(() => warnings.some((w) => /not using the shared hub/.test(w))).toBe(true);
});
