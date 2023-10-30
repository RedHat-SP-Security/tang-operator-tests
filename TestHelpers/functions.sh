#!/bin/bash
## vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
## ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
##
##   runtest.sh of /CoreOS/tang-operator/Sanity
##   Description: Basic functionality tests of the tang operator
##   Author: Patrik Koncity <pkoncity@redhat.com>
##   Author: Sergio Arroutbi <sarroutb@redhat.com>
##
## ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
##
##   Copyright (c) 2023 Red Hat, Inc.
##
##   This program is free software: you can redistribute it and/or
##   modify it under the terms of the GNU General Public License as
##   published by the Free Software Foundation, either version 2 of
##   the License, or (at your option) any later version.
##
##   This program is distributed in the hope that it will be
##   useful, but WITHOUT ANY WARRANTY; without even the implied
##   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
##   PURPOSE.  See the GNU General Public License for more details.
##
##   You should have received a copy of the GNU General Public License
##   along with this program. If not, see http://www.gnu.org/licenses/.
##
## ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
### Global Test Variables
TO_BUNDLE="15m"
FUNCTION_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TEST_NAMESPACE_PATH="${FUNCTION_DIR}/reg_test/all_test_namespace"
TEST_NAMESPACE_FILE_NAME="daemons_v1alpha1_namespace.yaml"
TEST_NAMESPACE_FILE="${TEST_NAMESPACE_PATH}/${TEST_NAMESPACE_FILE_NAME}"
TEST_NAMESPACE=$(grep -i 'name:' "${TEST_NAMESPACE_FILE}" | awk -F ':' '{print $2}' | tr -d ' ')
TEST_PVSC_PATH="${FUNCTION_DIR}/reg_test/all_test_namespace"
TEST_PV_FILE_NAME="daemons_v1alpha1_pv.yaml"
TEST_PV_FILE="${TEST_PVSC_PATH}/${TEST_PV_FILE_NAME}"
TEST_SC_FILE_NAME="daemons_v1alpha1_storageclass.yaml"
TEST_SC_FILE="${TEST_PVSC_PATH}/${TEST_SC_FILE_NAME}"
EXECUTION_MODE=
TO_POD_START=120 #seconds
TO_POD_SCALEIN_WAIT=120 #seconds
TO_LEGACY_POD_RUNNING=120 #seconds
TO_DAST_POD_COMPLETED=240 #seconds (DAST lasts around 120 seconds)
TO_POD_STOP=5 #seconds
TO_POD_TERMINATE=120 #seconds
TO_POD_CONTROLLER_TERMINATE=180 #seconds (for controller to end must wait longer)
TO_SERVICE_START=120 #seconds
TO_SERVICE_STOP=120 #seconds
TO_EXTERNAL_IP=120 #seconds
TO_WGET_CONNECTION=10 #seconds
TO_ALL_POD_CONTROLLER_TERMINATE=120 #seconds
TO_KEY_ROTATION=1 #seconds
TO_ACTIVE_KEYS=60 #seconds
TO_HIDDEN_KEYS=60 #seconds
TO_SERVICE_UP=180 #seconds
ADV_PATH="adv"
OC_DEFAULT_CLIENT="kubectl"
TOP_SECRET_WORDS="top secret"
[ -n "$TANG_IMAGE" ] || TANG_IMAGE="registry.redhat.io/rhel9/tang"


test -z "${VERSION}" && VERSION="latest"
test -z "${DISABLE_BUNDLE_INSTALL_TESTS}" && DISABLE_BUNDLE_INSTALL_TESTS="0"
test -z "${DISABLE_BUNDLE_UNINSTALL_TESTS}" && DISABLE_BUNDLE_UNINSTALL_TESTS="0"
test -z "${IMAGE_VERSION}" && IMAGE_VERSION="quay.io/sec-eng-special/tang-operator-bundle:${VERSION}"
test -n "${DOWNSTREAM_IMAGE_VERSION}" && {
    test -z "${OPERATOR_NAMESPACE}" && OPERATOR_NAMESPACE="openshift-operators"
}
test -z "${OPERATOR_NAMESPACE}" && OPERATOR_NAMESPACE="default"
test -z "${CONTAINER_MGR}" && CONTAINER_MGR="podman"

