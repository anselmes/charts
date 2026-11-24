# Samples

## Prerequisites

Create a kubernetes cluster and install flux

```shell
# deploy flux
helm upgrade flux --install --create-namespace --namespace sre service/flux

# update flux
kubectl apply -f hack/samples/repository.yaml
kubectl apply -f hack/samples/flux.yaml

# namespaces
kubectl create namespace cert-manager
kubectl create namespace operators

kubectl create namespace ucp
kubectl create namespace cicd

kubectl create namespace fleetdm
kubectl create namespace minio

kubectl create namespace knative
```

## Core Services

```shell
kubectl apply -f hack/samples/core/gwapi/envoy.yaml

kubectl apply -f hack/samples/core/eso.yaml

kubectl apply -f hack/samples/core/certmanager.yaml
kubectl apply -f hack/samples/core/operator.yaml

envsubst < hack/samples/core/gateway.yaml | kubectl apply -f -
```

## Infra Services

Vault (OpenBao) auto-unseals with a NetHSM through PKCS#11 and initializes itself from the
`initialize` stanzas in its config, which create the `admin` userpass user. No recovery key or
root token is generated. Set the NetHSM variables from `hack/samples/example.env` in
`hack/samples/.env` (git-ignored) before applying anything below:

| Variable                     | Purpose                                                |
| ---------------------------- | ------------------------------------------------------ |
| `NETHSM_ADDRESS`             | NetHSM host or `host:port` reachable from the cluster  |
| `NETHSM_OPERATOR_USERNAME`   | NetHSM user with the Operator role                     |
| `NETHSM_OPERATOR_PASSPHRASE` | That user's passphrase, used as the seal `pin`         |

The NetHSM must be version 5.0 or later and hold the key `bao-root-rsa`
(`RSA_Decryption_OAEP_SHA256`) with a `label` set to `bao-root-rsa`. The PKCS#11 library matches
the seal's `key_label` against that label, so a key with only an id is never found.

```shell
set -a && source hack/samples/.env && set +a

# optional: local NetHSM test instance (NETHSM_ADDRESS=<host-ip>:8443, operator/OperatorOperator)
docker compose -f hack/samples/compose.yml up -d

kubectl -n ucp create configmap p11nethsm \
  -o=yaml \
  --dry-run=client \
  --from-literal=p11nethsm.conf="$(envsubst < hack/samples/p11nethsm.conf)" | kubectl apply -f -

kubectl apply -f hack/samples/ucp/ldap.yaml

envsubst < hack/samples/ucp/vault.yaml | kubectl apply -f -
envsubst < hack/samples/ucp/netbox.yaml | kubectl apply -f -
envsubst < hack/samples/ucp/maas.yaml | kubectl apply -f -
```

## Shared Services

```shell
envsubst < hack/samples/harbor/fleet.yaml | kubectl apply -f -
envsubst < hack/samples/harbor/msr.yaml | kubectl apply -f -
```

## CI Service

```shell
envsubst < hack/samples/cicd/semaphore.yaml | kubectl apply -f -

kubectl apply -f hack/samples/cicd/coder.yaml
kubectl apply -f hack/samples/cicd/gitea.yaml
kubectl apply -f hack/samples/cicd/sonarqube.yaml
```

## Knative

```shell
export GATEWAY_SERVICE="$(kubectl -n kube-system get service --selector gateway.envoyproxy.io/owning-gateway-name=default-gateway -o custom-columns=NAME:.metadata.name --no-headers)"

kubectl apply -f hack/samples/knative/operator.yaml

envsubst < hack/samples/knative/serving.yaml | kubectl apply -f -
```

## Workload

```shell
kubectl apply -f hack/samples/demo.yaml
```

## Optional

### MinIO AIStor

MinIO runs with KES as its key manager, using Vault (OpenBao) as the KES keystore. Before applying
`optional/minio.yaml`:

1. Apply `ucp/vault.yaml`. It also creates the `external-secrets-store-ucp` store and the
   read-only `vault-ca-reader` RBAC that let ESO sync the Vault CA into the `minio` namespace.
2. Put the AIStor license in Vault at `secret/minio`, property `license`.
3. Create the KES policy and Kubernetes auth role in OpenBao. KES authenticates as the
   operator-created `minio-sa` service account:

