# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# xen-guest-bundle.bbclass
# ===========================================================================
# Xen guest bundling class for creating installable guest packages
# ===========================================================================
#
# This class creates packages that bundle Xen guest images (rootfs + kernel +
# config). When these packages are installed via IMAGE_INSTALL into a Dom0
# image that inherits xen-guest-cross-install, the guests are automatically
# merged into the target image by merge_installed_xen_bundles().
#
# ===========================================================================
# Component Relationships
# ===========================================================================
#
# To bundle a guest like "xen-guest-image-minimal:autostart", two recipe
# types work together:
#
#   1. Guest Image Recipe (creates the guest rootfs)
#      recipes-extended/images/xen-guest-image-minimal.bb
#      +-- inherit core-image
#      +-- Produces: ${DEPLOY_DIR_IMAGE}/xen-guest-image-minimal-${MACHINE}.ext4
#
#   2. Bundle Recipe (packages guest images for deployment)
#      recipes-extended/xen-guest-bundles/my-bundle_1.0.bb
#      +-- inherit xen-guest-bundle
#      +-- XEN_GUEST_BUNDLES = "xen-guest-image-minimal:autostart"
#      +-- Creates installable package with rootfs, kernel, and config
#
# Flow diagram:
#
#   xen-guest-image-minimal.bb
#   (guest image recipe)
#        |
#        | do_image_complete
#        v
#   ${DEPLOY_DIR_IMAGE}/xen-guest-image-minimal-${MACHINE}.ext4
#        |
#        | XEN_GUEST_BUNDLES="xen-guest-image-minimal"
#        v
#   my-bundle_1.0.bb --------> my-bundle package
#   (inherits xen-guest-bundle)    |
#                                  | IMAGE_INSTALL="my-bundle"
#                                  v
#                           xen-image-minimal
#                           (Dom0 host image)
#
# ===========================================================================
# When to Use This Class vs BUNDLED_XEN_GUESTS
# ===========================================================================
#
# There are two ways to bundle Xen guests into a host image:
#
#   1. BUNDLED_XEN_GUESTS variable (simpler, no extra recipe needed)
#      Set in local.conf or image recipe:
#        BUNDLED_XEN_GUESTS = "xen-guest-image-minimal:autostart"
#
#   2. xen-guest-bundle packages (this class)
#      Create a bundle recipe, install via IMAGE_INSTALL
#
# Decision guide:
#
#   Use Case                                    | BUNDLED_XEN_GUESTS | Bundle Recipe
#   --------------------------------------------|--------------------|--------------
#   Simple: guests in one host image            | recommended        | overkill
#   Reuse guests across multiple host images    | repetitive         | recommended
#   Package versioning and dependencies         | not supported      | supported
#   Distribute pre-built guest sets             | not supported      | supported
#
# For most single-image use cases, BUNDLED_XEN_GUESTS is simpler.
#
# ===========================================================================
# Usage
# ===========================================================================
#
#   inherit xen-guest-bundle
#
#   XEN_GUEST_BUNDLES = "\
#       xen-guest-image-minimal:autostart \
#       my-other-guest \
#   "
#
# Variable format: recipe-name[:autostart][:external]
#   - recipe-name: Yocto image recipe name that produces the guest rootfs
#   - autostart: Optional. Creates symlink in /etc/xen/auto/ for xendomains
#   - external: Optional. Skip dependency generation (3rd-party guest)
#
# Per-guest configuration via varflags (same interface as cross-install):
#   XEN_GUEST_MEMORY[guest-name] = "1024"
#   XEN_GUEST_VCPUS[guest-name] = "2"
#   XEN_GUEST_VIF[guest-name] = "bridge=xenbr0"
#   XEN_GUEST_EXTRA[guest-name] = "root=/dev/xvda ro console=hvc0 ip=dhcp"
#   XEN_GUEST_DISK_DEVICE[guest-name] = "xvda"
#   XEN_GUEST_NAME[guest-name] = "my-custom-name"
#
# Custom config file (replaces auto-generation entirely):
#   SRC_URI += "file://custom.cfg"
#   XEN_GUEST_CONFIG_FILE[guest-name] = "${UNPACKDIR}/custom.cfg"
#
# Explicit rootfs/kernel paths (for external/3rd-party guests):
#   XEN_GUEST_ROOTFS[my-vendor-guest] = "vendor-rootfs.ext4"
#   XEN_GUEST_KERNEL[my-vendor-guest] = "vendor-kernel"
#
# ===========================================================================
# Integration with xen-guest-cross-install.bbclass
# ===========================================================================
#
# This class creates packages that are processed by xen-guest-cross-install:
#   1. Installs guest files to ${datadir}/xen-guest-bundles/${PN}/
#   2. merge_installed_xen_bundles() copies them to final locations at image time
#   3. Bundle files are removed from the final image after merge
#
# See also: xen-guest-cross-install.bbclass

