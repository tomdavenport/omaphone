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

Omaphone puts a private walkie-talkie in the Omarchy 4 bar. Open the widget,
pair a friend's invite, and press one big button to talk. Hold to record;
release to encrypt and send. Text chat, incoming calls, audio testing, voice
effects, and call-quality controls are there when you want them without turning
the experience into a terminal configuration project.

Under the friendly panel is TerminalPhone: a terminal-native voice and chat
tool carried through Tor onion services. Omaphone keeps that pinned upstream
implementation in charge of the network, audio, encryption, and protocol while
it handles setup, process supervision, safe local state, and the polished
Quickshell interface.

Direct calls are the everyday experience. An experimental room mode can also
turn one local machine into a multi-caller relay—no public server, public IP,
or port forwarding required. The machine must stay online, the host instance
cannot join its own room, and participants should take turns: this is
record-then-send push-to-talk, not live audio mixing.

## Feature bullets

- Private direct calls through Tor onion services.
- Hold to record; release to send.
- Encrypted voice messages and in-call text chat.
- Copy-and-paste invites instead of manual network setup.
- Clear incoming-call, connected, speaking, and listening states.
- Experimental small-group rooms hosted from a local machine.
- Audio test, quality presets, voice effects, and chimes.
- Optional Snowflake and message-authentication controls.
- Native Omarchy theming, keyboard access, and bar integration.
- A checksum-verified TerminalPhone backend pinned to an exact revision.

## Install

Review the repository, then run:

```bash
omarchy plugin add https://github.com/tomdavenport/omaphone.git --enable --yes
```

Open the phone in the bar and choose **Set up Omaphone**. If prompted, choose
**Install missing tools**, then go online. The first Tor connection can
take a minute or two.

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
Pair an invite, hold the big button to record, and release to send through Tor.
It also has encrypted text chat, incoming calls, voice effects, and an
experimental room host for small groups. TerminalPhone does the serious work;
Omaphone makes it feel simple and fun.

### GitHub release intro

Omaphone turns TerminalPhone into a native Omarchy 4 widget. The first release
wraps private Tor calls, record-then-send push-to-talk, encrypted chat, invites,
audio setup, and an experimental multi-caller relay in one compact bar panel.
There is no terminal session to babysit and no public server to configure.

### Plugin-site call to action

Put a phone in your bar. Share an invite privately, call a friend, and hold to
talk.

## Artwork notes

Primary plugin-listing and README image: [preview.png](../preview.png).
The ready-to-upload GitHub social card is
[`assets/omaphone-social.png`](../assets/omaphone-social.png).

The image should be a real screenshot from a clean, disposable Omarchy 4 VM,
lightly composed for each destination. It should look like a carefully riced
Omarchy desktop while keeping the Omaphone widget legible at thumbnail size.
Never capture or publish a real invite, room key, onion address, username,
notification, network name, or other personal data.

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
- Invites contain a shared room key and must be shared through a trusted,
  private channel.
- The experimental group host forwards opaque traffic and does not join the
  conversation. It exposes connection count, timing, and traffic-volume
  metadata to the host and is not a moderation or admission-control service.
- The pinned upstream listener may accept connections on non-loopback network
  interfaces. Hosts should firewall the listen port from LAN/WAN access.
- Omarchy plugins run as the logged-in user and are not sandboxed. Users should
  review the source before installing.
- Optional Snowflake support requires the user to review and install the
  `snowflake-pt-client-bin` AUR package; normal Tor calls do not need it.
