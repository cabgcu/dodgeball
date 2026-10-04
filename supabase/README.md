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

## Confirmation emails (Brevo)

When someone signs up, they get an email with what they signed up for:

- **New team:** the captain gets the team name, the team code, the share link and how to use "Manage
  My Team". Teammates the captain listed by email get an invite with the code to confirm their spot.
- **Joining a team:** the player gets the team name, code and share link.
- **Waitlist:** the player gets their place in line.

The database sends them itself through Supabase's `pg_net` extension, using the same Brevo account as
Commuter Life. There's no edge function to deploy. An email is only sent after the signup is saved,
so a failed signup never sends one, and if Brevo is down or not set up, signups still go through.

To turn it on, run this once in a new SQL query, using the Brevo API key (`xkeysib-…`) and the
address of the sign-up page:

```sql
select app_private.configure_email('xkeysib-…', 'https://your-site/dodgeball/');
```

Emails come from `noreply@cabgcu.com` ("Dodgeball After Dark"). That sender has to be verified in
Brevo. It already is if Commuter Life's emails work. To change it, edit the one row in
`app_private.email_config`. To turn emails off, run `select app_private.configure_email(null);`.

The When / Where box and the event description in every email come from `app_private.email_config`.
Change them there when the details change (they're HTML, so `&bull;` and `&amp;` work):

```sql
update app_private.email_config set
  event_when  = 'Oct 20, 2026 &nbsp;&bull;&nbsp; 8:00 PM - 10:00 PM',
  event_where = 'LPC',
  event_blurb = 'Compete in a high stakes glow in the dark dodgeball tournament with exciting prizes!'
where id = 1;
```

To see whether emails went out, look at the last few Brevo responses (pg_net keeps them for 6 hours):

```sql
select created, status_code, content from net._http_response order by created desc limit 20;
```

Problems queuing an email are logged in `event_log` as `email:error`.

> The key lives only in `app_private.email_config`, which the site can't read. Never put it in `index.html`.

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
- Team names with profanity, slurs or sexual terms are refused at sign-up (`app_private.is_inappropriate`,
  which also catches l33t and spaced-out spellings). Admins can rename any team from the dashboard,
  and can add words to the lists in that function if something slips through.
- Every player needs a student ID, including teammates a captain lists on the create form. Those
  listed players show as unconfirmed until they sign up themselves with the team code.

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

## Editing the bracket

The bracket lays itself out in sign-up order and follows new teams until the first result is recorded.
To arrange it yourself, click **Edit Bracket** on the admin Overview tab. Every open spot becomes a
dropdown. Picking a team that's already in another open spot swaps the two, and teams that aren't in
the bracket yet (say, ones that signed up after play started) are marked "not in bracket" so you can
drop them into an empty spot. Spots that are already decided are locked until you undo that result.

Once you've edited it by hand, new teams are no longer added automatically. **Reset Bracket** clears
all results and goes back to the automatic layout.

## Looking at or editing data by hand

Supabase ▸ **Table Editor**, then switch the schema dropdown from `public` to `app_private`:

| Table | What's in it |
|---|---|
| `teams` | name, team code, eliminated |
| `players` | everyone; an empty `team_id` means they're on the waitlist |
| `matches` | bracket slots and winners (`round` and `pos` start at 0) |
| `settings` | registration / waitlist open, team sizes |
| `timers` | the three court clocks |
| `email_config` | Brevo key, sender, site link and event details for confirmation emails |
| `event_log` | everything that happened, including errors |

Rosters can be exported as CSV from the Table Editor.
