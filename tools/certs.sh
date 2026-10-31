#!/bin/sh
# OFM certificates (ADR-0019, step 2.7). Run by the one-shot "certs" service
# on every "docker compose up", before the broker and the HTTPS proxy start.
#
#   up      (default) create what is missing, renew what is due; idempotent
#   import  install certificates supplied by plant IT from deploy/certs/import/
#   show    print what is installed
#
# OFM makes its own small certificate authority (CA): a key that signs the
# server certificate, like a stamp. Clients trust OFM by trusting the CA's
# public certificate, deploy/certs/ofm-ca.crt (not secret). Private keys stay
# in the Docker volume "certs" and never enter the repository folder.
#
# The server certificate names every way clients reach this server: the
# Compose service names, localhost, and OFM_TLS_NAMES from .env (the server's
# network name and IP address, e.g. "ofm-server,192.168.10.20"). It is
# reissued when those names change, when it is within 30 days of expiry, or
# when it was not signed by the current CA.
set -eu

DIR=/certs                          # the "certs" volume: keys and certificates
EXPORT=/repo/deploy/certs           # repository folder: only ofm-ca.crt (public)
CA_DAYS=3650                        # 10 years
SERVER_DAYS=825                     # the longest validity Apple devices accept
RENEW_DAYS=30
mode="${1:-up}"

fail() { echo "certs: $*" >&2; exit 1; }
when() { openssl x509 -noout -enddate -in "$1" | cut -d= -f2; }

# --- the names the server certificate must cover --------------------------------
names=$(printf '%s' "localhost,127.0.0.1,mosquitto,proxy,${OFM_TLS_NAMES:-}" |
        tr 'A-Z' 'a-z' | tr -d ' \r' | tr ',' '\n' |
        awk 'NF && !seen[$0]++ { printf "%s%s", (n++ ? "," : ""), $0 }')
san=""
for n in $(echo "$names" | tr ',' ' '); do
  if echo "$n" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || echo "$n" | grep -Eq '^[0-9a-f:]+:[0-9a-f:]*$'; then
    san="$san,IP:$n"
  elif echo "$n" | grep -Eq '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$'; then
    san="$san,DNS:$n"
  else
    fail "OFM_TLS_NAMES: '$n' is not a host name or IP address (use letters, digits, dots and hyphens; separate names with commas)"
  fi
