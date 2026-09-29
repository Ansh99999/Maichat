---
name: greeting-variety
description: Writing a first message and alternate greetings that each open a genuinely different scene. Use when writing or revising greetings, when the user asks for more openings, or when existing greetings feel like the same scene reworded.
license: Apache-2.0
metadata:
  origin: maichat-starter
  version: "1"
---

# Greeting variety

A greeting is the first thing the user reads and the example the model copies
for length, tense and voice. Alternate greetings exist so the user can start a
different story with the same character. Three greetings that open the same
scene in different words are one greeting.

## What makes a greeting good

- It drops the user into a moment, not a biography. Something is happening:
  a knock, a storm, an argument half over, a request.
- It gives the user something to answer. End on a question, a choice, a look
  that waits for a reply, or an action that invites one.
- It is written in the voice and style the card uses everywhere — the same
  tense, person and roughly the length replies should have. A 600-word greeting
  teaches the model to write 600-word replies.
- It never writes {{user}}'s actions, words, thoughts or feelings. Describe
  the world and {{char}}; leave {{user}} free. "You step inside" is already
  deciding for them — prefer "The door stands open behind {{user}}."

## Make each alternate differ on purpose

Before writing, decide how each greeting differs from the others. Vary at least
two of these per greeting:

- **Situation**: first meeting, reunion, mid-crisis, aftermath, ordinary day.
- **Relationship**: strangers, rivals, old friends, employer and hire, captor.
- **Place and time**: the lamp room at night, the market at dawn, a funeral.
- **Mood**: tense, playful, melancholy, urgent, quiet.
- **Who acts first**: {{char}} approaches, {{char}} is found, something happens
  to both.

A good set of three for a lighthouse keeper might be: a stranger washed up after
a wreck (first meeting, urgent); an old friend back after ten years (reunion,
quiet); a storm cutting the power while something knocks below (crisis, tense).

## Tie each greeting to its situation

When a greeting implies a situation the card's scenario does not cover, give it
a scenario of its own with upsert_scenario and list that greeting's index in
it, so the model knows where each opening takes place. The first message is
greeting 0, the first alternate is greeting 1.

## Length and form

- Match the length you want replies to have — usually one to three short
  paragraphs.
- Mix action and dialogue; a wall of either reads flat.
- Use the formatting the card uses elsewhere (asterisks for actions, or plain
  prose) and keep it consistent across every greeting.

## Before you finish

Read the greetings side by side. If two could swap situations without changing
much, rewrite one. Then playtest at least one alternate, not just the first
message: `playtest` takes a `greeting_index`.
