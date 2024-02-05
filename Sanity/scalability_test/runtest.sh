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
    ########### SCALABILTY TESTS ##########
    rlPhaseStartTest "Scale-out scalability test"
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        TO_POD_SCALEIN_WAIT=120 #seconds
        TO_POD_TERMINATE=120 #seconds

        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_out/scale_out0/" 0 "Creating scale out test [0]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_out/scale_out1/" 0 "Creating scale out test [1]"
        rlRun "ocpopCheckPodAmount 2 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1+1 PODs are started [Timeout=${TO_POD_START} secs.]"
        pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking added POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_out/scale_out0/" 0 "Deleting scale out test"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Scale-in scalability test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_in/scale_in0/" 0 "Creating scale in test [0]"
        rlRun "ocpopCheckPodAmount 2 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 2 PODs are started [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is running [Timeout=${TO_SERVICE_START} secs.]"
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
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_START} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Scale-up scalability test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_up/scale_up0/" 0 "Creating scale up test [0]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is running [Timeout=${TO_SERVICE_START} secs.]"
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
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Scale-down scalability test"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/scale_test/scale_down/scale_down0/" 0 "Creating scale down test [0]"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is running [Timeout=${TO_SERVICE_START} secs.]"
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
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd
    ########### /SCALABILTY TESTS #########

rlJournalPrintText
rlJournalEnd
