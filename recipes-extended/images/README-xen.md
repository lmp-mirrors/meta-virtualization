This README contains information on the xen reference images
and testing / usability information

Images
------

xen-image-minimal:

This is the reference xen host image. It currently requires systemd
and xen as DISTRO_FEATURES.

All required dependencies are included for typical execution (and
debug) of guests.

xen-guest-image-minimal:

This is the reference guest / domU image. Note that it boots the
same kernel as the xen host image (unless multiconfig is used
to differentiate).

It creates tarballs, ext4 and qcow images for testing purposes.

Bundling
--------

There are two ways to bundle Xen guests into a Dom0 host image:

| Use Case | `BUNDLED_XEN_GUESTS` | Bundle Recipe |
|---|---|---|
| Simple: guests in one host image | recommended | overkill |
| Reuse guests across multiple host images | repetitive | recommended |
| Package versioning and dependencies | not supported | supported |
| Distribute pre-built guest sets | not supported | supported |

### Variable-driven (BUNDLED_XEN_GUESTS)

Guests can be bundled into the host image automatically using
`xen-guest-cross-install.bbclass` (inherited by xen-image-minimal).

Set `BUNDLED_XEN_GUESTS` in local.conf or the image recipe:

  BUNDLED_XEN_GUESTS = "xen-guest-image-minimal:autostart"

Each entry is a recipe name with optional tags:

  recipe-name[:autostart][:external]

  - recipe-name: Yocto image recipe that produces the guest rootfs
  - autostart: Creates symlink in /etc/xen/auto/ for xendomains
  - external: Skip dependency generation (3rd-party guest)

Examples:

  # Single guest with autostart (default recommendation)
  BUNDLED_XEN_GUESTS = "xen-guest-image-minimal:autostart"

  # Guest without autostart
  BUNDLED_XEN_GUESTS = "xen-guest-image-minimal"

  # External/3rd-party guest (no build dependency)
  BUNDLED_XEN_GUESTS = "my-vendor-guest:external"

Per-guest configuration via varflags:

  XEN_GUEST_MEMORY[xen-guest-image-minimal] = "1024"
  XEN_GUEST_VCPUS[xen-guest-image-minimal] = "2"
  XEN_GUEST_VIF[xen-guest-image-minimal] = "bridge=xenbr0"
  XEN_GUEST_EXTRA[xen-guest-image-minimal] = "root=/dev/xvda ro console=hvc0 ip=dhcp"

Custom config file (replaces auto-generation):

  SRC_URI += "file://my-custom-guest.cfg"
  BUNDLED_XEN_GUESTS = "xen-guest-image-minimal:autostart"
  XEN_GUEST_CONFIG_FILE[xen-guest-image-minimal] = "${UNPACKDIR}/my-custom-guest.cfg"

Explicit rootfs/kernel for external guests:

  XEN_GUEST_ROOTFS[my-vendor-guest] = "vendor-rootfs.ext4"
  XEN_GUEST_KERNEL[my-vendor-guest] = "vendor-kernel"

### Package-based (xen-guest-bundle.bbclass)

For reusable guest sets, create a bundle recipe that inherits
`xen-guest-bundle`:

  # recipes-extended/xen-guest-bundles/my-guests_1.0.bb
  inherit xen-guest-bundle

  XEN_GUEST_BUNDLES = "xen-guest-image-minimal:autostart"
  XEN_GUEST_MEMORY[xen-guest-image-minimal] = "1024"

Then install the bundle in the host image:

  IMAGE_INSTALL:append:pn-xen-image-minimal = " my-guests"

The bundle package includes rootfs, kernel, and config files. At
image time, `merge_installed_xen_bundles()` deploys them to the
same target locations as the variable-driven path.

Custom config files work the same way via SRC_URI + varflag:

  SRC_URI += "file://my-custom-guest.cfg"
  XEN_GUEST_CONFIG_FILE[xen-guest-image-minimal] = "${UNPACKDIR}/my-custom-guest.cfg"

See `example-xen-guest-bundle_1.0.bb` for a complete example.

### 3rd-party guest import

