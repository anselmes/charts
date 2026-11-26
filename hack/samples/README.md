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
kubectl create namespace cicd
kubectl create namespace iam
kubectl create namespace minio
kubectl create namespace operators
kubectl create namespace ucp
```

## Core Services

```shell
kubectl apply -f hack/samples/core/gwapi/envoy.yaml

kubectl apply -f hack/samples/core/eso.yaml

kubectl apply -f hack/samples/core/certmanager.yaml
kubectl apply -f hack/samples/core/operator.yaml

envsubst < hack/samples/core/gateway.yaml | kubectl apply -f -
```

## Identity Services

### Keycloak

Keycloak runs in the `iam` namespace under the Keycloak operator. `harbor/keycloak.yaml` installs the
operator in `operators`, then the Keycloak server, a Percona PostgreSQL cluster, the realm import
named by `KEYCLOAK_REALM_NAME` and the gateway route. External Secrets generates the bootstrap `admin`
password from the `password-generator` ClusterGenerator, so no credential is committed.

Set the realm variables from `hack/samples/example.env` in `hack/samples/.env` (git-ignored). The
Vault and MinIO samples read the same variables:

| Variable                   | Purpose                                 |
| -------------------------- | --------------------------------------- |
| `KEYCLOAK_REALM_NAME`         | Realm id and name shared by the clients |
| `KEYCLOAK_REALM_DISPLAY_NAME` | Realm display name                      |

```shell
set -a && source hack/samples/.env && set +a

envsubst < hack/samples/harbor/keycloak.yaml | kubectl apply -f -

kubectl -n iam get keycloak,keycloakrealmimport,externalsecret
```

Read the bootstrap admin password:

```shell
kubectl -n iam get secret keycloak-admin-password -o jsonpath='{.data.password}' | base64 -d; echo
```

> [!IMPORTANT]
> Keycloak creates the bootstrap admin only when it creates the master realm. If the database
> already holds a master realm that was created without `bootstrapAdmin`, sign-in fails with
> `user_not_found` and the Keycloak log shows only a `temp-admin` user whose password is gone.

To recover on a fresh install, reset the Keycloak schema and restart the pod so that Keycloak
bootstraps again with the generated admin:

> [!CAUTION]
> The reset below drops every realm, user and client in the Keycloak database. Run it only on a
> fresh install, before anything else depends on this Keycloak.

```shell
kubectl -n iam exec "$(kubectl -n iam get pod -l postgres-operator.crunchydata.com/role=primary -o name)" \
  -c database -- psql -d keycloak \
  -c 'DROP SCHEMA keycloak CASCADE; CREATE SCHEMA keycloak AUTHORIZATION keycloak;'

