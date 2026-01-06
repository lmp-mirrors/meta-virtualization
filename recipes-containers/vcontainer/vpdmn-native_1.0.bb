# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# vpdmn-native_1.0.bb
# ===========================================================================
# Emulated Podman for cross-architecture container operations
# ===========================================================================
#
# vpdmn provides a Podman-like CLI that executes arbitrary podman commands
# inside a QEMU-emulated environment with the target architecture's Podman.
# Commands like "podman load", "podman images", etc. are passed through to
# Podman running inside QEMU and results streamed back.
#
# vpdmn shares the vrunner.sh runner with vdkr (it's runtime-agnostic).
#
# USAGE:
#   vpdmn images                    # Uses detected default arch
#   vpdmn -a aarch64 images         # Explicit arch
#   vpdmn-aarch64 images            # Symlink (backwards compatible)
#   vpdmn-x86_64 load -i myimage.tar
#
# Architecture detection (in priority order):
#   1. --arch / -a flag
#   2. Executable name (vpdmn-aarch64, vpdmn-x86_64)
#   3. VPDMN_ARCH environment variable
#   4. Config file: ~/.config/vpdmn/arch
#   5. Host architecture (uname -m)
#
# DEPENDENCIES:
#   - Kernel/initramfs blobs from vpdmn-initramfs-create
#   - QEMU system emulator (qemu-system-native)
#   - vrunner.sh (shared runner from vdkr-native)
#
# ===========================================================================

SUMMARY = "Emulated Podman for cross-architecture container operations"
DESCRIPTION = "Provides vpdmn CLI that executes podman commands inside \
               QEMU-emulated environment. Useful for building/manipulating \
               containers for target architectures on a different host."
HOMEPAGE = "https://github.com/anthropics/meta-virtualization"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit native

# Dependencies - we use vdkr's runner script
DEPENDS = "qemu-system-native coreutils-native socat-native vdkr-native"

SRC_URI = "\
    file://vpdmn.sh \
"

# Pre-built blobs are optional - they're checked into the layer after being
# built by vpdmn-initramfs-create. If not present, vpdmn will still build
# but will require --blob-dir at runtime.
#
# To build blobs:
#   MACHINE=qemuarm64 bitbake vpdmn-initramfs-create
#   MACHINE=qemux86-64 bitbake vpdmn-initramfs-create
# Then copy from tmp/deploy/images/<machine>/vpdmn-initramfs/ to files/blobs/vpdmn/<arch>/

FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Layer directory containing optional blobs
VPDMN_LAYER_BLOBS = "${THISDIR}/files/blobs/vpdmn"

# Deploy directories (used when VPDMN_USE_DEPLOY = "1")
VPDMN_DEPLOY_AARCH64 = "${DEPLOY_DIR}/images/qemuarm64/vpdmn-initramfs"
VPDMN_DEPLOY_X86_64 = "${DEPLOY_DIR}/images/qemux86-64/vpdmn-initramfs"

# Set to "1" in local.conf to prefer DEPLOY_DIR blobs over layer
VPDMN_USE_DEPLOY ?= "0"

S = "${UNPACKDIR}"

