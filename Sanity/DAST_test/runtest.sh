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

OC_CLIENT=${OC_CLIENT:-oc}

rlJournalStart
rlPhaseStartSetup
    [ -z "${OPERATOR_NAME}" ] && OPERATOR_NAME=tang-operator

    rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
    rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

    TO_DAST_POD_COMPLETED=300
    TO_RAPIDAST=30

    # Ensure helm is installed
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

-------------

############# DAST TESTS ##############
rlPhaseStartTest "Dynamic Application Security Testing"
    ocpopLogVerbose "$(helm version)"

    tmpdir=$(mktemp -d)
    pushd "${tmpdir}" || exit
    git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || exit

    # Download tang_operator template depending on environment
    if [ -z "${KONFLUX}" ]; then
        rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
    else
        rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
    fi

    # Determine API host
    API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ')
    rlLog "API_HOST_PORT determined: ${API_HOST_PORT}"

    # --- Authentication logic ---
    DEFAULT_TOKEN=""
    KUBECONFIG_PATH=""

    # Try token-based login (CRC-like)
    DEFAULT_TOKEN=$("${OC_CLIENT}" whoami -t 2>/dev/null || true)
    if [ -n "${DEFAULT_TOKEN}" ]; then
        rlLog "CRC-like environment detected. Using token-based authentication."
        rlRun "${OC_CLIENT} login --token=${DEFAULT_TOKEN} --server=${API_HOST_PORT}" 0 "Login to OCP with token"
    else
        # Ephemeral/Konflux environment
        rlLog "Ephemeral/Konflux detected. Creating service account + token for DAST pod."

        # Service account
        "${OC_CLIENT}" create sa ${OPERATOR_NAME} -n ${OPERATOR_NAMESPACE} || true

        # Token creation role
        "${OC_CLIENT}" create role token-creator --verb=create --resource=serviceaccounts/token -n ${OPERATOR_NAMESPACE} || true
        "${OC_CLIENT}" create rolebinding token-creator-binding-sa \
            --role=token-creator \
            --serviceaccount=${OPERATOR_NAMESPACE}:${OPERATOR_NAME} \
            -n ${OPERATOR_NAMESPACE} || true

        # ClusterRole / ClusterRoleBinding for DAST pod
        "${OC_CLIENT}" create clusterrole daster --verb=get,list --resource=pods,services,ingresses,deployments || true
        "${OC_CLIENT}" create clusterrolebinding daster-binding \
            --clusterrole=daster \
            --serviceaccount=${OPERATOR_NAMESPACE}:${OPERATOR_NAME} || true

        rlRun "sleep 5"

        # Extract token from service account
        SECRET_NAME=$("${OC_CLIENT}" get sa ${OPERATOR_NAME} -n ${OPERATOR_NAMESPACE} -o jsonpath='{.secrets[0].name}')
        DEFAULT_TOKEN=$("${OC_CLIENT}" get secret "${SECRET_NAME}" -n ${OPERATOR_NAMESPACE} -o jsonpath='{.data.token}' | base64 --decode)
        rlLog "Service account token acquired for ephemeral pipeline."
    fi

    echo "API_HOST_PORT=${API_HOST_PORT}"
    echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"

    # Replace placeholders in YAML
    sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
    sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml

    # Auth token replacement
    sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
    sed -i s@KUBECONFIG_PATH_HERE@""@g tang_operator.yaml

    # adapt helm and run rapidast
    pushd rapidast || exit
    sed -i "s@kubectl --kubeconfig=./kubeconfig @${OC_CLIENT} @" helm/results.sh
    sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
    sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

    helm uninstall rapidast || true
    rlRun -c "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" 0 "Installing rapidast helm chart"

    pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1)
    rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} default ${pod_name}" 0 "Checking POD ${pod_name} in Completed state [Timeout=${TO_DAST_POD_COMPLETED} secs.]"

    # extract results
    rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

    report_file=$(find "${tmpdir}" -name "zap-report.json" -type f | head -n 1)
    report_dir=$(dirname "${report_file}")

    ocpopLogVerbose "REPORT FILE:${report_file}"
    ocpopLogVerbose "REPORT DIR:${report_dir}"

    if [ -n "${report_dir}" ] && [ -f "${report_file}" ]; then
        alerts=$(jq '.site[0].alerts | length' < "${report_file}")
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

    helm uninstall rapidast || true

    # Clean up ephemeral RBAC only if it was created
    if [ -z "${KUBECONFIG_CONTENT}" ]; then
        rlRun "${OC_CLIENT} delete clusterrole daster" || true
        rlRun "${OC_CLIENT} delete clusterrolebinding daster-binding" || true
    fi

    popd || exit
    popd || exit

rlPhaseEnd

rlJournalPrintText
rlJournalEnd

# OC_CLIENT=${OC_CLIENT:-oc}

# rlJournalStart
#     rlPhaseStartSetup
#         [ -z "${OPERATOR_NAME}" ] && OPERATOR_NAME=tang-operator

#         rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
#         rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

#         TO_DAST_POD_COMPLETED=300
#         TO_RAPIDAST=30

#         # Ensure helm is installed
#         if ! command -v helm &> /dev/null; then
#             ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
#             OS=$(uname | awk '{print tolower($0)}')
#             LATEST_RELEASE_TAG=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
#             RELEASE_URL="https://get.helm.sh/helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz"
#             TAR_FILE="helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz"
#             rlRun "curl -LO $RELEASE_URL"
#             rlRun "tar -xzf $TAR_FILE"
#             rlRun "mv ${OS}-${ARCH}/helm /usr/local/bin/helm"
#         fi
#     rlPhaseEnd
    
#     -------------

#     ############# DAST TESTS ##############
#     rlPhaseStartTest "Dynamic Application Security Testing"
#         ocpopLogVerbose "$(helm version)"

