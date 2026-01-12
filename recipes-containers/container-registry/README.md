# Container Registry Infrastructure

Local container registry for Yocto/OE builds - analogous to package-index for containers.

## Quick Start

```bash
# 1. Configure in local.conf
CONTAINER_REGISTRY_URL = "localhost:5000"
CONTAINER_REGISTRY_NAMESPACE = "yocto"
CONTAINER_REGISTRY_INSECURE = "1"

# 2. Generate the helper script
bitbake container-registry-index -c generate_registry_script

# 3. Start registry, push images
$TOPDIR/container-registry/container-registry.sh start
$TOPDIR/container-registry/container-registry.sh push

# 4. Import 3rd party images
$TOPDIR/container-registry/container-registry.sh import docker.io/library/alpine:latest

# 5. Use with vdkr (10.0.2.2 is QEMU slirp gateway to localhost)
vdkr vconfig registry 10.0.2.2:5000/yocto
vdkr pull container-base
```

## Helper Script Commands

Script location: `${TOPDIR}/container-registry/container-registry.sh` (outside tmp/, persists)

| Command | Description |
|---------|-------------|
| `start` | Start the container registry server |
| `stop` | Stop the container registry server |
| `status` | Check if registry is running |
| `push [image] [options]` | Push OCI images from deploy/ to registry |
| `import <image> [name]` | Import 3rd party image to registry |
| `delete <image>:<tag>` | Delete a tagged image from registry |
| `gc` | Garbage collect unreferenced blobs |
| `list` | List all images with their tags |
| `tags <image>` | List tags for a specific image |
| `catalog` | Raw API catalog output |

### Push Options

```bash
# Explicit tags (require image name)
container-registry.sh push container-base --tag v1.0.0
container-registry.sh push container-base --tag latest --tag v1.0.0

# Strategy-based (see Tag Strategies below)
container-registry.sh push --strategy "sha branch latest"
container-registry.sh push --strategy semver --version 1.2.3

# Environment variable override
CONTAINER_REGISTRY_TAG_STRATEGY="sha latest" container-registry.sh push
```

## Tag Strategies

Configure tag generation via `CONTAINER_REGISTRY_TAG_STRATEGY` (space-separated):

| Strategy | Output | Description |
|----------|--------|-------------|
| `timestamp` | `20260112-143022` | Build timestamp |
| `sha` / `git` | `8a3f2b1` | Short git commit hash |
| `branch` | `main`, `feature-login` | Git branch name (sanitized) |
| `semver` | `1.2.3`, `1.2`, `1` | Nested SemVer from PV |
| `version` | `1.2.3` | Single version tag |
| `latest` | `latest` | The "latest" tag |
| `arch` | `*-x86_64` | Append architecture suffix |

### Example Workflows

**Development builds** (track code changes):
```bitbake
CONTAINER_REGISTRY_TAG_STRATEGY = "sha branch latest"
```
Result: `my-app:8a3f2b1`, `my-app:feature-login`, `my-app:latest`

**Release builds** (semantic versioning):
```bitbake
CONTAINER_REGISTRY_TAG_STRATEGY = "semver latest"
PV = "1.2.3"
```
Result: `my-app:1.2.3`, `my-app:1.2`, `my-app:1`, `my-app:latest`

**CI/CD** (traceability):
```bash
IMAGE_VERSION=1.2.3 container-registry.sh push --strategy "semver sha latest"
```

## Development Loop

The default strategy (`timestamp latest`) supports a simple development workflow:

```bash
# Build
bitbake container-base

# Push (creates both timestamp tag AND :latest)
./container-registry/container-registry.sh push

# Pull on target - :latest is implicit, gets your most recent push
vdkr pull container-base

# Test
vdkr run container-base /bin/sh

# Repeat: rebuild, push, pull - no tag hunting needed
```

Each push overwrites `:latest` with your newest build. The timestamp tags (`20260112-143022`) remain for rollback/debugging.

## Build-Time OCI Labels

Container images automatically include standard OCI traceability labels:

```bash
$ skopeo inspect oci:container-base-oci | jq '.Labels'
{
  "org.opencontainers.image.revision": "8a3f2b1",
  "org.opencontainers.image.ref.name": "master",
  "org.opencontainers.image.created": "2026-01-12T20:32:24Z"
}
```

