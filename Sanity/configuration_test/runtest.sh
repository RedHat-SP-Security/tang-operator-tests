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
    ########## CONFIGURATION TESTS #########
    rlPhaseStartTest "Minimal Configuration"
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/conf_test/minimal/" 0 "Creating minimal configuration"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/conf_test/minimal/" 0 "Deleting minimal configuration"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no POD continues running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Main Configuration"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/conf_test/main/" 0 "Creating main configuration"
        rlRun "ocpopCheckPodAmount 3 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 3 PODs are started [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is started [Timeout=${TO_SERVICE_START} secs.]"
        pod1_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 2)
        pod3_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 3)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod3_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD:[$pod1_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD:[$pod2_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod3_name}" 0 "Checking POD:[$pod3_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/conf_test/main/" 0 "Deleting main configuration"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Multiple Deployment Configuration"
        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/conf_test/multi_deployment/" 0 "Creating multiple deployment configuration"
        rlRun "ocpopCheckPodAmount 5 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 5 PODs are started [Timeout=${TO_POD_START} secs.]"
        rlRun "sleep 5" 0 "Waiting to ensure no more than expected replicas are started"
        rlRun "ocpopCheckPodAmount 5 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 5 PODs continue running [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 2 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 2 Services are running [Timeout=${TO_SERVICE_START} secs.]"
        pod1_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 1)
        pod2_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 2)
        pod3_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 3)
        pod4_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 4)
        pod5_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5 5)
        rlAssertNotEquals "Checking pod name not empty" "${pod1_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod2_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod3_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod4_name}" ""
        rlAssertNotEquals "Checking pod name not empty" "${pod5_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD:[$pod1_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD:[$pod2_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod3_name}" 0 "Checking POD:[$pod3_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod4_name}" 0 "Checking POD:[$pod2_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod5_name}" 0 "Checking POD:[$pod3_name] in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/conf_test/multi_deployment/" 0 "Deleting multiple deployment configuration"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd
    ######### /CONFIGURATION TESTS ########

rlJournalPrintText
rlJournalEnd
