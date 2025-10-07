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
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        TO_SERVICE_UP=300 #seconds
        TO_EXTERNAL_IP=240 #seconds

        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Creating unique deployment"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        service_name=$(ocpopGetServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service_ip=$(ocpopGetServiceIp "${service_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service_port=$(ocpopGetServicePort "${service_name}" "${TEST_NAMESPACE}")
        rlRun "ocpopCheckServiceUp ${service_ip} ${service_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service_ip}] UP"
        rlRun "ocpopServiceAdv ${service_ip} ${service_port}" 0 "Checking Service Advertisement [IP/HOST:${service_ip} PORT:${service_port}]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Deleting unique deployment"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Unique deployment functional test (with clevis encryption/decryption)"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Creating unique deployment"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        service_name=$(ocpopGetServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service_ip=$(ocpopGetServiceIp "${service_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service_port=$(ocpopGetServicePort "${service_name}" "${TEST_NAMESPACE}")
        rlRun "ocpopCheckServiceUp ${service_ip} ${service_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service_ip}] UP"
        rlRun "ocpopServiceAdv ${service_ip} ${service_port}" 0 "Checking Service Advertisement [IP/HOST:${service_ip} PORT:${service_port}]"

        TOP_SECRET_WORDS="top secret"
        tmpdir=$(mktemp -d)
        rlRun "echo \"${TOP_SECRET_WORDS}\" | clevis encrypt tang '{\"url\":\"http://${service_ip}:${service_port}\"}' -y > ${tmpdir}/test_secret_words.jwe"
        decrypted=$(clevis decrypt < "${tmpdir}/test_secret_words.jwe")
        rlAssertEquals "Checking clevis decryption worked properly" "${decrypted}" "${TOP_SECRET_WORDS}"

        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/func_test/unique_deployment_test/" 0 "Deleting unique deployment"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Multiple deployment functional test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/func_test/multiple_deployment_test/" 0 "Creating multiple deployment"
        rlRun "ocpopCheckPodAmount 2 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 2 PODs are started [Timeout=${TO_POD_START} secs.]"
        pod1_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 2)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 2 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 2 Services are started [Timeout=${TO_SERVICE_START} secs.]"
        service1_name=$(ocpopGetServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service1_ip=$(ocpopGetServiceIp "${service1_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service1_port=$(ocpopGetServicePort "${service1_name}" "${TEST_NAMESPACE}")
        service2_name=$(ocpopGetServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 2)
        service2_ip=$(ocpopGetServiceIp "${service2_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service2_port=$(ocpopGetServicePort "${service2_name}" "${TEST_NAMESPACE}")
        rlRun "ocpopCheckServiceUp ${service1_ip} ${service1_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service1_ip}] UP"
        rlRun "ocpopCheckServiceUp ${service2_ip} ${service2_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service2_ip}] UP"
        rlRun "ocpopServiceAdvCompare ${service1_ip} ${service1_port} ${service2_ip} ${service2_port}" 0 \
              "Checking Services Advertisement [IP1/HOST1:${service1_ip} PORT1:${service1_port}][IP2/HOST2:${service2_ip} PORT2:${service2_port}]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/func_test/multiple_deployment_test/" 0 "Deleting multiple deployment"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Key rotation functional test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/func_test/key_rotation/" 0 "Creating key rotation deployment"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 PODs is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        service_name=$(ocpopGetServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service_ip=$(ocpopGetServiceIp "${service_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        service_port=$(ocpopGetServicePort "${service_name}" "${TEST_NAMESPACE}")
        rlRun "ocpopCheckServiceUp ${service_ip} ${service_port} ${TO_SERVICE_UP}" 0 "Checking Service:[${service_ip}] UP"
        rlRun "checkKeyRotation ${service_ip} ${service_port} ${TEST_NAMESPACE}" 0\
              "Checking Key Rotation [IP/HOST:${service_ip} PORT:${service_port}]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/func_test/key_rotation/" 0 "Deleting key rotation deployment"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Unique deployment functional test (ClusterIP none)"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/func_test/none_cluster_ip/" 0 "Creating unique deployment with None ClusterIP"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        service_name=$(ocpopGetServiceNameWithPrefix "service" "${TEST_NAMESPACE}" 5 1)
        service_ip=$(ocpopGetServiceClusterIp "${service_name}" "${TEST_NAMESPACE}" "${TO_EXTERNAL_IP}")
        rlAssertEquals "Checking IP is None" "${service_ip}" "None"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/func_test/none_cluster_ip/" 0 "Deleting unique deployment with None ClusterIP"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    ########### /FUNCTIONAL TESTS #########

rlJournalPrintText
rlJournalEnd
