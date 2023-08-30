#!/bin/bash

set -ex

function clear_secret {
    wget \
        --server-response \
        --ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
        --header='Content-Type: application/json' \
        --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        --method=DELETE \
        https://kubernetes.default.svc.cluster.local/api/v1/namespaces/${SECRET_NAMESPACE}/secrets/${SECRET_NAME}
}

function post_secret {
    wget \
        --server-response \
        --ca-certificate=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
        --header='Content-Type: application/json' \
        --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
        --method=POST \
        --body-file=/tmp/secret.json \
        https://kubernetes.default.svc.cluster.local/api/v1/namespaces/${SECRET_NAMESPACE}/secrets \
        2>&1
}

KEY=$(maas-region apikey --username=${ADMIN_USERNAME})

if [ "x$KEY" != "x" ]; then
    ENCODED_KEY=$(echo -n $KEY | base64 -w 0)
    cat <<EOS > /tmp/secret.json
{
  "apiVersion": "v1",
  "kind": "Secret",
  "type": "Opaque",
  "metadata": {
    "name": "${SECRET_NAME}"
  },
  "data": {
    "token": "$ENCODED_KEY"
  }
}
EOS
    while true; do
        export result=$(post_secret)
        if [ ! -z "$(echo "$result" | grep -i '201 Created')" ]; then
            echo 'Secret created'
            break
        elif [ ! -z "$(echo "$result" | grep -i '409 Conflict')" ]; then
            echo 'Secret exists, clearing before trying again'
            clear_secret
        else
          echo 'Secret creation failed'
          echo $result
        fi
        sleep 15
    done
else
    echo "Failed to get key from maas."
    exit 1
fi
