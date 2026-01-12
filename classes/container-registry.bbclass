# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# container-registry.bbclass
# ===========================================================================
# Container registry operations for pushing OCI images to registries
# ===========================================================================
#
# This class provides functions to push OCI images from the deploy directory
# to a container registry. It works with docker-distribution, Docker Hub,
# or any OCI-compliant registry.
#
# Usage:
#   inherit container-registry
#
#   # In do_populate_registry task:
#   container_registry_push(d, oci_path, image_name)
#
# Configuration:
#   CONTAINER_REGISTRY_URL = "localhost:5000"      # Registry endpoint
#   CONTAINER_REGISTRY_NAMESPACE = "yocto"         # Image namespace
#   CONTAINER_REGISTRY_TLS_VERIFY = "false"        # TLS verification
#   CONTAINER_REGISTRY_TAG_STRATEGY = "timestamp latest"  # Tag generation
#   CONTAINER_REGISTRY_STORAGE = "${TOPDIR}/container-registry"  # Persistent storage
#
# ===========================================================================

# Registry configuration
CONTAINER_REGISTRY_URL ?= "localhost:5000"
CONTAINER_REGISTRY_NAMESPACE ?= "yocto"
CONTAINER_REGISTRY_TLS_VERIFY ?= "false"
CONTAINER_REGISTRY_TAG_STRATEGY ?= "timestamp latest"

# Storage location for registry data (default: outside tmp/, persists across builds)
# Set in local.conf to customize, e.g.:
#   CONTAINER_REGISTRY_STORAGE = "/data/container-registry"
#   CONTAINER_REGISTRY_STORAGE = "${TOPDIR}/../container-registry"
CONTAINER_REGISTRY_STORAGE ?= "${TOPDIR}/container-registry"

# Require skopeo-native for registry operations
DEPENDS += "skopeo-native"

def container_registry_generate_tags(d, image_name):
    """Generate tags based on CONTAINER_REGISTRY_TAG_STRATEGY.

    Strategies:
        timestamp - YYYYMMDD-HHMMSS format
        git       - Short git hash if in git repo
        version   - PV from recipe or image name
        latest    - Always includes 'latest' tag
        arch      - Appends architecture suffix

    Returns list of tags to apply.
    """
    import datetime
    import subprocess

    strategy = (d.getVar('CONTAINER_REGISTRY_TAG_STRATEGY') or 'latest').split()
    tags = []

    for strat in strategy:
        if strat == 'timestamp':
            ts = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
            tags.append(ts)
        elif strat == 'git':
            try:
                git_hash = subprocess.check_output(
                    ['git', 'rev-parse', '--short', 'HEAD'],
                    stderr=subprocess.DEVNULL,
                    cwd=d.getVar('TOPDIR')
                ).decode().strip()
                if git_hash:
                    tags.append(git_hash)
            except (subprocess.CalledProcessError, FileNotFoundError):
                pass
        elif strat == 'version':
            pv = d.getVar('PV')
            if pv and pv != '1.0':
                tags.append(pv)
        elif strat == 'latest':
            tags.append('latest')
        elif strat == 'arch':
            arch = d.getVar('TARGET_ARCH') or d.getVar('BUILD_ARCH')
            if arch:
                # Add arch suffix to existing tags
                arch_tags = [f"{t}-{arch}" for t in tags if t != 'latest']
                tags.extend(arch_tags)

    # Ensure at least one tag
    if not tags:
        tags = ['latest']

    return tags

def container_registry_push(d, oci_path, image_name, tags=None):
    """Push an OCI image to the configured registry.

    Args:
        d: BitBake datastore
        oci_path: Path to OCI directory (containing index.json)
        image_name: Name for the image (without registry/namespace)
        tags: Optional list of tags (default: generated from strategy)

    Returns:
        List of pushed image references (registry/namespace/name:tag)
    """
    import os
    import subprocess

    registry = d.getVar('CONTAINER_REGISTRY_URL')
    namespace = d.getVar('CONTAINER_REGISTRY_NAMESPACE')
    tls_verify = d.getVar('CONTAINER_REGISTRY_TLS_VERIFY')

    # Find skopeo in native sysroot
    staging_sbindir = d.getVar('STAGING_SBINDIR_NATIVE')
    skopeo = os.path.join(staging_sbindir, 'skopeo')

    if not os.path.exists(skopeo):
        bb.fatal(f"skopeo not found at {skopeo} - ensure skopeo-native is built")

    # Validate OCI directory
    index_json = os.path.join(oci_path, 'index.json')
    if not os.path.exists(index_json):
        bb.fatal(f"Invalid OCI directory: {oci_path} (missing index.json)")

    # Generate tags if not provided
    if tags is None:
        tags = container_registry_generate_tags(d, image_name)

    pushed = []
    src = f"oci:{oci_path}"

    for tag in tags:
        dest = f"docker://{registry}/{namespace}/{image_name}:{tag}"

        cmd = [skopeo, 'copy']
        if tls_verify == 'false':
            cmd.append('--dest-tls-verify=false')
        cmd.extend([src, dest])

        bb.note(f"Pushing {image_name}:{tag} to {registry}/{namespace}/")

        try:
            subprocess.check_call(cmd)
            pushed.append(f"{registry}/{namespace}/{image_name}:{tag}")
            bb.note(f"Successfully pushed {dest}")
        except subprocess.CalledProcessError as e:
            bb.error(f"Failed to push {dest}: {e}")

    return pushed

def container_registry_discover_oci_images(d):
    """Discover OCI images in the deploy directory.

    Finds directories matching *-oci or *-latest-oci patterns
    that contain valid OCI layouts (index.json).

    Returns:
        List of tuples: (oci_path, image_name)
    """
    import os

    deploy_dir = d.getVar('DEPLOY_DIR_IMAGE')
    if not deploy_dir or not os.path.isdir(deploy_dir):
        return []

    images = []

    for entry in os.listdir(deploy_dir):
        # Match *-oci or *-latest-oci directories
        if not (entry.endswith('-oci') or entry.endswith('-latest-oci')):
            continue

        oci_path = os.path.join(deploy_dir, entry)
        if not os.path.isdir(oci_path):
            continue

        # Verify valid OCI layout
        if not os.path.exists(os.path.join(oci_path, 'index.json')):
            continue

        # Extract image name from directory name
        # container-base-qemux86-64.rootfs-20260108.rootfs-oci -> container-base
        # container-base-latest-oci -> container-base
        name = entry
        for suffix in ['-latest-oci', '-oci']:
            if name.endswith(suffix):
                name = name[:-len(suffix)]
                break

        # Remove machine suffix if present (e.g., -qemux86-64)
        machine = d.getVar('MACHINE')
        if machine and f'-{machine}' in name:
            name = name.split(f'-{machine}')[0]

        # Remove rootfs timestamp suffix (e.g., .rootfs-20260108)
        if '.rootfs-' in name:
            name = name.split('.rootfs-')[0]

        images.append((oci_path, name))

    return images
