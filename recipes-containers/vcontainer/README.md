# vdkr & vpdmn - Emulated Docker/Podman for Cross-Architecture

Execute Docker or Podman commands inside a QEMU-emulated target environment.

| Tool | Runtime | State Directory |
|------|---------|-----------------|
| `vdkr` | Docker (dockerd + containerd) | `~/.vdkr/<arch>/` |
| `vpdmn` | Podman (daemonless) | `~/.vpdmn/<arch>/` |

## Quick Start

```bash
# Build vdkr
bitbake vdkr-native

# List images (uses host architecture by default)
vdkr images

# Explicit architecture
vdkr -a aarch64 images

# Import an OCI container
vdkr vimport ./my-container-oci/ myapp:latest

# Export storage for deployment
vdkr --storage /tmp/docker-storage.tar vimport ./container-oci/ myapp:latest

# Clean persistent state
vdkr clean
```

## Architecture Selection

vdkr detects the target architecture automatically. Override with:

| Method | Example | Priority |
|--------|---------|----------|
| `--arch` / `-a` flag | `vdkr -a aarch64 images` | Highest |
| Executable name | `vdkr-x86_64 images` | 2nd |
| `VDKR_ARCH` env var | `export VDKR_ARCH=aarch64` | 3rd |
| Config file | `~/.config/vdkr/arch` | 4th |
| Host architecture | `uname -m` | Lowest |

**Set default architecture:**
```bash
mkdir -p ~/.config/vdkr
echo "aarch64" > ~/.config/vdkr/arch
```

**Backwards-compatible symlinks:**
```bash
vdkr-aarch64 images   # Same as: vdkr -a aarch64 images
vdkr-x86_64 images    # Same as: vdkr -a x86_64 images
```

## Commands

### Docker-Compatible (same syntax as Docker)

| Command | Description |
|---------|-------------|
| `images` | List images |
| `run [opts] <image> [cmd]` | Run a command in a container |
| `import <tarball> [name:tag]` | Import rootfs tarball |
| `load -i <file>` | Load Docker image archive |
| `save -o <file> <image>` | Save image to archive |
| `pull <image>` | Pull image from registry |
| `tag <source> <target>` | Tag an image |
| `rmi <image>` | Remove an image |
| `ps`, `rm`, `logs`, `start`, `stop` | Container management |
| `exec [opts] <container> <cmd>` | Execute in running container |

### Extended Commands (vdkr-specific)

| Command | Description |
|---------|-------------|
| `vimport <path> [name:tag]` | Import OCI directory, tarball, or directory (auto-detect) |
| `vrun [opts] <image> [cmd]` | Run with entrypoint cleared (command runs directly) |
| `clean` | Remove persistent state |
| `memres start [-p port:port]` | Start memory resident VM with optional port forwards |
| `memres stop` | Stop memory resident VM |
| `memres restart [--clean]` | Restart VM (optionally clean state) |
| `memres status` | Show memory resident VM status |
| `memres list` | List all running memres instances |

### run vs vrun

| Command | Behavior |
|---------|----------|
| `run` | Docker-compatible - entrypoint honored |
| `vrun` | Clears entrypoint when command given - runs command directly |

## Options

| Option | Description |
|--------|-------------|
| `--arch, -a <arch>` | Target architecture (x86_64 or aarch64) |
| `--instance, -I <name>` | Use named instance (shortcut for `--state-dir ~/.vdkr/<name>`) |
| `--stateless` | Don't use persistent state |
| `--storage <file>` | Export Docker storage to tar after command |
| `--state-dir <path>` | Override state directory |
| `--no-kvm` | Disable KVM acceleration |
| `-v, --verbose` | Enable verbose output |

## Memory Resident Mode

Keep QEMU VM running for fast command execution (~1s vs ~30s):

```bash
vdkr memres start              # Start daemon
vdkr images                    # Fast!
vdkr pull alpine:latest        # Fast!
vdkr run -it alpine /bin/sh    # Interactive mode works via daemon!
vdkr memres stop               # Stop daemon
```

