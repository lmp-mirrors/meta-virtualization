# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# vdkr-rootfs-image.bb
# Minimal Docker-capable image for vdkr QEMU environment
#
# This image is built via multiconfig and used by vdkr-initramfs-create
# to provide a proper rootfs for running Docker in QEMU.
#
# Build with:
#   bitbake mc:vruntime-aarch64:vdkr-rootfs-image
#   bitbake mc:vruntime-x86-64:vdkr-rootfs-image

SUMMARY = "Minimal Docker rootfs for vdkr"
DESCRIPTION = "A minimal image containing Docker tools for use with vdkr. \
               This image runs inside QEMU to provide Docker command execution."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Track init script changes via file-checksums
# This adds the file content hash to the task signature
do_rootfs[file-checksums] += "${THISDIR}/files/vdkr-init.sh:True"
do_rootfs[file-checksums] += "${THISDIR}/files/vcontainer-init-common.sh:True"

# Force do_rootfs to always run (no stamp caching)
# Combined with file-checksums, this ensures init script changes are picked up
do_rootfs[nostamp] = "1"

# Inherit from core-image-minimal for a minimal base
inherit core-image

# We need Docker and container tools
IMAGE_INSTALL = " \
    packagegroup-core-boot \
    docker-moby \
    containerd \
    runc \
    skopeo \
    busybox \
    iproute2 \
    iptables \
    util-linux \
"

# No extra features needed
IMAGE_FEATURES = ""

# Keep the image small
IMAGE_ROOTFS_SIZE = "524288"
IMAGE_ROOTFS_EXTRA_SPACE = "0"

# Use squashfs for smaller size (~3x compression)
# The preinit mounts squashfs read-only with tmpfs overlay for writes
IMAGE_FSTYPES = "squashfs"

# Install our init script
ROOTFS_POSTPROCESS_COMMAND += "install_vdkr_init;"

install_vdkr_init() {
    # Install vdkr-init.sh as /init and vcontainer-init-common.sh alongside it
    install -m 0755 ${THISDIR}/files/vdkr-init.sh ${IMAGE_ROOTFS}/init
    install -m 0755 ${THISDIR}/files/vcontainer-init-common.sh ${IMAGE_ROOTFS}/vcontainer-init-common.sh

    # Create required directories
    install -d ${IMAGE_ROOTFS}/mnt/input
    install -d ${IMAGE_ROOTFS}/mnt/state
    install -d ${IMAGE_ROOTFS}/var/lib/docker
    install -d ${IMAGE_ROOTFS}/run/containerd

    # Create skopeo policy
    install -d ${IMAGE_ROOTFS}/etc/containers
    echo '{"default":[{"type":"insecureAcceptAnything"}]}' > ${IMAGE_ROOTFS}/etc/containers/policy.json
}
