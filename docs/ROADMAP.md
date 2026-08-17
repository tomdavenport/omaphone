# Omaphone roadmap: the private switchboard

> **Vision, not a promise or release schedule.** This roadmap separates ideas
> that fit today's TerminalPhone connection from work that needs a versioned
> protocol, an always-on service, or a completely different media transport.

## The north star

**Choose a person or room, send one intentional burst, and get back to what you
were doing. No account. No feed. No public identity.**

Omaphone should become the private people layer in the Omarchy bar, not Discord
inside a dropdown. The panel stays small. It starts a conversation, shows what
is happening, and hands larger things to the right native viewer.

Five verbs are enough to describe the long-term product:

- **Knock** — ask “free to talk?” without starting a call.
- **Talk** — today's record, release, and send rhythm.
- **Postcard** — leave a voice note or short video for later.
- **Drop** — hand over text, a link, an image, or a file deliberately.
- **Campfire** — gather a small group and visibly pass the mic.

The strategic bet is that communication has different tempos. Omaphone should
make the right tempo obvious while hiding networking machinery, never hiding a
privacy trade-off.

## What the foundation can and cannot do

Today, TerminalPhone gives Omaphone encrypted record-then-send Opus audio,
encrypted text, direct onion calls, and an experimental multi-caller relay. It
sends each audio clip as one Base64 line and has no content IDs,
acknowledgements, resumable chunks, capability negotiation, or offline store.
The relay deliberately forwards only its known audio, message, and ping frames.

That boundary creates four honest development lanes:

| Lane | Good fits | Boundary |
| --- | --- | --- |
| **Current wire** | one paired phone, quick text signals, voice drafts, local captions, better room rituals | both peers still need a live TerminalPhone connection and share its one global key |
| **Omaphone Protocol v2** | named contacts with per-contact keys, files, receipts, resumable Drops, video Postcards, per-device identity | both peers need the new protocol; legacy fallback remains |
| **Self-hosted switchboard** | offline delivery, persistent rooms, multi-device pickup | a trusted machine must stay online and will see metadata |
| **New live-media lane** | live audio, video, screen sharing | not a Bash/PTY feature and not a clean fit for Tor's TCP streams |

## Horizon 1 — Known voices

Grow beyond the one **Paired phone** that Omaphone 1.2 can call again.

### People that accrue naturally

Omaphone 1.2 guides the first connection, keeps one stable device onion address,
remembers one paired phone, and remembers whether this computer normally waits
or calls. TerminalPhone still uses one global shared secret; it does not ship
person-specific keys or multiple contact profiles. After a successfully
authenticated conversation, a future version can ask **Keep this person?** and
let the user give the relationship a local name such as “Ada” or “Studio”. The
name never leaves the device and never pretends to verify a real identity.

The target keeps one device address—one private phone number—while each saved
person owns a distinct cryptographic relationship key, matching capabilities,
and scoped local history. Those keys stay invisible in normal UI. Only an
authenticated conversation can enter **Recent**. Failed calls, pasted
addresses, unknown incoming attempts, and unauthenticated sessions never create
people silently.

TerminalPhone cannot get there by putting several names beside its one shared
secret. The ordinary multi-contact design needs a versioned listener that can
select and authenticate separate relationship keys behind the stable device
address. Fully isolated TerminalPhone profiles and onion identities can remain
an advanced privacy mode. The storage, migration, and trust boundaries are
detailed in [Contacts roadmap](CONTACTS.md).

### Experiments only after People is solid

- **Replay before send** and a local voice-draft tray, without changing the
  network format. The current PTY adapter still needs an explicit audio hook
  to retain or inject a prerecorded clip.
- **Local captions** for received voice, generated on the user's machine and
  never sent unless they choose to send the text. This needs the same local
  decoded-audio hook.
- A few explicit in-call phrases such as “one moment” or “your turn”, sent as
  ordinary text rather than pretending to be a new control protocol.

### Room work before adding scale

Turn-taking is the product, not a limitation to disguise. On today's wire the
panel can show only honest local cues: someone is speaking, wait your turn, the
host is relay-only, and the room timer is local. The relay cannot synchronize a
speaking token, attribute **raise hand**, or enforce **pass the mic** because it
forwards only its existing frame types and every participant shares one room
identity. Coordinated room rituals belong after v2 member identities.

