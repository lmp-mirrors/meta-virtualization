#!/bin/sh
# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: GPL-2.0-only
#
# vxn-init.sh
# Init script for vxn: execute container entrypoint directly in Xen DomU
#
# This script runs on a real filesystem after switch_root from initramfs.
# Unlike vdkr-init.sh which starts Docker, this script directly mounts
# the container's rootfs and executes the entrypoint via chroot.
#
# The VM IS the container — no container runtime runs inside the guest.
#
# Drive layout:
#   /dev/xvda = rootfs.img (this script runs from here, mounted as /)
#   /dev/xvdb = container rootfs (OCI image, passed from host)
#
# Kernel parameters (reuses docker_ prefix for frontend compatibility):
#   docker_cmd=<base64>    Base64-encoded entrypoint command
#   docker_input=<type>    Input type: none, oci, rootfs (default: none)
#   docker_output=<type>   Output type: text (default: text)
#   docker_network=1       Enable networking
#   docker_interactive=1   Interactive mode (suppress boot messages)
#   docker_daemon=1        Daemon mode (command loop on hvc1)
#
# Version: 1.0.0

# Set runtime-specific parameters before sourcing common code
VCONTAINER_RUNTIME_NAME="vxn"
VCONTAINER_RUNTIME_CMD="chroot"
VCONTAINER_RUNTIME_PREFIX="docker"
VCONTAINER_STATE_DIR="/var/lib/vxn"
VCONTAINER_SHARE_NAME="vxn_share"
VCONTAINER_VERSION="1.0.0"

# Source common init functions
. /vcontainer-init-common.sh

# ============================================================================
# Container Rootfs Handling
# ============================================================================

# Find the container rootfs directory from the input disk.
# Sets CONTAINER_ROOT to the path of the extracted rootfs.
find_container_rootfs() {
    CONTAINER_ROOT=""

    if [ ! -d /mnt/input ] || [ -z "$(ls -A /mnt/input 2>/dev/null)" ]; then
        log "WARNING: No container rootfs found on input disk"
        return 1
    fi

    # Check if the input disk IS the rootfs (has typical Linux dirs)
    if [ -d /mnt/input/bin ] || [ -d /mnt/input/usr ]; then
        CONTAINER_ROOT="/mnt/input"
        log "Container rootfs: direct mount (/mnt/input)"
        return 0
    fi

    # Check for OCI layout (index.json + blobs/)
    if [ -f /mnt/input/index.json ] || [ -f /mnt/input/oci-layout ]; then
        log "Found OCI layout on input disk, extracting layers..."
        extract_oci_rootfs /mnt/input /mnt/container
        CONTAINER_ROOT="/mnt/container"
        return 0
    fi

    # Check for rootfs/ subdirectory
    if [ -d /mnt/input/rootfs ]; then
        CONTAINER_ROOT="/mnt/input/rootfs"
        log "Container rootfs: /mnt/input/rootfs"
        return 0
    fi

    log "WARNING: Could not determine rootfs layout in /mnt/input"
    [ "$QUIET_BOOT" = "0" ] && ls -la /mnt/input/
    return 1
}

