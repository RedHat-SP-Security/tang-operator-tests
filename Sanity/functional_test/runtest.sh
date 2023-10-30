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
    ########### FUNCTIONAL TESTS ##########
    rlPhaseStartTest "Unique deployment functional test"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Creating unique deployment"
        rlRun "checkPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        service_name=$(getServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service_ip=$(getServiceIp "${service_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service_port=$(getServicePort "${service_name}" "${TEST_NAMESPACE}")
        rlRun "checkServiceUp ${service_ip} ${service_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service_ip}] UP"
        rlRun "serviceAdv ${service_ip} ${service_port}" 0 "Checking Service Advertisement [IP/HOST:${service_ip} PORT:${service_port}]"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Deleting unique deployment"
        rlRun "checkPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "checkServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Unique deployment functional test (with clevis encryption/decryption)"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Creating unique deployment"
        rlRun "checkPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        service_name=$(getServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service_ip=$(getServiceIp "${service_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service_port=$(getServicePort "${service_name}" "${TEST_NAMESPACE}")
        rlRun "checkServiceUp ${service_ip} ${service_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service_ip}] UP"
        rlRun "serviceAdv ${service_ip} ${service_port}" 0 "Checking Service Advertisement [IP/HOST:${service_ip} PORT:${service_port}]"

        tmpdir=$(mktemp -d)
        rlRun "echo \"${TOP_SECRET_WORDS}\" | clevis encrypt tang '{\"url\":\"http://${service_ip}:${service_port}\"}' -y > ${tmpdir}/test_secret_words.jwe"
        decrypted=$(clevis decrypt < "${tmpdir}/test_secret_words.jwe")
        rlAssertEquals "Checking clevis decryption worked properly" "${decrypted}" "${TOP_SECRET_WORDS}"

        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Deleting unique deployment"
        rlRun "checkPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "checkServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Multiple deployment functional test"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/func_test/multiple_deployment_test/" 0 "Creating multiple deployment"
        rlRun "checkPodAmount 2 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 2 PODs are started [Timeout=${TO_POD_START} secs.]"
        pod1_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 1)
        pod2_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 2)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkServiceAmount 2 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 2 Services are started [Timeout=${TO_SERVICE_START} secs.]"
        service1_name=$(getServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service1_ip=$(getServiceIp "${service1_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service1_port=$(getServicePort "${service1_name}" "${TEST_NAMESPACE}")
        service2_name=$(getServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 2)
        service2_ip=$(getServiceIp "${service2_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service2_port=$(getServicePort "${service2_name}" "${TEST_NAMESPACE}")
        rlRun "checkServiceUp ${service1_ip} ${service1_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service1_ip}] UP"
        rlRun "checkServiceUp ${service2_ip} ${service2_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service2_ip}] UP"
        rlRun "serviceAdvCompare ${service1_ip} ${service1_port} ${service2_ip} ${service2_port}" 0 \
              "Checking Services Advertisement [IP1/HOST1:${service1_ip} PORT1:${service1_port}][IP2/HOST2:${service2_ip} PORT2:${service2_port}]"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/func_test/multiple_deployment_test/" 0 "Deleting multiple deployment"
        rlRun "checkPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "checkServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Key rotation functional test"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/func_test/key_rotation/" 0 "Creating key rotation deployment"
        rlRun "checkPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 PODs is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        service_name=$(getServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service_ip=$(getServiceIp "${service_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service_port=$(getServicePort "${service_name}" "${TEST_NAMESPACE}")
        rlRun "checkServiceUp ${service_ip} ${service_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service_ip}] UP"
        rlRun "checkKeyRotation ${service_ip} ${service_port} ${TEST_NAMESPACE}" 0\
              "Checking Key Rotation [IP/HOST:${service_ip} PORT:${service_port}]"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/func_test/key_rotation/" 0 "Deleting key rotation deployment"
        rlRun "checkPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "checkServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd
    ########### /FUNCTIONAL TESTS #########

rlJournalPrintText
rlJournalEnd
