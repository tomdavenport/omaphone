# Contacts roadmap

> **Proposal, not a shipped feature.** Omaphone currently remembers one peer
> address and one room key. This document describes how a useful address book
> can grow without quietly weakening that privacy model.

## The experience

The address book should accrue through normal use instead of starting as a
blank database form:

1. Pair an invite.
2. Give it a local name such as “Ada” or “Studio room”.
3. Call from the **People** list next time.

After a successful authenticated conversation with a new address, Omaphone can
show a gentle **Add to People** prompt. It may also place that peer in a short
**Recent** list. Failed calls, pasted addresses, incoming connection attempts,
and unauthenticated sessions must never create a recent contact.

Names are local nicknames. Omaphone must not send them to the peer, add them to
an invite, or claim that a nickname verifies a person's real identity. The
shared room key still proves only that both sides hold the same secret.

## One person listens at a time

TerminalPhone uses one active shared secret and Omaphone deliberately runs one
TerminalPhone instance. That means the first address book should not pretend to
listen for every saved person at once.

One contact is selected as the listening profile. The panel should say
**Listening for Ada**, not simply **Listening for everyone**. Selecting another
contact while online should:

1. stop the current listener;
2. switch the complete room profile atomically;
3. restart listening; and
4. make the selected person unmistakable in the panel.

A contact switch is blocked during a call, audio test, or hosted room. A future
multi-profile listener would need isolated TerminalPhone data directories,
Tor services, listen ports, and supervisors; that is a separate feature, not a
shortcut for version one.

## What a contact owns

Each contact represents a room relationship, not a globally verified person.
Its profile contains:

- a random local contact ID;
- a local display name;
- the peer's onion address;
- the room's shared secret;
- settings that must agree across the room, including message authentication;
- the time of the last successful authenticated connection; and
- that contact's bounded text history.

The room secret belongs to the contact profile. It must not be copied into a
general address index. Two entries may point to the same onion address while
using different room keys, and changing an invite should replace a key only
after a clear confirmation.

Direct-message history is scoped to the selected contact. Group-room history
is scoped to the saved room, not copied into each participant. Switching
contacts must never leave the previous conversation visible beneath the new
name.

## Safe local storage

A practical on-disk shape is:

```text
$XDG_DATA_HOME/omaphone/contacts/
  index.json
  <random-contact-id>/
    room.json
    secret
$XDG_STATE_HOME/omaphone/contacts/
  <random-contact-id>/messages.json
```

Directories stay mode `0700`; files stay mode `0600`. `index.json` can contain
the local name, random ID, and ordering information, but not a secret or a
reusable invite. The secret remains in its own file. Omaphone should not keep
the original invite after it has parsed and stored the minimum fields.

The ordinary status snapshot must expose only what the panel needs: random
contact ID, local name, selection state, and perhaps a masked address. It must
never contain a room secret, full invite, or chat text from an unselected
contact. Commands should select or call a contact by its random ID; the backend
resolves the address and secret privately.

Invites and replacement secrets should continue to cross the short-lived CLI
over standard input, never process arguments. Logs and error messages should
refer to the local contact name or random ID, not echo private material.

## When a recent contact is trustworthy enough

“The socket connected” is not enough. The supervisor needs a distinct
authenticated-session event before it updates **Recent**. With message
authentication enabled, that event should follow acceptance of a valid frame
under the selected room key. Relay greetings and group-count messages do not
qualify because the upstream relay sends them outside that authentication
wrapper.

If a user deliberately turns message authentication off, Omaphone cannot make
the same claim. It should label the session unverified and require an explicit
save instead of automatically adding it to **Recent**.

Recent entries should be bounded, deduplicated by contact profile, easy to
clear, and disabled with one setting. They should influence local ordering
only—never be synced, broadcast, or placed in an invite.

## Privacy controls the first version needs

- **Save as a person** after pairing, with a local-only name.
- **Forget contact**, which removes its profile and scoped chat after warning
  that storage backups may retain old copies.
- **Clear recents** without deleting saved people.
- **Clear this conversation** without touching other contacts.
- **Replace room key** with explicit confirmation and listener restart.
- **Reveal address** only on demand; keep long onion addresses out of the main
  list and general status snapshot.
- No automatic cloud sync, contact discovery, phone-book upload, or telemetry.

Local names and last-contact times still form a relationship graph for anyone
who can read the unlocked account. User-only permissions help, but disk
encryption, session locking, backups, and device compromise remain part of the
threat model.

## Suggested delivery order

1. Introduce contact storage and atomic profile selection behind backend tests.
2. Move today's valid peer and room secret into one migrated contact. Preserve
   old messages as unassigned **Previous local chat**; do not guess who sent
   them.
3. Add the **People** picker and local naming after invite pairing.
4. Add per-contact chat and explicit deletion.
5. Add authenticated recents only after the backend can prove the session
   event described above.

This sequence gives people a useful address book early while keeping automatic
accrual behind the security signal it depends on.
