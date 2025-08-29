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

        # 4 - adapt configuration file template (token, machine)
        # We replace this section with the more robust login procedure
        declare -a OC_CMD=("oc")
        if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
            # Inside a pod
            NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
            API_HOST_PORT="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
            SA_NAME="${SA_NAME:-dast-test-sa}"
        else
            # Running on VM / external cluster
            NAMESPACE="${OPERATOR_NAMESPACE:-default}"
            SA_NAME="${SA_NAME:-dast-test-sa}"
            if [ -z "${KUBECONFIG}" ]; then
                KUBECONFIG="${HOME}/.kube/config"
            fi
            OC_CMD+=("--kubeconfig=${KUBECONFIG}")
            API_HOST_PORT=$("${OC_CMD[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
            rlLog "Detected API server from kubeconfig: ${API_HOST_PORT}"
        fi

        # --- UPDATED SERVICE ACCOUNT SETUP ---
        rlLog "Verifying and creating service account and permissions for DAST..."
        if ! "${OC_CMD[@]}" get sa "$SA_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
            rlLog "Service account '$SA_NAME' not found. Creating it now."
            rlRun 'eval "${OC_CMD[@]} create sa \"$SA_NAME\" -n \"$NAMESPACE\""' || rlDie "Failed to create service account '$SA_NAME'."
        else
            rlLog "Service account '$SA_NAME' already exists. Proceeding."
        fi
        if ! "${OC_CMD[@]}" get clusterrolebinding "dast-test-sa-binding" >/dev/null 2>&1; then
            rlLog "Creating ClusterRoleBinding to grant '$SA_NAME' cluster-admin permissions."
            rlRun 'eval "${OC_CMD[@]} create clusterrolebinding dast-test-sa-binding --clusterrole=cluster-admin --serviceaccount=${NAMESPACE}:${SA_NAME}"' || rlDie "Failed to create ClusterRoleBinding."
        else
            rlLog "ClusterRoleBinding for '$SA_NAME' already exists. Proceeding."
        fi
        # --- END OF UPDATED SERVICE ACCOUNT SETUP ---

        # --- Obtain API server and token (robust fallback chain) ---
        rlLog "Obtaining a token for service account: ${SA_NAME} in namespace: ${NAMESPACE}"

        # Use the modern, recommended way to get the token (oc create token)
        DEFAULT_TOKEN=$("${OC_CMD[@]}" create token "$SA_NAME" -n "$NAMESPACE" 2>/dev/null)
        if [ -z "$DEFAULT_TOKEN" ]; then
            # Fallback for older clusters or specific setups
            secret_name=$("${OC_CMD[@]}" get sa "$SA_NAME" -n "${NAMESPACE}" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
            if [ -n "${secret_name}" ]; then
                DEFAULT_TOKEN=$("${OC_CMD[@]}" get secret -n "${NAMESPACE}" "${secret_name}" -o json | jq -Mr '.data.token' | base64 -d 2>/dev/null || true)
            fi
        fi

        echo "API_HOST_PORT=${API_HOST_PORT}"
        echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"
        
        # Check application URL
        rlLog "Attempting to find the service for operator: ${OPERATOR_NAME} in namespace: ${NAMESPACE}"
        rlRun "oc get services -n ${NAMESPACE} --show-labels"
        
        # Dynamically find the service name with a new, more robust approach
        TANG_SERVICE_NAME=""
        
        # First, try to find the service using the full, specific name
        SERVICE_NAME_FROM_LOG="nbde-tang-server-controller-manager-metrics-service"
        if "${OC_CMD[@]}" get service "${SERVICE_NAME_FROM_LOG}" -n "${NAMESPACE}" >/dev/null 2>&1; then
            TANG_SERVICE_NAME="${SERVICE_NAME_FROM_LOG}"
        else
            # Fallback to the generic operator name from the script's setup
            TANG_SERVICE_NAME=$("${OC_CMD[@]}" get services --selector="operators.coreos.com/${OPERATOR_NAME}.default=" -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        fi

        if [ -z "${TANG_SERVICE_NAME}" ]; then
            rlDie "Failed to find the service for operator ${OPERATOR_NAME}. Check its labels or name."
        fi
        rlLog "Found operator service name: ${TANG_SERVICE_NAME}"

        TANG_ROUTE_URL=$("${OC_CMD[@]}" get route -n "${NAMESPACE}" "${TANG_SERVICE_NAME}" -o jsonpath='{.spec.host}' 2>/dev/null)
        if [ -z "${TANG_ROUTE_URL}" ]; then
            rlLogWarning "Route for service ${TANG_SERVICE_NAME} not found. Trying Cluster IP."
            TANG_SERVICE_IP=$("${OC_CMD[@]}" get service -n "${NAMESPACE}" "${TANG_SERVICE_NAME}" -o jsonpath='{.spec.clusterIP}')
            TANG_SERVICE_PORT=$("${OC_CMD[@]}" get service -n "${NAMESPACE}" "${TANG_SERVICE_NAME}" -o jsonpath='{.spec.ports[0].port}')
            if [ -z "${TANG_SERVICE_IP}" ] || [ -z "${TANG_SERVICE_PORT}" ]; then
                rlDie "Failed to get Cluster IP or port for service ${TANG_SERVICE_NAME}."
            fi
            APPLICATION_URL="https://${TANG_SERVICE_IP}:${TANG_SERVICE_PORT}"
        else
            APPLICATION_URL="https://${TANG_ROUTE_URL}"
        fi
        rlLog "Application URL for DAST: ${APPLICATION_URL}"
        rlAssertNotEquals "Checking application URL is not empty" "${APPLICATION_URL}" "" || rlDie "Application URL is empty"

        # Replace placeholders in YAML
        sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
        sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
        sed -i s@OPERATOR_NAMESPACE_HERE@"${NAMESPACE}"@g tang_operator.yaml

        rlAssertNotEquals "Checking token not empty" "${DEFAULT_TOKEN}" ""

        # 5 - adapt helm
        pushd rapidast || exit
        # FIX: Create a single string for the oc command and replace the placeholder
        OC_COMMAND_STRING="${OC_CMD[@]}"
        OC_COMMAND_STRING_ESCAPED=$(echo "$OC_COMMAND_STRING" | sed 's/\//\\\//g')
        sed -i "s@kubectl --kubeconfig=./kubeconfig @${OC_COMMAND_STRING_ESCAPED} @g" helm/results.sh

        sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
        sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

        # 6 - run rapidast on adapted configuration file (via helm)
        helm uninstall rapidast
        rlRun -c "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" 0 "Installing rapidast helm chart"
        
        # Re-introducing the logic from the older, working script for pod discovery and state check
        # This function seems to be better at handling the race condition of pod creation.
        pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "${NAMESPACE}" "${TO_RAPIDAST}" 1) || rlDie "Failed to find rapidast pod name"
        
        # We check for a Completed state because DAST runs a single-shot job
        rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} ${NAMESPACE} ${pod_name}" 0 "Checking POD ${pod_name} in Completed state [Timeout=${TO_DAST_POD_COMPLETED} secs.]"
        
        # Add debugging for pod state failure
        if [ $? -ne 0 ]; then
            rlLog "DAST pod failed. Retrieving pod status and logs..."
            rlRun "oc describe pod ${pod_name}"
            rlRun "oc logs ${pod_name}"
            rlDie "Pod ${pod_name} failed to reach 'Completed'"
        fi

        # 7 - extract results
        rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

        # 8 - parse results (do not have to ensure no previous results exist, as this is a temporary directory)
        # Check no alarm exist ...
        report_dir=$(ls -1d "${tmpdir}"/rapidast/tangservers/DAST*tangservers/ | head -1 | sed -e 's@/$@@g')
        ocpopLogVerbose "REPORT DIR:${report_dir}"

        rlAssertNotEquals "Checking report_dir not empty" "${report_dir}" ""

        report_file="${report_dir}/zap/zap-report.json"
        ocpopLogVerbose "REPORT FILE:${report_file}"

        if [ -n "${report_dir}" ] && [ -f "${report_file}" ];
        then
            alerts=$(jq '.site[0].alerts | length' < "${report_dir}/zap/zap-report.json" )
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
    rlPhaseStartCleanup
        rlLog "Cleaning up DAST service account and its role binding."
        # Remove the role binding and service account
        rlRun 'eval "${OC_CMD[@]} delete clusterrolebinding dast-test-sa-binding --ignore-not-found"' || true
        rlRun 'eval "${OC_CMD[@]} delete serviceaccount dast-test-sa -n ${NAMESPACE} --ignore-not-found"' || true
        # Remove the temporary directory
        rm -rf "${tmpdir}" || true
    rlPhaseEnd

rlJournalPrintText
rlJournalEnd