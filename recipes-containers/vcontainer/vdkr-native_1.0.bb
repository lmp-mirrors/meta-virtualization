# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# vdkr-native_1.0.bb
# ===========================================================================
# Emulated Docker for cross-architecture container operations
# ===========================================================================
#
# vdkr provides a Docker-like CLI that executes arbitrary docker commands
# inside a QEMU-emulated environment with the target architecture's Docker
# daemon. Commands like "docker load", "docker export", "docker images" etc
# are passed through to Docker running inside QEMU and results streamed back.
#
# vdkr uses its own initramfs (built by vdkr-initramfs-create) which
# has vdkr-init.sh baked in. This is separate from container-cross-install.
#
# USAGE:
#   vdkr images                    # Uses detected default arch
#   vdkr -a aarch64 images         # Explicit arch
#   vdkr-aarch64 images            # Symlink (backwards compatible)
#   vdkr-x86_64 load -i myimage.tar
#
# Architecture detection (in priority order):
#   1. --arch / -a flag
#   2. Executable name (vdkr-aarch64, vdkr-x86_64)
#   3. VDKR_ARCH environment variable
#   4. Config file: ~/.config/vdkr/arch
#   5. Host architecture (uname -m)
#
# DEPENDENCIES:
#   - Kernel/initramfs blobs from vdkr-initramfs-create
#   - QEMU system emulator (qemu-system-native)
#
# ===========================================================================

SUMMARY = "Emulated Docker for cross-architecture container operations"
DESCRIPTION = "Provides vdkr CLI that executes docker commands inside \
               QEMU-emulated environment. Useful for building/manipulating \
               containers for target architectures on a different host."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit native

# Dependencies
DEPENDS = "qemu-system-native coreutils-native socat-native"

# vdkr-init.sh is now baked into the initramfs, not installed separately
SRC_URI = "\
    file://vdkr.sh \
    file://vrunner.sh \
"

# Pre-built blobs are optional - they're checked into the layer after being
# built by vdkr-initramfs-build. If not present, vdkr will still build
# but will require --blob-dir at runtime.
#
# To build blobs:
#   MACHINE=qemuarm64 bitbake vdkr-initramfs-build
#   MACHINE=qemux86-64 bitbake vdkr-initramfs-build
# Then copy from tmp/deploy/images/<machine>/vdkr-initramfs/ to files/blobs/vdkr/<arch>/
#
# For development, set VDKR_USE_DEPLOY = "1" in local.conf to use blobs
# directly from DEPLOY_DIR instead of copying to layer.

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Layer directory containing optional blobs
VDKR_LAYER_BLOBS = "${THISDIR}/files/blobs/vdkr"

# Deploy directories (used when VDKR_USE_DEPLOY = "1")
VDKR_DEPLOY_AARCH64 = "${DEPLOY_DIR}/images/qemuarm64/vdkr-initramfs"
VDKR_DEPLOY_X86_64 = "${DEPLOY_DIR}/images/qemux86-64/vdkr-initramfs"

# Set to "1" in local.conf to prefer DEPLOY_DIR blobs over layer
VDKR_USE_DEPLOY ?= "0"

S = "${UNPACKDIR}"

