-- =============================================================================
--  DODGEBALL AFTER DARK — Supabase backend
-- =============================================================================
--  Paste this whole file into Supabase ▸ SQL Editor ▸ New query, and click Run.
--  It is safe to run again after edits: it creates what's missing and replaces
--  every function, without touching existing data.
--
--  Note: Supabase runs API requests with `safeupdate`, which rejects any UPDATE or
--  DELETE without a WHERE clause. Every such statement here has one (even `where true`).
--
--  Design
--   • All tables live in the `app_private` schema, which the public API does not
--     expose. The site can't read or write them directly.
--   • The site calls exactly one function, public.dodgeball_api(action, payload,
--     token), using the publishable key. It checks the admin token, serialises
--     writes with an advisory lock, and returns { ok, error?, code?, state, ... }.
--   • public.state_version is the only public table. Triggers bump it whenever
--     something viewers can see changes, and the site listens for that over
--     Realtime instead of polling every few seconds.
--
--  Admin password (default: Cabgcu49!) — change it in the SQL editor:
--     select app_private.set_admin_password('your-new-password');
-- =============================================================================

create extension if not exists pgcrypto with schema extensions;
-- pg_net sends the confirmation emails (HTTP calls to Brevo) after the transaction commits.
do $$ begin
  create extension if not exists pg_net;
exception when others then
  raise notice 'pg_net is not available, so confirmation emails are off: %', sqlerrm;
end $$;

create schema if not exists app_private;
revoke all on schema app_private from public;
do $$ begin
  revoke all on schema app_private from anon, authenticated;
exception when undefined_object then null;
end $$;

-- ---------------------------------------------------------------------------
--  Small helpers needed by table defaults
-- ---------------------------------------------------------------------------

create or replace function app_private.new_id(prefix text) returns text
language sql volatile as $$
  select prefix || '-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
$$;

create or replace function app_private.now_ms() returns bigint
language sql volatile as $$
  select (extract(epoch from clock_timestamp()) * 1000)::bigint;
$$;

-- ---------------------------------------------------------------------------
--  Tables
-- ---------------------------------------------------------------------------

create table if not exists app_private.settings (
  id                 int primary key default 1 check (id = 1),
  registration_open  boolean not null default true,
  waitlist_open      boolean not null default false,
  max_team_size      int not null default 10 check (max_team_size between 1 and 50),
  waitlist_team_size int not null default 6  check (waitlist_team_size between 1 and 50)
);
insert into app_private.settings default values on conflict do nothing;

