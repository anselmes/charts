# KCM Umbrella Chart

This umbrella chart installs the KCM controller and its supporting dependencies. You select exactly one implementation:
- OSS `kcm` controller
- Enterprise `k0rdent-enterprise` controller

## Included Components
- Controller: OSS `kcm` or Enterprise `k0rdent-enterprise`
- Core dependencies (managed via subcharts of the selected controller): `cert-manager`, `cluster-api-operator`, `velero`
- Enterprise UI: `k0rdent-ui` (enabled when using enterprise values)
- Optional integration knobs (via values): Flux controllers and other provider templates

Exact components are determined by the selected implementation and your values.

## Mutual Exclusion
- You may leave both toggles `false` (default) to install neither.
- To enable one implementation, set exactly one to `true` and keep the other `false`.
  - OSS: `kcm.install = true`, Enterprise: `k0rdent-enterprise.install = false`
  - Enterprise: `k0rdent-enterprise.install = true`, OSS: `kcm.install = false`
- A render-time guard enforces mutual exclusion and fails only if both are `true`. See [templates/dependency.yaml](templates/dependency.yaml).

## Helm commands
- Render OSS only:
  - `helm template my-kcm . --set kcm.install=true`
- Render Enterprise only:
  - `helm template my-kcm . --set k0rdent-enterprise.install=true`
- Install OSS only:
  - `helm install my-kcm . --set kcm.install=true`
- Install Enterprise only:
  - `helm install my-kcm . --set k0rdent-enterprise.install=true`

## Version Hints
Chart dependencies are pinned in [Chart.yaml](Chart.yaml). Image tags and template registries for each implementation are shown in [values.yaml](values.yaml) comments and defaults.

### Enterprise-only values
```yaml
kcm:
  install: false
k0rdent-enterprise:
  install: true
```

### Neither (default) values
```yaml
kcm:
  install: false
k0rdent-enterprise:
  install: false
```

## Sharing Common Values (DRY)
Upstream subcharts do not consume `.Values.global`. Keep shared configuration DRY using YAML anchors and merge keys:

```yaml
common: &common
  nodeSelector:
    kubernetes.io/os: linux
  imagePullSecrets:
    - name: regcred

kcm:
  install: true
  <<: *common

k0rdent-enterprise:
  install: false
  <<: *common
```

Alternatively, pass synchronized overrides via CLI:

```bash
helm template my-kcm . \
  --set kcm.nodeSelector."kubernetes\.io/os"=linux \
  --set k0rdent-enterprise.nodeSelector."kubernetes\.io/os"=linux
```

## References
- Mutual-exclusion guard: [templates/dependency.yaml](templates/dependency.yaml)
- Dependencies and conditions: [Chart.yaml](Chart.yaml)
