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
    rlPhaseStartCleanup
        rlRun 'rlImport "common-cloud-orchestration/ocpop-lib"' || rlDie "cannot import ocpop lib"
        rlRun ". ../../TestHelpers/functions.sh" || rlDie "cannot import function script"
        TO_POD_CONTROLLER_TERMINATE=180 #seconds (for controller to end must wait longer)

        rlRun "ocpopCheckClusterStatus" 0 "Checking cluster status"
        controller_name=$(ocpopGetPodNameWithPartialName "tang-operator-controller" "${OPERATOR_NAMESPACE}" 1)
        ocpopLogVerbose "Controller name:[${controller_name}]"
        if [ -n "${DOWNSTREAM_IMAGE_VERSION}" ] && [ "${DISABLE_BUNDLE_INSTALL_TESTS}" != "1" ];
        then
            rlRun "uninstallDownstreamVersion" 0 "Uninstalling downstream version"
        fi
        rlRun "bundleStop" 0 "Cleaning installed tang-operator"
        if [ "${DISABLE_BUNDLE_INSTALL_TESTS}" != "1" ] && [ "${DISABLE_BUNDLE_UNINSTALL_TESTS}" != "1" ];
        then
          test -z "${controller_name}" ||
          rlRun "ocpopCheckPodKilled ${controller_name} ${OPERATOR_NAMESPACE} ${TO_POD_CONTROLLER_TERMINATE}" 0 "Checking controller POD not available any more [Timeout=${TO_POD_CONTROLLER_TERMINATE} secs.]"
        fi
        rlRun "${OC_CLIENT} delete -f ${TEST_NAMESPACE_FILE}" 0 "Deleting test namespace:${TEST_NAMESPACE}"

        if [ "${UPSTREAM_TANG}" == "true" ]; then
            rlLog "Stop running registry container."
            rlRun "podman rm --force -t 2 registry"
        fi
    rlPhaseEnd
rlJournalEnd
