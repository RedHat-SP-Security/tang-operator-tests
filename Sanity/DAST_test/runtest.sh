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
    if [ -z "${OPERATOR_NAME}" ]; then
        OPERATOR_NAME=tang-operator
    fi

    # Import necessary libraries
    rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
    rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

    # Set timeouts
    TO_DAST_POD_COMPLETED=300
    TO_RAPIDAST=30

    # Install helm if missing
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

    # -------------------------
    # Setup oc command with Kubeconfig
    # -------------------------
    # Use an array to store the oc command and its arguments. This is the most reliable method
    # to avoid "No such file or directory" errors when arguments contain spaces.
    declare -a OC_CMD=("oc")

    if [ -f /var/run/secrets/kubernetes.io/serviceaccount/namespace ]; then
        # Inside a pod
        NAMESPACE=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        POD_NAME=$("${OC_CMD[@]}" get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)
        if [ -z "$SA_NAME" ]; then
            rlDie "Cannot detect service account for pod $POD_NAME in namespace $NAMESPACE"
        fi
        # API server from env
        API_HOST_PORT="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
        SA_NAME=$("${OC_CMD[@]}" get pod "$POD_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null)
    else
        # Running on VM / external cluster
        NAMESPACE="${OPERATOR_NAMESPACE:-default}"
        SA_NAME="${SA_NAME:-dast-test-sa}"
        POD_NAME=$(hostname)
        # Extract API server from kubeconfig
        if [ -z "${KUBECONFIG}" ]; then
            KUBECONFIG="${HOME}/.kube/config"
        fi
        # Add --kubeconfig to the OC_CMD array
        OC_CMD+=("--kubeconfig=${KUBECONFIG}")
        API_HOST_PORT=$("${OC_CMD[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        rlLog "Detected API server from kubeconfig: ${API_HOST_PORT}"
    fi

    # --- NEW ADDITIONS FOR SERVICE ACCOUNT SETUP ---
    rlLog "Verifying and creating service account and permissions for DAST..."

    # Check for and create the service account
    if ! "${OC_CMD[@]}" get sa "$SA_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
        rlLog "Service account '$SA_NAME' not found. Creating it now."
        rlRun 'eval "${OC_CMD[@]} create sa "$SA_NAME" -n "$NAMESPACE""' || rlDie "Failed to create service account '$SA_NAME'."
    else
        rlLog "Service account '$SA_NAME' already exists. Proceeding."
    fi

    # Check for and create a ClusterRoleBinding for the service account
    if ! "${OC_CMD[@]}" get clusterrolebinding "dast-test-sa-binding" >/dev/null 2>&1; then
        rlLog "Creating ClusterRoleBinding to grant '$SA_NAME' cluster-admin permissions."
        rlRun 'eval "${OC_CMD[@]} create clusterrolebinding dast-test-sa-binding --clusterrole=cluster-admin --serviceaccount=${NAMESPACE}:${SA_NAME}"' || rlDie "Failed to create ClusterRoleBinding."    else
        rlLog "ClusterRoleBinding for '$SA_NAME' already exists. Proceeding."
    fi
    # --- END OF NEW ADDITIONS ---

    # Obtain token
    rlLog "Obtaining a token for service account: ${SA_NAME} in namespace: ${NAMESPACE}"
    DEFAULT_TOKEN=$(ocpopGetSAtoken "${SA_NAME}" "${NAMESPACE}")
    rlLog "Default token: ${DEFAULT_TOKEN}"
    rlAssertNotEquals "Checking token is not empty" "${DEFAULT_TOKEN}" "" || rlDie "Authentication token is empty"


    rlLog "✅ Using service account: $SA_NAME, namespace: $NAMESPACE, API: $API_HOST_PORT"
rlPhaseEnd

---

############# DAST TESTS ##############
rlPhaseStartTest "Dynamic Application Security Testing"

    # Log helm version
    ocpopLogVerbose "$(helm version)"

    # Clone rapidast repo
    tmpdir=$(mktemp -d)
    pushd "${tmpdir}" || rlDie "Failed to push to temporary directory"
    git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || rlDie "Failed to clone rapidast repository"

    # Download configuration file template
    if [ -z "${KONFLUX}" ]; then
        CONFIG_URL="https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
    else
        CONFIG_URL="https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
    fi
    rlRun "curl -o tang_operator.yaml $CONFIG_URL" || rlDie "Failed to download configuration file"

    # Adapt configuration (token, API, namespace)
    if [ "${EXECUTION_MODE}" == "MINIKUBE" ]; then
        API_HOST_PORT=$(minikube ip)
        DEFAULT_TOKEN="TEST_TOKEN_UNREQUIRED_IN_MINIKUBE"
    fi
    rlAssertNotEquals "Checking token is not empty" "${DEFAULT_TOKEN}" "" || rlDie "Authentication token is empty"

    # Dynamically find the tang-operator service name using a label selector
    TANG_SERVICE_NAME=$("${OC_CMD[@]}" get services --selector=app.kubernetes.io/name=tang-operator -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "${TANG_SERVICE_NAME}" ]; then
        rlDie "Failed to find tang-operator service using label selector. Check your operator's service labels."
    fi
    rlLog "Found tang-operator service name: ${TANG_SERVICE_NAME}"

    # Get the exposed URL
    TANG_ROUTE_URL=$("${OC_CMD[@]}" get route -n "${NAMESPACE}" "${TANG_SERVICE_NAME}" -o jsonpath='{.spec.host}' 2>/dev/null)
    if [ -z "${TANG_ROUTE_URL}" ]; then
        rlLogWarning "Route for service ${TANG_SERVICE_NAME} not found. Trying Cluster IP."
        TANG_SERVICE_IP=$(ocpopGetServiceClusterIp "${TANG_SERVICE_NAME}" "${NAMESPACE}" 10) || rlDie "Failed to get service IP for tang-operator"
        TANG_SERVICE_PORT=$(ocpopGetServicePort "${TANG_SERVICE_NAME}" "${NAMESPACE}") || rlDie "Failed to get service port"
        APPLICATION_URL="https://${TANG_SERVICE_IP}:${TANG_SERVICE_PORT}"
    else
        APPLICATION_URL="https://${TANG_ROUTE_URL}"
    fi

    rlLog "Application URL for DAST: ${APPLICATION_URL}"
    rlAssertNotEquals "Checking application URL is not empty" "${APPLICATION_URL}" "" || rlDie "Application URL is empty"

    sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
    sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
    sed -i s@OPERATOR_NAMESPACE_HERE@"${NAMESPACE}"@g tang_operator.yaml
    # Add a new line to replace the application URL placeholder
    sed -i s@APPLICATION_URL_HERE@"${APPLICATION_URL}"@g tang_operator.yaml

    # Adapt helm
    pushd rapidast || rlDie "Failed to push to rapidast directory"
    sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
    sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
    sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

    # Run rapidast via helm
    rlRun "helm uninstall rapidast --ignore-not-found" 0 "Removing previous rapidast helm chart"
    rlRun "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml" 0 "Installing rapidast helm chart"

    # NOTE: The ocpopGetPodNameWithPartialName function also needs to be updated to use the array
    # This change has to be made in the ocpop-lib file itself, not this script.
    pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1) || rlDie "Failed to find rapidast pod name"
    
    if ! ocpopCheckPodState Completed "${TO_DAST_POD_COMPLETED}" default "${pod_name}"; then
        rlLog "DAST pod failed. Retrieving pod status and logs..."
        rlRun "oc describe pod ${pod_name}"
        rlRun "oc logs ${pod_name}"
        rlDie "Pod ${pod_name} failed to reach 'Completed'"
    fi

    # Extract results
    # Add these lines for debugging
    rlLog "Listing contents of the rapidast directory..."
    rlRun "ls -R ${tmpdir}/rapidast"

    rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

    # Parse results
    rlRun "ls "${tmpdir}"/rapidast/tangservers/DAST*tangservers/" 0 "tmp dir output"
    report_dir=$(ls -1d "${tmpdir}"/rapidast/tangservers/DAST*tangservers/ 2>/dev/null | head -1 | sed -e 's@/$@@g')
    ocpopLogVerbose "REPORT DIR: ${report_dir}"
    rlAssertNotEquals "Checking report_dir not empty" "${report_dir}" "" || rlDie "Report directory not found"

    report_file="${report_dir}/zap/zap-report.json"
    ocpopLogVerbose "REPORT FILE: ${report_file}"

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