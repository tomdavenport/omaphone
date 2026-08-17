"""Security-focused, side-effect-free tests for the Omaphone Python backend.

The suite deliberately avoids the daemon, Tor, audio programs, networking, root,
and desktop integration.  Every filesystem test is contained in a temporary XDG
layout and every executable lookup or downloader is supplied as a fake.
"""

from __future__ import annotations

import base64
import errno
import hashlib
import hmac
import importlib.util
import io
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
BACKEND_PATH = REPOSITORY_ROOT / "scripts" / "omaphone.py"
SPEC = importlib.util.spec_from_file_location("omaphone_backend_under_test", BACKEND_PATH)
if SPEC is None or SPEC.loader is None:  # pragma: no cover - a broken checkout
    raise RuntimeError(f"cannot load backend from {BACKEND_PATH}")
omaphone = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = omaphone
SPEC.loader.exec_module(omaphone)


VALID_SECRET = "s" * 43
VALID_ONION = "a" * 56 + ".onion"
SECOND_ONION = "b" * 56 + ".onion"


def mode_of(path: Path) -> int:
    return stat.S_IMODE(path.stat().st_mode)


def make_paths(root: Path) -> object:
    return omaphone.Paths.from_environment(
        {
            "HOME": str(root / "home"),
            "XDG_DATA_HOME": str(root / "data"),
            "XDG_STATE_HOME": str(root / "state"),
            "XDG_RUNTIME_DIR": str(root / "runtime"),
        }
    )


def encode_invite(payload: object, secret: str = VALID_SECRET) -> str:
    payload_bytes = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    tag = hmac.new(
        secret.encode("ascii"), b"omaphone-invite-v1\0" + payload_bytes, hashlib.sha256
    ).digest()
    encoded = base64.urlsafe_b64encode(payload_bytes + tag).decode("ascii").rstrip("=")
    return omaphone.INVITE_PREFIX + encoded


class FakeUnixSocket:
    """Minimal socket double used for both sides of the JSON-line protocol."""

    def __init__(
        self,
        incoming: list[bytes] | tuple[bytes, ...] = (),
        *,
        peer_uid: int | None = None,
        connect_error: OSError | None = None,
    ) -> None:
        self.incoming = list(incoming)
        self.peer_uid = os.getuid() if peer_uid is None else peer_uid
        self.connect_error = connect_error
        self.timeout: float | None = None
        self.connected_to: str | None = None
        self.sent: list[bytes] = []
        self.closed = False

    def settimeout(self, timeout: float) -> None:
        self.timeout = timeout

    def connect(self, destination: str) -> None:
        if self.connect_error is not None:
            raise self.connect_error
        self.connected_to = destination

    def sendall(self, payload: bytes) -> None:
        self.sent.append(payload)

    def recv(self, _size: int) -> bytes:
        return self.incoming.pop(0) if self.incoming else b""

    def getsockopt(self, _level: int, _option: int, _size: int) -> bytes:
        return (
            (1234).to_bytes(4, sys.byteorder)
            + self.peer_uid.to_bytes(4, sys.byteorder)
            + (5678).to_bytes(4, sys.byteorder)
        )

    def close(self) -> None:
        self.closed = True


class TemporaryPathsTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(prefix="omaphone-tests-")
        self.root = Path(self.temporary_directory.name)
        self.paths = make_paths(self.root)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()


class PathAndPermissionTests(TemporaryPathsTestCase):
    def test_paths_honor_all_xdg_locations(self) -> None:
        self.assertEqual(self.paths.data_dir, self.root / "data" / "omaphone")
        self.assertEqual(self.paths.state_dir, self.root / "state" / "omaphone")
        self.assertEqual(self.paths.runtime_dir, self.root / "runtime" / "omaphone")
        self.assertEqual(self.paths.secret_file, self.paths.upstream_data / "shared_secret")
        self.assertEqual(self.paths.socket_file, self.paths.runtime_dir / "daemon.sock")

    def test_home_fallback_locations_are_scoped_below_home(self) -> None:
        home = self.root / "isolated-home"
        paths = omaphone.Paths.from_environment({"HOME": str(home)})
        self.assertEqual(paths.data_dir, home / ".local" / "share" / "omaphone")
        self.assertEqual(paths.state_dir, home / ".local" / "state" / "omaphone")
        self.assertNotEqual(paths.runtime_dir, home)

    def test_layout_and_files_are_private(self) -> None:
        omaphone.ensure_layout(self.paths)
        directories = (
            self.paths.data_dir,
            self.paths.state_dir,
            self.paths.runtime_dir,
            self.paths.upstream_dir,
            self.paths.upstream_data,
        )
        for directory in directories:
            with self.subTest(directory=directory):
                self.assertTrue(directory.is_dir())
                self.assertEqual(mode_of(directory), 0o700)

        destination = self.paths.state_dir / "private.txt"
        omaphone.atomic_write(destination, b"private")
        self.assertEqual(destination.read_bytes(), b"private")
        self.assertEqual(mode_of(destination), 0o600)
        self.assertEqual(list(destination.parent.glob(f".{destination.name}.*.tmp")), [])

    def test_existing_directory_permissions_are_tightened(self) -> None:
        self.paths.state_dir.mkdir(parents=True, mode=0o755)
        os.chmod(self.paths.state_dir, 0o755)
        omaphone.ensure_private_dir(self.paths.state_dir)
        self.assertEqual(mode_of(self.paths.state_dir), 0o700)

    def test_symlink_is_rejected_as_an_application_directory(self) -> None:
        target = self.root / "target"
        target.mkdir()
        link = self.root / "link"
        link.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(omaphone.OmaphoneError, "unsafe application directory"):
            omaphone.ensure_private_dir(link)

    def test_atomic_write_replaces_destination_symlink_without_following_it(self) -> None:
        omaphone.ensure_private_dir(self.paths.state_dir)
        outside = self.root / "outside.txt"
        outside.write_bytes(b"do not overwrite")
        destination = self.paths.state_dir / "status.json"
        destination.symlink_to(outside)

        omaphone.atomic_write(destination, b"replacement")

        self.assertFalse(destination.is_symlink())
        self.assertEqual(destination.read_bytes(), b"replacement")
        self.assertEqual(outside.read_bytes(), b"do not overwrite")
        self.assertEqual(mode_of(destination), 0o600)

    def test_atomic_json_is_compact_utf8_newline_terminated_and_private(self) -> None:
        destination = self.paths.state_dir / "value.json"
        omaphone.atomic_json(destination, {"message": "café", "value": 1})
        self.assertEqual(destination.read_text("utf-8"), '{"message":"café","value":1}\n')
        self.assertEqual(mode_of(destination), 0o600)

    def test_read_json_rejects_invalid_utf8_invalid_json_and_oversized_files(self) -> None:
        omaphone.ensure_private_dir(self.paths.state_dir)
        destination = self.paths.state_dir / "input.json"
        for payload in (b"\xff", b"{not json", b" " * (omaphone.MAX_REQUEST_BYTES + 1)):
            with self.subTest(payload_size=len(payload)):
                destination.write_bytes(payload)
                self.assertEqual(omaphone.read_json(destination, {"safe": True}), {"safe": True})


class ReleaseContractTests(unittest.TestCase):
    def test_manifest_version_matches_backend_handshake_version(self) -> None:
        manifest = json.loads((REPOSITORY_ROOT / "manifest.json").read_text("utf-8"))
        self.assertEqual(manifest["version"], omaphone.BACKEND_VERSION)


