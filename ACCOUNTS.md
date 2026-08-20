# Accounts & services

Which external service this project uses, and which personal account it's tied to.
Kept intentionally **redacted** — this repo is public, so exact login emails are
never committed here. The full version (real emails) lives in `ACCOUNTS.local.md`
on the maintainer's machine, which is gitignored and never pushed.

**Whenever a new service is added, update BOTH `ACCOUNTS.md` (here, redacted) and
`ACCOUNTS.local.md` (local only, full details) together.**

| Service | Used for | Account / handle | Login | Notes |
|---|---|---|---|---|
| GitHub | Source repo, GitHub Actions, Pages hosting | `AzMaVeZe` | owner's personal Gmail | Repo: `AzMaVeZe/PadelZit` (public). Deploys from branch `claude/puddle-game-scoring-9e3hvi`. |
| Domain registrar | DNS for `azma.app` / `padel.azma.app` | GoDaddy account | owner's personal Gmail | `CNAME` record points `padel.azma.app` at GitHub Pages. |
| Supabase | Cloud backend: auth, Postgres, RLS/RPCs (`cloud/setup.sql`) | Org "AzMaVeZe's Org" (`pvudwkmqgftdonrmycnw`), project "PadelZit" (`axrugdszycwmadbdwolx`), region eu-central-2, free plan | TBD — confirm | Likely the same GitHub-linked identity as above (unconfirmed — Supabase's API doesn't expose a billing/owner email). |
| Google OAuth | "Continue with Google" sign-in (Google Cloud Console OAuth client, wired into Supabase Auth) | TBD — confirm | TBD — confirm | |
| Facebook OAuth | "Continue with Facebook" sign-in (Meta for Developers app, wired into Supabase Auth) | TBD — confirm | TBD — confirm | |
| Google Play Console | Planned: publishing the Android app (Trusted Web Activity) | TBD — confirm | TBD — confirm | Not yet published; see the TWA plan when it ships. |
| WhatsApp | *(not an account)* Share links use the public `wa.me/?text=...` URL format | — | — | No login involved; listed only so it isn't mistaken for a tracked account. |
