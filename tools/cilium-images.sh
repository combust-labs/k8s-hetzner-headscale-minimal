#!/bin/bash

if [ -z "${1}" ]; then
    echo >&2 "expected the first argument to be Cilium version"
    exit 1
fi

set -eu
version="${1}"
path="/tmp/chart-cilium/${version}"

helm search repo cilium/cilium
mkdir -p "${path}" && cd "${path}"
helm pull cilium/cilium --version "${version}"
tar xf "cilium-${version}.tgz"

cilium_image_version=$(cat "${path}/cilium/values.yaml" | yq '.image.repository + ":" + .image.tag')
cilium_certgen_image_version=$(cat "${path}/cilium/values.yaml" | yq '.certgen.image.repository + ":" + .certgen.image.tag')
cilium_clustermesh_image_version=$(cat "${path}/cilium/values.yaml" | yq '.clustermesh.apiserver.image.repository + ":" + .clustermesh.apiserver.image.tag')
cilium_envoy_image_version=$(cat "${path}/cilium/values.yaml" | yq '.envoy.image.repository + ":" + .envoy.image.tag')
cilium_operator_image_version=$(cat "${path}/cilium/values.yaml" | yq '.operator.image.repository + ":" + .operator.image.tag')
cilium_ztunnel_image_version=$(cat "${path}/cilium/values.yaml" | yq '.encryption.ztunnel.image.repository + ":" + .encryption.ztunnel.image.tag')
hubble_relay_image_version=$(cat "${path}/cilium/values.yaml" | yq '.hubble.relay.image.repository + ":" + .hubble.relay.image.tag')
hubble_ui_backend_image_version=$(cat "${path}/cilium/values.yaml" | yq '.hubble.ui.backend.image.repository + ":" + .hubble.ui.backend.image.tag')
hubble_ui_frontend_image_version=$(cat "${path}/cilium/values.yaml" | yq '.hubble.ui.frontend.image.repository + ":" + .hubble.ui.frontend.image.tag')
nodeinit_image_version=$(cat "${path}/cilium/values.yaml" | yq '.nodeinit.image.repository + ":" + .nodeinit.image.tag')

echo >&2 "-----------------------"
echo >&2 "[Cilium ${version}] images:"
echo >&2 " - cilium: ${cilium_image_version}"
echo >&2 " - certgen: ${cilium_certgen_image_version}"
echo >&2 " - cilium-envoy: ${cilium_envoy_image_version}"
echo >&2 " - cilium-operator: ${cilium_operator_image_version}"
echo >&2 " - clustermesh: ${cilium_clustermesh_image_version}"
echo >&2 " - ztunnel: ${cilium_ztunnel_image_version}"
echo >&2 "[Hubble for Cilium ${version}] images:"
echo >&2 " - Hubble Relay: ${hubble_relay_image_version}"
echo >&2 " - Hubble UI backend: ${hubble_ui_backend_image_version}"
echo >&2 " - Hubble UI frontend: ${hubble_ui_frontend_image_version}"
echo >&2 "[Other Cilium ${version}] images:"
echo >&2 " - nodeinit: ${nodeinit_image_version}"
echo >&2 "-----------------------"

cd -
rm -rf "/tmp/chart-cilium/${version}"