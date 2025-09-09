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
        # WARNING: if tang-operator is changed to OpenShift organization, change this
        if [ -z "${KONFLUX}" ];
        then
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
        else
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
        fi

        rlLog "Execution mode is: ${EXECUTION_MODE}"

        # --- UPDATED AUTHENTICATION LOGIC ---
        # This section is added to properly handle authentication in a robust, modern way.
        
        declare -a OC_CMD=("${OC_CLIENT}")
        API_HOST_PORT=""
        NAMESPACE=""
        DEFAULT_TOKEN=""
        SA_NAME="dast-test-sa"

        # Check if running inside a pod, which is typical for a pipeline job
        if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
            NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
            API_HOST_PORT="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
            # Use the existing token from the pod's service account
            DEFAULT_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
            rlLog "Detected cluster via pod identity. Using existing token."
        else
            # Running on a VM / external cluster
            NAMESPACE="${OPERATOR_NAMESPACE:-default}"
            if [ -z "${KUBECONFIG}" ]; then
                KUBECONFIG="${HOME}/.kube/config"
            fi
            OC_CMD+=("--kubeconfig=${KUBECONFIG}")
            
            # Use oc to get API server details
            API_HOST_PORT=$("${OC_CMD[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
            rlLog "Detected API server from kubeconfig: ${API_HOST_PORT}"

            # Validate authentication and get token for the user from kubeconfig
            if ! "${OC_CMD[@]}" whoami &>/dev/null; then
                rlDie "Cannot authenticate to the cluster using the provided kubeconfig."
            fi
            # Fallback to creating a new token if a kubeconfig is used
            rlLog "Obtaining a token for service account: ${SA_NAME} in namespace: ${NAMESPACE}"
            DEFAULT_TOKEN=$("${OC_CMD[@]}" create token "$SA_NAME" -n "$NAMESPACE" 2>/dev/null)
            if [ -z "$DEFAULT_TOKEN" ]; then
                # Fallback for older clusters or specific setups
                secret_name=$("${OC_CMD[@]}" get sa "$SA_NAME" -n "${NAMESPACE}" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
                if [ -n "${secret_name}" ]; then
                    DEFAULT_TOKEN=$("${OC_CMD[@]}" get secret -n "${NAMESPACE}" "${secret_name}" -o json | jq -Mr '.data.token' | base64 -d 2>/dev/null || true)
                fi
            fi
        fi
        
        # --- END OF UPDATED AUTHENTICATION LOGIC ---

        echo "API_HOST_PORT=${API_HOST_PORT}"
        echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"

        # Assert that the token is not empty. If it is, the test cannot proceed.
        rlAssertNotEquals "Checking token not empty" "${DEFAULT_TOKEN}" ""

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

        # Check the pod status and get logs if it fails
        if ! ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} default "${pod_name}" ; then
            rlLog "Pod ${pod_name} failed to reach 'Completed' state. Fetching logs for diagnosis."
            # Use 'oc logs' to get details on why the pod failed
            rlRun "oc logs \"${pod_name}\""
            rlDie "DAST pod failed. Please review the logs above for the root cause."
        fi
        
        # 7 - extract results
        rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

        # 8 - parse results (do not have to ensure no previous results exist, as this is a temporary directory)
        # Check no alarm exist ...
        report_base_dir="${tmpdir}/rapidast/tangservers/"
        report_dir="" # Initialize the variable as empty

        if [ -d "${report_base_dir}" ]; then
            # Use `find` to get the full path, which is more reliable than `ls`
            report_dir=$(find "${report_base_dir}" -maxdepth 1 -type d -name "DAST*tangservers" | head -1)
        fi
        
        ocpopLogVerbose "REPORT DIR:${report_dir}"

        # Now, check if the report_dir was actually found, provide useful logs if not
        if [ -z "${report_dir}" ]; then
            # Since the pod failed earlier, this is expected. Log the error and exit gracefully.
            rlLog "Failed to find the DAST report directory. This is expected as the DAST pod failed."
            # Fetch the pod logs again for the final report to ensure the failure is clear
            pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1)
            rlRun "oc logs \"${pod_name}\""
            rlDie "DAST report was not generated. Check pod logs for the root cause."
        fi

        rlAssertNotEquals "Checking report_dir not empty" "${report_dir}" ""

        report_file="${report_dir}/zap/zap-report.json"
        ocpopLogVerbose "REPORT FILE:${report_file}"

        # Make sure the file itself exists before trying to read it
        if [ ! -f "${report_file}" ]; then
            rlDie "DAST report file '${report_file}' does not exist."
        fi

        if [ -n "${report_dir}" ] && [ -f "${report_file}" ];
        then
            alerts=$(jq '.site[0].alerts | length' < "${report_file}" )
            ocpopLogVerbose "Alerts:${alerts}"
            for ((alert=0; alert<alerts; alert++));
            do
                risk_desc=$(jq ".site[0].alerts[${alert}].riskdesc" < "${report_dir}/zap/zap-report.json" | awk '{print $1}' | tr -d '"' | tr -d " ")
                rlLog "Alert[${alert}] -> Priority:[${risk_desc}]"
                rlAssertNotEquals "Checking alarm is not High Risk" "${risk_desc}" "High"
            done
            if [ "${alerts}" != "0" ];
            then
                rlLogWarning "A total of [${alerts}] alerts were detected! Please, review ZAP report: ${report_dir}/zap/zap-report.json"
            else
                rlLog "No alerts detected"
            fi
        else
            rlLogWarning "Report file:${report_dir}/zap/zap-report.json does not exist"
        fi

        # 9 - clean helm installation
        helm uninstall rapidast

        # 10 - return
        popd || exit
        popd || exit

    rlPhaseEnd
    ############# /DAST TESTS #############

rlJournalPrintText
rlJournalEnd