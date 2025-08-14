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

rlJournalStart
    rlPhaseStartSetup
        if [ -z "${OPERATOR_NAME}" ];
        then
            OPERATOR_NAME=tang-operator
        fi
        
        # Import necessary libraries
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

        # Set timeouts
        TO_DAST_POD_COMPLETED=300 #seconds (DAST lasts around 120 seconds)
        TO_RAPIDAST=30 #seconds to wait for Rapidast container to appear

        # Install helm if not present
        if ! command -v helm &> /dev/null; then
            ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
            OS=$(uname | awk '{print tolower($0)}')
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

        # 2 - Clone rapidast code (development branch)
        tmpdir=$(mktemp -d)
        pushd "${tmpdir}" || rlDie "Failed to push to temporary directory"
        git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || rlDie "Failed to clone rapidast repository"

        # 3 - Download configuration file template
        if [ -z "${KONFLUX}" ]; then
            CONFIG_URL="https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
        else
            CONFIG_URL="https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
        fi
        rlRun "curl -o tang_operator.yaml $CONFIG_URL" || rlDie "Failed to download configuration file"

        # 4 - Adapt configuration file template (token, machine)
        if [ "${EXECUTION_MODE}" == "MINIKUBE" ]; then
            API_HOST_PORT=$(minikube ip)
            DEFAULT_TOKEN="TEST_TOKEN_UNREQUIRED_IN_MINIKUBE"
        else
            # Unified and more robust token retrieval logic
            API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ' || true)
            if [ -z "${API_HOST_PORT}" ]; then
                rlDie "Failed to get API server address. Is OC_CLIENT configured correctly?"
            fi

            # Prioritize an explicit OCP_TOKEN, then try `oc whoami -t`, then try service account
            DEFAULT_TOKEN="${OCP_TOKEN}"
            if [ -z "${DEFAULT_TOKEN}" ]; then
                DEFAULT_TOKEN=$(oc whoami -t 2>/dev/null || true)
            fi
            if [ -z "${DEFAULT_TOKEN}" ]; then
                DEFAULT_TOKEN=$(ocpopPrintTokenFromConfiguration || true)
            fi
            if [ -z "${DEFAULT_TOKEN}" ]; then
                # Fallback to service account secret retrieval
                secret_name=$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}" | grep -m 1 "^${OPERATOR_NAME}" | grep service-account | awk '{print $1}' || true)
                if [ -n "${secret_name}" ]; then
                    DEFAULT_TOKEN=$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}" "${secret_name}" -o json | jq -Mr '.data.token' | base64 -d)
                fi
            fi
        fi

        echo "API_HOST_PORT=${API_HOST_PORT}"
        echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"

        rlAssertNotEquals "Checking token is not empty" "${DEFAULT_TOKEN}" "" || rlDie "Authentication token is empty. Cannot proceed."

        # Replace placeholders in YAML
        sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
        sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
        sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml

        # 5 - Adapt helm
        pushd rapidast || rlDie "Failed to push to rapidast directory"
        sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
        sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
        sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

        # 6 - Run rapidast on adapted configuration file (via helm)
        rlRun "helm uninstall rapidast --ignore-not-found" 0 "Removing any previous rapidast helm chart"
        rlRun "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml" 0 "Installing rapidast helm chart"
        
        pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1) || rlDie "Failed to find rapidast pod name"
        
        if ! ocpopCheckPodState Completed "${TO_DAST_POD_COMPLETED}" default "${pod_name}"; then
            # If the pod fails, get and log its status and logs for debugging
            rlLog "DAST pod failed to complete. Retrieving pod status and logs for debugging."
            rlRun "oc describe pod ${pod_name}"
            rlRun "oc logs ${pod_name}"
            rlDie "Pod ${pod_name} failed to reach 'Completed' state."
        fi

        # 7 - Extract results
        rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

        # 8 - Parse results (do not have to ensure no previous results exist, as this is a temporary directory)
        report_dir=$(ls -1d "${tmpdir}"/rapidast/tangservers/DAST*tangservers/ 2>/dev/null | head -1 | sed -e 's@/$@@g')
        ocpopLogVerbose "REPORT DIR:${report_dir}"
        rlAssertNotEquals "Checking report_dir not empty" "${report_dir}" "" || rlDie "Report directory not found. Report extraction failed."

        report_file="${report_dir}/zap/zap-report.json"
        ocpopLogVerbose "REPORT FILE:${report_file}"

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
            rlDie "Report file: ${report_file} does not exist."
        fi

        # 9 - Clean helm installation
        helm uninstall rapidast || true

        # 10 - Return
        popd || exit
        popd || exit

    rlPhaseEnd
    ############# /DAST TESTS #############

rlJournalPrintText
rlJournalEnd