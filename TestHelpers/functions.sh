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
TANG_FUNCTION_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TEST_NAMESPACE_PATH="${TANG_FUNCTION_DIR}/reg_test/all_test_namespace"
TEST_NAMESPACE_FILE_NAME="daemons_v1alpha1_namespace.yaml"
TEST_NAMESPACE_FILE="${TEST_NAMESPACE_PATH}/${TEST_NAMESPACE_FILE_NAME}"
TEST_NAMESPACE=$(grep -i 'name:' "${TEST_NAMESPACE_FILE}" | awk -F ':' '{print $2}' | tr -d ' ')
TEST_PVSC_PATH="${TANG_FUNCTION_DIR}/reg_test/all_test_namespace"
TEST_PV_FILE_NAME="daemons_v1alpha1_pv.yaml"
TEST_PV_FILE="${TEST_PVSC_PATH}/${TEST_PV_FILE_NAME}"
TEST_SC_FILE_NAME="daemons_v1alpha1_storageclass.yaml"
TEST_SC_FILE="${TEST_PVSC_PATH}/${TEST_SC_FILE_NAME}"
test -z "${TO_POD_START}" && TO_POD_START=300 #seconds
test -z "${TO_POD_STOP}" && TO_POD_STOP=300 #seconds
test -z "${TO_SERVICE_START}" && TO_SERVICE_START=300 #seconds
test -z "${TO_SERVICE_STOP}" && TO_SERVICE_STOP=300 #seconds
test -z "${TO_ALL_POD_CONTROLLER_TERMINATE}" && TO_ALL_POD_CONTROLLER_TERMINATE=60 #seconds

if [ -d /etc/profile.d/upstream_operator_init.sh ]; then
    sh /etc/profile.d/upstream_operator_init.sh
fi

TO_KEY_ROTATION=10 #seconds
[ -n "$TANG_IMAGE" ] || TANG_IMAGE="registry.redhat.io/rhel9/tang"

if [ -z "${OPERATOR_NAME}" ];
then
    OPERATOR_NAME=tang-operator
fi
test -z "${DISABLE_BUNDLE_INSTALL_TESTS}" && DISABLE_BUNDLE_INSTALL_TESTS="0"
test -z "${DISABLE_BUNDLE_UNINSTALL_TESTS}" && DISABLE_BUNDLE_UNINSTALL_TESTS="0"
test -z "${IMAGE_VERSION}" && IMAGE_VERSION="quay.io/sec-eng-special/${OPERATOR_NAME}-bundle:${VERSION}"
test -z "${CONTAINER_MGR}" && CONTAINER_MGR="podman"

checkActiveKeysAmount() {
    local expected=$1
    local iterations=$2
    local namespace=$3
    local counter
    counter=0
    while [ ${counter} -lt ${iterations} ];
    do
        ACTIVE_KEYS_AMOUNT=$("${OC_CLIENT}" -n "${namespace}" get tangserver -o json | jq '.items[0].status.activeKeys | length')
        ocpopLogVerbose "ACTIVE KEYS AMOUNT:${ACTIVE_KEYS_AMOUNT} EXPECTED:${expected} COUNTER:${counter}/${iterations}"
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
        ocpopLogVerbose "HIDDEN KEYS AMOUNT:${HIDDEN_KEYS_AMOUNT} EXPECTED:${expected} COUNTER:${counter}/${iterations}"
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

checkKeyRotation() {
    local ip=$1
    local port=$2
    local namespace=$3
    local file1
    file1=$(mktemp)
    local file2
    file2=$(mktemp)
    dumpKeyAdv "${ip}" "${port}" "${file1}"
    rlRun "${TANG_FUNCTION_DIR}/reg_test/func_test/key_rotation/rotate_keys.sh ${namespace} ${OC_CLIENT}" 0 "Rotating keys"
    rlLog "Waiting:${TO_KEY_ROTATION} secs. for keys to rotate"
    sleep "${TO_KEY_ROTATION}"
    dumpKeyAdv "${ip}" "${port}" "${file2}"
    ocpopLogVerbose "Comparing files:${file1} and ${file2}"
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
    get_command1="curl ${url} --connect-timeout ${TO_CURL_CONNECTION} -o ${file} 1>/dev/null 2>/dev/null"
    ocpopLogVerbose "DUMP_KEY_ADV_COMMAND:[${get_command1}]"
    ${get_command1}
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

analyzeVersion() {
    ocpopLogVerbose "DETECTING MALWARE ON VERSION:[${1}]"
    local TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
    TMPDIR="${__INTERNAL_ocpopTmpDir}/tang_malware_detection_$TIMESTAMP"
    rlRun "mkdir -p $TMPDIR && chmod 777 $TMPDIR"

    "${CONTAINER_MGR}" pull "${1}"
    user=$(whoami | tr -d ' ' | awk '{print $1}')
    if [ "${user}" == "root" ]; then
        freshclam
        dir_mount=$(sh "$TANG_FUNCTION_DIR"/scripts/mount_image.sh -v "${1}" -c "${CONTAINER_MGR}")
    else
        dir_mount=$("${CONTAINER_MGR}" unshare sh "$TANG_FUNCTION_DIR"/scripts/mount_image.sh -v "${1}" -c "${CONTAINER_MGR}")
    fi
    rlAssertEquals "Checking image could be mounted appropriately" "$?" "0"
    analyzed_dir=$(echo "${dir_mount}" | sed -e 's@/merged@@g')
    ocpopLogVerbose "Analyzing directory:[${analyzed_dir}]"
    ocpopCommandVerbose "tree ${analyzed_dir}"
    prefix=$(echo "${1}" | tr ':' '_' | awk -F "/" '{print $NF}')
    rlRun "clamscan -o --recursive --infected ${analyzed_dir} --log ${TMPDIR}/${prefix}_malware.log" 0 "Checking for malware, logfile:${TMPDIR}/${prefix}_malware.log"
    infected_files=$(grep -i "Infected Files:" "${TMPDIR}/${prefix}_malware.log" | awk -F ":" '{print $2}' | tr -d ' ')
    rlAssertEquals "Checking no infected files" "${infected_files}" "0"
    if [ "${infected_files}" != "0" ]; then
        rlLogWarning "${infected_files} Infected Files Detected!"
        rlLogWarning "Please, review Malware Detection log file: ${TMPDIR}/${prefix}_malware.log"
    fi
    if [ "${user}" == "root" ]; then
        sh "$TANG_FUNCTION_DIR"/scripts/umount_image.sh -v "${1}" -c "${CONTAINER_MGR}"
    else
        "${CONTAINER_MGR}" unshare sh "$TANG_FUNCTION_DIR"/scripts/umount_image.sh -v "${1}" -c "${CONTAINER_MGR}"
    fi
    rlAssertEquals "Checking image could be umounted appropriately" "$?" "0"
}

useUpstreamImages(){
    for yaml_file in `find ${TANG_FUNCTION_DIR}/reg_test* \( -iname "*.yaml" -o -iname "*.sh" \) -type f -print`
    do
        sed -i "s~\"registry.redhat.io/rhel9/tang\"~\"${TANG_IMAGE}\"~g" $yaml_file
    done
}

checkKonflux() {
    pushd ${TANG_FUNCTION_DIR}; rm -v reg_test; test -z "${KONFLUX}" && ln -s reg_test_ori reg_test || ln -s reg_test_openshift_konflux reg_test; popd
}

cleanKonflux() {
    pushd ${TANG_FUNCTION_DIR}; git restore reg_test || : ; popd
}
