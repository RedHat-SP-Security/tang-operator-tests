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

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

# --- AUTH HELPER -----------------------------------------------------
ocpopGetAuth() {
    local sa_name=${1:-dast-test-sa}
    local namespace api_host_port token
    declare -a oc_cmd=("${OC_CLIENT:-oc}")

    # Helper to dump diagnostics for debugging auth issues
    _auth_diag() {
        rlLog "=== AUTH DIAGNOSTICS ==="
        rlLog "Environment:"
        rlRun "env | egrep 'KUBERNETES_SERVICE_HOST|KUBECONFIG|KONFLUX|EXECUTION_MODE' || true"
        rlLog "ServiceAccount secret files (if present):"
        rlRun "ls -l /var/run/secrets/kubernetes.io/ || true"
        rlRun "ls -l /var/run/secrets/kubernetes.io/serviceaccount || true"
        rlRun "cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true"
        rlRun "test -s /var/run/secrets/kubernetes.io/serviceaccount/token && echo 'token file exists and non-empty' || echo 'no token file or empty' || true"
        rlLog "oc diagnostics (if oc available):"
        rlRun "${oc_cmd[@]} version --client || true"
        rlRun "${oc_cmd[@]} whoami 2>/dev/null || true"
        rlRun "${oc_cmd[@]} whoami -t 2>/dev/null || true"
        rlRun "${oc_cmd[@]} config view --minify -o yaml 2>/dev/null || true"
        rlLog "========================="
    }

    # --- Strong in-cluster detection ---
    # If any of these indicate "in-cluster", prefer mounted SA token:
    # - KUBERNETES_SERVICE_HOST is set (standard in pods)
    # - serviceaccount token file exists and non-empty
    # - serviceaccount namespace file exists
    if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] || [ -s "/var/run/secrets/kubernetes.io/serviceaccount/token" ] || [ -f "/var/run/secrets/kubernetes.io/serviceaccount/namespace" ]; then
        # Try to read namespace and token (be defensive)
        if [ -f "/var/run/secrets/kubernetes.io/serviceaccount/namespace" ]; then
            namespace=$(</var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo "")
        fi
        api_host_port="https://${KUBERNETES_SERVICE_HOST:-localhost}:${KUBERNETES_SERVICE_PORT:-6443}"
        if [ -s "/var/run/secrets/kubernetes.io/serviceaccount/token" ]; then
            token=$(</var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || echo "")
            rlLog "Detected in-cluster execution (namespace=${namespace:-unknown}, api=${api_host_port}). Using mounted SA token."
        else
            rlLogWarning "In-cluster indicator present but SA token file missing/empty."
            _auth_diag
            # Fall through to try kubeconfig-based token
        fi
    fi

    # --- If we don't have a token yet, try external methods (kubeconfig / oc) ---
    if [ -z "${token:-}" ]; then
        # Ensure we have a kubeconfig path
        if [ -z "${KUBECONFIG:-}" ]; then
            KUBECONFIG="${HOME}/.kube/config"
        fi
        oc_cmd+=("--kubeconfig=${KUBECONFIG}")

        # Check oc auth
        if ! "${oc_cmd[@]}" whoami &>/dev/null; then
            rlLogWarning "oc whoami failed with kubeconfig '${KUBECONFIG}'. Attempting diagnostics..."
            _auth_diag
            rlDie "Cannot authenticate to the cluster using kubeconfig!"
        fi

        # Primary: use current user token (reliable for CRC/dev)
        token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
        if [ -n "${token}" ]; then
            namespace="${OPERATOR_NAMESPACE:-$(${oc_cmd[@]} config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)}"
            api_host_port=$(${oc_cmd[@]} config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
            rlLog "Using kubeconfig token for external execution (namespace=${namespace}, api=${api_host_port})."
        else
            rlLogWarning "'oc whoami -t' returned empty. Trying 'oc create token' for SA: ${sa_name} in namespace ${OPERATOR_NAMESPACE:-default}"
            # Try to create SA token (works when user has permission)
            token=$("${oc_cmd[@]}" create token "${sa_name}" -n "${OPERATOR_NAMESPACE:-default}" 2>/dev/null || true)
            if [ -n "${token}" ]; then
                namespace="${OPERATOR_NAMESPACE:-default}"
                api_host_port=$(${oc_cmd[@]} config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo "")
                rlLog "Obtained token via 'oc create token' for SA ${sa_name}."
            else
                rlLogWarning "Failed to get token via 'oc create token'."
                _auth_diag
            fi
        fi
    fi

    # Export (echo) and final checks
    echo "API_HOST_PORT=${api_host_port}"
    echo "DEFAULT_TOKEN=${token}"
    echo "NAMESPACE=${namespace}"

    rlLog "Token length: ${#token}"
    [ -z "${token}" ] && rlDie "Failed to obtain an authentication token! See earlier diagnostics above."
}
# ---------------------------------------------------------------------