create table if not exists app_private.teams (
  id          text primary key default app_private.new_id('T'),
  seq         bigint generated always as identity,
  name        text not null,
  code        text not null unique,
  eliminated  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists teams_name_ci on app_private.teams (lower(name));

-- team_id null = on the waitlist (free agent).
create table if not exists app_private.players (
  id          text primary key default app_private.new_id('P'),
  seq         bigint generated always as identity,
  team_id     text references app_private.teams (id) on delete cascade,
  name        text not null,
  email       text not null default '',
  phone       text not null default '',
  student_id  text not null default '',
  role        text not null default 'Player' check (role in ('Captain', 'Player', 'Alternate')),
  checked_in  boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists players_email_ci on app_private.players (lower(email)) where email <> '';
create index if not exists players_team on app_private.players (team_id);

-- Single-elimination layout. The last round holds one "match" whose team1 is the champion.
create table if not exists app_private.matches (
  round       int not null,
  pos         int not null,
  team1_id    text references app_private.teams (id) on delete set null,
  team2_id    text references app_private.teams (id) on delete set null,
  winner_id   text references app_private.teams (id) on delete set null,
  updated_at  timestamptz not null default now(),
  primary key (round, pos)
);

create table if not exists app_private.timers (
  idx                int primary key,
  court              text not null,
  default_seconds    int not null default 600,
  remaining_seconds  numeric not null default 600,
  running            boolean not null default false,
  started_at         bigint,           -- ms since epoch while running
  updated_at         timestamptz not null default now()
);
insert into app_private.timers (idx, court) values (0, 'Court 1'), (1, 'Court 2'), (2, 'Court 3')
on conflict do nothing;

-- Who was checked in before a team advanced, so an undo can restore it.
create table if not exists app_private.checkin_snapshots (
  match_key   text primary key,
  player_ids  text[] not null default '{}'
);

create table if not exists app_private.admin_config (
  id              int primary key default 1 check (id = 1),
  password_hash   text not null,
  login_failures  int not null default 0,
  locked_until    timestamptz
);
insert into app_private.admin_config (password_hash)
values (extensions.crypt('Cabgcu49!', extensions.gen_salt('bf')))
on conflict do nothing;

create table if not exists app_private.admin_sessions (
  token       text primary key,
  expires_at  timestamptz not null
);

-- Confirmation emails (Brevo). Off until brevo_api_key is set. See supabase/README.md.
create table if not exists app_private.email_config (
  id             int primary key default 1 check (id = 1),
  brevo_api_key  text,
  sender_email   text not null default 'noreply@cabgcu.com',
  sender_name    text not null default 'Dodgeball After Dark',
  site_url       text   -- the sign-up page; share links in emails point here
);
alter table app_private.email_config add column if not exists event_when  text not null default 'Oct 20, 2026 &nbsp;&bull;&nbsp; 8:00 PM - 10:00 PM';
alter table app_private.email_config add column if not exists event_where text not null default 'LPC';
alter table app_private.email_config add column if not exists event_blurb text not null default 'Compete in a high stakes glow in the dark dodgeball tournament with exciting prizes!';
insert into app_private.email_config default values on conflict do nothing;

create table if not exists app_private.event_log (
  id       bigint generated always as identity primary key,
  at       timestamptz not null default now(),
  action   text not null,
  details  text not null default '',
  source   text not null default 'web'
);

alter table app_private.settings          enable row level security;
alter table app_private.teams             enable row level security;
alter table app_private.players           enable row level security;
alter table app_private.matches           enable row level security;
alter table app_private.timers            enable row level security;
alter table app_private.checkin_snapshots enable row level security;
alter table app_private.admin_config      enable row level security;
alter table app_private.admin_sessions    enable row level security;
alter table app_private.email_config      enable row level security;
alter table app_private.event_log         enable row level security;

-- Public change signal for Realtime (contains no data, just a counter).
create table if not exists public.state_version (
  id          int primary key default 1 check (id = 1),
  version     bigint not null default 0,
  updated_at  timestamptz not null default now()
);
insert into public.state_version default values on conflict do nothing;
alter table public.state_version enable row level security;
drop policy if exists "anyone can read the version" on public.state_version;
create policy "anyone can read the version" on public.state_version for select using (true);
do $$ begin
  revoke insert, update, delete, truncate on public.state_version from anon, authenticated;
  grant select on public.state_version to anon, authenticated;
exception when undefined_object then null;
end $$;
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'state_version') then
    alter publication supabase_realtime add table public.state_version;
  end if;
end $$;

create or replace function app_private.bump_state_version() returns trigger
language plpgsql security definer set search_path = app_private, public as $$
begin
  update public.state_version set version = version + 1, updated_at = now() where id = 1;
  return null;
end $$;

drop trigger if exists bump_version on app_private.teams;
create trigger bump_version after insert or update or delete on app_private.teams
  for each statement execute function app_private.bump_state_version();
drop trigger if exists bump_version on app_private.matches;
create trigger bump_version after insert or update or delete on app_private.matches
  for each statement execute function app_private.bump_state_version();
drop trigger if exists bump_version on app_private.timers;
create trigger bump_version after insert or update or delete on app_private.timers
  for each statement execute function app_private.bump_state_version();
drop trigger if exists bump_version on app_private.settings;
create trigger bump_version after update on app_private.settings
  for each statement execute function app_private.bump_state_version();
-- Player counts are public; check-ins are not, so check-in toggles don't wake every viewer.
drop trigger if exists bump_version on app_private.players;
drop trigger if exists bump_version_ins_del on app_private.players;
create trigger bump_version_ins_del after insert or delete on app_private.players
  for each statement execute function app_private.bump_state_version();
drop trigger if exists bump_version_team on app_private.players;
create trigger bump_version_team after update of team_id on app_private.players
  for each statement execute function app_private.bump_state_version();

-- ---------------------------------------------------------------------------
--  Utilities
-- ---------------------------------------------------------------------------

-- Expected errors: message is shown to the user. errcode DB401 = auth problem.
create or replace function app_private.fail(msg text, code text default 'P0001') returns void
language plpgsql as $$
begin
  raise exception using message = msg, errcode = code;
end $$;

create or replace function app_private.log(p_action text, p_details text, p_source text default 'web') returns void
language sql as $$
  insert into app_private.event_log (action, details, source) values (p_action, left(coalesce(p_details, ''), 2000), p_source);
$$;

create or replace function app_private.clean_text(v text, max_len int default 100) returns text
language sql immutable as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(v, ''), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g')), max_len);
$$;

create or replace function app_private.clean_email(v text) returns text
language sql immutable as $$
  select lower(app_private.clean_text(v, 120));
$$;

create or replace function app_private.is_email(v text) returns boolean
language sql immutable as $$
  select v ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$';
$$;

create or replace function app_private.mask_email(v text) returns text
language sql immutable as $$
  select case
    when coalesce(v, '') = '' then ''
    when position('@' in v) < 2 then '••••••'
    else left(v, 1) || '•••••' || substr(v, position('@' in v))
  end;
$$;

create or replace function app_private.mask_id(v text) returns text
language sql immutable as $$
  select case when coalesce(v, '') = '' then '' else '•••••' || case when length(v) > 4 then right(v, 2) else '' end end;
$$;

create or replace function app_private.unique_team_code(requested text default null) returns text
language plpgsql as $$
declare
  req text := upper(btrim(coalesce(requested, '')));
  chars constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  v_code text;
begin
  if req ~ '^[A-Z0-9]{4,10}$' and not exists (select 1 from app_private.teams where upper(teams.code) = req) then
    return req;
  end if;
  loop
    select string_agg(substr(chars, 1 + floor(random() * length(chars))::int, 1), '') into v_code from generate_series(1, 6);
    exit when not exists (select 1 from app_private.teams where upper(teams.code) = v_code);
  end loop;
  return v_code;
end $$;

create or replace function app_private.unique_team_name(base text) returns text
language plpgsql as $$
declare n int := 1;
begin
  while exists (select 1 from app_private.teams where lower(name) = lower(base || ' ' || n)) loop
    n := n + 1;
  end loop;
  return base || ' ' || n;
end $$;

create or replace function app_private.settings_row() returns app_private.settings
language sql stable as $$ select * from app_private.settings where id = 1; $$;

-- ---------------------------------------------------------------------------
--  Bracket
-- ---------------------------------------------------------------------------

create or replace function app_private.bracket_started() returns boolean
language sql stable as $$ select exists (select 1 from app_private.matches where winner_id is not null); $$;

create or replace function app_private.num_rounds() returns int
language sql stable as $$ select coalesce(max(round) + 1, 0) from app_private.matches; $$;

create or replace function app_private.bracket_label(r int, num int) returns text
language sql immutable as $$
  select case when r = num - 1 then 'Champion' when r = num - 2 then 'Finals' else 'Round ' || (r + 1) end;
$$;

/**
 * Fresh layout in sign-up order. Every first-round match gets one team before
 * any gets a second, so open slots are spread out and no match is empty on both sides.
 */
create or replace function app_private.rebuild_bracket() returns void
language plpgsql as $$
declare
  n int;
  k int := 0;
  num int;
  first_count int;
  cnt int;
begin
  select count(*) into n from app_private.teams;
  while (1 << k) < greatest(2, n) loop k := k + 1; end loop;
  num := k + 1;
  first_count := 1 << (num - 2);

  delete from app_private.matches where true;
  for r in 0 .. num - 1 loop
    cnt := case when r = num - 1 then 1 else 1 << (num - r - 2) end;
    insert into app_private.matches (round, pos) select r, g from generate_series(0, cnt - 1) g;
  end loop;

  with ordered as (select id, (row_number() over (order by seq)) - 1 as i from app_private.teams)
  update app_private.matches m set team1_id = o.id from ordered o where m.round = 0 and o.i < first_count and m.pos = o.i;
  with ordered as (select id, (row_number() over (order by seq)) - 1 as i from app_private.teams)
  update app_private.matches m set team2_id = o.id from ordered o where m.round = 0 and o.i >= first_count and o.i < 2 * first_count and m.pos = o.i - first_count;
end $$;

/** Keep the layout in step with the teams until the first result is recorded. */
create or replace function app_private.sync_bracket() returns void
language plpgsql as $$
begin
  if not app_private.bracket_started() then perform app_private.rebuild_bracket(); end if;
end $$;

create or replace function app_private.subtree_has_teams(r int, m int) returns boolean
language plpgsql stable as $$
declare mt app_private.matches;
begin
  select * into mt from app_private.matches where round = r and pos = m;
  if not found then return false; end if;
  if mt.team1_id is not null or mt.team2_id is not null then return true; end if;
  if r = 0 then return false; end if;
  return app_private.subtree_has_teams(r - 1, 2 * m) or app_private.subtree_has_teams(r - 1, 2 * m + 1);
end $$;

/** True while a slot is still waiting on an undecided match that has teams in it (shown as "TBD"). */
create or replace function app_private.slot_pending(r int, m int, slot int) returns boolean
language plpgsql stable as $$
declare feeder app_private.matches; fm int := 2 * m + slot - 1;
begin
  if r = 0 then return false; end if;
  select * into feeder from app_private.matches where round = r - 1 and pos = fm;
  if not found then return false; end if;
  return feeder.winner_id is null and app_private.subtree_has_teams(r - 1, fm);
end $$;

create or replace function app_private.get_bracket() returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(arr order by round), '[]'::jsonb) from (
    select round, jsonb_agg(jsonb_build_object(
      'round', round, 'pos', pos,
      'team1Id', coalesce(team1_id, ''), 'team2Id', coalesce(team2_id, ''), 'winnerId', coalesce(winner_id, '')
    ) order by pos) as arr
    from app_private.matches group by round
  ) r;
$$;

-- ---------------------------------------------------------------------------
--  State (what the site renders)
-- ---------------------------------------------------------------------------

create or replace function app_private.player_out(p app_private.players) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'playerId', p.id, 'name', p.name, 'email', p.email, 'phone', p.phone,
    'studentId', p.student_id, 'role', p.role, 'checkedIn', p.checked_in
  );
$$;

create or replace function app_private.timer_remaining(t app_private.timers, now_ms bigint) returns numeric
language sql immutable as $$
  select case when not t.running or t.started_at is null then t.remaining_seconds
              else t.remaining_seconds - (now_ms - t.started_at) / 1000.0 end;
$$;

create or replace function app_private.get_timers() returns jsonb
language sql stable as $$
  with now as (select app_private.now_ms() as ms)
  select coalesce(jsonb_agg(jsonb_build_object(
    'name', t.court,
    'defaultTime', t.default_seconds,
    'timeRemaining', ceil(greatest(0, app_private.timer_remaining(t, now.ms))),
    'isRunning', t.running and app_private.timer_remaining(t, now.ms) > 0,
    -- When the clock hits zero (ms); kept after it finishes so clients can fire the alert.
    'endsAt', case when t.running and t.started_at is not null then t.started_at + (t.remaining_seconds * 1000)::bigint end
  ) order by t.idx), '[]'::jsonb)
  from app_private.timers t, now;
$$;

