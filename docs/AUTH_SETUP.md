# Twogether — Auth & Pairing setup

Real per-user auth (Supabase Auth) + invite-code partner pairing + Row-Level Security.
Do the steps in order. Items marked **[you]** need the Supabase / Google / Apple
dashboards; **[me]** are code changes I make in `index.html`.

## Architecture

- **Identity**: Supabase Auth. Each person signs in (Apple / Google / email magic-link).
- **Pairing**: Partner A taps *Create* → gets a 6-char **invite code**. Partner B signs in,
  taps *Join*, enters the code → they're bound and the couple **locks** (no 3rd person can join).
- **Security**: RLS means a signed-in user can only read/write *their own couple's* rows,
  enforced by their auth ID — not a guessable name. Closes the current privacy hole.
- Tables + policies + pairing functions live in
  [`supabase/migrations/0001_auth_pairing.sql`](../supabase/migrations/0001_auth_pairing.sql).

## Step 1 — Run the database migrations **[you]**
Supabase Dashboard → **SQL Editor** → New query → run **both**, in order:
1. `supabase/migrations/0001_auth_pairing.sql` — tables, RLS, `create_couple` / `join_couple`.
2. `supabase/migrations/0002_pairing_immutable.sql` — DB triggers making a pairing permanent
   (membership can't be changed/removed; a locked couple can't be unlocked — *one account, one
   partner, for life*).
3. `supabase/migrations/0003_backfill_legacy.sql` — `claim_legacy_history()`, which copies a
   couple's old name-keyed check-ins into the new account schema after they re-pair. The old
   data is preserved untouched in `couples_legacy` / `checkins_legacy`.
4. `supabase/migrations/0004_private_until_reveal.sql` — reveal privacy at the DB layer: a
   partner can't read your answers until they've submitted their own for that week (writing/
   overriding the partner's entry is already blocked by the insert/update policies).

To test without Google/Apple, also turn on **Authentication → Providers → Anonymous sign-ins**,
then open the app at `?dev=1` and use the lime **Continue as guest** button.

## Step 2 — Turn on Email auth (works immediately, no extra accounts) **[you]**
Dashboard → **Authentication → Providers → Email** → enable. Enable "magic link".
This lets us build and test the whole flow before Google/Apple are configured.

## Step 3 — Google sign-in **[you]** (has lead time — start early)
1. [Google Cloud Console](https://console.cloud.google.com/) → create a project →
   **APIs & Services → Credentials → Create OAuth client ID → Web application**.
2. Authorized redirect URI: `https://kpzeahhwldycfgaxlvsx.supabase.co/auth/v1/callback`
3. Copy the **Client ID** + **Client secret** → Supabase → **Authentication → Providers →
   Google** → paste → enable.

## Step 4 — Sign in with Apple **[you]** (needs the Apple Developer account)
> ⚠️ App Store **Guideline 4.8**: because we offer Google, we **must** also offer Sign in
> with Apple. This requires your paid Apple Developer account (the one you're enrolling in),
> so it comes after enrollment. We can develop with Google + email first and add Apple
> before submission.
1. Apple Developer → **Certificates, IDs & Profiles** → create a **Services ID**, enable
   "Sign in with Apple", set return URL to the Supabase callback above.
2. Create a **Sign in with Apple key (.p8)**, note the Key ID + Team ID.
3. Supabase → **Authentication → Providers → Apple** → fill in Services ID, Team ID, Key ID,
   and the key → enable.

## Step 5 — Redirect handling for the iOS app **[you+me]**
OAuth opens a browser and must return to the app. We use the custom scheme
`space.twogether.app://auth-callback`.
- **[you]** Add that URL to Supabase → **Authentication → URL Configuration → Redirect URLs**
  (also add `https://twogether.space` for the web build).
- **[me]** Register the URL scheme in the iOS project + a Capacitor `appUrlOpen` listener that
  completes the session.

## Step 6 — Client rewrite **[me]**
- Add Supabase Auth (sign-in screen: Apple / Google / email).
- Replace the "type two names" setup with **Create / Join (invite code)** + the locked state.
- Rewrite the data layer to send the signed-in user's access token (so RLS applies) and call
  `create_couple` / `join_couple`. Check-ins keyed by the real `couple_id` (uuid).

## Cutover note
The live site (twogether.space) auto-deploys from `main`. The new client and the new schema
must go live together — so we'll develop/test, then deploy the index.html change and run the
migration in one coordinated cutover. Old prototype data is disposable.
