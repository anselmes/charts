#!/bin/bash

set -ex

COMMAND="${1:-start}"

function start () {
  exec /usr/bin/dumb-init \
      /nginx-ingress-controller \
      --http-port="${HTTP_PORT}" \
      --watch-namespace="${POD_NAMESPACE}" \
      --https-port="${HTTPS_PORT}" \
      --status-port="${STATUS_PORT}" \
      --stream-port="${STREAM_PORT}" \
      --profiler-port="${PROFILER_PORT}" \
      --healthz-port="${HEALTHZ_PORT}" \
      --election-id=${RELEASE_NAME} \
      --default-server-port=${DEFAULT_ERROR_PORT} \
      --ingress-class=maas-ingress \
      --default-backend-service=${POD_NAMESPACE}/${ERROR_PAGE_SERVICE} \
      --configmap=${POD_NAMESPACE}/maas-ingress-config \
      --tcp-services-configmap=${POD_NAMESPACE}/maas-ingress-services-tcp \
      --udp-services-configmap=${POD_NAMESPACE}/maas-ingress-services-udp
}

function stop () {
  kill -TERM 1
}

$COMMAND
