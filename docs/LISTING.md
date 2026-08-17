# Omaphone listing copy

Ready-to-paste copy for the Omarchy plugin site, GitHub, and launch posts.

## Marketplace fields

| Field | Value |
| --- | --- |
| Name | Omaphone |
| Category | Widgets |
| Short description | A private walkie-talkie in your Omarchy bar. Hold to record, release to send, and let Tor carry it. |
| Repository | <https://github.com/tomdavenport/omaphone> |
| License | MIT |
| Tags | `bar`, `media`, `quickshell` |
| Suggested GitHub topics | `omarchy`, `quickshell`, `push-to-talk`, `tor`, `voice`, `privacy` |

## Long description

Omaphone puts a private walkie-talkie in the Omarchy 4 bar. On one computer,
choose **Share my phone**. On the other, choose **Add a phone**, paste its
private contact card, and choose **Add & connect**. Hold one big button to
record; release to encrypt and send. Text chat, audio testing, voice effects,
and call-quality controls are there when you want them without turning the
experience into a terminal configuration project.

Under the friendly panel is TerminalPhone: a terminal-native voice and chat
tool carried through Tor onion services. Omaphone keeps that pinned upstream
implementation in charge of the network, audio, encryption, and protocol while
it handles setup, process supervision, safe local state, and the polished
Quickshell interface.

Direct calls are the everyday experience. An experimental room mode can also
turn one local machine into a multi-caller relay—no public server, public IP,
or port forwarding required. The machine must stay online, the host instance
cannot join its own room, and participants join through **Advanced → Join a
room** with the host's private room invite. Everyone should take turns: this
is record-then-send push-to-talk, not live audio mixing.

## Feature bullets

- Private direct calls through Tor onion services.
- Hold to record; release to send.
- Encrypted voice messages and in-call text chat.
- A two-action first call: share and wait on one computer; add and connect on
  the other.
- Clear Tor progress, connected, speaking, and waiting states.
- Experimental small-group rooms hosted from a local machine.
- Audio test, quality presets, voice effects, and chimes.
- Optional Snowflake help for networks that block Tor, plus message
  verification controls.
- Native Omarchy theming, keyboard access, and bar integration.
- A checksum-verified TerminalPhone backend pinned to an exact revision.

## Install

Review the repository, then run:

```bash
omarchy plugin add https://github.com/tomdavenport/omaphone.git --enable --yes
```

Open the phone in the bar and choose **Set up Omaphone**. If prompted, choose
**Install missing tools**. The guided first-call buttons handle the listener
and Tor route; the first connection can take a minute or two.

Remove it cleanly with:

```bash
omarchy-shell omaphone.phone offline
omarchy plugin remove omaphone.phone
```

Removing the plugin does not delete the user's private address, room key,
settings, or local message history.

## Launch snippets

### One line

Omaphone is a private push-to-talk phone in your Omarchy bar: hold to record,
release to send, and let Tor carry it.

### Short post

Meet Omaphone: a little private walkie-talkie that lives in the Omarchy 4 bar.
Share one phone's private contact card; add and connect from the other. Then
hold the big button to record and release to send through Tor. It also has
encrypted text chat, voice effects, and an experimental room host for small
groups. TerminalPhone does the serious work; Omaphone makes it feel simple and
fun.

### GitHub release intro

Omaphone turns TerminalPhone into a native Omarchy 4 widget. The first release
wraps private Tor calls, record-then-send push-to-talk, encrypted chat, private
contact cards, audio setup, and an experimental multi-caller relay in one
compact bar panel.
There is no terminal session to babysit and no public server to configure.

### Plugin-site call to action

Put a phone in your bar. Share its private contact card, connect, and hold to
talk.

## Artwork notes

Primary plugin-listing and README image: [preview.png](../preview.png).
The ready-to-upload GitHub social card is
[`assets/omaphone-social.png`](../assets/omaphone-social.png).

The image should be a real screenshot from a clean, disposable Omarchy 4 VM,
lightly composed for each destination. It should look like a carefully riced
Omarchy desktop while keeping the Omaphone widget legible at thumbnail size.
Never capture or publish a real contact card, room invite, room key, onion
address, username, notification, network name, or other personal data.

Use these four plain-English feature bullets in the image:

- PRIVATE CALLS OVER TOR
- HOLD, TALK, RELEASE
- ENCRYPTED TEXT CHAT
- HOST A SMALL GROUP, with an **EXPERIMENTAL** label

Keep the words as a clean editorial overlay outside the live UI. Do not make
the screenshot look as if those bullets are controls inside Omaphone. If a
square mark is required later, export it from the approved screenshot
treatment so the listing uses one visual system; do not fall back to a
separate concept illustration.

Recommended exports:

- GitHub social preview: `1280 × 640` PNG.
- Plugin listing and README hero: `1600 × 900` PNG.

## Required disclosures

- Omaphone and TerminalPhone have not been independently security audited.
- Voice is recorded while the button is held and sent on release; it is not a
  continuous live-audio call.
- TerminalPhone has no telephone-style ringing or answer phase. One computer
  waits while the other connects; sounds are connection or push-to-talk
  feedback, not a ringtone.
- Private contact cards and room invites contain a shared room key and must be
  shared through a trusted, private channel.
- Omaphone 1.2 has one stable device onion address, TerminalPhone's one global
  direct-call secret, and one saved paired phone. It does not create a unique
  number or isolated key for each named person. Adding another private contact
  card—or using a room invite—replaces that pairing and active key.
- The experimental group host forwards opaque traffic and does not join the
  conversation. It exposes connection count, timing, and traffic-volume
  metadata to the host and is not a moderation or admission-control service.
- The pinned upstream listener may accept connections on non-loopback network
  interfaces. Hosts should firewall the listen port from LAN/WAN access.
- Omarchy plugins run as the logged-in user and are not sandboxed. Users should
  review the source before installing.
- Optional Snowflake support requires the user to review and install the
  `snowflake-pt-client-bin` AUR package; normal Tor calls do not need it.