XEN_GUEST_BUNDLES ?= ""
XEN_GUEST_IMAGE_FSTYPE ?= "ext4"
XEN_GUEST_MEMORY_DEFAULT ?= "512"
XEN_GUEST_VCPUS_DEFAULT ?= "1"
XEN_GUEST_VIF_DEFAULT ?= "bridge=xenbr0"
XEN_GUEST_EXTRA_DEFAULT ?= "root=/dev/xvda ro ip=dhcp"
XEN_GUEST_DISK_DEVICE_DEFAULT ?= "xvda"

# ===========================================================================
# Parse-time dependency generation
# ===========================================================================

python __anonymous() {
    bundles = (d.getVar('XEN_GUEST_BUNDLES') or "").split()
    if not bundles:
        return

    processed = []
    deps = ""

    for entry in bundles:
        parts = entry.split(':')
        guest_name = parts[0]

        is_external = 'external' in parts
        is_autostart = 'autostart' in parts

        # Generate dependency on guest recipe (unless external)
        if not is_external:
            deps += " %s:do_image_complete" % guest_name

        # Store processed entry: guest_name:autostart_flag
        autostart_flag = "autostart" if is_autostart else ""
        processed.append("%s:%s" % (guest_name, autostart_flag))

    if deps:
        d.appendVarFlag('do_compile', 'depends', deps)

    d.setVar('_PROCESSED_XEN_BUNDLES', ' '.join(processed))

    # Build config file map from varflags
    # Format: guest1=/path/to/file1;guest2=/path/to/file2
    config_mappings = []
    for entry in bundles:
        guest_name = entry.split(':')[0]
        custom_file = d.getVarFlag('XEN_GUEST_CONFIG_FILE', guest_name)
        if custom_file:
            config_mappings.append("%s=%s" % (guest_name, custom_file))
    d.setVar('_XEN_GUEST_CONFIG_FILE_MAP', ';'.join(config_mappings))

    # Build params map from varflags
    # Format: guest1=memory|vcpus|vif|extra|disk_device|name|rootfs|kernel;guest2=...
    mem_default = d.getVar('XEN_GUEST_MEMORY_DEFAULT')
    vcpus_default = d.getVar('XEN_GUEST_VCPUS_DEFAULT')
    vif_default = d.getVar('XEN_GUEST_VIF_DEFAULT')
    extra_default = d.getVar('XEN_GUEST_EXTRA_DEFAULT')
    disk_default = d.getVar('XEN_GUEST_DISK_DEVICE_DEFAULT')

    param_mappings = []
    for entry in bundles:
        guest_name = entry.split(':')[0]

        memory = d.getVarFlag('XEN_GUEST_MEMORY', guest_name) or mem_default
        vcpus = d.getVarFlag('XEN_GUEST_VCPUS', guest_name) or vcpus_default
        vif = d.getVarFlag('XEN_GUEST_VIF', guest_name) or vif_default
        extra = d.getVarFlag('XEN_GUEST_EXTRA', guest_name) or extra_default
        disk_device = d.getVarFlag('XEN_GUEST_DISK_DEVICE', guest_name) or disk_default
        name = d.getVarFlag('XEN_GUEST_NAME', guest_name) or guest_name
        rootfs = d.getVarFlag('XEN_GUEST_ROOTFS', guest_name) or ""
        kernel = d.getVarFlag('XEN_GUEST_KERNEL', guest_name) or ""

        params = "|".join([memory, vcpus, vif, extra, disk_device, name, rootfs, kernel])
        param_mappings.append("%s=%s" % (guest_name, params))

    d.setVar('_XEN_GUEST_PARAMS_MAP', ';'.join(param_mappings))
}

