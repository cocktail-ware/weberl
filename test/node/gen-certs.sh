#!/usr/bin/env bash
# Makes a fake CA and a server certificate for the app under test (run inside the
# test container by test/e2e/run.sh). Output in certs/: ca.pem (the CA),
# server.pem and server.key (EC P-256, valid for app.test, other.test and
# localhost). Throwaway material: valid 30 days, never used outside tests.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf certs
mkdir certs
cd certs

openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 30 -subj "/CN=Weberl test CA" -out ca.pem

openssl ecparam -name prime256v1 -genkey -noout -out server.key
openssl req -new -key server.key -subj "/CN=app.test" -out server.csr
cat > server.ext <<'EOF'
subjectAltName = DNS:app.test, DNS:other.test, DNS:localhost
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = serverAuth
EOF
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
  -days 30 -sha256 -extfile server.ext -out server.pem

rm -f server.csr server.ext ca.srl
chmod 644 ca.pem server.pem server.key
