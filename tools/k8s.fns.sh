#!/bin/bash

get_cluster_domain() {
    kubectl get configmap coredns \
        -n kube-system \
        -o yaml \
        | yq '.data.Corefile' \
        | grep kubernetes \
        | xargs \
        | awk '{print $2}'
}

is_crd_available() {
    local resource="${1}"
    local context="${2:-"$(kubectl config current-context)"}"
    if [ -z "${resource}" ]; then
        echo >&2 "first argument missing: is_crd_available \${crd_name}"
        return 2
    fi
    if kubectl --context="${context}" describe "crd/${resource}" --request-timeout "5s" &> /dev/null; then
        echo "true"
    fi
    echo "false"
}

secret_exists() {
    local name="${1}"
    local ns="${2}"
    kubectl get secret "${name}" -n "${ns}" >/dev/null 2>&1
}

wait_for_namespace() {
    local ns="${1}"
    local timeout="${2:-"15s"}"
    if [ -z "${ns}" ]; then
        echo >&2 "first argument missing: wait_for_namespace \${namespace}"
        return 2
    fi
    kubectl wait "namespace/${ns}" \
        --for jsonpath='{.status.phase}=Active' \
        --timeout="${timeout}"
    local ref=$?
    return $ref
}

wait_for_crd() {
    local resource="${1}"
    if [ -z "${resource}" ]; then
        echo >&2 "first argument missing: wait_for_crd \${crd_name}"
        return 2
    fi
    local context="${2:-"$(kubectl config current-context)"}"
    local max_wait_secs=${3:-300}
    local interval_secs=${4:-2}
    local start_time=$(date +%s)
    while true; do
        current_time=$(date +%s)
        if (( (current_time - start_time) > max_wait_secs )); then
            echo >&2 "crd ${resource}: bailing out after ${max_wait_secs} seconds"
            return 3
        fi
        if kubectl --context="${context}" describe "crd/${resource}" --request-timeout "5s" &> /dev/null; then
            >&2 echo "crd ${resource}: found"
            break
        else
            >&2 echo "crd ${resource}: not found, waiting"
            sleep $interval_secs
        fi
    done
}

wait_for_resource() {
    local resource="${1}"
    if [ -z "${resource}" ]; then
        echo >&2 "first argument missing: wait_for_resource \${resource}"
        return 2
    fi
    local ns="${2:-default}"
    local context="${3:-"$(kubectl config current-context)"}"
    local max_wait_secs=${4:-300}
    local interval_secs=${5:-2}
    local start_time=$(date +%s)
    while true; do
        current_time=$(date +%s)
        if (( (current_time - start_time) > max_wait_secs )); then
            echo >&2 "${resource}.${ns}: bailing out after ${max_wait_secs} seconds"
            return 3
        fi

        _e=false
        if [[ $- == *e* ]]; then
            set +e
            _e=true
        fi

        if kubectl --context="${context}" -n "$ns" describe "${resource}" --request-timeout "5s" &> /dev/null; then
            echo >&2 "${resource}.${ns}: found"
            [ "${_e}" = "true" ] && set -e
            break
        else
            [ "${_e}" = "true" ] && set -e
            echo >&2 "${resource}.${ns}: not found, waiting"
            sleep $interval_secs
        fi
    done
}
