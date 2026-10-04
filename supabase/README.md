# Supabase backend

`schema.sql` is the whole backend: tables, security rules and the API, written as Postgres functions.
The site (`index.html`) calls one function, `dodgeball_api`, with the project's **publishable** key.

## Setup (one time, about 2 minutes)

1. Open the project in Supabase ▸ **SQL Editor** ▸ **New query**.
2. Paste in all of `schema.sql` and click **Run**. It is safe to run again after an update. It replaces
   the functions and adds anything missing, and it never deletes data.
3. Change the admin password (the default is the old one) in a new SQL query:

   ```sql
   select app_private.set_admin_password('your-new-password');
   ```

   This also signs out every admin session.

That's it. `SUPABASE_URL` and `SUPABASE_KEY` (publishable) are already set near the top of the main
`<script>` in `index.html`.

> **Never put the secret key (`sb_secret_…`) in `index.html` or this repo.** The site doesn't need it.

## How it's secured

- All data lives in the `app_private` schema. The public API doesn't expose that schema, so the site
  can't read or edit tables directly.
- `dodgeball_api` decides what each caller gets. Visitors only see team names, player counts, the
  bracket and the timers. Admin sessions (from logging in with the password) also get the rosters,
  emails, student IDs and phones. "Manage My Team" with a team code shows that team's roster with
  emails and IDs partly hidden.
- Writes run one at a time behind a lock. A team can never go over the size limit, and an email or
  student ID can't be registered twice, even when hundreds of people submit at once.
- After 10 wrong admin passwords, logins pause for 10 minutes.

## Live updates

The public table `state_version` holds only a counter. Triggers bump it when anything viewers can
see changes, and every open page listens for that over Supabase Realtime and then refreshes. Check-in
toggles don't bump it, because only admins see check-ins. If Realtime isn't available, a page checks
for changes every 15 seconds on its own (every 10 seconds on the admin dashboard).

Plan limits worth knowing for a 200–500 person event:

- **Realtime connections:** 200 at once on the Free plan, 500 on Pro. Viewers over the limit fall
  back to the 15-second refresh, so nothing breaks.
- **Free projects pause after a week with no activity.** Open the dashboard or the site in the days
  before the event (or use Pro) so it isn't paused on game night.

## Looking at or editing data by hand

Supabase ▸ **Table Editor**, then switch the schema dropdown from `public` to `app_private`:

| Table | What's in it |
|---|---|
| `teams` | name, team code, eliminated |
| `players` | everyone; an empty `team_id` means they're on the waitlist |
| `matches` | bracket slots and winners (`round` and `pos` start at 0) |
| `settings` | registration / waitlist open, team sizes |
| `timers` | the three court clocks |
| `event_log` | everything that happened, including errors |

Rosters can be exported as CSV from the Table Editor.
