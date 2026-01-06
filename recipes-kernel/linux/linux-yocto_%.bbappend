# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# Kernel config fragments for vdkr/vpdmn:
# - 9P filesystem for virtio-9p file sharing (volume mounts)
# - Squashfs and overlayfs for rootfs images
#
# Only applied when "vcontainer" is in DISTRO_FEATURES.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "${@bb.utils.contains('DISTRO_FEATURES', 'vcontainer', 'file://9p.cfg file://squashfs.cfg', '', d)}"
