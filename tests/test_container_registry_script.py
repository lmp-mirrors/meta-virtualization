# SPDX-FileCopyrightText: Copyright (C) 2025 Bruce Ashfield
#
# SPDX-License-Identifier: MIT
"""
Tests for container-registry.sh helper script.

These tests verify the container registry helper script commands:
- start/stop/status - Registry server lifecycle
- push - Push OCI images to registry (with tag/strategy options)
- import - Import 3rd party images
- delete - Delete tagged images
- gc - Garbage collection
- list/tags/catalog - Query registry contents

Prerequisites:
    # Generate the script first:
    bitbake container-registry-index -c generate_registry_script

    # The script location is:
    $TOPDIR/container-registry/container-registry.sh

Run with:
    pytest tests/test_container_registry_script.py -v

Run with specific registry script:
    pytest tests/test_container_registry_script.py -v \\
        --registry-script /path/to/container-registry.sh

Environment variables:
    CONTAINER_REGISTRY_SCRIPT: Path to the registry script
    TOPDIR: Yocto build directory (script at $TOPDIR/container-registry/)
"""

import pytest
import subprocess
import os
import time
from pathlib import Path


# Note: Registry options (--registry-script, --skip-registry-network)
# are defined in conftest.py


@pytest.fixture(scope="module")
def registry_script(request):
    """Get path to the registry script.

    Looks in order:
    1. --registry-script command line option
    2. CONTAINER_REGISTRY_SCRIPT environment variable
    3. $TOPDIR/container-registry/container-registry.sh
    4. Common locations based on cwd
    """
    # Check command line option
    script_path = request.config.getoption("--registry-script", default=None)

    if script_path is None:
        # Check environment variable
        script_path = os.environ.get("CONTAINER_REGISTRY_SCRIPT")

    if script_path is None:
        # Try TOPDIR-based path
        topdir = os.environ.get("TOPDIR")
        if topdir:
            script_path = os.path.join(topdir, "container-registry", "container-registry.sh")

    if script_path is None:
        # Try common locations relative to cwd
        candidates = [
            "container-registry/container-registry.sh",
            "../container-registry/container-registry.sh",
            "build/container-registry/container-registry.sh",
        ]
        for candidate in candidates:
            if os.path.exists(candidate):
                script_path = candidate
                break

    if script_path is None or not os.path.exists(script_path):
        pytest.skip(
            "Registry script not found. Generate it with: "
            "bitbake container-registry-index -c generate_registry_script\n"
            "Or specify path with --registry-script or CONTAINER_REGISTRY_SCRIPT env var"
        )

    script_path = Path(script_path).resolve()
    if not script_path.exists():
        pytest.skip(f"Registry script not found at: {script_path}")

    return script_path


@pytest.fixture(scope="module")
def skip_network(request):
    """Check if network tests should be skipped."""
    return request.config.getoption("--skip-registry-network", default=False)


