#!/bin/bash

set -e

maas config-tls enable --yes --port 5240 --cacert /etc/maas/ssl/ca.crt /etc/maas/ssl/tls.key /etc/maas/ssl/tls.crt
