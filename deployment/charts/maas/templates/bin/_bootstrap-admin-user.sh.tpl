#!/bin/bash

set -e

maas-region createadmin --username=${ADMIN_USERNAME} --password=${ADMIN_PASSWORD} --email=${ADMIN_EMAIL} || true

# Change password.
echo "${ADMIN_USERNAME}:${ADMIN_PASSWORD}" | maas-region changepasswords
