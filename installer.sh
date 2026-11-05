#!/bin/bash

kubeconfig=""
set -euo pipefail
base="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

backup_file=""

cert_manager_ns="cert-manager"
cert_manager_values_file=""
cert_manager_version="v1.21.3"

cilium_values_file=""
cluster_file=""
cluster_launch=false
cluster_bootstrap=false
cluster_show_cilium_version=false
hcloud_token_file=""

route53_dns01_credential_file=""

while (( "$#" )); do
    case "${1}" in
        --cert-manager-ns)
            cert_manager_ns="${2}"
            shift 2
            ;;
        --cert-manager-values-file)
            cert_manager_values_file="${2}"
            shift 2
            ;;
        --cert-manager-version)
            cert_manager_version="${2}"
            shift 2
            ;;
        --cilium-values-file)
            cilium_values_file="${2}"
            shift 2
            ;;
        --cluster-file)
            cluster_file="${2}"
            shift 2
            ;;
        --cluster-bootstrap)
            cluster_bootstrap=true
            shift
            ;;
        --cluster-launch)
            cluster_launch=true
            shift
            ;;
        --from-backup-file)
            backup_file="${2}"
            shift 2
            ;;
        --hcloud-token-file)
            hcloud_token_file="${2}"
            shift 2
            ;;
        --route53-dns01-credential-file)
            route53_dns01_credential_file="${2}"
            shift 2
            ;;
        --show-cilium-version)
            cluster_show_cilium_version="true"
            shift
            ;;
        -*)
            echo "error: unsupported flag ${1}" >&2
            exit 1
            ;;
    esac
done

# always required:
[ -z "${cluster_file}" ] && echo >&2 "missing argument: --cluster-file" && exit 1
[ ! -f "${cluster_file}" ] && echo >&2 "file at --cluster-file doesn't exist" && exit 1

source "${base}/tools/k8s.fns.sh"

export_kubeconfig() {
    # establish kubeconfig path:
    if [ -z "${kubeconfig}" ]; then
        kubeconfig=$(cat "${cluster_file}" \
            | yq '.kubeconfig_path' -r \
            | sed -e 's!~!'${HOME}'!')
        if [ ! -f "${kubeconfig}" ]; then
            if [ "${cluster_bootstrap}" = "true" ]; then
                echo >&2 "error: kubeconfig at ${kubeconfig} does not exist"
                exit 1
            fi
        fi
        export KUBECONFIG="${kubeconfig}"
    fi
}

if [ "${cluster_show_cilium_version}" = "true" ]; then
    cilium_version=$(cat "${cluster_file}" | yq '.networking.cni.cilium.chart_version' -r | sed -e 's/^v//')
    echo "${cilium_version}"
    exit 0
fi

if [ "${cluster_launch}" = "true" ]; then

    [ -z "${cilium_values_file}" ] && echo >&2 "missing argument: --cilium-values-file" && exit 1
    [ ! -f "${cilium_values_file}" ] && echo >&2 "file at --cilium-values-file doesn't exist" && exit 1
    [ -z "${hcloud_token_file}" ] && echo >&2 "missing argument: --hcloud-token-file" && exit 1
    [ ! -f "${hcloud_token_file}" ] && echo >&2 "file at --hcloud-token-file doesn't exist" && exit 1

    export_kubeconfig
    export HCLOUD_TOKEN=$(cat "${hcloud_token_file}")

    # hetzner-ks3 requires the cluster declaration in a yaml file
    # the content needs to be changed, hence a temp file...
    temp_dir=$(mktemp -d)
    cat "${cluster_file}" \
        | yq '( .networking.cni.cilium.helm_values_path = "'${cilium_values_file}'" )' \
        > "${temp_dir}/cluster.yaml"
    # Install base cluster with CNI only:
    hetzner-k3s create --config="${temp_dir}/cluster.yaml"
    rm -rf "${temp_dir}"

    set +e
    wait_for_resource daemonsets/cilium "kube-system"
    wait_for_resource daemonsets/cilium-envoy "kube-system"
    wait_for_resource deployments/cilium-operator "kube-system"
    set -e

    kubectl rollout status \
        daemonsets/cilium \
        -n "kube-system" \
        --timeout=90s

    kubectl rollout status \
        daemonsets/cilium-envoy \
        -n "kube-system" \
        --timeout=90s

    kubectl rollout status \
        deployments/cilium-operator \
        -n "kube-system" \
        --timeout=90s
    
    kubectl rollout status \
        deployment/hcloud-cloud-controller-manager \
        -n kube-system \
        --timeout=90s

fi

[ "${cluster_bootstrap}" = "false" ] && exit 0

export_kubeconfig

[ -z "${cert_manager_values_file}" ] && echo >&2 "missing argument: --cert-manager-values-file" && exit 1
[ ! -f "${cert_manager_values_file}" ] && echo >&2 "file at --cert-manager-values-file doesn't exist" && exit 1
[ -z "${route53_dns01_credential_file}" ] && echo >&2 "missing argument: --route53-dns01-credential-file" && exit 1
[ ! -f "${route53_dns01_credential_file}" ] && echo >&2 "file at --route53-dns01-credential-file doesn't exist" && exit 1

