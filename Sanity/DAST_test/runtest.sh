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

        # Provide some debug info about the credentials mount
        rlRun "ls -la /credentials || true" 0 "List /credentials for debug"

        oc_cmd+=("--kubeconfig=${KUBECONFIG}")

        # read server & namespace from kubeconfig
        api_host_port=$("${oc_cmd[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
        namespace=$("${oc_cmd[@]}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)

        rlLog "Ephemeral kubeconfig reports: api=${api_host_port:-<none>}, ns=${namespace}"

        # Try to get token using the kubeconfig (whoami -t), retry a few times
        local try=0
        for try in 1 2 3 4 5; do
            token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            rlLog "whoami -t attempt ${try}, token length=${#token}"
            [ -n "$token" ] && break
            sleep 2
        done

        # If token is still missing, try logging in using /credentials username/password files
        if [ -z "$token" ]; then
            if ls /credentials/*-password >/dev/null 2>&1; then
                local user pass
                user=$(head -n1 /credentials/*-username 2>/dev/null || echo "admin")
                pass=$(< /credentials/*-password)
                rlLog "Attempting oc login with username/password (user=${user})"
                # retry oc login a small number of times
                for try in 1 2 3; do
                    rlRun "${oc_bin} login -u ${user} -p '${pass}' --server='${api_host_port}' --kubeconfig='${KUBECONFIG}'" 0-255 "oc login attempt ${try} (ephemeral creds)" || true
                    token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
                    rlLog "Post-login whoami -t attempt ${try}, token length=${#token}"
                    [ -n "$token" ] && break
                    sleep 2
                done
            elif [ -n "${OCP_TOKEN}" ]; then
                rlLog "Attempting oc login with provided OCP_TOKEN"
                rlRun "${oc_bin} login --token='${OCP_TOKEN}' --server='${api_host_port}' --kubeconfig='${KUBECONFIG}'" 0-255 "oc login with OCP_TOKEN" || true
                token=$("${oc_cmd[@]}" whoami -t 2>/dev/null || true)
            fi
        fi

    # --- Case B: Running inside a pod with a service account token (in-cluster) ---
    elif [ -s /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        namespace=$(< /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || echo default)
        api_host_port="https://${KUBERNETES_SERVICE_HOST:-<unknown>}:${KUBERNETES_SERVICE_PORT:-<unknown>}"
        token=$(< /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || true)
        rlLog "Detected in-cluster environment (service account). namespace=${namespace}"

    # --- Case C: External environment / already-logged-in oc client (CRC, dev) ---
    else
        rlLog "Assuming external cluster (oc client present / already logged in)"
        api_host_port=$("${oc_bin}" whoami --show-server 2>/dev/null | tr -d ' ' || true)
        namespace=$("${oc_bin}" config view --minify -o jsonpath='{..namespace}' 2>/dev/null || echo default)
        token=$("${oc_bin}" whoami -t 2>/dev/null || true)

        # If no token and OCP_TOKEN is available, try login
        if [ -z "${token}" ] && [ -n "${OCP_TOKEN}" ]; then
            rlLog "No local token; attempting login with OCP_TOKEN"
            rlRun "${oc_bin} login --token='${OCP_TOKEN}' --server='${api_host_port}'" 0-255 "oc login with OCP_TOKEN (external env)" || true
            token=$("${oc_bin}" whoami -t 2>/dev/null || true)
        fi
    fi

    # --- Final fallback: try to extract token from service account secret ---
    if [ -z "$token" ]; then
        rlLogWarning "Primary auth failed; trying SA secret fallback (sa=${sa_name}, ns=${namespace})"
        # Use oc_cmd (which may contain --kubeconfig if ephemeral) to fetch SA secrets
        local secret_name
        secret_name=$("${oc_cmd[@]}" get sa "${sa_name}" -n "${namespace}" -o jsonpath='{.secrets[0].name}' 2>/dev/null || true)
        rlLog "Found SA secret name: ${secret_name:-<none>}"
        if [ -n "${secret_name}" ]; then
            token=$("${oc_cmd[@]}" get secret -n "${namespace}" "${secret_name}" -o json 2>/dev/null \
                | jq -r '.data.token' 2>/dev/null | base64 -d 2>/dev/null || true)
            rlLog "Retrieved token from SA secret, length=${#token}"
        fi
    fi

    # If still no token -> fatal
    if [ -z "$token" ]; then
        rlLogWarning "Failed to retrieve token via all methods"
        rlDie "Failed to retrieve token."
    fi

    # Output values for caller (short token prefix only in log)
    rlLog "Auth success: api=${api_host_port:-<none>}, namespace=${namespace:-default}, token_prefix=${token:0:8}..."
    echo "API_HOST_PORT=${api_host_port}"
    echo "DEFAULT_TOKEN=${token}"
    echo "NAMESPACE=${namespace:-default}"
}

# oc-safe-sed: perform a sed replace but ensure quoting is safe.
ocpop_sed_inplace() {
    local find="$1"
    local replace="$2"
    local file="$3"
    # Use perl for safer in-place substitution with arbitrary content
    perl -0777 -pe "s/$find/$replace/gms" -i -- "${file}"
}


# --- MAIN TEST ----------------------------------------------------------------
rlJournalStart

rlPhaseStartSetup
    if [ -z "${OPERATOR_NAME}" ]; then
        OPERATOR_NAME=tang-operator
    fi

    rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
    rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"

    TO_DAST_POD_COMPLETED=${TO_DAST_POD_COMPLETED:-300}   # seconds (DAST job)
    TO_RAPIDAST=${TO_RAPIDAST:-30}                     # seconds to wait for Rapidast pod to appear

    # Ensure helm present (download it if not)
    if ! command -v helm &>/dev/null; then
        ARCH=$(
            case "$(uname -m)" in
                x86_64)  echo amd64 ;;
                aarch64) echo arm64 ;;
                *)       uname -m ;;
            esac
        )
        OS=$(uname | tr '[:upper:]' '[:lower:]')
        LATEST_RELEASE_TAG=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name')
        rlRun "curl -LO https://get.helm.sh/helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz" 0 "Download helm"
        rlRun "tar -xzf helm-${LATEST_RELEASE_TAG}-${OS}-${ARCH}.tar.gz" 0 "Unpack helm"
        rlRun "mv ${OS}-${ARCH}/helm /usr/local/bin/helm" 0 "Move helm to /usr/local/bin"
    fi
rlPhaseEnd

############# DAST TESTS ##############
rlPhaseStartTest "Dynamic Application Security Testing"
    # 1 - Log helm version
    rlRun "helm version" 0 "Helm version"

    # 2 - clone rapidast code (development branch)
    tmpdir=$(mktemp -d)
    rlRun "pushd ${tmpdir} >/dev/null && git clone https://github.com/RedHatProductSecurity/rapidast.git -b development || true; popd >/dev/null" 0 "Clone Rapidast repo"
    pushd "${tmpdir}/rapidast" >/dev/null || rlDie "Cannot enter rapidast dir"

    # 3 - download configuration file template
    if [ -z "${KONFLUX}" ]; then
        rlRun "curl -sSfL -o tang_operator.yaml https://raw.githubusercontent.com/latchset/tang-operator/main/tools/scan_tools/tang_operator_template.yaml" 0 "Fetch tang_operator.yaml template (latchset)"
    else
        rlRun "curl -sSfL -o tang_operator.yaml https://raw.githubusercontent.com/openshift/nbde-tang-server/main/tools/scan_tools/tang_operator_template.yaml" 0 "Fetch tang_operator.yaml template (openshift)"
    fi

    # 4 - determine auth & API server
    # ocpopGetAuth prints environment variables to stdout; eval them into shell variables
    eval "$(ocpopGetAuth)" || rlDie "ocpopGetAuth failed"
    # Use values returned by ocpopGetAuth
    API_HOST_PORT="${API_HOST_PORT:-${API_HOST_PORT}}"
    DEFAULT_TOKEN="${DEFAULT_TOKEN:-${DEFAULT_TOKEN}}"
    OPERATOR_NS="${OPERATOR_NAMESPACE:-${NAMESPACE:-default}}"
    rlLog "API=${API_HOST_PORT:-<none>} | NS=${OPERATOR_NS} | Token prefix=${DEFAULT_TOKEN:0:6}..."

    # Replace placeholders in YAML safely (use simple sed; values are not expected to contain newline)
    # Use perl substitution when values can contain slashes or quotes.
    # Escape @ used as delimiter.
    # Note: tang_operator.yaml is small; this is safe.
    ocpop_sed_inplace 'API_HOST_PORT_HERE' "${API_HOST_PORT}" tang_operator.yaml
    ocpop_sed_inplace 'AUTH_TOKEN_HERE' "${DEFAULT_TOKEN}" tang_operator.yaml
    ocpop_sed_inplace 'OPERATOR_NAMESPACE_HERE' "${OPERATOR_NS}" tang_operator.yaml

    # Check replacements
    if grep -q "HERE" tang_operator.yaml; then
        rlDie "Template placeholders not replaced!"
    fi

    # 5 - adapt helm chart
    # Replace any kubectl invocation in helm/results.sh with oc client if OC_CLIENT defined
    if [ -n "${OC_CLIENT}" ]; then
        rlRun "sed -i 's@kubectl --kubeconfig=./kubeconfig @${OC_CLIENT} @g' helm/results.sh" 0 "Adapt helm/results.sh to use OC_CLIENT"
    else
        rlRun "sed -i 's@kubectl --kubeconfig=./kubeconfig @oc @g' helm/results.sh" 0 "Adapt helm/results.sh to use oc"
    fi

    # Ensure privileged secContext and tag
    # Use perl-style safe replace helper
    ocpop_sed_inplace 'secContext:\s*\{\}' 'secContext: {"privileged": true}' helm/chart/values.yaml
    ocpop_sed_inplace 'tag:\s*"latest"' 'tag: "2.8.0"' helm/chart/values.yaml

    # 6 - install Rapidast (with retry)
    RAPIDAST_NS="${RAPIDAST_NS:-rapidast-test}"
    rlRun "helm uninstall rapidast --namespace ${RAPIDAST_NS} || true" 0 "Uninstall any previous rapidast (noop if none)"

    local helm_try=0
    local helm_ret=1
    for helm_try in 1 2 3; do
        rlRun "helm install rapidast ./helm/chart/ --namespace \"${RAPIDAST_NS}\" --create-namespace --set-file rapidastConfig=$(pwd)/tang_operator.yaml" 0-255 "helm install attempt ${helm_try}" || true
        helm_ret=$?
        if [ "$helm_ret" -eq 0 ]; then
            break
        fi
        rlLogWarning "helm install attempt ${helm_try} failed (rc=${helm_ret}), retrying..."
        sleep 3
    done
    [ "$helm_ret" -ne 0 ] && rlDie "helm install failed after ${helm_try} attempts"

    # 7 - Wait for the Rapidast pod to complete
    # find pod name with helper (honors namespace)
    pod_name=$(ocpopGetPodNameWithPartialName "rapidast" "${RAPIDAST_NS}" "${TO_RAPIDAST}" 1)
    rlAssertNotEquals "Rapidast pod must not be empty" "${pod_name}" ""
    rlRun "ocpopCheckPodState Completed ${TO_DAST_POD_COMPLETED} ${RAPIDAST_NS} ${pod_name}" 0 "Check Rapidast pod Completed"

    # 8 - extract results using helm/results.sh (the script now uses oc/OC_CLIENT)
    rlRun "bash ./helm/results.sh" 0 "Extracting DAST results via helm/results.sh"
    # results.sh should produce files under rapidast/tangservers/DAST*...

    # 9 - find report directory & file
    report_dir=$(ls -1d "${tmpdir}"/rapidast/tangservers/DAST*tangservers/ 2>/dev/null | head -1 | sed -e 's@/$@@g' || true)
    rlLog "REPORT DIR: ${report_dir:-<none>}"

    rlAssertNotEquals "Checking report_dir not empty" "${report_dir}" ""

    report_file=$(find "${report_dir}" -type f -name zap-report.json 2>/dev/null | head -1 || true)
    rlLog "REPORT FILE: ${report_file:-<none>}"

    [ -f "${report_file}" ] || rlDie "DAST report not found at expected location"

    # 10 - analyze report
    alerts=$(jq '.site[0].alerts | length' < "${report_file}")
    rlLog "Number of alerts: ${alerts}"
    if [ "${alerts}" -gt 0 ]; then
        for ((i=0; i<alerts; i++)); do
            risk=$(jq -r ".site[0].alerts[${i}].riskdesc" < "${report_file}" | awk '{print $1}')
            rlLog "Alert[${i}] -> ${risk}"
            rlAssertNotEquals "No High Risk alerts" "$risk" "High"
        done
    else
        rlLog "No alerts detected in report"
    fi

    # 11 - cleanup
    rlRun "helm uninstall rapidast --namespace ${RAPIDAST_NS} || true" 0 "Uninstall Rapidast helm release"
    rlRun "oc delete ns ${RAPIDAST_NS} --ignore-not-found || true" 0 "Delete Rapidast namespace (cleanup)"

    # leave rapidast dir and temp dir will be cleaned by pipeline if desired
    popd >/dev/null || true
    popd >/dev/null || true
rlPhaseEnd
############# /DAST TESTS #############

rlJournalPrintText
rlJournalEnd