#!/usr/bin/env python3
"""Omaphone: a private, stdlib-only supervisor for pinned TerminalPhone."""

from __future__ import annotations

import argparse
import base64
import codecs
import dataclasses
import datetime as dt
import errno
import fcntl
import hashlib
import hmac
import json
import os
import pty
import random
import re
import select
import selectors
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable, Mapping


SCHEMA_VERSION = 1
BACKEND_VERSION = "1.2.1"
UPSTREAM_COMMIT = "67c8167dae167276b1ba69ac66b79b3abedceef8"
UPSTREAM_URL = (
    "https://raw.githubusercontent.com/edengilbertus/terminalphone/"
    f"{UPSTREAM_COMMIT}/terminalphone.sh"
)
UPSTREAM_SHA256 = "a9d95621fb4351250a73c2577776c8929f0c067b7d2d47bd200ef5f860adcacc"
UPSTREAM_LICENSE_URL = (
    "https://raw.githubusercontent.com/edengilbertus/terminalphone/"
    f"{UPSTREAM_COMMIT}/LICENSE"
)
UPSTREAM_LICENSE_SHA256 = "9b7c73dbc3cfff3291279c41b8f8ca61535a177d90d46dd8436b8260a84c38a7"
BUNDLED_DIR = Path(__file__).resolve().parent.parent / "vendor"
BUNDLED_UPSTREAM_SCRIPT = BUNDLED_DIR / "terminalphone.sh"
BUNDLED_UPSTREAM_LICENSE = BUNDLED_DIR / "TerminalPhone-LICENSE"

MAX_DOWNLOAD_BYTES = 1_000_000
MAX_REQUEST_BYTES = 32_768
MAX_INVITE_BYTES = 4_096
MAX_TEXT_BYTES = 4_096
MAX_MESSAGE_CHARS = 2_048
MAX_MESSAGES = 50
MAX_LINE_CHARS = 8_192
MAX_ROOM_SIZE = 10_000
MAX_LOG_BYTES = 256 * 1024
MAX_PTY_WRITE_QUEUE_BYTES = 64 * 1024
PTT_INTERVAL_MIN = 0.100
PTT_INTERVAL_MAX = 0.150
PTT_WATCHDOG_SECONDS = 8.0
LISTENER_RETRY_BASE_SECONDS = 2.0
LISTENER_RETRY_MAX_SECONDS = 30.0
OFFLINE_IDLE_SECONDS = 60.0
CHILD_GRACEFUL_EXIT_SECONDS = 1.0
CHILD_TERM_EXIT_SECONDS = 3.0
CALL_DIAL_TIMEOUT_SECONDS = 60.0
CALL_SETUP_TIMEOUT_SECONDS = 360.0
# Kept as a descriptive alias for callers/tests referring to the overall guard.
CALL_OVERALL_TIMEOUT_SECONDS = CALL_SETUP_TIMEOUT_SECONDS
MAX_CALL_MESSAGE_CHARS = 240
MAX_OUTCOME_SEQUENCE = (1 << 53) - 1

PHASES = {
    "unconfigured",
    "offline",
    "starting",
    "listening",
    "calling",
    "connected",
    "testing",
    "relay",
    "error",
}
DEFAULT_SETTINGS: dict[str, Any] = {
    "quality": "balanced",
    "voiceEffect": "none",
    "chime": "tone",
    "snowflake": False,
    "hmac": True,
}
QUALITY_BITRATE = {"low": 12, "balanced": 16, "high": 24}
VOICE_EFFECTS = {"none", "deep", "high", "robot", "echo", "whisper"}
CHIMES = {"off", "tone", "double", "chirp", "ding", "click"}
BOOL_CONFIG_KEYS = {"snowflake", "hmac"}
PREFERRED_ROLES = {"", "caller", "listener"}
PEER_KINDS = {"direct", "group"}
CALL_STAGES = {"", "preparing", "opening-tor", "dialing"}
CALL_OUTCOMES = {"", "failed", "timeout"}
ONION_RE = re.compile(r"^[a-z2-7]{56}\.onion$")
SECRET_RE = re.compile(r"^[A-Za-z0-9_-]{32,256}$")
INVITE_PREFIX = "omaphone:v1:"
SNOWFLAKE_BINARY = "snowflake-client"
SNOWFLAKE_AUR_PACKAGE = "snowflake-pt-client-bin"
SELF_CONNECTION_MESSAGE = (
    "You cannot connect a phone to itself. Use this invite on your other phone."
)
CALL_FAILED_MESSAGE = (
    "Could not connect. Make sure the other phone is listening, then try again."
)
CALL_TIMEOUT_MESSAGE = (
    "The call took too long to connect. Make sure the other phone is listening, then try again."
)
CALL_OUTCOME_MESSAGES = {
    "failed": CALL_FAILED_MESSAGE,
    "timeout": CALL_TIMEOUT_MESSAGE,
}


class OmaphoneError(Exception):
    """A safe, user-facing error."""


@dataclasses.dataclass(frozen=True)
class Paths:
    data_dir: Path
    state_dir: Path
    runtime_dir: Path

    @classmethod
    def from_environment(cls, env: Mapping[str, str] | None = None) -> "Paths":
        env = os.environ if env is None else env
        home = Path(env.get("HOME") or str(Path.home()))
        data = Path(env.get("XDG_DATA_HOME") or home / ".local/share") / "omaphone"
        state_dir = Path(env.get("XDG_STATE_HOME") or home / ".local/state") / "omaphone"
        if env.get("XDG_RUNTIME_DIR"):
            runtime = Path(env["XDG_RUNTIME_DIR"]) / "omaphone"
        else:
            run_user = Path("/run/user") / str(os.getuid())
            runtime = run_user / "omaphone" if run_user.is_dir() else Path(tempfile.gettempdir()) / f"omaphone-{os.getuid()}"
        return cls(data, state_dir, runtime)

    @property
    def upstream_dir(self) -> Path:
        return self.data_dir / "terminalphone"

    @property
    def upstream_script(self) -> Path:
        return self.upstream_dir / "terminalphone.sh"

    @property
    def upstream_license(self) -> Path:
        return self.upstream_dir / "LICENSE"

    @property
    def upstream_data(self) -> Path:
        return self.upstream_dir / ".terminalphone"

    @property
    def secret_file(self) -> Path:
        return self.upstream_data / "shared_secret"

    @property
    def upstream_config(self) -> Path:
        return self.upstream_data / "config"

    @property
    def onion_file(self) -> Path:
        return self.upstream_data / "tor_data/hidden_service/hostname"

    @property
    def app_config(self) -> Path:
        return self.state_dir / "config.json"

    @property
    def desired_state(self) -> Path:
        return self.state_dir / "desired.json"

    @property
    def status_file(self) -> Path:
        return self.state_dir / "status.json"

    @property
    def log_file(self) -> Path:
        return self.state_dir / "daemon.log"

    @property
    def socket_file(self) -> Path:
        return self.runtime_dir / "daemon.sock"

    @property
    def lock_file(self) -> Path:
        return self.runtime_dir / "daemon.lock"


def ensure_private_dir(path: Path) -> None:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = os.stat(path, follow_symlinks=False)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise OmaphoneError(f"unsafe application directory: {path}")
    os.chmod(path, 0o700)


def ensure_layout(paths: Paths) -> None:
    for directory in (paths.data_dir, paths.state_dir, paths.runtime_dir, paths.upstream_dir, paths.upstream_data):
        ensure_private_dir(directory)


def atomic_write(path: Path, data: bytes, mode: int = 0o600) -> None:
    ensure_private_dir(path.parent)
    temporary = path.parent / f".{path.name}.{os.getpid()}.{random.getrandbits(64):016x}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, mode)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        os.chmod(path, mode)
        directory_fd = os.open(path.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def atomic_json(path: Path, value: Any) -> None:
    atomic_write(path, (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))


def read_json(path: Path, default: Any) -> Any:
    try:
        if path.stat().st_size > MAX_REQUEST_BYTES:
            return default
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, OSError, UnicodeError, json.JSONDecodeError):
        return default


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def asset_is_valid(path: Path, expected_sha256: str) -> bool:
    descriptor = -1
    try:
        path_info = os.lstat(path)
        if not stat.S_ISREG(path_info.st_mode) or path_info.st_size > MAX_DOWNLOAD_BYTES:
            return False
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
        opened_info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened_info.st_mode)
            or opened_info.st_dev != path_info.st_dev
            or opened_info.st_ino != path_info.st_ino
        ):
            return False
        digest = hashlib.sha256()
        with os.fdopen(descriptor, "rb", closefd=True) as handle:
            descriptor = -1
            for block in iter(lambda: handle.read(65_536), b""):
                digest.update(block)
        return hmac.compare_digest(digest.hexdigest(), expected_sha256)
    except OSError:
        return False
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def chmod_private_regular(path: Path) -> None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OmaphoneError(f"unsafe pinned asset: {path}")
        os.fchmod(descriptor, 0o600)
    finally:
        os.close(descriptor)


def verify_asset(data: bytes, expected_sha256: str, label: str) -> bytes:
    if not data or len(data) > MAX_DOWNLOAD_BYTES:
        raise OmaphoneError(f"invalid {label}: unexpected size")
    actual = sha256_bytes(data)
    if not hmac.compare_digest(actual, expected_sha256):
        raise OmaphoneError(f"invalid {label}: SHA-256 mismatch")
    return data


def fetch_url(url: str) -> bytes:
    try:
        request = urllib.request.Request(url, headers={"User-Agent": f"Omaphone/{BACKEND_VERSION}"})
        with urllib.request.urlopen(request, timeout=20) as response:
            if response.geturl() != url:
                raise OmaphoneError("pinned upstream URL redirected unexpectedly")
            return response.read(MAX_DOWNLOAD_BYTES + 1)
    except OmaphoneError:
        raise
    except (OSError, TimeoutError) as exc:
        raise OmaphoneError("could not download the pinned TerminalPhone asset") from exc


def read_verified_bundled_asset(path: Path, expected_sha256: str, label: str) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_DOWNLOAD_BYTES:
                raise OmaphoneError(f"invalid bundled {label}: unexpected file type or size")
            with os.fdopen(descriptor, "rb", closefd=False) as handle:
                payload = handle.read(MAX_DOWNLOAD_BYTES + 1)
        finally:
            os.close(descriptor)
    except OmaphoneError:
        raise
    except OSError as exc:
        raise OmaphoneError(f"could not read bundled {label}") from exc
    return verify_asset(payload, expected_sha256, f"bundled {label}")