do_install() {
    # Install vpdmn main script and architecture symlinks
    install -d ${D}${bindir}
    install -d ${D}${bindir}/vpdmn-blobs/aarch64
    install -d ${D}${bindir}/vpdmn-blobs/x86_64

    # Install main vpdmn script (arch detected at runtime)
    install -m 0755 ${S}/vpdmn.sh ${D}${bindir}/vpdmn

    # Create backwards-compatible symlinks
    ln -sf vpdmn ${D}${bindir}/vpdmn-aarch64
    ln -sf vpdmn ${D}${bindir}/vpdmn-x86_64

    # Note: vpdmn uses vrunner.sh from vdkr-native (it's runtime-agnostic)

    # Determine blob source directories based on VPDMN_USE_DEPLOY
    if [ "${VPDMN_USE_DEPLOY}" = "1" ]; then
        AARCH64_SRC="${VPDMN_DEPLOY_AARCH64}"
        X86_64_SRC="${VPDMN_DEPLOY_X86_64}"
        bbwarn "============================================================"
        bbwarn "VPDMN_USE_DEPLOY=1: Using blobs from DEPLOY_DIR"
        bbwarn "This is for development only. For permanent use, copy blobs:"
        bbwarn ""
        bbwarn "  # For aarch64:"
        bbwarn "  cp ${VPDMN_DEPLOY_AARCH64}/Image \\"
        bbwarn "     ${VPDMN_LAYER_BLOBS}/aarch64/"
        bbwarn "  cp ${VPDMN_DEPLOY_AARCH64}/initramfs.cpio.gz \\"
        bbwarn "     ${VPDMN_LAYER_BLOBS}/aarch64/"
        bbwarn ""
        bbwarn "  # For x86_64:"
        bbwarn "  cp ${VPDMN_DEPLOY_X86_64}/bzImage \\"
        bbwarn "     ${VPDMN_LAYER_BLOBS}/x86_64/"
        bbwarn "  cp ${VPDMN_DEPLOY_X86_64}/initramfs.cpio.gz \\"
        bbwarn "     ${VPDMN_LAYER_BLOBS}/x86_64/"
        bbwarn ""
        bbwarn "Then remove VPDMN_USE_DEPLOY from local.conf"
        bbwarn "============================================================"
    else
        AARCH64_SRC="${VPDMN_LAYER_BLOBS}/aarch64"
        X86_64_SRC="${VPDMN_LAYER_BLOBS}/x86_64"
    fi

    # Install aarch64 blobs (if available)
    # Requires: Image, initramfs.cpio.gz, rootfs.img
    if [ -f "$AARCH64_SRC/Image" ] && [ -f "$AARCH64_SRC/rootfs.img" ]; then
        install -m 0644 "$AARCH64_SRC/Image" ${D}${bindir}/vpdmn-blobs/aarch64/
        install -m 0644 "$AARCH64_SRC/initramfs.cpio.gz" ${D}${bindir}/vpdmn-blobs/aarch64/
        install -m 0644 "$AARCH64_SRC/rootfs.img" ${D}${bindir}/vpdmn-blobs/aarch64/
        bbnote "Installed aarch64 blobs from $AARCH64_SRC"
    else
        bbnote "No aarch64 blobs found at $AARCH64_SRC"
        bbnote "Required: Image, initramfs.cpio.gz, rootfs.img"
    fi

    # Install x86_64 blobs (if available)
    # Requires: bzImage, initramfs.cpio.gz, rootfs.img
    if [ -f "$X86_64_SRC/bzImage" ] && [ -f "$X86_64_SRC/rootfs.img" ]; then
        install -m 0644 "$X86_64_SRC/bzImage" ${D}${bindir}/vpdmn-blobs/x86_64/
        install -m 0644 "$X86_64_SRC/initramfs.cpio.gz" ${D}${bindir}/vpdmn-blobs/x86_64/
        install -m 0644 "$X86_64_SRC/rootfs.img" ${D}${bindir}/vpdmn-blobs/x86_64/
        bbnote "Installed x86_64 blobs from $X86_64_SRC"
    else
        bbnote "No x86_64 blobs found at $X86_64_SRC"
        bbnote "Required: bzImage, initramfs.cpio.gz, rootfs.img"
    fi
}

# Make available in native sysroot
SYSROOT_DIRS += "${bindir}"

# Task to print usage instructions
# Run with: bitbake vpdmn-native -c print_usage
python do_print_usage() {
    import os
    native_sysroot = d.getVar('STAGING_DIR_NATIVE')

    bb.plain("")
    bb.plain("=" * 70)
    bb.plain("vpdmn Usage Instructions")
    bb.plain("=" * 70)
    bb.plain("")
    bb.plain("Option 1: Add to PATH (recommended)")
    bb.plain("-" * 40)
    bb.plain("export PATH=\"%s:$PATH\"" % (native_sysroot + d.getVar('bindir')))
    bb.plain("")
    bb.plain("Then use:")
    bb.plain("  vpdmn images              # Uses default arch (host or config)")
    bb.plain("  vpdmn -a aarch64 images   # Explicit arch")
    bb.plain("  vpdmn-x86_64 images       # Symlink (backwards compatible)")
    bb.plain("")
    bb.plain("Option 2: Set default architecture")
    bb.plain("-" * 40)
    bb.plain("mkdir -p ~/.config/vpdmn && echo 'aarch64' > ~/.config/vpdmn/arch")
    bb.plain("")
    bb.plain("Note: QEMU must be in PATH. If not found, also add:")
    bb.plain("export PATH=\"%s:$PATH\"" % (d.getVar('STAGING_BINDIR_NATIVE')))
    bb.plain("")
    bb.plain("=" * 70)
}
addtask print_usage
do_print_usage[nostamp] = "1"
