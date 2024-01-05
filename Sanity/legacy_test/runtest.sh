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
    ############# LEGACY TESTS ############
    rlPhaseStartTest "Legacy Test"
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        TO_LEGACY_POD_RUNNING=120 #seconds

        rlRun "${OC_CLIENT} apply -f ${TANG_FUNCTION_DIR}/reg_test/legacy_test/" 0 "Creating legacy test"
        rlRun "ocpopCheckPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        rlRun "ocpopCheckServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is running [Timeout=${TO_SERVICE_START} secs.]"
        pod_name=$(ocpopGetPodNameWithPartialName "tang" "${TEST_NAMESPACE}" 5)
        rlAssertNotEquals "Checking pod name not empty" "${pod_name}" ""
        rlRun "ocpopCheckPodState Running ${TO_LEGACY_POD_RUNNING} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_LEGACY_POD_RUNNING} secs.]"
        rlRun "${OC_CLIENT} delete -f ${TANG_FUNCTION_DIR}/reg_test/legacy_test/" 0 "Deleting legacy test"
        rlRun "ocpopCheckPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "ocpopCheckServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd
    ############# /LEGACY TESTS ###########
rlJournalPrintText
rlJournalEnd