### Required setup for script, installing required packages
if [ -z "${TEST_OC_CLIENT}" ];
then
    OC_CLIENT="${OC_DEFAULT_CLIENT}"
else
    OC_CLIENT="${TEST_OC_CLIENT}"
fi

if [ -z "${TEST_EXTERNAL_CLUSTER_MODE}" ];
then
    if [ -n "${TEST_CRC_MODE}" ];
    then
        EXECUTION_MODE="CRC"
    else
        EXECUTION_MODE="MINIKUBE"
    fi
else
        EXECUTION_MODE="CLUSTER"
fi

### Install required packages for script functions
PACKAGES=(git podman jq)
echo -e "\nInstall packages required by the script functions when missing."
rpm -q "${PACKAGES[@]}" || yum -y install "${PACKAGES[@]}"



### Functions

dumpVerbose() {
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
        rlLog "${1}"
    fi
}

commandVerbose() {
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
        $*
    fi
}

dumpDate() {
    rlLog "DATE:$(date)"
}

dumpInfo() {
    rlLog "HOSTNAME:$(hostname)"
    rlLog "RELEASE:$(cat /etc/redhat-release)"
    test -n "${DOWNSTREAM_IMAGE_VERSION}" && {
        rlLog "DOWNSTREAM_IMAGE_VERSION:${DOWNSTREAM_IMAGE_VERSION}"
    } || rlLog "IMAGE_VERSION:${IMAGE_VERSION}"
    rlLog "OPERATOR NAMESPACE:${OPERATOR_NAMESPACE}"
    rlLog "DISABLE_BUNDLE_INSTALL_TESTS:${DISABLE_BUNDLE_INSTALL_TESTS}"
    rlLog "OC_CLIENT:${OC_CLIENT}"
    rlLog "RUN_BUNDLE_PARAMS:${RUN_BUNDLE_PARAMS}"
    rlLog "EXECUTION_MODE:${EXECUTION_MODE}"
    rlLog "ID:$(id)"
    rlLog "WHOAMI:$(whoami)"
    rlLog "TANG_IMAGE:${TANG_IMAGE}"
    rlLog "vvvvvvvvv IP vvvvvvvvvv"
    ip a | grep 'inet '
    rlLog "^^^^^^^^^ IP ^^^^^^^^^^"
    #rlLog "vvvvvvvvv IP TABLES vvvvvvvvvv"
    #sudo iptables -L
    #rlLog "Flushing iptables"
    #sudo iptables -F
    #sudo iptables -L
    #rlLog "^^^^^^^^^ IP TABLES ^^^^^^^^^^"
}

minikubeInfo() {
    rlLog "MINIKUBE IP:$(minikube ip)"
    rlLog "vvvvvvvvvvvv MINIKUBE STATUS vvvvvvvvvvvv"
    minikube status
    rlLog "^^^^^^^^^^^^ MINIKUBE STATUS ^^^^^^^^^^^^"
    rlLog "vvvvvvvvvvvv MINIKUBE SERVICE LIST vvvvvvvvvvvv"
    minikube service list
    rlLog "^^^^^^^^^^^^ MINIKUBE SERVICE LIST ^^^^^^^^^^^^"
}


checkClusterStatus() {
    if [ "${EXECUTION_MODE}" == "CRC" ];
    then
        rlRun "crc status | grep OpenShift | awk -F ':' '{print $2}' | awk '{print $1}' | grep -i Running" 0 "Checking Code Ready Containers up and running"
    elif [ "${EXECUTION_MODE}" == "MINIKUBE" ];
    then
        rlRun "minikube status" 0 "Checking Minikube status"
    else
        if [ "${OC_CLIENT}" != "oc" ];
        then
            return 0
        fi
        rlRun "${OC_CLIENT} status" 0 "Checking cluster status"
    fi
    return $?
}