do_install() {
    # Install vdkr main script and architecture symlinks
    install -d ${D}${bindir}
    install -d ${D}${bindir}/vdkr-blobs/aarch64
    install -d ${D}${bindir}/vdkr-blobs/x86_64

    # Install main vdkr script (arch detected at runtime)
    install -m 0755 ${S}/vdkr.sh ${D}${bindir}/vdkr

    # Create backwards-compatible symlinks
    ln -sf vdkr ${D}${bindir}/vdkr-aarch64
    ln -sf vdkr ${D}${bindir}/vdkr-x86_64

    # Install runner script
    install -m 0755 ${S}/vrunner.sh ${D}${bindir}/

    # Determine blob source directories based on VDKR_USE_DEPLOY
    if [ "${VDKR_USE_DEPLOY}" = "1" ]; then
        AARCH64_SRC="${VDKR_DEPLOY_AARCH64}"
        X86_64_SRC="${VDKR_DEPLOY_X86_64}"
        bbwarn "============================================================"
        bbwarn "VDKR_USE_DEPLOY=1: Using blobs from DEPLOY_DIR"
        bbwarn "This is for development only. For permanent use, copy blobs:"
        bbwarn ""
        bbwarn "  # For aarch64:"
        bbwarn "  cp ${VDKR_DEPLOY_AARCH64}/Image \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/aarch64/"
        bbwarn "  cp ${VDKR_DEPLOY_AARCH64}/initramfs.cpio.gz \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/aarch64/"
        bbwarn ""
        bbwarn "  # For x86_64:"
        bbwarn "  cp ${VDKR_DEPLOY_X86_64}/bzImage \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/x86_64/"
        bbwarn "  cp ${VDKR_DEPLOY_X86_64}/initramfs.cpio.gz \\"
        bbwarn "     ${VDKR_LAYER_BLOBS}/x86_64/"
        bbwarn ""
        bbwarn "Then remove VDKR_USE_DEPLOY from local.conf"
        bbwarn "============================================================"
    else
        AARCH64_SRC="${VDKR_LAYER_BLOBS}/aarch64"
        X86_64_SRC="${VDKR_LAYER_BLOBS}/x86_64"
    fi

    # Install aarch64 blobs (if available)
    # Requires: Image, initramfs.cpio.gz, rootfs.img
    if [ -f "$AARCH64_SRC/Image" ] && [ -f "$AARCH64_SRC/rootfs.img" ]; then
        install -m 0644 "$AARCH64_SRC/Image" ${D}${bindir}/vdkr-blobs/aarch64/
        install -m 0644 "$AARCH64_SRC/initramfs.cpio.gz" ${D}${bindir}/vdkr-blobs/aarch64/
        install -m 0644 "$AARCH64_SRC/rootfs.img" ${D}${bindir}/vdkr-blobs/aarch64/
        bbnote "Installed aarch64 blobs from $AARCH64_SRC"
    else
        bbnote "No aarch64 blobs found at $AARCH64_SRC"
        bbnote "Required: Image, initramfs.cpio.gz, rootfs.img"
    fi

    # Install x86_64 blobs (if available)
    # Requires: bzImage, initramfs.cpio.gz, rootfs.img
    if [ -f "$X86_64_SRC/bzImage" ] && [ -f "$X86_64_SRC/rootfs.img" ]; then
        install -m 0644 "$X86_64_SRC/bzImage" ${D}${bindir}/vdkr-blobs/x86_64/
        install -m 0644 "$X86_64_SRC/initramfs.cpio.gz" ${D}${bindir}/vdkr-blobs/x86_64/
        install -m 0644 "$X86_64_SRC/rootfs.img" ${D}${bindir}/vdkr-blobs/x86_64/
        bbnote "Installed x86_64 blobs from $X86_64_SRC"
    else
        bbnote "No x86_64 blobs found at $X86_64_SRC"
        bbnote "Required: bzImage, initramfs.cpio.gz, rootfs.img"
    fi
}

# Make available in native sysroot
SYSROOT_DIRS += "${bindir}"

# Task to print usage instructions for using vdkr from current location
# Run with: bitbake vdkr-native -c print_usage
python do_print_usage() {
    import os
    bindir = d.getVar('D') + d.getVar('bindir')

    # Find the actual install location
    image_dir = d.getVar('D')
    native_sysroot = d.getVar('STAGING_DIR_NATIVE')

    bb.plain("")
    bb.plain("=" * 70)
    bb.plain("vdkr Usage Instructions")
    bb.plain("=" * 70)
    bb.plain("")
    bb.plain("Option 1: Add to PATH (recommended)")
    bb.plain("-" * 40)
    bb.plain("export PATH=\"%s:$PATH\"" % (native_sysroot + d.getVar('bindir')))
    bb.plain("")
    bb.plain("Then use:")
    bb.plain("  vdkr images              # Uses default arch (host or config)")
    bb.plain("  vdkr -a aarch64 images   # Explicit arch")
    bb.plain("  vdkr-x86_64 images       # Symlink (backwards compatible)")
    bb.plain("")
    bb.plain("Option 2: Direct invocation")
    bb.plain("-" * 40)
    bb.plain("%s/vdkr images" % (native_sysroot + d.getVar('bindir')))
    bb.plain("")
    bb.plain("Option 3: Set default architecture")
    bb.plain("-" * 40)
    bb.plain("mkdir -p ~/.config/vdkr && echo 'aarch64' > ~/.config/vdkr/arch")
    bb.plain("")
    bb.plain("Note: QEMU must be in PATH. If not found, also add:")
    bb.plain("export PATH=\"%s:$PATH\"" % (d.getVar('STAGING_BINDIR_NATIVE')))
    bb.plain("")
    bb.plain("=" * 70)
}
addtask print_usage
do_print_usage[nostamp] = "1"
