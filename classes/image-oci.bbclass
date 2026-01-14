#
# This image class creates an oci image spec directory from a generated
# rootfs. The contents of the rootfs do not matter (i.e. they need not be
# container optimized), but by using the container image type and small
# footprint images, we can create directly executable container images.
#
# Once the tarball (or oci image directory) has been created of the OCI
# image, it can be manipulated by standard tools. For example, to create a
# runtime bundle from the oci image, the following can be done:
#
# Assuming the image name is "container-base":
#
#   If the oci image was a tarball, extract it (skip, if a directory is being directly used)
#     % tar xvf container-base-<arch>-<stamp>.rootfs-oci-latest-x86_64-linux.oci-image.tar
#
#   And then create the bundle:
#     % oci-image-tool create --ref name=latest container-base-<arch>-<stamp>.rootfs-oci container-base-oci-bundle
#
#   Alternatively, the bundle can be created with umoci (use --rootless if sudo is not available)
#     % sudo umoci unpack --image container-base-<arch>-<stamp>.rootfs-oci:latest container-base-oci-bundle
#
#   Or to copy (push) the oci image to a docker registry, skopeo can be used (vary the
#   tag based on the created oci image:
#
#     % skopeo copy --dest-creds <username>:<password> oci:container-base-<arch>-<stamp>:latest docker://zeddii/container-base
#
#   If your build host architecture matches the target, you can execute the unbundled
#   container with runc:
#
#     % sudo runc run -b container-base-oci-bundle ctr-build
# / % uname -a
# Linux mrsdalloway 4.18.0-25-generic #26-Ubuntu SMP Mon Jun 24 09:32:08 UTC 2019 x86_64 GNU/Linux
#

# We'd probably get this through the container image typdep, but just
# to be sure, we'll repeat it here.
ROOTFS_BOOTSTRAP_INSTALL = ""
# we want container and tar.bz2's to be created
IMAGE_TYPEDEP:oci = "container tar.bz2"

# sloci is the script/project that will create the oci image
# OCI_IMAGE_BACKEND ?= "sloci-image"
OCI_IMAGE_BACKEND ?= "umoci"
do_image_oci[depends] += "${OCI_IMAGE_BACKEND}-native:do_populate_sysroot"
# jq-native is needed for the merged-usr whiteout fix
do_image_oci[depends] += "jq-native:do_populate_sysroot"

#
# image type configuration block
#
OCI_IMAGE_AUTHOR ?= "${PATCH_GIT_USER_NAME}"
OCI_IMAGE_AUTHOR_EMAIL ?= "${PATCH_GIT_USER_EMAIL}"

OCI_IMAGE_TAG ?= "latest"
OCI_IMAGE_RUNTIME_UID ?= ""

OCI_IMAGE_ARCH ?= "${@oe.go.map_arch(d.getVar('TARGET_ARCH'))}"
OCI_IMAGE_SUBARCH ?= "${@oci_map_subarch(d.getVar('TARGET_ARCH'), d.getVar('TUNE_FEATURES'), d)}"

# OCI_IMAGE_ENTRYPOINT: If set, this command always runs (args appended).
# OCI_IMAGE_CMD: Default command (replaced when user passes arguments).
# Most base images use CMD only for flexibility. Use ENTRYPOINT for wrapper scripts.
OCI_IMAGE_ENTRYPOINT ?= ""
OCI_IMAGE_ENTRYPOINT_ARGS ?= ""
OCI_IMAGE_CMD ?= "/bin/sh"
OCI_IMAGE_WORKINGDIR ?= ""
OCI_IMAGE_STOPSIGNAL ?= ""

# List of ports to expose from a container running this image:
#  PORT[/PROT]  
#     format: <port>/tcp, <port>/udp, or <port> (same as <port>/tcp).
OCI_IMAGE_PORTS ?= ""

# key=value list of labels (user-defined)
OCI_IMAGE_LABELS ?= ""
# key=value list of environment variables
OCI_IMAGE_ENV_VARS ?= ""

# =============================================================================
# Build-time metadata for traceability
# =============================================================================
#
# These variables embed source info into OCI image labels for traceability.
# Standard OCI annotations are used: https://github.com/opencontainers/image-spec/blob/main/annotations.md
#
# OCI_IMAGE_APP_RECIPE: Recipe name for the "main application" in the container.
#   If set, future versions may auto-extract SRCREV/branch from this recipe.
#   For now, it's documentation and a hook point.
#
# OCI_IMAGE_REVISION: Git commit SHA (short or full).
#   - If set: uses this value
#   - If empty: auto-detects from TOPDIR git repo
#   - Set to "none" to disable
#
# OCI_IMAGE_BRANCH: Git branch name.
#   - If set: uses this value
#   - If empty: auto-detects from TOPDIR git repo
#   - Set to "none" to disable
#
# OCI_IMAGE_BUILD_DATE: ISO 8601 timestamp.
#   - Auto-generated at build time
#
# These become standard OCI labels:
#   org.opencontainers.image.revision = OCI_IMAGE_REVISION
#   org.opencontainers.image.ref.name = OCI_IMAGE_BRANCH
#   org.opencontainers.image.created = OCI_IMAGE_BUILD_DATE
#   org.opencontainers.image.version = PV (if meaningful)

# Application recipe for traceability (documentation/future use)
OCI_IMAGE_APP_RECIPE ?= ""

