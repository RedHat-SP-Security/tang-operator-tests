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

# Helper function to check pod and service amounts
checkPodsAndServices() {
    local expected_pods=$1
    local expected_services=$2
    local pod_timeout=$3
    local service_timeout=$4
    local namespace=$5

    rlRun "ocpopCheckPodAmount ${expected_pods} ${pod_timeout} ${namespace}" 0 "Checking ${expected_pods} POD(s) [Timeout=${pod_timeout} secs.]"
    rlRun "ocpopCheckServiceAmount ${expected_services} ${service_timeout} ${namespace}" 0 "Checking ${expected_services} Service(s) [Timeout=${service_timeout} secs.]"
}

# Helper function to wait for PVC phase with retry loop
waitForPvcPhase() {
    local pvc_name=$1
    local namespace=$2
    local timeout=$3
    local counter=0

    while [ ${counter} -lt ${timeout} ]; do
        pvc_status=$(${OC_CLIENT} get pvc ${pvc_name} -n ${namespace} -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        ocpopLogVerbose "PVC ${pvc_name} status: ${pvc_status} [${counter}/${timeout}]"

        if [ "$pvc_status" = "Bound" ] || [ "$pvc_status" = "Pending" ]; then
            echo "$pvc_status"
            return 0
        fi

        counter=$((counter+1))
        sleep 1
    done

    echo "$pvc_status"
    return 1
}

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1
rlJournalStart
    ########### SCALABILTY TESTS ##########
    rlPhaseStartTest "Scale-out scalability test"
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        TO_POD_SCALEIN_WAIT=180 #seconds
        TO_POD_TERMINATE=180 #seconds
        TO_PVC_READY=30 #seconds

        # Check if ReadWriteMany is supported by attempting to create the PVC
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_out/scale_out0/" 0 "Creating scale out test [0]"

        # Wait for PVC to reach Bound or Pending state with retry loop
        pvc_status=$(waitForPvcPhase "tangserver-pvc" "${TEST_NAMESPACE}" ${TO_PVC_READY})

        SKIP_TEST=0
        SCALE_OUT1_CREATED=0
        if [ "$pvc_status" = "Pending" ]; then
            # Check if the issue is due to ReadWriteMany not being supported
            pvc_events=$(${OC_CLIENT} get events -n ${TEST_NAMESPACE} --field-selector involvedObject.name=tangserver-pvc -o json 2>/dev/null)
            if echo "$pvc_events" | grep -q -i "storageclass.*does not support.*ReadWriteMany\|no.*volume.*plugin.*matched\|volume.*does not support.*access mode"; then
                rlLogWarning "ReadWriteMany access mode is not supported by the storage class. Skipping scale-out test."
                rlLog "RESULT: SKIP - ReadWriteMany not supported"
                SKIP_TEST=1
            fi
        fi

        if [ $SKIP_TEST -eq 0 ]; then
            # Continue with normal test if PVC is bound or accessible
            checkPodsAndServices 1 1 ${TO_POD_START} ${TO_SERVICE_START} ${TEST_NAMESPACE}
            pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
            rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
            rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
            rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_out/scale_out1/" 0 "Creating scale out test [1]"
            SCALE_OUT1_CREATED=1
            checkPodsAndServices 2 1 ${TO_POD_START} ${TO_SERVICE_START} ${TEST_NAMESPACE}
            pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
            rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
            rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking added POD in Running state [Timeout=${TO_POD_START} secs.]"
        fi

        # Cleanup regardless of skip status
        if [ $SCALE_OUT1_CREATED -eq 1 ]; then
            rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_out/scale_out1/" 0 "Deleting scale out test [1]"
        fi
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_out/scale_out0/ --ignore-not-found=true" 0 "Deleting scale out test [0]"
        checkPodsAndServices 0 0 ${TO_POD_STOP} ${TO_SERVICE_STOP} ${TEST_NAMESPACE}
    rlPhaseEnd

    rlPhaseStartTest "Scale-in scalability test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_in/scale_in0/" 0 "Creating scale in test [0]"
        checkPodsAndServices 2 1 ${TO_POD_START} ${TO_SERVICE_START} ${TEST_NAMESPACE}
        pod1_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 2)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD:[$pod1_name}] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD:[$pod2_name}] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_in/scale_in1/" 0 "Creating scale in test [1]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_SCALEIN_WAIT} ${TEST_NAMESPACE}" 0 "Checking only 1 POD continues running [Timeout=${TO_POD_SCALEIN_WAIT} secs.]"
        pod1_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD:[$pod1_name}] still in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_in/scale_in0/" 0 "Deleting scale in test"
        checkPodsAndServices 0 0 ${TO_POD_STOP} ${TO_SERVICE_START} ${TEST_NAMESPACE}
    rlPhaseEnd

    rlPhaseStartTest "Scale-up scalability test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_up/scale_up0/" 0 "Creating scale up test [0]"
        checkPodsAndServices 1 1 ${TO_POD_START} ${TO_SERVICE_START} ${TEST_NAMESPACE}
        pod1_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD:[$pod1_name}] in Running state [Timeout=${TO_POD_START} secs.]"
        cpu1=$(ocpopGetPodCpuRequest "${pod1_name}" "${TEST_NAMESPACE}")
        mem1=$(ocpopGetPodMemRequest "${pod1_name}" "${TEST_NAMESPACE}")
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_up/scale_up1/" 0 "Creating scale up test [1]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking only 1 POD continues running [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodKilled ${pod1_name} ${TEST_NAMESPACE} ${TO_POD_TERMINATE}" 0 "Checking POD:[${pod1_name}] not available any more [Timeout=${TO_POD_TERMINATE} secs.]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 new POD is running [Timeout=${TO_POD_START} secs.]"
        pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlAssertNotEquals "Checking new POD has been created" "${pod1_name}" "${pod2_name}"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD:[$pod2_name}] in Running state [Timeout=${TO_POD_START} secs.]"
        cpu2=$(ocpopGetPodCpuRequest "${pod2_name}" "${TEST_NAMESPACE}")
        mem2=$(ocpopGetPodMemRequest "${pod2_name}" "${TEST_NAMESPACE}")
        rlAssertGreater "Checking cpu request value increased" "${cpu2}" "${cpu1}"
        rlAssertGreater "Checking mem request value increased" "${mem2}" "${mem1}"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_up/scale_up0/" 0 "Deleting scale up test"
        checkPodsAndServices 0 0 ${TO_POD_STOP} ${TO_SERVICE_STOP} ${TEST_NAMESPACE}
    rlPhaseEnd

    rlPhaseStartTest "Scale-down scalability test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_down/scale_down0/" 0 "Creating scale down test [0]"
        checkPodsAndServices 1 1 ${TO_POD_START} ${TO_SERVICE_START} ${TEST_NAMESPACE}
        pod1_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD:[$pod1_name}] in Running state [Timeout=${TO_POD_START} secs.]"
        cpu1=$(ocpopGetPodCpuRequest "${pod1_name}" "${TEST_NAMESPACE}")
        mem1=$(ocpopGetPodMemRequest "${pod1_name}" "${TEST_NAMESPACE}")
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_down/scale_down1/" 0 "Creating scale down test [1]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking only 1 POD continues running [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodKilled ${pod1_name} ${TEST_NAMESPACE} ${TO_POD_TERMINATE}" 0 "Checking POD:[${pod1_name}] not available any more [Timeout=${TO_POD_TERMINATE} secs.]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 new POD is running [Timeout=${TO_POD_START} secs.]"
        pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlAssertNotEquals "Checking new POD has been created" "${pod1_name}" "${pod2_name}"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD:[$pod2_name}] in Running state [Timeout=${TO_POD_START} secs.]"
        cpu2=$(ocpopGetPodCpuRequest "${pod2_name}" "${TEST_NAMESPACE}")
        mem2=$(ocpopGetPodMemRequest "${pod2_name}" "${TEST_NAMESPACE}")
        rlAssertLesser "Checking cpu request value decreased" "${cpu2}" "${cpu1}"
        rlAssertLesser "Checking mem request value decreased" "${mem2}" "${mem1}"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_down/scale_down0/" 0 "Deleting scale down test"
        checkPodsAndServices 0 0 ${TO_POD_STOP} ${TO_SERVICE_STOP} ${TEST_NAMESPACE}
    rlPhaseEnd
    ########### /SCALABILTY TESTS #########

rlJournalPrintText
rlJournalEnd