Interactive mode (`run -it`, `vrun -it`, `exec -it`) now works directly via the daemon using virtio-serial passthrough - no need to stop/restart the daemon.

Note: Interactive mode combined with volume mounts (`-v`) still requires stopping the daemon temporarily.

## Port Forwarding

Forward ports from host to containers for SSH, web servers, etc:

```bash
# Start daemon with port forwarding
vdkr memres start -p 8080:80           # Host:8080 -> Guest:80
vdkr memres start -p 8080:80 -p 2222:22  # Multiple ports

# Run container with host networking (shares guest's network)
vdkr run -d --rm --network=host nginx:alpine

# Access from host
curl http://localhost:8080              # Access nginx
```

**How it works:**
```
Host:8080 → (QEMU hostfwd) → Guest:80 → (--network=host) → Container on port 80
```

Containers must use `--network=host` because Docker runs with `--bridge=none` inside the guest. This means the container shares the guest VM's network stack directly.

**Options:**
- `-p <host_port>:<guest_port>` - TCP forwarding (default)
- `-p <host_port>:<guest_port>/udp` - UDP forwarding
- Multiple `-p` options can be specified

**Managing instances:**
```bash
vdkr memres list                        # Show all running instances
vdkr memres start -p 9000:80            # Prompts if instance already running
vdkr -I web memres start -p 8080:80     # Start named instance "web"
vdkr -I web images                      # Use named instance
vdkr -I backend run -d --network=host my-api:latest
```

## Exporting Images

Two ways to export, for different purposes:

```bash
# Export a single image as Docker archive (portable, can be `docker load`ed)
vdkr save -o /tmp/myapp.tar myapp:latest

# Export entire Docker storage for deployment to target rootfs
vdkr --storage /tmp/docker-storage.tar images
```

| Method | Output | Use case |
|--------|--------|----------|
| `save -o file image:tag` | Docker archive | Share image, load on another Docker |
| `--storage file` | `/var/lib/docker` tar | Deploy to target rootfs |

## Persistent State

By default, Docker state persists in `~/.vdkr/<arch>/`. Images imported in one session are available in the next.

```bash
vdkr vimport ./container-oci/ myapp:latest
vdkr images   # Shows myapp:latest

# Later...
vdkr images   # Still shows myapp:latest

# Start fresh
vdkr --stateless images   # Empty

# Clear state
vdkr clean
```

## Standalone Distribution

Create a self-contained redistributable tarball that works without Yocto:

```bash
# Build the standalone tarball
MACHINE=qemux86-64 bitbake vdkr-native -c create_tarball

# Output: tmp/deploy/vdkr/vdkr-standalone-x86_64.tar.gz
```

The tarball includes:
- `vdkr` - Main CLI script
- `vdkr-aarch64`, `vdkr-x86_64` - Symlinks (only for available architectures)
- `vrunner.sh` - QEMU runner
- `vdkr-blobs/` - Kernel and initramfs per architecture
- `qemu/` - QEMU system emulators with wrapper scripts
- `lib/` - Shared libraries for QEMU
- `share/qemu/` - QEMU firmware files
- `socat` - Socket communication for memres mode
- `init-env.sh` - Environment setup script

Usage:
```bash
tar -xzf vdkr-standalone-x86_64.tar.gz
cd vdkr-standalone
source init-env.sh
vdkr images
```

## Interactive Mode

Run containers with an interactive shell:

```bash
# Interactive shell in a container
vdkr run -it alpine:latest /bin/sh

# Using vrun (clears entrypoint)
vdkr vrun -it alpine:latest /bin/sh

# Inside the container:
/ # apk add curl
/ # exit
```

## Networking

vdkr supports outbound networking via QEMU's slirp user-mode networking:

```bash
# Pull an image from a registry
vdkr pull alpine:latest

# Images persist in state directory
vdkr images   # Shows alpine:latest
```

## Volume Mounts

Mount host directories into containers using `-v` (requires memory resident mode):

