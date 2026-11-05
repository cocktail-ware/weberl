// Reads a browser script of the framework. The scripts live in priv/ (outside
// the folder that is mounted into the test container), so the run script copies
// them to test/node/_priv/ before each run; WEBERL_PRIV points elsewhere.
"use strict";

const fs = require("node:fs");
const path = require("node:path");

const DIR = process.env.WEBERL_PRIV || path.join(__dirname, "..", "_priv");

module.exports = function source(name) {
  return fs.readFileSync(path.join(DIR, name), "utf8");
};
