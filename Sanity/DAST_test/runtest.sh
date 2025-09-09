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
    local namespace
    local api_host_port
    local token

    declare -a oc_cmd=("${OC_CLIENT}")

    if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
        # In-cluster pod (Konflux)
        namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        api_host_port="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
        token=$(< /var/run/secrets/kubernetes.io/serviceaccount/token)
        rlLog "Detected in-cluster execution (namespace=${namespace})."
    else
        # External (CRC, developer machine, etc.)
        namespace="${OPERATOR_NAMESPACE:-$(${OC_CLIENT} config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)}"
        api_host_port=$(${OC_CLIENT} config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        rlLog "Detected external cluster (namespace=${namespace}, api=${api_host_port})."

        if [ -z "${KUBECONFIG}" ]; then
            KUBECONFIG="${HOME}/.kube/config"
        fi
        oc_cmd+=("--kubeconfig=${KUBECONFIG}")

        if ! "${oc_cmd[@]}" whoami &>/dev/null; then
            rlDie "Cannot authenticate to the cluster using kubeconfig!"
        fi

        token=$("${oc_cmd[@]}" create token "$sa_name" -n "$namespace" 2>/dev/null || true)
        if [ -z "$token" ]; then
            rlLogWarning "Falling back to SA secret (legacy)"
            local secret_name
            secret_name=$("${oc_cmd[@]}" get sa "$sa_name" -n "$namespace" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
            if [ -n "$secret_name" ]; then
                token=$("${oc_cmd[@]}" get secret -n "$namespace" "$secret_name" -o json | jq -Mr '.data.token' | base64 -d 2>/dev/null || true)
            fi
        fi
    fi

    echo "API_HOST_PORT=${api_host_port}"
    echo "DEFAULT_TOKEN=${token}"
    echo "NAMESPACE=${namespace}"

    [ -z "$token" ] && rlDie "Failed to obtain a service account token!"
}
# ---------------------------------------------------------------------

rlJournalStart
    rlPhaseStartSetup
        if [ -z "${OPERATOR_NAME}" ];
        then
            OPERATOR_NAME=tang-operator
        fi
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        TO_DAST_POD_COMPLETED=300 #seconds (DAST lasts around 120 seconds)
        TO_RAPIDAST=30 #seconds to wait for Rapidast container to appear
        if ! command -v helm &> /dev/null; then
            ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
            OS=$(uname | awk '{print tolower($0)}')
            #download latest helm
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
        # 1 - Log helm version
        ocpopLogVerbose "$(helm version)"

        # 2 - clone rapidast code (development branch)
        tmpdir=$(mktemp -d)
        pushd "${tmpdir}" && git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || exit

        # 3 - download configuration file template
        if [ -z "${KONFLUX}" ];
        then
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
        else
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
        fi

        rlLog "Execution mode is: ${EXECUTION_MODE}"

        # --- USE AUTH HELPER ---
        eval "$(ocpopGetAuth dast-test-sa)"
        rlAssertNotEquals "Checking token not empty" "${DEFAULT_TOKEN}" ""
        # -----------------------

        # Replace placeholders in YAML
        sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
        sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
        sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml

        # 5 - adapt helm
        pushd rapidast || exit
        sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
        sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
        sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

        # 6 - run rapidast on adapted configuration file (via helm)
        helm uninstall rapidast
        rlRun -c "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" 0 "Installing rapidast helm chart"
        pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1)

        if ! ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} default "${pod_name}" ; then
            rlLog "Pod ${pod_name} failed to reach 'Completed' state. Fetching logs for diagnosis."
            rlRun "oc logs \"${pod_name}\""
            rlDie "DAST pod failed. Please review the logs above for the root cause."
        fi
        
        # 7 - extract results
        rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

        # 8 - parse results
        report_base_dir="${tmpdir}/rapidast/tangservers/"
        report_dir=""
        if [ -d "${report_base_dir}" ]; then
            report_dir=$(find "${report_base_dir}" -maxdepth 1 -type d -name "DAST*tangservers" | head -1)
        fi
        
        ocpopLogVerbose "REPORT DIR:${report_dir}"
        if [ -z "${report_dir}" ]; then
            rlLog "Failed to find the DAST report directory. Expected as the pod failed."
            pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1)
            rlRun "oc logs \"${pod_name}\""
            rlDie "DAST report was not generated. Check pod logs for the root cause."
        fi

        rlAssertNotEquals "Checking report_dir not empty" "${report_dir}" ""

        report_file="${report_dir}/zap/zap-report.json"
        ocpopLogVerbose "REPORT FILE:${report_file}"

        if [ ! -f "${report_file}" ]; then
            rlDie "DAST report file '${report_file}' does not exist."
        fi

        if [ -n "${report_dir}" ] && [ -f "${report_file}" ]; then
            alerts=$(jq '.site[0].alerts | length' < "${report_file}" )
            ocpopLogVerbose "Alerts:${alerts}"
            for ((alert=0; alert<alerts; alert++)); do
                risk_desc=$(jq ".site[0].alerts[${alert}].riskdesc" < "${report_file}" | awk '{print $1}' | tr -d '"' | tr -d " ")
                rlLog "Alert[${alert}] -> Priority:[${risk_desc}]"
                rlAssertNotEquals "Checking alarm is not High Risk" "${risk_desc}" "High"
            done
            if [ "${alerts}" != "0" ]; then
                rlLogWarning "A total of [${alerts}] alerts were detected! Please, review ZAP report: ${report_file}"
            else
                rlLog "No alerts detected"
            fi
        else
            rlLogWarning "Report file:${report_file} does not exist"
        fi

        # 9 - clean helm installation
        helm uninstall rapidast

        popd || exit
        popd || exit

    rlPhaseEnd
    ############# /DAST TESTS #############

rlJournalPrintText
rlJournalEnd