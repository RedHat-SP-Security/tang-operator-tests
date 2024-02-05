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
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        TO_DAST_POD_COMPLETED=240 #seconds (DAST lasts around 120 seconds)
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
        rlRun "wget -O tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml"

        # 4 - adapt configuration file template (token, machine)
        if [ "${EXECUTION_MODE}" == "MINIKUBE" ];
        then
            API_HOST_PORT=$(minikube ip)
            DEFAULT_TOKEN="TEST_TOKEN_UNREQUIRED_IN_MINIKUBE"
        else
            API_HOST_PORT=$("${OC_CLIENT}" whoami --show-server | tr -d  ' ')
            DEFAULT_TOKEN=$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}" "$("${OC_CLIENT}" get secret -n "${OPERATOR_NAMESPACE}"\
                            | grep ^tang-operator | grep service-account | awk '{print $1}')" -o json | jq -Mr '.data.token' | base64 -d)
        fi
        sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
        sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
        sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NAMESPACE}"@g tang_operator.yaml
        ocpopLogVerbose "API_HOST_PORT:[${API_HOST_PORT}]"
        ocpopLogVerbose "DEFAULT_TOKEN:[${DEFAULT_TOKEN}]"
        ocpopLogVerbose "OPERATOR_NAMESPACE provided to DAST:[${OPERATOR_NAMESPACE}]"
        rlAssertNotEquals "Checking token not empty" "${DEFAULT_TOKEN}" ""

        # 5 - adapt helm
        pushd rapidast || exit
        sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
        sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
        sed -i s@'tag: "latest"'@'tag: "2.3.0"'@g helm/chart/values.yaml

        # 6 - run rapidast on adapted configuration file (via helm)
        rlRun -c "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" 0 "Installing rapidast helm chart"
        pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" 5 1)
        rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} default ${pod_name}" 0 "Checking POD ${pod_name} in Completed state [Timeout=${TO_DAST_POD_COMPLETED} secs.]"

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

rlJournalPrintText
rlJournalEnd
