// Only for the "layouts" variant of the app under test: /switch is rendered with the layout
// the handler picks per request (?layout=main|admin|none; route options
// `layout => main, layouts => [admin, none]`). The session remembers the layout, so the
// page's regions are re-rendered with the same layout: `who` exists only in the admin one.
"use strict";

const { test, expect } = require("@playwright/test");

test.skip(process.env.E2E_VARIANT !== "layouts", "pages are not built from a layout in this variant");

test("the default layout, and the one the handler picks, wrap the same view", async ({ request }) => {
  const main = await (await request.get("/switch")).text();
  expect(main).toContain("<title>Switch</title>");
  expect(main).not.toContain('class="admin"');
  expect(main).toContain('<weberl-region name="name">');

  const admin = await (await request.get("/switch?layout=admin")).text();
  expect(admin).toContain("<title>Admin: Switch</title>");
  expect(admin).toContain('<body class="admin">');
  expect(admin).toContain('<weberl-region name="who">');
  expect(admin).toContain('<weberl-region name="name">');
});

test("none renders the bare view; an unknown name falls back to the default", async ({ request }) => {
  const bare = await (await request.get("/switch?layout=none")).text();
  expect(bare).not.toContain("<html");
  expect(bare).not.toContain("<title>");
  expect(bare).toContain("<h1>Switch</h1>");
  expect(bare).toMatch(/data-weberl-page="[^"]+"/);   // the beacon still goes in

  const other = await (await request.get("/switch?layout=%3Cscript%3E")).text();
  expect(other).toContain("<title>Switch</title>");
});

test("a live page re-renders the regions of its own layout", async ({ page }) => {
  await page.goto("/switch?layout=admin");
  await expect(page.locator("#who")).toHaveText("ann");
  await expect(page.locator("#name")).toHaveText("ann");
  await page.getByRole("button", { name: "Rename" }).click();
  await expect(page.locator("#who")).toHaveText("zed");    // a region of the admin layout
  await expect(page.locator("#name")).toHaveText("zed");   // a region of the view
});

test("with the default layout only the view's region follows the change", async ({ page }) => {
  await page.goto("/switch");
  await expect(page.locator("#who")).toHaveCount(0);
  await page.getByRole("button", { name: "Rename" }).click();
  await expect(page.locator("#name")).toHaveText("zed");
  await expect(page.locator("#who")).toHaveCount(0);
});

test("the bare view is live too", async ({ page }) => {
  await page.goto("/switch?layout=none");
  await page.getByRole("button", { name: "Rename" }).click();
  await expect(page.locator("#name")).toHaveText("zed");
});
