---
name: playtest-checklist
description: A structured way to playtest a draft character — which messages to send, what to look for in each reply, and how to turn problems into fixes. Use before calling a card finished, after large changes, or when the user asks to test the character.
license: Apache-2.0
metadata:
  origin: maichat-starter
  version: "1"
---

# Playtest checklist

A playtest sends the draft through the user's real chat setup — their preset,
persona, model and the draft's lorebooks — and shows what the character
actually says. One playtest with the right messages finds more than several
with "hello".

## The messages to send

Run the playtest tool with up to four messages at a time. Cover these, choosing
wording that fits the card:

1. **An ordinary reply to the greeting** — what a user would naturally say
   next. Checks voice, length and whether the scene moves.
2. **A question that uses a lorebook key** — "What happened at the drowned
   bell?" Checks that lore fires and is used in the character's own words.
3. **A push against the character** — a rude remark, a request they should
   refuse, a challenge to their story. Checks that they stay themselves rather
   than becoming agreeable.
4. **Something the card does not cover** — an unexpected question. Checks that
   the character improvises in voice instead of breaking.

For a card with alternate greetings, run at least one playtest from an
alternate (`greeting_index`) as well as the first message.

## What to look for

- **Voice**: do the replies sound like this character, with their habits, or
  like a generic assistant?
- **{{user}}'s agency**: does the reply write {{user}}'s actions, words or
  feelings? That is the most common and most annoying fault.
- **Length and format**: close to the greeting's length and formatting?
- **Lore**: did the entries that should fire get used, and correctly?
- **Consistency**: does anything contradict the description, the scenario or
  another reply?
- **Stock phrases and repetition**: the same opening words, the same closing
  question, clichés.

## Turning findings into fixes

- Speaking for {{user}}: rewrite the greetings and example dialogue so they
  never do it; add one line to post-history instructions only if that fails.
- Generic voice: add or sharpen example dialogue (see the distinct-voices
  skill if it is on).
- Lore not firing: the keys are words nobody typed; add the words the playtest
  actually used.
- Too long or too short: fix the greeting's length first.
- Contradictions: decide which version is true and fix the other at its source.

Fix one or two things, then playtest again with the messages that failed. Report
what you tested, what you found and what you changed — briefly.