```bash
# Start memres first
vdkr memres start

# Mount a host directory
vdkr vrun -v /tmp/data:/data alpine cat /data/file.txt

# Mount multiple directories
vdkr vrun -v /home/user/src:/src -v /tmp/out:/out alpine /src/build.sh

# Read-only mount
vdkr vrun -v /etc/config:/config:ro alpine cat /config/settings.conf

# With run command (same syntax)
vdkr run -v ./local:/app --rm myapp:latest /app/run.sh
```

**How it works:**
- Host files are copied to the virtio-9p share directory before container runs
- Container accesses them via the shared filesystem mount
- For `:rw` mounts (default), changes are synced back to host after container exits
- For `:ro` mounts, changes in container are discarded

**Limitations:**
- Requires daemon mode (memres) - volume mounts don't work in regular mode
- Interactive + volumes (`-it -v`) requires stopping daemon temporarily (share directory conflict)
- Changes sync after container exits (not real-time)
- Large directories may be slow to copy

**Debugging with volumes:**
```bash
# Run non-interactively with a shell command to inspect volume contents
vdkr vrun -v /tmp/data:/data alpine ls -la /data

# Or start the container detached and exec into it
vdkr run -d --name debug -v /tmp/data:/data alpine sleep 3600
vdkr exec debug ls -la /data
vdkr rm -f debug
```

## Testing

See `tests/README.md` for the pytest-based test suite:

```bash
# Build standalone tarball
MACHINE=qemux86-64 bitbake vdkr-native -c create_tarball

# Extract and run tests
cd /tmp && tar -xzf .../vdkr-standalone-x86_64.tar.gz
cd /opt/bruce/poky/meta-virtualization
pytest tests/test_vdkr.py -v --vdkr-dir /tmp/vdkr-standalone
```

## vpdmn (Podman)

vpdmn provides the same functionality as vdkr but uses Podman instead of Docker:

```bash
# Pull and run with Podman
vpdmn-x86_64 pull alpine:latest
vpdmn-x86_64 vrun alpine:latest echo hello

# Override entrypoint
vpdmn-x86_64 run --rm --entrypoint /bin/cat alpine:latest /etc/os-release

# Import OCI container
vpdmn-x86_64 vimport ./my-container-oci/ myapp:latest
```

Key differences from vdkr:
- **Daemonless** - No containerd/dockerd startup, faster boot (~5s vs ~10-15s)
- **Separate state** - Uses `~/.vpdmn/<arch>/` (images not shared with vdkr)
- **Same commands** - `images`, `pull`, `run`, `vrun`, `vimport`, etc. all work

## Recipes

| Recipe | Purpose |
|--------|---------|
| `vdkr-native_1.0.bb` | Main vdkr (Docker) CLI and blobs |
| `vpdmn-native_1.0.bb` | Main vpdmn (Podman) CLI and blobs |
| `vcontainer-native_1.0.bb` | Unified tarball with both tools |
| `vdkr-initramfs-create_1.0.bb` | Build vdkr initramfs blobs |
| `vpdmn-initramfs-create_1.0.bb` | Build vpdmn initramfs blobs |

## Files

| File | Purpose |
|------|---------|
| `vdkr.sh` | Docker CLI wrapper |
| `vpdmn.sh` | Podman CLI wrapper |
| `vrunner.sh` | Shared QEMU runner script |
| `vdkr-init.sh` | Docker init script (baked into initramfs) |
| `vpdmn-init.sh` | Podman init script (daemonless) |

## Testing

```bash
# Build unified standalone tarball
bitbake vcontainer-native -c create_tarball

# Extract
cd /tmp && tar -xzf .../vcontainer-standalone-*.tar.gz

# Run tests for both tools
cd /opt/bruce/poky/meta-virtualization
pytest tests/test_vdkr.py tests/test_vpdmn.py -v --vdkr-dir /tmp/vcontainer-standalone
```

## See Also

- `classes/container-cross-install.bbclass` for bundling containers into Yocto images
- `classes/container-bundle.bbclass` for creating container bundle packages
- `tests/README.md` for test documentation
