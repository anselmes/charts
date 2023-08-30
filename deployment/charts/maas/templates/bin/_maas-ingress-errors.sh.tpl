#!/bin/sh

set -ex
COMMAND="${@:-start}"

if [ "x${COMMAND}" == "xstart" ]; then
  if [[ -z "${BIND_PORT}" ]]
  then
    exec /server
  else
    exec /server -port ${BIND_PORT}
  fi
elif [ "x${COMMAND}" == "xstop" ]; then
  kill -TERM 1
fi
