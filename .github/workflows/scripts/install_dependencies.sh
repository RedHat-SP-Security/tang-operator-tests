#!/bin/sh -ex
#
# MIT License
#
# Copyright (c) 2023 Sergio Arroutbi
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
#
COMMON="git file tree make"

case "${DISTRO}" in
debian:*|ubuntu:*)
    export DEBIAN_FRONTEND=noninteractive
    apt clean
    apt update
    # We get some errors once in a while, so let's try a few times.
    for i in 1 2 3; do
        apt -y install ${COMMON} ${DEBIAN_UBUNTU} && break
        sleep 1
    done
    ;;
fedora:*|*centos:*)
    echo 'max_parallel_downloads=10' >> /etc/dnf/dnf.conf
    dnf -y clean all
    dnf -y --setopt=deltarpm=0 update
    dnf -y install ${COMMON} ${FEDORA_CENTOS}
    ;;
esac

echo "================= SYSTEM ================="
cat /etc/os-release
uname -a
echo "=========================================="
