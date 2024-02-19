# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Makefile of /CoreOS/attestation-operator/Setup/prepare_library
#   Description: Clone common cloud orchestration library repository
#   Author: Sergio Arroutbi <sarroutb@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2023 Red Hat, Inc.
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
COMMON_REPOSITORY:=$(shell sh -c "grep url $(COMMON_REPOSITORY_CLONE_DIR)/main.fmf | grep common | \
                     sed -e s@' \- url: '@@g" | tr -d ' ')
COMMON_REPOSITORY_DIR=$(shell echo "$(COMMON_REPOSITORY)" | awk -F '/' '{print $$NF}')

.PHONY: clone

clone:
	test -d $(COMMON_REPOSITORY_CLONE_DIR)/$(COMMON_REPOSITORY_DIR) || git clone $(COMMON_REPOSITORY) $(COMMON_REPOSITORY_CLONE_DIR)/$(COMMON_REPOSITORY_DIR)