done
san=${san#,}

mkdir -p "$DIR" "$EXPORT"
umask 077

# Keys readable by root only (the broker and proxy start as root); the
# certificates are public, so every container, e.g. the test runner, may read them.
permissions() {
  chmod 755 "$DIR"
  chmod 600 "$DIR"/*.key 2>/dev/null || true
  chmod 644 "$DIR"/*.crt "$DIR/names" "$DIR/source" 2>/dev/null || true
}

export_ca() {
  cp "$DIR/ca.crt" "$EXPORT/ofm-ca.crt"
  chmod 644 "$EXPORT/ofm-ca.crt"
  chown "$(stat -c %u:%g "$EXPORT")" "$EXPORT/ofm-ca.crt" 2>/dev/null || true
}

show() {
  echo "TLS certificate ($(cat "$DIR/source" 2>/dev/null || echo ofm)): valid until $(when "$DIR/server.crt")"
  echo "  names: $(openssl x509 -noout -ext subjectAltName -in "$DIR/server.crt" | tail -n 1 | tr -d ' ')"
  echo "  clients trust: deploy/certs/ofm-ca.crt ($(openssl x509 -noout -subject -in "$DIR/ca.crt" | sed 's/^subject=//'), valid until $(when "$DIR/ca.crt"))"
  case "${OFM_LISTEN_ADDRESS:-127.0.0.1}" in
    127.0.0.1) echo "  reachable from: this computer only (OFM_LISTEN_ADDRESS=127.0.0.1)" ;;
    *) echo "  reachable from: the network (OFM_LISTEN_ADDRESS=${OFM_LISTEN_ADDRESS})"
       [ -n "${OFM_TLS_NAMES:-}" ] ||
         echo "WARNING: OFM is open to the network but OFM_TLS_NAMES is empty: other computers will get a certificate name warning. Set it in .env to this server's name and IP address." ;;
  esac
}

# --- import: certificates from plant IT -----------------------------------------
if [ "$mode" = import ]; then
  IMP="$EXPORT/import"
  for f in server.crt server.key ca.crt; do
    [ -s "$IMP/$f" ] || fail "import: $IMP/$f is missing (needed: server.crt, server.key, ca.crt)"
  done
  openssl verify -CAfile "$IMP/ca.crt" "$IMP/server.crt" >/dev/null 2>&1 ||
    fail "import: server.crt is not signed by ca.crt (if IT uses an intermediate CA, append it to server.crt)"
  [ "$(openssl x509 -noout -pubkey -in "$IMP/server.crt" | openssl sha256)" = \
    "$(openssl pkey -pubout -in "$IMP/server.key" | openssl sha256)" ] ||
    fail "import: server.key does not belong to server.crt"
  cp "$IMP/server.crt" "$IMP/server.key" "$IMP/ca.crt" "$DIR/"
  rm -f "$DIR/ca.key"                       # IT keeps its CA key; OFM stops issuing
  echo imported > "$DIR/source"
  echo "$names" > "$DIR/names"
  permissions
  export_ca
  show
  echo "Imported. Now delete deploy/certs/import/server.key (it is a secret) and run: docker compose restart mosquitto proxy"
  exit 0
fi

[ "$mode" = up ] || [ "$mode" = show ] || fail "unknown command '$mode' (up, import or show)"
if [ "$mode" = show ]; then show; exit 0; fi

# --- up: certificates provided by plant IT are checked, never replaced -------------
if [ "$(cat "$DIR/source" 2>/dev/null)" = imported ]; then
  openssl x509 -checkend $((RENEW_DAYS * 86400)) -noout -in "$DIR/server.crt" >/dev/null ||
    echo "WARNING: the imported TLS certificate expires $(when "$DIR/server.crt"): ask plant IT for a new one (deploy/README.md)"
  export_ca
  show
  exit 0
fi

# --- up: OFM's own certificate authority, created once ------------------------------
if [ ! -s "$DIR/ca.key" ] || [ ! -s "$DIR/ca.crt" ]; then
  cat > "$DIR/ca.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
O = Open Factory Model
CN = OFM certificate authority $(date -u +%Y-%m-%d)
[ext]
basicConstraints = critical,CA:TRUE,pathlen:0
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -new -newkey rsa:3072 -nodes -sha256 -days $CA_DAYS -config "$DIR/ca.cnf" \
          -keyout "$DIR/ca.key" -out "$DIR/ca.crt" 2>/dev/null
  rm -f "$DIR/ca.cnf" "$DIR/server.crt"
  echo "Created a new OFM certificate authority. Every client must trust the new deploy/certs/ofm-ca.crt."
fi

# --- up: the server certificate, (re)issued when needed -------------------------------
reason=""
if [ ! -s "$DIR/server.crt" ] || [ ! -s "$DIR/server.key" ]; then reason="none yet"
elif [ "$(cat "$DIR/names" 2>/dev/null)" != "$names" ]; then reason="the names changed (OFM_TLS_NAMES)"
elif ! openssl verify -CAfile "$DIR/ca.crt" "$DIR/server.crt" >/dev/null 2>&1; then reason="not signed by the current certificate authority"
elif ! openssl x509 -checkend $((RENEW_DAYS * 86400)) -noout -in "$DIR/server.crt" >/dev/null; then reason="it expires within $RENEW_DAYS days"
fi

if [ -n "$reason" ]; then
  first=$(echo "$names" | cut -d, -f1)
  [ -z "${OFM_TLS_NAMES:-}" ] || first=$(echo "$OFM_TLS_NAMES" | tr 'A-Z' 'a-z' | tr -d ' \r' | cut -d, -f1)
  cat > "$DIR/server.cnf" <<EOF
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = $san
EOF
  openssl req -new -newkey rsa:2048 -nodes -sha256 -subj "/O=Open Factory Model/CN=$first" \
          -keyout "$DIR/server.key.new" -out "$DIR/server.csr" 2>/dev/null
  openssl x509 -req -sha256 -days $SERVER_DAYS -in "$DIR/server.csr" \
          -CA "$DIR/ca.crt" -CAkey "$DIR/ca.key" -set_serial "0x$(openssl rand -hex 16)" \
          -extfile "$DIR/server.cnf" -out "$DIR/server.crt.new" 2>/dev/null
  mv "$DIR/server.key.new" "$DIR/server.key"
  mv "$DIR/server.crt.new" "$DIR/server.crt"
  rm -f "$DIR/server.csr" "$DIR/server.cnf"
  echo "$names" > "$DIR/names"
  echo ofm > "$DIR/source"
  echo "Issued a new TLS server certificate: $reason."
  [ "$reason" = "none yet" ] || echo "If the broker and proxy were already running: docker compose restart mosquitto proxy"
fi

permissions
export_ca
show