# Extract OCI image layers into a flat rootfs.
# Usage: extract_oci_rootfs <oci_dir> <target_dir>
extract_oci_rootfs() {
    local oci_dir="$1"
    local target_dir="$2"

    mkdir -p "$target_dir"

    if [ ! -f "$oci_dir/index.json" ]; then
        log "ERROR: No index.json in OCI layout"
        return 1
    fi

    if command -v jq >/dev/null 2>&1; then
        local manifest_digest=$(jq -r '.manifests[0].digest' "$oci_dir/index.json")
        local manifest_file="$oci_dir/blobs/${manifest_digest/://}"

        if [ -f "$manifest_file" ]; then
            # Extract layer digests from manifest (in order, bottom to top)
            local layers=$(jq -r '.layers[].digest' "$manifest_file")
            for layer_digest in $layers; do
                local layer_file="$oci_dir/blobs/${layer_digest/://}"
                if [ -f "$layer_file" ]; then
                    log "Extracting layer: ${layer_digest#sha256:}"
                    tar -xf "$layer_file" -C "$target_dir" 2>/dev/null || true
                fi
            done
        fi
    else
        # Fallback: find and extract all blobs that look like tarballs
        log "No jq available, extracting all blob layers..."
        for blob in "$oci_dir"/blobs/sha256/*; do
            if [ -f "$blob" ]; then
                tar -xf "$blob" -C "$target_dir" 2>/dev/null || true
            fi
        done
    fi

    if [ -d "$target_dir/bin" ] || [ -d "$target_dir/usr" ] || [ -f "$target_dir/hello" ]; then
        log "OCI rootfs extracted to $target_dir"
        return 0
    else
        log "WARNING: Extracted OCI rootfs may be incomplete"
        [ "$QUIET_BOOT" = "0" ] && ls -la "$target_dir/"
        return 0
    fi
}

# Parse OCI config for environment, entrypoint, cmd, workdir.
# Sets: OCI_ENTRYPOINT, OCI_CMD, OCI_ENV, OCI_WORKDIR
parse_oci_config() {
    OCI_ENTRYPOINT=""
    OCI_CMD=""
    OCI_ENV=""
    OCI_WORKDIR=""

    local config_file=""

    # Look for config in OCI layout on input disk
    if [ -f /mnt/input/index.json ]; then
        config_file=$(oci_find_config_blob /mnt/input)
    fi

    # Check for standalone config.json
    [ -z "$config_file" ] && [ -f /mnt/input/config.json ] && config_file="/mnt/input/config.json"

    if [ -z "$config_file" ] || [ ! -f "$config_file" ]; then
        log "No OCI config found (using command from kernel cmdline)"
        return
    fi

    log "Parsing OCI config: $config_file"

    if command -v jq >/dev/null 2>&1; then
        OCI_ENTRYPOINT=$(jq -r '(.config.Entrypoint // []) | join(" ")' "$config_file" 2>/dev/null)
        OCI_CMD=$(jq -r '(.config.Cmd // []) | join(" ")' "$config_file" 2>/dev/null)
        OCI_WORKDIR=$(jq -r '.config.WorkingDir // ""' "$config_file" 2>/dev/null)
        OCI_ENV=$(jq -r '(.config.Env // []) | .[]' "$config_file" 2>/dev/null)
    else
        # Fallback: parse OCI config JSON with grep/sed (no jq in minimal rootfs)
        log "Using grep/sed fallback for OCI config parsing"
        OCI_ENTRYPOINT=$(oci_grep_json_array "Entrypoint" "$config_file")
        OCI_CMD=$(oci_grep_json_array "Cmd" "$config_file")
        OCI_WORKDIR=$(grep -o '"WorkingDir":"[^"]*"' "$config_file" 2>/dev/null | sed 's/"WorkingDir":"//;s/"$//')
        OCI_ENV=$(grep -o '"Env":\[[^]]*\]' "$config_file" 2>/dev/null | \
            sed 's/"Env":\[//;s/\]$//' | tr ',' '\n' | sed 's/^ *"//;s/"$//')
    fi

    log "OCI config: entrypoint='$OCI_ENTRYPOINT' cmd='$OCI_CMD' workdir='$OCI_WORKDIR'"
}

# Follow OCI index.json → manifest → config blob using grep/sed.
# Works with or without jq.
oci_find_config_blob() {
    local oci_dir="$1"
    local digest=""
    local blob_file=""

    if command -v jq >/dev/null 2>&1; then
        digest=$(jq -r '.manifests[0].digest' "$oci_dir/index.json" 2>/dev/null)
        blob_file="$oci_dir/blobs/${digest/://}"
        [ -f "$blob_file" ] && digest=$(jq -r '.config.digest' "$blob_file" 2>/dev/null)
        blob_file="$oci_dir/blobs/${digest/://}"
    else
        # grep fallback: extract first digest from index.json
        digest=$(grep -o '"digest":"sha256:[a-f0-9]*"' "$oci_dir/index.json" 2>/dev/null | \
            head -n 1 | sed 's/"digest":"//;s/"$//')
        blob_file="$oci_dir/blobs/${digest/://}"
        if [ -f "$blob_file" ]; then
            # Extract config digest from manifest (mediaType contains "config")
            digest=$(grep -o '"config":{[^}]*}' "$blob_file" 2>/dev/null | \
                grep -o '"digest":"sha256:[a-f0-9]*"' | sed 's/"digest":"//;s/"$//')
            blob_file="$oci_dir/blobs/${digest/://}"
        fi
    fi

    [ -f "$blob_file" ] && echo "$blob_file"
}

# Extract a JSON array value as a space-separated string using grep/sed.
# Usage: oci_grep_json_array "Entrypoint" config_file
# Handles: "Entrypoint":["/hello"], "Cmd":["/bin/sh","-c","echo hi"]
oci_grep_json_array() {
    local key="$1"
    local file="$2"
    grep -o "\"$key\":\\[[^]]*\\]" "$file" 2>/dev/null | \
        sed "s/\"$key\":\\[//;s/\\]$//" | \
        tr ',' '\n' | sed 's/^ *"//;s/"$//' | tr '\n' ' ' | sed 's/ $//'
}

# ============================================================================
# Command Resolution
# ============================================================================

# Parse a "docker run" command to extract the container command (after image name).
# "docker run --rm hello-world" → "" (no cmd, use OCI defaults)
# "docker run --rm hello-world /bin/sh" → "/bin/sh"
parse_docker_run_cmd() {
    local full_cmd="$1"
    local found_image=false
    local container_cmd=""
    local skip_next=false

    # Strip "docker run" or "podman run" prefix
    local args=$(echo "$full_cmd" | sed 's/^[a-z]* run //')

    for arg in $args; do
        if [ "$found_image" = "true" ]; then
            container_cmd="$container_cmd $arg"
            continue
        fi

        if [ "$skip_next" = "true" ]; then
            skip_next=false
            continue
        fi

        case "$arg" in
            --rm|--detach|-d|-i|--interactive|-t|--tty|--privileged)
                ;;
            -p|--publish|-v|--volume|-e|--env|--name|--network|-w|--workdir|--entrypoint|-m|--memory|--cpus)
                skip_next=true
                ;;
            -p=*|--publish=*|-v=*|--volume=*|-e=*|--env=*|--name=*|--network=*|-w=*|--workdir=*|--entrypoint=*)
                ;;
            -*)
                ;;
            *)
                # First non-option argument is the image name — skip it
                found_image=true
                ;;
        esac
    done

    echo "$container_cmd" | sed 's/^ *//'
}

