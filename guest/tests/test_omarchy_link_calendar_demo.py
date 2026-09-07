from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


GUEST = Path(__file__).resolve().parents[1]
REPOSITORY = GUEST.parent
LAUNCHER = GUEST / "native-overlay/usr/local/bin/omarchy-link-calendar-demo"
SURFACE = (
    GUEST
    / "native-overlay/usr/share/try-omarchy/development/omarchy-link-calendar/shell.qml"
)
INSTALLER = GUEST / "scripts/install-omarchy-link-development.sh"


class OmarchyLinkCalendarDemoTests(unittest.TestCase):
    def test_surface_fetches_broker_json_and_contains_no_event_fixtures(self) -> None:
        qml = SURFACE.read_text(encoding="utf-8")

        self.assertIn('"/usr/local/bin/omarchy-link", "demo-agenda"', qml)
        self.assertIn('"--range", root.selectedRange', qml)
        self.assertIn('"--calendar"', qml)
        self.assertIn("JSON.parse", qml)
        self.assertIn("Repeater", qml)
        self.assertNotIn("Project Aurora planning", qml)
        self.assertNotIn("Lunch with Morgan", qml)
        self.assertNotIn("Invented Focus", qml)
        self.assertNotIn("Invented Personal", qml)

    def test_surface_opens_the_canonical_create_request_in_a_visible_review_ui(self) -> None:
        qml = SURFACE.read_text(encoding="utf-8")

        self.assertIn('"foot"', qml)
        self.assertIn('"demo-create"', qml)
        self.assertIn('"--title", createTitle.text', qml)
        self.assertIn('"--start", createStart.text', qml)
        self.assertIn('"--end", createEnd.text', qml)
        self.assertIn('"--calendar"', qml)
        self.assertIn('"review.ui_unavailable"', qml)
        self.assertNotIn('"--approve"', qml)
        self.assertNotIn("calendar.events.create.perform", qml)
        self.assertNotIn("proposal.approve", qml)

    def test_launcher_requires_the_explicit_development_flag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            calls = temporary_path / "calls"
            quickshell = temporary_path / "quickshell"
            quickshell.write_text(
                f'#!/bin/bash\nprintf "%s\\n" "$*" >"{calls}"\n',
                encoding="utf-8",
            )
            quickshell.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{temporary_path}:{environment['PATH']}"
            environment.pop("OMARCHY_LINK_DEVELOPMENT", None)

            disabled = subprocess.run(
                [str(LAUNCHER)],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(disabled.returncode, 69)
            self.assertIn("OMARCHY_LINK_DEVELOPMENT=1", disabled.stderr)
            self.assertFalse(calls.exists())

            environment["OMARCHY_LINK_DEVELOPMENT"] = "1"
            subprocess.run([str(LAUNCHER)], env=environment, check=True)
            self.assertEqual(
                calls.read_text(encoding="utf-8").strip(),
                "-n -p /usr/share/try-omarchy/development/omarchy-link-calendar",
            )

    def test_native_adapter_and_bridge_never_request_permission(self) -> None:
        adapter = (
            REPOSITORY
            / "macos/Sources/OmarchyVMHelper/OmarchyLinkCalendarAdapter.swift"
        ).read_text(encoding="utf-8")
        helper_main = (
            REPOSITORY / "macos/Sources/OmarchyVMHelper/main.swift"
        ).read_text(encoding="utf-8")
        info = (REPOSITORY / "macos/Info.plist").read_text(encoding="utf-8")

        self.assertIn("EventKitOmarchyLinkCalendarAdapter", adapter)
        self.assertNotIn("requestFullAccessToEvents", adapter)
        self.assertNotIn("requestAccess", adapter)
        # Production Queries now route to EventKit (#11); permission prompting
        # still belongs exclusively to the visible Mac start-menu surface.

        # The grant-status ticket added exactly one permission surface: the
        # declared full-access usage description and the visible start-menu
        # request in OmarchyLinkCalendarAccess. The bridge and adapter still
        # only read status and never prompt.
        access = (
            REPOSITORY
            / "macos/Sources/OmarchyVMHelper/OmarchyLinkCalendarAccess.swift"
        ).read_text(encoding="utf-8")
        self.assertIn("NSCalendarsFullAccessUsageDescription", info)
        self.assertNotIn("NSCalendarsWriteOnlyAccessUsageDescription", info)
        self.assertIn("requestFullAccessToEvents", access)
        self.assertNotIn("requestFullAccessToEvents", helper_main)

    def test_factory_build_installs_the_offline_broker_without_enabling_ui(self) -> None:
        build = (GUEST / "build.sh").read_text(encoding="utf-8")
        finalizer = (GUEST / "scripts/finalize-rootfs.sh").read_text(encoding="utf-8")
        self.assertIn("install-omarchy-link-development.sh", build)
        self.assertNotIn("omarchy-link-calendar-demo", finalizer)

        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            root = temporary_path / "root"
            work = temporary_path / "work"
            fake_bin = temporary_path / "bin"
            root.mkdir()
            work.mkdir()
            fake_bin.mkdir()
            cargo = fake_bin / "cargo"
            cargo.write_text(
                "#!/bin/bash\n"
                "set -e\n"
                'mkdir -p "$CARGO_TARGET_DIR/release"\n'
                'printf \'#!/bin/bash\\n\' >"$CARGO_TARGET_DIR/release/omarchy-link"\n'
                'chmod 0755 "$CARGO_TARGET_DIR/release/omarchy-link"\n',
                encoding="utf-8",
            )
            cargo.chmod(0o755)
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"

            subprocess.run(
                [str(INSTALLER), "--root", str(root), "--work", str(work)],
                env=environment,
                text=True,
                capture_output=True,
                check=True,
            )
            installed = root / "usr/local/bin/omarchy-link"
            self.assertTrue(installed.is_file())
            self.assertTrue(installed.stat().st_mode & 0o100)


if __name__ == "__main__":
    unittest.main()