create or replace function app_private.build_state(is_admin boolean) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'isAdmin', is_admin,
    'serverTime', app_private.now_ms(),
    'settings', (select jsonb_build_object(
        'registrationOpen', s.registration_open, 'waitlistOpen', s.waitlist_open,
        'maxTeamSize', s.max_team_size, 'waitlistTeamSize', s.waitlist_team_size)
      from app_private.settings s where s.id = 1),
    'teams', coalesce((
      select jsonb_agg(
        jsonb_build_object('id', t.id, 'name', t.name, 'eliminated', t.eliminated,
          'playerCount', (select count(*) from app_private.players p where p.team_id = t.id))
        || case when is_admin then jsonb_build_object(
             'code', t.code,
             'players', coalesce((select jsonb_agg(app_private.player_out(p) order by p.seq)
                                  from app_private.players p where p.team_id = t.id), '[]'::jsonb))
           else '{}'::jsonb end
        order by t.seq)
      from app_private.teams t), '[]'::jsonb),
    'waitlistCount', (select count(*) from app_private.players where team_id is null),
    'bracket', app_private.get_bracket(),
    'timers', app_private.get_timers()
  ) || case when is_admin then jsonb_build_object(
    'waitlist', coalesce((select jsonb_agg(app_private.player_out(p) order by p.created_at, p.seq)
                          from app_private.players p where p.team_id is null), '[]'::jsonb))
  else '{}'::jsonb end;
$$;

-- ---------------------------------------------------------------------------
--  Confirmation emails (Brevo, sent through pg_net)
-- ---------------------------------------------------------------------------

/** One-time setup from the SQL editor: select app_private.configure_email('xkeysib-…', 'https://…/'); */
create or replace function app_private.configure_email(api_key text, site_url text default null) returns text
language plpgsql as $$
begin
  update app_private.email_config set
    brevo_api_key = nullif(btrim(coalesce(api_key, '')), ''),
    site_url = coalesce(nullif(btrim(coalesce(configure_email.site_url, '')), ''), email_config.site_url)
  where id = 1;
  return case when nullif(btrim(coalesce(api_key, '')), '') is null then 'Confirmation emails are off.' else 'Confirmation emails are on.' end;
end $$;

