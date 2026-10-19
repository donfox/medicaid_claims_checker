#!/usr/bin/env bash
# Generate a development CA and an engine certificate signed by it, in
# haskell_engine/priv/tls/:
#
#   ca.pem             give to Phoenix as RULE_ENGINE_CA_CERT
#   cert.pem, key.pem  give to the engine as RULE_ENGINE_TLS_CERT / _KEY
#
# The certificate covers localhost and 127.0.0.1, plus any host names or IP
# addresses given as arguments:  ./gen-dev-tls.sh engine.internal 10.0.0.5
#
# Phoenix (Erlang :ssl) rejects a lone self-signed certificate even when it is
# trusted explicitly, hence the separate CA.
set -euo pipefail
dir="$(dirname "$0")/priv/tls"
mkdir -p "$dir"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

san="DNS:localhost,IP:127.0.0.1"
for host in "$@"; do
  if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:* ]]; then
    san="$san,IP:$host"
  else
    san="$san,DNS:$host"
  fi
done

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$tmp/ca.key" -out "$dir/ca.pem" -days 3650 \
  -subj "/CN=Medicaid Claims Checker dev engine CA" 2>/dev/null

openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout "$dir/key.pem" -out "$tmp/engine.csr" -subj "/CN=localhost" 2>/dev/null

cat >"$tmp/ext.cnf" <<EOF
subjectAltName=$san
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=serverAuth
EOF

openssl x509 -req -in "$tmp/engine.csr" -CA "$dir/ca.pem" -CAkey "$tmp/ca.key" \
  -CAcreateserial -CAserial "$tmp/ca.srl" -out "$dir/cert.pem" -days 825 \
  -extfile "$tmp/ext.cnf" 2>/dev/null
chmod 600 "$dir/key.pem"

echo "Wrote haskell_engine/priv/tls/{ca,cert,key}.pem for $san"