kubectl -n iam delete pod keycloak-0
```

The database user and name are `keycloak`, not the Percona default `keycloak-postgres`. Keycloak runs
an unquoted `SET SEARCH_PATH TO <user>` at startup, which fails on a name with a hyphen.

#### OIDC clients

Applications register with Keycloak through `KeycloakOIDCClient` resources, rendered by the
`clients` list of the `keycloak` chart. A client resource must live in the same namespace as the
Keycloak resource, so each `*-keycloak-client` release uses `targetNamespace: iam`. The client secret
is generated in `iam` and synced into the application's namespace by a ClusterSecretStore:

| Application | Sample                  | Client release           | Secret in the application namespace |
| ----------- | ----------------------- | ------------------------ | ----------------------------------- |
| Vault       | `ucp/vault.yaml`        | `vault-keycloak-client`  | `vault-oidc-client` in `ucp`        |
| MinIO       | `optional/minio.yaml`   | `minio-keycloak-client`  | `minio-oidc-client` in `minio`      |

`harbor/keycloak.yaml` also creates the `external-secrets-store-iam` store and the read-only
`oidc-client-reader` RBAC. The Role names each readable Secret, so add the Secret of any new client to
its `resourceNames`. The client releases reconcile only once Keycloak and the `KEYCLOAK_REALM_NAME`
realm exist, and the Vault release depends on `vault-keycloak-client`, so apply
`harbor/keycloak.yaml` before `ucp/vault.yaml`.

#### Vault group mapping

Vault has two OIDC roles. The `default` role lets any realm user sign in with the `default` policy
only. The `admin` role accepts only users whose `groups` claim contains `vault-admins` and grants
the `superuser` policy. The realm import creates the `vault-admins` group, but only when it creates
a new realm. Keycloak must also emit the `groups` claim. `KeycloakOIDCClient` has no client-scope or
mapper fields, so do this once in the admin console of the realm:

1. Under Client scopes, create a scope `groups` of type Default. Add a mapper of type Group
   Membership with token claim name `groups` and full group path turned off, adding the claim to
   the ID token and to userinfo.
2. Under Clients, open `vault`, then Client scopes, and add `groups` as a Default scope.
3. Under Groups, add your users to `vault-admins`.

Then sign in with the `admin` role:

```shell
bao login -method=oidc role=admin
```

#### MinIO policy mapping

MinIO reads the policy names of a user from the `policy` claim of the token. A user without that
claim cannot sign in. The realm import creates a group `consoleAdmin`, which is the name of the
built-in MinIO administrator policy, so the group name becomes the policy name. Keycloak must emit
the claim, which again takes a one-time step in the realm's admin console:

1. Under Clients, open `minio`, then Client scopes, then `minio-dedicated`, and add a mapper by
   configuration of type Group Membership. Set the token claim name to `policy`, turn full group
   path off, and add the claim to the ID token and to userinfo. The `groups` scope that Vault uses
   does not help here, because it emits a claim named `groups`, not `policy`.
2. Under Groups, add your users to `consoleAdmin`. For other access levels, create groups named
   after other built-in policies, such as `consolereadonly` (browse buckets in the Console),
   `readonly` or `readwrite`. Policy names are case-sensitive: check the exact spelling under
   Access, IAM Policies in the MinIO Console.
3. Check the result under Clients, `minio`, Client scopes, Evaluate. Pick a user and open the
   generated ID token: it must contain `"policy": ["consoleAdmin"]`.

A user who belongs to none of these groups has no `policy` claim, and the Console reports a bare
`Error from IDP` after the Keycloak sign-in. That is expected: add the user to a group.

## Infra Services

Vault (OpenBao) auto-unseals with a NetHSM through PKCS#11 and initializes itself from the
`initialize` stanzas in its config, which create the `admin` userpass user. No recovery key or
root token is generated. It also registers Keycloak as an OIDC login, so apply the Identity
Services section first. Set the NetHSM variables from `hack/samples/example.env` in
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

## Workload

```shell
kubectl apply -f hack/samples/demo.yaml
```

## Optional

### MinIO AIStor

`optional/minio.yaml` holds three Flux releases, each in the namespace that owns it:

| Release                 | Namespace   | Purpose                                                                  |
| ----------------------- | ----------- | ------------------------------------------------------------------------ |
| `minio-keycloak-client` | `iam`       | `KeycloakOIDCClient` for MinIO and its generated client secret           |
| `minio-operator`        | `operators` | AIStor operator, its CRDs and the `minio-license` Secret                 |
| `minio`                 | `minio`     | ObjectStore with KES, the ExternalSecrets, the gateway routes and policy |

MinIO runs with KES as its key manager, using Vault (OpenBao) as the KES keystore, and signs users
in through Keycloak. Before applying the file:

1. Apply `ucp/vault.yaml`. It also creates the `external-secrets-store-ucp` store and the
   read-only `vault-ca-reader` RBAC that let ESO sync the Vault CA into the `minio` namespace. It
   also creates the `external-secrets-store-kube-system` store that syncs the default gateway CA,
   which MinIO needs to trust Keycloak for its OIDC login.
2. Put the AIStor license in Vault at `secret/minio`, property `license`.
3. Apply `harbor/keycloak.yaml`, which the `minio-keycloak-client` release depends on. It creates
   the `external-secrets-store-iam` store that syncs the `minio-oidc-client` secret into the `minio`
   namespace.
4. Create the KES policy and Kubernetes auth role in OpenBao. KES authenticates as the
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

The file reads these variables from `hack/samples/.env`:

| Variable            | Purpose                                              |
| ------------------- | ---------------------------------------------------- |
| `DOMAIN_NAME`       | Base domain of the `minio`, `s3` and `iam` hostnames |
| `KEYCLOAK_REALM_NAME`  | Keycloak realm that the `minio` client is created in |
| `MINIO_SITE_NAME`   | Site name reported by the object store               |
| `MINIO_SITE_REGION` | Site region reported by the object store             |

Apply the file with `envsubst` and an explicit variable list. A bare `envsubst` blanks
`${MINIO_KES_IDENTITY}`, which KES expands itself at startup from the identity the operator injects.
Flux then orders the releases: `minio` waits for `minio-operator`, the gateway and the External
Secrets generators, and `minio-keycloak-client` waits for Keycloak.

```shell
set -a && source hack/samples/.env && set +a

envsubst '${DOMAIN_NAME} ${KEYCLOAK_REALM_NAME} ${MINIO_SITE_NAME} ${MINIO_SITE_REGION}' \
  < hack/samples/optional/minio.yaml | kubectl apply -f -
```

Check that the releases and the object store are healthy:

```shell
kubectl get helmrelease -A | grep minio
kubectl -n operators get pods,externalsecret
kubectl -n minio get objectstore,pods,externalsecret
kubectl -n iam get keycloakoidcclient minio
```

`minio-pool-0-0` and `minio-kes` should be `2/2 Running`, and the `minio-env-configuration`,
`vault-ca`, `default-gateway-ca` and `minio-oidc-client` ExternalSecrets should be `SecretSynced`.
The operator reads the AIStor license from its own namespace, so `minio-license` is in `operators`
and must be `SecretSynced` there. Without it the operator logs `error checking license` and never
reconciles the ObjectStore. The `minio` client should report no errors.

To sign in through Keycloak, add the `policy` claim mapper and the `consoleAdmin` group membership
described under Identity Services (MinIO policy mapping). The Console login page then offers a
Keycloak sign-in.

### Other

```shell
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
