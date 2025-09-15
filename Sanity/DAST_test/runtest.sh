#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/tang-operator/Sanity
#   Description: Basic functionality tests of the tang operator
#   Author: Martin Zeleny <mzeleny@redhat.com>
#   Author: Sergio Arroutbi <sarroutb@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2021 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment (guard to avoid double-source warnings)
if [ -z "${BEAKERLIB_INCLUDED:-}" ]; then
    . /usr/share/beakerlib/beakerlib.sh || exit 1
    BEAKERLIB_INCLUDED=1
fi

# --- AUTH HELPER ---
ocpopGetAuth() {
    local sa_name=${1:-dast-test-sa}
    local namespace api_host_port token
    local oc_bin="${OC_CLIENT:-oc}"
    local -a oc_cmd=("${oc_bin}")

    if [ -s /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        namespace=$(< /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        api_host_port="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
        token=$(< /var/run/secrets/kubernetes.io/serviceaccount/token)
        rlLog "Detected in-cluster pod (namespace=${namespace}, api=${api_host_port})." >&2

    elif [ -n "${KUBECONFIG}" ] && [[ "${KUBECONFIG}" == /credentials/* ]]; then
        namespace=$(${oc_bin} config view --kubeconfig="${KUBECONFIG}" --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)
        api_host_port=$(${oc_bin} config view --kubeconfig="${KUBECONFIG}" --minify -o jsonpath='{.clusters[0].cluster.server}')
        rlLog "Detected ephemeral pipeline with kubeconfig (namespace=${namespace}, api=${api_host_port})." >&2
        oc_cmd+=("--kubeconfig=${KUBECONFIG}")
        token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
        [ -z "$token" ] && DEFAULT_TOKEN="" 

    else
        namespace="${OPERATOR_NAMESPACE:-$(${oc_bin} config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)}"
        api_host_port=$(${oc_bin} config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        rlLog "Detected external cluster (namespace=${namespace}, api=${api_host_port})." >&2
        oc_cmd+=("--kubeconfig=${KUBECONFIG:-${HOME}/.kube/config}")
        token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
    fi

    if [ -z "$token" ]; then
        rlLogWarning "Primary auth failed; trying SA secret." >&2
        local secret_name
        secret_name=$("${oc_cmd[@]}" get sa "$sa_name" -n "$namespace" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
        [ -n "$secret_name" ] && token=$("${oc_cmd[@]}" get secret -n "$namespace" "$secret_name" -o json | jq -Mr '.data.token' | base64 -d 2>/dev/null || true)
    fi

    echo "API_HOST_PORT=${api_host_port}"
    echo "DEFAULT_TOKEN=${token}"
    echo "NAMESPACE=${namespace}"
    return 0
}

# --- MAIN TEST ---
rlJournalStart

rlPhaseStartSetup
    OPERATOR_NAME="${OPERATOR_NAME:-tang-operator}"
    rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"'
    rlRun ". ../../TestHelpers/functions.sh"
    TO_DAST_POD_COMPLETED=300
    TO_RAPIDAST=30
rlPhaseEnd

rlPhaseStartTest "Dynamic Application Security Testing"

    rlLog "Preparing Rapidast configuration..."

    # Gather cluster auth info
    eval "$(ocpopGetAuth "${KUBECONFIG}" "${OPERATOR_NAMESPACE}")"

    rlLog "API host/port: ${API_HOST_PORT}"
    rlLog "Default token: ${DEFAULT_TOKEN:-<empty>}"
    rlLog "Operator namespace: ${OPERATOR_NAMESPACE}"

    # Replace placeholders in tang_operator.yaml
    sed -i "s@API_HOST_PORT_HERE@${API_HOST_PORT}@g" tang_operator.yaml
    sed -i "s@AUTH_TOKEN_HERE@'${DEFAULT_TOKEN}'@g" tang_operator.yaml
    sed -i "s@OPERATOR_NAMESPACE_HERE@${OPERATOR_NAMESPACE}@g" tang_operator.yaml

    # Sanity check: make sure no placeholders remain
    if grep -q "API_HOST_PORT_HERE\|AUTH_TOKEN_HERE\|OPERATOR_NAMESPACE_HERE" tang_operator.yaml; then
        rlDie "tang_operator.yaml still contains unreplaced placeholders"
    fi

    # Validate YAML before helm
    python3 -c "import yaml,sys;yaml.safe_load(open('tang_operator.yaml'))" \
        || rlDie "tang_operator.yaml is not valid YAML"

    rlLog "Deploying Rapidast via Helm..."
    helm install rapidast rapidast/helm \
        --namespace "${RAPIDAST_NS}" \
        --set-file rapidastConfig=./tang_operator.yaml

    # Wait for report
    sleep_seconds=10
    max_retries=60
    retry_count=0
    report_dir=""
    while [ $retry_count -lt $max_retries ]; do
        report_dir=$(${oc_client} get cm -n "${RAPIDAST_NS}" \
            -o custom-columns=":metadata.name" \
            | grep "dast-rapidast-tangservers" | head -1)
        if [ -z "$report_dir" ]; then
            rlLog "Report directory not found yet. Sleeping ${sleep_seconds}s..."
            sleep $sleep_seconds
            ((retry_count++))
        else
            break
        fi
    done

    rlAssertNotEquals "Report directory must exist" "$report_dir"

    report_file="${report_dir}/zap/zap-report.json"
    [ -f "$report_file" ] || rlDie "DAST report file '${report_file}' does not exist"
    rlLog "DAST report file is ready: ${report_file}"

    alerts=$(jq '.site[0].alerts | length' < "$report_file")
    for ((alert=0; alert<alerts; alert++)); do
        risk_desc=$(jq -r ".site[0].alerts[${alert}].riskdesc" < "$report_file")
        rlLog "Alert[${alert}] -> Priority: ${risk_desc}"
        rlAssertNotEquals "Check alarm is not High Risk" "${risk_desc}" "High"
    done

rlPhaseEnd