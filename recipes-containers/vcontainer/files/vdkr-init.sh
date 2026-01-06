#!/bin/sh
# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: GPL-2.0-only
#
# vdkr-init.sh
# Init script for vdkr: execute arbitrary docker commands in QEMU
#
# This script runs on a real ext4 filesystem after switch_root from initramfs.
# The preinit script mounted /dev/vda (rootfs.img) and did switch_root to us.
#
# Drive layout (rootfs.img is always /dev/vda, mounted as /):
#   /dev/vda = rootfs.img (this script runs from here, mounted as /)
#   /dev/vdb = input disk (optional, OCI/tar/dir data)
#   /dev/vdc = state disk (optional, persistent Docker storage)
#
# Kernel parameters:
#   docker_cmd=<base64>    Base64-encoded docker command + args
#   docker_input=<type>    Input type: none, oci, tar, dir (default: none)
#   docker_output=<type>   Output type: text, tar, storage (default: text)
#   docker_state=<type>    State type: none, disk (default: none)
#   docker_network=1       Enable networking (configure eth0, DNS)
#
# Version: 2.3.0

# Set runtime-specific parameters before sourcing common code
VCONTAINER_RUNTIME_NAME="vdkr"
VCONTAINER_RUNTIME_CMD="docker"
VCONTAINER_RUNTIME_PREFIX="docker"
VCONTAINER_STATE_DIR="/var/lib/docker"
VCONTAINER_SHARE_NAME="vdkr_share"
VCONTAINER_VERSION="2.3.0"

# Source common init functions
# When installed as /init, common file is at /vcontainer-init-common.sh
. /vcontainer-init-common.sh

# ============================================================================
# Docker-Specific Functions
# ============================================================================

setup_docker_storage() {
    mkdir -p /run/containerd /run/lock
    mkdir -p /var/lib/docker
    mkdir -p /var/lib/containerd

    # Handle Docker storage
    if [ -n "$STATE_DISK" ] && [ -b "$STATE_DISK" ]; then
        log "Mounting state disk $STATE_DISK as /var/lib/docker..."
        if mount -t ext4 "$STATE_DISK" /var/lib/docker 2>&1; then
            log "SUCCESS: Mounted $STATE_DISK as Docker storage"
            log "Docker storage contents:"
            [ "$QUIET_BOOT" = "0" ] && ls -la /var/lib/docker/ 2>/dev/null || log "(empty)"
        else
            log "WARNING: Failed to mount state disk, using tmpfs"
            RUNTIME_STATE="none"
        fi
    fi

    # If no state disk, use tmpfs for Docker storage
    if [ "$RUNTIME_STATE" != "disk" ]; then
        log "Using tmpfs for Docker storage (ephemeral)..."
        mount -t tmpfs -o size=1G tmpfs /var/lib/docker
    fi
}

start_containerd() {
    CONTAINERD_READY=false
    if [ -x "/usr/bin/containerd" ]; then
        log "Starting containerd..."
        mkdir -p /var/lib/containerd
        mkdir -p /run/containerd
        /usr/bin/containerd --log-level info --root /var/lib/containerd --state /run/containerd >/tmp/containerd.log 2>&1 &
        CONTAINERD_PID=$!
        # Wait for containerd socket
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if [ -S /run/containerd/containerd.sock ]; then
                log "Containerd running (PID: $CONTAINERD_PID)"
                CONTAINERD_READY=true
                break
            fi
            sleep 1
        done
        if [ "$CONTAINERD_READY" != "true" ]; then
            log "WARNING: Containerd failed to start, check /tmp/containerd.log"
            [ -f /tmp/containerd.log ] && cat /tmp/containerd.log >&2
        fi
    fi
}

