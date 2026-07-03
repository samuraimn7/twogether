# Twogether

A private weekly check-in for couples. Each partner answers the same prompts on
their own; answers unlock **only when both have submitted**. Live at
**[twogether.space](https://twogether.space)** (also being packaged for the iOS App Store).

- **Brand:** black `#0C0C0E` · white · lime `#E8FF6B`
- **App icon:** infinity + lime plus — source in [`assets/icon.svg`](assets/icon.svg)

---

## Architecture

- **Frontend:** a single self-contained file, [`index.html`](index.html) (vanilla JS,
  no build step). Loads `@supabase/supabase-js` from CDN.
- **Backend:** Supabase (Postgres + Auth + Storage), project ref `kpzeahhwldycfgaxlvsx`.
- **Web hosting:** Vercel, auto-deploys from `main`. `vercel.json` keeps it static.
- **iOS:** Capacitor wrapper (`ios/`), bundle id `space.twogether.app`. The web app is
  bundled locally into the native shell.

## How pairing & privacy work

- **Auth = account identity.** Sign in with **email magic-link** or **Google** (live);
  **Apple** in progress. No passwords.
- **Pairing:** one partner *creates* a space → gets a 6-char invite code → the other
  *joins* with it. Then the couple **locks**.
- **Permanent:** one account = one partner, for life — enforced in the app, in RLS, and
  by DB triggers (membership can't be changed/removed; a locked couple can't unlock).
- **Reveal privacy:** Row-Level Security means a partner cannot read your answers until
  they've submitted their own for that week. Nobody else can read a couple's data.

## Features

- Weekly **lobby** showing both partners' status (Done ✓ / Not yet), only your row tappable
- **Check-in** form (7 prompts; Q1 retired but still shown in history)
- **Save & finish later** drafts (localStorage, one per couple+partner, survives week rollover)
- **Photo** per check-in (1, private Supabase Storage, shown in Reveal + Archive)
- **Reveal** (side-by-side, gated until both submit) and **Archive** (grouped by person)
- **Match** celebration when a partner joins
- **↺ Redo my check-in** button (clears the current week via `reset_my_week`)
- **Dev:** `?dev` shows a guest button; `?mock` is a full offline sandbox (no auth/backend)

---

## Supabase setup (one-time, run in the SQL editor)

Run in order — see [`supabase/migrations/`](supabase/migrations/):

1. `0001_auth_pairing.sql` — tables, RLS, `create_couple` / `join_couple`
2. `0002_pairing_immutable.sql` — permanence triggers
3. `0003_backfill_legacy.sql` — `claim_legacy_history()` (legacy import; not auto-run)
4. `0004_private_until_reveal.sql` — reveal privacy read policy + `i_submitted()`
5. `0005_week_status.sql` — `week_status()` for the lobby
6. `0006_photo_storage.sql` — creates the private `checkin-photos` bucket + policies

Plus `reset_my_week(text)` — powers the Redo button (deletes the caller's own week).

**Providers:** Auth → Providers → enable **Email** + **Google** (+ **Apple** when ready).
**URL config:** Site URL `https://twogether.space`, Redirect URLs include `https://twogether.space/**`.
Provider visibility in the app is gated by the `PROVIDERS` flag in `index.html`.

## Develop & deploy

```bash
npm install
npm run build:web          # copies index.html -> www/ (what Capacitor bundles)
python3 -m http.server 8000 --directory .   # local test at http://localhost:8000/index.html
#   ?mock  = offline sandbox (skip auth)   ·   ?dev = guest sign-in button
```

Deploy the website by pushing `index.html` to `main` (Vercel picks it up).

iOS build (needs full Xcode + CocoaPods):
```bash
npm run ios                # build:web + cap sync + open Xcode
```

## iOS / App Store status

- ✅ Capacitor project, final icon + splash generated into the Xcode asset catalog
- ✅ OAuth deep-link code on branch `feature/ios-oauth` (`space.twogether.app://auth-callback`)
- ✅ Listing assets ready: screenshots in [`appstore/`](appstore/), privacy page at
  `twogether.space/privacy.html`, copy drafted
- ⏳ **Remaining (manual):** install full Xcode; finish **Sign in with Apple** (Services ID
  `space.twogether.signin`, secret generated locally from the `.p8`) → Supabase Apple
  provider; then merge branch → `pod install` → archive → submit.

## Repo layout

```
index.html                 the entire web app
assets/                    icon + splash sources (SVG/PNG)
appstore/                  App Store screenshots (1290×2796)
privacy.html               privacy policy (served at /privacy.html)
supabase/migrations/       DB schema, RLS, functions, storage
ios/                       Capacitor iOS project
docs/AUTH_SETUP.md         auth/provider setup notes
capacitor.config.json      appId space.twogether.app
vercel.json                keep the site static
```