# Determine the command to execute inside the container.
# Priority: 1) explicit command from docker run args, 2) RUNTIME_CMD as raw command,
#           3) OCI entrypoint + cmd, 4) /bin/sh fallback
determine_exec_command() {
    local cmd=""

    if [ -n "$RUNTIME_CMD" ]; then
        # Check if this is a "docker run" wrapper command
        if echo "$RUNTIME_CMD" | grep -qE '^(docker|podman) run '; then
            cmd=$(parse_docker_run_cmd "$RUNTIME_CMD")
            # If no command after image name, fall through to OCI config
        else
            # Raw command — use as-is
            cmd="$RUNTIME_CMD"
        fi
    fi

    # If no explicit command, use OCI config
    if [ -z "$cmd" ]; then
        if [ -n "$OCI_ENTRYPOINT" ]; then
            cmd="$OCI_ENTRYPOINT"
            [ -n "$OCI_CMD" ] && cmd="$cmd $OCI_CMD"
        elif [ -n "$OCI_CMD" ]; then
            cmd="$OCI_CMD"
        fi
    fi

    # Final fallback
    if [ -z "$cmd" ]; then
        cmd="/bin/sh"
        log "No command specified, defaulting to /bin/sh"
    fi

    echo "$cmd"
}

# ============================================================================
# Container Execution
# ============================================================================

