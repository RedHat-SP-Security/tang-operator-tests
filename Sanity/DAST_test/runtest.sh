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

        # Ensure helm present
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

        # Pick template depending on KONFLUX
        if [ -z "${KONFLUX}" ]; then
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"
        else
            rlRun "curl -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml"
        fi

        ############################################################################
        # Determine API host and get token based on environment capabilities
        ############################################################################
        API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d ' ')
        rlLog "API_HOST_PORT determined: ${API_HOST_PORT}"

        ############################################################################
        # Token acquisition / authentication
        ############################################################################
        DEFAULT_TOKEN=$("${OC_CLIENT}" whoami -t 2>/dev/null || true)

        if [ -z "${DEFAULT_TOKEN}" ]; then
            rlLog "oc whoami -t failed, trying other methods."

            # Try modern oc create token
            DEFAULT_TOKEN=$("${OC_CLIENT}" create token "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" 2>/dev/null || true)
        fi

        if [ -z "${DEFAULT_TOKEN}" ]; then
            rlLog "oc create token failed, falling back to secret."
            SECRET_NAME=$("${OC_CLIENT}" get sa "${OPERATOR_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
            if [ -n "${SECRET_NAME}" ]; then
                DEFAULT_TOKEN=$("${OC_CLIENT}" get secret "${SECRET_NAME}" -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.data.token}' | base64 --decode || true)
            fi
        fi

        # Final fallback for Konflux / ephemeral: use kubeconfig
        if [ -z "${DEFAULT_TOKEN}" ] && [ -n "${KUBECONFIG_CONTENT}" ]; then
            rlLog "Falling back to KUBECONFIG_CONTENT for ephemeral pipeline."
            export KUBECONFIG=/tmp/kubeconfig.yaml
            # Try base64 decode, fallback to plain text
            echo "${KUBECONFIG_CONTENT}" | base64 -d 2>/dev/null > "${KUBECONFIG}" || echo "${KUBECONFIG_CONTENT}" > "${KUBECONFIG}"
            rlRun "${OC_CLIENT} whoami" 0 "Verified cluster access via kubeconfig"
            DEFAULT_TOKEN="TOKEN_NOT_USED_IN_KONFLUX"
        fi

        if [ -z "${DEFAULT_TOKEN}" ]; then
            rlDie "Failed to acquire token or kubeconfig for DAST scan."
        fi

        # Replace placeholders in YAML
        sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
        sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
        sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml

        # adapt helm and run rapidast
        pushd rapidast || exit
        sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
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

        helm uninstall rapidast || true

        # Clean up RBAC created for the test (only if real token was used)
        if [ "${DEFAULT_TOKEN}" != "TOKEN_NOT_USED_IN_KONFLUX" ]; then
            rlRun "${OC_CLIENT} delete clusterrole daster" || true
            rlRun "${OC_CLIENT} delete clusterrolebinding daster-binding" || true
        fi

        popd || exit
        popd || exit

    rlPhaseEnd

rlJournalPrintText
rlJournalEnd