checkPodAmount() {
    local expected=$1
    local iterations=$2
    local namespace=$3
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
        POD_AMOUNT=$("${OC_CLIENT}" -n "${namespace}" get pods | grep -v "^NAME" -c)
        dumpVerbose "POD AMOUNT:${POD_AMOUNT} EXPECTED:${expected} COUNTER:${counter}/${iterations}"
        if [ ${POD_AMOUNT} -eq ${expected} ]; then
            return 0
        fi
        counter=$((counter+1))
        sleep 1
    done
    return 1
}

checkPodKilled() {
    local pod_name=$1
    local namespace=$2
    local iterations=$3
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
        if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ]; then
            "${OC_CLIENT}" -n "${namespace}" get pod "${pod_name}"
        else
            "${OC_CLIENT}" -n "${namespace}" get pod "${pod_name}" 2>/dev/null 1>/dev/null
        fi
        if [ $? -ne 0 ]; then
            return 0
        fi
        counter=$((counter+1))
        sleep 1
    done
    return 1
}

checkPodState() {
    local expected=$1
    local iterations=$2
    local namespace=$3
    local podname=$4
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
      pod_status=$("${OC_CLIENT}" -n "${namespace}" get pod "${podname}" | grep -v "^NAME" | awk '{print $3}')
      dumpVerbose "POD STATUS:${pod_status} EXPECTED:${expected} COUNTER:${counter}/${iterations}"
      if [ "${pod_status}" == "${expected}" ]; then
        return 0
      fi
      counter=$((counter+1))
      sleep 1
    done
    return 1
}

checkServiceAmount() {
    local expected=$1
    local iterations=$2
    local namespace=$3
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
        SERVICE_AMOUNT=$("${OC_CLIENT}" -n "${namespace}" get services | grep -v "^NAME" -c)
        dumpVerbose "SERVICE AMOUNT:${SERVICE_AMOUNT} EXPECTED:${expected} COUNTER:${counter}/${iterations}"
        if [ ${SERVICE_AMOUNT} -eq ${expected} ]; then
            return 0
        fi
        counter=$((counter+1))
        sleep 1
    done
    return 1
}

checkServiceUp() {
    local service_ip_host=$1
    local service_ip_port=$2
    local iterations=$3
    local counter
    local http_service="http://${service_ip_host}:${service_ip_port}/adv"
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
        if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ]; then
            wget -O /dev/null -o /dev/null --timeout=${TO_WGET_CONNECTION} ${http_service}
        else
            wget -O /dev/null -o /dev/null --timeout=${TO_WGET_CONNECTION} ${http_service} 2>/dev/null 1>/dev/null
        fi
        if [ $? -eq 0 ]; then
            return 0
        fi
        counter=$((counter+1))
        dumpVerbose "WAITING SERVICE:${http_service} UP, COUNTER:${counter}/${iterations}"
        sleep 1
    done
    return 1
}

checkActiveKeysAmount() {
    local expected=$1
    local iterations=$2
    local namespace=$3
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
        ACTIVE_KEYS_AMOUNT=$("${OC_CLIENT}" -n "${namespace}" get tangserver -o json | jq '.items[0].status.activeKeys | length')
        dumpVerbose "ACTIVE KEYS AMOUNT:${ACTIVE_KEYS_AMOUNT} EXPECTED:${expected} COUNTER:${counter}/${iterations}"
        if [ ${ACTIVE_KEYS_AMOUNT} -eq ${expected} ];
        then
            return 0
        fi
        counter=$((counter+1))
        sleep 1
    done
    rlLog "Active Keys Amount not as expected: Active Keys:${ACTIVE_KEYS_AMOUNT}, Expected:[${expected}]"
    return 1
}

checkHiddenKeysAmount() {
    local expected=$1
    local iterations=$2
    local namespace=$3
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
        HIDDEN_KEYS_AMOUNT=$("${OC_CLIENT}" -n "${namespace}" get tangserver -o json | jq '.items[0].status.hiddenKeys | length')
        dumpVerbose "HIDDEN KEYS AMOUNT:${HIDDEN_KEYS_AMOUNT} EXPECTED:${expected} COUNTER:${counter}/${iterations}"
        if [ ${HIDDEN_KEYS_AMOUNT} -eq ${expected} ];
        then
            return 0
        fi
        counter=$((counter+1))
        sleep 1
    done
    rlLog "Hidden Keys Amount not as expected: Hidden Keys:${HIDDEN_KEYS_AMOUNT}, Expected:[${expected}]"
    return 1
}

