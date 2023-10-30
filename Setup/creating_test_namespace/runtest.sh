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
    rlPhaseStartSetup
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        dumpDate
        dumpInfo
        rlLog "Creating tmp directory"
        tmpdir=$(mktemp -d)
        rlAssertNotEquals "Checking temporary directory name not empty" "${tmpdir}" ""
        rlRun "dumpOpenShiftClientStatus" 0 "Checking OpenshiftClient installation"
        rlRun "operator-sdk version > /dev/null" 0 "Checking operator-sdk installation"
        rlRun "checkClusterStatus" 0 "Checking cluster status"
        # In case previous execution was abruptelly stopped:
        rlRun "bundleInitialStop" 0 "Cleaning already installed tang-operator (if any)"
        rlRun "bundleStart" 0 "Installing tang-operator-bundle version:${VERSION}"
        rlRun "${OC_CLIENT} apply -f ${TEST_NAMESPACE_FILE}" 0 "Creating test namespace:${TEST_NAMESPACE}"
        rlRun "${OC_CLIENT} get namespace ${TEST_NAMESPACE}" 0 "Checking test namespace:${TEST_NAMESPACE}"
        #go through all the files and set substition for TANG_IMAGE keyword
        if [ -n "$TANG_IMAGE" ]; then
            useUpstreamImages
        fi
        ########## CHECK CONTROLLER RUNNING #########
        controller_name=$(getPodNameWithPrefix "tang-operator-controller" "${OPERATOR_NAMESPACE}" "${TO_POD_START}")
        rlRun "checkPodState Running ${TO_POD_START} ${OPERATOR_NAMESPACE} ${controller_name}" 0 "Checking controller POD in Running [Timeout=${TO_POD_START} secs.]"
    rlPhaseEnd
rlJournalEnd