rlJournalStart
    rlPhaseStartSetup
        if [ -z "${OPERATOR_NAME}" ]; then
            OPERATOR_NAME=tang-operator
        fi

        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

        TO_DAST_POD_COMPLETED=300 # seconds (DAST lasts ~120s)
        TO_RAPIDAST=30 # seconds to wait for Rapidast container to appear

        if ! command -v helm &> /dev/null; then
            ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
            OS=$(uname | awk '{print tolower($0)}')
            # download latest helm
            LATEST_RELEASE_TAG=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
            RELEASE_URL="https://get.helm.sh/helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz"
            TAR_FILE="helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz"
            rlRun "curl -LO $RELEASE_URL"
            rlRun "tar -xzf $TAR_FILE"
            rlRun "mv ${OS}-${ARCH}/helm /usr/local/bin/helm"
        fi
    rlPhaseEnd

    ############# DAST TESTS ##############
    rlPhaseStartTest "Dynamic Application Security Testing"
        # local oc client fallback
        oc_client="${OC_CLIENT:-oc}"

        # Namespace for Rapidast
        RAPIDAST_NS="rapidast-test"
        rlLog "Ensuring namespace ${RAPIDAST_NS} exists with required SCC."
        ${oc_client} get ns "${RAPIDAST_NS}" >/dev/null 2>&1 || ${oc_client} create ns "${RAPIDAST_NS}"
        ${oc_client} adm policy add-scc-to-user privileged -z default -n "${RAPIDAST_NS}" || true
        ${oc_client} adm policy add-scc-to-user anyuid -z default -n "${RAPIDAST_NS}" || true

        # 1 - Log helm version
        ocpopLogVerbose "$(helm version)"

        # 2 - clone rapidast code (development branch)
        tmpdir=$(mktemp -d)
        pushd "${tmpdir}" && git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || exit

        # 3 - download configuration file template
        if [ -z "${KONFLUX}" ]; then
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
        else
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
        fi

        rlLog "Execution mode is: ${EXECUTION_MODE}"

        # --- USE AUTH HELPER ---
        eval "$(ocpopGetAuth)"
        # -----------------------

        # Assert token not empty
        rlAssertNotEquals "Checking token not empty" "${DEFAULT_TOKEN}" ""

        # Dynamically get the Tang operator service URL
        rlLog "Attempting to get the tang-operator service URL."
        tang_operator_svc_url=$(ocpopGetServiceIp "nbde-tang-server-service" "${OPERATOR_NAMESPACE}" 10)
        if [ $? -ne 0 ]; then
            rlDie "Failed to find the URL/IP for the tang-operator service."
        fi
        rlLog "Found tang-operator service URL: ${tang_operator_svc_url}"

        # Replace placeholders in YAML
        rlLog "Replacing placeholders in tang_operator.yaml with debug info."
        rlLog "  API_HOST_PORT: ${tang_operator_svc_url}"
        rlLog "  AUTH_TOKEN: (token length: ${#DEFAULT_TOKEN})"
        rlLog "  OPERATOR_NAMESPACE: ${OPERATOR_NAMESPACE}"

        sed -i "s@API_HOST_PORT_HERE@${tang_operator_svc_url}@g" tang_operator.yaml
        sed -i "s@AUTH_TOKEN_HERE@${DEFAULT_TOKEN}@g" tang_operator.yaml
        sed -i "s@OPERATOR_NAMESPACE_HERE@${OPERATOR_NAMESPACE}@g" tang_operator.yaml

        # 5 - adapt helm
        pushd rapidast || exit
        sed -i "s@kubectl --kubeconfig=./kubeconfig @${OC_CLIENT} @g" helm/results.sh
        sed -i "s@secContext: '{}'@secContext: '{\"privileged\": true}'@g" helm/chart/values.yaml
        sed -i "s@'tag: \"latest\"'@'tag: \"2.8.0\"'@g" helm/chart/values.yaml || true

        # 6 - run rapidast on adapted configuration file (via helm)
        rlLog "Cleaning previous rapidast installation (if any)."
        helm uninstall rapidast -n "${RAPIDAST_NS}" || true
        ${oc_client} delete pods -l app.kubernetes.io/instance=rapidast -n "${RAPIDAST_NS}" --ignore-not-found || true
        ${oc_client} delete job -l app.kubernetes.io/instance=rapidast -n "${RAPIDAST_NS}" --ignore-not-found || true
        ${oc_client} delete pvc -l app.kubernetes.io/instance=rapidast -n "${RAPIDAST_NS}" --ignore-not-found || true

        rlRun -c "helm install rapidast ./helm/chart/ \
            --namespace ${RAPIDAST_NS} \
            --create-namespace \
            --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" \
            0 "Installing rapidast helm chart"

        pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "${RAPIDAST_NS}" "${TO_RAPIDAST}" 1)
        rlLog "Checking DAST pod status. Pod name: ${pod_name}"
        if ! ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} "${RAPIDAST_NS}" "${pod_name}" ; then
            rlLog "Pod ${pod_name} failed to reach 'Completed' state. Fetching logs for diagnosis."
            rlRun "${oc_client} describe pod \"${pod_name}\" -n ${RAPIDAST_NS}" || true
            rlRun "${oc_client} get pods -n ${RAPIDAST_NS}" || true
            rlRun "${oc_client} logs \"${pod_name}\" -n ${RAPIDAST_NS}" || true
            rlRun "${oc_client} get events -n ${RAPIDAST_NS} --sort-by='.lastTimestamp' | tail -20" || true
            rlDie "DAST pod failed. Please review the logs above for the root cause."
        fi

        # 7 - extract results with a retry loop
        retry_count=0
        max_retries=10
        sleep_seconds=10
        found_report=false

        while [ "$found_report" = false ] && [ $retry_count -lt $max_retries ]; do
            rlLog "Extracting DAST results (Attempt $((retry_count+1))/${max_retries})..."
            rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Running results.sh (Attempt $((retry_count+1)))"

            report_base_dir="${tmpdir}/rapidast/tangservers/"
            report_dir=""
            if [ -d "${report_base_dir}" ]; then
                report_dir=$(find "${report_base_dir}" -maxdepth 1 -type d -name "DAST*tangservers" | head -1)
            fi

            if [ -n "${report_dir}" ]; then
                ocpopLogVerbose "Report directory found: ${report_dir}"
                found_report=true
                break
            fi

            rlLogWarning "Report directory not found. Gathering diagnostics before retrying..."
            rlRun "${oc_client} get pods -n ${RAPIDAST_NS} -o wide" || true
            rlRun "${oc_client} get pods -n ${RAPIDAST_NS} --selector=job-name,app.kubernetes.io/instance=rapidast -o name" || true
            for p in $(${oc_client} get pods -n ${RAPIDAST_NS} -o name | grep -E 'rapidast-job|rapiterm' || true); do
                rlLog "----- logs for pod ${p} -----"
                rlRun "${oc_client} logs ${p#pod/} -n ${RAPIDAST_NS} || true"
            done

            rlLog "Sleeping ${sleep_seconds}s before next attempt..."
            sleep ${sleep_seconds}
            ((retry_count++))
        done

        # 8 - parse results
        ocpopLogVerbose "REPORT DIR:${report_dir}"
        if [ "$found_report" = false ]; then
            rlRun "${oc_client} get pods -n ${RAPIDAST_NS} -o wide" || true
            rlRun "${oc_client} get events -n ${RAPIDAST_NS} --sort-by='.lastTimestamp' | tail -20" || true
            rlDie "Failed to find the DAST report directory after multiple retries."
        fi

        rlAssertNotEquals "Checking report_dir not empty" "${report_dir}" ""

        report_file="${report_dir}/zap/zap-report.json"
        ocpopLogVerbose "REPORT FILE:${report_file}"

        if [ ! -f "${report_file}" ]; then
            rlDie "DAST report file '${report_file}' does not exist."
        fi

        alerts=$(jq '.site[0].alerts | length' < "${report_file}" )
        ocpopLogVerbose "Alerts:${alerts}"
        for ((alert=0; alert<alerts; alert++)); do
            risk_desc=$(jq ".site[0].alerts[${alert}].riskdesc" < "${report_file}" | awk '{print $1}' | tr -d '"' | tr -d " ")
            rlLog "Alert[${alert}] -> Priority:[${risk_desc}]"
            rlAssertNotEquals "Checking alarm is not High Risk" "${risk_desc}" "High"
            if [ "${alerts}" != "0" ]; then
                rlLogWarning "A total of [${alerts}] alerts were detected! Please, review ZAP report: ${report_file}"
            else
                rlLog "No alerts detected"
            fi
        done

        # 9 - clean helm installation
        rlLog "Cleaning up rapidast installation."
        helm uninstall rapidast -n "${RAPIDAST_NS}" || true
        ${oc_client} delete pods -l app.kubernetes.io/instance=rapidast -n "${RAPIDAST_NS}" --ignore-not-found || true
        ${oc_client} delete job -l app.kubernetes.io/instance=rapidast -n "${RAPIDAST_NS}" --ignore-not-found || true

        popd || exit
        popd || exit

    rlPhaseEnd
    ############# /DAST TESTS #############

rlJournalPrintText
rlJournalEnd