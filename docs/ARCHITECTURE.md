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
ANSI cursor updates. It keeps critical process state in memory and records
helper-process IDs and pipes inside its profile. A second copy using that same
profile could race with those files or clean up helpers owned by the active
call. Omaphone therefore never starts a second copy merely to ask for status.

The supervisor therefore runs exactly one upstream process in a real
pseudo-terminal. It translates explicit UI actions into TerminalPhone's
existing controls and derives presentation state from sanitized output. It
never sources the script and never duplicates the transport or cryptography.
The exact pinned source revision and checksum are constants, so an upstream
UI change cannot silently change the parser contract.

## State and permissions

The supervisor socket and lifecycle lock use `XDG_RUNTIME_DIR`, falling back to
the user's `/run/user/<uid>` directory and finally a UID-namespaced temporary
directory. Durable backend, onion identity, and room configuration use XDG
data. A hosted room's separate secret lives only in the supervisor invocation.
Derived status and bounded message history use XDG state. The app configuration
also stores one validated paired address, whether it is a direct phone or a
group room, and a preferred caller/listener role. The room/direct marker is an
authenticated optional field in Omaphone's version-1 invite. Older invites
without it safely remain direct contacts, and older Omaphone clients ignore it.
TerminalPhone keeps one stable onion identity and one global shared secret in
its private profile; Omaphone 1.2 does not create a separate number or key per
person. Every Omaphone directory is checked for user ownership and set to mode
`0700`; the socket, current call secret, lock, and other private files use mode
`0600`.

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
- Adding a phone validates the complete private contact card, requires its
  address, and rejects this computer's own address before stopping a listener
  or changing the saved profile. Only then does it commit the new peer, room
  settings, role, and secret and start the outgoing call.
- An outgoing call has two separate guards: the 60-second peer wait starts only
  once TerminalPhone actually begins dialing, while a 360-second overall guard
  also bounds Tor bootstrap and every earlier stage.
- A failed or timed-out call records one bounded, user-facing outcome. That
  outcome survives the automatic return to listening so the panel can show it;
  a deliberate hangup is not reported as a connection failure.
- Push-to-talk is a renewable eight-second lease. If the shell or UI dies
  during recording, the supervisor stops transmission when the lease expires.
- If the bundled upstream fails its pinned checksum, Omaphone refuses to copy
  or execute it.
- If the supervisor is gone but its socket path remains, replacement code must
  first acquire the lifecycle lock. It then removes only Omaphone's socket path
  inside the already checked, user-owned runtime directory.
- An offline supervisor with no shell clients retires after one minute, so a
  disabled or removed plugin does not leave an idle detached process behind.

## Compatibility boundary

The pin currently targets GitHub commit
`67c8167dae167276b1ba69ac66b79b3abedceef8`. Although GitHub and GitLab both
advertise TerminalPhone 1.1.7, their scripts differ. Omaphone deliberately uses
the pinned GitHub source, which includes the later PipeWire/PulseAudio path,
and does not follow the GitLab URL embedded in upstream installation examples.

TerminalPhone does not expose a telephone ringing/answer state. Its listener
waits for a connection and the caller dials it; connection and chime output are
feedback, not evidence that a remote person is seeing an Answer prompt.

The same compatibility boundary prevents a secure multi-contact address book:
the pinned listener accepts one global shared secret. A future one-device-number
experience with named contacts needs invisible per-contact keys and protocol
support to select them. Merely storing several names beside the legacy global
key would not isolate those relationships; separate TerminalPhone identities
remain a possible advanced privacy mode, not the everyday contact model.