class PinnedAssetTests(TemporaryPathsTestCase):
    BUNDLED_ASSETS = (
        ("terminalphone.sh", "upstream_script", "UPSTREAM_SHA256", "TerminalPhone source"),
        (
            "TerminalPhone-LICENSE",
            "upstream_license",
            "UPSTREAM_LICENSE_SHA256",
            "TerminalPhone license",
        ),
    )

    def test_upstream_asset_urls_are_commit_pinned_and_digests_are_sha256(self) -> None:
        self.assertRegex(omaphone.UPSTREAM_COMMIT, r"\A[0-9a-f]{40}\Z")
        for url, digest in (
            (omaphone.UPSTREAM_URL, omaphone.UPSTREAM_SHA256),
            (omaphone.UPSTREAM_LICENSE_URL, omaphone.UPSTREAM_LICENSE_SHA256),
        ):
            with self.subTest(url=url):
                self.assertIn("/" + omaphone.UPSTREAM_COMMIT + "/", url)
                self.assertNotIn("/main/", url)
                self.assertNotIn("/master/", url)
                self.assertRegex(digest, r"\A[0-9a-f]{64}\Z")

    def test_bundled_assets_exactly_match_pinned_upstream_hashes(self) -> None:
        vendor = REPOSITORY_ROOT / "vendor"
        for filename, _destination, digest_name, label in self.BUNDLED_ASSETS:
            with self.subTest(filename=filename):
                payload = (vendor / filename).read_bytes()
                expected_digest = getattr(omaphone, digest_name)
                self.assertEqual(hashlib.sha256(payload).hexdigest(), expected_digest)
                self.assertIs(omaphone.verify_asset(payload, expected_digest, label), payload)

    def test_default_install_uses_verified_bundled_assets_without_network(self) -> None:
        vendor = REPOSITORY_ROOT / "vendor"
        with mock.patch.object(
            omaphone.urllib.request,
            "urlopen",
            side_effect=AssertionError("default install attempted network access"),
        ) as open_url:
            omaphone.install_pinned_backend(self.paths)

        open_url.assert_not_called()
        for filename, destination_name, _digest_name, _label in self.BUNDLED_ASSETS:
            with self.subTest(filename=filename):
                destination = getattr(self.paths, destination_name)
                self.assertEqual(destination.read_bytes(), (vendor / filename).read_bytes())
                self.assertEqual(mode_of(destination), 0o600)

    def test_default_install_fails_closed_for_missing_or_tampered_bundle(self) -> None:
        missing = self.root / "missing-terminalphone.sh"
        tampered = self.root / "tampered-terminalphone.sh"
        tampered.write_bytes(b"#!/bin/sh\necho attacker-controlled replacement\n")

        cases = (
            (missing, "could not read bundled TerminalPhone source"),
            (tampered, "SHA-256 mismatch"),
        )
        for bundled_script, expected_error in cases:
            with self.subTest(expected_error=expected_error):
                with (
                    mock.patch.object(
                        omaphone, "BUNDLED_UPSTREAM_SCRIPT", bundled_script
                    ),
                    mock.patch.object(
                        omaphone.urllib.request,
                        "urlopen",
                        side_effect=AssertionError("bundle failure fell back to the network"),
                    ) as open_url,
                ):
                    with self.assertRaisesRegex(omaphone.OmaphoneError, expected_error):
                        omaphone.install_pinned_backend(self.paths)

                open_url.assert_not_called()
                self.assertFalse(self.paths.upstream_script.exists())
                self.assertFalse(self.paths.upstream_license.exists())

    def test_verify_asset_accepts_only_exact_nonempty_bounded_sha256(self) -> None:
        payload = b"known pinned bytes"
        digest = hashlib.sha256(payload).hexdigest()
        self.assertIs(omaphone.verify_asset(payload, digest, "fixture"), payload)

        invalid_cases = (
            (b"", hashlib.sha256(b"").hexdigest(), "unexpected size"),
            (b"different", digest, "SHA-256 mismatch"),
            (b"x" * (omaphone.MAX_DOWNLOAD_BYTES + 1), digest, "unexpected size"),
        )
        for data, expected, message in invalid_cases:
            with self.subTest(message=message):
                with self.assertRaisesRegex(omaphone.OmaphoneError, message):
                    omaphone.verify_asset(data, expected, "fixture")

    def test_asset_is_valid_requires_regular_bounded_exact_file(self) -> None:
        payload = b"asset"
        digest = hashlib.sha256(payload).hexdigest()
        regular = self.root / "asset"
        regular.write_bytes(payload)
        self.assertTrue(omaphone.asset_is_valid(regular, digest))
        self.assertFalse(omaphone.asset_is_valid(regular, "0" * 64))
        self.assertFalse(omaphone.asset_is_valid(self.root / "missing", digest))
        self.assertFalse(omaphone.asset_is_valid(self.root, digest))
        symlink = self.root / "asset-link"
        symlink.symlink_to(regular)
        self.assertFalse(omaphone.asset_is_valid(symlink, digest))
        regular.write_bytes(b"x" * (omaphone.MAX_DOWNLOAD_BYTES + 1))
        self.assertFalse(omaphone.asset_is_valid(regular, hashlib.sha256(regular.read_bytes()).hexdigest()))

    def test_install_pinned_backend_uses_exact_urls_hashes_and_private_modes(self) -> None:
        script = b"#!/bin/sh\nexit 0\n"
        license_text = b"fixture license\n"
        fetched_urls: list[str] = []

        def fetcher(url: str) -> bytes:
            fetched_urls.append(url)
            return {
                "https://fixture.invalid/source": script,
                "https://fixture.invalid/license": license_text,
            }[url]

        patches = (
            mock.patch.object(omaphone, "UPSTREAM_URL", "https://fixture.invalid/source"),
            mock.patch.object(omaphone, "UPSTREAM_LICENSE_URL", "https://fixture.invalid/license"),
            mock.patch.object(omaphone, "UPSTREAM_SHA256", hashlib.sha256(script).hexdigest()),
            mock.patch.object(
                omaphone, "UPSTREAM_LICENSE_SHA256", hashlib.sha256(license_text).hexdigest()
            ),
        )
        with patches[0], patches[1], patches[2], patches[3]:
            omaphone.install_pinned_backend(self.paths, fetcher=fetcher)
            self.assertTrue(omaphone.backend_installed(self.paths))

            self.assertEqual(fetched_urls, ["https://fixture.invalid/source", "https://fixture.invalid/license"])
            self.assertEqual(self.paths.upstream_script.read_bytes(), script)
            self.assertEqual(self.paths.upstream_license.read_bytes(), license_text)
            self.assertEqual(mode_of(self.paths.upstream_script), 0o600)
            self.assertEqual(mode_of(self.paths.upstream_license), 0o600)

            fetched_urls.clear()
            os.chmod(self.paths.upstream_script, 0o777)
            omaphone.install_pinned_backend(self.paths, fetcher=fetcher)
            self.assertEqual(fetched_urls, [])
            self.assertEqual(mode_of(self.paths.upstream_script), 0o600)

    def test_install_rejects_download_with_wrong_hash(self) -> None:
        expected = b"expected"
        with (
            mock.patch.object(omaphone, "UPSTREAM_URL", "https://fixture.invalid/source"),
            mock.patch.object(omaphone, "UPSTREAM_SHA256", hashlib.sha256(expected).hexdigest()),
        ):
            with self.assertRaisesRegex(omaphone.OmaphoneError, "SHA-256 mismatch"):
                omaphone.install_pinned_backend(self.paths, fetcher=lambda _url: b"attacker bytes")
        self.assertFalse(self.paths.upstream_script.exists())


