#!/bin/bash

set -eo pipefail

BUILD_DIR=$(mktemp -d)
REGISTRY="oci://ghcr.io/labsonline/charts"

UPSTREAM=(
  rockoon
)
CLUSTERS=()
SERVICES=(
  ca
  ccm
  cni
  csi
  edns
  flux
  gateway
  gwapi
  kcm
  knative
  monitoring
  openstack
  pinniped
)
TEMPLATES=(
  ca-service-template
  cni-service-template
  csi-service-template
  crd-service-template
  edns-service-template
  gateway-service-template
  gwapi-service-template
  knative-service-template
  monitoring-service-template
  openstack-service-template
  pinniped-service-template
)

mkdir -p "${BUILD_DIR}"

build() {
  local chart_path="$1"
  local output_dir="$2"

  helm dependency update "${chart_path}"
  helm lint "${chart_path}"

  # FIXME: Templating is currently disabled due to issues with charts that have
  # dependencies not present in the local environment.
  # helm template "$(basename "${chart_path}")" "${chart_path}" --include-crds >/dev/null

  helm package "${chart_path}" --destination "${output_dir}"
}

# Package charts.

for chart in "${UPSTREAM[@]}"; do
  build "upstream/${chart}" "${BUILD_DIR}"
done

for cluster in "${CLUSTERS[@]}"; do
  build "cluster/${cluster}" "${BUILD_DIR}"
done

for service in "${SERVICES[@]}"; do
  build "service/${service}" "${BUILD_DIR}"
done

for template in "${TEMPLATES[@]}"; do
  build "template/${template}" "${BUILD_DIR}"
done

# Push charts.
for chart in "${BUILD_DIR}"/*.tgz; do
  chart_name=$(basename "${chart}" .tgz)

  # Check if this is a template chart
  is_template=false
  for template in "${TEMPLATES[@]}"; do
    if [[ "${chart_name}" == "${template}"* ]]; then
      is_template=true
      break
    fi
  done

  if [[ "${is_template}" == "true" ]]; then
    helm push "${chart}" "${REGISTRY}/servicetemplate"
  else
    helm push "${chart}" "${REGISTRY}"
  fi
done