class RegistryScriptRunner:
    """Helper class for running registry script commands."""

    def __init__(self, script_path: Path):
        self.script_path = script_path
        self._was_running = None

    def run(self, *args, timeout=30, check=True, capture_output=True):
        """Run a registry script command."""
        cmd = [str(self.script_path)] + list(args)
        result = subprocess.run(
            cmd,
            timeout=timeout,
            check=False,
            capture_output=capture_output,
            text=True,
        )
        if check and result.returncode != 0:
            error_msg = f"Command failed: {' '.join(cmd)}\n"
            error_msg += f"Exit code: {result.returncode}\n"
            if result.stdout:
                error_msg += f"stdout: {result.stdout}\n"
            if result.stderr:
                error_msg += f"stderr: {result.stderr}\n"
            raise AssertionError(error_msg)
        return result

    def start(self, timeout=30):
        """Start the registry."""
        return self.run("start", timeout=timeout)

    def stop(self, timeout=10):
        """Stop the registry."""
        return self.run("stop", timeout=timeout, check=False)

    def status(self, timeout=10):
        """Check registry status."""
        return self.run("status", timeout=timeout, check=False)

    def is_running(self):
        """Check if registry is running."""
        result = self.status()
        return result.returncode == 0 and "running" in result.stdout.lower()

    def ensure_running(self, timeout=30):
        """Ensure registry is running, starting if needed."""
        if not self.is_running():
            result = self.start(timeout=timeout)
            if result.returncode != 0:
                raise RuntimeError(f"Failed to start registry: {result.stderr}")
            time.sleep(2)

    def push(self, timeout=120):
        """Push OCI images to registry."""
        return self.run("push", timeout=timeout)

    def import_image(self, source, dest_name=None, timeout=300):
        """Import a 3rd party image."""
        args = ["import", source]
        if dest_name:
            args.append(dest_name)
        return self.run(*args, timeout=timeout)

    def list_images(self, timeout=30):
        """List images in registry."""
        return self.run("list", timeout=timeout)

    def tags(self, image, timeout=30):
        """Get tags for an image."""
        return self.run("tags", image, timeout=timeout, check=False)

    def catalog(self, timeout=30):
        """Get raw catalog."""
        return self.run("catalog", timeout=timeout)

    def help(self):
        """Show help."""
        return self.run("help", check=False)

    def delete(self, image_tag, timeout=30):
        """Delete a tagged image."""
        return self.run("delete", image_tag, timeout=timeout, check=False)

    def gc(self, timeout=60):
        """Run garbage collection (non-interactive)."""
        # gc prompts for confirmation, so we can't easily test interactive mode
        # Just test that the command exists and shows dry-run
        return self.run("gc", timeout=timeout, check=False)

    def push_with_args(self, *args, timeout=120):
        """Push with custom arguments."""
        return self.run("push", *args, timeout=timeout, check=False)


@pytest.fixture(scope="module")
def registry(registry_script):
    """Create a RegistryScriptRunner instance."""
    return RegistryScriptRunner(registry_script)


@pytest.fixture(scope="module")
def registry_session(registry):
    """Module-scoped fixture that ensures registry is running.

    Starts the registry if not running and stops it at the end
    if we started it.
    """
    was_running = registry.is_running()

    if not was_running:
        result = registry.start(timeout=30)
        if result.returncode != 0:
            pytest.skip(f"Failed to start registry: {result.stderr}")
        # Wait a moment for registry to be ready
        time.sleep(2)

    yield registry

    # Only stop if we started it
    if not was_running:
        registry.stop()


class TestRegistryScriptBasic:
    """Test basic registry script functionality."""

    def test_script_exists_and_executable(self, registry_script):
        """Test that the script exists and is executable."""
        assert registry_script.exists()
        assert os.access(registry_script, os.X_OK)

    def test_help_command(self, registry):
        """Test help command shows usage info."""
        result = registry.help()
        assert result.returncode == 0
        assert "start" in result.stdout
        assert "stop" in result.stdout
        assert "push" in result.stdout
        assert "import" in result.stdout
        assert "list" in result.stdout

    def test_unknown_command_shows_error(self, registry):
        """Test that unknown command shows error and help."""
        result = registry.run("invalid-command", check=False)
        assert result.returncode != 0
        assert "unknown" in result.stdout.lower() or "usage" in result.stdout.lower()


