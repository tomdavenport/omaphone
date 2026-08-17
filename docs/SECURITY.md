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
- The room secret is stored unencrypted on disk with mode `0600` so background
  listening can restart without a passphrase. Full-disk encryption protects a
  powered-off machine; a compromised or unlocked user account does not.
- The recent in-widget text history is stored as bounded plaintext status with
  the same user-only boundary. Use **Advanced → Clear local chat history** if
  local message retention is inappropriate for the device.
- Contact identity is possession of an invite/shared secret, not a public-key
  identity ceremony. Confirm an invite through a second channel for sensitive
  use.
- Tor hides network location under its own threat model; it does not make a
  compromised endpoint, microphone, operating system, or room peer safe.

## Settings that change the threat model

- **HMAC** authenticates protocol messages with the room secret and should
  normally remain enabled for Omaphone peers. Both ends must agree.
- **Snowflake** is a censorship-circumvention transport, not an extra content
  encryption layer.
- **Single-hop** (used for specialized relay operation upstream) trades server
  anonymity for latency and should not be treated as a harmless performance
  switch.
- **Country exclusions** can reduce available paths and create a distinctive
  routing policy; they are expert controls, not a universal security upgrade.
- **Voice effects** alter outgoing audio but are not reliable speaker
  anonymization.

## Reporting a vulnerability

Do not include room secrets, onion private keys, invites, message contents, or
raw diagnostic logs in a public issue. Reproduce with a fresh disposable
profile, then report whether the issue belongs to the Omaphone supervisor/UI or
the pinned TerminalPhone backend.
