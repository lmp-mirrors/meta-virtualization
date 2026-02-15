# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# vxn_1.0.bb
# ===========================================================================
# Target integration package for vxn (vcontainer on Xen)
# ===========================================================================
#
# This recipe installs vxn onto a Xen Dom0 target. It provides:
# - vxn CLI wrapper (docker-like interface for Xen DomU containers)
# - vrunner.sh (hypervisor-agnostic VM runner)
# - vrunner-backend-xen.sh (Xen xl backend)
# - vcontainer-common.sh (shared CLI code)
# - Kernel, initramfs, and rootfs blobs for booting DomU guests
#
# The blobs are sourced from the vxn-initramfs-create recipe which
# reuses the same rootfs images built by vdkr/vpdmn (the init scripts
# detect the hypervisor at boot time).
#
# ===========================================================================
# BUILD INSTRUCTIONS
# ===========================================================================
#
# For aarch64 Dom0:
#   MACHINE=qemuarm64 bitbake vxn
#
# For x86_64 Dom0:
#   MACHINE=qemux86-64 bitbake vxn
#
# Add to a Dom0 image:
#   IMAGE_INSTALL:append = " vxn"
#
# Usage on Dom0:
#   vxn run hello-world           # Run OCI container as Xen DomU
#   vxn vmemres start             # Start persistent DomU (daemon mode)
#   vxn vexpose                   # Expose Docker API on Dom0
#
# ===========================================================================

SUMMARY = "Docker CLI for Xen-based container execution"
DESCRIPTION = "vxn provides a familiar docker-like CLI that executes commands \
               inside a Xen DomU guest with Docker. It uses the vcontainer \
               infrastructure with a Xen hypervisor backend."
HOMEPAGE = "https://git.yoctoproject.org/meta-virtualization/"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit features_check
REQUIRED_DISTRO_FEATURES = "xen"

SRC_URI = "\
    file://vxn.sh \
    file://vrunner.sh \
    file://vrunner-backend-xen.sh \
    file://vrunner-backend-qemu.sh \
    file://vcontainer-common.sh \
"

FILESEXTRAPATHS:prepend := "${THISDIR}/../../recipes-containers/vcontainer/files:"

S = "${UNPACKDIR}"

# Runtime dependencies on Dom0
RDEPENDS:${PN} = "\
    xen-tools-xl \
    bash \
    jq \
    socat \
    coreutils \
    util-linux \
    e2fsprogs \
    skopeo \
"

# Blobs are sourced from vxn-initramfs-create deploy output.
# Build blobs first: bitbake vxn-initramfs-create
# No task dependency here - vxn-initramfs-create is deploy-only (no packages).
# Adding any dependency from a packaged recipe to a deploy-only recipe
# breaks do_rootfs (sstate manifest not found for package_write_rpm).

# Blobs come from DEPLOY_DIR which is untracked by sstate hash.
# nostamp on do_install alone is insufficient — do_package and
# do_package_write_rpm have unchanged sstate hashes so they restore
# the OLD RPM from cache, discarding the fresh do_install output.
# Force the entire install→package→RPM chain to always re-run.
do_install[nostamp] = "1"
do_package[nostamp] = "1"
do_packagedata[nostamp] = "1"
do_package_write_rpm[nostamp] = "1"
do_package_write_ipk[nostamp] = "1"
do_package_write_deb[nostamp] = "1"

def vxn_get_blob_arch(d):
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'aarch64'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'x86_64'
    return 'aarch64'

def vxn_get_kernel_image_name(d):
    arch = d.getVar('TARGET_ARCH')
    if arch == 'aarch64':
        return 'Image'
    elif arch in ['x86_64', 'i686', 'i586']:
        return 'bzImage'
    elif arch == 'arm':
        return 'zImage'
    return 'Image'

BLOB_ARCH = "${@vxn_get_blob_arch(d)}"
KERNEL_IMAGETYPE_VXN = "${@vxn_get_kernel_image_name(d)}"

VXN_DEPLOY = "${DEPLOY_DIR_IMAGE}"

do_install() {
    # Install CLI wrapper
    install -d ${D}${bindir}
    install -m 0755 ${S}/vxn.sh ${D}${bindir}/vxn

    # Install shared scripts into libdir
    install -d ${D}${libdir}/vxn
    install -m 0755 ${S}/vrunner.sh ${D}${libdir}/vxn/
    install -m 0755 ${S}/vrunner-backend-xen.sh ${D}${libdir}/vxn/
    install -m 0755 ${S}/vrunner-backend-qemu.sh ${D}${libdir}/vxn/
    install -m 0644 ${S}/vcontainer-common.sh ${D}${libdir}/vxn/

    # Install blobs from vxn-initramfs-create deployment
    # Layout must match what vrunner backends expect: $BLOB_DIR/<arch>/{Image,initramfs.cpio.gz,rootfs.img}
    install -d ${D}${datadir}/vxn/${BLOB_ARCH}

    VXN_BLOB_SRC="${VXN_DEPLOY}/vxn/${BLOB_ARCH}"
    if [ -d "${VXN_BLOB_SRC}" ]; then
        if [ -f "${VXN_BLOB_SRC}/${KERNEL_IMAGETYPE_VXN}" ]; then
            install -m 0644 "${VXN_BLOB_SRC}/${KERNEL_IMAGETYPE_VXN}" ${D}${datadir}/vxn/${BLOB_ARCH}/
            bbnote "Installed kernel ${KERNEL_IMAGETYPE_VXN}"
        else
            bbwarn "Kernel not found at ${VXN_BLOB_SRC}/${KERNEL_IMAGETYPE_VXN}"
        fi

        if [ -f "${VXN_BLOB_SRC}/initramfs.cpio.gz" ]; then
            install -m 0644 "${VXN_BLOB_SRC}/initramfs.cpio.gz" ${D}${datadir}/vxn/${BLOB_ARCH}/
            bbnote "Installed initramfs"
        else
            bbwarn "Initramfs not found at ${VXN_BLOB_SRC}/initramfs.cpio.gz"
        fi

        if [ -f "${VXN_BLOB_SRC}/rootfs.img" ]; then
            install -m 0644 "${VXN_BLOB_SRC}/rootfs.img" ${D}${datadir}/vxn/${BLOB_ARCH}/
            bbnote "Installed rootfs.img"
        else
            bbwarn "Rootfs not found at ${VXN_BLOB_SRC}/rootfs.img"
        fi
    else
        bbwarn "VXN blob directory not found at ${VXN_BLOB_SRC}. Build with: bitbake vxn-initramfs-create"
    fi
}

FILES:${PN} = "\
    ${bindir}/vxn \
    ${libdir}/vxn/ \
    ${datadir}/vxn/ \
"

# Blobs are large binary files
INSANE_SKIP:${PN} += "already-stripped"