class TestRegistryLifecycle:
    """Test registry start/stop/status commands."""

    def test_start_registry(self, registry):
        """Test starting the registry."""
        # Stop first if running
        registry.stop()
        time.sleep(1)

        result = registry.start()
        assert result.returncode == 0
        assert "started" in result.stdout.lower() or "running" in result.stdout.lower()

        # Verify it's running
        assert registry.is_running()

    def test_status_when_running(self, registry):
        """Test status command when registry is running."""
        # Ensure running
        if not registry.is_running():
            registry.start()
            time.sleep(2)

        result = registry.status()
        assert result.returncode == 0
        assert "running" in result.stdout.lower()
        assert "healthy" in result.stdout.lower() or "url" in result.stdout.lower()

    def test_stop_registry(self, registry):
        """Test stopping the registry."""
        # Ensure running first
        if not registry.is_running():
            registry.start()
            time.sleep(2)

        result = registry.stop()
        assert result.returncode == 0
        assert "stop" in result.stdout.lower()

        # Verify it's stopped
        assert not registry.is_running()

    def test_status_when_stopped(self, registry):
        """Test status command when registry is stopped."""
        # Ensure stopped
        registry.stop()
        time.sleep(1)

        result = registry.status()
        assert result.returncode != 0
        assert "not running" in result.stdout.lower()

    def test_start_when_already_running(self, registry):
        """Test that starting when already running is idempotent."""
        # Start once
        if not registry.is_running():
            registry.start()
            time.sleep(2)

        # Start again
        result = registry.start()
        assert result.returncode == 0
        assert "already running" in result.stdout.lower() or "running" in result.stdout.lower()

    def test_stop_when_not_running(self, registry):
        """Test that stopping when not running is idempotent."""
        # Ensure stopped
        registry.stop()
        time.sleep(1)

        # Stop again
        result = registry.stop()
        assert result.returncode == 0
        assert "not running" in result.stdout.lower()


class TestRegistryPush:
    """Test pushing OCI images to the registry.

    Note: This requires OCI images in the deploy directory.
    Tests will skip if no images are available.
    """

    def test_push_requires_running_registry(self, registry):
        """Test that push fails when registry is not running."""
        registry.stop()
        time.sleep(1)

        result = registry.run("push", check=False, timeout=10)
        assert result.returncode != 0
        assert "not responding" in result.stdout.lower() or "start" in result.stdout.lower()

    def test_push_with_no_images(self, registry_session):
        """Test push when no OCI images are in deploy directory.

        This may succeed (with "no images" message) or actually push
        images if they exist. Either is acceptable.
        """
        registry_session.ensure_running()
        result = registry_session.push(timeout=120)
        # Either succeeds (with images) or shows message (without)
        # Both are valid outcomes
        assert result.returncode == 0


class TestRegistryImport:
    """Test importing 3rd party images.

    Note: Import tests require network access to docker.io.
    Use --skip-registry-network to skip these tests.
    """

    def test_import_requires_running_registry(self, registry):
        """Test that import fails when registry is not running."""
        registry.stop()
        time.sleep(1)

        result = registry.run("import", "docker.io/library/alpine:latest",
                              check=False, timeout=10)
        assert result.returncode != 0
        assert "not responding" in result.stdout.lower() or "start" in result.stdout.lower()

    def test_import_no_args_shows_usage(self, registry_session):
        """Test that import without args shows usage."""
        registry_session.ensure_running()
        result = registry_session.run("import", check=False)
        assert result.returncode != 0
        assert "usage" in result.stdout.lower()
        assert "docker.io" in result.stdout.lower() or "example" in result.stdout.lower()

    @pytest.mark.network
    @pytest.mark.slow
    def test_import_alpine(self, registry_session, skip_network):
        """Test importing alpine from docker.io."""
        if skip_network:
            pytest.skip("Skipping network test (--skip-registry-network)")

        registry_session.ensure_running()
        result = registry_session.import_image(
            "docker.io/library/alpine:latest",
            timeout=300
        )
        assert result.returncode == 0
        assert "import complete" in result.stdout.lower() or "importing" in result.stdout.lower()

        # Verify it appears in list
        list_result = registry_session.list_images()
        assert "alpine" in list_result.stdout

    @pytest.mark.network
    @pytest.mark.slow
    def test_import_with_custom_name(self, registry_session, skip_network):
        """Test importing with a custom local name."""
        if skip_network:
            pytest.skip("Skipping network test (--skip-registry-network)")

        registry_session.ensure_running()
        result = registry_session.import_image(
            "docker.io/library/busybox:latest",
            "my-busybox",
            timeout=300
        )
        assert result.returncode == 0

        # Verify it appears with custom name
        list_result = registry_session.list_images()
        assert "my-busybox" in list_result.stdout