# Set up environment variables for the container
setup_container_env() {
    # Apply OCI environment variables
    if [ -n "$OCI_ENV" ]; then
        echo "$OCI_ENV" | while IFS= read -r env_line; do
            [ -n "$env_line" ] && export "$env_line" 2>/dev/null || true
        done
    fi

    # Ensure basic environment
    export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
    export HOME="${HOME:-/root}"
    export TERM="${TERM:-linux}"
}

# Execute a command inside the container rootfs via chroot.
# Mounts /proc, /sys, /dev inside the container and copies DNS config.
exec_in_container() {
    local rootfs="$1"
    local cmd="$2"
    local workdir="${OCI_WORKDIR:-/}"

    # Mount essential filesystems inside the container rootfs
    mkdir -p "$rootfs/proc" "$rootfs/sys" "$rootfs/dev" "$rootfs/tmp" 2>/dev/null || true
    mount -t proc proc "$rootfs/proc" 2>/dev/null || true
    mount -t sysfs sysfs "$rootfs/sys" 2>/dev/null || true
    mount --bind /dev "$rootfs/dev" 2>/dev/null || true

    # Copy resolv.conf for DNS
    if [ -f /etc/resolv.conf ]; then
        mkdir -p "$rootfs/etc" 2>/dev/null || true
        cp /etc/resolv.conf "$rootfs/etc/resolv.conf" 2>/dev/null || true
    fi

    log "Executing in container: $cmd"
    log "Working directory: $workdir"

    # Determine how to exec: use /bin/sh if available, otherwise direct exec
    local use_sh=true
    if [ ! -x "$rootfs/bin/sh" ]; then
        use_sh=false
        log "No /bin/sh in container, using direct exec"
    fi

    if [ "$RUNTIME_INTERACTIVE" = "1" ]; then
        # Interactive mode: connect stdin/stdout directly
        export TERM=linux
        printf '\r\033[K'
        if [ "$use_sh" = "true" ]; then
            chroot "$rootfs" /bin/sh -c "cd '$workdir' 2>/dev/null; exec $cmd"
        else
            chroot "$rootfs" $cmd
        fi
        EXEC_EXIT_CODE=$?
    else
        # Non-interactive: capture output
        EXEC_OUTPUT="/tmp/container_output.txt"
        EXEC_EXIT_CODE=0
        if [ "$use_sh" = "true" ]; then
            chroot "$rootfs" /bin/sh -c "cd '$workdir' 2>/dev/null; exec $cmd" \
                > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?
        else
            chroot "$rootfs" $cmd \
                > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?
        fi

        log "Exit code: $EXEC_EXIT_CODE"

        echo "===OUTPUT_START==="
        cat "$EXEC_OUTPUT"
        echo "===OUTPUT_END==="
        echo "===EXIT_CODE=$EXEC_EXIT_CODE==="
    fi

    # Cleanup mounts inside container
    umount "$rootfs/proc" 2>/dev/null || true
    umount "$rootfs/sys" 2>/dev/null || true
    umount "$rootfs/dev" 2>/dev/null || true
}

# ============================================================================
# Daemon Mode (vxn-specific)
# ============================================================================

