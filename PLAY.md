# Publishing PadelZit to Google Play

The Android app is a **Trusted Web Activity (TWA)** — a thin native shell around
the live site at `https://padel.azma.app`. It opens fullscreen with no address
bar and always serves whatever is currently deployed, so **app content updates
need no new release and no store review**. You only ship a new build when the
wrapper itself changes (name, icon, version, target SDK).

Follow these steps in order. Steps 1–2 and 4–7 are done by you in the browser;
step 3 is a button in this repo's Actions tab.

---

## 1. Create the app in Play Console

1. <https://play.google.com/console> → **Create app**.
2. App name: **פאדלז׳יט** · Default language: Hebrew · Type: **App** · **Free**.
3. Accept the declarations, then open **Test and release → Setup → App integrity**
   and confirm **Play App Signing** is enabled (it is on by default — keep it).

Package name (permanent, cannot be changed after publishing):

```
app.azma.padel
```

## 2. Generate the upload key (once)

Play signs the app with its own key; you sign uploads with an *upload key*. Keep
this file safe — losing it means asking Google to reset it.

```sh
keytool -genkey -v -keystore upload.jks -alias padelzit \
  -keyalg RSA -keysize 2048 -validity 9125
```

Then base64 it so it can live in a GitHub secret:

```sh
base64 -w0 upload.jks > upload.jks.b64   # macOS: base64 -i upload.jks -o upload.jks.b64
```

In GitHub → **Settings → Secrets and variables → Actions → New repository
secret**, add all four:

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | contents of `upload.jks.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | the store password you chose above |
| `ANDROID_KEY_ALIAS` | `padelzit` |
| `ANDROID_KEY_PASSWORD` | the key password you chose above |

Store `upload.jks` somewhere safe (password manager / backup) and **never commit
it** — `*.jks` and `*.keystore` are gitignored.

## 3. Build the .aab

GitHub → **Actions** → **Build Android app (TWA)** → **Run workflow**.
Leave the version inputs empty for the first build. When it finishes, download
the **padelzit-android** artifact — it contains:

- `app-release-bundle.aab` → upload this to Play
- `app-release-signed.apk` → for sideload testing on your own phone

For later releases, set **versionCode** to a higher integer than the previous
upload (Play rejects a repeat), and **versionName** to something human like
`1.0.1`.

## 4. Upload to internal testing

Play Console → **Test and release → Testing → Internal testing → Create new
release** → upload the `.aab` → add yourself as a tester → roll out.

Install it from the tester link on a real Android device.

## 5. Remove the address bar (Digital Asset Links)

If the app opens with a URL bar at the top, the ownership proof has not been
matched yet. Fix it:

1. Play Console → **Test and release → Setup → App integrity → App signing**.
2. Copy the **SHA-256 certificate fingerprint** of the *App signing key*
   (not the upload key).
3. Edit [`pwa/.well-known/assetlinks.json`](pwa/.well-known/assetlinks.json) and
   replace `REPLACE_ME_WITH_PLAY_APP_SIGNING_SHA256` with that fingerprint.
4. Commit and push to the deploy branch. The Pages workflow publishes it to
   `https://padel.azma.app/.well-known/assetlinks.json`.
5. Verify it is live and well-formed:
   <https://developers.google.com/digital-asset-links/tools/generator>
6. Fully close and reopen the app (or reinstall). The URL bar should be gone.

> Sideloading the `.apk` before this step will always show a URL bar, because
> the apk is signed with the *upload* key, whose fingerprint isn't listed. To
> test a sideload without a bar, add the upload key's SHA-256 as a second entry
> in the `sha256_cert_fingerprints` array.

## 6. Fill in the store listing

| Field | Value |
|---|---|
| App name | פאדלז׳יט |
| Short description | ניהול טורנירי פאדל אמריקנו ומקסיקנו — 4–12 שחקנים, בלי חישובים |
| Full description | Reuse and expand the copy in [`marketing/`](marketing/) (Hebrew + English) |
| App icon (512×512) | `pwa/icons/icon-512.png` |
| Feature graphic (1024×500) | `marketing/play/feature-graphic.png` |
| Phone screenshots | `marketing/play/screenshot-1-home.png`, `-2-game.png`, `-3-friends.png` |
| Category | Sports |
| Privacy policy URL | `https://padel.azma.app/privacy.html` |

Regenerate the graphics any time the UI changes:

```sh
python3 -m http.server 8000 &
node mock-supabase.js &
node marketing/play/shot-play-assets.js
```

## 7. Content rating & Data safety

**Content rating** — fill the questionnaire; the app has no objectionable
content (a sports scorekeeper).

**Data safety** — declare honestly, matching `privacy.html`:

- **Collected:** email address and display name/nickname (account creation and
  letting friends find you), plus app activity (tournaments, scores, friend
  connections) synced to Supabase.
- Data **is** transmitted off-device (cloud sync) and **is** encrypted in transit.
- Users **can request deletion** — the app has self-serve account + data deletion
  in the account menu.
- **No** advertising, **no** analytics/tracking, **no** data sold or shared with
  third parties.
- Sign-in is optional — the app is fully usable offline with no account.

## 8. Go live

Once internal testing looks right: **Production → Create new release**, promote
the same bundle, complete any remaining Play checklist items, and submit.
First review typically takes a few days.

---

## Notes

- **Which account?** Record the Play Console login in `ACCOUNTS.local.md`
  (gitignored) and mark the row filled in `ACCOUNTS.md`.
- **The old keystore is burned.** The repo previously contained
  `android/puddlezit.keystore` with its password committed in plain text in the
  build script. It was never used on Play and has been deleted — treat it as
  public and never reuse it.
- **Updating the app content** needs nothing here: push to the deploy branch, the
  Pages workflow publishes, and the TWA picks it up on next launch.