| Label | Source | Description |
|-------|--------|-------------|
| `org.opencontainers.image.revision` | git SHA from TOPDIR | Code traceability |
| `org.opencontainers.image.ref.name` | git branch from TOPDIR | Branch tracking |
| `org.opencontainers.image.created` | Build timestamp | When image was built |
| `org.opencontainers.image.version` | PV (if set) | Semantic version |

### Customizing Labels

```bitbake
# In local.conf or image recipe

# Explicit override (e.g., from CI/CD)
OCI_IMAGE_REVISION = "${CI_COMMIT_SHA}"
OCI_IMAGE_BRANCH = "${CI_BRANCH}"

# Disable specific label
OCI_IMAGE_REVISION = "none"

# Disable all auto-labels
OCI_IMAGE_AUTO_LABELS = "0"
```

## Configuration (local.conf)

```bitbake
# Registry endpoint (host-side)
CONTAINER_REGISTRY_URL = "localhost:5000"

# Image namespace
CONTAINER_REGISTRY_NAMESPACE = "yocto"

# Mark as insecure (HTTP)
CONTAINER_REGISTRY_INSECURE = "1"

# Tag strategy (default: "timestamp latest")
CONTAINER_REGISTRY_TAG_STRATEGY = "sha branch latest"

# For Docker targets
DOCKER_REGISTRY_INSECURE = "localhost:5000"

# Persistent storage (default: ${TOPDIR}/container-registry)
CONTAINER_REGISTRY_STORAGE = "/data/container-registry"
```

## vdkr Registry Usage

### Pull Behavior with Registry Fallback

When a registry is configured, vdkr uses **registry-first, Docker Hub fallback** for pulls:

1. Try configured registry first (e.g., `10.0.2.2:5000/yocto/alpine`)
2. If not found, fall back to Docker Hub (`docker.io/library/alpine`)

This allows you to override images with local builds while still pulling public images normally.

```bash
# One-off
vdkr --registry 10.0.2.2:5000/yocto pull alpine

# Persistent config
vdkr vconfig registry 10.0.2.2:5000/yocto
vdkr pull alpine      # Tries registry first, falls back to Docker Hub
vdkr pull container-base  # Pulls from registry (your Yocto-built image)
vdkr run alpine echo hello

# Clear config
vdkr vconfig registry --reset

# Image management (all commands use registry prefix for stored images)
vdkr image ls
vdkr image inspect alpine   # Works for both registry and Docker Hub images
vdkr image rm <image>
vdkr image rm e7b39c54cdec  # Image IDs work without transformation
```

### Registry Transform

When a registry is configured:
- `pull`, `run` - Use fallback (registry first, then Docker Hub)
- `inspect`, `history`, `rmi`, `tag`, `images` - No transform (use actual local image names)
- Image IDs (hex strings like `e7b39c54cdec`) - Never transformed

## Baking Registry Config into Target Images

Use `IMAGE_FEATURES` to auto-select the right package based on `CONTAINER_PROFILE`:

```bitbake
# In local.conf
CONTAINER_REGISTRY_URL = "localhost:5000"
CONTAINER_REGISTRY_INSECURE = "1"
DOCKER_REGISTRY_INSECURE = "localhost:5000"

# Enable the feature
IMAGE_FEATURES:append = " container-registry"
```

This installs:
- **Docker profile** → `docker-registry-config` → `/etc/docker/daemon.json`
- **Podman profile** → `container-oci-registry-config` → `/etc/containers/registries.conf.d/`

## Files

| File | Description |
|------|-------------|
| `container-registry-index.bb` | Generates helper script with baked-in paths |
| `container-registry-populate.bb` | Alternative bitbake-driven push |
| `container-oci-registry-config.bb` | OCI tools config (Podman/Skopeo/Buildah/CRI-O) |
| `docker-registry-config.bb` | Docker daemon config |
| `files/container-registry-dev.yml` | Development registry config |

## Storage

Registry data and script are stored at `${TOPDIR}/container-registry/` by default:
- Outside tmp/, persists across builds and cleanall
- Imported and pushed images are copied here
- Script regenerates with same paths after tmp/ cleanup

## Localhost to 10.0.2.2 Translation

For vdkr baked configs, `localhost` URLs are auto-translated to `10.0.2.2` (QEMU slirp gateway):
- Set `CONTAINER_REGISTRY_URL = "localhost:5000"` in local.conf
- Host-side operations use localhost directly
- vdkr inside QEMU accesses via 10.0.2.2 automatically