def install_pinned_backend(
    paths: Paths, fetcher: Callable[[str], bytes] | None = None
) -> None:
    ensure_layout(paths)
    assets = (
        (
            paths.upstream_script,
            BUNDLED_UPSTREAM_SCRIPT,
            UPSTREAM_URL,
            UPSTREAM_SHA256,
            "TerminalPhone source",
        ),
        (
            paths.upstream_license,
            BUNDLED_UPSTREAM_LICENSE,
            UPSTREAM_LICENSE_URL,
            UPSTREAM_LICENSE_SHA256,
            "TerminalPhone license",
        ),
    )
    for destination, bundled, url, digest, label in assets:
        if asset_is_valid(destination, digest):
            chmod_private_regular(destination)
            continue
        if fetcher is None:
            payload = read_verified_bundled_asset(bundled, digest, label)
        else:
            payload = verify_asset(fetcher(url), digest, label)
        atomic_write(destination, payload)


def backend_installed(paths: Paths) -> bool:
    return asset_is_valid(paths.upstream_script, UPSTREAM_SHA256) and asset_is_valid(
        paths.upstream_license, UPSTREAM_LICENSE_SHA256
    )


def valid_secret(secret: str) -> bool:
    return bool(SECRET_RE.fullmatch(secret))


def read_secret(paths: Paths) -> str:
    try:
        if paths.secret_file.stat().st_size > 512:
            return ""
        value = paths.secret_file.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError, UnicodeError):
        return ""
    return value if valid_secret(value) else ""


def _random_secret() -> str:
    return base64.urlsafe_b64encode(os.urandom(32)).decode("ascii").rstrip("=")


def ensure_room_secret(paths: Paths) -> str:
    existing = read_secret(paths)
    if existing:
        os.chmod(paths.secret_file, 0o600)
        return existing
    secret = _random_secret()
    atomic_write(paths.secret_file, secret.encode("ascii"))
    return secret


