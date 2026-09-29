---
name: avoid-purple-prose
description: Keeping card text and greetings concrete and readable, and steering the model away from the stock phrases roleplay replies fall into. Use when writing descriptions or greetings, when the user complains of clichés or overwrought writing, or when playtest replies repeat stock phrases.
license: Apache-2.0
metadata:
  origin: maichat-starter
  version: "1"
---

# Avoiding purple prose

Overwrought card text produces overwrought replies: the model matches the
register it is given. Plain, specific writing in the card is the most reliable
way to get plain, specific writing back.

## In the card itself

- Prefer the concrete detail to the adjective. Not "beautiful and mysterious"
  but "grey eyes, a scar through one eyebrow, never sits with her back to a
  door."
- One precise detail beats three vague ones. Cut the adjective that says what
  the detail already shows.
- Avoid stacked intensifiers and superlatives: "incredibly", "utterly",
  "impossibly", "the most beautiful".
- Descriptions are reference material, not a showcase: short sentences or a
  clean attribute list are both fine; flowery paragraphs are not.
- Greetings set the tone of every reply. Write them the way you want the model
  to write: grounded, active verbs, sensory but not saturated.

## Stock phrases to keep out

The phrases in `references/stock-phrases.md` are the ones models reach for
when a card leaves room. Do not use them in the card or greetings, and if a
playtest reply leans on them, tighten the card's own writing rather than
adding a long ban list — a ban list in the prompt spends tokens and often
plants the very phrase it forbids.

If the user wants an explicit instruction, keep it to one line in the
post-history instructions, phrased positively: "Write plainly and
specifically; favour concrete detail over adjectives."

## Revising

1. Read the draft aloud in your head. Mark every sentence that sounds like a
   blurb rather than a person.
2. Replace each with a detail, an action or a line of dialogue.
3. Cut what repeats.
4. Playtest once and compare the reply's register with the greeting's.
