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

MINIKUBE_URL="https://storage.googleapis.com/minikube/releases/latest"
MINIKUBE_FILE="minikube-latest.x86_64.rpm"
MINIKUBE_URL_FILE="${MINIKUBE_URL}/${MINIKUBE_FILE}"
OLM_INSTALL_TIMEOUT="5m"

rlJournalStart

    rlPhaseStartTest "Main test"
          #install operator sdk
          ARCH=$(case $(uname -m) in x86_64) echo -n amd64 ;; aarch64) echo -n arm64 ;; *) echo -n "$(uname -m)" ;; esac)
          OS=$(uname | awk '{print tolower($0)}')
          #download latest operator
          curl -s https://api.github.com/repos/operator-framework/operator-sdk/releases/latest \
| grep "operator-sdk_${OS}_${ARCH}" \
| cut -d : -f 2,3 \
| tr -d \" \
| wget -qi - 
          rlRun "chmod +x operator-sdk_${OS}_${ARCH} && mv operator-sdk_${OS}_${ARCH} /usr/local/bin/operator-sdk"

          #setup of libvirt
          rlRun "systemctl enable --now libvirtd"
          rlRun "systemctl restart libvirtd.service"

          #installation of minikube
          rlRun "curl -LO '${MINIKUBE_URL_FILE}'"
          rlRun "rpm -Uvh '${MINIKUBE_FILE}' || true"
          rlRun "curl -LO https://storage.googleapis.com/kubernetes-release/release/`curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt`/bin/linux/amd64/kubectl"
          rlRun "chmod +x kubectl"
          rlRun "mv kubectl  /usr/local/bin/"
          rlRun "kubectl version --client -o json"
          rlRun "minikube start --force"
          #not trying to install again with rerun
          if command -v operator-sdk &>/dev/null && kubectl get catalogsource -n olm &>/dev/null; then
            rlRun "echo 'OLM as already installed.'"
          else
            rlRun "echo 'Instaling OLM'"
            rlRun "operator-sdk --timeout ${OLM_INSTALL_TIMEOUT} olm install"
          fi
          #not use function script due possible usage of this setup for other components
          rlRun "minikube status"
          rlRun "kubectl config view"
    rlPhaseEnd


rlJournalEnd