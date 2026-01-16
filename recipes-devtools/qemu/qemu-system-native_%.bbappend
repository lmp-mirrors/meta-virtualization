# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# Enable virtfs (virtio-9p) for vcontainer cross-architecture container bundling.
# This is required for the fast batch-import path in container-cross-install.
#
# Only applied when "vcontainer" or "virtualization" is in DISTRO_FEATURES.

PACKAGECONFIG:append = " ${@bb.utils.contains_any('DISTRO_FEATURES', 'vcontainer virtualization', 'virtfs', '', d)}"