getPodNameWithPrefix() {
    local prefix=$1
    local namespace=$2
    local iterations=$3
    local tail_position=$4
    test -z "${tail_position}" && tail_position=1
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
      local pod_line
      pod_line=$("${OC_CLIENT}" -n "${namespace}" get pods | grep -v "^NAME" | grep "${prefix}" | tail -${tail_position} | head -1)
      dumpVerbose "POD LINE:[${pod_line}] POD PREFIX:[${prefix}] COUNTER:[${counter}/${iterations}]"
      if [ "${pod_line}" != "" ]; then
          echo "${pod_line}" | awk '{print $1}'
          dumpVerbose "FOUND POD name:[$(echo ${pod_line} | awk '{print $1}')] POD PREFIX:[${prefix}] COUNTER:[${counter}/${iterations}]"
          return 0
      else
          counter=$((counter+1))
          sleep 1
      fi
    done
    return 1
}

getServiceNameWithPrefix() {
    local prefix=$1
    local namespace=$2
    local iterations=$3
    local tail_position=$4
    test -z "${tail_position}" && tail_position=1
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
      local service_name
      service_name=$("${OC_CLIENT}" -n "${namespace}" get services | grep -v "^NAME" | grep "${prefix}" | tail -${tail_position} | head -1)
      dumpVerbose "SERVICE NAME:[${service_name}] COUNTER:[${counter}/${iterations}]"
      if [ "${service_name}" != "" ]; then
          dumpVerbose "FOUND SERVICE name:[$(echo ${service_name} | awk '{print $1}')] POD PREFIX:[${prefix}] COUNTER:[${counter}/${iterations}]"
          echo "${service_name}" | awk '{print $1}'
          return 0
      else
          counter=$((counter+1))
          sleep 1
      fi
    done
    return 1
}

getServiceIp() {
    local service_name=$1
    local namespace=$2
    local iterations=$3
    counter=0
    dumpVerbose "Getting SERVICE:[${service_name}](Namespace:[${namespace}]) IP/HOST ..."
    if [ ${EXECUTION_MODE} == "CRC" ];
    then
        local crc_service_ip
        crc_service_ip=$(crc ip)
        dumpVerbose "CRC MODE, SERVICE IP/HOST:[${crc_service_ip}]"
        echo "${crc_service_ip}"
        return 0
    elif [ ${EXECUTION_MODE} == "MINIKUBE" ];
    then
        local minikube_service_ip
        minikube_service_ip=$(minikube ip)
        dumpVerbose "MINIKUBE MODE, SERVICE IP/HOST:[${minikube_service_ip}]"
        echo "${minikube_service_ip}"
        return 0
    fi
    while [ ${counter} -lt ${iterations} ];
    do
        local service_ip
        service_ip=$("${OC_CLIENT}" -n "${namespace}" describe service "${service_name}" | grep -i "LoadBalancer Ingress:" | awk -F ':' '{print $2}' | tr -d ' ')
        dumpVerbose "SERVICE IP/HOST:[${service_ip}](Namespace:[${namespace}])"
        if [ -n "${service_ip}" ] && [ "${service_ip}" != "<pending>" ];
        then
            echo "${service_ip}"
            return 0
        else
            dumpVerbose "PENDING OR EMPTY IP/HOST:[${service_ip}], COUNTER[${counter}/${iterations}]"
        fi
        counter=$((counter+1))
        sleep 1
    done
    return 1
}

getServicePort() {
    local service_name=$1
    local namespace=$2
    local service_port
    dumpVerbose "Getting SERVICE:[${service_name}](Namespace:[${namespace}]) PORT ..."
    if [ ${EXECUTION_MODE} == "CLUSTER" ];
    then
        service_port=$("${OC_CLIENT}" -n "${namespace}" get service "${service_name}" | grep -v ^NAME | awk '{print $5}' | awk -F ':' '{print $1}')
    else
        service_port=$("${OC_CLIENT}" -n "${namespace}" get service "${service_name}" | grep -v ^NAME | awk '{print $5}' | awk -F ':' '{print $2}' | awk -F '/' '{print $1}')
    fi
    result=$?
    dumpVerbose "SERVICE PORT:[${service_port}](Namespace:[${namespace}])"
    echo "${service_port}"
    return ${result}
}

