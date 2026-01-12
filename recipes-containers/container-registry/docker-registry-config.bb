# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
#
# docker-registry-config.bb
# ===========================================================================
# Configure custom container registry for Docker daemon (OPT-IN)
# ===========================================================================
#
# FOR DOCKER ONLY - creates /etc/docker/daemon.json
#
# NOT for Podman/Skopeo/Buildah - they use /etc/containers/registries.conf.d/
#   See: container-registry-config.bb for Podman/Skopeo/Buildah
#
# This recipe creates daemon.json for Docker to access insecure registries.
# It is completely OPT-IN and requires explicit configuration.
#
# NOTE: Docker does not support "default registry" like our vdkr transform.
# Users must still use fully qualified image names unless using Docker Hub.
# This config only handles insecure registry trust.
#
# IMPORTANT: This recipe:
#   - Does NOT install automatically - user must add to IMAGE_INSTALL
#   - Skips entirely if DOCKER_REGISTRY_INSECURE is not set
#   - Creates /etc/docker/daemon.json (will be merged if docker recipe
#     also creates one, or may need RCONFLICTS handling)
#
# Usage:
#   # In local.conf or image recipe:
#   DOCKER_REGISTRY_INSECURE = "10.0.2.2:5000 myregistry.local:5000"
#   IMAGE_INSTALL:append = " docker-registry-config"
#
# ===========================================================================

SUMMARY = "Configure insecure container registries for Docker daemon (opt-in)"
DESCRIPTION = "Creates /etc/docker/daemon.json with insecure-registries config. \
FOR DOCKER ONLY - not for Podman/Skopeo (use container-oci-registry-config for those). \
This recipe is opt-in: requires DOCKER_REGISTRY_INSECURE to be set. \
Use IMAGE_FEATURES container-registry to auto-select based on container engine."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Space-separated list of insecure registries
# Example: "10.0.2.2:5000 myregistry.local:5000"
DOCKER_REGISTRY_INSECURE ?= ""

inherit allarch

# Skip recipe entirely if not configured
python() {
    registries = d.getVar('DOCKER_REGISTRY_INSECURE')
    if not registries or not registries.strip():
        raise bb.parse.SkipRecipe("DOCKER_REGISTRY_INSECURE not set - recipe is opt-in only")
}

python do_install() {
    import os
    import json

    registries = d.getVar('DOCKER_REGISTRY_INSECURE').split()

    dest = d.getVar('D')
    confdir = os.path.join(dest, d.getVar('sysconfdir').lstrip('/'), 'docker')
    os.makedirs(confdir, exist_ok=True)

    config_path = os.path.join(confdir, 'daemon.json')

    # Create daemon.json
    config = {
        "insecure-registries": registries
    }

    with open(config_path, 'w') as f:
        json.dump(config, f, indent=2)
        f.write("\n")

    bb.note(f"Created Docker config with insecure registries: {registries}")
}

FILES:${PN} = "${sysconfdir}/docker/daemon.json"

# Docker must be installed for this to be useful
RDEPENDS:${PN} = "docker"