def parse_bool(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.lower()
        if lowered == "true":
            return True
        if lowered == "false":
            return False
    raise OmaphoneError("value must be true or false")


def validate_config_value(key: str, value: Any) -> Any:
    if key == "quality" and isinstance(value, str) and value in QUALITY_BITRATE:
        return value
    if key == "voiceEffect" and isinstance(value, str) and value in VOICE_EFFECTS:
        return value
    if key == "chime" and isinstance(value, str) and value in CHIMES:
        return value
    if key in BOOL_CONFIG_KEYS:
        return parse_bool(value)
    if key not in DEFAULT_SETTINGS:
        raise OmaphoneError(f"unsupported config key: {key}")
    raise OmaphoneError(f"invalid value for {key}")


def load_app_config(paths: Paths) -> dict[str, Any]:
    raw = read_json(paths.app_config, {})
    settings = dict(DEFAULT_SETTINGS)
    if isinstance(raw, dict) and isinstance(raw.get("settings"), dict):
        for key, value in raw["settings"].items():
            try:
                settings[key] = validate_config_value(key, value)
            except OmaphoneError:
                pass
    peer = raw.get("peerAddress", "") if isinstance(raw, dict) else ""
    if not isinstance(peer, str):
        peer = ""
    if peer and not ONION_RE.fullmatch(peer):
        peer = ""
    peer_kind = ""
    if peer:
        raw_peer_kind = raw.get("peerKind") if isinstance(raw, dict) else None
        # Version 1.2.0 and older stored only an address. Those peers were all
        # direct calls, so a missing or invalid classification safely migrates
        # to direct without exposing an unvalidated value in status.
        peer_kind = (
            raw_peer_kind
            if isinstance(raw_peer_kind, str) and raw_peer_kind in PEER_KINDS
            else "direct"
        )
    preferred_role = raw.get("preferredRole", "") if isinstance(raw, dict) else ""
    if not isinstance(preferred_role, str) or preferred_role not in PREFERRED_ROLES:
        preferred_role = ""
    return {
        "settings": settings,
        "peerAddress": peer,
        "peerKind": peer_kind,
        "preferredRole": preferred_role,
    }


def save_app_config(paths: Paths, config: Mapping[str, Any]) -> None:
    atomic_json(paths.app_config, config)
    sync_upstream_config(paths, config["settings"])


def effective_preferred_role(
    config: Mapping[str, Any], *, listening: bool
) -> str:
    """Expose a safe role for legacy 1.1 configs without persisting a guess."""
    role = config.get("preferredRole", "")
    if isinstance(role, str) and role in {"caller", "listener"}:
        return role
    if listening:
        return "listener"
    return "caller" if config.get("peerAddress") else ""


def sync_upstream_config(paths: Paths, settings: Mapping[str, Any]) -> None:
    lines = [
        f"OPUS_BITRATE={QUALITY_BITRATE[settings['quality']]}",
        f'VOICE_EFFECT="{settings["voiceEffect"]}"',
        f'PTT_CHIME="{settings["chime"]}"',
        f"SNOWFLAKE_ENABLED={int(settings['snowflake'])}",
        f"HMAC_AUTH={int(settings['hmac'])}",
        "AUTO_LISTEN=0",
        "",
    ]
    atomic_write(paths.upstream_config, "\n".join(lines).encode("ascii"))


def normalize_onion_address(value: str) -> str:
    address = value.strip().lower()
    if address.startswith("http://"):
        address = address[7:]
    elif address.startswith("https://"):
        address = address[8:]
    address = address.rstrip("/")
    if not ONION_RE.fullmatch(address):
        raise OmaphoneError("address must be a v3 56-character base32 .onion hostname")
    return address


@dataclasses.dataclass(frozen=True)
class Invite:
    secret: str = dataclasses.field(repr=False)
    address: str
    hmac: bool = True
    kind: str = "direct"


def create_invite(
    secret: str,
    address: str = "",
    hmac_enabled: bool = True,
    kind: str = "direct",
) -> str:
    if not valid_secret(secret):
        raise OmaphoneError("room secret is missing or invalid")
    if address:
        address = normalize_onion_address(address)
    if not isinstance(kind, str) or kind not in PEER_KINDS:
        raise OmaphoneError("invite kind must be direct or group")
    payload = json.dumps(
        {
            "address": address,
            "kind": kind,
            "roomSettings": {"hmac": bool(hmac_enabled)},
            "secret": secret,
            "version": 1,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    tag = hmac.new(secret.encode("ascii"), b"omaphone-invite-v1\0" + payload, hashlib.sha256).digest()
    encoded = base64.urlsafe_b64encode(payload + tag).decode("ascii").rstrip("=")
    return INVITE_PREFIX + encoded


def parse_invite(code: str) -> Invite:
    code = code.strip()
    try:
        encoded_length = len(code.encode("utf-8"))
    except UnicodeEncodeError:
        raise OmaphoneError("invalid Omaphone invite") from None
    if encoded_length > MAX_INVITE_BYTES or not code.startswith(INVITE_PREFIX):
        raise OmaphoneError("invalid Omaphone invite")
    encoded = code[len(INVITE_PREFIX) :]
    try:
        padded = encoded + "=" * (-len(encoded) % 4)
        raw = base64.b64decode(padded.encode("ascii"), altchars=b"-_", validate=True)
        payload, supplied_tag = raw[:-32], raw[-32:]
        value = json.loads(payload.decode("utf-8"))
    except (ValueError, UnicodeError, json.JSONDecodeError):
        raise OmaphoneError("invalid Omaphone invite") from None
    if not isinstance(value, dict) or value.get("version") != 1:
        raise OmaphoneError("unsupported Omaphone invite")
    secret = value.get("secret")
    address = value.get("address", "")
    kind = value.get("kind", "direct")
    room_settings = value.get("roomSettings", {})
    if (
        not isinstance(secret, str)
        or not valid_secret(secret)
        or not isinstance(address, str)
        or not isinstance(kind, str)
        or kind not in PEER_KINDS
    ):
        raise OmaphoneError("invalid Omaphone invite")
    if not isinstance(room_settings, dict) or set(room_settings) - {"hmac"}:
        raise OmaphoneError("invalid Omaphone room settings")
    hmac_enabled = room_settings.get("hmac", True)
    if not isinstance(hmac_enabled, bool):
        raise OmaphoneError("invalid Omaphone room settings")
    expected = hmac.new(secret.encode("ascii"), b"omaphone-invite-v1\0" + payload, hashlib.sha256).digest()
    if not hmac.compare_digest(expected, supplied_tag):
        raise OmaphoneError("invalid Omaphone invite checksum")
    if address:
        address = normalize_onion_address(address)
    return Invite(secret, address, hmac_enabled, kind)


def snowflake_available(which: Callable[[str], str | None] | None = None) -> bool:
    resolver = shutil.which if which is None else which
    return bool(resolver(SNOWFLAKE_BINARY))


def dependency_status(settings: Mapping[str, Any], which: Callable[[str], str | None] = shutil.which) -> list[str]:
    missing = [name for name in ("tor", "opusenc", "opusdec", "sox", "socat", "openssl") if not which(name)]
    pulse_ready = bool(which("parec") and which("pacat"))
    alsa_ready = bool(which("arecord") and which("aplay"))
    if not pulse_ready and not alsa_ready:
        missing.append("parec+pacat or arecord+aplay")
    if settings.get("snowflake") and not snowflake_available(which):
        missing.append(SNOWFLAKE_BINARY)
    return missing


def required_dependency_status(
    settings: Mapping[str, Any], which: Callable[[str], str | None] | None = None
) -> list[str]:
    """Return only dependencies required for Omaphone's standard Tor mode."""
    missing = dependency_status(settings) if which is None else dependency_status(settings, which)
    return [name for name in missing if name != SNOWFLAKE_BINARY]


def status_defaults(settings: Mapping[str, Any] | None = None) -> dict[str, Any]:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "backendVersion": BACKEND_VERSION,
        "phase": "unconfigured",
        "configured": False,
        "backendInstalled": False,
        "dependenciesReady": False,
        "missingDependencies": [],
        "snowflakeAvailable": False,
        "online": False,
        "busy": False,
        "onion": "",
        "remoteAddress": "",
        "pairedAddress": "",
        "peerKind": "",
        "hasPeer": False,
        "selfPeer": False,
        "preferredRole": "",
        "callStage": "",
        "torProgress": 0,
        "lastCallOutcome": "",
        "lastCallMessage": "",
        "callOutcomeSequence": 0,
        "localTalking": False,
        "remoteTalking": False,
        "groupCall": False,
        "roomSize": 0,
        "relayReady": False,
        "messages": [],
        "settings": dict(DEFAULT_SETTINGS if settings is None else settings),
        "lastError": "",
    }


def utc_timestamp() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


@dataclasses.dataclass(frozen=True)
class OutputEvent:
    kind: str
    value: str = ""


class AnsiCleaner:
    """Incrementally remove CSI/OSC/DCS and C0/C1 terminal controls."""

    def __init__(self) -> None:
        self.state = "normal"
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")

    def feed(self, data: bytes) -> str:
        output: list[str] = []
        for char in self.decoder.decode(data):
            code = ord(char)
            if self.state == "normal":
                if char == "\x1b":
                    self.state = "escape"
                elif code == 0x9B:
                    self.state = "csi"
                elif code == 0x9D:
                    self.state = "osc"
                elif code in {0x90, 0x98, 0x9E, 0x9F}:
                    self.state = "string"
                elif char in "\r\n":
                    output.append("\n")
                elif char == "\t":
                    output.append("\t")
                elif code < 0x20 or code == 0x7F or 0x80 <= code <= 0x9F:
                    continue
                else:
                    output.append(char)
            elif self.state == "escape":
                if char == "[":
                    self.state = "csi"
                elif char == "]":
                    self.state = "osc"
                elif char in "P^_X":
                    self.state = "string"
                elif 0x30 <= code <= 0x7E:
                    self.state = "normal"
            elif self.state == "csi":
                if char == "\x1b":
                    self.state = "escape"
                elif code == 0x9B:
                    self.state = "csi"
                elif code == 0x9D:
                    self.state = "osc"
                elif code in {0x90, 0x98, 0x9E, 0x9F}:
                    self.state = "string"
                elif code == 0x9C or code in {0x18, 0x1A}:
                    self.state = "normal"
                elif 0x40 <= code <= 0x7E:
                    self.state = "normal"
            elif self.state in {"osc", "string"}:
                if char == "\x07" or code == 0x9C:
                    self.state = "normal"
                elif char == "\x1b":
                    self.state = "string_escape"
            elif self.state == "string_escape":
                self.state = "normal" if char == "\\" else ("escape" if char == "\x1b" else "string")
        return "".join(output)


def sanitize_terminal_text(text: str) -> str:
    cleaner = AnsiCleaner()
    return cleaner.feed(text.encode("utf-8", "replace"))


def _safe_event_text(value: str) -> str:
    value = sanitize_terminal_text(value).replace("\n", " ").replace("\t", " ")
    value = " ".join(value.split())
    return value[:MAX_MESSAGE_CHARS]


def _plain_call_message(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return _safe_event_text(value)[:MAX_CALL_MESSAGE_CHARS]


def _bounded_outcome_sequence(value: Any) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        return 0
    return max(0, min(value, MAX_OUTCOME_SEQUENCE))


_INCOMING_CHAT_RE = re.compile(r"^\s*\[MSG\]\s?(.*)$", re.I)
_OUTGOING_CHAT_RE = re.compile(r"^\s*\[you\]\s?(.*)$", re.I)


def _is_chat_line(line: str) -> bool:
    return bool(_INCOMING_CHAT_RE.match(line) or _OUTGOING_CHAT_RE.match(line))


def _parse_terminal_line(line: str) -> list[OutputEvent]:
    """Parse one sanitized display line, classifying chat before controls."""
    incoming = _INCOMING_CHAT_RE.match(line)
    if incoming:
        message = _safe_event_text(incoming.group(1))
        return [OutputEvent("incoming_message", message)] if message else []
    outgoing = _OUTGOING_CHAT_RE.match(line)
    if outgoing:
        message = _safe_event_text(outgoing.group(1))
        return [OutputEvent("outgoing_message", message)] if message else []

    events: list[OutputEvent] = []
    stripped = line.strip()
    if re.fullmatch(r"Protect it with a passphrase\? \[Y/n\]:", stripped):
        events.append(OutputEvent("migration_prompt"))
    if re.fullmatch(r"Enter \.onion address:", stripped):
        events.append(OutputEvent("address_prompt"))
    if re.fullmatch(r"Start relay\? \[Y/n\]:", stripped):
        events.append(OutputEvent("relay_prompt"))
    if re.fullmatch(r"Continue\? \[y/N\]:", stripped):
        events.append(OutputEvent("rotate_prompt"))
    if re.fullmatch(r"Select:\s*", stripped):
        events.append(OutputEvent("menu_prompt"))
    if re.fullmatch(r"Press Enter to continue(?:\.\.\.)?", stripped):
        events.append(OutputEvent("continue_prompt"))
    if re.fullmatch(r"MSG>", stripped):
        events.append(OutputEvent("message_prompt"))

    # These controls intentionally match only output emitted by the pinned
    # TerminalPhone revision. The dialing event never carries the peer address.
    if re.fullmatch(r"\[INFO\] Starting Tor\.\.\.", stripped):
        events.append(OutputEvent("tor_start"))
    bootstrap_match = re.fullmatch(
        r"Bootstrapped ([0-9]{1,3})%(?: \([^()\r\n]{1,64}\): [^\r\n]{1,512})?",
        stripped,
    )
    if bootstrap_match:
        progress = int(bootstrap_match.group(1))
        if 0 <= progress <= 100:
            events.append(OutputEvent("tor_progress", str(progress)))
    dialing_match = re.fullmatch(
        r"Connecting to [a-z2-7]{56}\.onion:([0-9]{1,5}) via Tor\.\.\.",
        stripped,
        re.I,
    )
    if dialing_match and 1 <= int(dialing_match.group(1)) <= 65_535:
        events.append(OutputEvent("dialing"))

    onion_match = re.fullmatch(
        r"(?:Your address:|Relay address:)\s*([a-z2-7]{56}\.onion)", stripped, re.I
    )
    if onion_match:
        events.append(OutputEvent("onion", onion_match.group(1).lower()))
    connected_match = re.fullmatch(r"CALL CONNECTED(?:\s+([a-z2-7]{56}\.onion))?", stripped, re.I)
    if " ".join(stripped.split()) == "CALL CONNECTED RELAY (group)":
        events.append(OutputEvent("connected_group"))
    elif connected_match:
        events.append(OutputEvent("connected", (connected_match.group(1) or "").lower()))
    elif re.fullmatch(r"Incoming call detected!", stripped):
        events.append(OutputEvent("connected"))
    elif re.fullmatch(r"(?:\[\s*OK\]\s*)?Call connected!", stripped, re.I):
        events.append(OutputEvent("connected"))
    if re.fullmatch(r"(?:═+\s*)?Listening for Calls(?:\s*═+)?", stripped):
        events.append(OutputEvent("listening"))
    if re.fullmatch(r"(?:\[INFO\]\s*)?Waiting for incoming connection(?:\.\.\.)?", stripped, re.I):
        events.append(OutputEvent("listening"))
    if re.fullmatch(r"(?:═+\s*)?Audio Loopback Test(?:\s*═+)?", stripped):
        events.append(OutputEvent("testing"))
    if re.fullmatch(r"(?:\[\s*OK\]\s*)?Relay active(?:\s+[—-]\s+waiting for callers(?:\.\.\.)?)?", stripped, re.I):
        events.append(OutputEvent("relay"))
    if (
        re.fullmatch(r"Remote party hung up\.?", stripped, re.I)
        or re.fullmatch(r"Connection lost\.?", stripped, re.I)
        or re.fullmatch(r"CALL ENDED", stripped, re.I)
    ):
        events.append(OutputEvent("call_ended"))
    if re.search(r"(?:^|\s)Remote:\s*(?:.\s*)?Recording(?:\s|$)", line, re.I):
        events.append(OutputEvent("remote_talking", "true"))
    if re.search(r"(?:^|\s)Remote:\s*Idle(?:\s|$)", line, re.I):
        events.append(OutputEvent("remote_talking", "false"))
    # Both displays are updated in place, so several updates can be
    # concatenated in the PTY byte stream without a newline. Only the newest
    # complete, tightly-shaped counter on this display line is authoritative.
    room_matches = [
        *re.finditer(r"(?:^|\s)Group:\s*([0-9]{1,5})\s+callers\b", line),
        *re.finditer(r"(?:^|\s)Callers:\s*([0-9]{1,5})(?=\s|$)", line),
    ]
    if room_matches:
        newest = max(room_matches, key=lambda match: match.start())
        room_size = int(newest.group(1))
        if room_size <= MAX_ROOM_SIZE:
            events.append(OutputEvent("room_size", str(room_size)))
    failure = re.fullmatch(r"\s*\[FAIL\]\s*(.*)", line, re.I)
    if failure:
        events.append(OutputEvent("error", _safe_event_text(failure.group(1)) or "TerminalPhone failed"))
    return events


def parse_terminal_output(text: str) -> list[OutputEvent]:
    """Pure, defensive parser for bounded PTY output."""
    clean = sanitize_terminal_text(text)[-MAX_LINE_CHARS:]
    events: list[OutputEvent] = []
    for line in clean.split("\n"):
        events.extend(_parse_terminal_line(line))
    return events


class OutputStreamParser:
    def __init__(self) -> None:
        self.cleaner = AnsiCleaner()
        self.partial = ""
        self.emitted: set[OutputEvent] = set()
        self.mutable_values: dict[str, str] = {}

    def feed(self, data: bytes) -> tuple[str, list[OutputEvent]]:
        cleaned = self.cleaner.feed(data)
        events: list[OutputEvent] = []
        pieces = cleaned.split("\n")
        for index, piece in enumerate(pieces):
            self.partial = (self.partial + piece)[-MAX_LINE_CHARS:]
            complete_line = index < len(pieces) - 1
            # Chat is untrusted data. Wait for its line boundary, then classify
            # it before looking for any control-looking text in the payload.
            parsed = [] if _is_chat_line(self.partial) and not complete_line else parse_terminal_output(self.partial)
            for event in parsed:
                if event.kind == "room_size":
                    if self.mutable_values.get(event.kind) == event.value:
                        continue
                    self.mutable_values[event.kind] = event.value
                    events.append(event)
                elif event not in self.emitted:
                    self.emitted.add(event)
                    events.append(event)
            if complete_line:
                self.partial = ""
                self.emitted.clear()
                self.mutable_values.clear()
        return cleaned, events


def desired_online(paths: Paths) -> bool:
    value = read_json(paths.desired_state, {})
    return bool(value.get("online", False)) if isinstance(value, dict) else False


def save_desired_online(paths: Paths, value: bool) -> None:
    atomic_json(paths.desired_state, {"online": bool(value)})


def read_onion(paths: Paths) -> str:
    try:
        value = paths.onion_file.read_text(encoding="ascii").strip().lower()
    except (FileNotFoundError, OSError, UnicodeError):
        return ""
    return value if ONION_RE.fullmatch(value) else ""


def build_initial_status(paths: Paths) -> dict[str, Any]:
    config = load_app_config(paths)
    status = status_defaults(config["settings"])
    installed = backend_installed(paths)
    secret = read_secret(paths)
    missing = dependency_status(config["settings"])
    required_missing = [name for name in missing if name != SNOWFLAKE_BINARY]
    configured = bool(installed and secret)
    prior = read_json(paths.status_file, {})
    prior_messages = prior.get("messages", []) if isinstance(prior, dict) else []
    if isinstance(prior_messages, list):
        status["messages"] = [message for message in prior_messages[-MAX_MESSAGES:] if isinstance(message, dict)]
    prior_outcome = prior.get("lastCallOutcome", "") if isinstance(prior, dict) else ""
    if not isinstance(prior_outcome, str) or prior_outcome not in CALL_OUTCOMES:
        prior_outcome = ""
    prior_sequence = prior.get("callOutcomeSequence", 0) if isinstance(prior, dict) else 0
    onion = read_onion(paths)
    paired_address = config["peerAddress"]
    online = desired_online(paths)
    status.update(
        {
            "phase": "offline" if configured else "unconfigured",
            "configured": configured,
            "backendInstalled": installed,
            "dependenciesReady": not required_missing,
            "missingDependencies": missing,
            "snowflakeAvailable": snowflake_available(),
            "online": online,
            "onion": onion,
            "remoteAddress": paired_address,
            "pairedAddress": paired_address,
            "peerKind": config["peerKind"],
            "hasPeer": bool(paired_address),
            "selfPeer": bool(paired_address and onion and paired_address == onion),
            "preferredRole": effective_preferred_role(config, listening=online),
            "lastCallOutcome": prior_outcome,
            "lastCallMessage": _plain_call_message(
                CALL_OUTCOME_MESSAGES.get(prior_outcome, "")
            ),
            "callOutcomeSequence": _bounded_outcome_sequence(prior_sequence),
        }
    )
    return status


def arch_install_command(
    which: Callable[[str], str | None] = shutil.which,
    os_release: str | None = None,
) -> list[str]:
    if os_release is None:
        try:
            os_release = Path("/etc/os-release").read_text(encoding="utf-8")
        except OSError:
            os_release = ""
    fields: dict[str, str] = {}
    for line in os_release.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            fields[key] = value.strip().strip('"')
    arch_like = fields.get("ID") == "arch" or "arch" in fields.get("ID_LIKE", "").split()
    if not arch_like or not which("pacman"):
        raise OmaphoneError("automatic dependency installation is supported only on Arch/Omarchy")
    if not which("pkexec"):
        raise OmaphoneError("pkexec is required to install dependencies")
    command = [
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
    return command


def install_dependencies(settings: Mapping[str, Any] | None = None) -> None:
    selected_settings = DEFAULT_SETTINGS if settings is None else settings
    missing = dependency_status(selected_settings)
    required_missing = [name for name in missing if name != SNOWFLAKE_BINARY]
    if not required_missing:
        return
    command = arch_install_command()
    # stdout is reserved for the single JSON response consumed by Service.qml.
    # PolicyKit and pacman diagnostics remain on stderr for terminal callers.
    result = subprocess.run(command, check=False, stdout=subprocess.DEVNULL)
    if result.returncode:
        raise OmaphoneError(f"dependency installation failed with exit code {result.returncode}")
    remaining = required_dependency_status(selected_settings)
    if remaining:
        raise OmaphoneError("dependencies are still missing after installation: " + ", ".join(remaining))


@dataclasses.dataclass
class Invocation:
    kind: str
    pid: int
    master_fd: int
    parser: OutputStreamParser
    started_at: float
    address: str = dataclasses.field(default="", repr=False)
    dial_started_at: float = 0.0
    timeout_outcome: str = ""
    outcome_published: bool = False
    address_sent: bool = False
    relay_confirmed: bool = False
    relay_ready: bool = False
    relay_secret: str = dataclasses.field(default="", repr=False)
    rotate_stage: int = 0
    connected_once: bool = False
    write_buffer: bytearray = dataclasses.field(default_factory=bytearray, repr=False)
    write_failed: bool = False


class Supervisor:
    """Own exactly one TerminalPhone PTY and expose commands over a Unix socket."""

    def __init__(self, paths: Paths) -> None:
        self.paths = paths
        ensure_layout(paths)
        self.selector = selectors.DefaultSelector()
        self.status = build_initial_status(paths)
        self.invocation: Invocation | None = None
        self.pending_invocation: tuple[str, str] | None = None
        self.pending_text: str | None = None
        self.stop_reason = ""
        self.stop_deadline = 0.0
        self.stop_escalation_stage = 0
        self.ptt_next = 0.0
        self.ptt_deadline = 0.0
        self.listener_failures = 0
        self.listener_retry_at = 0.0
        self.last_client_at = time.monotonic()
        self.running = True
        self.server: socket.socket | None = None
        self._persist()

    def _refresh_static(self) -> None:
        config = load_app_config(self.paths)
        installed = backend_installed(self.paths)
        missing = dependency_status(config["settings"])
        required_missing = [name for name in missing if name != SNOWFLAKE_BINARY]
        configured = bool(installed and read_secret(self.paths))
        onion = read_onion(self.paths) or self.status.get("onion", "")
        if not isinstance(onion, str) or not ONION_RE.fullmatch(onion):
            onion = ""
        paired_address = config.get("peerAddress", "")
        online = desired_online(self.paths)
        listener_running = bool(
            self.invocation is not None
            and self.invocation.kind == "listen"
            and self.status.get("phase") in {"starting", "listening", "connected"}
        )
        self.status.update(
            {
                "configured": configured,
                "backendInstalled": installed,
                "dependenciesReady": not required_missing,
                "missingDependencies": missing,
                "snowflakeAvailable": snowflake_available(),
                "online": online,
                "settings": config["settings"],
                "onion": onion,
                "pairedAddress": paired_address,
                "peerKind": config.get("peerKind", "direct" if paired_address else ""),
                "hasPeer": bool(paired_address),
                "selfPeer": bool(
                    paired_address and onion and paired_address == onion
                ),
                "preferredRole": effective_preferred_role(
                    config, listening=online or listener_running
                ),
            }
        )
        if not self.status.get("remoteAddress"):
            self.status["remoteAddress"] = config["peerAddress"]
        if not configured and self.invocation is None:
            self.status["phase"] = "unconfigured"

    def _persist(self) -> None:
        self._refresh_static()
        self.status["messages"] = self.status.get("messages", [])[-MAX_MESSAGES:]
        self.status["busy"] = self.status["phase"] in {"starting", "calling", "testing", "relay"}
        self.status["localTalking"] = bool(self.status.get("localTalking") and self.invocation)
        self.status["remoteTalking"] = bool(self.status.get("remoteTalking") and self.invocation)
        self.status["groupCall"] = bool(self.status.get("groupCall") and self.invocation)
        invocation = self.invocation
        self.status["relayReady"] = bool(
            invocation
            and invocation.kind == "relay"
            and self.status["phase"] == "relay"
            and invocation.relay_ready
            and not getattr(self, "stop_reason", "")
        )
        room_size = self.status.get("roomSize", 0)
        room_context = bool(
            invocation
            and (self.status["groupCall"] or invocation.kind == "relay")
        )
        self.status["roomSize"] = (
            room_size
            if isinstance(room_size, int)
            and not isinstance(room_size, bool)
            and 0 <= room_size <= MAX_ROOM_SIZE
            and room_context
            else 0
        )
        if self.status["phase"] not in PHASES:
            self.status["phase"] = "error"
        call_stage = self.status.get("callStage", "")
        self.status["callStage"] = (
            call_stage if isinstance(call_stage, str) and call_stage in CALL_STAGES else ""
        )
        tor_progress = self.status.get("torProgress", 0)
        if not isinstance(tor_progress, int) or isinstance(tor_progress, bool):
            tor_progress = 0
        self.status["torProgress"] = max(0, min(tor_progress, 100))
        outcome = self.status.get("lastCallOutcome", "")
        if not isinstance(outcome, str) or outcome not in CALL_OUTCOMES:
            outcome = ""
        self.status["lastCallOutcome"] = outcome
        # Outcome copy is fixed rather than derived from upstream output.
        self.status["lastCallMessage"] = _plain_call_message(
            CALL_OUTCOME_MESSAGES.get(outcome, "")
        )
        self.status["callOutcomeSequence"] = _bounded_outcome_sequence(
            self.status.get("callOutcomeSequence", 0)
        )
        atomic_json(self.paths.status_file, self.status)

    def _response(self, **extra: Any) -> dict[str, Any]:
        self._persist()
        return {"ok": True, "status": self.status, **extra}

    def _error(self, message: str) -> dict[str, Any]:
        self.status["lastError"] = _safe_event_text(message)
        self._persist()
        return {"ok": False, "error": message, "status": self.status}

    def _append_message(self, direction: str, text: str) -> None:
        safe = _safe_event_text(text)
        if not safe:
            return
        self.status.setdefault("messages", []).append(
            {"direction": direction, "text": safe, "timestamp": utc_timestamp()}
        )
        self.status["messages"] = self.status["messages"][-MAX_MESSAGES:]

    def _local_onion(self) -> str:
        address = read_onion(self.paths)
        if address:
            return address
        candidate = self.status.get("onion", "")
        return candidate if isinstance(candidate, str) and ONION_RE.fullmatch(candidate) else ""

    def _reject_self_address(self, address: str) -> None:
        local_address = self._local_onion()
        if local_address and hmac.compare_digest(address, local_address):
            raise OmaphoneError(SELF_CONNECTION_MESSAGE)

    def _clear_call_outcome(self) -> None:
        self.status["lastCallOutcome"] = ""
        self.status["lastCallMessage"] = ""

    def _publish_call_outcome(self, outcome: str) -> None:
        if outcome not in {"failed", "timeout"}:
            return
        invocation = self.invocation
        if invocation is not None and invocation.kind == "call" and invocation.outcome_published:
            return
        sequence = _bounded_outcome_sequence(self.status.get("callOutcomeSequence", 0))
        # Sequence zero is reserved for "no outcome has ever been published".
        self.status["callOutcomeSequence"] = 1 if sequence >= MAX_OUTCOME_SEQUENCE else sequence + 1
        self.status["lastCallOutcome"] = outcome
        self.status["lastCallMessage"] = _plain_call_message(CALL_OUTCOME_MESSAGES[outcome])
        self.status["callStage"] = ""
        self.status["torProgress"] = 0
        self.status["lastError"] = CALL_OUTCOME_MESSAGES[outcome]
        if invocation is not None and invocation.kind == "call":
            invocation.outcome_published = True
            if outcome == "timeout":
                invocation.timeout_outcome = outcome

    def _save_wrapper_config(self, config: Mapping[str, Any]) -> None:
        """Persist wrapper-only metadata without rewriting live upstream config."""
        if self.invocation is None:
            save_app_config(self.paths, config)
        else:
            atomic_json(self.paths.app_config, config)

    def _commit_invite_config(
        self,
        previous_config: Mapping[str, Any],
        next_config: Mapping[str, Any],
        next_secret: str,
    ) -> None:
        """Commit the two-file room identity, rolling back synchronous failures."""
        previous_secret = read_secret(self.paths)
        try:
            save_app_config(self.paths, next_config)
            atomic_write(self.paths.secret_file, next_secret.encode("ascii"))
        except OSError:
            # TerminalPhone is quiescent while this runs. Restore both sides of
            # the room identity before reporting failure; if restoration also
            # fails, callers still force desired-online false.
            try:
                save_app_config(self.paths, previous_config)
            except OSError:
                pass
            try:
                if previous_secret:
                    atomic_write(self.paths.secret_file, previous_secret.encode("ascii"))
                else:
                    self.paths.secret_file.unlink(missing_ok=True)
            except OSError:
                pass
            raise

    @staticmethod
    def _signal_child_tree(invocation: Invocation, signal_number: int) -> None:
        """Signal only a verified child-owned process group, otherwise its PID."""
        try:
            process_group = os.getpgid(invocation.pid)
        except OSError:
            return
        try:
            if process_group == invocation.pid:
                os.killpg(process_group, signal_number)
            else:
                os.kill(invocation.pid, signal_number)
        except OSError:
            pass

    def _update_pty_interest(self) -> None:
        invocation = self.invocation
        if invocation is None:
            return
        events = selectors.EVENT_READ
        if invocation.write_buffer and not invocation.write_failed:
            events |= selectors.EVENT_WRITE
        try:
            self.selector.modify(invocation.master_fd, events, "pty")
        except (KeyError, OSError, ValueError):
            pass

    def _flush_pty_writes(self) -> bool:
        """Drain queued PTY input without dropping partial or EAGAIN writes."""
        invocation = self.invocation
        if invocation is None or invocation.write_failed:
            return False
        while invocation.write_buffer:
            try:
                written = os.write(invocation.master_fd, bytes(invocation.write_buffer))
            except InterruptedError:
                continue
            except BlockingIOError:
                self._update_pty_interest()
                return True
            except OSError as exc:
                if exc.errno in {errno.EAGAIN, errno.EWOULDBLOCK}:
                    self._update_pty_interest()
                    return True
                invocation.write_failed = True
                invocation.write_buffer.clear()
                self.status["lastError"] = "failed to deliver input to TerminalPhone"
                self._update_pty_interest()
                return False
            if not isinstance(written, int) or written < 0 or written > len(invocation.write_buffer):
                invocation.write_failed = True
                invocation.write_buffer.clear()
                self.status["lastError"] = "failed to deliver input to TerminalPhone"
                self._update_pty_interest()
                return False
            if written == 0:
                self._update_pty_interest()
                return True
            del invocation.write_buffer[:written]
        self._update_pty_interest()
        return True

    def _write_pty(self, data: bytes) -> bool:
        """Accept one complete payload into the bounded, ordered PTY queue."""
        invocation = self.invocation
        if invocation is None or invocation.write_failed:
            return False
        payload = bytes(data)
        if not payload:
            return True
        if len(invocation.write_buffer) + len(payload) > MAX_PTY_WRITE_QUEUE_BYTES:
            self.status["lastError"] = "TerminalPhone input queue is full"
            return False
        invocation.write_buffer.extend(payload)
        return self._flush_pty_writes()

    def _clear_ptt(self, *, clear_remote: bool = True) -> None:
        self.status["localTalking"] = False
        if clear_remote:
            self.status["remoteTalking"] = False
        self.ptt_next = 0.0
        self.ptt_deadline = 0.0

    def _clear_room(self) -> None:
        self.status["groupCall"] = False
        self.status["roomSize"] = 0

    def _clear_relay_ready(self) -> None:
        self.status["relayReady"] = False
        if self.invocation is not None:
            self.invocation.relay_ready = False

    def _start_invocation(self, kind: str, address: str = "") -> None:
        if self.invocation is not None:
            raise OmaphoneError("TerminalPhone is already running")
        if kind == "call":
            address = normalize_onion_address(address)
            self._reject_self_address(address)
        self._refresh_static()
        if not self.status["configured"]:
            raise OmaphoneError("run setup before starting TerminalPhone")
        if not self.status["dependenciesReady"]:
            missing = [
                name for name in self.status["missingDependencies"] if name != SNOWFLAKE_BINARY
            ]
            raise OmaphoneError("missing dependencies: " + ", ".join(missing))
        if self.status["settings"].get("snowflake") and not self.status["snowflakeAvailable"]:
            raise OmaphoneError(
                "Snowflake is turned on, but its client is not installed. "
                "Turn Snowflake off to use normal Tor, or install "
                f"{SNOWFLAKE_AUR_PACKAGE} from the AUR."
            )
        arguments = {
            "listen": ["listen"],
            # argv[2] only gets past upstream dispatch; call_remote still ignores it and prompts.
            "call": ["call", address],
            "test": ["test"],
            "relay": ["relay"],
            "rotate": [],
        }
        if kind not in arguments:
            raise OmaphoneError("invalid invocation")
        # The validated address must be argv[2] to enter upstream's call branch,
        # but is still sent only after the real interactive prompt appears.
        pid, master_fd = pty.fork()
        if pid == 0:
            environment = dict(os.environ)
            environment.setdefault("TERM", "xterm-256color")
            bash = shutil.which("bash") or "/usr/bin/bash"
            try:
                os.execvpe(bash, [bash, str(self.paths.upstream_script), *arguments[kind]], environment)
            except Exception:
                os._exit(127)
        os.set_blocking(master_fd, False)
        invocation = Invocation(
            kind,
            pid,
            master_fd,
            OutputStreamParser(),
            time.monotonic(),
            address=address,
            relay_secret=_random_secret() if kind == "relay" else "",
        )
        self.invocation = invocation
        self.selector.register(master_fd, selectors.EVENT_READ, "pty")
        self.stop_reason = ""
        self.stop_deadline = 0.0
        self.stop_escalation_stage = 0
        self.pending_text = None
        self._clear_ptt()
        self._clear_room()
        self._clear_relay_ready()
        self.status["lastError"] = ""
        self.status["phase"] = {
            "listen": "starting",
            "call": "calling",
            "test": "testing",
            "relay": "relay",
            "rotate": "starting",
        }[kind]
        if kind == "call":
            self._clear_call_outcome()
            self.status["callStage"] = "preparing"
            self.status["torProgress"] = 0
        if address:
            self.status["remoteAddress"] = address
        self._persist()

    def _request_stop(self, reason: str, pending: tuple[str, str] | None = None) -> None:
        self.pending_invocation = pending
        self.stop_reason = reason
        self.stop_escalation_stage = 0
        self._clear_ptt()
        self._clear_room()
        self._clear_relay_ready()
        if reason not in {"call-timeout", "transition"} or (
            self.invocation is not None
            and self.invocation.kind == "call"
            and reason != "call-timeout"
        ):
            self.status["callStage"] = ""
            self.status["torProgress"] = 0
        if self.invocation is not None:
            # Q works in raw call mode and, with newline, in cooked listen/relay prompts.
            self._write_pty(b"Q\n")
            self.stop_deadline = time.monotonic() + 5.0

    def _transition(self, kind: str, address: str = "") -> None:
        self._clear_relay_ready()
        if kind == "call":
            address = normalize_onion_address(address)
            self._reject_self_address(address)
            self._clear_call_outcome()
            self.status["callStage"] = "preparing"
            self.status["torProgress"] = 0
        if self.invocation is None:
            try:
                self._start_invocation(kind, address)
            except OmaphoneError:
                if kind == "call":
                    self.status["callStage"] = ""
                    self.status["torProgress"] = 0
                raise
        else:
            self._request_stop("transition", (kind, address))
            self.status["phase"] = {
                "listen": "starting",
                "call": "calling",
                "test": "testing",
                "relay": "relay",
                "rotate": "starting",
            }[kind]
            if address:
                self.status["remoteAddress"] = address

    def _quiesce_listener(self) -> bool:
        """Stop an online listener and synchronously wait before file mutation."""
        if self.invocation is None:
            return desired_online(self.paths)
        if self.invocation.kind != "listen":
            raise OmaphoneError("finish the active call or test before reconfiguring")
        restart = desired_online(self.paths)
        self._request_stop("reconfigure")
        # Suppress the normal desired-online restart until the mutation is committed.
        save_desired_online(self.paths, False)
        deadline = time.monotonic() + 8.0
        while self.invocation is not None and time.monotonic() < deadline:
            self._read_pty()
            self._tick()
            time.sleep(0.02)
        if self.invocation is not None:
            self._signal_child_tree(self.invocation, signal.SIGKILL)
            kill_deadline = time.monotonic() + 1.0
            while self.invocation is not None and time.monotonic() < kill_deadline:
                self._tick()
                time.sleep(0.01)
        if self.invocation is not None:
            save_desired_online(self.paths, restart)
            raise OmaphoneError("could not stop TerminalPhone safely")
        save_desired_online(self.paths, restart)
        return restart

    def _handle_output_event(self, event: OutputEvent) -> None:
        invocation = self.invocation
        if invocation is None:
            return
        if event.kind == "migration_prompt":
            # The pinned script asks twice on some entry points; answer every occurrence.
            self._write_pty(b"n\n")
        elif event.kind == "address_prompt" and invocation.kind == "call" and not invocation.address_sent:
            if self._write_pty(invocation.address.encode("ascii") + b"\n"):
                invocation.address_sent = True
        elif event.kind == "relay_prompt" and invocation.kind == "relay" and not invocation.relay_confirmed:
            if self._write_pty(b"y\n"):
                invocation.relay_confirmed = True
        elif invocation.kind == "rotate" and event.kind == "menu_prompt":
            if invocation.rotate_stage == 0:
                if self._write_pty(b"11\n"):
                    invocation.rotate_stage = 1
            elif invocation.rotate_stage == 3:
                if self._write_pty(b"0\n"):
                    invocation.rotate_stage = 4
        elif invocation.kind == "rotate" and event.kind == "rotate_prompt" and invocation.rotate_stage == 1:
            if self._write_pty(b"y\n"):
                invocation.rotate_stage = 2
        elif invocation.kind == "rotate" and event.kind == "continue_prompt" and invocation.rotate_stage == 2:
            if self._write_pty(b"\n"):
                invocation.rotate_stage = 3
        elif event.kind == "message_prompt" and self.pending_text is not None:
            if self._write_pty(self.pending_text.encode("utf-8") + b"\n"):
                self.pending_text = None
        elif event.kind == "onion":
            self.status["onion"] = event.value
        elif event.kind == "tor_start" and invocation.kind == "call":
            self.status["callStage"] = "opening-tor"
            self.status["torProgress"] = 0
        elif event.kind == "tor_progress" and invocation.kind == "call":
            if re.fullmatch(r"[0-9]{1,3}", event.value):
                progress = int(event.value)
                if 0 <= progress <= 100:
                    self.status["callStage"] = "opening-tor"
                    self.status["torProgress"] = progress
        elif event.kind == "dialing" and invocation.kind == "call":
            self.status["callStage"] = "dialing"
            self.status["torProgress"] = 100
            if not invocation.dial_started_at:
                invocation.dial_started_at = time.monotonic()
        elif event.kind == "listening":
            self._clear_room()
            self._clear_relay_ready()
            self.status["phase"] = "listening"
            invocation.connected_once = False
            self.listener_failures = 0
            self.listener_retry_at = 0.0
        elif event.kind == "connected":
            self._clear_room()
            self._clear_relay_ready()
            self.status["phase"] = "connected"
            invocation.connected_once = True
            self.status["callStage"] = ""
            self.status["torProgress"] = 100 if invocation.kind == "call" else 0
            self._clear_call_outcome()
            if event.value:
                self.status["remoteAddress"] = event.value
                # A future authenticated listener display may identify the
                # caller. Persist it only after the connected control and only
                # when replacing no peer (or a stale self-pair).
                if (
                    invocation.kind == "listen"
                    and self.status.get("settings", {}).get("hmac") is True
                    and event.value != self._local_onion()
                ):
                    config = load_app_config(self.paths)
                    peer = config["peerAddress"]
                    if not peer or peer == self._local_onion():
                        config["peerAddress"] = event.value
                        config["peerKind"] = "direct"
                        try:
                            atomic_json(self.paths.app_config, config)
                        except OSError:
                            # The connected call remains usable; callback
                            # metadata can be learned again on a later call.
                            pass
        elif event.kind == "connected_group":
            self._clear_relay_ready()
            self.status["groupCall"] = True
            self.status["roomSize"] = 0
            self.status["phase"] = "connected"
            invocation.connected_once = True
            self.status["callStage"] = ""
            self.status["torProgress"] = 100 if invocation.kind == "call" else 0
            self._clear_call_outcome()
        elif event.kind == "testing":
            self._clear_room()
            self._clear_relay_ready()
            self.status["phase"] = "testing"
        elif event.kind == "relay":
            self._clear_room()
            self.status["phase"] = "relay"
            if invocation.kind == "relay" and not getattr(self, "stop_reason", ""):
                invocation.relay_ready = True
                self.status["relayReady"] = True
        elif event.kind == "call_ended":
            self._clear_ptt()
            self._clear_room()
            self._clear_relay_ready()
            self.status["phase"] = "starting" if desired_online(self.paths) else "offline"
        elif event.kind == "remote_talking":
            self.status["remoteTalking"] = event.value == "true"
        elif event.kind == "room_size":
            if invocation.kind == "relay" or self.status.get("groupCall"):
                if re.fullmatch(r"[0-9]{1,5}", event.value):
                    room_size = int(event.value)
                    if room_size <= MAX_ROOM_SIZE:
                        self.status["roomSize"] = room_size
        elif event.kind == "incoming_message":
            self._append_message("incoming", event.value)
        elif event.kind == "outgoing_message":
            self._append_message("outgoing", event.value)
        elif event.kind == "error":
            self.status["lastError"] = event.value
        self._persist()

    def _read_pty(self) -> None:
        invocation = self.invocation
        if invocation is None:
            return
        try:
            data = os.read(invocation.master_fd, 65_536)
        except OSError as exc:
            if exc.errno not in {errno.EAGAIN, errno.EIO}:
                self.status["lastError"] = "failed to read TerminalPhone output"
            return
        if not data:
            return
        _, events = invocation.parser.feed(data)
        # Never persist PTY output: it can contain decrypted/echoed chat plaintext.
        for event in events:
            self._handle_output_event(event)

    def _finish_invocation(self, wait_status: int) -> None:
        invocation = self.invocation
        if invocation is None:
            return
        try:
            self.selector.unregister(invocation.master_fd)
        except Exception:
            pass
        try:
            os.close(invocation.master_fd)
        except OSError:
            pass
        kind = invocation.kind
        deliberate = bool(getattr(self, "stop_reason", ""))
        exit_code = os.waitstatus_to_exitcode(wait_status)
        if kind == "call" and not invocation.connected_once:
            if invocation.timeout_outcome:
                # The timeout was published when the guard fired.
                pass
            elif not deliberate:
                self._publish_call_outcome("failed")
            else:
                self.status["callStage"] = ""
                self.status["torProgress"] = 0
        invocation.write_buffer.clear()
        self._clear_relay_ready()
        self.invocation = None
        self.pending_text = None
        self._clear_ptt()
        self._clear_room()
        self.status["remoteTalking"] = False
        pending = self.pending_invocation
        self.pending_invocation = None
        self.stop_reason = ""
        self.stop_deadline = 0.0
        self.stop_escalation_stage = 0
        self.status["onion"] = read_onion(self.paths) or self.status.get("onion", "")
        if pending:
            try:
                self._start_invocation(*pending)
            except OmaphoneError as exc:
                self.status["phase"] = "error"
                self.status["lastError"] = str(exc)
                if pending[0] == "call":
                    self.status["callStage"] = ""
                    self.status["torProgress"] = 0
                    if desired_online(self.paths):
                        try:
                            self._start_invocation("listen")
                        except OmaphoneError:
                            pass
                        else:
                            self.status["lastError"] = str(exc)
        elif desired_online(self.paths):
            if kind == "listen" and not deliberate and not invocation.connected_once:
                self._schedule_listener_retry(
                    self.status.get("lastError") or "listener exited unexpectedly"
                )
            else:
                try:
                    self._start_invocation("listen")
                except OmaphoneError as exc:
                    self.status["phase"] = "error"
                    self.status["lastError"] = str(exc)
        else:
            self.listener_failures = 0
            self.listener_retry_at = 0.0
            self.status["phase"] = "offline" if self.status["configured"] else "unconfigured"
            if exit_code and not deliberate and kind != "call":
                self.status["phase"] = "error"
                self.status["lastError"] = self.status.get("lastError") or f"TerminalPhone exited with status {exit_code}"
        self._persist()

    def _schedule_listener_retry(self, message: str) -> None:
        self._clear_relay_ready()
        self.listener_failures = max(0, getattr(self, "listener_failures", 0)) + 1
        exponent = min(self.listener_failures - 1, 10)
        delay = min(LISTENER_RETRY_BASE_SECONDS * (2**exponent), LISTENER_RETRY_MAX_SECONDS)
        self.listener_retry_at = time.monotonic() + delay
        self.status["phase"] = "error"
        self.status["lastError"] = f"{_safe_event_text(message)}; retrying listener in {delay:g}s"

    @staticmethod
    def _wait_for_child(pid: int, timeout: float) -> int | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                waited_pid, wait_status = os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                return 0
            except InterruptedError:
                continue
            if waited_pid:
                return wait_status
            time.sleep(0.02)
        return None

    def _shutdown_invocation(self) -> None:
        """Synchronously reap TerminalPhone before releasing the daemon lock."""
        self._clear_relay_ready()
        invocation = self.invocation
        if invocation is None:
            return
        self.pending_invocation = None
        self.stop_reason = "shutdown"
        self._clear_ptt()
        self._write_pty(b"Q\n")
        self._flush_pty_writes()
        wait_status = self._wait_for_child(invocation.pid, CHILD_GRACEFUL_EXIT_SECONDS)
        if wait_status is None:
            self._signal_child_tree(invocation, signal.SIGTERM)
            wait_status = self._wait_for_child(invocation.pid, CHILD_TERM_EXIT_SECONDS)
        if wait_status is None:
            self._signal_child_tree(invocation, signal.SIGKILL)
            try:
                _, wait_status = os.waitpid(invocation.pid, 0)
            except ChildProcessError:
                wait_status = 0
        try:
            self.selector.unregister(invocation.master_fd)
        except Exception:
            pass
        try:
            os.close(invocation.master_fd)
        except OSError:
            pass
        invocation.write_buffer.clear()
        self.invocation = None
        self.pending_text = None
        self.stop_deadline = 0.0
        self.stop_escalation_stage = 0
        self.status["localTalking"] = False
        self.status["remoteTalking"] = False
        self._clear_room()
        self.status["phase"] = (
            "starting"
            if desired_online(self.paths)
            else ("offline" if self.status.get("configured") else "unconfigured")
        )
        try:
            self._persist()
        except OSError:
            pass

    def _tick(self) -> None:
        now = time.monotonic()
        if self.invocation and self.invocation.write_buffer:
            self._flush_pty_writes()
        if self.status.get("localTalking") and self.invocation:
            if now >= self.ptt_deadline:
                self._clear_ptt(clear_remote=False)
                self.status["lastError"] = "push-to-talk stopped because its control lease expired"
                self._persist()
            elif now >= self.ptt_next:
                if self._write_pty(b" "):
                    self.ptt_next = now + random.uniform(PTT_INTERVAL_MIN, PTT_INTERVAL_MAX)
                else:
                    self._clear_ptt(clear_remote=False)
                    self.status["lastError"] = "push-to-talk stopped because TerminalPhone input was unavailable"
                    self._persist()
        if self.invocation and self.stop_deadline and now >= self.stop_deadline:
            escalation_stage = getattr(self, "stop_escalation_stage", 0)
            if escalation_stage == 0:
                self._signal_child_tree(self.invocation, signal.SIGTERM)
                self.stop_escalation_stage = 1
                self.stop_deadline = now + 2.0
            elif escalation_stage == 1:
                self._signal_child_tree(self.invocation, signal.SIGKILL)
                self.stop_escalation_stage = 2
                self.stop_deadline = 0.0
            else:
                self.stop_deadline = 0.0
        invocation = self.invocation
        if (
            invocation is not None
            and invocation.kind == "call"
            and not invocation.connected_once
            and not getattr(self, "stop_reason", "")
        ):
            dial_timed_out = bool(
                invocation.dial_started_at
                and now - invocation.dial_started_at >= CALL_DIAL_TIMEOUT_SECONDS
            )
            setup_timed_out = now - invocation.started_at >= CALL_SETUP_TIMEOUT_SECONDS
            if dial_timed_out or setup_timed_out:
                self._publish_call_outcome("timeout")
                self._request_stop("call-timeout")
                self._persist()
        if self.invocation:
            try:
                pid, status_value = os.waitpid(self.invocation.pid, os.WNOHANG)
            except ChildProcessError:
                pid, status_value = self.invocation.pid, 0
            if pid:
                self._finish_invocation(status_value)
        if self.invocation is None and self.listener_retry_at and now >= self.listener_retry_at:
            if not self.status.get("online"):
                self.listener_failures = 0
                self.listener_retry_at = 0.0
            else:
                self.listener_retry_at = 0.0
                try:
                    self._start_invocation("listen")
                except OmaphoneError as exc:
                    self._schedule_listener_retry(str(exc))
                    self._persist()
        if (
            self.invocation is None
            and not self.status.get("online")
            and now - getattr(self, "last_client_at", now) >= OFFLINE_IDLE_SECONDS
        ):
            self.running = False

    def dispatch(self, request: Mapping[str, Any]) -> dict[str, Any]:
        command = request.get("command")
        if not isinstance(command, str):
            return self._error("invalid command")
        try:
            if command in {"status", "ping"}:
                return self._response()
            if command == "shutdown":
                # Used by a newer helper before replacing this daemon. The
                # lifecycle lock remains held until the child is fully reaped.
                self.running = False
                self._clear_relay_ready()
                return self._response()
            if command == "refresh":
                self._refresh_static()
                if (
                    desired_online(self.paths)
                    and self.invocation is None
                    and self.status["configured"]
                    and self.status["dependenciesReady"]
                ):
                    self._start_invocation("listen")
                return self._response()
            if command == "setup":
                if self.invocation:
                    raise OmaphoneError("go offline before setup")
                install_pinned_backend(self.paths)
                ensure_room_secret(self.paths)
                config = load_app_config(self.paths)
                save_app_config(self.paths, config)
                self.status["phase"] = "offline"
                self.status["lastError"] = ""
                if desired_online(self.paths) and not required_dependency_status(config["settings"]):
                    self._start_invocation("listen")
                return self._response()
            if command == "online":
                was_online = desired_online(self.paths)
                config = load_app_config(self.paths)
                config["preferredRole"] = "listener"
                try:
                    self._save_wrapper_config(config)
                    save_desired_online(self.paths, True)
                except OSError as exc:
                    if not was_online:
                        try:
                            save_desired_online(self.paths, False)
                        except OSError:
                            pass
                    self.status["phase"] = "error"
                    raise OmaphoneError(
                        "Could not save listening mode. This phone was left offline."
                    ) from exc
                self.listener_retry_at = 0.0
                if self.invocation is None:
                    try:
                        self._start_invocation("listen")
                    except OmaphoneError:
                        if not was_online:
                            try:
                                save_desired_online(self.paths, False)
                            except OSError:
                                pass
                        raise
                return self._response()
            if command == "offline":
                save_desired_online(self.paths, False)
                self.listener_failures = 0
                self.listener_retry_at = 0.0
                self.pending_invocation = None
                self._clear_relay_ready()
                if self.invocation:
                    self._request_stop("offline")
                else:
                    self.status["phase"] = "offline" if self.status["configured"] else "unconfigured"
                return self._response()
            if command == "call":
                supplied_address = request.get("address", "")
                if not isinstance(supplied_address, str):
                    raise OmaphoneError("invalid phone address")
                address = normalize_onion_address(supplied_address)
                self._reject_self_address(address)
                if self.invocation and self.invocation.kind != "listen":
                    raise OmaphoneError("another TerminalPhone action is already active")
                config = load_app_config(self.paths)
                config["peerAddress"] = address
                config["peerKind"] = "direct"
                config["preferredRole"] = "caller"
                try:
                    self._save_wrapper_config(config)
                except OSError as exc:
                    raise OmaphoneError("Could not save the other phone. No call was started.") from exc
                self._transition("call", address)
                return self._response()
            if command == "call-peer":
                if self.invocation and self.invocation.kind != "listen":
                    raise OmaphoneError("another TerminalPhone action is already active")
                config = load_app_config(self.paths)
                address = config["peerAddress"]
                if not address:
                    raise OmaphoneError("No other phone is paired yet.")
                self._reject_self_address(address)
                config["preferredRole"] = "caller"
                try:
                    self._save_wrapper_config(config)
                except OSError as exc:
                    raise OmaphoneError("Could not save calling mode. No call was started.") from exc
                self._transition("call", address)
                return self._response()
            if command == "ptt":
                action = request.get("action")
                if action == "start":
                    if not self.invocation or self.status["phase"] != "connected":
                        raise OmaphoneError("push-to-talk requires a connected call")
                    self.status["localTalking"] = True
                    now = time.monotonic()
                    self.ptt_next = now
                    self.ptt_deadline = now + PTT_WATCHDOG_SECONDS
                    self._tick()
                elif action == "stop":
                    self._clear_ptt(clear_remote=False)
                else:
                    raise OmaphoneError("ptt action must be start or stop")
                return self._response()
            if command == "send":
                text = request.get("text")
                if not isinstance(text, str) or not text or "\n" in text or "\r" in text:
                    raise OmaphoneError("message must be one non-empty line")
                if any(ord(char) < 0x20 or 0x7F <= ord(char) <= 0x9F for char in text):
                    raise OmaphoneError("message must not contain terminal control characters")
                # TerminalPhone renders chat with `echo -e`; doubling a slash
                # preserves literal backslashes without allowing escape input
                # to become a terminal control sequence for a raw CLI peer.
                wire_text = text.replace("\\", "\\\\")
                if len(wire_text.encode("utf-8")) > MAX_TEXT_BYTES:
                    raise OmaphoneError("message is too long")
                if not self.invocation or self.status["phase"] != "connected":
                    raise OmaphoneError("text messaging requires a connected call")
                if self.pending_text is not None:
                    raise OmaphoneError("another message is still being sent")
                self.pending_text = wire_text
                if not self._write_pty(b"T"):
                    self.pending_text = None
                    raise OmaphoneError("TerminalPhone input is unavailable")
                return self._response()
            if command == "hangup":
                if not self.invocation:
                    raise OmaphoneError("nothing is active")
                self._request_stop("hangup")
                return self._response()
            if command in {"audio-test", "relay"}:
                if self.invocation and self.invocation.kind != "listen":
                    raise OmaphoneError("another TerminalPhone action is already active")
                self._transition("test" if command == "audio-test" else "relay")
                return self._response()
            if command == "rotate":
                if request.get("confirm") is not True:
                    raise OmaphoneError("rotate requires --confirm")
                if self.invocation and self.invocation.kind != "listen":
                    raise OmaphoneError("another TerminalPhone action is already active")
                self._transition("rotate")
                return self._response()
            if command == "config":
                key = request.get("key")
                if not isinstance(key, str):
                    raise OmaphoneError("invalid config key")
                value = validate_config_value(key, request.get("value"))
                if key == "snowflake" and value and not snowflake_available():
                    raise OmaphoneError(
                        "Snowflake is not installed. Keep using normal Tor, or install "
                        f"{SNOWFLAKE_AUR_PACKAGE} from the AUR first."
                    )
                config = load_app_config(self.paths)
                config["settings"][key] = value
                restart = self._quiesce_listener()
                try:
                    save_app_config(self.paths, config)
                except OSError as exc:
                    # A multi-file configuration commit may be partial. Never
                    # restart TerminalPhone against a mixed generation.
                    try:
                        save_desired_online(self.paths, False)
                    except OSError:
                        pass
                    self.status["phase"] = "error"
                    raise OmaphoneError(
                        "could not save Omaphone settings; Omaphone was left offline"
                    ) from exc
                if restart:
                    try:
                        self._start_invocation("listen")
                    except OmaphoneError as exc:
                        self.status["phase"] = "error"
                        self.status["lastError"] = str(exc)
                else:
                    self.status["phase"] = "offline"
                    self.status["lastError"] = ""
                return self._response()
            if command == "pair":
                code = request.get("invite")
                if not isinstance(code, str):
                    raise OmaphoneError("invalid Omaphone invite")
                invite = parse_invite(code)
                if invite.address:
                    self._reject_self_address(invite.address)
                config = load_app_config(self.paths)
                previous_config = {
                    "settings": dict(config["settings"]),
                    "peerAddress": config["peerAddress"],
                    "peerKind": config.get(
                        "peerKind", "direct" if config["peerAddress"] else ""
                    ),
                    "preferredRole": config.get("preferredRole", ""),
                }
                config["peerAddress"] = invite.address
                config["peerKind"] = invite.kind if invite.address else ""
                config["settings"]["hmac"] = invite.hmac
                config["preferredRole"] = "caller"
                restart = self._quiesce_listener()
                # No live reader exists: commit room settings and secret before publishing status.
                try:
                    self._commit_invite_config(previous_config, config, invite.secret)
                except OSError as exc:
                    # Do not restart with a partially committed room identity.
                    try:
                        save_desired_online(self.paths, False)
                    except OSError:
                        pass
                    self.status["phase"] = "error"
                    raise OmaphoneError(
                        "could not save that Omaphone invite; Omaphone was left offline"
                    ) from exc
                self.status["remoteAddress"] = invite.address
                if restart:
                    try:
                        self._start_invocation("listen")
                    except OmaphoneError as exc:
                        self.status["phase"] = "error"
                        self.status["lastError"] = str(exc)
                else:
                    self.status["phase"] = "offline"
                    self.status["lastError"] = ""
                return self._response()
            if command == "join":
                code = request.get("invite")
                if not isinstance(code, str):
                    raise OmaphoneError("invalid Omaphone invite")
                invite = parse_invite(code)
                if not invite.address:
                    raise OmaphoneError(
                        "That invite has no phone address. Create a fresh invite on the other phone."
                    )
                self._reject_self_address(invite.address)
                if self.invocation and self.invocation.kind != "listen":
                    raise OmaphoneError("finish the active call or test before connecting")
                config = load_app_config(self.paths)
                previous_config = {
                    "settings": dict(config["settings"]),
                    "peerAddress": config["peerAddress"],
                    "peerKind": config.get(
                        "peerKind", "direct" if config["peerAddress"] else ""
                    ),
                    "preferredRole": config.get("preferredRole", ""),
                }
                config["peerAddress"] = invite.address
                config["peerKind"] = invite.kind
                config["settings"]["hmac"] = invite.hmac
                config["preferredRole"] = "caller"
                restart = self._quiesce_listener()
                try:
                    self._commit_invite_config(previous_config, config, invite.secret)
                except OSError as exc:
                    try:
                        save_desired_online(self.paths, False)
                    except OSError:
                        pass
                    self.status["phase"] = "error"
                    raise OmaphoneError(
                        "Could not save that invite. This phone was left offline."
                    ) from exc
                self.status["remoteAddress"] = invite.address
                try:
                    self._start_invocation("call", invite.address)
                except OmaphoneError:
                    if restart:
                        try:
                            self._start_invocation("listen")
                        except OmaphoneError:
                            pass
                    raise
                return self._response()
            if command == "clear-peer":
                config = load_app_config(self.paths)
                restart = self._quiesce_listener()
                config["peerAddress"] = ""
                config["peerKind"] = ""
                config["preferredRole"] = ""
                try:
                    save_app_config(self.paths, config)
                except OSError as exc:
                    try:
                        save_desired_online(self.paths, False)
                    except OSError:
                        pass
                    self.status["phase"] = "error"
                    raise OmaphoneError(
                        "Could not clear the paired phone. This phone was left offline."
                    ) from exc
                self.status["remoteAddress"] = ""
                if restart:
                    try:
                        self._start_invocation("listen")
                    except OmaphoneError as exc:
                        self.status["phase"] = "error"
                        self.status["lastError"] = str(exc)
                else:
                    self.status["phase"] = "offline" if self.status["configured"] else "unconfigured"
                    self.status["lastError"] = ""
                return self._response()
            if command == "clear-chat":
                self.status["messages"] = []
                return self._response()
            if command == "invite":
                if self.status.get("phase") == "relay":
                    invocation = self.invocation
                    if (
                        invocation is None
                        or invocation.kind != "relay"
                        or not invocation.relay_ready
                        or getattr(self, "stop_reason", "")
                        or not valid_secret(invocation.relay_secret)
                    ):
                        raise OmaphoneError("group host is not ready to share an invite")
                    secret = invocation.relay_secret
                    kind = "group"
                else:
                    secret = read_secret(self.paths)
                    kind = "direct"
                if not secret:
                    raise OmaphoneError("run setup before creating an invite")
                address = read_onion(self.paths)
                if kind == "group" and not address:
                    raise OmaphoneError("group host address is not ready to share")
                config = load_app_config(self.paths)
                code = create_invite(
                    secret,
                    address,
                    config["settings"]["hmac"],
                    kind,
                )
                return self._response(invite=code)
            return self._error(f"unknown command: {command}")
        except OmaphoneError as exc:
            return self._error(str(exc))

    def _serve_client(self, client: socket.socket) -> None:
        try:
            if hasattr(socket, "SO_PEERCRED"):
                credentials = client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
                peer_uid = int.from_bytes(credentials[4:8], sys.byteorder)
                if peer_uid != os.getuid():
                    return
            self.last_client_at = time.monotonic()
            client.settimeout(0.25)
            data = bytearray()
            while b"\n" not in data and len(data) <= MAX_REQUEST_BYTES:
                block = client.recv(4096)
                if not block:
                    break
                data.extend(block)
            if len(data) > MAX_REQUEST_BYTES or b"\n" not in data:
                response = self._error("invalid or oversized request")
            else:
                line, remainder = bytes(data).split(b"\n", 1)
                if remainder.strip():
                    response = self._error("only one command is allowed per connection")
                else:
                    try:
                        decoded = json.loads(line.decode("utf-8"))
                        if not isinstance(decoded, dict):
                            raise ValueError
                        response = self.dispatch(decoded)
                    except (UnicodeError, json.JSONDecodeError, ValueError):
                        response = self._error("invalid request JSON")
            client.sendall((json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"))
        except OSError:
            pass
        finally:
            client.close()

    def run(self) -> int:
        lock_flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
        if hasattr(os, "O_NOFOLLOW"):
            lock_flags |= os.O_NOFOLLOW
        lock_fd = os.open(self.paths.lock_file, lock_flags, 0o600)
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid():
            os.close(lock_fd)
            raise OmaphoneError("unsafe Omaphone lifecycle lock")
        os.fchmod(lock_fd, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(lock_fd)
            return 0
        try:
            try:
                self.paths.socket_file.unlink()
            except FileNotFoundError:
                pass
            self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.server.bind(str(self.paths.socket_file))
            os.chmod(self.paths.socket_file, 0o600)
            self.server.listen(16)
            self.server.setblocking(False)
            self.selector.register(self.server, selectors.EVENT_READ, "server")
            signal.signal(signal.SIGTERM, lambda *_: setattr(self, "running", False))
            signal.signal(signal.SIGINT, lambda *_: setattr(self, "running", False))
            if desired_online(self.paths) and self.status["configured"] and self.status["dependenciesReady"]:
                try:
                    self._start_invocation("listen")
                except OmaphoneError as exc:
                    self.status["phase"] = "error"
                    self.status["lastError"] = str(exc)
                    self._persist()
            while self.running:
                for key, event_mask in self.selector.select(0.05):
                    if key.data == "server" and self.server:
                        try:
                            client, _ = self.server.accept()
                            self._serve_client(client)
                        except BlockingIOError:
                            pass
                    elif key.data == "pty":
                        if event_mask & selectors.EVENT_READ:
                            self._read_pty()
                        if event_mask & selectors.EVENT_WRITE:
                            self._flush_pty_writes()
                self._tick()
        finally:
            self._clear_ptt()
            self._shutdown_invocation()
            if self.server:
                try:
                    self.selector.unregister(self.server)
                except Exception:
                    pass
                self.server.close()
            try:
                self.paths.socket_file.unlink()
            except FileNotFoundError:
                pass
            os.close(lock_fd)
        return 0


def socket_request(paths: Paths, request: Mapping[str, Any], timeout: float = 30.0) -> dict[str, Any]:
    payload = (json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(payload) > MAX_REQUEST_BYTES:
        raise OmaphoneError("request is too large")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(timeout)
    try:
        client.connect(str(paths.socket_file))
        client.sendall(payload)
        response = bytearray()
        while b"\n" not in response and len(response) <= 512 * 1024:
            block = client.recv(65_536)
            if not block:
                break
            response.extend(block)
    except OSError as exc:
        raise OmaphoneError("Omaphone daemon is unavailable") from exc
    finally:
        client.close()
    if b"\n" not in response or len(response) > 512 * 1024:
        raise OmaphoneError("invalid daemon response")
    try:
        decoded = json.loads(bytes(response).split(b"\n", 1)[0].decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise OmaphoneError("invalid daemon response") from exc
    if not isinstance(decoded, dict):
        raise OmaphoneError("invalid daemon response")
    return decoded


def wait_for_daemon_exit(paths: Paths, timeout: float = 8.0) -> None:
    """Wait until the lifecycle lock proves the previous daemon is gone."""
    deadline = time.monotonic() + timeout
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    while time.monotonic() < deadline:
        try:
            descriptor = os.open(paths.lock_file, flags, 0o600)
        except OSError as exc:
            raise OmaphoneError("unsafe Omaphone lifecycle lock") from exc
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                return
        finally:
            os.close(descriptor)
        time.sleep(0.05)
    raise OmaphoneError("the previous Omaphone daemon did not stop safely")


def ensure_daemon(paths: Paths) -> None:
    ensure_layout(paths)
    response: dict[str, Any] | None = None
    try:
        response = socket_request(paths, {"command": "ping"}, timeout=0.2)
    except OmaphoneError:
        pass
    if response and response.get("ok"):
        status = response.get("status")
        if isinstance(status, dict) and status.get("backendVersion") == BACKEND_VERSION:
            return
        try:
            stopped = socket_request(paths, {"command": "shutdown"}, timeout=1.0)
        except OmaphoneError as exc:
            raise OmaphoneError("an incompatible Omaphone daemon is still running") from exc
        if not stopped.get("ok"):
            raise OmaphoneError("an incompatible Omaphone daemon is still running")
        wait_for_daemon_exit(paths)
    try:
        if paths.log_file.stat().st_size > MAX_LOG_BYTES:
            atomic_write(paths.log_file, paths.log_file.read_bytes()[-MAX_LOG_BYTES // 2 :])
    except (FileNotFoundError, OSError):
        pass
    descriptor = os.open(paths.log_file, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    os.chmod(paths.log_file, 0o600)
    with os.fdopen(descriptor, "ab", closefd=True) as log_handle:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "daemon"],
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=log_handle,
            start_new_session=True,
            close_fds=True,
            env=dict(os.environ),
        )
    deadline = time.monotonic() + 5.0
    while time.monotonic() < deadline:
        try:
            response = socket_request(paths, {"command": "ping"}, timeout=0.2)
            if response.get("ok"):
                return
        except OmaphoneError:
            time.sleep(0.05)
    raise OmaphoneError("Omaphone daemon did not start")


def read_one_stdin_line(stream: Any, limit: int, label: str) -> str:
    raw = stream.readline(limit + 2)
    if isinstance(raw, str):
        raw = raw.encode("utf-8")
    if not raw.endswith(b"\n"):
        raise OmaphoneError(f"{label} must be one newline-terminated line")
    if len(raw) - 1 > limit:
        raise OmaphoneError(f"{label} is too long")
    raw = raw[:-1]
    if b"\r" in raw or b"\n" in raw:
        raise OmaphoneError(f"{label} must not contain embedded newlines")
    try:
        descriptor = stream.fileno()
        original_flags = fcntl.fcntl(descriptor, fcntl.F_GETFL)
        try:
            # readline may have prefetched line two into BufferedReader even when
            # the underlying fd is no longer readable. Nonblocking peek catches it
            # without waiting for a Quickshell writer to close stdin.
            fcntl.fcntl(descriptor, fcntl.F_SETFL, original_flags | os.O_NONBLOCK)
            peek = getattr(stream, "peek", None)
            if callable(peek) and peek(1):
                raise OmaphoneError(f"{label} must contain exactly one line")
            ready, _, _ = select.select([descriptor], [], [], 0)
            if ready and os.read(descriptor, 1):
                raise OmaphoneError(f"{label} must contain exactly one line")
        finally:
            fcntl.fcntl(descriptor, fcntl.F_SETFL, original_flags)
    except (AttributeError, OSError, ValueError):
        pass
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise OmaphoneError(f"{label} must be valid UTF-8") from exc


def build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="omaphone")
    commands = parser.add_subparsers(dest="command", required=True)
    for name in (
        "status", "setup", "install-deps", "online", "offline", "send", "pair",
        "join", "call-peer", "clear-peer", "invite", "audio-test", "hangup",
        "relay", "clear-chat", "shutdown",
    ):
        commands.add_parser(name)
    call_parser = commands.add_parser("call")
    call_parser.add_argument("address")
    ptt_parser = commands.add_parser("ptt")
    ptt_parser.add_argument("action", choices=("start", "stop"))
    config_parser = commands.add_parser("config")
    config_parser.add_argument("key", choices=tuple(DEFAULT_SETTINGS))
    config_parser.add_argument("value")
    rotate_parser = commands.add_parser("rotate")
    rotate_parser.add_argument("--confirm", action="store_true")
    commands.add_parser("daemon", help=argparse.SUPPRESS)
    return parser


def cli_request(arguments: argparse.Namespace) -> dict[str, Any]:
    command = arguments.command
    request: dict[str, Any] = {"command": command}
    if command == "call":
        request["address"] = normalize_onion_address(arguments.address)
    elif command == "ptt":
        request["action"] = arguments.action
    elif command == "config":
        request.update(key=arguments.key, value=validate_config_value(arguments.key, arguments.value))
    elif command == "rotate":
        if not arguments.confirm:
            raise OmaphoneError("rotate requires --confirm")
        request["confirm"] = True
    elif command == "send":
        text = read_one_stdin_line(sys.stdin.buffer, MAX_TEXT_BYTES, "message")
        if not text:
            raise OmaphoneError("message must not be empty")
        request["text"] = text
    elif command in {"pair", "join"}:
        request["invite"] = read_one_stdin_line(sys.stdin.buffer, MAX_INVITE_BYTES, "invite")
    return request


def main(argv: list[str] | None = None) -> int:
    os.umask(0o077)
    parser = build_argument_parser()
    arguments = parser.parse_args(argv)
    paths = Paths.from_environment()
    if arguments.command == "daemon":
        return Supervisor(paths).run()
    try:
        request = cli_request(arguments)
        if arguments.command == "install-deps":
            install_dependencies(load_app_config(paths)["settings"])
            request = {"command": "refresh"}
        ensure_daemon(paths)
        response = socket_request(paths, request)
        if not response.get("ok"):
            raise OmaphoneError(str(response.get("error") or "command failed"))
        if arguments.command == "invite":
            invite = response.get("invite")
            if not isinstance(invite, str) or not invite.startswith(INVITE_PREFIX):
                raise OmaphoneError("daemon returned an invalid invite")
            print(invite)
        else:
            print(json.dumps(response["status"], ensure_ascii=False, separators=(",", ":")))
        return 0
    except OmaphoneError as exc:
        print(f"omaphone: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
