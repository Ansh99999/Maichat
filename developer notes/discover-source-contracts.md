# Discover — reverse-engineered source contracts

The in-app catalogue browser (`services/discover/*`) talks to ~9 third-party
sites, each reverse-engineered (cross-checked against the SillyTavern
CharacterLibrary extension `modules/providers/*`, agnai's `chub.ts`, and ST's
`content-manager.js`). These contracts are **not derivable from our code** and
several **cannot be verified from the dev host** — record them here.

## Verification reality
- **Chub** (`api.chub.ai`, `gateway.chub.ai`, `api.characterhub.org`) geo-blocks
  datacentre IPs → 403 "not available in your country". **Never run against the
  real API from here** — written from 3 agreeing sources + loopback tests.
  Confirmed working on the user's phone. If Chub 403s on device, it's geo-block,
  not a client bug.
- **JannyAI** (`jannyai.com`, `api.jannyai.com`) is Cloudflare-challenged from a
  datacentre; `search.jannyai.com` (MeiliSearch) *does* answer here.
- **character-tavern.com, realm.risuai.net, botbooru.com** answer 200 here — these
  were driven live via a throwaway `test/live_sources_probe_test.dart` (deleted;
  the committed suite stays offline). Same for Pygmalion/Wyvern/DataCat.

## Per-site facts that are easy to get wrong
- **Chub field crossover** (`ChubSource._cardFromDefinition`): `definition.
  personality`→`data.description`, `definition.tavern_personality`→`data.
  personality`, `definition.description`→`data.creator_notes`, `first_message`→
  `first_mes`, `example_dialogs`→`mes_example`, node `topics`→`tags`. Casing is
  inconsistent **per field** (`starCount` beside `n_favorites`) → every read via
  `pick([camel, snake])`. `starCount` is the **download** count. Lorebooks = same
  `/search` + `namespace=lorebooks`; exclude param is `excludetopics` (no `_`).
  A lorebook's entries: git API path `.../files/raw%252Fsillytavern_raw.json/raw`
  — the escape is **deliberately doubled**, must not be re-encoded.
- **CharacterTavern**: a search hit **already contains the full definition**
  (`characterDefinition`/`characterPersonality`/…) — the web client never reads
  them, they're only indexed. Art at `ct-cards.storage.character-tavern.com/…png`,
  and **`?action=download` on that same URL is the card** (chara/ccv3 chunks) —
  without the param you get a picture with no metadata (the mistake that looks
  like a working download). No adult param (excluding the `nsfw` tag is how the
  site does SFW; adult needs a session).
- **RisuRealm**: feed reads the site's own SvelteKit page data
  `GET /__data.json?mode=character&…` — **devalue-flattened, every int is a pointer
  into a flat array** (`services/discover/sveltekit_data.dart` hydrates it).
  Search `q=` (not `search=`). `recommended` sort is **first-page only (page 2 =
  HTTP 500)**. Dates are **minutes since epoch**. Download ladder walks
  `json-v3 → png-v3 → charx-v3` and decides refusals **from the body** (Realm
  reports errors under a 200); some cards refuse png-v3 but give charx-v3 (docs
  claiming charx unsupported are stale). json-v3 preferred (few KB, carries
  `character_book`).
- **Botbooru**: download is **`/download/json/{id}`** (tens of KB), not
  `/download/png/{id}` (megabytes). `meta_name` beats `character_name`.
- **JannyAI**: browse = MeiliSearch `POST search.jannyai.com/multi-search` (index
  `janny-characters`, public key, numeric tag ids, relevance = **omit** `sort`, an
  empty array is rejected). Download rebuilt (`janny_page.dart`): the legacy
  `api.jannyai.com/api/v1/download` is dead; the definition now lives only in the
  rendered page as **Astro-island props** (HTML-escaped, each value in Astro's
  `[type,data]` envelope; unescape `&amp;` **last**). Ladder: plain-HTTP page →
  legacy API → `DiscoverChallengeException` → WebView solves the Cloudflare check.
- **Pygmalion**: Connect RPC (`server.pygmalion.chat/…/CharacterSearch?connect=v1
  &encoding=json&message=<json>`), **pages start at 0**, **every number quoted**
  (`stars:"555"`, unix-seconds-as-string dates). Download = ST's own
  `/api/export/character/{id}/v2`.
- **Wyvern**: a hit carries the whole definition; **searching and sorting are
  exclusive** (a `q` drops `sort`); `nsfw-popular` is the only order serving adult
  without an account; a book's entries live under **`lexicon`** (not `entries`,
  which sits empty).
- **DataCat** (JanitorAI/Saucepan archive): every call needs `X-Session-Token`;
  anonymous one from `POST /api/liberator/identify {deviceToken:<uuid we invent>}`
  (re-mint on 401/403). **Every listing row is flagged `isNsfw:true`** → a
  client-side SFW filter empties the feed; adult must be on. Definition whole in
  `/api/characters/{id}` `chara_card_v2_json` (avoids the Turnstile-gated
  `/download`). Tags: use the **slug** (name carries an emoji).
- **saucepan.ai is not addable** — needs a logged-in bearer token; browsing 403s
  anonymously; definitions often server-hidden; honeypots + botting signals. Their
  front door is MCP/OAuth only.

## Cloudflare clearance replay (`services/discover/browser_clearance.dart`)
Reading `cf_clearance` does **not** need `flutter_inappwebview` — HttpOnly blocks
scripts, not the platform cookie store: a ~20-line `MethodChannel` in
`MainActivity.kt` (`readCookies` → `CookieManager.getCookie`) hands it to Dart.
**A clearance is a pair, always**: Cloudflare binds it to IP *and* User-Agent, so
it must ship with the WebView's real `navigator.userAgent` or it reads as stolen —
`BrowserClearance.headers` is the only way to send it. **Never persisted** (tied
to current IP, and a credential); keyed by host with `www.` stripped. Android's
WebView cookie store is **process-wide**, so the first pass clears the rest of the
session. **Unverified on hardware** (host can't reach JannyAI) — the fallback is
intact if Cloudflare refuses the replay.

## Other deliberate calls
One source at a time (each has its own sort/tag vocabulary), not a merged feed.
Avatars downloaded as **bytes at download time** (a saved character must survive
the CDN) — `hasAvatar && !avatarIsUrl` guards overwriting a URL avatar. A
download may carry **both** a character and its embedded `character_book`
(`CharacterCodec.cardJsonOf` + `embeddedLorebook`) — cards were silently losing
their lorebooks before that. No catalogue publishes presets.
