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

# --- AUTH HELPER -----------------------------------------------------
ocpopGetAuth() {
    # Safe to eval: prints KEY=VALUE assignments to stdout, logs go to stderr

    local sa_name=${1:-dast-test-sa}
    local namespace api_host_port token
    local oc_bin="${OC_CLIENT:-oc}"
    local -a oc_cmd=("${oc_bin}")

    # --- Case 1: in-cluster SA token ---
    if [ -s /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        namespace=$(< /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        api_host_port="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
        token=$(< /var/run/secrets/kubernetes.io/serviceaccount/token)
        rlLog "Detected in-cluster pod (namespace=${namespace}, api=${api_host_port})." >&2

    # --- Case 2: ephemeral pipeline (KUBECONFIG under /credentials) ---
    elif [ -n "${KUBECONFIG}" ] && [[ "${KUBECONFIG}" == /credentials/* ]]; then
        namespace=$(${oc_bin} config view --kubeconfig="${KUBECONFIG}" --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)
        api_host_port=$(${oc_bin} config view --kubeconfig="${KUBECONFIG}" --minify -o jsonpath='{.clusters[0].cluster.server}')
        rlLog "Detected ephemeral pipeline with kubeconfig (namespace=${namespace}, api=${api_host_port})." >&2
        oc_cmd+=("--kubeconfig=${KUBECONFIG}")
        token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)

        # Fallback if token empty (certificate-only kubeconfig)
        if [ -z "$token" ]; then
            rlLogWarning "No token in KUBECONFIG; will use kubeconfig directly for auth" >&2
            DEFAULT_TOKEN=""  # explicitly empty
            echo "API_HOST_PORT=${api_host_port}"
            echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"
            echo "NAMESPACE=${namespace}"
            return 0
        fi

    # --- Case 3: external cluster (CRC / dev machine) ---
    else
        namespace="${OPERATOR_NAMESPACE:-$(${oc_bin} config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)}"
        api_host_port=$(${oc_bin} config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        rlLog "Detected external cluster (namespace=${namespace}, api=${api_host_port})." >&2

        if [ -z "${KUBECONFIG}" ]; then
            KUBECONFIG="${HOME}/.kube/config"
        fi
        oc_cmd+=("--kubeconfig=${KUBECONFIG}")

        if ! "${oc_cmd[@]}" whoami &>/dev/null; then
            rlLogWarning "Cannot authenticate to the cluster using kubeconfig!" >&2
            return 1
        fi
        token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
    fi

    # --- Fallback if token is still empty ---
    if [ -z "$token" ]; then
        rlLogWarning "Primary auth method failed, falling back to SA secret." >&2
        local secret_name
        secret_name=$("${oc_cmd[@]}" get sa "$sa_name" -n "$namespace" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
        if [ -n "$secret_name" ]; then
            token=$("${oc_cmd[@]}" get secret -n "$namespace" "$secret_name" -o json | jq -Mr '.data.token' | base64 -d 2>/dev/null || true)
        fi
    fi

    echo "API_HOST_PORT=${api_host_port}"
    echo "DEFAULT_TOKEN=${token}"
    echo "NAMESPACE=${namespace}"

    if [ -z "$token" ]; then
        return 0  # proceed without token for ephemeral kubeconfigs
    fi
    return 0
}
# ---------------------------------------------------------------------

rlJournalStart

rlPhaseStartSetup
    OPERATOR_NAME="${OPERATOR_NAME:-tang-operator}"
    rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"'
    rlRun ". ../../TestHelpers/functions.sh"

    TO_DAST_POD_COMPLETED=300
    TO_RAPIDAST=30
rlPhaseEnd

rlPhaseStartTest "Dynamic Application Security Testing"
    oc_client="${OC_CLIENT:-oc}"
    RAPIDAST_NS="rapidast-test"

    rlLog "Ensuring namespace ${RAPIDAST_NS} exists"
    ${oc_client} get ns "${RAPIDAST_NS}" >/dev/null 2>&1 || ${oc_client} create ns "${RAPIDAST_NS}"
    ${oc_client} adm policy add-scc-to-user privileged -z default -n "${RAPIDAST_NS}" || true
    ${oc_client} adm policy add-scc-to-user anyuid -z default -n "${RAPIDAST_NS}" || true

    tmpdir=$(mktemp -d)
    pushd "$tmpdir"
    git clone https://github.com/RedHatProductSecurity/rapidast.git -b development

    rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"

    # --- eval auth ---
    if ! eval "$(ocpopGetAuth)"; then
        rlLogWarning "Authentication failed; skipping DAST test"
        rlSkip "Cannot obtain authentication to cluster"
    fi

    cluster_api_host="${API_HOST_PORT:-$(${oc_client} whoami --show-server 2>/dev/null || echo)}"
    is_crc=0
    if echo "${cluster_api_host}" | grep -qi 'crc.testing'; then
        is_crc=1
    fi

    tang_operator_svc_url=$(ocpopGetServiceIp "nbde-tang-server-service" "${OPERATOR_NAMESPACE}" 10)
    rlAssertNotEquals "Tang operator service URL must not be empty" "${tang_operator_svc_url}" ""

    # --- Replace placeholders in tang_operator.yaml ---
    sed -i "s@API_HOST_PORT_HERE@${tang_operator_svc_url}@g" tang_operator.yaml
    if [ -n "${DEFAULT_TOKEN}" ]; then
        sed -i "s@AUTH_TOKEN_HERE@${DEFAULT_TOKEN}@g" tang_operator.yaml
    else
        rlLog "Skipping AUTH_TOKEN_HERE replacement because token is empty"
    fi
    sed -i "s@OPERATOR_NAMESPACE_HERE@${OPERATOR_NAMESPACE}@g" tang_operator.yaml

    pushd rapidast
    sed -i "s@kubectl --kubeconfig=./kubeconfig @${oc_client} @g" helm/results.sh
    helm uninstall rapidast -n "${RAPIDAST_NS}" || true

    rlRun -c "helm install rapidast ./helm/chart/ --namespace ${RAPIDAST_NS} --set-file rapidastConfig=${tmpdir}/tang_operator.yaml" 0 "Installing rapidast"

    pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "${RAPIDAST_NS}" "${TO_RAPIDAST}" 1)
    rlAssertNotEquals "Pod name must not be empty" "${pod_name}" ""

    if ! ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} "${RAPIDAST_NS}" "${pod_name}" ; then
        rlLog "DAST pod failed to reach 'Completed' state. Fetching diagnostic info..."
        rlRun "oc describe pod ${pod_name} -n ${RAPIDAST_NS} || true" 0 "Describe pod"
        pod_logs_output=$(oc logs ${pod_name} -n ${RAPIDAST_NS} 2>/dev/null || true)
        rlLog "$pod_logs_output"

        if [ "${is_crc}" -eq 1 ] && echo "${pod_logs_output}" | grep -qi "Permission denied"; then
            rlLogWarning "Detected Rapidast permission denied writing to results on CRC."
            rlPass "Skipping DAST failure on CRC due to permission denied"
        else
            rlRun "oc logs ${pod_name} -n ${RAPIDAST_NS} || true" 0 "Pod logs for failure analysis"
            rlDie "DAST pod failed. Check logs above."
        fi
    fi

    rlLog "Running results.sh to generate the DAST report..."
    if ! rlRun -c "bash ./helm/results.sh" 0 "Generating DAST report"; then
        results_logs=$(find . -maxdepth 2 -type f -name '*.log' -o -name '*.txt' -print 2>/dev/null || true)
        rlLog "results.sh failed. Found files: ${results_logs}"
        rlDie "Generating DAST report failed."
    fi

    report_base_dir="${tmpdir}/rapidast/tangservers/"
    retry_count=0
    max_retries=5
    sleep_seconds=5
    report_dir=""

    while [ -z "$report_dir" ] && [ $retry_count -lt $max_retries ]; do
        report_dir=$(find "${report_base_dir}" -maxdepth 1 -type d -name "DAST*tangservers" | head -1)
        if [ -z "$report_dir" ]; then
            rlLog "Report directory not found yet. Sleeping ${sleep_seconds}s..."
            sleep $sleep_seconds
            ((retry_count++))
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

rlJournalPrintText
rlJournalEnd