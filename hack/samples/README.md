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
```

## Core Services

```shell
kubectl apply -f hack/samples/core/eso.yaml

kubectl apply -f hack/samples/core/certmanager.yaml
kubectl apply -f hack/samples/core/operator.yaml

envsubst < hack/samples/core/gateway.yaml | kubectl apply -f -
```

## Infra Services

```shell
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

## Workload

```shell
kubectl apply -f hack/samples/demo.yaml
```

## Optional

```shell
envsubst < hack/samples/optional/minio.yaml | kubectl apply -f -

kubectl apply -f hack/samples/optional/openebs.yaml
kubectl apply -f hack/samples/optional/gatekeeper.yaml

kubectl apply -f hack/samples/optional/gwapi/envoy.yaml

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
