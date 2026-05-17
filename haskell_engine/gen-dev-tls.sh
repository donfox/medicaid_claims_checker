#!/usr/bin/env bash
# Regenerate the self-signed TLS certificate used for the local rule-engine
# HTTPS channel.  Run once after a fresh clone, or any time the cert expires.
set -euo pipefail
mkdir -p "$(dirname "$0")/priv/tls"
openssl req -x509 \
  -newkey ec -pkeyopt ec_paramgen_curve:P-256 \
  -keyout "$(dirname "$0")/priv/tls/key.pem" \
  -out    "$(dirname "$0")/priv/tls/cert.pem" \
  -days 3650 -nodes \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
echo "TLS cert written to haskell_engine/priv/tls/{cert,key}.pem"
