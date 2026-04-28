# Copyright 2022 Flavien Solt, ETH Zurich.
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck
# Licensed under the General Public License, Version 3.0, see LICENSE for details.
# SPDX-License-Identifier: GPL-3.0-only

# This Makefile manages the repository and the submodule hierarchy.

SHELL := /bin/bash # Need this for associative arrays

# Docker targets are exempt from the env.sh requirement.
ifeq (,$(filter docker-build docker-run docker-run-ro,$(MAKECMDGOALS)))
ifndef CELLIFT_ENV_SOURCED
$(error Please re-source env.sh first, see README.md)
endif
ifneq "$(CELLIFT_ENV_VERSION)" "1"
$(error Current env.sh out of date, please source env.sh again, see README.md)
endif
endif

DOCKER_IMAGE ?= sparc-sca
DOCKER_TAG   ?= latest

default-target:
	@echo "Usage:"
	@echo "    make installtools    - build riscv toolchain, morty, bender,"
	@echo "                           verilator, sv2v and other tools and install"
	@echo "                           in $(PREFIX_CELLIFT)"
	@echo "    make cleantools      - clean build tree of tools and delete"
	@echo "                           $(PREFIX_CELLIFT)"
	@echo "    make pull            - do git pull for current repo and update submodules"
	@echo "    make docker-build    - build the Docker image (no env.sh required)"
	@echo "    make docker-run      - start interactive shell with repo mounted"
	@echo "    make docker-run-ro   - same but mount read-only (safe for exploration)"

# ── Docker targets (do NOT require env.sh to be sourced) ─────────────────────
.PHONY: docker-build docker-run docker-run-ro

docker-build:
	docker build \
	  --build-arg JOBS=$$(nproc) \
	  -t $(DOCKER_IMAGE):$(DOCKER_TAG) \
	  .

docker-run:
	docker run -it --rm \
	  -v $$(pwd):/workspace \
	  -e CELLIFT_JOBS=$$(nproc) \
	  $(DOCKER_IMAGE):$(DOCKER_TAG)

docker-run-ro:
	docker run -it --rm \
	  -v $$(pwd):/workspace:ro \
	  $(DOCKER_IMAGE):$(DOCKER_TAG)

pull:
	git submodule update --jobs $(CELLIFT_JOBS) --init --recursive

clean-designs:
	for design in $(DESIGNS); \
	do	 \
     	make -C designs/$$design/cellift clean; \
	done

update-designs:
	for design in $(DESIGNS); \
	do	 \
     	( cd designs/$$design && git checkout master && echo $$design && git pull --rebase ) \
	done
	( cd cellift-paper && git checkout master && git pull --rebase && git push )

installtools:
	make -C tools installtools

cleantools:
	make -C tools cleantools
