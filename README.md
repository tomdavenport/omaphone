# Omaphone

![Omaphone on a riced Omarchy 4 desktop](preview.png)

**A private walkie-talkie in your Omarchy bar. Hold to record. Release to
send. Tor carries it.**

Omaphone turns
[TerminalPhone](https://github.com/edengilbertus/terminalphone) into a small,
native Omarchy 4 widget. Open it from the bar, call a friend, hold the big talk
button, and let go when you are done. You can also send text messages or host
an experimental group room.

It feels like a call, but the audio is intentionally not live. Omaphone records
one short voice message while you hold the button, then encrypts and sends it
when you release. That simple rhythm works well over Tor and makes taking turns
feel natural.

## What you get

- Private, direct voice calls carried through Tor onion services.
- One big hold-to-record button, with clear local and remote activity.
- Encrypted text chat alongside every call.
- Simple invites: copy yours, or paste one from someone you trust.
- An experimental group-room host for small push-to-talk conversations.
- First-run setup, audio testing, call quality, voice effects, and chimes.
- Optional connection and authentication controls tucked into **Advanced**.
- A theme-aware Omarchy panel with keyboard navigation and no terminal window
  to manage.

Underneath the friendly panel, Omaphone runs one pinned copy of TerminalPhone.
TerminalPhone still owns the Tor connection, audio, encryption, and wire
protocol; Omaphone handles setup, lifecycle, safe state, and the desktop
experience. See [Architecture](docs/ARCHITECTURE.md) for the full design.

## Install

From a committed checkout of this repository:

```bash
omarchy plugin validate .
omarchy plugin add "$PWD" --enable --yes
```

Or install the published repository directly:

```bash
omarchy plugin add https://github.com/tomdavenport/omaphone.git --enable --yes
```

Omarchy clones the plugin into
`~/.config/omarchy/plugins/omaphone.phone` and adds the phone to the right side
of the bar.

Open the phone and choose **Set up Omaphone**. If it says a few tools are
missing, choose **Install missing tools**, then go online. Tor may take a minute
or two to connect for the first time. Your private address appears when it is
ready.

Update an installed copy with:

```bash
omarchy-shell omaphone.phone offline
omarchy plugin update omaphone.phone
```

Omarchy validates the update and reloads the plugin automatically. Very early
local-checkout installs made before the public repository may not share its
Git history. If Omarchy refuses that one update even though the checkout is
clean, remove it with the command below and run the published install command
again; Omaphone's private state is kept.

To remove Omaphone cleanly:

```bash
omarchy-shell omaphone.phone offline
omarchy plugin remove omaphone.phone
```

Going offline first stops the background listener. Removing the plugin leaves
your private address, room key, settings, and local messages in your standard
per-user data folders, so reinstalling does not unexpectedly give you a new
identity.

## Make a private call

1. Choose **Go online** so Omaphone can receive calls.
2. Choose **Copy invite** and send it through a private channel you already
   trust, or paste an invite that a friend sent you.
3. Choose **Call**.
4. Hold the talk button to record. Release it to send. Type below it when text
   is easier.
5. Choose **Hang up** when you are finished. If you are online, Omaphone goes
   back to listening.

An invite is a key to the conversation. Anyone who gets it can call you
and decrypt compatible traffic, so treat it like a password: do not post it in
public, and remove it from clipboard history when that matters. You can delete
the small local text history from **Advanced**.

Omaphone currently remembers one call key at a time. Using a different invite
replaces that key, so calls using an earlier invite may stop working. A proper
multi-contact design is the next step, not something the current panel quietly
pretends to provide.

## Host a group room (experimental)

TerminalPhone includes an experimental multi-caller relay, and Omaphone makes
it available as **Host a group on this computer**. The host can be an ordinary
local machine. You do not need a public server, a public IP address, or router
port forwarding: Tor publishes the room as an onion service.

The trade-off is that the host machine must stay awake, online, and running the
room. That Omaphone instance becomes a relay only; it cannot talk or chat in
the room. Join from another machine if the host also wants to take part.

Each time you host, Omaphone makes a fresh room key in memory. It does not
replace or share the host's regular call key, and Omaphone does not save it to
disk. Participants save the room key as their current call key when they use
the invite, so they should still treat it like a password. A clipboard manager
may retain a copied room invite after the room stops.

To join a room:

1. Choose **Use an invite** and paste the invite from the host.
2. Choose **Go online**.
3. Choose **Call**. There is no separate join mode: the relay identifies the
   connection as a group call.

To host a room:

1. Under **Small group · Experimental**, choose **Host a group on this
   computer** and confirm.
2. Wait for **Room is ready**, then choose **Copy room invite**.
3. Send that same invite to every participant through a trusted private
   channel.
4. Keep the host awake. Everyone else follows the three joining steps above.

Take turns speaking. This is push-to-talk forwarding, not a live audio mix.

Keep rooms small and have one person speak at a time. The upstream design can
accept multiple callers, but Omaphone labels the feature experimental because
it does not set a tested capacity or provide moderation, admission controls,
or speaking queues.

There is one important hosting caveat in the currently pinned TerminalPhone:
its `socat` listener does not explicitly bind to loopback, so the listening
port may also be reachable on the host's LAN interfaces. No router forwarding
is needed, but the host should use a firewall to block non-loopback access to
that port. The default is TCP `7777`. Read the room's metadata and trust limits
in [Security](docs/SECURITY.md#group-room-hosting) before inviting people.

## Requirements

- Omarchy 4.x with the `omarchy-shell`/Quickshell bar.
- Python 3, used only by Omaphone's local supervisor.
- TerminalPhone's Arch packages: `tor`, `opus-tools`, `sox`, `socat`,
  `openssl`, `alsa-utils`, and `libpulse`.
- The AUR package `snowflake-pt-client` only if you turn on the optional
  Snowflake connection method.

**Install missing tools** uses PolicyKit for package-manager approval. It
does not store or bypass an administrator password. Omaphone does not silently
build the optional Snowflake package as root; review and install that package
separately with:

```bash
omarchy pkg aur add snowflake-pt-client
```

## Privacy, in plain English

Omaphone hides networking and cryptography controls; it does not make their
trade-offs disappear. Your current call key is kept in a user-only file so
Omaphone can listen in the background without asking for a passphrase after
every restart. A hosted room uses a separate, short-lived key in the host
process; participants save it when they use the room invite. Recent text
messages are also local plaintext with user-only permissions. Disk encryption
and a locked session still matter.

TerminalPhone has not been independently audited as part of this project.
Omaphone preserves its implementation instead of inventing a second
cryptographic protocol. Read [Security](docs/SECURITY.md) before relying on it
for a high-risk conversation.

Omaphone does not ship an address book yet. The privacy-safe design we plan to
use is documented in [Contacts roadmap](docs/CONTACTS.md).

The larger product direction—People, Private Drops, video Postcards, a
self-hosted answering machine, and the honest boundary around live video—is in
the [communications roadmap](docs/ROADMAP.md).

## Command-line controls

The widget exposes the Omarchy Shell target `omaphone.phone`:

```bash
omarchy-shell omaphone.phone open
omarchy-shell omaphone.phone status
omarchy-shell omaphone.phone online
omarchy-shell omaphone.phone offline
omarchy-shell omaphone.phone hangup
```

## Development

The Omaphone supervisor has no third-party Python dependencies. Run the
non-desktop checks with:

```bash
python3 -m unittest discover -s tests -v
python3 -m py_compile scripts/*.py
omarchy plugin validate .
```

These checks do not need Tor, a microphone, root access, a compositor, or
control of the host desktop.

Omaphone is MIT licensed. TerminalPhone's separate license, pinned revision,
and checksum are recorded in
[Third-party notices](THIRD_PARTY_NOTICES.md).