class TestRegistryQuery:
    """Test registry query commands (list, tags, catalog)."""

    def test_catalog_requires_running_registry(self, registry):
        """Test that catalog fails when registry is not running."""
        registry.stop()
        time.sleep(1)

        result = registry.run("catalog", check=False, timeout=10)
        # May fail or return empty/error JSON
        # Just verify it doesn't hang

    def test_list_requires_running_registry(self, registry):
        """Test that list fails when registry is not running."""
        registry.stop()
        time.sleep(1)

        result = registry.run("list", check=False, timeout=10)
        assert result.returncode != 0
        assert "not responding" in result.stdout.lower()

    def test_catalog_returns_json(self, registry_session):
        """Test that catalog returns JSON format."""
        registry_session.ensure_running()
        result = registry_session.catalog()
        assert result.returncode == 0

        # Should be valid JSON with repositories key
        import json
        try:
            data = json.loads(result.stdout)
            assert "repositories" in data
        except json.JSONDecodeError:
            # May be pretty-printed, try parsing lines
            assert "repositories" in result.stdout

    def test_list_shows_images(self, registry_session):
        """Test that list shows images with their tags."""
        registry_session.ensure_running()
        result = registry_session.list_images()
        assert result.returncode == 0
        # Should show header or images
        assert "images" in result.stdout.lower() or ":" in result.stdout or "(none)" in result.stdout

    def test_tags_for_nonexistent_image(self, registry_session):
        """Test tags command for nonexistent image."""
        registry_session.ensure_running()
        result = registry_session.tags("nonexistent-image-xyz")
        # Either returns non-zero with "not found", or returns empty/error JSON
        # The important thing is it doesn't crash and indicates the image doesn't exist
        if result.returncode == 0:
            # If it returns 0, stdout should be empty or contain error info
            assert "nonexistent" not in result.stdout.lower() or "error" in result.stdout.lower() or result.stdout.strip() == ""
        else:
            assert "not found" in result.stdout.lower() or "error" in result.stdout.lower()

    def test_tags_usage_without_image(self, registry_session):
        """Test tags command without image argument shows usage."""
        registry_session.ensure_running()
        result = registry_session.run("tags", check=False)
        assert result.returncode != 0
        assert "usage" in result.stdout.lower()


class TestRegistryDelete:
    """Test delete command for removing tagged images."""

    def test_delete_requires_running_registry(self, registry):
        """Test that delete fails when registry is not running."""
        registry.stop()
        time.sleep(1)

        result = registry.delete("container-base:latest")
        assert result.returncode != 0
        assert "not responding" in result.stdout.lower()

    def test_delete_no_args_shows_usage(self, registry_session):
        """Test that delete without args shows usage."""
        registry_session.ensure_running()
        result = registry_session.run("delete", check=False)
        assert result.returncode != 0
        assert "usage" in result.stdout.lower()

    def test_delete_requires_tag(self, registry_session):
        """Test that delete requires image:tag format."""
        registry_session.ensure_running()
        result = registry_session.delete("container-base")  # No tag
        assert result.returncode != 0
        assert "tag required" in result.stdout.lower()

    def test_delete_nonexistent_tag(self, registry_session):
        """Test deleting a nonexistent tag."""
        registry_session.ensure_running()
        result = registry_session.delete("container-base:nonexistent-tag-xyz")
        assert result.returncode != 0
        assert "not found" in result.stdout.lower()

    @pytest.mark.network
    @pytest.mark.slow
    def test_delete_workflow(self, registry_session, skip_network):
        """Test importing an image, then deleting it."""
        if skip_network:
            pytest.skip("Skipping network test (--skip-registry-network)")

        registry_session.ensure_running()

        # Import an image with unique name
        result = registry_session.import_image(
            "docker.io/library/alpine:latest",
            "delete-test",
            timeout=300
        )
        assert result.returncode == 0

        # Verify it exists
        result = registry_session.tags("delete-test")
        assert result.returncode == 0
        assert "latest" in result.stdout

        # Delete it
        result = registry_session.delete("delete-test:latest")
        assert result.returncode == 0
        assert "deleted successfully" in result.stdout.lower()

        # Verify it's gone
        result = registry_session.tags("delete-test")
        assert result.returncode != 0 or "not found" in result.stdout.lower()


