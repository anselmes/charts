#!/bin/bash

set -eo pipefail

BUILD_DIR="build"
REGISTRY="oci://ghcr.io/labsonline/charts"

CLUSTERS=()
SERVICES=(
  ca
  ccm
  cni
  csi
  gateway
)
TEMPLATES=(
  ca-service-template
  crd-service-template
  gateway-service-template
)

mkdir -p "${BUILD_DIR}"

build() {
  local chart_path="$1"
  local output_dir="$2"

  helm template "$(basename "${chart_path}")" "${chart_path}" --include-crds >/dev/null || {
    echo "Error: Failed to template chart ${chart_path}"
    exit 1
  }

  helm package "${chart_path}" --destination "${output_dir}"
}

# Package charts.

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
  helm push "${chart}" "${REGISTRY}"
done