# In daemon mode, commands come via the hvc1 console channel
# and are executed in the container rootfs via chroot.
run_vxn_daemon_mode() {
    log "=== vxn Daemon Mode ==="
    log "Container rootfs: ${CONTAINER_ROOT:-(none)}"
    log "Idle timeout: ${RUNTIME_IDLE_TIMEOUT}s"

    # Find the command channel (prefer hvc1 for Xen)
    DAEMON_PORT=""
    for port in /dev/hvc1 /dev/vport0p1 /dev/vport1p1 /dev/virtio-ports/vxn; do
        if [ -c "$port" ]; then
            DAEMON_PORT="$port"
            log "Found command channel: $port"
            break
        fi
    done

    if [ -z "$DAEMON_PORT" ]; then
        log "ERROR: No command channel for daemon mode"
        ls -la /dev/hvc* /dev/vport* /dev/virtio-ports/ 2>/dev/null || true
        sleep 5
        reboot -f
    fi

    # Open bidirectional FD
    exec 3<>"$DAEMON_PORT"

    log "Daemon ready, waiting for commands..."

    ACTIVITY_FILE="/tmp/.daemon_activity"
    touch "$ACTIVITY_FILE"
    DAEMON_PID=$$

    trap 'log "Shutdown signal"; sync; reboot -f' TERM
    trap 'rm -f "$ACTIVITY_FILE"; exit' INT

    # Command loop
    while true; do
        CMD_B64=""
        read -r CMD_B64 <&3
        READ_EXIT=$?

        if [ $READ_EXIT -eq 0 ] && [ -n "$CMD_B64" ]; then
            touch "$ACTIVITY_FILE"

            case "$CMD_B64" in
                "===PING===")
                    echo "===PONG===" | cat >&3
                    continue
                    ;;
                "===SHUTDOWN===")
                    log "Received shutdown command"
                    echo "===SHUTTING_DOWN===" | cat >&3
                    break
                    ;;
            esac

            # Decode command
            CMD=$(echo "$CMD_B64" | base64 -d 2>/dev/null)
            if [ -z "$CMD" ]; then
                printf "===ERROR===\nFailed to decode command\n===END===\n" | cat >&3
                continue
            fi

            log "Executing: $CMD"

            # Execute command in container rootfs (or host rootfs if no container)
            EXEC_OUTPUT="/tmp/daemon_output.txt"
            EXEC_EXIT_CODE=0
            if [ -n "$CONTAINER_ROOT" ]; then
                chroot "$CONTAINER_ROOT" /bin/sh -c "$CMD" \
                    > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?
            else
                eval "$CMD" > "$EXEC_OUTPUT" 2>&1 || EXEC_EXIT_CODE=$?
            fi

            {
                echo "===OUTPUT_START==="
                cat "$EXEC_OUTPUT"
                echo "===OUTPUT_END==="
                echo "===EXIT_CODE=$EXEC_EXIT_CODE==="
                echo "===END==="
            } | cat >&3

            log "Command completed (exit code: $EXEC_EXIT_CODE)"
        else
            sleep 0.1
        fi
    done

    exec 3>&-
    log "Daemon shutting down..."
}

# ============================================================================
# Main
# ============================================================================

# Initialize base environment
setup_base_environment
mount_base_filesystems

# Check for quiet boot mode
check_quiet_boot

log "=== vxn Init ==="
log "Version: $VCONTAINER_VERSION"

# Mount tmpfs directories and cgroups
mount_tmpfs_dirs
setup_cgroups

# Parse kernel command line
parse_cmdline

# Detect and configure disks
detect_disks

# Mount input disk (container rootfs from host)
mount_input_disk

# Configure networking
configure_networking

# Find the container rootfs on the input disk
if ! find_container_rootfs; then
    if [ "$RUNTIME_DAEMON" = "1" ]; then
        log "No container rootfs, daemon mode will execute on host rootfs"
        CONTAINER_ROOT=""
    else
        echo "===ERROR==="
        echo "No container rootfs found on input disk"
        echo "Contents of /mnt/input:"
        ls -la /mnt/input/ 2>/dev/null || echo "(empty)"
        sleep 2
        reboot -f
    fi
fi

# Parse OCI config for entrypoint/env/workdir
parse_oci_config

# Set up container environment
setup_container_env

if [ "$RUNTIME_DAEMON" = "1" ]; then
    run_vxn_daemon_mode
else
    # Determine command to execute
    EXEC_CMD=$(determine_exec_command)

    if [ -z "$EXEC_CMD" ]; then
        echo "===ERROR==="
        echo "No command to execute"
        sleep 2
        reboot -f
    fi

    # Execute in container rootfs
    exec_in_container "$CONTAINER_ROOT" "$EXEC_CMD"
fi

# Graceful shutdown
graceful_shutdown