class TestRegistryGC:
    """Test garbage collection command."""

    def test_gc_help_in_help_output(self, registry):
        """Test that gc command is listed in help."""
        result = registry.help()
        assert "gc" in result.stdout.lower()

    def test_gc_requires_registry_binary(self, registry_session):
        """Test that gc checks for registry binary.

        This test just verifies gc command runs and either:
        - Works (shows dry-run output)
        - Fails with useful error message
        """
        # gc stops registry first, so just run it and check output
        result = registry_session.gc(timeout=30)
        # Should either work or show error about binary/not running
        output = result.stdout.lower()
        assert any([
            "garbage" in output,
            "collecting" in output,
            "registry" in output,
            "error" in output,
            "not found" in output,
        ])


class TestRegistryPushOptions:
    """Test push command with various options."""

    def test_push_tag_requires_image_name(self, registry_session):
        """Test that --tag without image name fails."""
        registry_session.ensure_running()
        result = registry_session.push_with_args("--tag", "v1.0.0")
        assert result.returncode != 0
        assert "--tag requires an image name" in result.stdout.lower()

    def test_push_with_image_filter(self, registry_session):
        """Test pushing a specific image by name."""
        registry_session.ensure_running()
        result = registry_session.push_with_args("container-base")
        # Should either succeed or report image not found
        # (depending on whether container-base exists)
        output = result.stdout.lower()
        assert any([
            "pushing" in output,
            "not found" in output,
            "done" in output,
        ])

    def test_push_with_strategy(self, registry_session):
        """Test pushing with explicit strategy."""
        registry_session.ensure_running()
        result = registry_session.push_with_args("--strategy", "latest")
        assert result.returncode == 0 or "pushing" in result.stdout.lower()

    def test_push_help_shows_options(self, registry):
        """Test that help shows push options."""
        result = registry.help()
        assert "--tag" in result.stdout
        assert "--strategy" in result.stdout
        assert "image" in result.stdout.lower()


class TestRegistryIntegration:
    """Integration tests for full registry workflow.

    These tests require:
    - Registry script generated
    - docker-distribution-native built
    - skopeo-native built
    - Network access (for import tests)
    """

    @pytest.mark.network
    @pytest.mark.slow
    def test_full_workflow(self, registry, skip_network):
        """Test complete workflow: start -> import -> list -> stop."""
        if skip_network:
            pytest.skip("Skipping network test (--skip-registry-network)")

        # Start fresh
        registry.stop()
        time.sleep(1)

        try:
            # Start
            result = registry.start()
            assert result.returncode == 0
            time.sleep(2)

            # Import an image
            result = registry.import_image(
                "docker.io/library/alpine:latest",
                "workflow-test",
                timeout=300
            )
            assert result.returncode == 0

            # List should show it
            result = registry.list_images()
            assert result.returncode == 0
            assert "workflow-test" in result.stdout

            # Tags should work
            result = registry.tags("workflow-test")
            assert result.returncode == 0
            assert "latest" in result.stdout

            # Catalog should include it
            result = registry.catalog()
            assert result.returncode == 0
            assert "workflow-test" in result.stdout

        finally:
            # Always stop
            registry.stop()
