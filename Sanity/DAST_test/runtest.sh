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
        if [ -z "${OPERATOR_NAME}" ]; then
            OPERATOR_NAME=tang-operator
        fi
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

        TO_DAST_POD_COMPLETED=300
        TO_RAPIDAST=30

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
        ocpopLogVerbose "$(helm version)"

        tmpdir=$(mktemp -d)
        pushd "${tmpdir}" && git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || exit

        # pick correct template depending on KONFLUX
        if [ -z "${KONFLUX}" ]; then
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
        else
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
        fi

        # common: determine API host
        API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ')

        ##############
        # KONFLUX (ephemeral) branch: create SA + RBAC and fetch token robustly
        ##############
        if [ -n "${KONFLUX}" ]; then
            rlLog "Konflux: preparing service account and RBAC for token creation."

            # Ensure operator namespace variable is set
            if [ -z "${OPERATOR_NAMESPACE}" ]; then
                rlDie "OPERATOR_NAMESPACE must be set for KONFLUX runs"
            fi

            # Ensure service account exists BEFORE rolebinding creation
            rlLog "Checking for service account ${OPERATOR_NAME} in namespace ${OPERATOR_NAMESPACE}..."
            if ! "${OC_CLIENT}" get sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" &>/dev/null; then
                rlLog "Service account ${OPERATOR_NAME} not found. Creating it now."
                rlRun "${OC_CLIENT} create sa ${OPERATOR_NAME} -n ${OPERATOR_NAMESPACE}"
            fi

            # Grant per-namespace permission to create tokens for serviceaccounts (role + binding to SA)
            rlLog "Granting token-creation permissions to the service account."
            rlRun "${OC_CLIENT} create role token-creator --verb=create --resource=serviceaccounts/token -n ${OPERATOR_NAMESPACE}"
            rlRun "${OC_CLIENT} create rolebinding token-creator-binding-sa --role=token-creator --serviceaccount=${OPERATOR_NAMESPACE}:${OPERATOR_NAME} -n ${OPERATOR_NAMESPACE}"
            sleep 2

            # Create cluster-level permissions needed by rapidast scanning
            rlLog "Creating ClusterRole and ClusterRoleBinding for the DAST scan."
            rlRun "${OC_CLIENT} create clusterrole daster --verb=get,list --resource=pods,services,ingresses,deployments"
            rlRun "${OC_CLIENT} create clusterrolebinding daster-binding --clusterrole=daster --serviceaccount=${OPERATOR_NAMESPACE}:${OPERATOR_NAME}"
            sleep 5

            # Acquire token: try methods in order that supports old/new oc versions
            DEFAULT_TOKEN=""
            rlLog "Attempting to acquire token for SA ${OPERATOR_NAME} in ${OPERATOR_NAMESPACE}..."

            # 1) Try oc sa get-token (older oc versions that include sa subcommand)
            if DEFAULT_TOKEN=$("${OC_CLIENT}" sa get-token "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true); then
                if [ -n "${DEFAULT_TOKEN}" ]; then
                    rlLog "Acquired token using 'oc sa get-token'."
                else
                    DEFAULT_TOKEN=""
                fi
            fi

            # 2) Try 'oc create token' (newer oc versions)
            if [ -z "${DEFAULT_TOKEN}" ]; then
                if "${OC_CLIENT}" create token --help >/dev/null 2>&1; then
                    rlLog "Trying 'oc create token'..."
                    DEFAULT_TOKEN=$("${OC_CLIENT}" create token "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true)
                else
                    rlLog "'oc create token' not available in this oc client; skipping."
                fi
            fi

            # 3) Fallback: read token from SA secret
            if [ -z "${DEFAULT_TOKEN}" ]; then
                rlLog "Falling back to extracting token from SA secret..."
                SECRET_NAME=$("${OC_CLIENT}" get sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
                if [ -n "${SECRET_NAME}" ]; then
                    DEFAULT_TOKEN=$("${OC_CLIENT}" get secret "${SECRET_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.data.token}' 2>/dev/null || true)
                    if [ -n "${DEFAULT_TOKEN}" ]; then
                        DEFAULT_TOKEN=$(printf "%s" "${DEFAULT_TOKEN}" | base64 --decode)
                    fi
                else
                    rlLog "No secret name found on SA ${OPERATOR_NAME}; cannot read token from secret."
                fi
            fi

            # Final check
            if [ -z "${DEFAULT_TOKEN}" ]; then
                rlDie "Failed to acquire token for DAST scan in Konflux environment."
            fi

        else
            ##############
            # CRC / external clusters: keep original behavior (unchanged)
            ##############
            rlLog "Non-KONFLUX pipeline: using existing kubeconfig token/credentials."

            API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ')

            # Try oc whoami -t first
            DEFAULT_TOKEN=$("${OC_CLIENT}" whoami -t 2>/dev/null || true)

            # If not present, try ocpop helper (existing behavior)
            if [ -z "${DEFAULT_TOKEN}" ]; then
                DEFAULT_TOKEN=$(ocpopPrintTokenFromConfiguration || true)
            fi

            # fallback: get token from operator SA secret (existing behavior)
            if [ -z "${DEFAULT_TOKEN}" ]; then
                # get secret name for the operator SA if available
                if SECRET_NAME=$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}" | grep ^${OPERATOR_NAME} | grep service-account | awk '{print $1}' 2>/dev/null || true); then
                    if [ -n "${SECRET_NAME}" ]; then
                        DEFAULT_TOKEN=$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}" "${SECRET_NAME}" -o json | jq -Mr '.data.token' | base64 -d 2>/dev/null || true)
                    fi
                fi
            fi
        fi

        echo "API_HOST_PORT=${API_HOST_PORT}"
        echo "DEFAULT_TOKEN=${DEFAULT_TOKEN}"

        rlAssertNotEquals "Checking token not empty" "${DEFAULT_TOKEN}" ""

        # Replace placeholders in YAML
        sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
        sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
        sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml

        # 5 - adapt helm and run rapidast
        pushd rapidast || exit
        sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
        sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
        sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

        helm uninstall rapidast || true
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
        helm uninstall rapidast || true

        # 10 - Konflux-only cleanup of RBAC objects we created
        if [ -n "${KONFLUX}" ]; then
            rlLog "Cleaning Konflux-created RBAC objects"
            rlRun "${OC_CLIENT} delete clusterrole daster" || true
            rlRun "${OC_CLIENT} delete clusterrolebinding daster-binding" || true
            rlRun "${OC_CLIENT} delete role token-creator -n ${OPERATOR_NAMESPACE}" || true
            rlRun "${OC_CLIENT} delete rolebinding token-creator-binding-sa -n ${OPERATOR_NAMESPACE}" || true
            # Do NOT delete the operator SA (it may pre-exist or be expected)
        fi

        popd || exit
        popd || exit

    rlPhaseEnd

rlJournalPrintText
rlJournalEnd