#!/usr/bin/env bash
# Runs the Playwright specs inside the test container (test/e2e/run.sh calls it).
# First it trusts the fake CA (certs/ca.pem) for Chromium, which reads the NSS
# database of the user; the other browsers still ignore certificate errors
# (see playwright.config.js). Arguments go to `playwright test`.
set -euo pipefail
cd "$(dirname "$0")"

NSS="$HOME/.pki/nssdb"
mkdir -p "$NSS"
certutil -d "sql:$NSS" -N --empty-password
certutil -d "sql:$NSS" -A -t "C,," -n weberl-test-ca -i certs/ca.pem

# Playwright's own HTTP client (the `request` fixture) runs in Node, which reads
# this instead of the NSS database.
export NODE_EXTRA_CA_CERTS="$PWD/certs/ca.pem"

exec npx playwright test "$@"