serviceAdv() {
    ip=$1
    port=$2
    URL="http://${ip}:${port}/${ADV_PATH}"
    local file
    file=$(mktemp)
    ### wget
    COMMAND="wget ${URL} --timeout=${TO_WGET_CONNECTION} -O ${file} -o /dev/null"
    dumpVerbose "CONNECTION_COMMAND:[${COMMAND}]"
    ${COMMAND}
    wget_res=$?
    dumpVerbose "WGET RESULT:$(cat ${file})"
    JSON_ADV=$(cat "${file}")
    dumpVerbose "CONNECTION_COMMAND:[${COMMAND}],RESULT:[${wget_res}],JSON_ADV:[${JSON_ADV}])"
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ]; then
        jq . -M -a < "${file}"
    else
        jq . -M -a < "${file}" 2>/dev/null
    fi
    jq_res=$?
    rm "${file}"
    return $((wget_res+jq_res))
}

checkKeyRotation() {
    local ip=$1
    local port=$2
    local namespace=$3
    local file1
    file1=$(mktemp)
    local file2
    file2=$(mktemp)
    dumpKeyAdv "${ip}" "${port}" "${file1}"
    rlRun "${FUNCTION_DIR}/reg_test/func_test/key_rotation/rotate_keys.sh ${namespace} ${OC_CLIENT}" 0 "Rotating keys"
    rlLog "Waiting:${TO_KEY_ROTATION} secs. for keys to rotate"
    sleep "${TO_KEY_ROTATION}"
    dumpKeyAdv "${ip}" "${port}" "${file2}"
    dumpVerbose "Comparing files:${file1} and ${file2}"
    rlAssertDiffer "${file1}" "${file2}"
    res=$?
    rm -f "${file1}" "${file2}"
    return ${res}
}

dumpKeyAdv() {
    local ip=$1
    local port=$2
    local file=$3
    test -z "${file}" && file="-"
    local url
    url="http://${ip}:${port}/${ADV_PATH}"
    local get_command1
    get_command1="wget ${url} --timeout=${TO_WGET_CONNECTION} -O ${file} -o /dev/null"
    dumpVerbose "DUMP_KEY_ADV_COMMAND:[${get_command1}]"
    ${get_command1}
}

serviceAdvCompare() {
    local ip=$1
    local port=$2
    local ip2=$3
    local port2=$4
    local url
    url="http://${ip}:${port}/${ADV_PATH}"
    local url2
    url2="http://${ip2}:${port2}/${ADV_PATH}"
    local jq_equal=1
    local file1
    local file2
    file1=$(mktemp)
    file2=$(mktemp)
    local jq_json_file1
    local jq_json_file2
    jq_json_file1=$(mktemp)
    jq_json_file2=$(mktemp)
    local command1
    command1="wget ${url} --timeout=${TO_WGET_CONNECTION} -O ${file1} -o /dev/null"
    local command2
    command2="wget ${url2} --timeout=${TO_WGET_CONNECTION} -O ${file2} -o /dev/null"
    dumpVerbose "CONNECTION_COMMAND:[${command1}]"
    dumpVerbose "CONNECTION_COMMAND:[${command2}]"
    ${command1}
    wget_res1=$?
    ${command2}
    wget_res2=$?
    dumpVerbose "CONNECTION_COMMAND:[${command1}],RESULT:[${wget_res1}],json_adv:[$(cat ${file1})]"
    dumpVerbose "CONNECTION_COMMAND:[${command2}],RESULT:[${wget_res2}],json_adv:[$(cat ${file2})]"
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ]; then
        jq . -M -a < "${file1}" 2>&1 | tee "${jq_json_file1}"
    else
        jq . -M -a < "${file1}" > "${jq_json_file1}"
    fi
    jq_res1=$?
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ]; then
        jq . -M -a < "${file2}" 2>&1 | tee "${jq_json_file2}"
    else
        jq . -M -a < "${file2}" > "${jq_json_file2}"
    fi
    jq_res2=$?
    rlAssertDiffer "${jq_json_file1}" "${jq_json_file2}"
    jq_equal=$?
    rm "${jq_json_file1}" "${jq_json_file2}"
    return $((wget_res1+wget_res2+jq_res1+jq_res2+jq_equal))
}

