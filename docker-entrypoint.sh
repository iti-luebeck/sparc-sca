#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2024-2026 Andrija Neskovic, University of Luebeck
#
# Docker entrypoint — run the container as the host user.
#
# When HOST_UID / HOST_GID are set (by Makefile docker-run), this script:
#   1. Adds the UID/GID to /etc/passwd and /etc/group so that name-lookup
#      tools (bash, git, groups(1), id(1)…) resolve them without warnings.
#   2. Sets HOME=/root (the volume-mounted cache home) and execs the command
#      via gosu so the process runs as HOST_UID:HOST_GID, not as root.
#
# Files written to bind-mounted workspace paths are therefore owned by the
# host user and can be edited or deleted from outside the container.
#
# Falls back to plain exec (as root) when HOST_UID/HOST_GID are unset.

set -e

HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"

if [ "${HOST_UID}" -ne 0 ] 2>/dev/null && [ "${HOST_GID}" -ne 0 ] 2>/dev/null; then
    # Register group in /etc/group if not already present
    if ! getent group "${HOST_GID}" > /dev/null 2>&1; then
        echo "hostgroup:x:${HOST_GID}:" >> /etc/group
    fi

    # Register user in /etc/passwd if not already present
    if ! getent passwd "${HOST_UID}" > /dev/null 2>&1; then
        echo "hostuser:x:${HOST_UID}:${HOST_GID}::/root:/bin/bash" >> /etc/passwd
    fi

    export HOME=/root
    exec gosu "${HOST_UID}:${HOST_GID}" "$@"
else
    exec "$@"
fi
