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
kubectl create namespace cicd
kubectl create namespace ucp
```

## Core Services

```shell
# Gateway API
kubectl apply -f hack/samples/gw/envoy.yaml

# Cert Manager
kubectl apply -f hack/samples/ca/certmanager.yaml

# Gateway
kubectl apply -f hack/samples/gw/gateway.yaml

# Operators
kubectl apply -f hack/samples/operator.yaml
```

## MSR

```shell
kubectl --namespace cicd \
  create secret generic msr-redis-secret \
  --from-literal REDIS_PASSWORD=<(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)

kubectl apply -f hack/samples/ca/msrca.yaml
kubectl apply -f hack/samples/db/msrdb.yaml
# TODO: msr
```

## Vault

```shell
openssl rand -out hack/unseal-20251231-1.key 32
openssl rand -out hack/unseal-20260122-1.key 32

kubectl --namespace ucp create secret generic unseal-20251231-1 --from-file hack/unseal-20251231-1.key
kubectl --namespace ucp create secret generic unseal-20260122-1 --from-file hack/unseal-20260122-1.key

kubectl apply -f hack/samples/ca/vaultca.yaml
kubectl apply -f hack/samples/db/vaultdb.yaml
kubectl apply -f hack/samples/vault.yaml
```

## Workload

### MaaS

```shell
# postgres
kubectl apply -f hack/samples/db/maasdb.yaml

# TODO: maas
```

### Demo App

```shell
kubectl apply -f hack/samples/demo.yaml
```

### TODO: Workload Services
