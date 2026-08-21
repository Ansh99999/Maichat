# Developer notes

Durable, session-derived notes for MaiChat that don't fit in `CLAUDE.md` and
aren't obvious from the code or git history. Committed on purpose (the repo is
private) so that a Claude Code session — or a human — on any machine has this
context, not just the machine it was first learned on.

`CLAUDE.md` is still the primary project guide. These notes are the "how we
learned this / do not regress this" layer underneath it.

## Index

- [floating-image-lag-fix.md](floating-image-lag-fix.md) — how the
  floating-picture drag/pinch/scroll lag was diagnosed and fixed on a real
  device. **Read before touching the float layer, the chat background, or
  message rendering.**
- [prompt-wire-and-storage.md](prompt-wire-and-storage.md) — the
  one-leading-`system`-message wire rule (verify at the wire), the base64-in-prefs
  OOM story + `prefs_repair`, pictures-are-files, and render-cost facts.
- [discover-source-contracts.md](discover-source-contracts.md) — reverse-engineered
  API contracts for every Discover source, the Cloudflare-clearance replay, and
  what can't be verified from the dev host.
- [chat-portability-formats.md](chat-portability-formats.md) — cross-app chat
  import/export format facts and the one-file-three-apps trick.
- [feature-notes-and-test-traps.md](feature-notes-and-test-traps.md) — per-feature
  gotchas (per-chat overrides, lorebooks, group chats, gallery) and the recurring
  Flutter/test traps.

