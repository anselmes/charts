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
kubectl apply -f hack/samples/certmanager.yaml

# Gateway
kubectl apply -f hack/samples/gw/gateway.yaml

# Operators
kubectl apply -f hack/samples/operator.yaml
```

## Vault

```shell
openssl rand -out hack/unseal-20251231-1.key 32
openssl rand -out hack/unseal-20260122-1.key 32

kubectl --namespace ucp create secret generic unseal-20251231-1 --from-file hack/unseal-20251231-1.key
kubectl --namespace ucp create secret generic unseal-20260122-1 --from-file hack/unseal-20260122-1.key
kubectl --namespace ucp create secret generic vault-initial-admin-password --from-literal password=$(openssl rand -hex 8)

kubectl apply -f hack/samples/vault.yaml
kubectl apply -f hack/samples/gw/vault.yaml
```

## Workload

```shell
# MSR
kubectl apply -f hack/samples/msr.yaml

# Demo App
kubectl apply -f hack/samples/demo.yaml

# Netbox
kubectl --namespace ucp \
  create secret generic \
  netbox-credential \
  --from-literal email=admin@orb.locals \
  --from-literal username=admin \
  --from-literal password=$(openssl rand -hex 8) \
  --from-literal api_token=$(openssl rand -base64 32)

kubectl --namespace ucp \
  create secret generic \
  netbox-oidc-credential \
  --from-literal oidc-vault.yaml="SOCIAL_AUTH_OIDC_KEY: ${SOCIAL_AUTH_OIDC_KEY}
SOCIAL_AUTH_OIDC_SECRET: ${SOCIAL_AUTH_OIDC_SECRET}"

kubectl apply -f hack/samples/netbox.yaml
```
