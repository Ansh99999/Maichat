---
name: distinct-voices
description: Giving a character (or each member of a cast) a voice that is recognisably theirs — word choice, rhythm, what they avoid saying — and example dialogue that teaches it. Use when writing personality, example dialogue or greetings, when playtest replies sound generic, or when several characters sound alike.
license: Apache-2.0
metadata:
  origin: maichat-starter
  version: "1"
---

# Distinct voices

The model imitates what it is shown more than what it is told. "She is
sarcastic" produces generic sarcasm; three lines of her actual sarcasm produce
her. A voice lives in example dialogue and greetings first, and in the
personality second.

## Build the voice from specifics

Decide, for this character:

- **Vocabulary**: plain or ornate, modern or old, technical, regional? What
  words would they never use?
- **Rhythm**: short clipped sentences, long winding ones, fragments, lists?
- **Register**: how formal are they with strangers, with friends, with people
  they despise?
- **Habits**: a phrase they repeat, how they deflect, what they do instead of
  answering, how they address people (by name, by title, by insult).
- **What they avoid**: the subject they change, the feeling they never name.
  Evasions characterise as much as statements.

Write these into the personality in a few lines — concrete, not adjectives:
"Answers questions with questions when cornered. Calls everyone 'lad' or
'lass' regardless of age. Never says her brother's name."

## Example dialogue that teaches

- Use the `<START>` convention: a `<START>` line before each example, then
  `{{char}}:` and `{{user}}:` turns.
- Two to four short exchanges, each showing a different side: at ease, under
  pressure, lying, being kind.
- Keep {{user}}'s lines minimal and neutral — they are there to prompt, not to
  characterise the user.
- Let {{char}}'s lines carry the habits you decided on. If a habit never
  appears in an example, the model will not learn it.
- Match the formatting and length of real replies.

## Several characters in one story

When a cast shares a world, make their voices differ on at least two axes
(rhythm and register are the easiest to hear). Read a line of dialogue with
the name hidden: if you cannot tell who said it, change one of them. Give each
character a different way of refusing, of joking and of being afraid.

## Check by ear

Playtest with an ordinary question and with a provoking one. Read only
{{char}}'s words: do they sound like this person, or like any helpful
assistant in costume? If generic, add a sharper example rather than more
adjectives.
