---
name: chub-ready-card
description: Preparing a character card for sharing on catalogues such as Chub, JannyAI or CharacterTavern — creator notes, tags, title, content warnings and the conventions readers expect. Use when the user says they want to publish or share a card, or asks for creator notes or tags.
license: Apache-2.0
metadata:
  origin: maichat-starter
  version: "1"
---

# A card ready to share

A shared card is read twice: by the model, which reads the definition, and by
people browsing a catalogue, who read the title, tags, picture and creator
notes and decide in seconds whether to open it. This skill is about the second
reader. Never change the definition's meaning to suit a catalogue.

## Title (the one-line hook)

One line under the name that says what the story is, not what the character is
like: "She kept the light for thirty years. Tonight something answered." Avoid
adjective lists ("Kind, mysterious, strong"). No quotation marks, no emoji
unless the card's tone is playful.

## Tags

- 5 to 12 tags, lower case, one or two words each.
- Cover: genre (horror, fantasy, sci-fi), setting (coastal, medieval,
  cyberpunk), relationship or role (mentor, rival, found family), tone
  (melancholy, wholesome, dark), and form (single character, multiple
  characters, scenario, narrator).
- Use the words people actually search for. Prefer "slow burn" over
  "gradual romance". Don't invent tags nobody searches.
- Mark content honestly. If the card involves violence, gore or mature themes,
  tag it so; readers filter on these, and catalogues remove mislabelled cards.

## Creator notes

Written to a person, never sent to the model. Keep them short and useful:

1. One or two sentences on what the card is and what kind of story it plays.
2. How to play it: which greeting starts what, anything the user should know
   (a lorebook is attached; the card works best with longer replies; it is a
   slow burn).
3. Content warnings, plainly.
4. Optional: credits for the picture or inspiration, and a version note.

Do not put instructions to the model in creator notes; they are not sent. Do
not paste the description into them either.

## Formatting conventions readers expect

- Greetings in the same formatting as the rest of the card, consistent across
  every alternate.
- `{{char}}` and `{{user}}` rather than hard-coded names in the definition, so
  the card works with any persona.
- Permanent text (description, personality, scenario, example dialogue)
  reasonably lean — well under 2000 tokens, ideally near 1000. Readers with
  small context windows notice.
- A picture that shows the character, cropped so the face survives a square
  thumbnail.

## A last pass

Check the card as a stranger would meet it: name, title, picture, the first
five tags, the first line of the creator notes. If those don't tell someone
what they are opening, fix them before anything else.
