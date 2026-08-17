# Architecture

Omaphone is split at the point where TerminalPhone is strongest: the upstream
process owns the wire protocol, Tor, encryption, audio capture/playback, and
call cleanup. Omaphone owns lifecycle, state, and the Omarchy-native UI.

```mermaid
flowchart LR
  UI["Omarchy bar panel<br/>Panel.qml"] -->|"short JSON commands"| CLI["Omaphone CLI"]
  CLI -->|"Unix socket"| D["Per-user supervisor"]
  D -->|"PTY keystrokes"| TP["Pinned TerminalPhone"]
  TP -->|"Tor hidden service"| Peer["TerminalPhone / Omaphone peer"]
  TP -->|"ANSI output"| D
  D -->|"atomic status.json"| CLI
  CLI -->|"status JSON"| UI
```

## Why a PTY supervisor

TerminalPhone 1.1.7 is a single interactive Bash program, not a library or
daemon. Its in-call loop uses `stty`, one-byte reads, key-repeat timing, and
ANSI cursor updates. It also keeps critical process state in memory, deletes
stale run files at startup, and cleans up stored child PIDs on exit. Starting a
second copy merely to ask for status can disrupt a live call.

The supervisor therefore runs exactly one upstream process in a real
pseudo-terminal. It translates explicit UI actions into TerminalPhone's
existing controls and derives presentation state from sanitized output. It
never sources the script and never duplicates the transport or cryptography.
The exact pinned source revision and checksum are constants, so an upstream
UI change cannot silently change the parser contract.

## State and permissions

Runtime socket/lock files use the per-user runtime directory when available.
Durable backend, onion identity, and room configuration use XDG data. Derived
status and bounded message history use XDG state. Directories are mode `0700`;
the room secret and other sensitive files are mode `0600`.

The UI never invokes TerminalPhone's `status` command. It reads only the
supervisor's atomic JSON snapshot.

## Failure model

- If the panel closes, the supervisor and active listener/call continue.
- If `omarchy-shell` reloads, the new panel reads the existing snapshot and
  reconnects to the same supervisor.
- A helper update compares backend versions, asks the old supervisor to stop,
  and waits for its lifecycle lock before starting replacement code.
- A normally completed call, test, or relay returns to listening when the user
  remains online. An unexpected listener failure is surfaced and retried with
  bounded exponential backoff instead of a rapid restart loop.
- Push-to-talk is a renewable eight-second lease. If the shell or UI dies
  during recording, the supervisor stops transmission when the lease expires.
- If the bundled upstream fails its pinned checksum, Omaphone refuses to copy
  or execute it.
- If the supervisor is gone but a stale socket remains, the replacement first
  acquires the lifecycle lock and then removes only that runtime socket.
- An offline supervisor with no shell clients retires after one minute, so a
  disabled or removed plugin does not leave an idle detached process behind.

## Compatibility boundary

The pin currently targets GitHub commit
`67c8167dae167276b1ba69ac66b79b3abedceef8`. Although GitHub and GitLab both
advertise TerminalPhone 1.1.7, their scripts differ. Omaphone deliberately uses
the pinned GitHub source, which includes the later PipeWire/PulseAudio path,
and does not follow the GitLab URL embedded in upstream installation examples.