```shell
bao policy write minio-kes - <<'EOF'
path "secret/data/kes/minio/*"     { capabilities = ["create", "read", "update", "delete"] }
path "secret/metadata/kes/minio/*" { capabilities = ["list", "read", "delete"] }
EOF

bao write auth/kubernetes/role/minio-kes \
  bound_service_account_names=minio-sa \
  bound_service_account_namespaces=minio \
  policies=minio-kes ttl=1h
```

Pass `envsubst` an explicit variable list. A bare `envsubst` blanks `${MINIO_KES_IDENTITY}`, which
KES expands itself at startup from the identity the operator injects:

```shell
yq '.spec.values' hack/samples/optional/minio.yaml \
  | envsubst '${DOMAIN_NAME} ${MINIO_SITE_NAME} ${MINIO_SITE_REGION}' \
  | helm upgrade --install --namespace minio minio service/aistor --values -
```

Check that the release is healthy:

```shell
kubectl -n minio get pods,externalsecret
```

`minio-pool-0-0` and `minio-kes` should be `2/2 Running`, and the `minio-env-configuration`,
`minio-license` and `vault-ca` ExternalSecrets should be `SecretSynced`.

### Other

```shell
kubectl apply -f hack/samples/optional/openebs.yaml
kubectl apply -f hack/samples/optional/gatekeeper.yaml

kubectl apply -f hack/samples/optional/cloudflare.yaml
kubectl apply -f hack/samples/optional/netbird.yaml
````

```sh
export DNS_SERVER_1=""
export DNS_SERVER_2=""

# export SEMAPHORE_RUNNER_TOKEN="" # From UI
export SEMAPHORE_CA_CERT="hack/samples/ca.crt"
export SEMAPHORE_RUNNER_PRIVATE_KEY_FILE="hack/samples/private.key" # From UI
export SEMAPHORE_RUNNER_TOKEN=$(kubectl -n sre get secret semaphore-token-secret -o jsonpath='{.data.token}' | base64 -d)

kubectl -n kube-system get secret http-gw-cert -o jsonpath='{.data.ca\.crt}' | base64 -d >hack/ca.crt

# FIXME: register
container run --rm \
  --dns ${DNS_SERVER_1} \
  --dns ${DNS_SERVER_2} \
  -e SEMAPHORE_RUNNER_PRIVATE_KEY_FILE=/var/lib/semaphore/runner.key \
  -e SEMAPHORE_WEB_ROOT=https://semaphore.svc.mockingbird.testplay.io \
  -e SEMAPHORE_RUNNER_TOKEN=${SEMAPHORE_RUNNER_TOKEN} \
  -v ${SEMAPHORE_CA_CERT}:/etc/ssl/certs/ca-certificates.crt:ro \
  -v semaphore_config:/etc/semaphore \
  -v semaphore_data:/var/lib/semaphore \
  -d semaphoreui/runner:v2.18.27 \
  runner register --name semaphore-runner

# FIXME: runner
container run --name semaphore-runner \
  --dns ${DNS_SERVER_1} \
  --dns ${DNS_SERVER_2} \
  -e SEMAPHORE_RUNNER_PRIVATE_KEY_FILE=/var/lib/semaphore/runner.key \
  -e SEMAPHORE_WEB_ROOT=https://semaphore.svc.mockingbird.testplay.io \
  -e SEMAPHORE_RUNNER_TOKEN=${SEMAPHORE_RUNNER_TOKEN} \
  -v ${SEMAPHORE_CA_CERT}:/etc/ssl/certs/ca-certificates.crt:ro \
  -v semaphore_config:/etc/semaphore \
  -v semaphore_data:/var/lib/semaphore \
  -v semaphore_tmp:/tmp/semaphore \
  -d semaphoreui/runner:v2.18.27

# NOTE: runner created from ui
container run --name semaphore-runner \
  --dns ${DNS_SERVER_1} \
  --dns ${DNS_SERVER_2} \
  -e SEMAPHORE_WEB_ROOT=https://semaphore.${DOMAIN_NAME} \
  -e SEMAPHORE_RUNNER_TOKEN=${SEMAPHORE_RUNNER_TOKEN} \
  -e SEMAPHORE_RUNNER_PRIVATE_KEY_FILE=/config.runner.key \
  -v ${SEMAPHORE_CA_CERT}:/etc/ssl/certs/ca-certificates.crt:ro \
  -v ${SEMAPHORE_RUNNER_PRIVATE_KEY_FILE}:/config.runner.key \
  -d semaphoreui/runner:v2.18.27
```
