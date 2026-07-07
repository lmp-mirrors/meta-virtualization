# Add chain module for Xen EFI boot on x86-64 and disable shim lock
# so GRUB can chainload the unsigned xen.efi binary.
GRUB_BUILDIN:append:x86-64 = "${@' chain' if bb.utils.contains('DISTRO_FEATURES', 'xen', True, False, d) else ''}"
GRUB_MKIMAGE_OPTS:append:x86-64 = "${@' --disable-shim-lock' if bb.utils.contains('DISTRO_FEATURES', 'xen', True, False, d) else ''}"
