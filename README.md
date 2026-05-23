# charts

```shell
export CHART_NAME=""
export CHART_VERSION=""
export RELEASE_NAME=""
export RELEASE_NAMESPACE=""

# install service template with helm
helm upgrade --install $RELEASE_NAME oci://ghcr.io/labsonline/charts/kgst --namespace=$RELEASE_NAMESPACE --set kgst.chart=${CHART_NAME}:${CHART_VERSION}

# install service template with helmrelease
echo <<EOF | kubectl apply -f -
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: ${RELEASE_NAME}-tpl
  namespace: $RELEASE_NAMESPACE
spec:
  interval: 10m0s
  releaseName: ${RELEASE_NAME}-tpl
  timeout: 15m0s
  chart:
    spec:
      interval: 5m
      chart: kgst
      version: 2.0.2
      sourceRef:
        kind: HelmRepository
        name: labsonline-catalog
        namespace: sre
  install:
    remediation:
      remediateLastFailure: true
      retries: 3
  values:
    chart: ${CHART_NAME}:${CHART_VERSION}
EOF
```

---

[![OpenSSF Scorecard][ossf-score-badge]][ossf-score-link]
[![Contiuos Integration][ci-badge]][ci-link]
[![Review][review-badge]][review-link]

[ossf-score-badge]: https://api.securityscorecards.dev/projects/github.com/anselmes/charts/badge
[ossf-score-link]: https://securityscorecards.dev/viewer/?uri=github.com/anselmes/charts
[ci-badge]: https://github.com/anselmes/charts/actions/workflows/cicd.yml/badge.svg
[ci-link]: https://github.com/anselmes/charts/actions/workflows/cicd.yml
[review-badge]: https://github.com/anselmes/charts/actions/workflows/required/anselmes/cicd/.github/workflows/review.yml/badge.svg
[review-link]: https://github.com/anselmes/charts/actions/workflows/required/anselmes/cicd/.github/workflows/review.yml

---

Copyright (c) 2023 Schubert Anselme <schubert@anselm.es>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.
