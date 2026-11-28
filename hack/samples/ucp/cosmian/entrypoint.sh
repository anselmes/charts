#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0
# Copyright (c) 2026 Schubert Anselme <schubert@anselm.es>
#
# Start Cosmian KMS with an HSM behind it. HSM_MODE is set by the image:
#   softhsm  init a SoftHSM2 token, create an AES key-encryption key (KEK) inside it
#            over KMIP, then run the KMS with that KEK so every stored key is wrapped
#            by it at rest. The slot and the KEK id persist in /state.
#   nethsm   use the NetHSM through its PKCS#11 library (slot 0, operator PIN). A KEK
#            is used only when COSMIAN_KEK is set; NetHSM has no AES wrap, so it must
#            be an RSA key that exists on the NetHSM.
# A development PKI is generated into /pki on first start. The client certificate has
# CN=admin, the KMS's HSM admin, so use it only for development.
set -Eeuo pipefail

: "${HSM_MODE:?HSM_MODE is not set}"
: "${KMIP_PORT:=5696}"
: "${TOKEN_LABEL:=seal-test}"
: "${TOKEN_PIN:=000000}"
: "${NETHSM_OPERATOR_PASSPHRASE:=OperatorOperator}"
: "${COSMIAN_KEK:=}"
: "${KEK_WRAP_ALG:=}"
p12_password=cosmian-dev
hsm_admin="admin"

log() { printf '==> %s\n' "$*"; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$KMIP_PORT") 2>/dev/null; }

make_pki() {
  [[ -s /pki/ca.pem ]] && return 0
  log "generating a development PKI in /pki"
  local d=/pki n cn
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$d/ca.key" -out "$d/ca.pem" -subj "/CN=cosmian-dev-ca" -days 30 2>/dev/null
  for n in server client; do
    cn=$n; [[ $n == client ]] && cn=$hsm_admin
    openssl req -newkey rsa:2048 -nodes -keyout "$d/$n.key" -out "$d/$n.csr" -subj "/CN=$cn" 2>/dev/null
    printf 'subjectAltName=DNS:localhost,DNS:cosmian,IP:127.0.0.1\nextendedKeyUsage=serverAuth,clientAuth\n' >"$d/$n.ext"
    openssl x509 -req -in "$d/$n.csr" -CA "$d/ca.pem" -CAkey "$d/ca.key" -CAcreateserial -out "$d/$n.pem" -days 30 -extfile "$d/$n.ext" 2>/dev/null
  done
  openssl pkcs12 -export -inkey "$d/server.key" -in "$d/server.pem" -certfile "$d/ca.pem" -out "$d/server.p12" -passout "pass:$p12_password"
  chmod 0644 "$d"/*.key "$d"/*.p12
}

softhsm_slot() {
  softhsm2-util --show-slots | awk -v label="$TOKEN_LABEL" '
    /^Slot / { slot = $2 }
    /^[[:space:]]*Label:/ { sub(/^[[:space:]]*Label:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); if ($0 == label) print slot }' | head -n 1
}

make_pki
# A browser identity for the web UI login (https://localhost:9998/ui, "Client certificate").
# Older algorithms on purpose: macOS Keychain refuses OpenSSL 3's default PKCS#12 encryption.
if [[ ! -s /pki/client.p12 ]]; then
  openssl pkcs12 -export -inkey /pki/client.key -in /pki/client.pem -certfile /pki/ca.pem -name "$hsm_admin" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -out /pki/client.p12 -passout "pass:$p12_password"
  chmod 0644 /pki/client.p12
fi
mkdir -p /state /var/lib/cosmian-kms

case $HSM_MODE in
  softhsm)
    model=softhsm2
    pin=$TOKEN_PIN
    if [[ -z "$(softhsm_slot)" ]]; then
      log "initialising a SoftHSM2 token"
      softhsm2-util --init-token --free --label "$TOKEN_LABEL" --so-pin "$TOKEN_PIN" --pin "$TOKEN_PIN"
    fi
    slot=$(softhsm_slot)
    [[ -n "$slot" ]] || { echo "error: no SoftHSM2 slot labelled $TOKEN_LABEL" >&2; exit 1; }
    ;;
  nethsm)
    model=other
    pin=$NETHSM_OPERATOR_PASSPHRASE
    slot=0
    ;;
  *) echo "error: unknown HSM_MODE $HSM_MODE" >&2; exit 1 ;;
esac
log "HSM mode $HSM_MODE, model $model, slot $slot"

export KMS_TLS_P12_FILE=/pki/server.p12 KMS_TLS_P12_PASSWORD=$p12_password
export KMS_CLIENTS_CA_CERT_FILE=/pki/ca.pem KMS_SOCKET_SERVER_START=true KMS_SOCKET_SERVER_PORT=$KMIP_PORT
export KMS_SOCKET_SERVER_HOSTNAME=0.0.0.0

kms_args=(--hsm-model "$model" --hsm-admin "$hsm_admin" --hsm-slot "$slot" --hsm-password "$pin"
  --database-type sqlite --sqlite-path /var/lib/cosmian-kms/sqlite-data)

kek=$COSMIAN_KEK
if [[ $HSM_MODE == softhsm ]]; then
  if [[ ! -s /state/kek ]]; then
    log "first start: running the KMS once to create the key-encryption key inside the HSM"
    cosmian_kms "${kms_args[@]}" &
    kms_pid=$!
    for ((i = 0; i < 60; i++)); do port_open && break; sleep 1; done
    port_open || { echo "error: the KMS did not open $KMIP_PORT" >&2; exit 1; }
    kek_id="hsm::$slot::master-kek"
    KMIP_HOST=127.0.0.1 KMIP_PORT=$KMIP_PORT KMIP_CLIENT_CERT=/pki/client.pem KMIP_CLIENT_KEY=/pki/client.key \
      KMIP_CA_CERT=/pki/ca.pem /opt/venv/bin/python /opt/kmip_probe.py create-hsm "$kek_id"
    kill "$kms_pid" 2>/dev/null || true
    for ((i = 0; i < 10; i++)); do kill -0 "$kms_pid" 2>/dev/null || break; sleep 1; done
    kill -KILL "$kms_pid" 2>/dev/null || true
    wait "$kms_pid" 2>/dev/null || true
    printf '%s\n' "$kek_id" >/state/kek
  fi
  kek=$(cat /state/kek)
fi

if [[ -n "$kek" ]]; then
  log "key_encryption_key: $kek"
  [[ -n "$KEK_WRAP_ALG" ]] && kms_args+=(--key-encryption-key-wrapping-algorithm "$KEK_WRAP_ALG")
  kms_args+=("$kek")
else
  log "no key-encryption key configured: stored keys are not wrapped by the HSM"
fi
exec cosmian_kms "${kms_args[@]}"
