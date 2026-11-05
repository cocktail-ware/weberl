// Only for the "layouts" variant of the app under test (E2E_VARIANT, see
// e2e_app/src/e2e_app_sup.erl): the pages are the ones of the other specs, built
// from a layout (layouts/main.weberl) and a view that fills its head slot. The
// other specs run unchanged against both variants; this one checks the layout is
// what produced the pages.
"use strict";

const { test, expect } = require("@playwright/test");

test.skip(process.env.E2E_VARIANT !== "layouts", "pages are not built from a layout in this variant");

test("the layout wraps the view: title from its variable, fills in the head slot", async ({ request }) => {
  const html = await (await request.get("/clock")).text();
  const head = /<head>([\s\S]*?)<\/head>/.exec(html)[1];
  const body = /<body>([\s\S]*)<\/body>/.exec(html)[1];
  expect(html.match(/<html/g)).toHaveLength(1);
  expect(head).toContain("<title>Clock</title>");
  expect(head).toContain('<script src="/static/clock.js" defer></script>');
  expect(head).not.toContain("<h1>");
  expect(body).toContain("<h1>Clock</h1>");
  expect(body).not.toContain("clock.js");
});

test("a slot the view does not fill is empty", async ({ request }) => {
  const html = await (await request.get("/regions")).text();
  const head = /<head>([\s\S]*?)<\/head>/.exec(html)[1];
  expect(head.replace(/\s+/g, "")).toBe("<title>Regions</title>");
});

test("the beacon goes at the end of the layout's body", async ({ request }) => {
  const html = await (await request.get("/counter")).text();
  const head = /<head>([\s\S]*?)<\/head>/.exec(html)[1];
  expect(head).not.toContain("data-weberl-page");
  expect(html).toMatch(/<script src="\/_weberl\/client\.js"[^>]*data-weberl-page="[^"]+"[^>]*><\/script><\/body>/);
});

test("regions of the view keep their wrappers inside the layout", async ({ request }) => {
  const html = await (await request.get("/counter")).text();
  expect(html).toContain('<weberl-region name="clock">');
  expect(html).toContain('<weberl-region name="count">');
});
