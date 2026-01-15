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
#   - Skips entirely if DOCKER_REGISTRY_INSECURE is not set
#   - Creates /etc/docker/daemon.json (will be merged if docker recipe
#     also creates one, or may need RCONFLICTS handling)
#
# Usage:
#   # In local.conf or image recipe:
#   DOCKER_REGISTRY_INSECURE = "10.0.2.2:5000 myregistry.local:5000"
#   IMAGE_FEATURES += "container-registry"
#
#   The IMAGE_FEATURES mechanism auto-selects this recipe for Docker
#   or container-oci-registry-config for Podman/CRI-O based on
#   VIRTUAL-RUNTIME_container_engine.
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
# Can also use runtime-agnostic CONTAINER_REGISTRY_URL + CONTAINER_REGISTRY_INSECURE
DOCKER_REGISTRY_INSECURE ?= ""
CONTAINER_REGISTRY_URL ?= ""
CONTAINER_REGISTRY_INSECURE ?= ""

def get_insecure_registries(d):
    """Get insecure registries from either Docker-specific or generic config"""
    # Prefer explicit DOCKER_REGISTRY_INSECURE if set
    docker_insecure = d.getVar('DOCKER_REGISTRY_INSECURE') or ""
    if docker_insecure.strip():
        return docker_insecure.strip()
    # Fall back to CONTAINER_REGISTRY_URL if marked insecure
    registry_url = d.getVar('CONTAINER_REGISTRY_URL') or ""
    is_insecure = d.getVar('CONTAINER_REGISTRY_INSECURE') or ""
    if registry_url.strip() and is_insecure in ['1', 'true', 'yes']:
        return registry_url.strip()
    return ""

inherit allarch

# Skip recipe entirely if not configured
python() {
    registries = get_insecure_registries(d)
    if not registries:
        raise bb.parse.SkipRecipe("No insecure registry configured - recipe is opt-in only")
}

python do_install() {
    import os
    import json

    registries = get_insecure_registries(d).split()

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