S = "${UNPACKDIR}/sources"
B = "${WORKDIR}/build"

do_patch[noexec] = "1"
do_configure[noexec] = "1"

# ===========================================================================
# do_compile: resolve guests and generate configs
# ===========================================================================

do_compile() {
    set -e

    mkdir -p "${S}"
    rm -rf "${B}/images" "${B}/configs"
    mkdir -p "${B}/images"
    mkdir -p "${B}/configs"

    # Clear manifest
    : > "${B}/manifest"

    if [ -z "${_PROCESSED_XEN_BUNDLES}" ]; then
        bbnote "No Xen guest bundles to process"
        return 0
    fi

    bbnote "Processing Xen guest bundles: ${_PROCESSED_XEN_BUNDLES}"

    for bundle in ${_PROCESSED_XEN_BUNDLES}; do
        guest_name=$(echo "$bundle" | cut -d: -f1)
        autostart_flag=$(echo "$bundle" | cut -d: -f2)

        bbnote "Processing guest: $guest_name (autostart=$autostart_flag)"

        # Resolve rootfs
        rootfs_path=$(resolve_bundle_rootfs "$guest_name")
        if [ -z "$rootfs_path" ]; then
            bbfatal "Cannot resolve rootfs for guest '$guest_name'"
        fi
        rootfs_basename=$(basename "$rootfs_path")

        # Resolve kernel
        kernel_path=$(resolve_bundle_kernel "$guest_name")
        if [ -z "$kernel_path" ]; then
            bbfatal "Cannot resolve kernel for guest '$guest_name'"
        fi
        kernel_basename=$(basename "$kernel_path")

        # Copy to build dir (readlink -f resolves versioned symlinks)
        cp "$(readlink -f "$rootfs_path")" "${B}/images/${rootfs_basename}"
        cp "$(readlink -f "$kernel_path")" "${B}/images/${kernel_basename}"

        # Generate or install config
        config_map="${_XEN_GUEST_CONFIG_FILE_MAP}"
        custom_config=$(echo "$config_map" | tr ';' '\n' | grep "^${guest_name}=" | cut -d= -f2-)

        if [ -n "$custom_config" ] && [ -f "$custom_config" ]; then
            bbnote "Installing custom config: $custom_config"
            sed -E \
                -e "s#^(disk = \[)[^,]+#\1'file:/var/lib/xen/images/$rootfs_basename#" \
                -e "s#^(kernel = )\"[^\"]+\"#\1\"/var/lib/xen/images/$kernel_basename\"#" \
                "$custom_config" > "${B}/configs/${guest_name}.cfg"
        else
            bbnote "Generating config for $guest_name"
            generate_bundle_config "$guest_name" "$rootfs_basename" "$kernel_basename" \
                "${B}/configs/${guest_name}.cfg"
        fi

        # Write manifest entry: guest_name:rootfs_file:kernel_file:autostart_flag
        echo "${guest_name}:${rootfs_basename}:${kernel_basename}:${autostart_flag}" >> "${B}/manifest"

        bbnote "Guest '$guest_name' compiled successfully"
    done
}

# Resolve guest rootfs path from DEPLOY_DIR_IMAGE
resolve_bundle_rootfs() {
    local guest="$1"
    local params_map="${_XEN_GUEST_PARAMS_MAP}"

    # Check for explicit rootfs override (field 6)
    local guest_params=$(echo "$params_map" | tr ';' '\n' | grep "^${guest}=" | cut -d= -f2-)
    local override=""
    if [ -n "$guest_params" ]; then
        override=$(echo "$guest_params" | cut -d'|' -f7)
    fi

    if [ -n "$override" ]; then
        local path="${DEPLOY_DIR_IMAGE}/$override"
        if [ -e "$path" ]; then
            echo "$path"
            return 0
        fi
        bbwarn "XEN_GUEST_ROOTFS override '$override' not found at $path"
        return 1
    fi

    # Standard Yocto naming: <recipe>-<MACHINE>.<fstype>
    local path="${DEPLOY_DIR_IMAGE}/${guest}-${MACHINE}.${XEN_GUEST_IMAGE_FSTYPE}"
    if [ -e "$path" ]; then
        echo "$path"
        return 0
    fi

    # Fallback: <recipe>-<MACHINE>.rootfs.<fstype>
    path="${DEPLOY_DIR_IMAGE}/${guest}-${MACHINE}.rootfs.${XEN_GUEST_IMAGE_FSTYPE}"
    if [ -e "$path" ]; then
        echo "$path"
        return 0
    fi

    bbwarn "Guest rootfs not found for '$guest'. Searched:"
    bbwarn "  ${DEPLOY_DIR_IMAGE}/${guest}-${MACHINE}.${XEN_GUEST_IMAGE_FSTYPE}"
    bbwarn "  ${DEPLOY_DIR_IMAGE}/${guest}-${MACHINE}.rootfs.${XEN_GUEST_IMAGE_FSTYPE}"
    return 1
}

