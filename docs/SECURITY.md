# Security model

Omaphone reduces setup and interaction complexity; it does not remove the
operational assumptions of TerminalPhone or Tor.

## Protected by design

- TerminalPhone's pinned implementation remains responsible for encryption,
  HMAC, audio encoding, onion routing, and its on-wire protocol.
- The bundled script is verified by SHA-256 before it is copied or executed.
- Room secrets are never passed in process arguments, written to logs, or
  returned by the regular status endpoint.
- Message text and pair/invite input cross the short-lived CLI over stdin.
- Runtime control is a user-only local socket, and durable private files use
  restrictive permissions.
- Only one TerminalPhone process may own a profile at a time.

## Trust and exposure

- Omarchy shell plugins execute unsandboxed as the logged-in user. Review this
  repository and its pinned upstream before enabling it.
- An Omaphone invite contains the onion address and shared room secret. Anyone
  with the invite can attempt to join that room and decrypt compatible
  traffic. Send it through an authenticated, confidential channel.
- Clipboard managers may retain an invite after copying it. Remove sensitive
  entries when necessary.
- The current call secret is stored unencrypted on disk with mode `0600` so
  background listening can restart without a passphrase. A hosted room uses a
  separate secret held in the host backend's memory for that relay session;
  participants store it when they use the invite. Full-disk encryption
  protects a powered-off machine; a compromised or unlocked user account does
  not.
- The recent in-widget text history is stored as bounded local plaintext state
  and appears in the user-only status snapshot used by the panel and CLI.
  Another process running as the same user can read it. Use **Advanced → Clear
  local chat history** if local message retention is inappropriate for the
  device.
- Contact identity is possession of an invite/shared secret, not a public-key
  identity ceremony. Confirm an invite through a second channel for sensitive
  use.
- Tor hides network location under its own threat model; it does not make a
  compromised endpoint, microphone, operating system, or room peer safe.

## Settings that change the threat model

- **HMAC** authenticates protocol messages with the room secret and should
  normally remain enabled for Omaphone peers. Both ends must agree.
- **Snowflake** is a censorship-circumvention transport, not an extra content
  encryption layer. Normal Tor calls and group rooms do not need it. If you
  enable it, you must separately review and install an AUR package, adding
  that package to the software you trust.
- **Single-hop** (used for specialized relay operation upstream) trades server
  anonymity for latency and should not be treated as a harmless performance
  switch.
- **Country exclusions** can reduce available paths and create a distinctive
  routing policy; they are expert controls, not a universal security upgrade.
- **Voice effects** alter outgoing audio but are not reliable speaker
  anonymization.

## Group-room hosting

The experimental group room is an upstream TerminalPhone relay. Omaphone
creates a fresh secret in the host backend's memory for each relay session and
puts it in the room invite; it does not replace the host's regular call secret.
The TerminalPhone relay process forwards matching protocol frames and does not
decrypt voice or text. Every participant uses the same invite and therefore
the same room secret; any participant with that secret can decrypt room
content and may be able to impersonate another participant. There is no
separate member identity, moderator, ban list, or admission service.

Hosting does not need a public IP, router port forwarding, or a separate
internet server because Tor publishes the relay's onion service. The host
machine must remain awake and connected, and that Omaphone instance cannot
speak or chat while it is acting as the relay.

The relay operator still controls the forwarding point and the Omaphone host
process that creates the room invite. Treat that operator as a trusted room
participant. They can observe connection count, timing, traffic volume,
protocol message types, and unencrypted handshake/control fields, and can
drop, delay, reorder, replay, or split traffic. Relay greetings and group-count
notices are not authenticated, so presence and room-size displays are
informational rather than proof of who is present.

The pinned upstream starts `socat` with `TCP-LISTEN` and no explicit bind
address. On a typical host this listens on non-loopback interfaces as well as
the loopback address used by Tor. Block non-loopback access to the listen port
with the host firewall (TCP `7777` by default). Do not assume that the absence
of router port forwarding prevents another device on the same LAN from
reaching it.

Group audio is still record-then-send push-to-talk. There is no live mixer,
speaking queue, collision handling, or tested room capacity in Omaphone. Keep
rooms small and agree that one person speaks at a time.

## Reporting a vulnerability

Do not include room secrets, onion private keys, invites, message contents, or
raw diagnostic logs in a public issue. Reproduce with a fresh disposable
profile, then report whether the issue belongs to the Omaphone supervisor/UI or
the pinned TerminalPhone backend.
