---
name: lorebook-hygiene
description: Writing lorebook (world info) entries that fire when they should and cost little when they do. Use when creating or revising lorebooks, when lore is not showing up in playtests, or when the permanent token count is too high and background needs to move out of the card.
license: Apache-2.0
metadata:
  origin: maichat-starter
  version: "1"
---

# Lorebook hygiene

A lorebook entry is text that is added to the prompt only when one of its keys
appears in the recent conversation. Done well, lore costs nothing until it is
needed. Done badly, it never fires, fires all the time, or repeats the card.

## Decide what belongs in lore

Move out of the card anything the character does not need in *every* reply:
places, factions, other people, history, objects, rules of magic or technology.
Keep in the card what shapes how they speak and act in every scene. If you are
unsure, ask: would a reply to "hello" be worse without this? If not, it is lore.

## One subject per entry

Each entry covers one thing — one place, one person, one faction, one event.
"The Saltmarsh" and "The drowned bell" are two entries, even if the bell hangs
in the marsh. One subject per entry means an entry fires only when it is
relevant, and a mention of the bell does not drag in the whole marsh.

## Keys

- Use the nouns a person would actually type: names, places, objects, titles.
  Not abstract words ("sadness", "history") — they fire everywhere or nowhere.
- Two to six keys per entry. Include the obvious variants: short names,
  nicknames, plurals, the way someone in the story would refer to it
  ("Saltmarsh", "the marsh", "marshes").
- Avoid keys that are common words in ordinary chat ("light", "door",
  "home"). A key like that fires on every other message. Prefer a longer
  phrase ("the lighthouse door") or a secondary key to narrow it.
- Secondary keys narrow an entry: the entry fires only when a primary key and
  a secondary key both appear. Use them for a common primary word that is only
  meaningful in one context.
- Check every key against the other entries. Two entries sharing a key fire
  together; that is fine only if they belong together.

See `references/key-examples.md` for good and bad keys side by side.

## Content

- 50 to 250 tokens. Longer entries crowd out the conversation; if an entry
  runs long, split it by subject.
- Plain facts, third person, present tense: "The drowned bell hangs under the
  Saltmarsh pier and rings at low tide." Not prose, not dialogue, not
  instructions to the model.
- Say what matters to a scene: what it looks, sounds and smells like, who is
  there, what is dangerous, what the character feels about it.
- Do not repeat the description. If the card already says Maren is the keeper,
  the lighthouse entry does not say it again.
- Use `{{char}}` and `{{user}}` where the entry refers to them.

## Constant entries

A constant entry is sent with every message, like the description. Use one only
for a rule of the world that must hold in every reply ("Magic here always costs
a memory"). Keep it short. If more than one or two entries are constant, most
of them belong in the card or should become keyed entries.

## Order and position

Leave order and position at their defaults unless there is a reason. Raise the
order of an entry that must win when several fire at once. Use a depth
position (a few messages from the end) only for something that must stay fresh
in the model's attention, such as a current condition or a secret the
character is guarding.

## Checking your work

After writing entries, playtest with messages that use the keys ("What is the
drowned bell?") and messages that should not trigger them. Read the reply and
the request: lore that should have fired and did not usually has a key nobody
would type.
