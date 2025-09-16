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

# Include Beaker environment (guard to avoid double-source warnings)
if [ -z "${BEAKERLIB_INCLUDED:-}" ]; then
    . /usr/share/beakerlib/beakerlib.sh || exit 1
    BEAKERLIB_INCLUDED=1
fi

ocpopGetAuth() {
    local sa_name=${1:-dast-test-sa}
    local namespace api_host_port token
    local oc_bin="${OC_CLIENT:-oc}"
    local -a oc_cmd=("${oc_bin}")

    rlLogVerbose "===== DEBUG: Starting ocpopGetAuth ====="
    rlLogVerbose "OC_CLIENT=${OC_CLIENT:-<unset>}"
    rlLogVerbose "KUBECONFIG=${KUBECONFIG:-<unset>}"
    rlLogVerbose "OCP_TOKEN=${OCP_TOKEN:-<unset>}"

    # --- Case 1: CRC pod ---
    if [ -s /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        namespace=$(< /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        api_host_port="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
        token=$(< /var/run/secrets/kubernetes.io/serviceaccount/token)
        rlLog "Detected CRC pod (ns=${namespace}, api=${api_host_port})."
        rlRun "${oc_bin} login --token=${token} --server=${api_host_port}" 0 "oc login with SA token"

    # --- Case 2: Ephemeral pipeline ---
    elif [ -n "${KUBECONFIG}" ] && [[ "${KUBECONFIG}" == /credentials/* ]]; then
        rlLogVerbose "===== DEBUG: Ephemeral pipeline detected ====="
        rlLogVerbose "KUBECONFIG exists: $( [ -f "${KUBECONFIG}" ] && echo yes || echo no )"
        rlRun "ls -la /credentials || true" 0 "List /credentials for debug"

        oc_cmd+=("--kubeconfig=${KUBECONFIG}")
        api_host_port=$("${oc_cmd[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')
        namespace=$("${oc_cmd[@]}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)
        rlLog "Ephemeral kubeconfig (ns=${namespace}, api=${api_host_port})."

        for i in {1..5}; do
            token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            rlLogVerbose "Attempt $i: token length=${#token}"
            [ -n "$token" ] && break
            sleep 2
        done

        if [ -z "$token" ]; then
            if ls /credentials/*-password >/dev/null 2>&1; then
                local user pass
                user=$(head -n1 /credentials/*-username 2>/dev/null || echo "admin")
                pass=$(< /credentials/*-password)
                rlLog "Logging in with ephemeral username/password (user=${user})"
                rlRun "${oc_bin} login -u ${user} -p ${pass} ${api_host_port} --kubeconfig=${KUBECONFIG}" 0 "oc login ephemeral creds"
                token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            elif [ -n "${OCP_TOKEN}" ]; then
                rlLog "Logging in with OCP_TOKEN"
                rlRun "${oc_bin} login --token=${OCP_TOKEN} --server=${api_host_port} --kubeconfig=${KUBECONFIG}" 0 "oc login OCP_TOKEN"
                token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            fi
        fi

    # --- Case 3: External cluster ---
    else
        local kubeconfig_path="${KUBECONFIG:-${HOME}/.kube/config}"
        rlLogVerbose "===== DEBUG: External cluster ====="
        rlLogVerbose "Using kubeconfig path: ${kubeconfig_path}"
        if [ -s "${kubeconfig_path}" ]; then
            oc_cmd+=("--kubeconfig=${kubeconfig_path}")
            api_host_port=$("${oc_cmd[@]}" whoami --show-server | tr -d ' ')
            namespace="${OPERATOR_NAMESPACE:-$(${oc_bin} config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)}"
            rlLog "External cluster (ns=${namespace}, api=${api_host_port})."
            token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            rlLogVerbose "Token length: ${#token}"
            if [ -z "$token" ] && [ -n "${OCP_TOKEN}" ]; then
                rlLog "Logging in with OCP_TOKEN"
                rlRun "${oc_bin} login --token=${OCP_TOKEN} --server=${api_host_port}" 0 "oc login OCP_TOKEN"
                token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            fi
        else
            rlDie "No kubeconfig found at ${kubeconfig_path}"
        fi
    fi

    # --- Fallback to SA secret ---
    if [ -z "$token" ]; then
        rlLogWarning "Primary auth failed; trying SA secret."
        local secret_name
        secret_name=$("${oc_cmd[@]}" get sa "$sa_name" -n "$namespace" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
        rlLogVerbose "SA secret: ${secret_name:-<none>}"
        if [ -n "$secret_name" ]; then
            token=$("${oc_cmd[@]}" get secret -n "$namespace" "$secret_name" -o json | jq -Mr '.data.token' | base64 -d 2>/dev/null || true)
            rlLogVerbose "Token length from SA secret: ${#token}"
        fi
    fi

    [ -z "$token" ] && rlDie "Failed to retrieve token."

    rlLogVerbose "===== End of ocpopGetAuth ====="
    echo "API_HOST_PORT=${api_host_port}"
    echo "DEFAULT_TOKEN=${token}"
    echo "NAMESPACE=${namespace}"
}

# --- MAIN TEST ---
rlJournalStart

rlPhaseStartSetup
    OPERATOR_NAME="${OPERATOR_NAME:-tang-operator}"
    RAPIDAST_NS="rapidast-test"
    rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' 0 "Import ocpop-lib"
    rlRun ". ../../TestHelpers/functions.sh" 0 "Import helper functions"
    TO_DAST_POD_COMPLETED=300
    TO_RAPIDAST=30

    if ! command -v helm &> /dev/null; then
        ARCH=$(
            case "$(uname -m)" in
                x86_64)  echo amd64 ;;
                aarch64) echo arm64 ;;
                *)       uname -m ;;
            esac
        )
        OS=$(uname | tr '[:upper:]' '[:lower:]')
        LATEST_RELEASE_TAG=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
        rlRun "curl -LO https://get.helm.sh/helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz" 0 "Download Helm"
        rlRun "tar -xzf helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz" 0 "Extract Helm"
        rlRun "mv ${OS}-${ARCH}/helm /usr/local/bin/helm" 0 "Install Helm"
    fi
rlPhaseEnd

rlPhaseStartTest "Dynamic Application Security Testing"
    rlRun "ocpopLogVerbose \"\$(helm version)\"" 0 "Helm version"

    rlRun "tmpdir=$(mktemp -d)" 0 "Create temporary directory"
    rlRun "pushd ${tmpdir}" 0 "Enter temporary directory"

    rlRun "git clone https://github.com/RedHatProductSecurity/rapidast.git -b development" 0 "Clone Rapidast repo"
    rlRun "pushd rapidast" 0 "Enter Rapidast directory"

    rlRun -c "curl -sSfL -o tang_operator.yaml \
        https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml" 0 "Fetch tang_operator.yaml template"

    eval "$(ocpopGetAuth)"
    rlLog "API=${API_HOST_PORT} | NS=${NAMESPACE} | Token=${DEFAULT_TOKEN:0:6}..."

    rlRun "sed -i 's@API_HOST_PORT_HERE@${API_HOST_PORT}@g' tang_operator.yaml" 0 "Replace API_HOST_PORT"
    rlRun "sed -i 's@AUTH_TOKEN_HERE@${DEFAULT_TOKEN}@g' tang_operator.yaml" 0 "Replace AUTH_TOKEN"
    rlRun "sed -i 's@OPERATOR_NAMESPACE_HERE@${NAMESPACE}@g' tang_operator.yaml" 0 "Replace OPERATOR_NAMESPACE"
    rlRun "grep -q 'HERE' tang_operator.yaml && rlDie 'Template placeholders not replaced!'" 0 "Check placeholders replaced"

    rlRun "sed -i s@'kubectl --kubeconfig=./kubeconfig '@'${OC_CLIENT} '@g helm/results.sh" 0 "Adapt helm/results.sh"
    rlRun "sed -i s@'secContext: '{}''@'secContext: '{\"privileged\": true}'@g helm/chart/values.yaml" 0 "Enable privileged"
    rlRun "sed -i s@'tag: \"latest\"'@'tag: \"2.8.0\"'@g helm/chart/values.yaml" 0 "Set Rapidast tag"

    rlRun "helm uninstall rapidast --namespace ${RAPIDAST_NS} || true" 0 "Uninstall existing Rapidast"
    rlRun "helm install rapidast ./helm/chart/ \
        --namespace ${RAPIDAST_NS} \
        --create-namespace \
        --set-file rapidastConfig=$(pwd)/tang_operator.yaml" 0 "Install Rapidast"

    pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "${RAPIDAST_NS}" "${TO_RAPIDAST}" 1)
    rlAssertNotEquals "Rapidast pod must not be empty" "${pod_name}" ""
    rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} ${RAPIDAST_NS} ${pod_name}" 0 "Check Rapidast pod Completed"

    rlRun -c "bash ./helm/results.sh" 0 "Extract DAST results"

    rlRun "report_dir=$(ls -1d ${tmpdir}/rapidast/tangservers/DAST*tangservers/ | head -1 | sed -e 's@/$@@g')" 0 "Locate report directory"
    rlLog "REPORT DIR: ${report_dir}"

    rlRun "report_file=$(find ${report_dir} -type f -name zap-report.json | head -1)" 0 "Locate zap-report.json"
    [ -f "$report_file" ] || rlDie "DAST report not found!"
    rlLog "DAST report ready: $report_file"

    alerts=$(jq '.site[0].alerts | length' < "$report_file")
    for ((i=0; i<alerts; i++)); do
        risk=$(jq -r ".site[0].alerts[${i}].riskdesc" < "$report_file")
        rlLog "Alert[$i] -> $risk"
        rlAssertNotEquals "No High Risk alerts" "$risk" "High"
    done

    rlRun "popd" 0 "Exit Rapidast directory"
    rlRun "popd" 0 "Exit temporary directory"
rlPhaseEnd

rlJournalPrintText
rlJournalEnd