start_dockerd() {
    log "Starting Docker daemon..."
    DOCKER_OPTS="--data-root=/var/lib/docker"
    DOCKER_OPTS="$DOCKER_OPTS --storage-driver=overlay2"
    DOCKER_OPTS="$DOCKER_OPTS --iptables=false"
    DOCKER_OPTS="$DOCKER_OPTS --userland-proxy=false"
    DOCKER_OPTS="$DOCKER_OPTS --bridge=none"
    DOCKER_OPTS="$DOCKER_OPTS --host=unix:///var/run/docker.sock"
    DOCKER_OPTS="$DOCKER_OPTS --exec-opt native.cgroupdriver=cgroupfs"
    DOCKER_OPTS="$DOCKER_OPTS --log-level=info"

    if [ "$CONTAINERD_READY" = "true" ]; then
        DOCKER_OPTS="$DOCKER_OPTS --containerd=/run/containerd/containerd.sock"
    fi

    /usr/bin/dockerd $DOCKER_OPTS >/dev/null 2>&1 &
    DOCKER_PID=$!
    log "Docker daemon started (PID: $DOCKER_PID)"

    # Wait for Docker to be ready
    log "Waiting for Docker daemon..."
    DOCKER_READY=false

    sleep 5

    for i in $(seq 1 60); do
        if ! kill -0 $DOCKER_PID 2>/dev/null; then
            echo "===ERROR==="
            echo "Docker daemon died after $i iterations"
            cat /var/log/docker.log 2>/dev/null || true
            dmesg | tail -20 2>/dev/null || true
            sleep 2
            reboot -f
        fi

        if /usr/bin/docker info >/dev/null 2>&1; then
            log "Docker daemon is ready!"
            DOCKER_READY=true
            break
        fi

        log "Waiting... ($i/60)"
        sleep 2
    done

    if [ "$DOCKER_READY" != "true" ]; then
        echo "===ERROR==="
        echo "Docker failed to start"
        sleep 2
        reboot -f
    fi
}

stop_runtime_daemons() {
    # Stop Docker daemon
    if [ -n "$DOCKER_PID" ]; then
        log "Stopping Docker daemon..."
        kill $DOCKER_PID 2>/dev/null || true
        for i in $(seq 1 10); do
            if ! kill -0 $DOCKER_PID 2>/dev/null; then
                log "Docker daemon stopped"
                break
            fi
            sleep 1
        done
    fi

    # Stop containerd
    if [ -n "$CONTAINERD_PID" ]; then
        log "Stopping containerd..."
        kill $CONTAINERD_PID 2>/dev/null || true
        sleep 2
    fi
}

handle_storage_output() {
    echo "Stopping Docker gracefully..."
    /usr/bin/docker system prune -f >/dev/null 2>&1 || true
    kill $DOCKER_PID 2>/dev/null || true
    [ -n "$CONTAINERD_PID" ] && kill $CONTAINERD_PID 2>/dev/null || true
    sleep 3

    echo "Packaging Docker storage..."
    cd /var/lib
    tar -cf /tmp/storage.tar docker/

    STORAGE_SIZE=$(stat -c%s /tmp/storage.tar 2>/dev/null || echo "0")
    echo "Storage size: $STORAGE_SIZE bytes"

    if [ "$STORAGE_SIZE" -gt 1000 ]; then
        dmesg -n 1
        echo "===STORAGE_START==="
        base64 /tmp/storage.tar
        echo "===STORAGE_END==="
        echo "===EXIT_CODE=$EXEC_EXIT_CODE==="
    else
        echo "===ERROR==="
        echo "Storage too small"
    fi
}

# ============================================================================
# Main
# ============================================================================

# Initialize base environment
setup_base_environment
mount_base_filesystems

# Check for quiet boot mode
check_quiet_boot

log "=== vdkr Init ==="
log "Version: $VCONTAINER_VERSION"

# Mount tmpfs directories and cgroups
mount_tmpfs_dirs
setup_cgroups

# Parse kernel command line
parse_cmdline

# Detect and configure disks
detect_disks

# Set up Docker storage (Docker-specific)
setup_docker_storage

# Mount input disk
mount_input_disk

# Configure networking
configure_networking

# Start containerd and dockerd (Docker-specific)
start_containerd
start_dockerd

# Handle daemon mode or single command execution
if [ "$RUNTIME_DAEMON" = "1" ]; then
    run_daemon_mode
else
    prepare_input_path
    execute_command
fi

# Graceful shutdown
graceful_shutdown
