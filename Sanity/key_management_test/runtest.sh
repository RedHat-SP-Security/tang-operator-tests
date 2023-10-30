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
    ############# KEY MANAGEMENT TESTS ############
    rlPhaseStartTest "Key Management Test"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/key_management_test/minimal-keyretrieve/daemons_v1alpha1_pv.yaml" 0 "Creating key management test pv"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/key_management_test/minimal-keyretrieve/daemons_v1alpha1_tangserver.yaml" 0 "Creating key management test tangserver"
        rlRun "checkPodAmount 1 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 1 POD is started [Timeout=${TO_POD_START} secs.]"
        pod_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 1)
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkServiceAmount 1 ${TO_SERVICE_START} ${TEST_NAMESPACE}" 0 "Checking 1 Service is running [Timeout=${TO_SERVICE_START} secs.]"
        rlRun "checkActiveKeysAmount 1 ${TO_ACTIVE_KEYS} ${TEST_NAMESPACE}" 0 "Checking Active Keys Amount is 1"
        rlRun "checkHiddenKeysAmount 0 ${TO_HIDDEN_KEYS} ${TEST_NAMESPACE}" 0 "Checking Hidden Keys Amount is 0"
        # Rotate VIA API
        rlRun "${FUNCTION_DIR}/reg_test/key_management_test/api_key_rotate.sh -n ${TEST_NAMESPACE} -c ${OC_CLIENT}" 0 "Rotating keys"
        rlRun "checkHiddenKeysAmount 1 ${TO_HIDDEN_KEYS} ${TEST_NAMESPACE}" 0 "Checking Hidden Keys Amount is 1"
        rlRun "checkActiveKeysAmount 1 ${TO_ACTIVE_KEYS} ${TEST_NAMESPACE}" 0 "Checking Active Keys Amount is 1"
        # Rotate again VIA API, keeping all the hidden
        rlRun "${FUNCTION_DIR}/reg_test/key_management_test/key_rotate_keep_existing.sh -n ${TEST_NAMESPACE} -c ${OC_CLIENT}" 0 "Rotating keys again"
        rlRun "checkActiveKeysAmount 1 ${TO_ACTIVE_KEYS} ${TEST_NAMESPACE}" 0 "Checking Active Keys Amount is 1"
        rlRun "checkHiddenKeysAmount 2 ${TO_HIDDEN_KEYS} ${TEST_NAMESPACE}" 0 "Checking Hidden Keys Amount is 2"
        # Delete one, keep one (selective deletion of hidden keys)
        rlRun "${FUNCTION_DIR}/reg_test/key_management_test/key_delete_one_keep_one.sh -n ${TEST_NAMESPACE} -c ${OC_CLIENT}" 0 "Deleteing keys selectively"
        rlRun "checkActiveKeysAmount 1 ${TO_ACTIVE_KEYS} ${TEST_NAMESPACE}" 0 "Checking Active Keys Amount is 1"
        rlRun "checkHiddenKeysAmount 1 ${TO_HIDDEN_KEYS} ${TEST_NAMESPACE}" 0 "Checking Hidden Keys Amount is 1"

        # Delete all VIA API
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/key_management_test/minimal-keyretrieve-deletehiddenkeys/daemons_v1alpha1_pv.yaml" 0 "Deleting key management test pv"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/key_management_test/minimal-keyretrieve-deletehiddenkeys/daemons_v1alpha1_tangserver.yaml" 0 "Deleting key management test tangserver"
        rlRun "checkActiveKeysAmount 1 ${TO_ACTIVE_KEYS} ${TEST_NAMESPACE}" 0 "Checking Active Keys Amount is 1"
        rlRun "checkHiddenKeysAmount 0 ${TO_HIDDEN_KEYS} ${TEST_NAMESPACE}" 0 "Checking Hidden Keys Amount is 0"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/key_management_test/minimal-keyretrieve/daemons_v1alpha1_tangserver.yaml" 0 "Deleting key management test tangserver"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/key_management_test/minimal-keyretrieve/daemons_v1alpha1_pv.yaml" 0 "Deleting key management test pv"
        rlRun "checkPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "checkServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd

    rlPhaseStartTest "Multiple Key Management Replicas Test"
        ### Check Running / Ready Replicas
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_clusterrole.yaml" 0 "Creating multiple key management test clusterrole"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_pv.yaml" 0 "Creating multiple key management test pv"
        rlRun "${OC_CLIENT} apply -f ${FUNCTION_DIR}/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_tangserver.yaml" 0 "Creating multiple key management test tangserver"
        sed "s/{{OPERATOR_NAMESPACE}}/${OPERATOR_NAMESPACE}/g" < $FUNCTION_DIR/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_clusterrolebinding.yaml | ${OC_CLIENT} apply -f -
        rlRun "checkPodAmount 3 ${TO_POD_START} ${TEST_NAMESPACE}" 0 "Checking 3 PODs are started [Timeout=${TO_POD_START} secs.]"
        pod1_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 1)
        pod2_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 2)
        pod3_name=$(getPodNameWithPrefix "tang" "${TEST_NAMESPACE}" 5 3)
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod1_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod2_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkPodState Running ${TO_POD_START} ${TEST_NAMESPACE} ${pod3_name}" 0 "Checking POD in Running state [Timeout=${TO_POD_START} secs.]"
        rlRun "checkStatusRunningReplicas 3 ${TEST_NAMESPACE} ${TO_POD_START}" 0 "Checking Running Replicas in tangserver status"
        rlRun "checkStatusReadyReplicas 3 ${TEST_NAMESPACE} ${TO_POD_START}" 0 "Checking Ready Replicas in tangserver status"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_clusterrole.yaml" 0 "Deleting key management test clusterrole"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_tangserver.yaml" 0 "Deleting key management test tangserver"
        rlRun "${OC_CLIENT} delete -f ${FUNCTION_DIR}/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_pv.yaml" 0 "Deleting key management test pv"
        sed "s/{{OPERATOR_NAMESPACE}}/${OPERATOR_NAMESPACE}/g" < $FUNCTION_DIR/reg_test/key_management_test/multiple-keyretrieve/daemons_v1alpha1_clusterrolebinding.yaml | ${OC_CLIENT} delete -f -
        rlRun "checkPodAmount 0 ${TO_POD_STOP} ${TEST_NAMESPACE}" 0 "Checking no PODs continue running [Timeout=${TO_POD_STOP} secs.]"
        rlRun "checkServiceAmount 0 ${TO_SERVICE_STOP} ${TEST_NAMESPACE}" 0 "Checking no Services continue running [Timeout=${TO_SERVICE_STOP} secs.]"
    rlPhaseEnd
    ############# /KEY MANAGEMENT TESTS ###########

rlJournalPrintText
rlJournalEnd
