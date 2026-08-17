# Contacts roadmap

> **Proposal, not a shipped feature.** Omaphone 1.2 has one stable device
> address, TerminalPhone's one global shared secret, and one saved **Paired
> phone**. It does not have an address book or a unique number or key for each
> person. This document describes how real contacts can grow without quietly
> reusing that global key.

## What 1.2 intentionally stops at

The guided flow removes manual online, address, and call steps. One computer
shares its private contact card and waits; the other pastes it and connects.
The connecting computer can call that **Paired phone** again later, and each
side remembers whether it normally waits or calls.

The `.onion` address is this installation's stable device identity—roughly one
private phone number for the device. It is not freshly generated for each
person. TerminalPhone also has one global direct-call secret, so normal contact
cards shared by that device carry the same key until the profile changes. A
contact card is therefore not a person-specific cryptographic identity.

Adding another private contact card—or using a group-room invite—replaces the
remembered peer address and active global key on the joining device. A list of
names pointing at that one key would expose every relationship to every key
holder, so Omaphone must not present that as secure multi-contact support.

## The experience

The future address book should accrue through normal use instead of starting
as a blank database form:

1. Add a phone with its private contact card.
2. Give it a local name such as “Ada” or “Studio room”.
3. Call from the **People** list next time.

After a successful authenticated conversation with a new phone, Omaphone can
show a gentle **Add to People** prompt. It may also place that peer in a short
**Recent** list. Failed calls, pasted addresses, incoming connection attempts,
and unauthenticated sessions must never create a recent contact.

Names are local nicknames. Omaphone must not send them to the peer, add them to
a private contact card, or claim that a nickname verifies a person's real
identity. Each saved relationship needs its own invisible cryptographic key;
the user should choose “Ada”, not manage key strings.

## One device number, separate relationship keys

The everyday target is one stable device address with a **People** list behind
it. A caller selects a local name; Omaphone resolves that person's stable
device address and relationship key privately. The receiver keeps one device
number rather than asking friends to track a different onion identity for each
relationship.

Today's TerminalPhone wire format cannot provide that model securely. Its
listener loads one global shared secret, so merely adding a contacts JSON file
would either listen for only one key or reuse one key across everyone. Proper
support needs a versioned protocol and listener that can select and
authenticate the right per-contact key without exposing another contact's key.

An advanced privacy mode can later isolate selected relationships into separate
TerminalPhone profiles, onion identities, ports, and supervisors. That is
useful compartmentalization for expert users, but it should not become the
ordinary price of having named contacts.

## What a contact owns

Each contact represents a cryptographic relationship, not a globally verified
person. Its profile contains:

- a random local contact ID;
- a local display name;
- the peer device's stable onion address;
- key material unique to that relationship, hidden from normal UI;
- negotiated settings and protocol capabilities;
- the time of the last successful authenticated connection; and
- that contact's bounded text history.

Relationship key material belongs to the contact profile. It must not be copied
into a general address index or cloned from TerminalPhone's legacy global
secret into every new contact. Two entries may point to the same device address
while using distinct relationship keys, and replacing a key requires clear
confirmation.

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
reusable private contact card. The secret remains in its own file. Omaphone
should not keep the original card after it has parsed and stored the minimum
fields.

The ordinary status snapshot must expose only what the panel needs: random
contact ID, local name, active-call state, and perhaps a masked address. It must
never contain a room secret, full contact card, or chat text from an unselected
contact. Commands should select or call a contact by its random ID; the backend
resolves the address and secret privately.

Private contact cards and replacement secrets should continue to cross the
short-lived CLI over standard input, never process arguments. Logs and error
messages should refer to the local contact name or random ID, not echo private
material.

## When a recent contact is trustworthy enough

“The socket connected” is not enough. The supervisor needs a distinct
authenticated-session event before it updates **Recent**. With message
authentication enabled, that event should follow acceptance of a valid frame
under the selected relationship key. Relay greetings and group-count messages
do not qualify because the upstream relay sends them outside that
authentication wrapper.

If a user deliberately turns message authentication off, Omaphone cannot make
the same claim. It should label the session unverified and require an explicit
save instead of automatically adding it to **Recent**.

Recent entries should be bounded, deduplicated by contact profile, easy to
clear, and disabled with one setting. They should influence local ordering
only—never be synced, broadcast, or placed in a contact card.

## Privacy controls the first version needs

- **Save as a person** after connecting, with a local-only name.
- **Forget contact**, which removes its profile and scoped chat after warning
  that storage backups may retain old copies.
- **Clear recents** without deleting saved people.
- **Clear this conversation** without touching other contacts.
- **Replace relationship key** with explicit confirmation.
- **Reveal device address** only on demand; keep long onion addresses out of
  the main list and general status snapshot.
- No automatic cloud sync, contact discovery, phone-book upload, or telemetry.

Local names and last-contact times still form a relationship graph for anyone
who can read the unlocked account. User-only permissions help, but disk
encryption, session locking, backups, and device compromise remain part of the
threat model.

## Suggested delivery order

1. Specify how one stable device address negotiates and selects distinct
   per-contact keys; publish downgrade and cross-contact isolation tests.
2. Introduce contact storage, then migrate 1.2's **Paired phone** once. Mark its
   key as legacy global material; never duplicate it into newly created people.
   Preserve old messages as unassigned **Previous local chat** rather than
   guessing who sent them.
3. Add **People** and local names while keeping keys invisible in normal UI.
4. Add listener/caller support for several authenticated relationships on the
   one stable device identity.
5. Add per-contact chat, explicit deletion, and key replacement.
6. Add authenticated recents only after the backend can prove the session
   event described above.

This sequence avoids dressing TerminalPhone's shared global key up as a secure
address book. Isolated identities can remain an advanced privacy option after
the one-number, separate-keys model is sound.
