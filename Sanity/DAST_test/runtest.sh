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

# --- Helpers -----------------------------------------------------------------

# Get auth information and ensure we can run oc commands.
# Outputs: API_HOST_PORT, DEFAULT_TOKEN, NAMESPACE (exported via echo)
ocpopGetAuth() {
    local sa_name=${1:-dast-test-sa}
    local namespace api_host_port token
    local oc_bin="${OC_CLIENT:-oc}"
    local -a oc_cmd=("${oc_bin}")

    rlLog "Starting ocpopGetAuth()"
    rlLog "OC_CLIENT=${OC_CLIENT:-<unset>}"
    rlLog "KUBECONFIG=${KUBECONFIG:-<unset>}"
    rlLog "OCP_TOKEN=${OCP_TOKEN:-<unset>}"

    # --- Case A: Ephemeral pipeline with /credentials kubeconfig ---
    if [ -n "${KUBECONFIG}" ] && [[ "${KUBECONFIG}" == /credentials/* ]]; then
        rlLog "Detected ephemeral pipeline kubeconfig: ${KUBECONFIG}"
        rlRun "ls -la /credentials || true" 0 "List /credentials for debug"
        oc_cmd+=("--kubeconfig=${KUBECONFIG}")
        api_host_port=$("${oc_cmd[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
        namespace=$("${oc_cmd[@]}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)
        rlLog "Ephemeral kubeconfig reports: api=${api_host_port:-<none>}, ns=${namespace}"

        for try in {1..5}; do
            token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            rlLog "whoami -t attempt ${try}, token length=${#token}"
            [ -n "$token" ] && break
            sleep 2
        done

        if [ -z "$token" ]; then
            if ls /credentials/*-password >/dev/null 2>&1; then
                local user pass
                user=$(head -n1 /credentials/*-username 2>/dev/null || echo "admin")
                pass=$(< /credentials/*-password)
                rlLog "Attempting oc login with username/password (user=${user})"
                rlRun "${oc_bin} login -u ${user} -p '${pass}' --server='${api_host_port}' --kubeconfig='${KUBECONFIG}'" 0-255 "oc login (ephemeral creds)" || true
                token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            elif [ -n "${OCP_TOKEN}" ]; then
                rlLog "Attempting oc login with provided OCP_TOKEN"
                rlRun "${oc_bin} login --token='${OCP_TOKEN}' --server='${api_host_port}' --kubeconfig='${KUBECONFIG}'" 0-255 "oc login (OCP_TOKEN)" || true
                token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            fi
        fi

    elif [ -s /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        namespace=$(< /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo default)
        api_host_port="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
        token=$(< /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || true)
        rlLog "Detected in-cluster environment (service account). namespace=${namespace}"
    else
        rlLog "Assuming external cluster (oc client present / already logged in)"
        api_host_port=$("${oc_bin}" whoami --show-server 2>/dev/null | tr -d ' ' || true)
        namespace=$("${oc_bin}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)
        token=$("${oc_bin}" whoami -t 2>/dev/null || true)
        if [ -z "${token}" ] && [ -n "${OCP_TOKEN}" ]; then
            rlLog "No local token; attempting login with OCP_TOKEN"
            rlRun "${oc_bin} login --token='${OCP_TOKEN}' --server='${api_host_port}'" 0-255 "oc login (external env)" || true
            token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
        fi
    fi

    if [ -z "$token" ]; then
        rlDie "Failed to retrieve token."
        return 1
    fi

    rlLog "Auth success: api=${api_host_port:-<none>}, namespace=${namespace:-default}, token_prefix=${token:0:8}..."
    echo "API_HOST_PORT=${api_host_port}"
    echo "DEFAULT_TOKEN=${token}"
    echo "NAMESPACE=${namespace:-default}"
    return 0
}

# --- MAIN TEST ----------------------------------------------------------------
rlJournalStart

rlPhaseStartSetup
    OPERATOR_NAME=${OPERATOR_NAME:-tang-operator}
    rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
    rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

    TO_DAST_POD_COMPLETED=${TO_DAST_POD_COMPLETED:-300}
    TO_RAPIDAST=${TO_RAPIDAST:-30}

    if ! command -v helm &>/dev/null; then
        ARCH=$(case "$(uname -m)" in x86_64) echo amd64 ;; aarch64) echo arm64 ;; *) uname -m ;; esac)
        OS=$(uname | tr '[:upper:]' '[:lower:]')
        LATEST_RELEASE_TAG=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
        rlRun "curl -LO https://get.helm.sh/helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz" 0 "Download helm"
        rlRun "tar -xzf helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz" 0 "Unpack helm"
        rlRun "mv ${OS}-${ARCH}/helm /usr/local/bin/helm" 0 "Move helm to /usr/local/bin"
    fi
rlPhaseEnd

############# DAST TESTS ##############
rlPhaseStartTest "Dynamic Application Security Testing"

    # Adjust ephemeral kubeconfig if needed
    if [ -z "${KUBECONFIG}" ] && [ -d "/credentials" ]; then
        KUBECONFIG_FILE=$(find "/credentials" -name "cluster-*-kubeconfig" | head -n 1)
        [ -n "${KUBECONFIG_FILE}" ] && export KUBECONFIG="${KUBECONFIG_FILE}" && rlLog "Exported ephemeral kubeconfig ${KUBECONFIG}"
    fi

    # 1 - Log helm version
    rlRun "helm version" 0 "Helm version"

    # 2 - clone rapidast repo
    tmpdir=$(mktemp -d)
    trap "rm -rf '${tmpdir}'" EXIT
    rlRun "pushd ${tmpdir} >/dev/null && git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || true; popd >/dev/null" 0 "Clone Rapidast repo"
    pushd "${tmpdir}/rapidast" >/dev/null || rlDie "Cannot enter rapidast dir"

    # 3 - download configuration file template
    if [ -z "${KONFLUX}" ]; then
        rlRun "curl -sSfL -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml" 0 "Fetch tang_operator.yaml template (latchset)"
    else
        rlRun "curl -sSfL -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml" 0 "Fetch tang_operator.yaml template (openshift)"
    fi

    # 4 - determine auth & API server
    eval "$(ocpopGetAuth)" || rlDie "ocpopGetAuth failed"
    API_HOST_PORT="${API_HOST_PORT:-${API_HOST_PORT}}"
    DEFAULT_TOKEN="${DEFAULT_TOKEN:-${DEFAULT_TOKEN}}"
    OPERATOR_NS="${OPERATOR_NAMESPACE:-${NAMESPACE:-default}}"
    rlLog "API=${API_HOST_PORT:-<none>} | NS=${OPERATOR_NS} | Token prefix=${DEFAULT_TOKEN:0:6}..."
    rlAssertNotEquals "API_HOST_PORT must not be empty" "${API_HOST_PORT}" ""
    rlAssertNotEquals "DEFAULT_TOKEN must not be empty" "${DEFAULT_TOKEN}" ""

    # Replace placeholders in YAML (using sed directly)
    sed -i s@API_HOST_PORT_HERE@"${API_HOST_PORT}"@g tang_operator.yaml
    sed -i s@AUTH_TOKEN_HERE@"${DEFAULT_TOKEN}"@g tang_operator.yaml
    sed -i s@OPERATOR_NAMESPACE_HERE@"${OPERATOR_NS}"@g tang_operator.yaml
    grep -q "HERE" tang_operator.yaml && rlDie "Template placeholders not replaced!"

    # 5 - adapt helm chart
    pushd rapidast || rlDie "Cannot enter rapidast root"
    sed -i s@"kubectl --kubeconfig=./kubeconfig "@"${OC_CLIENT} "@g helm/results.sh
    sed -i s@"secContext: '{}'"@"secContext: '{\"privileged\": true}'"@ helm/chart/values.yaml
    sed -i s@'tag: "latest"'@'tag: "2.8.0"'@g helm/chart/values.yaml

    # 6 - install rapidast
    helm uninstall rapidast --namespace default || true
    rlRun -c "helm install rapidast ./helm/chart/ --set-file rapidastConfig=${tmpdir}/tang_operator.yaml 2>/dev/null" 0 "Installing rapidast helm chart"
    pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "default" "${TO_RAPIDAST}" 1)
    rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} default ${pod_name}" 0 "Checking POD ${pod_name} in Completed state [Timeout=${TO_DAST_POD_COMPLETED} secs.]"

    # 7 - extract results
    rlRun -c "bash ./helm/results.sh 2>/dev/null" 0 "Extracting DAST results"

    # 8 - cleanup
    helm uninstall rapidast --namespace default || true
    oc delete ns default --ignore-not-found || true
    popd >/dev/null || true
    popd >/dev/null || true

rlPhaseEnd
############# /DAST TESTS #############

rlJournalPrintText
rlJournalEnd