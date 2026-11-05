// Browser tests of Weberl. The app under test (e2e_app/) runs in the same pod
// as the browser; the pod maps app.test and other.test to localhost.
"use strict";

const { defineConfig, devices } = require("@playwright/test");

module.exports = defineConfig({
  testDir: "./e2e",
  // The tests read counters of the one app under test (/_test/stats), so they run
  // one at a time.
  workers: 1,
  fullyParallel: false,
  retries: 0,
  timeout: 30_000,
  expect: { timeout: 10_000 },
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: process.env.BASE_URL || "https://app.test:8443",
    // The server certificate is signed by a fake CA (certs/ca.pem), which
    // run-e2e.sh makes Chromium trust. Firefox and WebKit do not trust it yet, so
    // errors are ignored for them (see the projects below).
    ignoreHTTPSErrors: false,
    trace: "retain-on-failure",
  },
  // Chromium only unless E2E_BROWSERS says otherwise (a comma separated list of
  // chromium, firefox, webkit): three browsers are heavy on the machine.
  projects: [
    { name: "chromium", use: { ...devices["Desktop Chrome"] } },
    { name: "firefox", use: { ...devices["Desktop Firefox"], ignoreHTTPSErrors: true } },
    { name: "webkit", use: { ...devices["Desktop Safari"], ignoreHTTPSErrors: true } },
  ].filter((p) => (process.env.E2E_BROWSERS || "chromium").split(",").includes(p.name)),
});
