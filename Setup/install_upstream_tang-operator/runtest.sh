#!/bin/bash
# Copyright 2023.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
. /usr/share/beakerlib/beakerlib.sh || exit 1

[ -n "${TANG_OPERATOR_UPSTREAM_URL}" ] || TANG_OPERATOR_UPSTREAM_URL="https://github.com/latchset/tang-operator.git"
[ -n "${TANG_OPERATOR_UPSTREAM_BRANCH}" ] || TANG_OPERATOR_UPSTREAM_BRANCH="main"

rlJournalStart

    rlPhaseStartTest "Build tang operator bundle from upstream code"
        export IP=$(hostname -I | awk '{print $1}')
        if [ -d /var/tmp/tang-operator_sources ]; then
            rlLogInfo "Compiling tang-operator bits from /var/tmp/tang-operator_sources"
        else
            rlLogInfo "Compiling tang-operator from cloned upstream repo"
            rlRun "git clone -b ${TANG_OPERATOR_UPSTREAM_BRANCH} ${TANG_OPERATOR_UPSTREAM_URL} /var/tmp/tang-operator_sources"
        fi
        rlRun "pushd /var/tmp/tang-operator_sources"
        rlRun "sed -i 's/FROM golang:1.21 as builder/FROM docker.io\/library\/golang:1.21 as builder/g' Dockerfile"
cat <<EOF >> /etc/containers/registries.conf
[[registry]]
location = "${IP}:5000"
insecure = true
EOF
        rlRun "mkdir -p /var/lib/registry"
        #Need to export to use it in make build commands
        export IMG="${IP}:5000/tang-controller:latest"
        export BUNDLE_IMG="${IP}:5000/tang-operator-bundle:latest"
        rlRun "podman container run -dt -p 5000:5000 --name registry --volume registry:/var/lib/registry:Z docker.io/library/registry:2"
        #Check if it's registry accesible
        rlRun "curl ${IP}:5000/v2/_catalog" 0 "Checking registry availability"
        rlRun "make podman-build podman-push"
        rlRun "make bundle"
        rlRun "make podman-bundle-build podman-bundle-push"
        #For another shell sessions
        cat <<EOF > /etc/profile.d/upstream_tang_init.sh
#!/bin/bash
export IMAGE_VERSION=${BUNDLE_IMG}
export RUN_BUNDLE_PARAMS="--use-http"
EOF
        popd
    rlPhaseEnd


rlJournalEnd
