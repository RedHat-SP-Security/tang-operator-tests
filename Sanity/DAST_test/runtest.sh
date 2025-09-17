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
    
    -------------

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

        if [ -n "${KONFLUX}" ]; then
            # --- FIX: Handle the ephemeral pipeline with a specific logic. ---
            # Ephemeral (Konflux) pipelines may not have a user token, so we create one for the SA.
            API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ')
            
            rlLog "Checking for service account ${OPERATOR_NAME} in namespace ${OPERATOR_NAMESPACE}..."
            if ! "${OC_CLIENT}" get sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
                rlLog "Service account ${OPERATOR_NAME} not found. Creating it now."
                rlRun "${OC_CLIENT} create sa ${OPERATOR_NAME} -n ${OPERATOR_NAMESPACE}"
            fi

            # --- FIX: Create RBAC permissions for the service account. ---
            rlLog "Creating ClusterRole and ClusterRoleBinding for the DAST scan."
            rlRun "${OC_CLIENT} create clusterrole daster --verb=get,list --resource=pods,services,ingresses,deployments"
            rlRun "${OC_CLIENT} create clusterrolebinding daster-binding --clusterrole=daster --serviceaccount=${OPERATOR_NAMESPACE}:${OPERATOR_NAME}"
            sleep 5 # Wait for RBAC to propagate

            DEFAULT_TOKEN=$("${OC_CLIENT}" create token "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}")

            if [ -z "${DEFAULT_TOKEN}" ]; then
                rlDie "Failed to acquire token for DAST scan in Konflux environment."
            fi
            # --- END FIX ---
        else
            # --- FIX: Handle CRC and other pipelines with a separate, simpler logic. ---
            # CRC and similar pipelines should have an accessible token.
            API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ')
            
            # --- FIX: Create RBAC permissions for the service account. ---
            rlLog "Checking for service account ${OPERATOR_NAME} in namespace ${OPERATOR_NAMESPACE}..."
            if ! "${OC_CLIENT}" get sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
                rlLog "Service account ${OPERATOR_NAME} not found. Creating it now."
                rlRun "${OC_CLIENT} create sa ${OPERATOR_NAME} -n ${OPERATOR_NAMESPACE}"
            fi
            
            rlLog "Creating ClusterRole and ClusterRoleBinding for the DAST scan."
            rlRun "${OC_CLIENT} create clusterrole daster --verb=get,list --resource=pods,services,ingresses,deployments"
            rlRun "${OC_CLIENT} create clusterrolebinding daster-binding --clusterrole=daster --serviceaccount=${OPERATOR_NAMESPACE}:${OPERATOR_NAME}"
            sleep 5 # Wait for RBAC to propagate
            # --- END FIX ---

            # Get the token using the traditional method.
            DEFAULT_TOKEN=$(oc whoami -t)
            if [ -z "${DEFAULT_TOKEN}" ]; then
                DEFAULT_TOKEN=$(ocpopPrintTokenFromConfiguration)
            fi
            if [ -z "${DEFAULT_TOKEN}" ]; then
                # fallback: get token from operator secrets
                DEFAULT_TOKEN=$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}" \
                    "$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}" | grep ^${OPERATOR_NAME} | grep service-account | awk '{print $1}')" \
                    -o json | jq -Mr '.data.token' | base64 -d)
            fi
        fi

        echo "API_HOST_PORT=${API_HOST_PORT}"
        echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"

        # Replace placeholders in YAML
        sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
        sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
        sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml

        rlAssertNotEquals "Checking token not empty" "${DEFAULT_TOKEN}" ""

        # 5 - adapt helm
        pushd rapidast || exit
        sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
        sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
        sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

        # 6 - run rapidast on adapted configuration file (via helm)
        helm uninstall rapidast
        rlRun -c "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" 0 "Installing rapidast helm chart"
        pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1)
        rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} default ${pod_name}" 0 "Checking POD ${pod_name} in Completed state [Timeout=${TO_DAST_POD_COMPLETED} secs.]"

        # 7 - extract results
        rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

        # Find the ZAP report file using a robust search.
        report_file=$(find "${tmpdir}" -name "zap-report.json" -type f | head -n 1)
        report_dir=$(dirname "${report_file}")
        
        ocpopLogVerbose "REPORT FILE:${report_file}"
        ocpopLogVerbose "REPORT DIR:${report_dir}"

        # 8 - parse results
        if [ -n "${report_dir}" ] && [ -f "${report_file}" ];
        then
            alerts=$(jq '.site[0].alerts | length' < "${report_file}" )
            ocpopLogVerbose "Alerts:${alerts}"
            for ((alert=0; alert<alerts; alert++));
            do
                risk_desc=$(jq ".site[0].alerts[${alert}].riskdesc" < "${report_file}" | awk '{print $1}' | tr -d '"' | tr -d " ")
                rlLog "Alert[${alert}] -> Priority:[${risk_desc}]"
                rlAssertNotEquals "Checking alarm is not High Risk" "${risk_desc}" "High"
            done
            if [ "${alerts}" != "0" ];
            then
                rlLogWarning "A total of [${alerts}] alerts were detected! Please, review ZAP report: ${report_file}"
            else
                rlLog "No alerts detected"
            fi
        else
            rlLogWarning "Report file:${report_file} does not exist"
        fi

        # 9 - clean helm installation
        helm uninstall rapidast
        # Clean up RBAC created for the test
        rlRun "${OC_CLIENT} delete clusterrole daster"
        rlRun "${OC_CLIENT} delete clusterrolebinding daster-binding"

        # 10 - return
        popd || exit
        popd || exit

    rlPhaseEnd
    
    -------------
    
rlJournalPrintText
rlJournalEnd