checkStatusRunningReplicas() {
    local counter
    counter=0
    local expected=$1
    local namespace=$2
    local iterations=$3
    while [ ${counter} -lt ${iterations} ];
    do
      local running
      running=$("${OC_CLIENT}" -n "${namespace}" get tangserver -o json | jq '.items[0].status.running | length')
      dumpVerbose "Status Running Replicas: Expected:[${expected}], Running:[${running}]"
      if [ ${expected} -eq ${running} ];
      then
          return 0
      fi
      counter=$((counter+1))
      sleep 1
    done
    return 1
}

checkStatusReadyReplicas() {
    local counter
    counter=0
    local expected=$1
    local namespace=$2
    local iterations=$3
    while [ ${counter} -lt ${iterations} ];
    do
      local ready
      ready=$("${OC_CLIENT}" -n "${namespace}" get tangserver -o json | jq '.items[0].status.ready | length')
      dumpVerbose "Status Ready Replicas: Expected:[${expected}], Ready:[${ready}]"
      if [ ${expected} -eq ${ready} ];
      then
          return 0
      fi
      counter=$((counter+1))
      sleep 1
    done
    return 1
}

uninstallDownstreamVersion() {
    pushd ${tmpdir}/tang-operator/tools/index_tools
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
        ./tang_uninstall_catalog.sh || err=1
    else
        ./tang_uninstall_catalog.sh 1>/dev/null 2>/dev/null || err=1
    fi
    popd || return 1
    return $?
}

installDownstreamVersion() {
    local err=0
    # Download required tools
    pushd ${tmpdir}
    # WARNING: if tang-operator is changed to OpenShift organization, change this
    git clone https://github.com/latchset/tang-operator
    pushd tang-operator/tools/index_tools
    local downstream_version=$(echo ${DOWNSTREAM_IMAGE_VERSION} | awk -F ':' '{print $2}')
    dumpVerbose "Installing Downstream version: ${DOWNSTREAM_IMAGE_VERSION} DOWNSTREAM_VERSION:[${downstream_version}]"
    rlLog "Indexing and installing catalog"
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
        DO_NOT_LOGIN="1" ./tang_index.sh "${DOWNSTREAM_IMAGE_VERSION}" "${downstream_version}" || err=1
        ./tang_install_catalog.sh || err=1
    else
        DO_NOT_LOGIN="1" ./tang_index.sh "${DOWNSTREAM_IMAGE_VERSION}" "${downstream_version}" 1>/dev/null 2>/dev/null || err=1
        ./tang_install_catalog.sh 1>/dev/null 2>/dev/null || err=1
    fi
    popd || return 1
    popd || return 1
    return $err
}

bundleStart() {
    if [ "${DISABLE_BUNDLE_INSTALL_TESTS}" == "1" ];
    then
      rlLog "User asked to not install/uninstall by using DISABLE_BUNDLE_INSTALL_TESTS=1"
      return 0
    fi
    if [ -n "${DOWNSTREAM_IMAGE_VERSION}" ];
    then
      installDownstreamVersion
      return $?
    fi
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
      rlRun "operator-sdk --verbose run bundle --timeout ${TO_BUNDLE} ${IMAGE_VERSION} ${RUN_BUNDLE_PARAMS} --namespace ${OPERATOR_NAMESPACE}"
    else
      rlRun "operator-sdk run bundle --timeout ${TO_BUNDLE} ${IMAGE_VERSION} ${RUN_BUNDLE_PARAMS} --namespace ${OPERATOR_NAMESPACE} 2>/dev/null"
    fi
    return $?
}