class SecretAndInviteTests(TemporaryPathsTestCase):
    def test_room_secret_round_trip_is_valid_and_private(self) -> None:
        generated = omaphone.ensure_room_secret(self.paths)
        self.assertTrue(omaphone.valid_secret(generated))
        self.assertEqual(omaphone.read_secret(self.paths), generated)
        self.assertEqual(mode_of(self.paths.secret_file), 0o600)

        os.chmod(self.paths.secret_file, 0o644)
        self.assertEqual(omaphone.ensure_room_secret(self.paths), generated)
        self.assertEqual(mode_of(self.paths.secret_file), 0o600)

    def test_invalid_or_oversized_secret_file_is_not_accepted(self) -> None:
        omaphone.ensure_private_dir(self.paths.secret_file.parent)
        for value in ("short", "a" * 513, "a" * 42 + "!"):
            with self.subTest(length=len(value)):
                self.paths.secret_file.write_text(value, encoding="utf-8")
                self.assertEqual(omaphone.read_secret(self.paths), "")

    def test_invite_round_trip_with_and_without_address(self) -> None:
        no_address = omaphone.parse_invite(omaphone.create_invite(VALID_SECRET))
        self.assertEqual(no_address, omaphone.Invite(VALID_SECRET, "", True))

        invitation = omaphone.create_invite(VALID_SECRET, f"HTTPS://{VALID_ONION.upper()}///")
        self.assertTrue(invitation.startswith(omaphone.INVITE_PREFIX))
        self.assertEqual(
            omaphone.parse_invite(f" \n{invitation}\t"),
            omaphone.Invite(VALID_SECRET, VALID_ONION, True),
        )

        hmac_disabled = omaphone.create_invite(VALID_SECRET, SECOND_ONION, hmac_enabled=False)
        self.assertEqual(
            omaphone.parse_invite(hmac_disabled),
            omaphone.Invite(VALID_SECRET, SECOND_ONION, False),
        )

        legacy = encode_invite({"address": "", "secret": VALID_SECRET, "version": 1})
        self.assertEqual(omaphone.parse_invite(legacy), omaphone.Invite(VALID_SECRET, "", True))

    def test_invite_tampering_is_rejected(self) -> None:
        invitation = omaphone.create_invite(VALID_SECRET, VALID_ONION)
        encoded = invitation[len(omaphone.INVITE_PREFIX) :]
        raw = bytearray(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        raw[5] ^= 1
        tampered = omaphone.INVITE_PREFIX + base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
        with self.assertRaises(omaphone.OmaphoneError):
            omaphone.parse_invite(tampered)

        raw = bytearray(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
        raw[-1] ^= 1
        bad_tag = omaphone.INVITE_PREFIX + base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
        with self.assertRaisesRegex(omaphone.OmaphoneError, "checksum"):
            omaphone.parse_invite(bad_tag)

    def test_invite_rejects_malformed_unsupported_and_oversized_values(self) -> None:
        invalid_values = (
            "not-an-invite",
            omaphone.INVITE_PREFIX + "%%not-base64%%",
            omaphone.INVITE_PREFIX + "\U0001f4a5",
            omaphone.INVITE_PREFIX + "\ud800",
            omaphone.INVITE_PREFIX + "a" * omaphone.MAX_INVITE_BYTES,
        )
        for value in invalid_values:
            with self.subTest(value=value[:40]):
                with self.assertRaises(omaphone.OmaphoneError):
                    omaphone.parse_invite(value)

        unsupported = encode_invite({"address": "", "secret": VALID_SECRET, "version": 2})
        with self.assertRaisesRegex(omaphone.OmaphoneError, "unsupported"):
            omaphone.parse_invite(unsupported)

    def test_invite_rejects_authenticated_but_invalid_fields(self) -> None:
        cases = (
            {"address": "", "secret": "short", "version": 1},
            {"address": 7, "secret": VALID_SECRET, "version": 1},
            {"address": "example.com", "secret": VALID_SECRET, "version": 1},
            {
                "address": "",
                "roomSettings": {"hmac": "false"},
                "secret": VALID_SECRET,
                "version": 1,
            },
            {
                "address": "",
                "roomSettings": {"hmac": True, "unknown": False},
                "secret": VALID_SECRET,
                "version": 1,
            },
            ["not", "an", "object"],
        )
        for payload in cases:
            with self.subTest(payload=payload):
                with self.assertRaises(omaphone.OmaphoneError):
                    omaphone.parse_invite(encode_invite(payload))

    def test_status_never_serializes_room_secret(self) -> None:
        omaphone.atomic_write(self.paths.secret_file, VALID_SECRET.encode("ascii"))
        omaphone.atomic_json(
            self.paths.status_file,
            {"secret": VALID_SECRET, "messages": [{"direction": "system", "text": "safe"}]},
        )
        with (
            mock.patch.object(omaphone, "backend_installed", return_value=True),
            mock.patch.object(omaphone, "dependency_status", return_value=[]),
        ):
            status_value = omaphone.build_initial_status(self.paths)

        serialized = json.dumps(status_value, sort_keys=True)
        self.assertNotIn(VALID_SECRET, serialized)
        self.assertNotIn("secret", status_value)
        self.assertTrue(status_value["configured"])


class OnionValidationTests(TemporaryPathsTestCase):
    def test_normalize_accepts_only_v3_base32_host_with_optional_http_scheme(self) -> None:
        accepted = (
            (VALID_ONION, VALID_ONION),
            (VALID_ONION.upper(), VALID_ONION),
            (f" HTTP://{VALID_ONION.upper()}/ ", VALID_ONION),
            (f"https://{VALID_ONION}///", VALID_ONION),
            ("2" * 56 + ".onion", "2" * 56 + ".onion"),
            ("7" * 56 + ".onion", "7" * 56 + ".onion"),
        )
        for supplied, expected in accepted:
            with self.subTest(supplied=supplied):
                self.assertEqual(omaphone.normalize_onion_address(supplied), expected)

    def test_normalize_rejects_non_v3_or_non_hostname_inputs(self) -> None:
        rejected = (
            "",
            "a" * 55 + ".onion",
            "a" * 57 + ".onion",
            "0" * 56 + ".onion",
            "1" * 56 + ".onion",
            "8" * 56 + ".onion",
            "a" * 16 + ".onion",
            VALID_ONION + ".example.com",
            VALID_ONION + ":80",
            VALID_ONION + "/path",
            VALID_ONION + "?query=yes",
            "user@" + VALID_ONION,
            "ftp://" + VALID_ONION,
            "http://" + VALID_ONION + "@example.com",
            "http://" + VALID_ONION + "/path",
            VALID_ONION + "\x00",
            "á" * 56 + ".onion",
        )
        for value in rejected:
            with self.subTest(value=repr(value)):
                with self.assertRaisesRegex(omaphone.OmaphoneError, "v3 56-character"):
                    omaphone.normalize_onion_address(value)

    def test_read_onion_returns_only_a_strict_hostname(self) -> None:
        omaphone.ensure_private_dir(self.paths.onion_file.parent)
        self.paths.onion_file.write_text(f" {VALID_ONION.upper()}\n", encoding="ascii")
        self.assertEqual(omaphone.read_onion(self.paths), VALID_ONION)
        for bad in ("http://" + VALID_ONION, VALID_ONION + "/", "x\n" + VALID_ONION):
            with self.subTest(bad=bad[:20]):
                self.paths.onion_file.write_text(bad, encoding="ascii")
                self.assertEqual(omaphone.read_onion(self.paths), "")


class ConfigurationTests(TemporaryPathsTestCase):
    def test_parse_bool_is_explicit_and_does_not_use_truthiness(self) -> None:
        for value, expected in ((True, True), (False, False), ("true", True), ("TRUE", True), ("false", False)):
            with self.subTest(value=value):
                self.assertIs(omaphone.parse_bool(value), expected)
        for value in (1, 0, None, "yes", " false ", [], {}):
            with self.subTest(value=value):
                with self.assertRaises(omaphone.OmaphoneError):
                    omaphone.parse_bool(value)

    def test_validate_config_value_accepts_only_documented_values(self) -> None:
        for value in omaphone.QUALITY_BITRATE:
            self.assertEqual(omaphone.validate_config_value("quality", value), value)
        for value in omaphone.VOICE_EFFECTS:
            self.assertEqual(omaphone.validate_config_value("voiceEffect", value), value)
        for value in omaphone.CHIMES:
            self.assertEqual(omaphone.validate_config_value("chime", value), value)
        self.assertTrue(omaphone.validate_config_value("snowflake", "true"))
        self.assertFalse(omaphone.validate_config_value("hmac", False))

        rejected = (
            ("quality", "maximum"),
            ("quality", 16),
            ("voiceEffect", 'none"\nEVIL=1'),
            ("chime", "beep"),
            ("snowflake", 1),
            ("unknown", "value"),
        )
        for key, value in rejected:
            with self.subTest(key=key, value=value):
                with self.assertRaises(omaphone.OmaphoneError):
                    omaphone.validate_config_value(key, value)

    def test_load_config_merges_defaults_and_ignores_invalid_values(self) -> None:
        omaphone.atomic_json(
            self.paths.app_config,
            {
                "settings": {
                    "quality": "high",
                    "voiceEffect": "invalid",
                    "chime": "ding",
                    "snowflake": "true",
                    "hmac": 1,
                    "unknown": "ignored",
                },
                "peerAddress": VALID_ONION,
            },
        )
        loaded = omaphone.load_app_config(self.paths)
        expected_settings = dict(omaphone.DEFAULT_SETTINGS)
        expected_settings.update(
            quality="high", voiceEffect="none", chime="ding", snowflake=True
        )
        self.assertEqual(
            loaded,
            {
                "settings": expected_settings,
                "peerAddress": VALID_ONION,
            },
        )

    def test_load_config_rejects_bad_shapes_and_noncanonical_peer(self) -> None:
        cases = (
            [],
            {"settings": []},
            {"settings": {}, "peerAddress": 42},
            {"settings": {}, "peerAddress": "https://" + VALID_ONION},
            {"settings": {}, "peerAddress": VALID_ONION.upper()},
        )
        for raw in cases:
            with self.subTest(raw=raw):
                omaphone.atomic_json(self.paths.app_config, raw)
                loaded = omaphone.load_app_config(self.paths)
                self.assertEqual(loaded["settings"], omaphone.DEFAULT_SETTINGS)
                self.assertEqual(loaded["peerAddress"], "")

    def test_save_config_serializes_app_and_exact_safe_upstream_format(self) -> None:
        config = {
            "settings": {
                "quality": "high",
                "voiceEffect": "robot",
                "chime": "double",
                "snowflake": True,
                "hmac": False,
            },
            "peerAddress": SECOND_ONION,
        }
        omaphone.save_app_config(self.paths, config)

        self.assertEqual(json.loads(self.paths.app_config.read_text("utf-8")), config)
        self.assertEqual(
            self.paths.upstream_config.read_text("ascii"),
            "OPUS_BITRATE=24\n"
            'VOICE_EFFECT="robot"\n'
            'PTT_CHIME="double"\n'
            "SNOWFLAKE_ENABLED=1\n"
            "HMAC_AUTH=0\n"
            "AUTO_LISTEN=0\n",
        )
        self.assertEqual(mode_of(self.paths.app_config), 0o600)
        self.assertEqual(mode_of(self.paths.upstream_config), 0o600)

    def test_desired_state_round_trip_is_private(self) -> None:
        for value in (True, False):
            with self.subTest(value=value):
                omaphone.save_desired_online(self.paths, value)
                self.assertIs(omaphone.desired_online(self.paths), value)
                self.assertEqual(mode_of(self.paths.desired_state), 0o600)

    def test_default_status_contains_a_copy_of_defaults_and_no_secret_field(self) -> None:
        first = omaphone.status_defaults()
        second = omaphone.status_defaults()
        self.assertEqual(first["settings"], omaphone.DEFAULT_SETTINGS)
        self.assertNotIn("secret", first)
        first["settings"]["hmac"] = not first["settings"]["hmac"]
        self.assertEqual(second["settings"], omaphone.DEFAULT_SETTINGS)
        self.assertEqual(set(first), set(second))


class TerminalSanitizerTests(unittest.TestCase):
    def test_removes_csi_sgr_cursor_and_private_mode_sequences(self) -> None:
        text = "before\x1b[31mred\x1b[0m\x1b[2J\x1b[Hafter"
        self.assertEqual(omaphone.sanitize_terminal_text(text), "beforeredafter")

    def test_removes_osc_with_bel_or_string_terminator(self) -> None:
        text = "a\x1b]0;malicious title\x07b\x1b]52;c;clipboard-data\x1b\\c"
        self.assertEqual(omaphone.sanitize_terminal_text(text), "abc")

    def test_removes_dcs_pm_apc_and_sos_strings(self) -> None:
        text = (
            "a\x1bP1;2;payload\x1b\\b"
            "\x1b^private message\x1b\\c"
            "\x1b_secret\x07d"
            "\x1bXstart of string\x1b\\e"
        )
        self.assertEqual(omaphone.sanitize_terminal_text(text), "abcde")

    def test_removes_c0_del_and_c1_controls_but_keeps_tab_and_newline(self) -> None:
        # C1 string introducers (DCS/SOS/CSI/OSC/PM/APC) are exercised below
        # with their terminators; an unterminated one must suppress its tail.
        controls = "\x00\x01\x08\x0b\x0c\x0e\x1f\x7f\x80\x85\x89"
        self.assertEqual(omaphone.sanitize_terminal_text("a" + controls + "b\tc\nd"), "ab\tc\nd")

    def test_removes_eight_bit_c1_csi_osc_dcs_and_string_terminator_sequences(self) -> None:
        text = (
            "a\u009b31mred\u009b0mb"
            "\u009d0;hidden title\u009cc"
            "\u0090hidden dcs\u009cd"
            "\u009eprivate message\u009ce"
            "\u009fapplication command\u009cf"
        )
        self.assertEqual(omaphone.sanitize_terminal_text(text), "aredbcdef")

    def test_escape_inside_csi_starts_a_new_control_sequence_without_leaking_payload(self) -> None:
        text = "a\x1b[31\x1b]0;hidden title\x07b\x1b[2\x1bPsecret dcs\x1b\\c"
        self.assertEqual(omaphone.sanitize_terminal_text(text), "abc")

    def test_incremental_cleaner_handles_split_utf8_and_escape_sequences(self) -> None:
        cleaner = omaphone.AnsiCleaner()
        chunks = (
            b"caf\xc3",
            b"\xa9\x1b]52;c;do-not-show",
            b"\x1b",
            b"\\safe\x1b[3",
            b"1mred\x1b[0m",
        )
        self.assertEqual("".join(cleaner.feed(chunk) for chunk in chunks), "cafésafered")

    def test_incomplete_control_string_is_not_exposed(self) -> None:
        self.assertEqual(omaphone.sanitize_terminal_text("safe\x1b]0;hidden forever"), "safe")
        cleaner = omaphone.AnsiCleaner()
        self.assertEqual(cleaner.feed(b"safe\x1bPsecret"), "safe")
        self.assertEqual(cleaner.feed(b" still secret"), "")

    def test_malformed_utf8_is_replaced_not_raised(self) -> None:
        cleaner = omaphone.AnsiCleaner()
        self.assertEqual(cleaner.feed(b"a\xffb"), "a\ufffdb")


class OutputParserTests(unittest.TestCase):
    def assertHasEvent(self, events: list[object], kind: str, value: str = "") -> None:
        self.assertIn(omaphone.OutputEvent(kind, value), events)

    def test_parses_prompts_and_call_state(self) -> None:
        cases = (
            ("Protect it with a passphrase? [Y/n]:", "migration_prompt"),
            ("Enter .onion address:", "address_prompt"),
            ("Start relay? [Y/n]:", "relay_prompt"),
            ("Continue? [y/N]:", "rotate_prompt"),
            ("Select:   ", "menu_prompt"),
            ("Press Enter to continue", "continue_prompt"),
            ("MSG>", "message_prompt"),
            ("Incoming call detected!", "connected"),
            ("Call connected!", "connected"),
            ("Listening for Calls", "listening"),
            ("Waiting for incoming connection", "listening"),
            ("Audio Loopback Test", "testing"),
            ("Relay active", "relay"),
            ("Remote party hung up", "call_ended"),
            ("Connection lost", "call_ended"),
            ("CALL ENDED", "call_ended"),
        )
        for text, kind in cases:
            with self.subTest(text=text):
                self.assertHasEvent(omaphone.parse_terminal_output(text), kind)

    def test_parses_onion_connected_and_talking_events(self) -> None:
        events = omaphone.parse_terminal_output(
            f"Your address: {VALID_ONION.upper()}\n"
            f"Relay address: {SECOND_ONION}\n"
            f"CALL CONNECTED {VALID_ONION.upper()}\n"
            "Remote: ● Recording\nRemote: Idle"
        )
        self.assertHasEvent(events, "onion", VALID_ONION)
        self.assertHasEvent(events, "onion", SECOND_ONION)
        self.assertHasEvent(events, "connected", VALID_ONION)
        self.assertHasEvent(events, "remote_talking", "true")
        self.assertHasEvent(events, "remote_talking", "false")

    def test_group_header_is_an_exact_control_and_room_counts_are_bounded(self) -> None:
        events = omaphone.parse_terminal_output(
            "\x1b[1;42m CALL CONNECTED \x1b[0m \x1b[36mRELAY (group)\x1b[0m\n"
            "  Group:      3 callers\n"
            "  Callers: 12  Uptime: 0m 04s"
        )
        self.assertHasEvent(events, "connected_group")
        self.assertNotIn("connected", {event.kind for event in events})
        self.assertHasEvent(events, "room_size", "3")
        self.assertHasEvent(events, "room_size", "12")

        invalid_displays = (
            "CALL CONNECTED RELAY (GROUP)",
            "CALL CONNECTED RELAY (group) extra",
            "Group: -1 callers",
            f"Group: {omaphone.MAX_ROOM_SIZE + 1} callers",
            "Callers: 999999 Uptime: 1m",
        )
        for display in invalid_displays:
            with self.subTest(display=display):
                parsed = omaphone.parse_terminal_output(display)
                self.assertNotIn("connected_group", {event.kind for event in parsed})
                self.assertNotIn("room_size", {event.kind for event in parsed})

    def test_incremental_room_displays_work_without_newlines_and_track_repeated_sizes(self) -> None:
        parser = omaphone.OutputStreamParser()
        _cleaned, header_one = parser.feed(b"\x1b[1;42m CALL CONNE")
        _cleaned, header_two = parser.feed(b"CTED \x1b[0m \x1b[36mRELAY (group)\x1b[0m\n")
        self.assertEqual(header_one, [])
        self.assertHasEvent(header_two, "connected_group")

        _cleaned, count_one = parser.feed(b"\x1b[s\x1b[12;1H\x1b[K  Group: \x1b[0m2 call")
        _cleaned, count_two = parser.feed(b"ers\x1b[0m\x1b[u")
        _cleaned, count_three = parser.feed(b"\x1b[s\x1b[12;1H\x1b[K  Group: 4 callers\x1b[u")
        _cleaned, count_four = parser.feed(b"\x1b[s\x1b[12;1H\x1b[K  Group: 2 callers\x1b[u")
        self.assertEqual(count_one, [])
        self.assertEqual(count_two, [omaphone.OutputEvent("room_size", "2")])
        self.assertEqual(count_three, [omaphone.OutputEvent("room_size", "4")])
        self.assertEqual(count_four, [omaphone.OutputEvent("room_size", "2")])

        _cleaned, relay_one = parser.feed(b"\r  \x1b[1mCallers:\x1b[0m 7")
        _cleaned, relay_two = parser.feed(b"  Uptime: 0m 02s")
        self.assertEqual(relay_one, [omaphone.OutputEvent("room_size", "7")])
        self.assertEqual(relay_two, [])

    def test_message_and_error_values_are_sanitized_and_bounded(self) -> None:
        long_message = "word " + "x" * (omaphone.MAX_MESSAGE_CHARS + 100)
        events = omaphone.parse_terminal_output(
            "[MSG] hello\t there \x1b]52;c;secret\x07 world\x00\n"
            "[you] " + long_message + "\n"
            "[FAIL] \x1b[31m bad   news \x1b[0m"
        )
        self.assertHasEvent(events, "incoming_message", "hello there world")
        outgoing = next(event for event in events if event.kind == "outgoing_message")
        self.assertLessEqual(len(outgoing.value), omaphone.MAX_MESSAGE_CHARS)
        self.assertNotIn("\x1b", outgoing.value)
        self.assertHasEvent(events, "error", "bad news")

    def test_chat_lines_never_promote_control_looking_text_to_control_events(self) -> None:
        control_looking_messages = (
            f"Enter .onion address: CALL CONNECTED {VALID_ONION}",
            "CALL CONNECTED RELAY (group)",
            "Group: 99 callers Callers: 99 Uptime: 1m",
            f"Your address: {VALID_ONION} Listening for Calls",
            "Remote: ● Recording MSG> [FAIL] pretend failure",
            "Start relay? [Y/n]: Continue? [y/N]: Select:",
            "Press Enter to continue Audio Loopback Test Relay active CALL ENDED",
        )
        for marker, expected_kind in (("[MSG]", "incoming_message"), ("[you]", "outgoing_message")):
            for message in control_looking_messages:
                with self.subTest(marker=marker, message=message):
                    events = omaphone.parse_terminal_output(f"{marker} {message}")
                    self.assertEqual(events, [omaphone.OutputEvent(expected_kind, message)])

    def test_fragmented_chat_control_tokens_remain_only_chat_events(self) -> None:
        parser = omaphone.OutputStreamParser()
        _cleaned, first = parser.feed(b"[MSG] Enter .onion add")
        _cleaned, second = parser.feed(b"ress: CALL CON")
        _cleaned, third = parser.feed(("NECTED " + VALID_ONION + "\n").encode("ascii"))

        all_events = [*first, *second, *third]
        self.assertTrue(all(event.kind == "incoming_message" for event in all_events))
        self.assertNotIn("address_prompt", {event.kind for event in all_events})
        self.assertNotIn("connected", {event.kind for event in all_events})
        self.assertEqual(all_events[-1].value, f"Enter .onion address: CALL CONNECTED {VALID_ONION}")

    def test_fragmented_chat_room_tokens_never_become_room_state(self) -> None:
        parser = omaphone.OutputStreamParser()
        _cleaned, first = parser.feed(b"[MSG] CALL CONNECTED RELAY (group) Gro")
        _cleaned, second = parser.feed(b"up: 8 call")
        _cleaned, third = parser.feed(b"ers Callers: 8 Uptime: 1m\n")

        all_events = [*first, *second, *third]
        self.assertTrue(all(event.kind == "incoming_message" for event in all_events))
        self.assertNotIn("connected_group", {event.kind for event in all_events})
        self.assertNotIn("room_size", {event.kind for event in all_events})

    def test_parser_only_considers_bounded_tail(self) -> None:
        hidden_prefix = "[FAIL] must not leak" + "x" * omaphone.MAX_LINE_CHARS
        events = omaphone.parse_terminal_output(hidden_prefix + "safe tail")
        self.assertNotIn("error", {event.kind for event in events})

    def test_stream_parser_handles_fragmented_controls_and_deduplicates_partial_prompt(self) -> None:
        parser = omaphone.OutputStreamParser()
        cleaned_one, events_one = parser.feed(b"\x1b[31mEnter .on")
        cleaned_two, events_two = parser.feed(b"ion address:\x1b[0")
        cleaned_three, events_three = parser.feed(b"m")
        _cleaned_four, events_four = parser.feed(b"\nEnter .onion address:")

        self.assertEqual(cleaned_one, "Enter .on")
        self.assertEqual(cleaned_two, "ion address:")
        self.assertEqual(cleaned_three, "")
        self.assertHasEvent(events_two, "address_prompt")
        self.assertEqual(events_three, [])
        self.assertHasEvent(events_four, "address_prompt")
        self.assertLessEqual(len(parser.partial), omaphone.MAX_LINE_CHARS)

    def test_stream_parser_bounds_partial_line(self) -> None:
        parser = omaphone.OutputStreamParser()
        parser.feed(b"x" * (omaphone.MAX_LINE_CHARS * 3))
        self.assertEqual(len(parser.partial), omaphone.MAX_LINE_CHARS)


class SupervisorContractTests(TemporaryPathsTestCase):
    @staticmethod
    def invocation(kind: str, address: str = ""):
        return omaphone.Invocation(
            kind=kind,
            pid=12345,
            master_fd=99,
            parser=omaphone.OutputStreamParser(),
            started_at=1.0,
            address=address,
        )

    def test_pty_queue_preserves_order_across_partial_write_and_eagain(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.invocation = self.invocation("call")
        supervisor.status = omaphone.status_defaults()
        supervisor.selector = mock.Mock()
        observed: list[bytes] = []
        outcomes: list[object] = [2, BlockingIOError(errno.EAGAIN, "would block")]

        def partial_write(_descriptor: int, data: object) -> int:
            observed.append(bytes(data))
            outcome = outcomes.pop(0)
            if isinstance(outcome, BaseException):
                raise outcome
            return int(outcome)

        with mock.patch.object(omaphone.os, "write", side_effect=partial_write):
            self.assertTrue(supervisor._write_pty(b"abcdef"))

        self.assertEqual(observed, [b"abcdef", b"cdef"])
        self.assertEqual(supervisor.invocation.write_buffer, b"cdef")
        self.assertFalse(supervisor.invocation.write_failed)
        supervisor.selector.modify.assert_called_with(
            supervisor.invocation.master_fd,
            omaphone.selectors.EVENT_READ | omaphone.selectors.EVENT_WRITE,
            "pty",
        )

        observed.clear()

        def would_block(_descriptor: int, data: object) -> int:
            observed.append(bytes(data))
            raise BlockingIOError(errno.EAGAIN, "would block")

        with mock.patch.object(omaphone.os, "write", side_effect=would_block):
            self.assertTrue(supervisor._write_pty(b"XYZ"))
        self.assertEqual(observed, [b"cdefXYZ"])
        self.assertEqual(supervisor.invocation.write_buffer, b"cdefXYZ")

        observed.clear()

        def finish_write(_descriptor: int, data: object) -> int:
            observed.append(bytes(data))
            return len(data)  # type: ignore[arg-type]

        with mock.patch.object(omaphone.os, "write", side_effect=finish_write):
            self.assertTrue(supervisor._flush_pty_writes())
        self.assertEqual(observed, [b"cdefXYZ"])
        self.assertEqual(supervisor.invocation.write_buffer, b"")
        supervisor.selector.modify.assert_called_with(
            supervisor.invocation.master_fd,
            omaphone.selectors.EVENT_READ,
            "pty",
        )

    def test_prompt_state_advances_only_when_complete_payload_is_accepted(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.status = omaphone.status_defaults()
        supervisor.pending_text = "queued message"
        supervisor._persist = mock.Mock()
        supervisor._write_pty = mock.Mock(return_value=False)

        call = self.invocation("call", VALID_ONION)
        supervisor.invocation = call
        supervisor._handle_output_event(omaphone.OutputEvent("address_prompt"))
        self.assertFalse(call.address_sent)

        relay = self.invocation("relay")
        supervisor.invocation = relay
        supervisor._handle_output_event(omaphone.OutputEvent("relay_prompt"))
        self.assertFalse(relay.relay_confirmed)

        rotate = self.invocation("rotate")
        supervisor.invocation = rotate
        supervisor._handle_output_event(omaphone.OutputEvent("menu_prompt"))
        self.assertEqual(rotate.rotate_stage, 0)

        supervisor.invocation = call
        supervisor._handle_output_event(omaphone.OutputEvent("message_prompt"))
        self.assertEqual(supervisor.pending_text, "queued message")

        supervisor._write_pty.return_value = True
        supervisor._handle_output_event(omaphone.OutputEvent("address_prompt"))
        self.assertTrue(call.address_sent)
        supervisor.invocation = relay
        supervisor._handle_output_event(omaphone.OutputEvent("relay_prompt"))
        self.assertTrue(relay.relay_confirmed)
        supervisor.invocation = rotate
        supervisor._handle_output_event(omaphone.OutputEvent("menu_prompt"))
        self.assertEqual(rotate.rotate_stage, 1)
        supervisor.invocation = call
        supervisor._handle_output_event(omaphone.OutputEvent("message_prompt"))
        self.assertIsNone(supervisor.pending_text)

    def test_eagain_accepts_whole_prompt_payload_into_bounded_queue(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.invocation = self.invocation("call", VALID_ONION)
        supervisor.status = omaphone.status_defaults()
        supervisor.pending_text = None
        supervisor.selector = mock.Mock()
        supervisor._persist = mock.Mock()
        payload = VALID_ONION.encode("ascii") + b"\n"

        with mock.patch.object(
            omaphone.os,
            "write",
            side_effect=BlockingIOError(errno.EAGAIN, "would block"),
        ):
            supervisor._handle_output_event(omaphone.OutputEvent("address_prompt"))

        self.assertTrue(supervisor.invocation.address_sent)
        self.assertEqual(supervisor.invocation.write_buffer, payload)
        with mock.patch.object(omaphone.os, "write", return_value=len(payload)) as write:
            self.assertTrue(supervisor._flush_pty_writes())
        write.assert_called_once()
        self.assertEqual(supervisor.invocation.write_buffer, b"")

    def test_pty_queue_rejects_payload_that_exceeds_bound_without_partial_acceptance(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.invocation = self.invocation("call")
        supervisor.status = omaphone.status_defaults()
        supervisor.selector = mock.Mock()
        payload = b"x" * (omaphone.MAX_PTY_WRITE_QUEUE_BYTES + 1)
        with mock.patch.object(omaphone.os, "write") as write:
            self.assertFalse(supervisor._write_pty(payload))
        write.assert_not_called()
        self.assertEqual(supervisor.invocation.write_buffer, b"")
        self.assertIn("queue is full", supervisor.status["lastError"])

    def test_call_child_argv_contains_address_but_parent_still_waits_for_prompt(self) -> None:
        class SimulatedChildExit(BaseException):
            pass

        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = None
        supervisor.status = {
            **omaphone.status_defaults(),
            "configured": True,
            "dependenciesReady": True,
        }
        supervisor._refresh_static = mock.Mock()

        with (
            mock.patch.object(omaphone.pty, "fork", return_value=(0, 99)),
            mock.patch.object(omaphone.shutil, "which", return_value="/fixture/bash"),
            mock.patch.object(omaphone.os, "execvpe", side_effect=RuntimeError("simulated exec")) as execute,
            mock.patch.object(omaphone.os, "_exit", side_effect=SimulatedChildExit) as child_exit,
        ):
            with self.assertRaises(SimulatedChildExit):
                supervisor._start_invocation("call", VALID_ONION)

        execute.assert_called_once()
        executable, argv, environment = execute.call_args.args
        self.assertEqual(executable, "/fixture/bash")
        self.assertEqual(
            argv,
            ["/fixture/bash", str(self.paths.upstream_script), "call", VALID_ONION],
        )
        self.assertIsInstance(environment, dict)
        child_exit.assert_called_once_with(127)

        supervisor.invocation = self.invocation("call", VALID_ONION)
        supervisor.status = omaphone.status_defaults()
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()
        supervisor._write_pty = mock.Mock()
        supervisor._handle_output_event(omaphone.OutputEvent("connected"))
        supervisor._write_pty.assert_not_called()
        supervisor._handle_output_event(omaphone.OutputEvent("address_prompt"))
        supervisor._write_pty.assert_called_once_with(VALID_ONION.encode("ascii") + b"\n")
        self.assertTrue(supervisor.invocation.address_sent)
        supervisor._handle_output_event(omaphone.OutputEvent("address_prompt"))
        self.assertEqual(supervisor._write_pty.call_count, 1)

    def test_migration_prompt_is_answered_every_time_and_relay_only_once(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.invocation = self.invocation("listen")
        supervisor.status = omaphone.status_defaults()
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()
        supervisor._write_pty = mock.Mock()

        supervisor._handle_output_event(omaphone.OutputEvent("migration_prompt"))
        supervisor._handle_output_event(omaphone.OutputEvent("migration_prompt"))
        self.assertEqual(supervisor._write_pty.call_args_list, [mock.call(b"n\n"), mock.call(b"n\n")])

        supervisor._write_pty.reset_mock()
        supervisor.invocation = self.invocation("relay")
        supervisor._handle_output_event(omaphone.OutputEvent("relay_prompt"))
        supervisor._handle_output_event(omaphone.OutputEvent("relay_prompt"))
        supervisor._write_pty.assert_called_once_with(b"y\n")
        self.assertTrue(supervisor.invocation.relay_confirmed)

    def test_ptt_watchdog_clears_local_lease_but_preserves_remote_talking(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.invocation = self.invocation("call")
        supervisor.status = {
            **omaphone.status_defaults(),
            "localTalking": True,
            "remoteTalking": True,
        }
        supervisor.ptt_deadline = 99.0
        supervisor.ptt_next = 0.0
        supervisor.stop_deadline = 0.0
        supervisor._persist = mock.Mock()
        supervisor._write_pty = mock.Mock()

        with (
            mock.patch.object(omaphone.time, "monotonic", return_value=100.0),
            mock.patch.object(omaphone.os, "waitpid", return_value=(0, 0)),
        ):
            supervisor._tick()

        self.assertFalse(supervisor.status["localTalking"])
        self.assertTrue(supervisor.status["remoteTalking"])
        self.assertEqual(supervisor.ptt_deadline, 0.0)
        self.assertIn("expired", supervisor.status["lastError"])
        supervisor._write_pty.assert_not_called()
        supervisor._persist.assert_called_once_with()

    def test_invalid_live_pair_and_config_are_validated_before_listener_quiesce(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        listener = self.invocation("listen")
        supervisor.paths = self.paths
        supervisor.invocation = listener
        supervisor.status = {**omaphone.status_defaults(), "phase": "listening", "online": True}
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()
        supervisor._quiesce_listener = mock.Mock(return_value=True)

        requests = (
            {"command": "pair", "invite": "not-an-invite"},
            {"command": "config", "key": "quality", "value": "not-a-quality"},
        )
        with mock.patch.object(omaphone, "load_app_config") as load_config:
            for request in requests:
                with self.subTest(command=request["command"]):
                    response = supervisor.dispatch(request)
                    self.assertFalse(response["ok"])
                    self.assertIs(supervisor.invocation, listener)

        supervisor._quiesce_listener.assert_not_called()
        load_config.assert_not_called()

    def test_pair_immediately_updates_remote_address_in_returned_status(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = None
        supervisor.status = {
            **omaphone.status_defaults(),
            "phase": "offline",
            "remoteAddress": VALID_ONION,
        }
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()
        supervisor._quiesce_listener = mock.Mock(return_value=False)
        invitation = omaphone.create_invite(VALID_SECRET, SECOND_ONION, hmac_enabled=False)
        current_config = {
            "settings": dict(omaphone.DEFAULT_SETTINGS),
            "peerAddress": VALID_ONION,
        }

        with (
            mock.patch.object(omaphone, "load_app_config", return_value=current_config),
            mock.patch.object(omaphone, "save_app_config") as save_config,
            mock.patch.object(omaphone, "atomic_write") as write_secret,
        ):
            response = supervisor.dispatch({"command": "pair", "invite": invitation})

        self.assertTrue(response["ok"])
        self.assertEqual(response["status"]["remoteAddress"], SECOND_ONION)
        self.assertEqual(supervisor.status["remoteAddress"], SECOND_ONION)
        saved_config = save_config.call_args.args[1]
        self.assertEqual(saved_config["peerAddress"], SECOND_ONION)
        self.assertFalse(saved_config["settings"]["hmac"])
        write_secret.assert_called_once_with(self.paths.secret_file, VALID_SECRET.encode("ascii"))

    def test_partial_reconfiguration_write_never_restarts_listener_without_rollback(self) -> None:
        original_config = {
            "settings": dict(omaphone.DEFAULT_SETTINGS),
            "peerAddress": VALID_ONION,
        }
        omaphone.save_app_config(self.paths, original_config)
        original_app_bytes = self.paths.app_config.read_bytes()
        original_upstream_bytes = self.paths.upstream_config.read_bytes()

        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = None
        supervisor.status = {
            **omaphone.status_defaults(),
            "phase": "offline",
            "configured": True,
            "dependenciesReady": True,
        }
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()
        supervisor._quiesce_listener = mock.Mock(return_value=True)
        supervisor._start_invocation = mock.Mock()

        with mock.patch.object(
            omaphone,
            "sync_upstream_config",
            side_effect=OSError("simulated upstream config write failure"),
        ):
            response = supervisor.dispatch(
                {"command": "config", "key": "quality", "value": "high"}
            )

        self.assertFalse(response["ok"])
        restarted = supervisor._start_invocation.called
        rolled_back = (
            self.paths.app_config.read_bytes() == original_app_bytes
            and self.paths.upstream_config.read_bytes() == original_upstream_bytes
        )
        self.assertTrue(
            (not restarted and supervisor.status["phase"] in {"offline", "error"}) or rolled_back,
            "a listener may restart after a failed write only when both config files were rolled back",
        )

    def test_outgoing_message_rejects_controls_and_escapes_literal_backslashes(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = self.invocation("call")
        supervisor.status = {**omaphone.status_defaults(), "phase": "connected"}
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()
        supervisor._write_pty = mock.Mock()

        for text in ("nul\x00byte", "tab\tbyte", "escape\x1bbyte", "delete\x7fbyte", "c1\u0085byte"):
            with self.subTest(text=repr(text)):
                response = supervisor.dispatch({"command": "send", "text": text})
                self.assertFalse(response["ok"])
                self.assertIn("control", response["error"])
                self.assertIsNone(supervisor.pending_text)
        supervisor._write_pty.assert_not_called()

        message = "literal \\n and C:\\temp\\file\\"
        escaped = message.replace("\\", "\\\\")
        response = supervisor.dispatch({"command": "send", "text": message})
        self.assertTrue(response["ok"])
        self.assertEqual(supervisor.pending_text, escaped)
        supervisor._write_pty.assert_called_once_with(b"T")

        supervisor._write_pty.reset_mock()
        supervisor._handle_output_event(omaphone.OutputEvent("message_prompt"))
        supervisor._write_pty.assert_called_once_with(escaped.encode("utf-8") + b"\n")
        self.assertIsNone(supervisor.pending_text)

    def test_outgoing_message_limit_is_applied_after_backslash_escaping(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = self.invocation("call")
        supervisor.status = {**omaphone.status_defaults(), "phase": "connected"}
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()
        supervisor._write_pty = mock.Mock()
        message = "\\" * (omaphone.MAX_TEXT_BYTES // 2 + 1)

        response = supervisor.dispatch({"command": "send", "text": message})

        self.assertFalse(response["ok"])
        self.assertIn("too long", response["error"])
        self.assertIsNone(supervisor.pending_text)
        supervisor._write_pty.assert_not_called()

    def test_refresh_resumes_a_desired_ready_listener(self) -> None:
        omaphone.save_desired_online(self.paths, True)
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = None
        supervisor.status = {
            **omaphone.status_defaults(),
            "configured": True,
            "dependenciesReady": True,
            "online": True,
        }
        supervisor._refresh_static = mock.Mock()
        supervisor._start_invocation = mock.Mock()
        supervisor._response = mock.Mock(return_value={"ok": True, "status": supervisor.status})

        response = supervisor.dispatch({"command": "refresh"})

        self.assertTrue(response["ok"])
        supervisor._refresh_static.assert_called_once_with()
        supervisor._start_invocation.assert_called_once_with("listen")

    def test_connected_phase_is_persisted_as_not_busy(self) -> None:
        omaphone.ensure_layout(self.paths)
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = self.invocation("call", VALID_ONION)
        supervisor.status = {**omaphone.status_defaults(), "phase": "calling"}
        supervisor.pending_text = None
        supervisor._refresh_static = mock.Mock()

        supervisor._handle_output_event(omaphone.OutputEvent("connected", VALID_ONION))

        self.assertEqual(supervisor.status["phase"], "connected")
        self.assertEqual(supervisor.status["remoteAddress"], VALID_ONION)
        self.assertFalse(supervisor.status["busy"])
        persisted = json.loads(self.paths.status_file.read_text("utf-8"))
        self.assertFalse(persisted["busy"])

    def test_group_call_and_room_size_reset_across_direct_listening_end_and_offline(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = self.invocation("call", VALID_ONION)
        supervisor.status = omaphone.status_defaults()
        supervisor.pending_text = None
        supervisor.listener_failures = 0
        supervisor.listener_retry_at = 0.0
        supervisor.ptt_next = 0.0
        supervisor.ptt_deadline = 0.0
        supervisor._persist = mock.Mock()
        supervisor._write_pty = mock.Mock(return_value=True)

        supervisor._handle_output_event(omaphone.OutputEvent("connected_group"))
        supervisor._handle_output_event(omaphone.OutputEvent("room_size", "4"))
        self.assertTrue(supervisor.status["groupCall"])
        self.assertEqual(supervisor.status["roomSize"], 4)

        supervisor._handle_output_event(omaphone.OutputEvent("connected", VALID_ONION))
        self.assertFalse(supervisor.status["groupCall"])
        self.assertEqual(supervisor.status["roomSize"], 0)

        supervisor._handle_output_event(omaphone.OutputEvent("connected_group"))
        supervisor._handle_output_event(omaphone.OutputEvent("room_size", "2"))
        supervisor._handle_output_event(omaphone.OutputEvent("listening"))
        self.assertFalse(supervisor.status["groupCall"])
        self.assertEqual(supervisor.status["roomSize"], 0)

        supervisor._handle_output_event(omaphone.OutputEvent("connected_group"))
        supervisor._handle_output_event(omaphone.OutputEvent("room_size", "2"))
        with mock.patch.object(omaphone, "desired_online", return_value=False):
            supervisor._handle_output_event(omaphone.OutputEvent("call_ended"))
        self.assertEqual(supervisor.status["phase"], "offline")
        self.assertFalse(supervisor.status["groupCall"])
        self.assertEqual(supervisor.status["roomSize"], 0)

        supervisor.status["groupCall"] = True
        supervisor.status["roomSize"] = 9
        supervisor._request_stop("offline")
        self.assertFalse(supervisor.status["groupCall"])
        self.assertEqual(supervisor.status["roomSize"], 0)

    def test_relay_host_tracks_bounded_room_size_without_joining_the_group_call(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.invocation = self.invocation("relay")
        supervisor.status = omaphone.status_defaults()
        supervisor.pending_text = None
        supervisor._persist = mock.Mock()

        supervisor._handle_output_event(omaphone.OutputEvent("relay"))
        for value in ("0", "7", str(omaphone.MAX_ROOM_SIZE)):
            supervisor._handle_output_event(omaphone.OutputEvent("room_size", value))
            self.assertEqual(supervisor.status["roomSize"], int(value))
            self.assertFalse(supervisor.status["groupCall"])

        for invalid in ("-1", str(omaphone.MAX_ROOM_SIZE + 1), "1.5", "true"):
            supervisor._handle_output_event(omaphone.OutputEvent("room_size", invalid))
            self.assertEqual(supervisor.status["roomSize"], omaphone.MAX_ROOM_SIZE)

    def test_persist_normalizes_room_state_to_its_active_context(self) -> None:
        omaphone.ensure_layout(self.paths)
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = self.invocation("call")
        supervisor.status = {
            **omaphone.status_defaults(),
            "phase": "connected",
            "groupCall": False,
            "roomSize": 7,
        }
        supervisor._refresh_static = mock.Mock()

        supervisor._persist()
        self.assertEqual(supervisor.status["roomSize"], 0)

        supervisor.status["groupCall"] = True
        supervisor.status["roomSize"] = omaphone.MAX_ROOM_SIZE
        supervisor._persist()
        self.assertEqual(supervisor.status["roomSize"], omaphone.MAX_ROOM_SIZE)

        supervisor.status["roomSize"] = True
        supervisor._persist()
        self.assertEqual(supervisor.status["roomSize"], 0)

    def test_clear_chat_removes_only_bounded_local_message_state(self) -> None:
        omaphone.ensure_layout(self.paths)
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.invocation = None
        supervisor.status = {
            **omaphone.status_defaults(),
            "phase": "offline",
            "messages": [
                {"direction": "incoming", "text": "hello", "timestamp": "2026-01-01T00:00:00Z"}
            ],
        }

        response = supervisor.dispatch({"command": "clear-chat"})

        self.assertTrue(response["ok"])
        self.assertEqual(response["status"]["messages"], [])
        persisted = json.loads(self.paths.status_file.read_text("utf-8"))
        self.assertEqual(persisted["messages"], [])

    def test_unexpected_listener_exit_retries_with_exponential_backoff(self) -> None:
        omaphone.save_desired_online(self.paths, True)
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.selector = mock.Mock()
        supervisor.invocation = self.invocation("listen")
        supervisor.status = {
            **omaphone.status_defaults(),
            "configured": True,
            "dependenciesReady": True,
            "online": True,
            "phase": "starting",
        }
        supervisor.pending_invocation = None
        supervisor.pending_text = None
        supervisor.stop_reason = ""
        supervisor.stop_deadline = 0.0
        supervisor.ptt_next = 0.0
        supervisor.ptt_deadline = 0.0
        supervisor.listener_failures = 0
        supervisor.listener_retry_at = 0.0
        supervisor.last_client_at = 100.0
        supervisor.running = True
        supervisor._persist = mock.Mock()
        supervisor._start_invocation = mock.Mock()

        with (
            mock.patch.object(omaphone.time, "monotonic", return_value=100.0),
            mock.patch.object(omaphone.os, "close"),
        ):
            supervisor._finish_invocation(0)

        self.assertIsNone(supervisor.invocation)
        supervisor._start_invocation.assert_not_called()
        self.assertEqual(supervisor.listener_failures, 1)
        self.assertEqual(supervisor.listener_retry_at, 102.0)
        self.assertEqual(supervisor.status["phase"], "error")
        self.assertIn("retrying listener in 2s", supervisor.status["lastError"])

        supervisor._start_invocation.side_effect = omaphone.OmaphoneError("still unavailable")
        with mock.patch.object(omaphone.time, "monotonic", return_value=101.0):
            supervisor._tick()
        supervisor._start_invocation.assert_not_called()

        with mock.patch.object(omaphone.time, "monotonic", return_value=102.0):
            supervisor._tick()
        supervisor._start_invocation.assert_called_once_with("listen")
        self.assertEqual(supervisor.listener_failures, 2)
        self.assertEqual(supervisor.listener_retry_at, 106.0)
        self.assertIn("retrying listener in 4s", supervisor.status["lastError"])

        with mock.patch.object(omaphone.time, "monotonic", return_value=105.0):
            supervisor._tick()
        self.assertEqual(supervisor._start_invocation.call_count, 1)

        supervisor._start_invocation.side_effect = None
        with mock.patch.object(omaphone.time, "monotonic", return_value=106.0):
            supervisor._tick()
        self.assertEqual(supervisor._start_invocation.call_count, 2)
        self.assertEqual(supervisor.listener_retry_at, 0.0)

        supervisor.invocation = self.invocation("listen")
        supervisor._handle_output_event(omaphone.OutputEvent("listening"))
        self.assertEqual(supervisor.listener_failures, 0)
        self.assertEqual(supervisor.listener_retry_at, 0.0)

    def test_shutdown_invocation_escalates_and_reaps_before_pty_cleanup(self) -> None:
        omaphone.save_desired_online(self.paths, False)
        supervisor = object.__new__(omaphone.Supervisor)
        invocation = self.invocation("call", VALID_ONION)
        invocation.write_buffer.extend(b"pending")
        supervisor.paths = self.paths
        supervisor.selector = mock.Mock()
        supervisor.invocation = invocation
        supervisor.status = {
            **omaphone.status_defaults(),
            "configured": True,
            "phase": "connected",
            "localTalking": True,
            "remoteTalking": True,
        }
        supervisor.pending_invocation = ("listen", "")
        supervisor.pending_text = "sensitive pending text"
        supervisor.stop_reason = ""
        supervisor.stop_deadline = 123.0
        supervisor.ptt_next = 50.0
        supervisor.ptt_deadline = 60.0
        supervisor._write_pty = mock.Mock(return_value=True)
        supervisor._flush_pty_writes = mock.Mock(return_value=True)
        supervisor._persist = mock.Mock()
        events: list[tuple[str, object]] = []

        def wait_for_child(_pid: int, timeout: float) -> None:
            events.append(("wait", timeout))
            return None

        def kill_child(_pid: int, child_signal: int) -> None:
            events.append(("kill", child_signal))

        def reap_child(_pid: int, flags: int) -> tuple[int, int]:
            events.append(("reap", flags))
            return invocation.pid, 0

        def unregister_pty(descriptor: int) -> None:
            events.append(("unregister", descriptor))

        def close_pty(descriptor: int) -> None:
            events.append(("close", descriptor))

        supervisor._wait_for_child = mock.Mock(side_effect=wait_for_child)
        supervisor.selector.unregister.side_effect = unregister_pty
        with (
            mock.patch.object(omaphone.os, "kill", side_effect=kill_child),
            mock.patch.object(omaphone.os, "waitpid", side_effect=reap_child),
            mock.patch.object(omaphone.os, "close", side_effect=close_pty),
        ):
            supervisor._shutdown_invocation()

        supervisor._write_pty.assert_called_once_with(b"Q\n")
        supervisor._flush_pty_writes.assert_called_once_with()
        self.assertEqual(
            events,
            [
                ("wait", omaphone.CHILD_GRACEFUL_EXIT_SECONDS),
                ("kill", omaphone.signal.SIGTERM),
                ("wait", omaphone.CHILD_TERM_EXIT_SECONDS),
                ("kill", omaphone.signal.SIGKILL),
                ("reap", 0),
                ("unregister", invocation.master_fd),
                ("close", invocation.master_fd),
            ],
        )
        self.assertIsNone(supervisor.invocation)
        self.assertIsNone(supervisor.pending_invocation)
        self.assertIsNone(supervisor.pending_text)
        self.assertEqual(invocation.write_buffer, b"")
        self.assertEqual(supervisor.stop_deadline, 0.0)
        self.assertFalse(supervisor.status["localTalking"])
        self.assertFalse(supervisor.status["remoteTalking"])
        self.assertEqual(supervisor.status["phase"], "offline")
        supervisor._persist.assert_called_once_with()

    def test_run_shuts_down_child_before_releasing_lifecycle_lock(self) -> None:
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.paths = self.paths
        supervisor.selector = mock.Mock()
        supervisor.status = {
            **omaphone.status_defaults(),
            "configured": False,
            "dependenciesReady": False,
        }
        supervisor.invocation = self.invocation("listen")
        supervisor.running = False
        supervisor.server = None
        supervisor._clear_ptt = mock.Mock()
        events: list[str] = []
        supervisor._shutdown_invocation = mock.Mock(
            side_effect=lambda: events.append("shutdown-child")
        )
        server = mock.Mock()
        lock_fd = 77
        lock_info = mock.Mock(st_mode=stat.S_IFREG | 0o600, st_uid=os.getuid())

        def close_lock(descriptor: int) -> None:
            self.assertEqual(descriptor, lock_fd)
            events.append("close-lock")

        with (
            mock.patch.object(omaphone.os, "open", return_value=lock_fd),
            mock.patch.object(omaphone.os, "fstat", return_value=lock_info),
            mock.patch.object(omaphone.os, "fchmod"),
            mock.patch.object(omaphone.fcntl, "flock"),
            mock.patch.object(omaphone.socket, "socket", return_value=server),
            mock.patch.object(omaphone.os, "chmod"),
            mock.patch.object(omaphone.signal, "signal"),
            mock.patch.object(omaphone, "desired_online", return_value=False),
            mock.patch.object(omaphone.os, "close", side_effect=close_lock),
        ):
            self.assertEqual(supervisor.run(), 0)

        self.assertEqual(events, ["shutdown-child", "close-lock"])
        supervisor._shutdown_invocation.assert_called_once_with()
        server.close.assert_called_once_with()


class DependencyTests(unittest.TestCase):
    BASE_COMMANDS = {"tor", "opusenc", "opusdec", "sox", "socat", "openssl"}

    @staticmethod
    def which_with(*available: str):
        names = set(available)
        return lambda name: f"/fixture/bin/{name}" if name in names else None

    def test_dependency_status_accepts_either_complete_audio_stack(self) -> None:
        for audio in (("parec", "pacat"), ("arecord", "aplay")):
            with self.subTest(audio=audio):
                which = self.which_with(*self.BASE_COMMANDS, *audio)
                self.assertEqual(omaphone.dependency_status(omaphone.DEFAULT_SETTINGS, which), [])

    def test_dependency_status_reports_missing_tools_and_conditional_snowflake(self) -> None:
        which = self.which_with("tor", "parec")
        missing = omaphone.dependency_status({**omaphone.DEFAULT_SETTINGS, "snowflake": True}, which)
        self.assertEqual(
            missing,
            [
                "opusenc",
                "opusdec",
                "sox",
                "socat",
                "openssl",
                "parec+pacat or arecord+aplay",
                "snowflake-client",
            ],
        )

    def test_arch_install_command_is_fixed_and_non_shell(self) -> None:
        which = self.which_with("pacman", "pkexec")
        expected = [
            "pkexec",
            "pacman",
            "-S",
            "--needed",
            "--noconfirm",
            "tor",
            "opus-tools",
            "sox",
            "socat",
            "openssl",
            "alsa-utils",
            "libpulse",
        ]
        self.assertEqual(omaphone.arch_install_command(which, 'ID="arch"\n'), expected)
        self.assertEqual(omaphone.arch_install_command(which, 'ID=omarchy\nID_LIKE="arch linux"\n'), expected)

    def test_arch_install_command_rejects_unsupported_or_missing_privilege_tool(self) -> None:
        with self.assertRaisesRegex(omaphone.OmaphoneError, "only on Arch"):
            omaphone.arch_install_command(self.which_with("pacman", "pkexec"), "ID=debian\n")
        with self.assertRaisesRegex(omaphone.OmaphoneError, "only on Arch"):
            omaphone.arch_install_command(self.which_with("pkexec"), "ID=arch\n")
        with self.assertRaisesRegex(omaphone.OmaphoneError, "pkexec is required"):
            omaphone.arch_install_command(self.which_with("pacman"), "ID=arch\n")

    def test_install_dependencies_invokes_argument_vector_without_shell(self) -> None:
        completed = mock.Mock(returncode=0)
        with (
            mock.patch.object(omaphone, "dependency_status", side_effect=(["tor"], [])),
            mock.patch.object(omaphone, "arch_install_command", return_value=["pkexec", "pacman"]),
            mock.patch.object(omaphone.subprocess, "run", return_value=completed) as run,
        ):
            omaphone.install_dependencies()
        run.assert_called_once_with(
            ["pkexec", "pacman"], check=False, stdout=omaphone.subprocess.DEVNULL
        )

    def test_install_dependencies_reports_nonzero_exit(self) -> None:
        completed = mock.Mock(returncode=19)
        with (
            mock.patch.object(omaphone, "dependency_status", return_value=["tor"]),
            mock.patch.object(omaphone, "arch_install_command", return_value=["pkexec", "pacman"]),
            mock.patch.object(omaphone.subprocess, "run", return_value=completed),
        ):
            with self.assertRaisesRegex(omaphone.OmaphoneError, "exit code 19"):
                omaphone.install_dependencies()

    def test_install_dependencies_is_noop_when_everything_is_present(self) -> None:
        with (
            mock.patch.object(omaphone, "dependency_status", return_value=[]),
            mock.patch.object(omaphone, "arch_install_command") as command,
            mock.patch.object(omaphone.subprocess, "run") as run,
        ):
            omaphone.install_dependencies()
        command.assert_not_called()
        run.assert_not_called()

    def test_install_dependencies_uses_current_snowflake_setting_and_gives_aur_guidance(self) -> None:
        settings = {**omaphone.DEFAULT_SETTINGS, "snowflake": True}
        completed = mock.Mock(returncode=0)
        command_value = ["pkexec", "pacman", "tor"]
        with (
            mock.patch.object(
                omaphone,
                "dependency_status",
                side_effect=(["tor", "snowflake-client"], ["snowflake-client"]),
            ) as status,
            mock.patch.object(omaphone, "arch_install_command", return_value=command_value) as command,
            mock.patch.object(omaphone.subprocess, "run", return_value=completed) as run,
        ):
            with self.assertRaisesRegex(omaphone.OmaphoneError, "snowflake-pt-client") as raised:
                omaphone.install_dependencies(settings)

        self.assertEqual(status.call_args_list, [mock.call(settings), mock.call(settings)])
        command.assert_called_once_with()
        run.assert_called_once_with(
            command_value, check=False, stdout=omaphone.subprocess.DEVNULL
        )
        self.assertIn("omarchy pkg aur add snowflake-pt-client", str(raised.exception))
        self.assertNotIn("snowflake-pt-client", command_value)

    def test_snowflake_only_missing_skips_pacman_and_gives_aur_guidance(self) -> None:
        settings = {**omaphone.DEFAULT_SETTINGS, "snowflake": True}
        with (
            mock.patch.object(
                omaphone,
                "dependency_status",
                side_effect=(["snowflake-client"], ["snowflake-client"]),
            ) as status,
            mock.patch.object(omaphone, "arch_install_command") as command,
            mock.patch.object(omaphone.subprocess, "run") as run,
        ):
            with self.assertRaisesRegex(omaphone.OmaphoneError, "snowflake-pt-client") as raised:
                omaphone.install_dependencies(settings)

        self.assertEqual(status.call_args_list, [mock.call(settings), mock.call(settings)])
        self.assertIn("omarchy pkg aur add snowflake-pt-client", str(raised.exception))
        command.assert_not_called()
        run.assert_not_called()

    def test_install_dependencies_fails_if_tools_remain_missing_after_pacman(self) -> None:
        settings = dict(omaphone.DEFAULT_SETTINGS)
        completed = mock.Mock(returncode=0)
        with (
            mock.patch.object(
                omaphone,
                "dependency_status",
                side_effect=(["tor"], ["tor"]),
            ) as status,
            mock.patch.object(omaphone, "arch_install_command", return_value=["pkexec", "pacman"]),
            mock.patch.object(omaphone.subprocess, "run", return_value=completed),
        ):
            with self.assertRaises(omaphone.OmaphoneError):
                omaphone.install_dependencies(settings)

        self.assertEqual(status.call_args_list, [mock.call(settings), mock.call(settings)])


class BoundedStdinTests(unittest.TestCase):
    @staticmethod
    def read_pipe(payload: bytes, limit: int = 32) -> str:
        read_descriptor, write_descriptor = os.pipe()
        try:
            os.write(write_descriptor, payload)
        finally:
            os.close(write_descriptor)
        # Match sys.stdin.buffer: it is buffered, rather than a raw FileIO object.
        with os.fdopen(read_descriptor, "rb") as stream:
            return omaphone.read_one_stdin_line(stream, limit, "fixture")

    def test_accepts_exactly_one_newline_terminated_utf8_line(self) -> None:
        self.assertEqual(self.read_pipe(b"hello\n"), "hello")
        self.assertEqual(self.read_pipe("é\n".encode("utf-8")), "é")
        self.assertEqual(self.read_pipe(b"x" * 32 + b"\n"), "x" * 32)
        self.assertEqual(omaphone.read_one_stdin_line(io.StringIO("text\n"), 10, "fixture"), "text")

    def test_rejects_missing_terminator_over_limit_crlf_and_bad_utf8(self) -> None:
        cases = (
            (b"unterminated", 32, "newline-terminated"),
            (b"x" * 33 + b"\n", 32, "too long"),
            (b"line\r\n", 32, "embedded newlines"),
            (b"\xff\n", 32, "valid UTF-8"),
        )
        for payload, limit, message in cases:
            with self.subTest(payload=payload[:20], message=message):
                with self.assertRaisesRegex(omaphone.OmaphoneError, message):
                    self.read_pipe(payload, limit)

    def test_byte_limit_applies_to_utf8_not_character_count(self) -> None:
        self.assertEqual(self.read_pipe("éé\n".encode("utf-8"), 4), "éé")
        with self.assertRaisesRegex(omaphone.OmaphoneError, "too long"):
            self.read_pipe("ééé\n".encode("utf-8"), 5)

    def test_rejects_a_second_line_even_when_buffered_reader_prefetched_it(self) -> None:
        with self.assertRaisesRegex(omaphone.OmaphoneError, "exactly one line"):
            self.read_pipe(b"first\nsecond\n")


class SocketProtocolTests(TemporaryPathsTestCase):
    def test_socket_request_sends_one_compact_json_line_and_parses_dict(self) -> None:
        fake = FakeUnixSocket([b'{"ok":', b'true,"value":7}\n'])
        with mock.patch.object(omaphone.socket, "socket", return_value=fake) as constructor:
            response = omaphone.socket_request(self.paths, {"command": "status"}, timeout=1.25)

        self.assertEqual(response, {"ok": True, "value": 7})
        constructor.assert_called_once_with(omaphone.socket.AF_UNIX, omaphone.socket.SOCK_STREAM)
        self.assertEqual(fake.timeout, 1.25)
        self.assertEqual(fake.connected_to, str(self.paths.socket_file))
        self.assertEqual(fake.sent, [b'{"command":"status"}\n'])
        self.assertTrue(fake.closed)

    def test_socket_request_rejects_oversized_request_before_opening_socket(self) -> None:
        with mock.patch.object(omaphone.socket, "socket") as constructor:
            with self.assertRaisesRegex(omaphone.OmaphoneError, "request is too large"):
                omaphone.socket_request(self.paths, {"text": "x" * omaphone.MAX_REQUEST_BYTES})
        constructor.assert_not_called()

    def test_socket_request_closes_and_wraps_connection_failures(self) -> None:
        fake = FakeUnixSocket(connect_error=FileNotFoundError("fixture"))
        with mock.patch.object(omaphone.socket, "socket", return_value=fake):
            with self.assertRaisesRegex(omaphone.OmaphoneError, "daemon is unavailable"):
                omaphone.socket_request(self.paths, {"command": "ping"})
        self.assertTrue(fake.closed)

    def test_socket_request_rejects_unterminated_invalid_nondict_and_oversized_responses(self) -> None:
        responses = (
            [b'{"ok":true}'],
            [b"\xff\n"],
            [b"[]\n"],
            [b'{"payload":"' + b"x" * (512 * 1024) + b'"}\n'],
        )
        for incoming in responses:
            with self.subTest(size=sum(map(len, incoming))):
                fake = FakeUnixSocket(incoming)
                with mock.patch.object(omaphone.socket, "socket", return_value=fake):
                    with self.assertRaisesRegex(omaphone.OmaphoneError, "invalid daemon response"):
                        omaphone.socket_request(self.paths, {"command": "ping"})
                self.assertTrue(fake.closed)

    @staticmethod
    def bare_supervisor(response: dict[str, object] | None = None):
        supervisor = object.__new__(omaphone.Supervisor)
        supervisor.dispatch = mock.Mock(return_value=response or {"ok": True})
        supervisor._error = mock.Mock(side_effect=lambda message: {"ok": False, "error": message})
        return supervisor

    def test_server_accepts_one_fragmented_json_line_from_same_uid(self) -> None:
        supervisor = self.bare_supervisor({"ok": True, "answer": 42})
        client = FakeUnixSocket([b'{"command":', b'"status"}\n'])
        omaphone.Supervisor._serve_client(supervisor, client)

        supervisor.dispatch.assert_called_once_with({"command": "status"})
        self.assertEqual(client.timeout, 0.25)
        self.assertEqual(client.sent, [b'{"ok":true,"answer":42}\n'])
        self.assertTrue(client.closed)

    def test_server_rejects_bad_framing_json_and_size_without_dispatch(self) -> None:
        cases = (
            ([b'{"command":"status"}'], "invalid or oversized request"),
            ([b"not-json\n"], "invalid request JSON"),
            ([b"[]\n"], "invalid request JSON"),
            ([b'{"command":"one"}\n{"command":"two"}\n'], "only one command"),
            ([b"x" * (omaphone.MAX_REQUEST_BYTES + 1)], "invalid or oversized request"),
        )
        for incoming, error in cases:
            with self.subTest(error=error):
                supervisor = self.bare_supervisor()
                client = FakeUnixSocket(incoming)
                omaphone.Supervisor._serve_client(supervisor, client)
                supervisor.dispatch.assert_not_called()
                self.assertIn(error.encode("utf-8"), client.sent[0])
                self.assertTrue(client.closed)

    @unittest.skipUnless(hasattr(omaphone.socket, "SO_PEERCRED"), "SO_PEERCRED is Linux-specific")
    def test_server_silently_rejects_a_different_peer_uid(self) -> None:
        supervisor = self.bare_supervisor()
        client = FakeUnixSocket([b'{"command":"status"}\n'], peer_uid=os.getuid() + 1)
        omaphone.Supervisor._serve_client(supervisor, client)
        supervisor.dispatch.assert_not_called()
        self.assertEqual(client.sent, [])
        self.assertTrue(client.closed)


class DaemonLifecycleTests(TemporaryPathsTestCase):
    @staticmethod
    def ping_response(version: str) -> dict[str, object]:
        return {"ok": True, "status": {"backendVersion": version}}

    def test_ensure_daemon_reuses_a_matching_backend_without_spawning(self) -> None:
        matching = self.ping_response(omaphone.BACKEND_VERSION)
        with (
            mock.patch.object(omaphone, "socket_request", return_value=matching) as request,
            mock.patch.object(omaphone, "wait_for_daemon_exit") as wait_for_exit,
            mock.patch.object(omaphone.subprocess, "Popen") as spawn,
        ):
            omaphone.ensure_daemon(self.paths)

        request.assert_called_once_with(self.paths, {"command": "ping"}, timeout=0.2)
        wait_for_exit.assert_not_called()
        spawn.assert_not_called()

    def test_ensure_daemon_replaces_mismatched_backend_only_after_shutdown_and_lock_exit(self) -> None:
        old = self.ping_response("0.0.0-old")
        new = self.ping_response(omaphone.BACKEND_VERSION)
        with (
            mock.patch.object(
                omaphone,
                "socket_request",
                side_effect=(old, {"ok": True}, new),
            ) as request,
            mock.patch.object(omaphone, "wait_for_daemon_exit") as wait_for_exit,
            mock.patch.object(omaphone.subprocess, "Popen", return_value=mock.Mock()) as spawn,
        ):
            omaphone.ensure_daemon(self.paths)

        self.assertEqual(
            request.call_args_list,
            [
                mock.call(self.paths, {"command": "ping"}, timeout=0.2),
                mock.call(self.paths, {"command": "shutdown"}, timeout=1.0),
                mock.call(self.paths, {"command": "ping"}, timeout=0.2),
            ],
        )
        wait_for_exit.assert_called_once_with(self.paths)
        spawn.assert_called_once()

    def test_ensure_daemon_refuses_to_replace_backend_that_rejects_shutdown(self) -> None:
        old = self.ping_response("0.0.0-old")
        with (
            mock.patch.object(
                omaphone,
                "socket_request",
                side_effect=(old, {"ok": False, "error": "refused"}),
            ) as request,
            mock.patch.object(omaphone, "wait_for_daemon_exit") as wait_for_exit,
            mock.patch.object(omaphone.subprocess, "Popen") as spawn,
        ):
            with self.assertRaisesRegex(omaphone.OmaphoneError, "incompatible"):
                omaphone.ensure_daemon(self.paths)

        self.assertEqual(request.call_count, 2)
        wait_for_exit.assert_not_called()
        spawn.assert_not_called()


class CliRequestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.parser = omaphone.build_argument_parser()

    def test_pure_cli_requests_are_validated_and_normalized(self) -> None:
        cases = (
            (["status"], {"command": "status"}),
            (["call", "HTTPS://" + VALID_ONION.upper() + "/"], {"command": "call", "address": VALID_ONION}),
            (["ptt", "start"], {"command": "ptt", "action": "start"}),
            (["config", "hmac", "false"], {"command": "config", "key": "hmac", "value": False}),
            (["rotate", "--confirm"], {"command": "rotate", "confirm": True}),
            (["install-deps"], {"command": "install-deps"}),
            (["clear-chat"], {"command": "clear-chat"}),
        )
        for argv, expected in cases:
            with self.subTest(argv=argv):
                self.assertEqual(omaphone.cli_request(self.parser.parse_args(argv)), expected)

    def test_rotate_requires_explicit_confirmation(self) -> None:
        with self.assertRaisesRegex(omaphone.OmaphoneError, "requires --confirm"):
            omaphone.cli_request(self.parser.parse_args(["rotate"]))

    def test_send_and_pair_read_only_the_bounded_stdin_line(self) -> None:
        cases = (
            (["send"], b"hello\n", {"command": "send", "text": "hello"}),
            (["pair"], b"invite-code\n", {"command": "pair", "invite": "invite-code"}),
        )
        for argv, stdin_value, expected in cases:
            fake_stdin = mock.Mock(buffer=io.BytesIO(stdin_value))
            with self.subTest(argv=argv), mock.patch.object(omaphone.sys, "stdin", fake_stdin):
                self.assertEqual(omaphone.cli_request(self.parser.parse_args(argv)), expected)

    def test_send_rejects_an_empty_line(self) -> None:
        fake_stdin = mock.Mock(buffer=io.BytesIO(b"\n"))
        with mock.patch.object(omaphone.sys, "stdin", fake_stdin):
            with self.assertRaisesRegex(omaphone.OmaphoneError, "must not be empty"):
                omaphone.cli_request(self.parser.parse_args(["send"]))


class MainCommandTests(TemporaryPathsTestCase):
    def test_install_deps_uses_saved_settings_and_emits_only_one_json_status_line(self) -> None:
        settings = {**omaphone.DEFAULT_SETTINGS, "snowflake": True}
        response = {"ok": True, "status": {"phase": "offline", "dependenciesReady": True}}
        stdout = io.StringIO()
        with (
            mock.patch.object(omaphone.os, "umask"),
            mock.patch.object(omaphone.Paths, "from_environment", return_value=self.paths),
            mock.patch.object(
                omaphone,
                "load_app_config",
                return_value={"settings": settings, "peerAddress": ""},
            ),
            mock.patch.object(omaphone, "install_dependencies") as install,
            mock.patch.object(omaphone, "ensure_daemon") as ensure_daemon,
            mock.patch.object(omaphone, "socket_request", return_value=response) as request,
            mock.patch.object(omaphone.sys, "stdout", stdout),
        ):
            exit_code = omaphone.main(["install-deps"])

        self.assertEqual(exit_code, 0)
        install.assert_called_once_with(settings)
        ensure_daemon.assert_called_once_with(self.paths)
        request.assert_called_once_with(self.paths, {"command": "refresh"})
        self.assertEqual(
            stdout.getvalue(),
            '{"phase":"offline","dependenciesReady":true}\n',
        )


if __name__ == "__main__":  # pragma: no cover
    unittest.main(verbosity=2)