# Explicit overrides - if set, these are used instead of auto-detection
# Set to "none" to disable a specific label
OCI_IMAGE_REVISION ?= ""
OCI_IMAGE_BRANCH ?= ""
OCI_IMAGE_BUILD_DATE ?= ""

# Enable/disable auto-detection of git metadata (set to "0" to disable)
OCI_IMAGE_AUTO_LABELS ?= "1"

# =============================================================================
# Multi-Layer OCI Support
# =============================================================================
#
# OCI_BASE_IMAGE: Base image to build on top of
#   - Recipe name: "container-base" (uses local recipe's OCI output)
#   - Path: "/path/to/oci-dir" (uses existing OCI layout)
#   - Registry URL: "docker.io/library/alpine:3.19" (fetches external image)
#
# OCI_LAYER_MODE: How to create layers
#   - "single" (default): Single layer with complete rootfs (backward compatible)
#   - "multi": Multiple layers from OCI_LAYERS definitions
#
# When OCI_BASE_IMAGE is set:
#   - Base image layers are preserved
#   - New content from IMAGE_ROOTFS is added as additional layer(s)
#
OCI_BASE_IMAGE ?= ""
OCI_BASE_IMAGE_TAG ?= "latest"
OCI_LAYER_MODE ?= "single"

# whether the oci image dir should be left as a directory, or
# bundled into a tarball.
OCI_IMAGE_TAR_OUTPUT ?= "true"

# Generate a subarch that is appropriate to OCI image
# types. This is typically only ARM architectures at the
# moment.
def oci_map_subarch(a, f, d):
    import re
    if re.match('arm.*', a):
        if 'armv7' in f:
            return 'v7'
        elif 'armv6' in f:
            return 'v6'
        elif 'armv5' in f:
            return 'v5'
            return ''
    return ''

# =============================================================================
# Base Image Resolution and Dependency Setup
# =============================================================================

def oci_resolve_base_image(d):
    """Resolve OCI_BASE_IMAGE to determine its type.

    Returns dict with 'type' key:
      - {'type': 'recipe', 'name': 'container-base'}
      - {'type': 'path', 'path': '/path/to/oci-dir'}
      - {'type': 'remote', 'url': 'docker.io/library/alpine:3.19'}
      - None if no base image
    """
    base = d.getVar('OCI_BASE_IMAGE') or ''
    if not base:
        return None

    # Check if it's a path (starts with /)
    if base.startswith('/'):
        return {'type': 'path', 'path': base}

    # Check if it looks like a registry URL (contains / or has registry prefix)
    if '/' in base or '.' in base.split(':')[0]:
        return {'type': 'remote', 'url': base}

    # Assume it's a recipe name
    return {'type': 'recipe', 'name': base}

python __anonymous() {
    import os

    backend = d.getVar('OCI_IMAGE_BACKEND') or 'umoci'
    base_image = d.getVar('OCI_BASE_IMAGE') or ''
    layer_mode = d.getVar('OCI_LAYER_MODE') or 'single'

    # sloci doesn't support multi-layer
    if backend == 'sloci-image':
        if layer_mode != 'single' or base_image:
            bb.fatal("Multi-layer OCI requires umoci backend. "
                     "Set OCI_IMAGE_BACKEND = 'umoci' or remove OCI_BASE_IMAGE")

    # Resolve base image and set up dependencies
    if base_image:
        resolved = oci_resolve_base_image(d)
        if resolved:
            if resolved['type'] == 'recipe':
                # Add dependency on base recipe's OCI output
                # Use do_build as it works for both image recipes and oci-fetch recipes
                base_recipe = resolved['name']
                d.setVar('_OCI_BASE_RECIPE', base_recipe)
                d.appendVarFlag('do_image_oci', 'depends',
                    f" {base_recipe}:do_build rsync-native:do_populate_sysroot")
                bb.debug(1, f"OCI: Using base image from recipe: {base_recipe}")

            elif resolved['type'] == 'path':
                d.setVar('_OCI_BASE_PATH', resolved['path'])
                d.appendVarFlag('do_image_oci', 'depends',
                    " rsync-native:do_populate_sysroot")
                bb.debug(1, f"OCI: Using base image from path: {resolved['path']}")

            elif resolved['type'] == 'remote':
                # Remote URLs are not supported directly - use a container-bundle recipe
                remote_url = resolved['url']
                # Create sanitized key for CONTAINER_DIGESTS varflag
                sanitized_key = remote_url.replace('/', '_').replace(':', '_')
                bb.fatal(f"Remote base images cannot be used directly: {remote_url}\n\n"
                         f"Create a container-bundle recipe to fetch the external image:\n\n"
                         f"  # recipes-containers/oci-base-images/my-base.bb\n"
                         f"  inherit container-bundle\n"
                         f"  CONTAINER_BUNDLES = \"{remote_url}\"\n"
                         f"  CONTAINER_DIGESTS[{sanitized_key}] = \"sha256:...\"\n"
                         f"  CONTAINER_BUNDLE_DEPLOY = \"1\"\n\n"
                         f"Get digest with: skopeo inspect docker://{remote_url} | jq -r '.Digest'\n\n"
                         f"Then use: OCI_BASE_IMAGE = \"my-base\"")
}

# the IMAGE_CMD:oci comes from the .inc
OCI_IMAGE_BACKEND_INC ?= "${@"image-oci-" + "${OCI_IMAGE_BACKEND}" + ".inc"}"
include ${OCI_IMAGE_BACKEND_INC}