bundleInitialStop() {
    if [ "${DISABLE_BUNDLE_INSTALL_TESTS}" == "1" ];
    then
      rlLog "User asked to not install/uninstall by using DISABLE_BUNDLE_INSTALL_TESTS=1"
      return 0
    fi
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
        operator-sdk --verbose cleanup tang-operator --namespace ${OPERATOR_NAMESPACE}
    else
        operator-sdk cleanup tang-operator --namespace ${OPERATOR_NAMESPACE} 2>/dev/null
    fi
    if [ $? -eq 0 ];
    then
        checkPodAmount 0 ${TO_ALL_POD_CONTROLLER_TERMINATE} ${OPERATOR_NAMESPACE}
    fi
    return 0
}


bundleStop() {
    if [ "${DISABLE_BUNDLE_INSTALL_TESTS}" == "1" ];
    then
      rlLog "User asked to not install/uninstall by using DISABLE_BUNDLE_INSTALL_TESTS=1"
      return 0
    fi
    if [ "${DISABLE_BUNDLE_UNINSTALL_TESTS}" == "1" ];
    then
      rlLog "User asked to not uninstall by using DISABLE_BUNDLE_UNINSTALL_TESTS=1"
      return 0
    fi
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
        operator-sdk cleanup tang-operator --namespace ${OPERATOR_NAMESPACE}
    else
        operator-sdk cleanup tang-operator --namespace ${OPERATOR_NAMESPACE} 2>/dev/null
    fi
    if [ $? -eq 0 ];
    then
        checkPodAmount 0 ${TO_ALL_POD_CONTROLLER_TERMINATE} ${OPERATOR_NAMESPACE}
    fi
    return 0
}

getPodCpuRequest() {
    local pod_name=$1
    local namespace=$2
    dumpVerbose "Getting POD:[${pod_name}](Namespace:[${namespace}]) CPU Request ..."
    local cpu
    cpu=$("${OC_CLIENT}" -n "${namespace}" describe pod "${pod_name}" | grep -i Requests -A2 | grep 'cpu' | awk -F ":" '{print $2}' | tr -d ' ' | tr -d "[A-Z,a-z]")
    dumpVerbose "CPU REQUEST COMMAND:["${OC_CLIENT}" -n "${namespace}" describe pod ${pod_name} | grep -i Requests -A2 | grep 'cpu' | awk -F ':' '{print $2}' | tr -d ' ' | tr -d \"[A-Z,a-z]\""
    dumpVerbose "POD:[${pod_name}](Namespace:[${namespace}]) CPU Request:[${cpu}]"
    echo "${cpu}"
}

getPodMemRequest() {
    local pod_name=$1
    local namespace=$2
    dumpVerbose "Getting POD:[${pod_name}](Namespace:[${namespace}]) MEM Request ..."
    local mem
    mem=$("${OC_CLIENT}" -n "${namespace}" describe pod "${pod_name}" | grep -i Requests -A2 | grep 'memory' | awk -F ":" '{print $2}' | tr -d ' ')
    local unit
    unit="${mem: -1}"
    local mult
    mult=1
    case "${unit}" in
        K|k)
            mult=1024
            ;;
        M|m)
            mult=$((1024*1024))
            ;;
        G|g)
            mult=$((1024*1024*1024))
            ;;
        T|t)
            mult=$((1024*1024*1024*1024))
            ;;
        *)
            mult=1
            ;;
    esac
    dumpVerbose "MEM REQUEST COMMAND:["${OC_CLIENT}" -n "${namespace}" describe pod ${pod_name} | grep -i Requests -A2 | grep 'memory' | awk -F ':' '{print $2}' | tr -d ' '"
    dumpVerbose "POD:[${pod_name}](Namespace:[${namespace}]) MEM Request With Unit:[${mem}] Unit:[${unit}] Mult:[${mult}]"
    local mem_no_unit
    mem_no_unit="${mem/${unit}/}"
    local mult_mem
    mult_mem=$((mem_no_unit*mult))
    dumpVerbose "POD:[${pod_name}](Namespace:[${namespace}]) MEM Request:[${mult_mem}] Unit:[${unit}] Mult:[${mult}]"
    echo "${mult_mem}"
}

