# SPDX-License-Identifier: GPL-3.0
# Copyright (c) 2026 Schubert Anselme <schubert@anselm.es>
#
# Cosmian KMS with an HSM behind it, for the compose profiles in ../../compose.yml.
# The upstream image is a minimal glibc rootfs with no package manager, so this
# takes a Debian base, copies the KMS binary and its OpenSSL files over, and adds
# the HSM's PKCS#11 library per target:
#   softhsm  SoftHSM2 from Debian (runs on arm64 and amd64)
#   nethsm   the NetHSM PKCS#11 library as /lib/libkmshsm.so (amd64 only)
# Development use: the upstream image is unpinned, and PyKMIP is only the client that
# creates the HSM key-encryption key on first start.
ARG COSMIAN_IMAGE=ghcr.io/cosmian/kms:latest
FROM ${COSMIAN_IMAGE} AS kms

FROM debian:trixie-slim AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates openssl python3 python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir pykmip==0.11.0
COPY --from=kms /bin/cosmian_kms /usr/local/bin/cosmian_kms
COPY --from=kms /usr/local/cosmian /usr/local/cosmian
COPY kmip_probe.py /opt/kmip_probe.py
COPY entrypoint.sh /usr/local/bin/cosmian-start
RUN chmod 0755 /usr/local/bin/cosmian-start && cosmian_kms --version
ENTRYPOINT ["/usr/local/bin/cosmian-start"]

FROM base AS softhsm
RUN apt-get update \
 && apt-get install -y --no-install-recommends softhsm2 \
 && rm -rf /var/lib/apt/lists/* \
 && if [ ! -e /usr/lib/softhsm/libsofthsm2.so ]; then \
      mkdir -p /usr/lib/softhsm \
      && ln -s "$(find /usr/lib -name libsofthsm2.so | head -n 1)" /usr/lib/softhsm/libsofthsm2.so; \
    fi \
 && ls -l /usr/lib/softhsm/libsofthsm2.so
ENV HSM_MODE=softhsm

FROM base AS nethsm
# The asset name follows the aarch64 names of the v3.0.1 release; confirm the x86_64 one.
ARG NETHSM_PKCS11_VERSION=v3.0.1
ARG NETHSM_PKCS11_URL=https://github.com/Nitrokey/nethsm-pkcs11/releases/download/${NETHSM_PKCS11_VERSION}/nethsm-pkcs11-${NETHSM_PKCS11_VERSION}-x86_64-linux-glibc.so
ADD --chmod=0755 ${NETHSM_PKCS11_URL} /lib/libkmshsm.so
ENV HSM_MODE=nethsm