#         tmpdir=$(mktemp -d)
#         pushd "${tmpdir}" || exit
#         git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || exit

#         # Download tang_operator template depending on environment
#         if [ -z "${KONFLUX}" ]; then
#             rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
#         else
#             rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
#         fi

#         # Determine API host
#         API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ')
#         rlLog "API_HOST_PORT determined: ${API_HOST_PORT}"

#         # --- FIX: Authentication and RBAC logic for both pipelines. ---
#         DEFAULT_TOKEN=""
#         KUBECONFIG_PATH=""

#         # Check if we have a valid token (CRC-like environment)
#         DEFAULT_TOKEN=$("${OC_CLIENT}" whoami -t 2>/dev/null || true)
#         if [ -z "${DEFAULT_TOKEN}" ]; then
#             # If no token, we are in an ephemeral-like environment.
#             # We'll use the provided kubeconfig content.
#             rlLog "Ephemeral-like environment detected. Relying on KUBECONFIG for authentication."
#             KUBECONFIG_PATH="${tmpdir}/kubeconfig"
#             echo "${KUBECONFIG_CONTENT}" | base64 -d 2>/dev/null > "${KUBECONFIG_PATH}" || echo "${KUBECONFIG_CONTENT}" > "${KUBECONFIG_PATH}"
#             rlRun "${OC_CLIENT} --kubeconfig=${KUBECONFIG_PATH} whoami" 0 "Verified cluster access via kubeconfig"
#         else
#             rlLog "CRC-like environment detected. Using token-based authentication."
#             rlRun "${OC_CLIENT} login --token=${DEFAULT_TOKEN} --server=${API_HOST_PORT}" 0 "Login to OCP with token"
#         fi

#         # Create service account and RBAC for the DAST pod (necessary for both pipelines)
#         rlLog "Checking for service account ${OPERATOR_NAME} in namespace ${OPERATOR_NAMESPACE}..."
#         if ! "${OC_CLIENT}" get sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
#             rlLog "Service account ${OPERATOR_NAME} not found. Creating it now."
#             rlRun "${OC_CLIENT} create sa ${OPERATOR_NAME} -n ${OPERATOR_NAMESPACE}"
#         fi

#         rlLog "Creating ClusterRole and ClusterRoleBinding for the DAST scan."
#         rlRun "${OC_CLIENT} create clusterrole daster --verb=get,list --resource=pods,services,ingresses,deployments" || true
#         rlRun "${OC_CLIENT} create clusterrolebinding daster-binding --clusterrole=daster --serviceaccount=${OPERATOR_NAMESPACE}:${OPERATOR_NAME}" || true
#         rlRun "sleep 5"

#         echo "API_HOST_PORT=${API_HOST_PORT}"
#         echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"
#         echo "KUBECONFIG_PATH=${KUBECONFIG_PATH}"

#         # Replace placeholders in YAML
#         sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
#         sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml

#         # Conditional replacement based on auth method
#         if [ -n "${KUBECONFIG_PATH}" ]; then
#             rlLog "Using kubeconfig-based authentication."
#             sed -i s@AUTH_TOKEN_HERE@"TOKEN_NOT_NEEDED"@g tang_operator.yaml
#             # Ensure the template has this placeholder
#             sed -i s@KUBECONFIG_PATH_HERE@"${KUBECONFIG_PATH}"@g tang_operator.yaml
#         else
#             rlLog "Using token-based authentication."
#             sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
#             sed -i s@KUBECONFIG_PATH_HERE@""@g tang_operator.yaml
#         fi
        
#         # adapt helm and run rapidast
#         pushd rapidast || exit
#         sed -i "s@kubectl --kubeconfig=./kubeconfig @${OC_CLIENT} @" helm/results.sh
#         sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
#         sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

#         helm uninstall rapidast || true
#         rlRun -c "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" 0 "Installing rapidast helm chart"

#         pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1)
#         rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} default ${pod_name}" 0 "Checking POD ${pod_name} in Completed state [Timeout=${TO_DAST_POD_COMPLETED} secs.]"

#         # extract results
#         rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

#         report_file=$(find "${tmpdir}" -name "zap-report.json" -type f | head -n 1)
#         report_dir=$(dirname "${report_file}")

#         ocpopLogVerbose "REPORT FILE:${report_file}"
#         ocpopLogVerbose "REPORT DIR:${report_dir}"

#         if [ -n "${report_dir}" ] && [ -f "${report_file}" ]; then
#             alerts=$(jq '.site[0].alerts | length' < "${report_file}")
#             ocpopLogVerbose "Alerts:${alerts}"
#             for ((alert=0; alert<alerts; alert++)); do
#                 risk_desc=$(jq ".site[0].alerts[${alert}].riskdesc" < "${report_file}" | awk '{print $1}' | tr -d '"' | tr -d " ")
#                 rlLog "Alert[${alert}] -> Priority:[${risk_desc}]"
#                 rlAssertNotEquals "Checking alarm is not High Risk" "${risk_desc}" "High"
#             done
#             if [ "${alerts}" != "0" ]; then
#                 rlLogWarning "A total of [${alerts}] alerts were detected! Please, review ZAP report: ${report_file}"
#             else
#                 rlLog "No alerts detected"
#             fi
#         else
#             rlLogWarning "Report file:${report_file} does not exist"
#         fi

#         helm uninstall rapidast || true

#         # Clean up RBAC created for the test.
#         rlRun "${OC_CLIENT} delete clusterrole daster" || true
#         rlRun "${OC_CLIENT} delete clusterrolebinding daster-binding" || true
        
#         popd || exit
#         popd || exit

#     rlPhaseEnd

# rlJournalPrintText
# rlJournalEnd