# Resolve guest kernel path from DEPLOY_DIR_IMAGE
resolve_bundle_kernel() {
    local guest="$1"
    local params_map="${_XEN_GUEST_PARAMS_MAP}"

    # Check for explicit kernel override (field 7)
    local guest_params=$(echo "$params_map" | tr ';' '\n' | grep "^${guest}=" | cut -d= -f2-)
    local override=""
    if [ -n "$guest_params" ]; then
        override=$(echo "$guest_params" | cut -d'|' -f8)
    fi

    if [ -n "$override" ]; then
        local path="${DEPLOY_DIR_IMAGE}/$override"
        if [ -e "$path" ]; then
            echo "$path"
            return 0
        fi
        bbwarn "XEN_GUEST_KERNEL override '$override' not found at $path"
        return 1
    fi

    # Default: shared kernel (same MACHINE)
    local path="${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE}"
    if [ -e "$path" ]; then
        echo "$path"
        return 0
    fi

    bbwarn "Guest kernel not found at ${DEPLOY_DIR_IMAGE}/${KERNEL_IMAGETYPE}"
    return 1
}

# Generate a Xen guest configuration file with final target paths
generate_bundle_config() {
    local guest="$1"
    local rootfs_basename="$2"
    local kernel_basename="$3"
    local outfile="$4"
    local params_map="${_XEN_GUEST_PARAMS_MAP}"

    # Extract params
    local guest_params=$(echo "$params_map" | tr ';' '\n' | grep "^${guest}=" | cut -d= -f2-)

    local memory=$(echo "$guest_params" | cut -d'|' -f1)
    local vcpus=$(echo "$guest_params" | cut -d'|' -f2)
    local vif=$(echo "$guest_params" | cut -d'|' -f3)
    local extra=$(echo "$guest_params" | cut -d'|' -f4)
    local disk_device=$(echo "$guest_params" | cut -d'|' -f5)
    local name=$(echo "$guest_params" | cut -d'|' -f6)

    cat > "$outfile" << EOF
name = "$name"
memory = $memory
vcpus = $vcpus
disk = ['file:/var/lib/xen/images/$rootfs_basename,$disk_device,rw']
vif = ['$vif']
kernel = "/var/lib/xen/images/$kernel_basename"
extra = "$extra"
EOF
}

# ===========================================================================
# do_install: package for merge_installed_xen_bundles
# ===========================================================================

do_install() {
    if [ ! -f "${B}/manifest" ] || [ ! -s "${B}/manifest" ]; then
        bbnote "No guests to install"
        return 0
    fi

    install -d ${D}${datadir}/xen-guest-bundles/${PN}/images
    install -d ${D}${datadir}/xen-guest-bundles/${PN}/configs

    # Install guest images
    if [ -d "${B}/images" ] && [ -n "$(ls -A ${B}/images 2>/dev/null)" ]; then
        cp ${B}/images/* ${D}${datadir}/xen-guest-bundles/${PN}/images/
    fi

    # Install guest configs
    if [ -d "${B}/configs" ] && [ -n "$(ls -A ${B}/configs 2>/dev/null)" ]; then
        cp ${B}/configs/* ${D}${datadir}/xen-guest-bundles/${PN}/configs/
    fi

    # Install manifest
    install -m 0644 ${B}/manifest ${D}${datadir}/xen-guest-bundles/${PN}/manifest
}

FILES:${PN} = "${datadir}/xen-guest-bundles"

# Guest rootfs images are binary filesystem images that contain build paths
# internally (normal for ext4/etc images) and can be large
INSANE_SKIP:${PN} += "installed-vs-shipped buildpaths"