dumpOpenShiftClientStatus() {
    if [ "${EXECUTION_MODE}" == "MINIKUBE" ];
    then
	return 0
    fi
    if [ "${OC_CLIENT}" != "oc" ];
    then
	return 0
    fi
    if [ "${V}" == "1" ] || [ "${VERBOSE}" == "1" ];
    then
        "${OC_CLIENT}" status
    else
        "${OC_CLIENT}" status 2>/dev/null 1>/dev/null
    fi
    return 0
}

installScPv() {
    if [ ${EXECUTION_MODE} == "CLUSTER" ];
    then
	for sc in $("${OC_CLIENT}" get storageclasses.storage.k8s.io  | grep "\(${OPERATOR_NAMESPACE}\)" | awk '{print $1}' );
        do
            "${OC_CLIENT}" patch storageclass "${sc}" -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "false"}}}'
	done
	rlLog "After Storage Class deletion:"
        "${OC_CLIENT}" get storageclasses.storage.k8s.io
        "${OC_CLIENT}" apply -f "${TEST_SC_FILE}"
        "${OC_CLIENT}" apply -f "${TEST_PV_FILE}"
	rlLog "After Storage Class application:"
        "${OC_CLIENT}" get storageclasses.storage.k8s.io
    fi
    return 0
}

getVersion() {
    if [ -n "${DOWNSTREAM_IMAGE_VERSION}" ];
    then
        echo "${DOWNSTREAM_IMAGE_VERSION}"
    else
        echo "${IMAGE_VERSION}"
    fi
}

analyzeVersion() {
    dumpVerbose "DETECTING MALWARE ON VERSION:[${1}]"
    "${CONTAINER_MGR}" pull "${1}"
    user=$(whoami | tr -d ' ' | awk '{print $1}')
    local tmpdir=$( mktemp -d )
    if [ "${user}" == "root" ]; then
        freshclam
        dir_mount=$(sh "$FUNCTION_DIR"/scripts/mount_image.sh -v "${1}" -c "${CONTAINER_MGR}")
    else
        dir_mount=$("${CONTAINER_MGR}" unshare sh "$FUNCTION_DIR"/scripts/mount_image.sh -v "${1}" -c "${CONTAINER_MGR}")
    fi
    rlAssertEquals "Checking image could be mounted appropriately" "$?" "0"
    analyzed_dir=$(echo "${dir_mount}" | sed -e 's@/merged@@g')
    dumpVerbose "Analyzing directory:[${analyzed_dir}]"
    commandVerbose "tree ${analyzed_dir}"
    prefix=$(echo "${1}" | tr ':' '_' | awk -F "/" '{print $NF}')
    rlRun "clamscan -o --recursive --infected ${analyzed_dir} --log ${tmpdir}/${prefix}_malware.log" 0 "Checking for malware, logfile:${tmpdir}/${prefix}_malware.log"
    infected_files=$(grep -i "Infected Files:" "${tmpdir}/${prefix}_malware.log" | awk -F ":" '{print $2}' | tr -d ' ')
    rlAssertEquals "Checking no infected files" "${infected_files}" "0"
    if [ "${infected_files}" != "0" ]; then
        rlLogWarning "${infected_files} Infected Files Detected!"
        rlLogWarning "Please, review Malware Detection log file: ${tmpdir}/${prefix}_malware.log"
    fi
    if [ "${user}" == "root" ]; then
        sh "$FUNCTION_DIR"/scripts/umount_image.sh -v "${1}" -c "${CONTAINER_MGR}"
    else
        "${CONTAINER_MGR}" unshare sh "$FUNCTION_DIR"/scripts/umount_image.sh -v "${1}" -c "${CONTAINER_MGR}"
    fi
    rlAssertEquals "Checking image could be umounted appropriately" "$?" "0"
}

useUpstreamImages(){
    for yaml_file in `find ${FUNCTION_DIR}/reg_test \( -iname "*.yaml" -o -iname "*.sh" \) -type f -print`
    do
        sed -i "s~\"registry.redhat.io/rhel9/tang\"~\"${TANG_IMAGE}\"~g" $yaml_file
    done
}