The import system converts fetched source formats (tarballs, qcow2 images,
etc.) into Xen-ready disk images at build time. This is for guests that
are not built by Yocto (e.g., Alpine minirootfs, Debian cloud images).

Per-guest varflags control the import:

  XEN_GUEST_SOURCE_TYPE[guest] = "rootfs_dir"   # import handler type
  XEN_GUEST_SOURCE_FILE[guest] = "alpine-rootfs" # file/dir in UNPACKDIR
  XEN_GUEST_IMAGE_SIZE[guest] = "128"            # target image size in MB

Built-in import types:

| Type | Input | Output | Tool |
|---|---|---|---|
| `rootfs_dir` | Extracted rootfs directory | ext4 image | `mkfs.ext4 -F -d` |
| `qcow2` | QCOW2 disk image | raw image | `qemu-img convert` |
| `ext4` | ext4 image file | ext4 (copy) | `cp` |
| `raw` | raw disk image | raw (copy) | `cp` |

Native tool dependencies are resolved automatically at parse time.

Kernel modes (per-guest via `XEN_GUEST_KERNEL` varflag):

  - (not set): Shared host kernel from DEPLOY_DIR_IMAGE
  - `"path"`: Custom kernel from UNPACKDIR or DEPLOY_DIR_IMAGE
  - `"none"`: HVM guest, no kernel (omits kernel= from config)

Alpine example (`alpine-xen-guest-bundle_3.23.bb`):

  inherit xen-guest-bundle

  SRC_URI = "https://...alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz;subdir=alpine-rootfs"

  XEN_GUEST_BUNDLES = "alpine:autostart:external"
  XEN_GUEST_SOURCE_TYPE[alpine] = "rootfs_dir"
  XEN_GUEST_SOURCE_FILE[alpine] = "alpine-rootfs"
  XEN_GUEST_IMAGE_SIZE[alpine] = "128"
  XEN_GUEST_MEMORY[alpine] = "256"
  XEN_GUEST_EXTRA[alpine] = "root=/dev/xvda ro console=hvc0"

Adding custom import types: define a shell function
`xen_guest_import_<type>(source_path, output_path, size_mb)` in a
bbclass, recipe, or bbappend and set the corresponding
`XEN_GUEST_IMPORT_DEPENDS_<type>` variable for native tool dependencies.

Target layout
-------------

kernel and rootfs are copied to the target in /var/lib/xen/images/

configuration files are copied to: /etc/xen

autostart symlinks are created in: /etc/xen/auto/

Guests can be launched after boot with: xl create -c /etc/xen/<guest>.cfg

Build and boot
--------------

Using a reference qemuarm64 MACHINE, the following are the commands
to build and boot a guest.

local.conf contains:

   BUNDLED_XEN_GUESTS = "xen-guest-image-minimal:autostart"

 % bitbake xen-guest-image-minimal
 % bitbake xen-image-minimal

 % runqemu qemuarm64 nographic slirp qemuparams="-m 4096"

Poky (Yocto Project Reference Distro) 5.1 qemuarm64 hvc0

qemuarm64 login: root

root@qemuarm64:~# ls /etc/xen/
auto
cpupool
scripts
xen-guest-image-minimal.cfg
xl.conf
root@qemuarm64:~# ls /var/lib/xen/images/
Image--6.10.11+git0+4bf82718cf_6c956b2ea6-r0-qemuarm64-20241018190311.bin
xen-guest-image-minimal-qemuarm64-20241111222814.ext4

 root@qemuarm64:~# xl create -c /etc/xen/xen-guest-image-minimal.cfg

qemuarm64 login: root

root@qemuarm64:~# uname -a
Linux qemuarm64 6.10.11-yocto-standard #1 SMP PREEMPT Fri Sep 20 22:32:26 UTC 2024 aarch64 GNU/Linux

From the host:

root@qemuarm64:~# xl list
Name                                        ID   Mem VCPUs      State   Time(s)
Domain-0                                     0   192     4     r-----     696.2
xen-guest-image-minimal                      1   512     1     -b----     153.0
root@qemuarm64:~# xl destroy xen-guest-image-minimal