create or replace function app_private.html(v text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(v, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;'), '''', '&#39;');
$$;

/** The share link for a team, or null when site_url isn't configured. */
create or replace function app_private.join_link(p_code text) returns text
language sql stable as $$
  select case when coalesce(site_url, '') = '' then null
    else site_url || '?join=' || p_code end
  from app_private.email_config where id = 1;
$$;

/**
 * The branded email. intro and body_html are already escaped (<b> is styled as white bold text);
 * rows are [label, value] pairs and are escaped here. event_when/where/blurb come from email_config
 * and are HTML, so entities like &bull; work there.
 */
create or replace function app_private.email_html(heading text, intro text, rows jsonb, body_html text default '', button_label text default null, button_url text default null)
returns text
language plpgsql stable as $$
declare
  cfg app_private.email_config;
  r jsonb;
  cells text[] := '{}';
  rows_html text := '';
  i int;
  border text;
  val text;
  styled_intro text := replace(replace(coalesce(intro, ''), '<b>', '<strong style="color: #FFFFFF;">'), '</b>', '</strong>');
  styled_body text := replace(replace(coalesce(body_html, ''), '<b>', '<strong style="color: #E3E5E8;">'), '</b>', '</strong>');
begin
  select * into cfg from app_private.email_config where id = 1;

  for r in select * from jsonb_array_elements(coalesce(rows, '[]'::jsonb)) loop
    continue when coalesce(r->>1, '') = '';
    val := case r->>0
      when 'Team code' then '<span style="background-color: #3F1D1D; color: #FF5E5E; font-weight: bold; font-size: 16px; letter-spacing: 2.5px; padding: 6px 12px; border-radius: 6px; display: inline-block;">' || app_private.html(r->>1) || '</span>'
      when 'Share link' then '<a href="' || app_private.html(r->>1) || '" style="color: #4793FF; text-decoration: none; font-weight: 500;">' || app_private.html(r->>1) || '</a>'
      else app_private.html(r->>1) end;
    cells := cells || array[app_private.html(r->>0), val, r->>0];
  end loop;
  for i in 0 .. (coalesce(array_length(cells, 1), 0) / 3) - 1 loop
    border := case when (i + 1) * 3 < array_length(cells, 1) then ' border-bottom: 1px solid #1E1F22;' else '' end;
    rows_html := rows_html || '<tr><td align="left" width="30%" style="padding: 18px 20px; color: #949BA4; font-size: 15px;' || border || '">' || cells[i * 3 + 1] || '</td>'
      || '<td align="right" width="70%" style="padding: 18px 20px; '
      || case cells[i * 3 + 3]
           when 'Share link' then 'font-size: 14px; word-break: break-all;'
           when 'Team code' then ''
           else 'color: #FFFFFF; font-weight: 600; font-size: 15px;' end
      || border || '">' || cells[i * 3 + 2] || '</td></tr>';
  end loop;

  return '<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">'
    || '<title>' || app_private.html(heading) || '</title><style>'
    || 'body, table, td, a { -webkit-text-size-adjust: 100%; -ms-text-size-adjust: 100%; } '
    || 'table, td { mso-table-lspace: 0pt; mso-table-rspace: 0pt; } '
    || 'img { -ms-interpolation-mode: bicubic; border: 0; height: auto; line-height: 100%; outline: none; text-decoration: none; } '
    || 'table { border-collapse: collapse !important; } '
    || 'body { height: 100% !important; margin: 0 !important; padding: 0 !important; width: 100% !important; background-color: #2C2F33; }'
    || '</style></head>'
    || '<body style="background-color: #2C2F33; margin: 0; padding: 0; font-family: ''Inter'', -apple-system, BlinkMacSystemFont, ''Segoe UI'', Roboto, Helvetica, Arial, sans-serif;">'
    || '<table border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color: #2C2F33; padding: 40px 20px;"><tr><td align="center">'
    || '<table border="0" cellpadding="0" cellspacing="0" width="100%" style="max-width: 600px; background-color: #18191C; border-radius: 12px; overflow: hidden; box-shadow: 0 10px 25px rgba(0,0,0,0.4);">'
    || '<tr><td align="center" style="background-color: #18191C;"><img src="https://i.imgur.com/qDkdmGO.jpeg" alt="Dodgeball After Dark Header" width="600" style="display: block; width: 100%; max-width: 600px; border: 0;"></td></tr>'
    || '<tr><td align="left" style="padding: 40px 35px;">'
    || '<p style="margin: 0 0 10px 0; color: #E3E5E8; font-size: 16px; line-height: 1.6;">' || styled_intro || '</p>'
    || '<p style="margin: 0 0 30px 0; color: #949BA4; font-size: 15px; line-height: 1.6;">' || cfg.event_blurb || '</p>'
    || '<table border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color: #2B2D31; border-radius: 10px; margin-bottom: 20px; overflow: hidden;">'
    || '<tr><td align="left" style="padding: 18px 20px; border-bottom: 1px solid #1E1F22;"><div style="color: #949BA4; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 4px; font-weight: 600;">When</div>'
    || '<div style="color: #FFFFFF; font-size: 15px; font-weight: 500;">' || cfg.event_when || '</div></td></tr>'
    || '<tr><td align="left" style="padding: 18px 20px;"><div style="color: #949BA4; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 4px; font-weight: 600;">Where</div>'
    || '<div style="color: #FFFFFF; font-size: 15px; font-weight: 500;">' || cfg.event_where || '</div></td></tr></table>'
    || case when rows_html <> '' then '<table border="0" cellpadding="0" cellspacing="0" width="100%" style="background-color: #2B2D31; border-radius: 10px; margin-bottom: 30px; overflow: hidden;">' || rows_html || '</table>' else '' end
    || styled_body
    || case when button_url is not null then
         '<table border="0" cellpadding="0" cellspacing="0" width="100%"><tr><td align="center"><table border="0" cellpadding="0" cellspacing="0"><tr>'
         || '<td align="center" style="background-color: #C10000; border-radius: 8px;"><a href="' || app_private.html(button_url) || '" target="_blank" style="display: inline-block; padding: 16px 36px; font-family: ''Inter'', Helvetica, Arial, sans-serif; font-size: 16px; color: #ffffff; text-decoration: none; font-weight: bold; border-radius: 8px;">'
         || app_private.html(button_label) || '</a></td></tr></table></td></tr></table>' else '' end
    || '</td></tr>'
    || '<tr><td align="center" style="padding: 0 35px 40px 35px;"><p style="margin: 0; color: #6D727A; font-size: 12px; line-height: 1.5; text-align: center;">'
    || 'You''re getting this because this address was used to sign up for Dodgeball After Dark. If that wasn''t you, you can ignore this email.'
    || '</p></td></tr></table></td></tr></table></body></html>';
end $$;

/**
 * Queues an email with Brevo. pg_net only sends it once the registration commits, so a
 * failed signup never sends anything. Never raises: a broken email setup must not block signups.
 */
create or replace function app_private.send_email(to_email text, to_name text, subject text, html_content text) returns boolean
language plpgsql as $$
declare cfg app_private.email_config;
begin
  select * into cfg from app_private.email_config where id = 1;
  if coalesce(cfg.brevo_api_key, '') = '' or coalesce(to_email, '') = '' then return false; end if;
  perform net.http_post(
    url := 'https://api.brevo.com/v3/smtp/email',
    headers := jsonb_build_object('api-key', cfg.brevo_api_key, 'Content-Type', 'application/json', 'Accept', 'application/json'),
    body := jsonb_build_object(
      'sender', jsonb_build_object('name', cfg.sender_name, 'email', cfg.sender_email),
      'to', jsonb_build_array(jsonb_build_object('email', to_email, 'name', coalesce(nullif(to_name, ''), split_part(to_email, '@', 1)))),
      'subject', subject,
      'htmlContent', html_content));
  return true;
exception when others then
  perform app_private.log('email:error', to_email || ': ' || sqlstate || ' ' || sqlerrm);
  return false;
end $$;

create or replace function app_private.send_registration_emails(mode text, v_name text, v_email text, team app_private.teams, waitlist_pos int, invitees jsonb default '[]'::jsonb)
returns boolean
language plpgsql as $$
declare
  link text;
  site text := (select nullif(site_url, '') from app_private.email_config where id = 1);
  sent boolean := false;
  inv jsonb;
  manage_note constant text := '<p style="margin: 0 0 35px 0; color: #949BA4; font-size: 14px; line-height: 1.6;">Need to remove someone or make changes? Use <b>Manage My Team</b> on the sign-up page with your team code. Keep the code to yourself and your teammates: anyone who has it can join or manage the team.</p>';
begin
  if team.id is not null then link := app_private.join_link(team.code); end if;

  if mode = 'create' then
    sent := app_private.send_email(v_email, v_name, 'Your team "' || team.name || '" is registered – Dodgeball After Dark',
      app_private.email_html('Your team is registered!',
        'Hi ' || app_private.html(v_name) || ', <b>' || app_private.html(team.name) || '</b> is in, and you''re the captain. '
          || 'Share your team code' || case when link is not null then ' or the link below' else '' end || ' so your teammates can join.',
        jsonb_build_array(jsonb_build_array('Team', team.name), jsonb_build_array('Role', 'Captain'), jsonb_build_array('Team code', team.code),
          jsonb_build_array('Share link', link)),
        manage_note, case when site is not null then 'Open the join page' end, site));
    -- Teammates the captain listed by email still have to confirm their spot.
    for inv in select * from jsonb_array_elements(coalesce(invitees, '[]'::jsonb)) loop
      continue when coalesce(inv->>'email', '') = '';
      perform app_private.send_email(inv->>'email', inv->>'name', v_name || ' added you to "' || team.name || '" – Dodgeball After Dark',
        app_private.email_html('You''ve been added to a team!',
          'Hi ' || app_private.html(inv->>'name') || ', <b>' || app_private.html(v_name) || '</b> put you on <b>' || app_private.html(team.name)
            || '</b> for Dodgeball After Dark. Confirm your spot by signing up with this email address and the team code below.',
          jsonb_build_array(jsonb_build_array('Team', team.name), jsonb_build_array('Captain', v_name), jsonb_build_array('Team code', team.code)),
          '', case when link is not null then 'Confirm my spot' end, link));
    end loop;
  elsif mode = 'join' then
    sent := app_private.send_email(v_email, v_name, 'You''re on "' || team.name || '" – Dodgeball After Dark',
      app_private.email_html('You''re on the team!',
        'Hi ' || app_private.html(v_name) || ', you''ve joined <b>' || app_private.html(team.name) || '</b>. '
          || 'Know someone else who should be on the team? Send them the code' || case when link is not null then ' or the link below' else '' end || '.',
        jsonb_build_array(jsonb_build_array('Team', team.name), jsonb_build_array('Team code', team.code), jsonb_build_array('Share link', link)),
        manage_note, case when site is not null then 'Open the join page' end, site));
  else
    sent := app_private.send_email(v_email, v_name, 'You''re on the waitlist – Dodgeball After Dark',
      app_private.email_html('You''re on the waitlist!',
        'Hi ' || app_private.html(v_name) || ', you''re signed up as a free agent. We''ll place you on a team as spots open up.',
        jsonb_build_array(jsonb_build_array('Status', 'Free agent (waitlist)'), jsonb_build_array('Place in line', '#' || waitlist_pos)),
        '', case when site is not null then 'Invite your friends' end, site));
  end if;
  return sent;
end $$;

-- ---------------------------------------------------------------------------
--  Registration (public)
-- ---------------------------------------------------------------------------

/** Rejects an email or student ID that's already registered (optionally ignoring one player row). */
create or replace function app_private.assert_available(p_email text, p_student_id text, p_except text default null) returns void
language plpgsql as $$
declare r record;
begin
  if coalesce(p_email, '') <> '' then
    select p.id, t.name as team_name, coalesce(t.eliminated, false) as eliminated into r
    from app_private.players p left join app_private.teams t on t.id = p.team_id
    where lower(p.email) = lower(p_email) and p.id is distinct from p_except
    order by coalesce(t.eliminated, false) desc limit 1;
    if found then
      if r.eliminated then
        perform app_private.fail('The email ' || p_email || ' belongs to a player on an eliminated team. You cannot register or join another team.');
      end if;
      perform app_private.fail('The email ' || p_email || ' is already registered'
        || case when r.team_name is not null then ' on "' || r.team_name || '"' else ' on the waitlist' end || '.');
    end if;
  end if;
  if coalesce(p_student_id, '') <> '' then
    select p.id, t.name as team_name into r
    from app_private.players p left join app_private.teams t on t.id = p.team_id
    where p.student_id = p_student_id and p.id is distinct from p_except limit 1;
    if found then
      perform app_private.fail('Student ID ' || p_student_id || ' is already registered'
        || case when r.team_name is not null then ' on "' || r.team_name || '"' else ' on the waitlist' end || '.');
    end if;
  end if;
end $$;

create or replace function app_private.register(p jsonb) returns jsonb
language plpgsql as $$
declare
  s app_private.settings := app_private.settings_row();
  mode text := coalesce(p->>'mode', '');
  person jsonb := coalesce(p->'player', '{}'::jsonb);
  v_name text := app_private.clean_text(person->>'name', 60);
  v_phone text := app_private.clean_text(person->>'phone', 30);
  v_email text := app_private.clean_email(person->>'email');
  v_sid text := app_private.clean_text(person->>'studentId', 30);
  team app_private.teams;
  team_name text;
  v_code text;
  extra jsonb;
  extras jsonb := '[]'::jsonb;
  x_name text; x_email text; x_role text;
  seen text[];
  pre app_private.players;
  roster_size int;
begin
  if mode not in ('create', 'join', 'freeplay') then perform app_private.fail('Unknown registration type.'); end if;
  if mode = 'freeplay' then
    if not s.waitlist_open then perform app_private.fail('The waitlist is currently closed.'); end if;
  elsif not s.registration_open then
    perform app_private.fail('General registration is currently closed.');
  end if;

  if v_name = '' then perform app_private.fail('Full name is required.'); end if;
  if v_phone = '' then perform app_private.fail('Phone number is required.'); end if;
  if v_email = '' then perform app_private.fail('Student email is required.'); end if;
  if not app_private.is_email(v_email) then perform app_private.fail('"' || v_email || '" is not a valid email address.'); end if;
  if v_sid = '' then perform app_private.fail('Student ID is required.'); end if;

  if mode = 'create' then
    team_name := app_private.clean_text(p->>'teamName', 40);
    if team_name = '' then perform app_private.fail('Team name is required.'); end if;
    if exists (select 1 from app_private.teams where lower(name) = lower(team_name)) then
      perform app_private.fail('A team named "' || team_name || '" already exists. Please pick another name.');
    end if;
    perform app_private.assert_available(v_email, v_sid);

    seen := array[v_email];
    for extra in select * from jsonb_array_elements(case when jsonb_typeof(p->'roster') = 'array' then p->'roster' else '[]'::jsonb end) loop
      x_name := app_private.clean_text(extra->>'name', 60);
      continue when x_name = '';
      x_email := app_private.clean_email(extra->>'email');
      x_role := case when extra->>'role' = 'Alternate' then 'Alternate' else 'Player' end;
      if x_email <> '' then
        if not app_private.is_email(x_email) then perform app_private.fail('"' || x_email || '" is not a valid email address.'); end if;
        if x_email = any(seen) then perform app_private.fail('The email ' || x_email || ' is listed more than once.'); end if;
        seen := seen || x_email;
        perform app_private.assert_available(x_email, '');
      end if;
      extras := extras || jsonb_build_object('name', x_name, 'email', x_email, 'role', x_role);
    end loop;
    if 1 + jsonb_array_length(extras) > s.max_team_size then
      perform app_private.fail('Teams are limited to ' || s.max_team_size || ' players including the captain.');
    end if;

    insert into app_private.teams (name, code) values (team_name, app_private.unique_team_code(p->>'teamCode')) returning * into team;
    insert into app_private.players (team_id, name, email, phone, student_id, role)
      values (team.id, v_name, v_email, v_phone, v_sid, 'Captain');
    insert into app_private.players (team_id, name, email, role)
      select team.id, e->>'name', e->>'email', e->>'role' from jsonb_array_elements(extras) e;
    perform app_private.sync_bracket();
    perform app_private.log('register:create', team.name || ' (' || team.code || ') by ' || v_name || ' <' || v_email || '>, ' || (1 + jsonb_array_length(extras)) || ' players');
    return jsonb_build_object(
      'message', 'Your team "' || team.name || '" has been created! Share your code (' || team.code || ') with teammates so they can join. '
                 || 'Need to remove someone later? Use "Manage My Team" with the same code.',
      'teamCode', team.code, 'teamName', team.name,
      'emailSent', app_private.send_registration_emails('create', v_name, v_email, team, null, extras));
  end if;

  if mode = 'join' then
    v_code := upper(btrim(coalesce(p->>'teamCode', '')));
    if v_code = '' then perform app_private.fail('Please enter a team code.'); end if;
    select * into team from app_private.teams where upper(teams.code) = v_code;
    if not found then perform app_private.fail('We couldn''t find a team with the code ' || v_code || '. Please check and try again.'); end if;
    if team.eliminated then perform app_private.fail('"' || team.name || '" has been eliminated and can no longer add players.'); end if;

    -- A captain may have pre-listed this player by email: claim that spot instead of duplicating.
    select * into pre from app_private.players
      where team_id = team.id and student_id = '' and email <> '' and lower(email) = v_email limit 1;
    if found then
      perform app_private.assert_available('', v_sid, pre.id);
      update app_private.players set name = v_name, phone = v_phone, student_id = v_sid, updated_at = now() where id = pre.id;
      perform app_private.log('register:claim', v_name || ' <' || v_email || '> confirmed spot on ' || team.name);
      return jsonb_build_object('message', 'You have confirmed your spot on "' || team.name || '"!', 'teamName', team.name, 'teamCode', team.code,
        'emailSent', app_private.send_registration_emails('join', v_name, v_email, team, null));
    end if;

    perform app_private.assert_available(v_email, v_sid);
    select count(*) into roster_size from app_private.players where team_id = team.id;
    if roster_size >= s.max_team_size then
      perform app_private.fail('"' || team.name || '" is full (' || s.max_team_size || ' players).');
    end if;
    insert into app_private.players (team_id, name, email, phone, student_id, role)
      values (team.id, v_name, v_email, v_phone, v_sid, 'Player');
    perform app_private.log('register:join', v_name || ' <' || v_email || '> joined ' || team.name);
    return jsonb_build_object('message', 'You have successfully joined "' || team.name || '"!', 'teamName', team.name, 'teamCode', team.code,
      'emailSent', app_private.send_registration_emails('join', v_name, v_email, team, null));
  end if;

  -- freeplay / waitlist
  perform app_private.assert_available(v_email, v_sid);
  insert into app_private.players (team_id, name, email, phone, student_id, role)
    values (null, v_name, v_email, v_phone, v_sid, 'Player');
  perform app_private.log('register:waitlist', v_name || ' <' || v_email || '>');
  roster_size := (select count(*) from app_private.players where team_id is null);
  return jsonb_build_object('message', 'You have been added to the waitlist! We will place you on a team if spots become available.',
    'waitlistPosition', roster_size,
    'emailSent', app_private.send_registration_emails('freeplay', v_name, v_email, null, roster_size));
end $$;

-- ---------------------------------------------------------------------------
--  Team self-service (public — whoever holds the team code can manage the team)
-- ---------------------------------------------------------------------------

create or replace function app_private.team_by_code(p_code text) returns app_private.teams
language plpgsql as $$
declare c text := upper(btrim(coalesce(p_code, ''))); t app_private.teams;
begin
  if c = '' then perform app_private.fail('Please enter your team code.'); end if;
  select * into t from app_private.teams where upper(code) = c;
  if not found then perform app_private.fail('We couldn''t find a team with the code ' || c || '. Please check and try again.'); end if;
  return t;
end $$;

/** Roster as a team (not an admin) sees it: emails and IDs stay redacted. */
create or replace function app_private.managed_team_out(t app_private.teams) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'name', t.name, 'code', t.code, 'eliminated', t.eliminated,
    'canDelete', not app_private.bracket_started(),
    'maxTeamSize', (app_private.settings_row()).max_team_size,
    'players', coalesce((select jsonb_agg(jsonb_build_object(
        'playerId', p.id, 'name', p.name, 'role', p.role,
        'email', app_private.mask_email(p.email), 'studentId', app_private.mask_id(p.student_id),
        'confirmed', p.student_id <> '') order by p.seq)
      from app_private.players p where p.team_id = t.id), '[]'::jsonb));
$$;

/** Removes a player. If the captain leaves, the longest-standing teammate (non-alternates first) takes over. */
create or replace function app_private.remove_player(p_player_id text, p_team_id text) returns app_private.players
language plpgsql as $$
declare removed app_private.players;
begin
  delete from app_private.players where id = p_player_id and (p_team_id is null or team_id = p_team_id) returning * into removed;
  if not found then
    perform app_private.fail(case when p_team_id is null then 'Player not found.' else 'That player is not on this team.' end);
  end if;
  if removed.role = 'Captain' and removed.team_id is not null then
    update app_private.players set role = 'Captain', updated_at = now()
    where id = (select id from app_private.players where team_id = removed.team_id order by (role = 'Alternate'), seq limit 1);
  end if;
  return removed;
end $$;

/** Deletes a team and every player on it. Returns how many players were removed. */
create or replace function app_private.delete_team(t app_private.teams) returns int
language plpgsql as $$
declare n int;
begin
  select count(*) into n from app_private.players where team_id = t.id;
  delete from app_private.teams where id = t.id;  -- players cascade
  perform app_private.sync_bracket();
  return n;
end $$;

/** What a share link shows before someone joins: no roster, just the team and whether there's room. */
create or replace function app_private.team_preview(p jsonb) returns jsonb
language sql as $$
  with t as (select * from app_private.team_by_code(p->>'teamCode'))
  select jsonb_build_object('team', jsonb_build_object(
    'name', t.name, 'code', t.code, 'eliminated', t.eliminated,
    'playerCount', (select count(*) from app_private.players pl where pl.team_id = t.id),
    'maxTeamSize', (app_private.settings_row()).max_team_size))
  from t;
$$;

create or replace function app_private.team_lookup(p jsonb) returns jsonb
language sql as $$
  select jsonb_build_object('team', app_private.managed_team_out(app_private.team_by_code(p->>'teamCode')));
$$;

create or replace function app_private.team_remove_player(p jsonb) returns jsonb
language plpgsql as $$
declare t app_private.teams := app_private.team_by_code(p->>'teamCode'); removed app_private.players;
begin
  removed := app_private.remove_player(p->>'playerId', t.id);
  perform app_private.log('team:removePlayer', removed.name || ' <' || removed.email || '> removed from ' || t.name || ' (team code)');
  return jsonb_build_object('message', removed.name || ' was removed from "' || t.name || '".', 'team', app_private.managed_team_out(t));
end $$;

create or replace function app_private.team_delete(p jsonb) returns jsonb
language plpgsql as $$
declare t app_private.teams := app_private.team_by_code(p->>'teamCode'); n int;
begin
  if app_private.bracket_started() then
    perform app_private.fail('The tournament has already started, so "' || t.name || '" can no longer be deleted. Please talk to an organizer.');
  end if;
  n := app_private.delete_team(t);
  perform app_private.log('team:delete', t.name || ' (' || t.code || ') and ' || n || ' players deleted (team code)');
  return jsonb_build_object('message', '"' || t.name || '" and its roster have been deleted.');
end $$;

-- ---------------------------------------------------------------------------
--  Admin auth
-- ---------------------------------------------------------------------------

/** Wrong passwords return { _fail } instead of raising, so the failure counter isn't rolled back. */
create or replace function app_private.login(p jsonb) returns jsonb
language plpgsql as $$
declare cfg app_private.admin_config; tok text;
begin
  select * into cfg from app_private.admin_config where id = 1 for update;
  if cfg.locked_until is not null and cfg.locked_until > now() then
    return jsonb_build_object('_fail', 'Too many failed attempts. Please wait 10 minutes and try again.', '_code', 'AUTH');
  end if;
  if extensions.crypt(coalesce(p->>'password', ''), cfg.password_hash) <> cfg.password_hash then
    update app_private.admin_config set
      login_failures = case when login_failures + 1 >= 10 then 0 else login_failures + 1 end,
      locked_until = case when login_failures + 1 >= 10 then now() + interval '10 minutes' else locked_until end
    where id = 1;
    perform app_private.log('login:failed', 'Incorrect password attempt');
    return jsonb_build_object('_fail', 'Incorrect admin password.', '_code', 'AUTH');
  end if;
  update app_private.admin_config set login_failures = 0, locked_until = null where id = 1;
  delete from app_private.admin_sessions where expires_at < now();
  tok := encode(extensions.gen_random_bytes(32), 'hex');
  insert into app_private.admin_sessions (token, expires_at) values (tok, now() + interval '6 hours');
  perform app_private.log('login', 'Admin logged in');
  return jsonb_build_object('token', tok, 'state', app_private.build_state(true));
end $$;

/** Valid session? Each use slides the 6-hour expiry forward. */
create or replace function app_private.check_admin(p_token text) returns boolean
language plpgsql as $$
begin
  if coalesce(p_token, '') = '' then return false; end if;
  update app_private.admin_sessions set expires_at = now() + interval '6 hours'
  where token = p_token and expires_at > now();
  return found;
end $$;

create or replace function app_private.set_admin_password(new_password text) returns text
language plpgsql security definer set search_path = app_private, extensions as $$
begin
  if length(coalesce(new_password, '')) < 6 then raise exception 'Password must be at least 6 characters.'; end if;
  update app_private.admin_config set password_hash = extensions.crypt(new_password, extensions.gen_salt('bf')), login_failures = 0, locked_until = null where id = 1;
  delete from app_private.admin_sessions where true;
  perform app_private.log('admin:password', 'Admin password changed (all admin sessions signed out)', 'sql');
  return 'Admin password updated.';
end $$;

-- ---------------------------------------------------------------------------
--  Admin actions
-- ---------------------------------------------------------------------------

create or replace function app_private.set_setting(p jsonb) returns jsonb
language plpgsql as $$
declare k text := p->>'key'; v text := p->>'value'; n int;
begin
  if k in ('registrationOpen', 'waitlistOpen') then
    if k = 'registrationOpen' then update app_private.settings set registration_open = v::boolean where id = 1;
    else update app_private.settings set waitlist_open = v::boolean where id = 1; end if;
  elsif k in ('maxTeamSize', 'waitlistTeamSize') then
    n := round(v::numeric);
    if n is null or n < 1 or n > 50 then perform app_private.fail(k || ' must be between 1 and 50.'); end if;
    if k = 'maxTeamSize' then update app_private.settings set max_team_size = n where id = 1;
    else update app_private.settings set waitlist_team_size = n where id = 1; end if;
  else
    perform app_private.fail('Unknown setting: ' || coalesce(k, ''));
  end if;
  perform app_private.log('setting', k || ' = ' || v);
  return '{}'::jsonb;
end $$;

create or replace function app_private.oldest_free_agent() returns app_private.players
language sql stable as $$
  select * from app_private.players where team_id is null order by created_at, seq limit 1;
$$;

create or replace function app_private.process_waitlist(p jsonb) returns jsonb
language plpgsql as $$
declare
  target int := (app_private.settings_row()).waitlist_team_size;
  t app_private.teams;
  fa app_private.players;
  size int;
  has_captain boolean;
  lines text[] := '{}';
  remaining int;
begin
  if not exists (select 1 from app_private.players where team_id is null) then
    perform app_private.fail('There are no free agents on the waitlist right now.');
  end if;

  for t in select * from app_private.teams where not eliminated order by seq loop
    select count(*), bool_or(role = 'Captain') into size, has_captain from app_private.players where team_id = t.id;
    while size < target loop
      fa := app_private.oldest_free_agent();
      exit when fa.id is null;
      update app_private.players set team_id = t.id, role = case when coalesce(has_captain, false) then 'Player' else 'Captain' end,
        checked_in = false, updated_at = now() where id = fa.id;
      has_captain := true;
      size := size + 1;
      lines := lines || ('Assigned ' || fa.name || ' to ' || t.name);
    end loop;
  end loop;

  while (select count(*) from app_private.players where team_id is null) >= target loop
    insert into app_private.teams (name, code) values (app_private.unique_team_name('Waitlist Team'), app_private.unique_team_code())
      returning * into t;
    update app_private.players pl set team_id = t.id, role = case when x.rn = 1 then 'Captain' else 'Player' end,
      checked_in = false, updated_at = now()
    from (select id, row_number() over (order by created_at, seq) rn from app_private.players
          where team_id is null order by created_at, seq limit target) x
    where pl.id = x.id;
    lines := lines || ('Created new team ' || t.name || ' (' || t.code || ') with ' || target || ' free agents.');
  end loop;

  perform app_private.sync_bracket();
  select count(*) into remaining from app_private.players where team_id is null;
  perform app_private.log('waitlist:process', coalesce(nullif(array_to_string(lines, ' | '), ''), 'No changes'));
  return jsonb_build_object('log', to_jsonb(lines), 'remaining', remaining);
end $$;

/**
 * Moves free agents onto one team, oldest sign-ups first, without going over max_team_size.
 * payload: { teamId, count } fills up to `count` open spots; { teamId, playerId } places one person.
 */
create or replace function app_private.fill_team(p jsonb) returns jsonb
language plpgsql as $$
declare
  s app_private.settings := app_private.settings_row();
  t app_private.teams;
  waiting int;
  roster int;
  has_captain boolean;
  open_spots int;
  want int;
  added text[] := '{}';
  fa record;
begin
  select * into t from app_private.teams where id = p->>'teamId';
  if not found then perform app_private.fail('Team not found.'); end if;
  if t.eliminated then perform app_private.fail('"' || t.name || '" has been eliminated.'); end if;

  select count(*) into waiting from app_private.players where team_id is null;
  if p->>'playerId' is not null and not exists (select 1 from app_private.players where id = p->>'playerId' and team_id is null) then
    perform app_private.fail('That player is no longer on the waitlist.');
  end if;
  if waiting = 0 then perform app_private.fail('There are no free agents on the waitlist right now.'); end if;

  select count(*), coalesce(bool_or(role = 'Captain'), false) into roster, has_captain from app_private.players where team_id = t.id;
  open_spots := s.max_team_size - roster;
  if open_spots <= 0 then perform app_private.fail('"' || t.name || '" is already full (' || s.max_team_size || ' players).'); end if;

  want := case when p->>'playerId' is not null then 1
               else greatest(1, least(open_spots, coalesce(nullif(regexp_replace(coalesce(p->>'count', ''), '\D', '', 'g'), '')::int, open_spots))) end;

  for fa in
    select id, name from app_private.players
    where team_id is null and (p->>'playerId' is null or id = p->>'playerId')
    order by created_at, seq limit want
  loop
    update app_private.players set team_id = t.id, role = case when has_captain then 'Player' else 'Captain' end,
      checked_in = false, updated_at = now() where id = fa.id;
    has_captain := true;
    added := added || fa.name;
  end loop;

  perform app_private.log('waitlist:fillTeam', t.name || ' <- ' || array_to_string(added, ', '));
  return jsonb_build_object('added', to_jsonb(added), 'teamName', t.name,
    'openLeft', open_spots - cardinality(added), 'remaining', waiting - cardinality(added));
end $$;

create or replace function app_private.reset_bracket(p jsonb) returns jsonb
language plpgsql as $$
begin
  update app_private.teams set eliminated = false, updated_at = now() where eliminated;
  delete from app_private.matches where true;
  delete from app_private.checkin_snapshots where true;
  perform app_private.rebuild_bracket();
  perform app_private.log('bracket:reset', 'All match progress cleared, all teams reinstated');
  return '{}'::jsonb;
end $$;

create or replace function app_private.add_team(p jsonb) returns jsonb
language plpgsql as $$
declare requested text := app_private.clean_text(p->>'name', 40); t app_private.teams;
begin
  if requested <> '' and exists (select 1 from app_private.teams where lower(name) = lower(requested)) then
    perform app_private.fail('A team named "' || requested || '" already exists.');
  end if;
  insert into app_private.teams (name, code)
    values (coalesce(nullif(requested, ''), app_private.unique_team_name('New Blank Team')), app_private.unique_team_code())
    returning * into t;
  perform app_private.sync_bracket();
  perform app_private.log('team:add', t.name || ' (' || t.code || ')');
  return jsonb_build_object('teamId', t.id);
end $$;

create or replace function app_private.add_player(p jsonb) returns jsonb
language plpgsql as $$
declare
  t app_private.teams;
  v_name text := app_private.clean_text(p->>'name', 60);
  v_email text := app_private.clean_email(p->>'email');
  v_sid text := app_private.clean_text(p->>'studentId', 30);
  v_phone text := app_private.clean_text(p->>'phone', 30);
  v_role text := case when p->>'role' in ('Player', 'Captain', 'Alternate') then p->>'role' else 'Player' end;
begin
  select * into t from app_private.teams where id = p->>'teamId';
  if not found then perform app_private.fail('Team not found.'); end if;
  if v_name = '' or v_email = '' or v_sid = '' then
    perform app_private.fail('Please fill out the Name, Email, and Student ID fields to add a player.');
  end if;
  if not app_private.is_email(v_email) then perform app_private.fail('"' || v_email || '" is not a valid email address.'); end if;
  perform app_private.assert_available(v_email, v_sid);
  insert into app_private.players (team_id, name, email, phone, student_id, role) values (t.id, v_name, v_email, v_phone, v_sid, v_role);
  perform app_private.log('player:add', v_name || ' <' || v_email || '> -> ' || t.name || ' as ' || v_role);
  return '{}'::jsonb;
end $$;

create or replace function app_private.remove_player_admin(p jsonb) returns jsonb
language plpgsql as $$
declare removed app_private.players; tname text;
begin
  removed := app_private.remove_player(p->>'playerId', null);
  select name into tname from app_private.teams where id = removed.team_id;
  perform app_private.log('player:remove', removed.name || ' <' || removed.email || '>'
    || coalesce(' removed from ' || tname, ' removed from waitlist'));
  return '{}'::jsonb;
end $$;

create or replace function app_private.delete_team_admin(p jsonb) returns jsonb
language plpgsql as $$
declare t app_private.teams; n int;
begin
  select * into t from app_private.teams where id = p->>'teamId';
  if not found then perform app_private.fail('Team not found.'); end if;
  if app_private.bracket_started() then perform app_private.fail('Matches have already been played. Reset the bracket before deleting a team.'); end if;
  n := app_private.delete_team(t);
  perform app_private.log('team:delete', t.name || ' (' || t.code || ') and ' || n || ' players deleted by admin');
  return '{}'::jsonb;
end $$;

create or replace function app_private.toggle_check_in(p jsonb) returns jsonb
language plpgsql as $$
declare r app_private.players;
begin
  update app_private.players set checked_in = not checked_in, updated_at = now() where id = p->>'playerId' returning * into r;
  if not found then perform app_private.fail('Player not found.'); end if;
  perform app_private.log('checkin', r.name || ' -> ' || case when r.checked_in then 'IN' else 'OUT' end);
  return '{}'::jsonb;
end $$;

create or replace function app_private.set_team_check_in(p jsonb) returns jsonb
language plpgsql as $$
declare t app_private.teams; v boolean := coalesce((p->>'checkedIn')::boolean, false);
begin
  select * into t from app_private.teams where id = p->>'teamId';
  if not found then perform app_private.fail('Team not found.'); end if;
  update app_private.players set checked_in = v, updated_at = now() where team_id = t.id;
  perform app_private.log('checkin:team', t.name || ' -> ' || case when v then 'all IN' else 'reset' end);
  return '{}'::jsonb;
end $$;

create or replace function app_private.advance_team(p jsonb) returns jsonb
language plpgsql as $$
declare
  r int := (p->>'round')::int;
  m int := (p->>'pos')::int;
  slot int := (p->>'slot')::int;
  num int := app_private.num_rounds();
  mt app_private.matches;
  winner app_private.teams;
  v_winner text;
  v_loser text;
  loser_name text := 'Unassigned';
  was_in text[];
begin
  select * into mt from app_private.matches where round = r and pos = m for update;
  if not found or r >= num - 1 or slot not in (1, 2) then perform app_private.fail('Invalid match.'); end if;
  v_winner := case when slot = 1 then mt.team1_id else mt.team2_id end;
  v_loser := case when slot = 1 then mt.team2_id else mt.team1_id end;
  if v_winner is null then perform app_private.fail('There is no team in that slot.'); end if;
  if mt.winner_id is not null then
    if mt.winner_id = v_winner then return '{}'::jsonb; end if;
    perform app_private.fail('That match already has a winner. Click the winner to undo the result first.');
  end if;
  if v_loser is null and app_private.slot_pending(r, m, 3 - slot) then
    perform app_private.fail('The other team for this match hasn''t been decided yet.');
  end if;
  select * into winner from app_private.teams where id = v_winner;
  if not found then perform app_private.fail('That team no longer exists.'); end if;
  if winner.eliminated then perform app_private.fail('"' || winner.name || '" has already been eliminated.'); end if;

  update app_private.matches set winner_id = v_winner, updated_at = now() where round = r and pos = m;
  if v_loser is not null then
    update app_private.teams set eliminated = true, updated_at = now() where id = v_loser returning name into loser_name;
  end if;
  if m % 2 = 0 then
    update app_private.matches set team1_id = v_winner, updated_at = now() where round = r + 1 and pos = m / 2;
  else
    update app_private.matches set team2_id = v_winner, updated_at = now() where round = r + 1 and pos = m / 2;
  end if;

  -- Moving on to another match means checking in again; remember who was in so an undo can restore it.
  if r + 1 < num - 1 then
    select coalesce(array_agg(id), '{}') into was_in from app_private.players where team_id = v_winner and checked_in;
    insert into app_private.checkin_snapshots (match_key, player_ids) values ('R' || (r + 1) || '-M' || (m + 1), was_in)
      on conflict (match_key) do update set player_ids = excluded.player_ids;
    update app_private.players set checked_in = false, updated_at = now() where team_id = v_winner and checked_in;
  end if;

  perform app_private.log('bracket:advance', app_private.bracket_label(r, num) || ' match ' || (m + 1) || ': ' || winner.name || ' def. ' || coalesce(loser_name, 'Unassigned'));
  return '{}'::jsonb;
end $$;

create or replace function app_private.undo_advance(p jsonb) returns jsonb
language plpgsql as $$
declare
  r int := (p->>'round')::int;
  m int := (p->>'pos')::int;
  num int := app_private.num_rounds();
  mt app_private.matches;
  nxt app_private.matches;
  w_id text;
  w_name text;
  loser_id text;
  snap text[];
  k text := 'R' || (r + 1) || '-M' || (m + 1);
begin
  select * into mt from app_private.matches where round = r and pos = m for update;
  if not found or r >= num - 1 then perform app_private.fail('Invalid match.'); end if;
  if mt.winner_id is null then perform app_private.fail('That match has no result to undo.'); end if;
  w_id := mt.winner_id;
  select name into w_name from app_private.teams where id = w_id;

  select * into nxt from app_private.matches where round = r + 1 and pos = m / 2 for update;
  if nxt.winner_id is not null then
    perform app_private.fail('"' || coalesce(w_name, 'That team') || '" has already played its next match. Undo that result first.');
  end if;
  update app_private.matches set
    team1_id = case when m % 2 = 0 and team1_id = w_id then null else team1_id end,
    team2_id = case when m % 2 = 1 and team2_id = w_id then null else team2_id end,
    updated_at = now()
  where round = r + 1 and pos = m / 2;
  update app_private.matches set winner_id = null, updated_at = now() where round = r and pos = m;

  loser_id := case when mt.team1_id = w_id then mt.team2_id else mt.team1_id end;
  if loser_id is not null then
    update app_private.teams set eliminated = false, updated_at = now() where id = loser_id;
  end if;

  select player_ids into snap from app_private.checkin_snapshots where match_key = k;
  if found then
    update app_private.players set checked_in = true, updated_at = now() where team_id = w_id and id = any(snap);
    delete from app_private.checkin_snapshots where match_key = k;
  end if;

  if not app_private.bracket_started() then perform app_private.rebuild_bracket(); end if;
  perform app_private.log('bracket:undo', app_private.bracket_label(r, num) || ' match ' || (m + 1) || ': result for ' || coalesce(w_name, w_id) || ' undone');
  return '{}'::jsonb;
end $$;

create or replace function app_private.timer_action(p jsonb) returns jsonb
language plpgsql as $$
declare
  t app_private.timers;
  now_ms bigint := app_private.now_ms();
  mins int;
begin
  select * into t from app_private.timers where idx = (p->>'index')::int for update;
  if not found then perform app_private.fail('Timer not found.'); end if;
  case p->>'op'
    when 'start' then
      if not t.running then
        update app_private.timers set
          remaining_seconds = case when remaining_seconds > 0 then remaining_seconds else default_seconds end,
          running = true, started_at = now_ms, updated_at = now()
        where idx = t.idx;
      end if;
    when 'pause' then
      update app_private.timers set remaining_seconds = greatest(0, ceil(app_private.timer_remaining(t, now_ms))),
        running = false, started_at = null, updated_at = now() where idx = t.idx;
    when 'reset' then
      update app_private.timers set running = false, started_at = null, remaining_seconds = default_seconds, updated_at = now() where idx = t.idx;
    when 'setDefault' then
      mins := nullif(regexp_replace(coalesce(p->>'minutes', ''), '\D', '', 'g'), '')::int;
      if mins is null or mins < 1 or mins > 60 then perform app_private.fail('Minutes must be between 1 and 60.'); end if;
      update app_private.timers set default_seconds = mins * 60,
        remaining_seconds = case when running then remaining_seconds else mins * 60 end, updated_at = now()
      where idx = t.idx;
    else
      perform app_private.fail('Unknown timer operation.');
  end case;
  return '{}'::jsonb;
end $$;

-- ---------------------------------------------------------------------------
--  The one public entry point
-- ---------------------------------------------------------------------------

create or replace function public.dodgeball_api(action text, payload jsonb default '{}'::jsonb, token text default null)
returns jsonb
language plpgsql volatile security definer
set search_path = app_private, public, extensions
as $$
declare
  is_admin boolean;
  result jsonb;
  admin_actions constant text[] := array['setSetting', 'processWaitlist', 'fillTeam', 'resetBracket', 'addTeam', 'addPlayer',
    'removePlayer', 'deleteTeam', 'toggleCheckIn', 'setTeamCheckIn', 'advanceTeam', 'undoAdvance', 'timer'];
begin
  payload := coalesce(payload, '{}'::jsonb);
  is_admin := app_private.check_admin(token);
  if action = any(admin_actions) and not is_admin then
    perform app_private.fail('Your admin session has expired. Please log in again.', 'DB401');
  end if;
  -- One write at a time keeps the "check, then write" logic race-free.
  if action not in ('getState', 'teamLookup', 'teamPreview') then perform pg_advisory_xact_lock(727274); end if;

  case action
    when 'getState'         then result := '{}'::jsonb;
    when 'register'         then result := app_private.register(payload);
    when 'teamLookup'       then result := app_private.team_lookup(payload);
    when 'teamPreview'      then result := app_private.team_preview(payload);
    when 'teamRemovePlayer' then result := app_private.team_remove_player(payload);
    when 'teamDelete'       then result := app_private.team_delete(payload);
    when 'login'            then result := app_private.login(payload);
    when 'logout'           then
      delete from app_private.admin_sessions where admin_sessions.token = dodgeball_api.token;
      result := jsonb_build_object('state', app_private.build_state(false));
    when 'setSetting'       then result := app_private.set_setting(payload);
    when 'processWaitlist'  then result := app_private.process_waitlist(payload);
    when 'fillTeam'         then result := app_private.fill_team(payload);
    when 'resetBracket'     then result := app_private.reset_bracket(payload);
    when 'addTeam'          then result := app_private.add_team(payload);
    when 'addPlayer'        then result := app_private.add_player(payload);
    when 'removePlayer'     then result := app_private.remove_player_admin(payload);
    when 'deleteTeam'       then result := app_private.delete_team_admin(payload);
    when 'toggleCheckIn'    then result := app_private.toggle_check_in(payload);
    when 'setTeamCheckIn'   then result := app_private.set_team_check_in(payload);
    when 'advanceTeam'      then result := app_private.advance_team(payload);
    when 'undoAdvance'      then result := app_private.undo_advance(payload);
    when 'timer'            then result := app_private.timer_action(payload);
    else perform app_private.fail('Unknown action: ' || coalesce(action, ''));
  end case;

  if result ? '_fail' then
    return jsonb_build_object('ok', false, 'error', result->>'_fail', 'code', coalesce(result->>'_code', 'ERROR'));
  end if;
  if not result ? 'state' then result := result || jsonb_build_object('state', app_private.build_state(is_admin)); end if;
  return jsonb_build_object('ok', true) || result;

exception
  when sqlstate 'DB401' then
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'code', 'AUTH');
  when sqlstate 'P0001' then
    return jsonb_build_object('ok', false, 'error', sqlerrm, 'code', 'ERROR');
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'That name, code or email was just taken. Please try again.', 'code', 'ERROR');
  when others then
    perform app_private.log('error', coalesce(action, '?') || ': ' || sqlstate || ' ' || sqlerrm);
    return jsonb_build_object('ok', false, 'code', 'ERROR',
      'error', 'Something went wrong on the server (' || coalesce(action, '?') || ' / ' || sqlstate || '). Please try again.');
end $$;

revoke all on function public.dodgeball_api(text, jsonb, text) from public;
do $$ begin
  grant execute on function public.dodgeball_api(text, jsonb, text) to anon, authenticated;
exception when undefined_object then null;
end $$;

-- Lay out the bracket for whatever teams exist (no-op once play has started).
select app_private.sync_bracket();
