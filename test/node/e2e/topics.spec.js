// C. Topics and snapshots, on a page without a session (one topic: its path).
"use strict";

const { test, expect } = require("@playwright/test");
const { stats, idle, recordEvents, events } = require("./helpers");

test.beforeEach(async ({ request }) => { await idle(request); });

const publish = (request, event, data) =>
  request.get(`/_test/publish?topic=%2Ftopics&event=${event}&data=${encodeURIComponent(data)}`);

test("a publish reaches every tab, over one connection", async ({ context, request }) => {
  await publish(request, "update", "start");
  // sessions of earlier specs may still be running down: they can only decrease
  const sessionsBefore = (await stats(request)).sessions;
  const a = await context.newPage();
  const b = await context.newPage();
  for (const tab of [a, b]) { await recordEvents(tab, ["news", "snapshot"]); }
  await a.goto("/topics");
  await b.goto("/topics");
  await expect.poll(async () => (await stats(request)).websockets).toBe(1);
  // both are subscribed once their snapshot is in
  for (const tab of [a, b]) {
    await expect.poll(() => events(tab, "snapshot")).toEqual(["start"]);
  }

  await publish(request, "news", "hello");
  for (const tab of [a, b]) {
    await expect.poll(() => events(tab, "news")).toEqual(["hello"]);
  }
  // no process per viewer: the two pages opened no session
  expect((await stats(request)).sessions).toBeLessThanOrEqual(sessionsBefore);
});

test("a snapshot goes to the subscribing tab only; a later tab gets its own", async ({ context, request }) => {
  await publish(request, "update", "v1");
  const a = await context.newPage();
  await recordEvents(a, ["snapshot"]);
  await a.goto("/topics");
  await expect.poll(() => events(a, "snapshot")).toEqual(["v1"]);

  await publish(request, "update", "v2");              // changes what the next snapshot says
  const b = await context.newPage();
  await recordEvents(b, ["snapshot"]);
  await b.goto("/topics");
  await expect.poll(() => events(b, "snapshot")).toEqual(["v2"]);
  expect(await events(a, "snapshot")).toEqual(["v1"]);  // a was not sent b's snapshot
});

test("an update published after the snapshot arrives in order", async ({ page, request }) => {
  await publish(request, "update", "s");
  await recordEvents(page, ["snapshot", "update"]);
  await page.goto("/topics");
  await expect.poll(() => events(page, "snapshot")).toEqual(["s"]);
  await publish(request, "update", "t");
  await expect.poll(() => events(page, "update")).toEqual(["t"]);
});