After People works, explore a host-and-join mode using a fully isolated second
TerminalPhone profile, its own supervisor, and non-conflicting Tor and listener
ports so one physical machine can relay and participate without sharing
runtime files or lifecycle state.

### Horizon gate

- A returning user can choose among saved people and call one in two actions.
- No unverified event silently creates or changes a person.
- A user can explain that the device has one number while every saved person
  has a separate relationship key.
- Group participants understand who hosts, who can talk, and how to leave.

## Horizon 2 — Private Drops

Files should feel like handing someone one thing, not opening a tiny file
manager.

### The experience

Drag a file onto the phone, choose a person, and send. The recipient sees one
card with sender, filename, type, size, and **Accept**. The bar icon becomes a
progress ring. Completion offers **Open** or **Show in Files** in a normal
window.

Start with explicit text and URL handoff, then small images, then ordinary
files. Never monitor the clipboard. Never download, preview, open, or copy
without a user action. Group fan-out waits until direct transfer is boringly
reliable because every recipient multiplies Tor traffic.

### A bridge experiment

A useful early prototype could start a one-time [OnionShare](https://docs.onionshare.org/2.4/en/features.html)
share and send its private capability link through Omaphone's encrypted text
channel. That tests the **Drop** experience without stuffing large blobs into
TerminalPhone's line protocol. It would remain an optional, separately
reviewed dependency—not the final Omaphone transfer protocol.

### Omaphone Protocol v2

Do not disguise a file as an enormous `MSG:` or `AUDIO:` line. Define a small,
carrier-independent envelope with:

- explicit version and capability negotiation with safe v1 fallback;
- content and transfer IDs;
- binary length framing and bounded chunks;
- acknowledgement, cancellation, retry, and resume;
- authenticated integrity, expiry, and replay protection;
- encrypted metadata wherever routing permits;
- normalized filenames, storage quotas, and failure cleanup; and
- individual device identities before multi-device or durable groups.

Use reviewed cryptographic building blocks rather than inventing file crypto.
For example, [libsodium secretstream](https://doc.libsodium.org/secret-key_cryptography/secretstream)
is designed for authenticated chunked streams and detects corruption,
reordering, duplication, and truncation. A protocol proposal still needs test
vectors, parser fuzzing, downgrade tests, and outside review before real use.

### Video that fits Omaphone

The native first video feature is a **Postcard**: record a short clip, compress
it locally, show one thumbnail, and deliver it as a bounded Drop. That keeps
the deliberate send-and-release rhythm and works better with Tor latency than
pretending the panel is a meeting app.

The same capsule model can later carry a screenshot or a short screen
recording. Capture must use the desktop permission portal, show an unmistakable
indicator, and stop automatically at a strict limit.

### Knocks, quiet presence, and Campfire controls

Protocol v2 can make **Knock** a real pre-call signal while the other person is
online, with plain replies such as “free now” or “later”. It can also expose
temporary, opt-in availability such as “open to calls for 15 minutes” without
creating a permanent last-seen record. Offline Knocks still require a Porch.

Synchronized **raise hand**, **pass the mic**, and attributable room events
must wait for individual device identities and authenticated control frames.
They should not be encoded as magic chat text or trusted when every participant
holds the same shared identity.

### Horizon gate

- An interrupted Drop resumes and verifies byte-for-byte.
- A refused or failed Drop leaves no stray plaintext.
- Filenames, previews, oversized content, and decompression bombs are treated
  as hostile input.
- A Postcard feels like one quick communication, not a second video product.

## Horizon 3 — Your own answering machine

True offline delivery needs another machine to remain online. Make that fact a
feature: **Omaphone Porch**, a tiny switchboard a user can run on an old Omarchy
box, home server, or VPS. Tor publishes it without a public IP or router port
forwarding.

The Porch holds encrypted text, voice Postcards, and Drops with visible expiry
and quotas. It should not receive plaintext content, but its operator can see
connection timing, volume, and routing metadata. Pickup, deletion, retry, and
recovery after restart need tests before “delivered” appears in the UI.

This horizon enables:

- voice bursts for someone who is offline;
- a private outbox and answering-machine inbox;
- persistent Campfires and bulletin-style radio rooms;
- encrypted multi-device pickup and handoff; and
- a self-hosted room appliance that can stay online without the desktop panel.

A persistent Campfire needs its own saved host profile, durable room identity,
and rotation story. Saving today's participant profile is not enough because
each newly hosted room intentionally gets a fresh in-memory key.

Durable groups need real membership and key rotation. Evaluate an audited
implementation of [Messaging Layer Security](https://www.rfc-editor.org/rfc/rfc9420.html)
rather than designing group key management from scratch. MLS provides a model
for asynchronous group establishment, forward secrecy, and post-compromise
security after fresh key updates are committed and processed; adopting it
would still be a substantial new protocol project.

### Horizon gate

- A queued voice burst survives sender, recipient, and Porch restarts.
- Expiry and deletion work under failure, not just in a demo.
- The Porch cannot read stored content and its metadata exposure is explained
  before setup.
- A home switchboard can be installed without an Omaphone account, public IP,
  or router configuration.

## Frontier — Live without a silent privacy downgrade

Live audio, video, and screen sharing are possible, but they are not a
TerminalPhone option. They need a native real-time media plane, a separate
window, congestion control, device permissions, and a much larger security
surface.

Keep the current record-and-send experience as **Private over Tor**. If live
media earns its way onto the roadmap, offer visibly different routes:

- **Private · Tor** — Talk, Postcards, and Drops; slower and location-hiding.
- **Nearby · direct** — live media on a trusted LAN or private overlay; peers
  learn network information.
- **Relayed live** — WebRTC through a chosen TURN service; its operator sees
  network metadata.

Never switch routes silently. Show the route before the user answers, make the
choice sticky per person, and fail closed if a privacy requirement cannot be
met.

[WebRTC](https://www.w3.org/TR/webrtc/) is the practical live-media family and
[libdatachannel](https://github.com/paullouisageneau/libdatachannel) is one
native implementation worth evaluating. Relay-only WebRTC requires a
[TURN server](https://webrtc.org/getting-started/turn-server), and direct ICE
candidates can reveal network addresses. Tor onion circuits carry
[TCP streams](https://spec.torproject.org/tor-spec/relay-cells.html), while
baseline WebRTC data channels and
[QUIC](https://www.rfc-editor.org/rfc/rfc9000.html) are UDP-oriented, so neither
is a drop-in replacement for today's onion call.

Live video comes last. Private Drops, Postcards, contacts, and an answering
machine are more distinctive, more accessible, and more faithful to the
reason Omaphone is delightful.

## Product rules that do not change

- No social feed, public discovery, mandatory account, or contact upload.
- No automatic clipboard sync, attachment download, or file opening.
- A local nickname never claims to verify a human identity.
- “Sent”, “received”, “picked up”, and “read” mean different things.
- Presence is coarse, temporary, and optional—not a surveillance timeline.
- Every route is named with its privacy trade-off before connection.
- Legacy TerminalPhone remains a bounded compatibility mode, not a reason to
  stretch Bash framing forever.
- The panel stays a switchboard. Files, galleries, and video belong in proper
  windows.
- Success is measured with local test harnesses and usability sessions, not
  central telemetry.

## The next three bets

1. **People and relationship keys.** Keep one stable device number, build
   separate invisible per-contact keys, and migrate 1.2's single **Paired
   phone** without guessing identity or cloning its legacy global key.
2. **Write the v2 envelope before shipping blobs.** Specify capabilities,
   framing, storage limits, cryptographic boundaries, and downgrade behavior;
   publish test vectors.
3. **Prototype one tiny Drop.** Send a bounded image between two disposable
   peers, require acceptance, interrupt it halfway, resume it, verify it, and
   prove cleanup—before adding larger files or video.

That sequence changes the local rules first, shortens the feedback loop with a
small survivable artifact, and prevents attention from being scattered across
live video, cloud accounts, and ten half-built transports at once.
