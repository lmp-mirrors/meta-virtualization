#
# Copyright (c) 2026, Bruce Ashfield
#
# SPDX-License-Identifier: GPL-2.0-only
#
# DESCRIPTION
# This implements the 'bootimg_efixen' source plugin class for 'wic'.
#
# Creates an EFI System Partition that boots Xen directly via the native
# xen.efi EFI application.  No GRUB or other intermediate bootloader is
# needed -- the UEFI firmware loads xen.efi, which reads its own config
# file and chain-loads the dom0 kernel.
#
# Bootloader arguments use the --- separator convention (same as the
# bootimg_biosxen plugin) to split Xen hypervisor options from Linux
# kernel options:
#
#   bootloader --append="dom0_mem=512M console=com1 --- console=hvc0 root=/dev/sda2"
#
# Optional source param: initrd
#   part /boot --source bootimg-efixen --sourceparams="initrd=initramfs.cpio.gz"
#

import logging
import os

from wic import WicError
from wic.pluginbase import SourcePlugin
from wic.misc import (exec_cmd, exec_native_cmd,
                      get_bitbake_var, BOOTDD_EXTRA_SPACE)

logger = logging.getLogger('wic')


class BootimgEfiXenPlugin(SourcePlugin):
    """
    Create an EFI System Partition for direct Xen EFI boot.
    """

    name = 'bootimg_efixen'

    @classmethod
    def do_configure_partition(cls, part, source_params, creator, cr_workdir,
                               oe_builddir, bootimg_dir, kernel_dir,
                               native_sysroot):
        hdddir = "%s/hdd/boot" % cr_workdir
        install_cmd = "install -d %s/EFI/BOOT" % hdddir
        exec_cmd(install_cmd)

        bootloader = creator.ks.bootloader

        # Split bootloader args at '---': Xen options --- Linux kernel options
        xen_options = "dom0_mem=512M console=com1,vga com1=115200,8n1"
        kernel_options = ""
        if bootloader.append:
            separator_pos = bootloader.append.find('---')
            if separator_pos != -1:
                xen_options = bootloader.append[:separator_pos].strip()
                kernel_options = bootloader.append[separator_pos + 3:].strip()
            else:
                kernel_options = bootloader.append.strip()

        kernel = get_bitbake_var("KERNEL_IMAGETYPE")
        if get_bitbake_var("INITRAMFS_IMAGE_BUNDLE") == "1":
            if get_bitbake_var("INITRAMFS_IMAGE"):
                kernel = "%s-%s.bin" % \
                    (get_bitbake_var("KERNEL_IMAGETYPE"),
                     get_bitbake_var("INITRAMFS_LINK_NAME"))

        # Xen EFI config: kernel= takes filename followed by kernel cmdline
        kernel_line = "%s %s" % (kernel, kernel_options)

        xen_cfg = "[global]\n"
        xen_cfg += "default=dom0\n\n"
        xen_cfg += "[dom0]\n"
        xen_cfg += "options=%s\n" % xen_options
        xen_cfg += "kernel=%s\n" % kernel_line

        initrd = source_params.get('initrd')
        if initrd:
            initrds = initrd.split(';')
            xen_cfg += "ramdisk=%s\n" % initrds[0]

        # xen.efi looks for <binary-basename>.cfg in the same directory
        cfg_path = "%s/EFI/BOOT/bootx64.cfg" % hdddir
        logger.debug("Writing Xen EFI config %s", cfg_path)
        with open(cfg_path, "w") as cfg:
            cfg.write(xen_cfg)

    @classmethod
    def do_prepare_partition(cls, part, source_params, creator, cr_workdir,
                             oe_builddir, bootimg_dir, kernel_dir,
                             rootfs_dir, native_sysroot):
        if not kernel_dir:
            kernel_dir = get_bitbake_var("DEPLOY_DIR_IMAGE")
            if not kernel_dir:
                raise WicError("Couldn't find DEPLOY_DIR_IMAGE, exiting")

        hdddir = "%s/hdd/boot" % cr_workdir

        # Install xen.efi as the default EFI boot application
        machine = get_bitbake_var("MACHINE")
        xen_efi = "xen-%s.efi" % machine
        xen_src = os.path.join(kernel_dir, xen_efi)
        if not os.path.exists(xen_src):
            raise WicError("Xen EFI binary not found: %s" % xen_src)

        install_cmd = "install -m 0644 %s %s/EFI/BOOT/bootx64.efi" % \
            (xen_src, hdddir)
        exec_cmd(install_cmd)

        # Install dom0 kernel alongside xen.efi — xen.efi resolves paths
        # in bootx64.cfg relative to its own directory (EFI/BOOT/)
        kernel = get_bitbake_var("KERNEL_IMAGETYPE")
        if get_bitbake_var("INITRAMFS_IMAGE_BUNDLE") == "1":
            if get_bitbake_var("INITRAMFS_IMAGE"):
                kernel = "%s-%s.bin" % \
                    (get_bitbake_var("KERNEL_IMAGETYPE"),
                     get_bitbake_var("INITRAMFS_LINK_NAME"))

        install_cmd = "install -m 0644 %s/%s %s/EFI/BOOT/%s" % \
            (kernel_dir, kernel, hdddir, kernel)
        exec_cmd(install_cmd)

        # Install initrd files if specified
        initrd = source_params.get('initrd')
        if initrd:
            initrds = initrd.split(';')
            for rd in initrds:
                install_cmd = "install -m 0644 %s/%s %s/EFI/BOOT/%s" % \
                    (kernel_dir, rd, hdddir, os.path.basename(rd))
                exec_cmd(install_cmd)

        # Create FAT filesystem for the ESP
        du_cmd = "du --apparent-size -ks %s" % hdddir
        out = exec_cmd(du_cmd)
        blocks = int(out.split()[0])

        extra_blocks = part.get_extra_block_count(blocks)
        if extra_blocks < BOOTDD_EXTRA_SPACE:
            extra_blocks = BOOTDD_EXTRA_SPACE

        blocks += extra_blocks

        if blocks < part.fixed_size:
            blocks = part.fixed_size

        logger.debug("Added %d extra blocks to %s to get to %d total blocks",
                     extra_blocks, part.mountpoint, blocks)

        bootimg = "%s/boot.img" % cr_workdir
        label = part.label if part.label else "ESP"

        sector_size = getattr(creator, 'sector_size', 512)
        dosfs_cmd = "mkdosfs -v -n %s -i %s -S %d -C %s %d" % \
                    (label, part.fsuuid, sector_size, bootimg, blocks)
        exec_native_cmd(dosfs_cmd, native_sysroot)

        mcopy_cmd = "mcopy -v -p -i %s -s %s/* ::/" % (bootimg, hdddir)
        exec_native_cmd(mcopy_cmd, native_sysroot)

        chmod_cmd = "chmod 644 %s" % bootimg
        exec_cmd(chmod_cmd)

        du_cmd = "du --apparent-size -Lks %s" % bootimg
        out = exec_cmd(du_cmd)
        bootimg_size = out.split()[0]

        part.size = int(bootimg_size)
        part.source_file = bootimg
