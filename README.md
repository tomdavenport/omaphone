# Omaphone

Omaphone turns [TerminalPhone](https://github.com/edengilbertus/terminalphone)
into a small, native Omarchy 4 phone widget. The normal surface is deliberately
simple: go online, share or paste an invite, call, hold to talk, send a message,
and hang up. Tor, the onion service, audio conversion, encryption commands,
process supervision, and TerminalPhone's terminal controls stay behind the
panel.

It is a push-to-talk phone, not a conventional live audio call. A voice note is
recorded while the talk control is held and sent when it is released—the model
TerminalPhone uses to tolerate Tor latency.

## What the widget includes

- One-click first-time setup with a bundled, checksum-verified TerminalPhone
  backend pinned to an exact revision.
- Online/listening, outgoing calls, incoming calls, hangup, and automatic
  return to listening.
- A large hold-to-talk control with local and remote speaking state.
- Encrypted in-call text messages and a compact conversation history.
- Opaque invite codes that carry the onion address and room configuration.
- Audio test, quality, voice effect, chime, Snowflake, HMAC, relay, and onion
  identity rotation controls behind an advanced section.
- A theme-aware Omarchy panel, keyboard navigation, IPC actions, and state
  polling without launching a visible terminal.

## Requirements

- Omarchy 4.x and its `omarchy-shell`/Quickshell bar.
- Python 3 (used only for the local supervisor).
- TerminalPhone's Arch packages: `tor`, `opus-tools`, `sox`, `socat`,
  `openssl`, `alsa-utils`, and `libpulse`.
- The AUR package `snowflake-pt-client` when the optional Snowflake transport
  is enabled.

The widget's **Install requirements** action uses PolicyKit to ask for the
package-manager authorization that a shell plugin cannot safely request in its
background process. It never embeds or bypasses an administrator password.
The optional Snowflake client is not in Arch's official repositories, so
Omaphone does not silently build it as root. Install and review it separately
with `omarchy pkg aur add snowflake-pt-client` before enabling Snowflake.

## Install locally

From a committed checkout of this repository:

```bash
omarchy plugin validate .
omarchy plugin add "$PWD" --enable --yes
```

Omarchy clones the repository into `~/.config/omarchy/plugins/omaphone.phone`
and places the widget on the right side of the bar. For a published copy,
replace `"$PWD"` with its trusted Git URL.

Open the phone icon and choose **Set up Omaphone**. If dependencies are
missing, choose **Install requirements**, then go online. The first Tor
bootstrap may take a minute or two; the onion identity becomes available when
it finishes.

To remove it:

```bash
omarchy-shell omaphone.phone offline
omarchy plugin remove omaphone.phone
```

Go offline before disabling or removing the plugin so its background listener
is shut down cleanly. Removing the plugin does not silently delete its onion
keys, room secret, or message state. Omaphone keeps those under the standard
per-user XDG data/state directories so an update or reinstall cannot rotate
identity by accident.

## Use

1. Choose **Go online** so Omaphone can receive calls.
2. Copy **My invite** and send it over a channel you already trust, or paste an
   invite you received.
3. Choose **Call**. When connected, hold the talk control and release it to
   send; text chat is available beneath it.
4. Choose **Hang up** when finished. Omaphone returns to listening when online.

An invite is effectively a room key: anyone who obtains it can call and
decrypt traffic for that room. Treat it like a password, do not publish it,
and clear it from clipboard history after sharing when that matters to your
threat model. The bounded local conversation history can be deleted with
**Advanced → Clear local chat history**.

## IPC

The widget exposes the standard Omarchy Shell target `omaphone.phone`:

```bash
omarchy-shell omaphone.phone open
omarchy-shell omaphone.phone status
omarchy-shell omaphone.phone online
omarchy-shell omaphone.phone offline
omarchy-shell omaphone.phone hangup
```

## Security notes

Omaphone intentionally leaves TerminalPhone's network, Tor, audio, and crypto
implementation untouched. It drives the pinned interactive program through an
isolated pseudo-terminal and verifies the bundled source before copying or
executing it.
That preserves wire compatibility and avoids creating a second crypto
implementation.

This does not make TerminalPhone independently audited. It uses a pre-shared
room secret and exposes several expert security/performance switches whose
trade-offs still apply. Omaphone stores the room secret in a user-only file
(`0600`) because unattended listening cannot stop for a passphrase prompt.
Its bounded chat history is also local plaintext state with user-only
permissions. Disk encryption and a locked user session remain part of the
local security boundary. See [docs/SECURITY.md](docs/SECURITY.md) before using
it for a high-risk situation.

## Development

The backend has no third-party Python dependencies. Run the non-desktop test
suite and plugin validator with:

```bash
python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/*.py
omarchy plugin validate .
```

No test needs Tor, a microphone, root, a compositor, or control of the host
desktop.

The implementation is MIT licensed. TerminalPhone's separate attribution and
pinned revision are recorded in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
