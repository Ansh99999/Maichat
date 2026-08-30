# Google Drive backups — the OAuth client, and how to get one

`services/drive_client.dart` signs in with a **"Desktop app" OAuth client**,
PKCE, and a loopback listener (`http://127.0.0.1:<port>`). No custom URL scheme,
so no native plugin and no AGP-9 Kotlin hook. The only scopes asked for are
`https://www.googleapis.com/auth/drive.file` and `email`.

The whole flow is exercised against a loopback stand-in for Google in
`test/drive_client_test.dart`. Nothing here has a real client, so what follows is
the manual part.

## Making the client (five console pages, once)

The console is redesigned constantly, so these deep links are the durable part —
they are the same five the app's Drive screen links to under
*Advanced ▸ Use my own Google client ▸ How to get them*.

1. **Project** — <https://console.cloud.google.com/projectcreate>
2. **Enable the Drive API** — <https://console.cloud.google.com/apis/library/drive.googleapis.com>
3. **Consent screen branding** (app name + a support email) —
   <https://console.cloud.google.com/auth/branding>
4. **Audience → External → Publish app** — <https://console.cloud.google.com/auth/audience>
5. **Credentials → OAuth client ID → Desktop app** —
   <https://console.cloud.google.com/apis/credentials>

Then either paste the two strings into the app (Settings ▸ Backups ▸ Export ▸
Google Drive ▸ Advanced) or build with them:

```
flutter build apk --release \
  --dart-define=MAICHAT_DRIVE_CLIENT_ID=…apps.googleusercontent.com \
  --dart-define=MAICHAT_DRIVE_CLIENT_SECRET=…
```

**MaiChat's own client lives in repo secrets, not in the source.** The project is
`maichat-507119`; `DRIVE_CLIENT_ID` and `DRIVE_CLIENT_SECRET` are GitHub Actions
secrets, and `.github/workflows/build-apk.yml` passes them as those two defines
when it builds the release and profile APKs. This repository is public, and while
an installed app's client secret is not a confidential credential, there is no
reason to leave it in the git history — and a fork with no secrets configured
simply builds an app that asks for a client of the user's own.

`kBundledDriveClientId`/`kBundledDriveClientSecret` read those defines and are
empty otherwise. A local `flutter build` therefore has no client, which is worth
remembering when a debug install will not offer the one-tap button. With one present the Drive screen is a single **Connect Google
Drive** button; with none it asks for a client instead. `DriveClient.clientIdFor`
prefers whatever the user pasted, and the stored grant never records which client
made it — so a build can change its client without invalidating anything.

## The facts that were easy to get wrong

- **Testing status expires refresh tokens after 7 days**, and caps the app at 100
  allowlisted test users. A scheduled Drive backup therefore dies weekly until
  the consent screen is **Published**. Publishing is a button, not a review.
- **`drive.file` is non-sensitive** ([scope table](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)),
  and `email` is a basic identity scope. So a *published but unverified* app has
  **no user cap and no "unverified app" danger screen** — verification is only
  about displaying your name and logo. Sensitive/restricted Drive scopes are the
  ones that drag in review and a security assessment; we never ask for them.
- **The support email on the consent screen is user-facing** — Google's words:
  "a support email address where users can contact you if they have questions
  about their consent". Whoever owns the client has that address shown to whoever
  signs in. The *developer contact* email is only Google → you.
- **Drive access is a checkbox** under granular permissions: a sign-in can
  succeed with it cleared. The token response's `scope` is checked for
  `drive.file` and the sign-in is rejected with a sentence that says so, rather
  than failing later with a bare 403.
- **An installed app's client secret is not confidential** (Google's own guidance
  for installed apps); PKCE protects the exchange. Holding both strings only lets
  someone ask a user to consent to an app that can see the files it creates.
- **Quotas are per project, not per user**: 1,000,000 quota units/minute, and
  **1 TB/day of egress before charges apply** — the one place a shipped client
  could cost its owner money, and only under restores in the thousands.
- **Uploads are streamed** (`uploadFile` builds the `multipart/related` body from
  a file stream; `downloadToFile` streams the other way). A backup is far too
  large to hold in memory twice — see the note in `backup_codec.dart`.

## What only a real account can settle

Whether the browser on a phone follows the `http://127.0.0.1:<port>` redirect
back into the app, and whether the project's Drive API is really enabled. Both
are one connect attempt away from being answered; neither can be checked here.

If the browser lands on Google's `redirect_uri_mismatch` page instead of coming
back, the fix is one word: `DriveClient.loopbackHost` → `'localhost'`. Google
documents `http://127.0.0.1:<port>` as the form for a Desktop client and does not
pin the port, but a project whose stored redirect URI reads `http://localhost`
has been known to disagree.