if [ -n "${backup_file}" ]; then
    [ ! -f "${backup_file}" ] && echo >&2 "file at --from-backup-file doesn't exist" && exit 1
fi

# Add Gateway API:
cilium_version=$(cat "${cluster_file}" | yq '.networking.cni.cilium.chart_version' -r | sed -e 's/^v//' | cut -d '.' -f 1,2)
case "${cilium_version}" in
    "1.18")
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
        wait_for_crd "tlsroutes.gateway.networking.k8s.io"
        # Restart the Cilium Operator for CRDs to be recognised.
        kubectl rollout restart deployment/cilium-operator -n kube-system
        ;;
    "1.19")
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
        kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.4.1/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
        wait_for_crd "tlsroutes.gateway.networking.k8s.io"
        # Restart the Cilium Operator for CRDs to be recognised.
        kubectl rollout restart deployment/cilium-operator -n kube-system
        ;;
    "1.20")
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_listenersets.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_backendtlspolicies.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_tcproutes.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_tlsroutes.yaml
        kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.6.3/config/crd/standard/gateway.networking.k8s.io_udproutes.yaml
        wait_for_crd "tlsroutes.gateway.networking.k8s.io"
        # Restart the Cilium Operator for CRDs to be recognised.
        kubectl rollout restart deployment/cilium-operator -n kube-system
        ;;
    *)
        ;;
esac

# Create the default GatewayClass because our Cilium installs without it.  
# The Gateway class requires Gateway API CRDs but we don't control
# the installation order so we need to add CRDs later, and create 
# the GatewayClass.

kubectl apply -f "${base}/headscale/gatewayclass.yaml"

## Install cert-manager.
## ---------------------

set +e
kubectl create namespace "${cert_manager_ns}"
set -e

wait_for_namespace "${cert_manager_ns}"

helm template cert-manager jetstack/cert-manager \
    --no-hooks \
    --version "${cert_manager_version}" \
    --namespace "${cert_manager_ns}" \
    -f "${cert_manager_values_file}" \
    --set "namespace=${cert_manager_ns}" \
    | kubectl apply -f -

## Wait for cert-manager to come up.
## ---------------------------------

wait_for_resource \
    deployment/cert-manager \
    "${cert_manager_ns}"

wait_for_resource \
    deployment/cert-manager-cainjector \
    "${cert_manager_ns}"

wait_for_resource \
    deployment/cert-manager-webhook \
    "${cert_manager_ns}"

kubectl rollout status \
    deployment/cert-manager \
    -n "${cert_manager_ns}" \
    --timeout=90s

kubectl rollout status \
    deployment/cert-manager-cainjector \
    -n "${cert_manager_ns}" \
    --timeout=90s

kubectl rollout status \
    deployment/cert-manager-webhook \
    -n "${cert_manager_ns}" \
    --timeout=90s

## Install Headscale.
## ------------------

set +e
HEADSCALE_NS=$(cat "${base}/headscale/namespace.yaml" \
    | yq '.metadata.name')
kubectl apply -f "${base}/headscale/namespace.yaml"
set -e

wait_for_namespace "${HEADSCALE_NS}"

## Configure the Route53 DNS-01 solver.
## ------------------------------------

if ! secret_exists route53-dns01-credential-secret "${HEADSCALE_NS}"; then
    kubectl create secret generic route53-dns01-credential-secret \
        -n "${HEADSCALE_NS}" \
        --from-env-file=${route53_dns01_credential_file}
else
    echo >&2 "secret ${HEADSCALE_NS}/route53-dns01-credential-secret already exists"
fi

## Install the gateway, issuers, certificates, and Headscale itself.
## -----------------------------------------------------------------

kubectl apply -f "${base}/headscale/gateway.yaml"
kubectl apply -f "${base}/headscale/cert-manager.outside.yaml"
kubectl apply -f "${base}/headscale/cert-manager.inside.yaml"
kubectl apply -f "${base}/headscale/headscale-pvc.yaml"
kubectl apply -f "${base}/headscale/headscale-config.yaml"

if [ -n "${backup_file}" ]; then
    kubectl apply -f "${base}/headscale/headscale-shell.yaml"
    kubectl rollout status \
        deployment/headscale-shell \
        -n headscale \
        --timeout=90s
    shell_pod_name=$(kubectl get pods \
        -l headscale/component=shell \
        -n headscale \
        --output jsonpath='{.items[0].metadata.name}')
    kubectl cp "${backup_file}" \
        "headscale/${shell_pod_name}:/opt/headscale/db.sqlite"
    kubectl exec -ti "${shell_pod_name}" -n headscale \
        -- chown root:root /opt/headscale/db.sqlite
    kubectl scale deployment/headscale-shell -n headscale --replicas 0
fi

kubectl apply -f "${base}/headscale/headscale-server.yaml"
