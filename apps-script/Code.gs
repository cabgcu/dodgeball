/* =============================================================================
 *  DODGEBALL AFTER DARK — Google Sheets backend (Google Apps Script Web App)
 * =============================================================================
 *
 *  ONE-TIME SETUP (about 3 minutes)
 *  ---------------------------------
 *   1. Create a new blank Google Sheet (https://sheets.new) and name it
 *      something like "Dodgeball After Dark DB".
 *   2. In the Sheet: Extensions ▸ Apps Script. Delete the sample code, paste
 *      this ENTIRE file into Code.gs, then click Save.
 *   3. In the function dropdown at the top pick `setup`, then click Run.
 *      Approve the permissions prompt (it only needs this spreadsheet).
 *      This builds every tab, header, checkbox and format automatically:
 *        Settings · Teams · Players · Bracket · Timers · Log
 *   4. Deploy ▸ New deployment ▸ gear icon ▸ "Web app"
 *        Execute as:      Me
 *        Who has access:  Anyone
 *      Click Deploy and copy the "Web app URL" (it ends in /exec).
 *   5. Open index.html and paste that URL into API_URL near the top of the
 *      main <script> block.
 *   6. Back in the Sheet, reload the page. Use the new menu
 *      "Dodgeball ▸ Set admin password" to change the admin password
 *      (the default is the one that used to be hard-coded in index.html).
 *
 *  UPDATING THIS SCRIPT LATER
 *  --------------------------
 *   Deploy ▸ Manage deployments ▸ pencil icon ▸ Version: "New version" ▸ Deploy.
 *   The URL stays the same. (Saving alone does NOT update the live web app.)
 *
 *  EDITING DATA BY HAND
 *  --------------------
 *   The Sheet is the source of truth; the site re-reads it on every request.
 *   You can rename teams, fix emails, tick checkboxes, flip settings, etc.
 *   directly in the Sheet. Don't change the header row or the ID columns.
 *   Columns are matched by header text, so you may reorder columns or add
 *   your own extra columns (e.g. "Notes") — they are preserved.
 *
 *  API (used by index.html — all requests are POST with a JSON body sent as
 *  text/plain to avoid CORS preflight):
 *    { action: "getState" }                                    public
 *    { action: "register", payload: {...} }                    public
 *    { action: "teamLookup" | "teamRemovePlayer" | "teamDelete",
 *      payload: { teamCode, ... } }                            public, team code required
 *    { action: "login", payload: { password } }                public → token
 *    { action: "...", token, payload }                         admin actions
 *   A GET to the /exec URL returns the public state as JSON (handy for testing).
 * ========================================================================== */

const APP = {
  SCHEMA_VERSION: '1',
  DEFAULT_ADMIN_PASSWORD: 'Cabgcu49!',
  SESSION_SECONDS: 6 * 60 * 60,   // admin login lasts 6h (CacheService maximum)
  MAX_LOGIN_FAILURES: 10,         // failed logins allowed per window...
  LOGIN_LOCK_SECONDS: 10 * 60,    // ...before logins pause for this long
  DEFAULT_COURTS: ['Court 1', 'Court 2', 'Court 3'],
  DEFAULT_TIMER_SECONDS: 600,
  HEADER_BG: '#0f172a',
  HEADER_FG: '#ffffff',
  DATE_FORMAT: 'yyyy-mm-dd hh:mm:ss',
};

const S = {
  SETTINGS: 'Settings',
  TEAMS: 'Teams',
  PLAYERS: 'Players',
  BRACKET: 'Bracket',
  TIMERS: 'Timers',
  LOG: 'Log',
};

const SETTINGS_DEFAULTS = [
  { key: 'registrationOpen', value: true,  type: 'bool',   description: 'Teams can be created and joined from the site.' },
  { key: 'waitlistOpen',     value: false, type: 'bool',   description: 'Free agents can sign up for the waitlist.' },
  { key: 'maxTeamSize',      value: 10,    type: 'number', min: 1, max: 50, description: 'Maximum players per team, captain included.' },
  { key: 'waitlistTeamSize', value: 6,     type: 'number', min: 1, max: 50, description: 'Auto-process fills teams up to this size, then forms new teams of this size.' },
];

/**
 * Column types: 'text' (default), 'bool' (checkbox), 'number', 'date', 'raw'.
 * idKey marks the column that must be non-empty for a row to count.
 */
const SCHEMA = {
  [S.SETTINGS]: { idKey: 'key', tab: '#64748b', columns: [
    { key: 'key',         header: 'Setting',     width: 170 },
    { key: 'value',       header: 'Value',       width: 100, type: 'raw' },
    { key: 'description', header: 'Description', width: 480 },
  ]},
  [S.TEAMS]: { idKey: 'teamId', tab: '#dc2626', columns: [
    { key: 'teamId',     header: 'Team ID',    width: 120 },
    { key: 'name',       header: 'Team Name',  width: 220 },
    { key: 'code',       header: 'Team Code',  width: 100 },
    { key: 'eliminated', header: 'Eliminated', width: 95,  type: 'bool' },
    { key: 'createdAt',  header: 'Created At', width: 150, type: 'date' },
    { key: 'updatedAt',  header: 'Updated At', width: 150, type: 'date' },
  ]},
  [S.PLAYERS]: { idKey: 'playerId', tab: '#2563eb', columns: [
    { key: 'playerId',  header: 'Player ID',  width: 120 },
    { key: 'teamId',    header: 'Team ID',    width: 120 },
    { key: 'teamName',  header: 'Team Name',  width: 190 },
    { key: 'status',    header: 'Status',     width: 95 },
    { key: 'name',      header: 'Name',       width: 180 },
    { key: 'email',     header: 'Email',      width: 220 },
    { key: 'phone',     header: 'Phone',      width: 130 },
    { key: 'studentId', header: 'Student ID', width: 110 },
    { key: 'role',      header: 'Role',       width: 95 },
    { key: 'checkedIn', header: 'Checked In', width: 95,  type: 'bool' },
    { key: 'createdAt', header: 'Created At', width: 150, type: 'date' },
    { key: 'updatedAt', header: 'Updated At', width: 150, type: 'date' },
  ]},
  [S.BRACKET]: { idKey: 'matchId', tab: '#f59e0b', columns: [
    { key: 'matchId',    header: 'Match ID',    width: 90 },
    { key: 'label',      header: 'Round Label', width: 110 },
    { key: 'round',      header: 'Round',       width: 70,  type: 'number' },
    { key: 'position',   header: 'Match #',     width: 75,  type: 'number' },
    { key: 'team1Id',    header: 'Team 1 ID',   width: 120 },
    { key: 'team1Name',  header: 'Team 1',      width: 190 },
    { key: 'team2Id',    header: 'Team 2 ID',   width: 120 },
    { key: 'team2Name',  header: 'Team 2',      width: 190 },
    { key: 'winnerId',   header: 'Winner ID',   width: 120 },
    { key: 'winnerName', header: 'Winner',      width: 190 },
    { key: 'updatedAt',  header: 'Updated At',  width: 150, type: 'date' },
  ]},
  [S.TIMERS]: { idKey: 'court', tab: '#10b981', columns: [
    { key: 'court',            header: 'Court',             width: 110 },
    { key: 'defaultSeconds',   header: 'Default Seconds',   width: 130, type: 'number' },
    { key: 'remainingSeconds', header: 'Remaining Seconds', width: 140, type: 'number' },
    { key: 'running',          header: 'Running',           width: 85,  type: 'bool' },
    { key: 'startedAt',        header: 'Started At (ms)',   width: 140, type: 'number' },
    { key: 'updatedAt',        header: 'Updated At',        width: 150, type: 'date' },
  ]},
  [S.LOG]: { idKey: 'timestamp', tab: '#94a3b8', columns: [
    { key: 'timestamp', header: 'Timestamp', width: 150, type: 'date' },
    { key: 'action',    header: 'Action',    width: 170 },
    { key: 'details',   header: 'Details',   width: 520 },
    { key: 'source',    header: 'Source',    width: 90 },
  ]},
};

/* =============================================================================
 *  HTTP ENTRY POINTS
 * ========================================================================== */

function doGet(e) {
  const p = (e && e.parameter) || {};
  return handle_(p.action || 'getState', p, p.token);
}

function doPost(e) {
  let body;
  try {
    body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
  } catch (err) {
    return json_({ ok: false, error: 'Invalid request body.', code: 'BAD_REQUEST' });
  }
  return handle_(body.action, body.payload || {}, body.token);
}

const ROUTES = {
  getState:        { fn: () => ({}) },
  register:        { fn: register_,        write: true },
  teamLookup:      { fn: teamLookup_ },
  teamRemovePlayer:{ fn: teamRemovePlayer_, write: true },
  teamDelete:      { fn: teamDelete_,      write: true },
  login:           { fn: login_ },
  logout:          { fn: logout_ },
  setSetting:      { fn: setSetting_,      write: true, admin: true },
  processWaitlist: { fn: processWaitlist_, write: true, admin: true },
  resetBracket:    { fn: resetBracket_,    write: true, admin: true },
  addTeam:         { fn: addTeam_,         write: true, admin: true },
  addPlayer:       { fn: addPlayer_,       write: true, admin: true },
  removePlayer:    { fn: removePlayerAdmin_, write: true, admin: true },
  deleteTeam:      { fn: deleteTeamAdmin_, write: true, admin: true },
  toggleCheckIn:   { fn: toggleCheckIn_,   write: true, admin: true },
  setTeamCheckIn:  { fn: setTeamCheckIn_,  write: true, admin: true },
  advanceTeam:     { fn: advanceTeam_,     write: true, admin: true },
  undoAdvance:     { fn: undoAdvance_,     write: true, admin: true },
  timer:           { fn: timerAction_,     write: true, admin: true },
};

function handle_(action, payload, token) {
  try {
    ensureSchema_();
    const route = ROUTES[action];
    if (!route) fail_('Unknown action: ' + action, 'BAD_REQUEST');

    const isAdmin = isAdminToken_(token);
    if (route.admin && !isAdmin) fail_('Your admin session has expired. Please log in again.', 'AUTH');

    const run = () => route.fn(payload || {}, isAdmin, token);
    const result = (route.write ? withLock_(run) : run()) || {};
    if (!result.state) result.state = buildState_(isAdmin);
    return json_(Object.assign({ ok: true }, result));
  } catch (err) {
    if (!err.expected) {
      try { log_('error', (action || '?') + ': ' + (err.stack || err.message)); } catch (ignored) {}
    }
    return json_({ ok: false, error: err.message || String(err), code: err.code || 'ERROR' });
  }
}

/* =============================================================================
 *  STATE (what the site renders)
 * ========================================================================== */

function buildState_(isAdmin) {
  const settings = getSettings_();
  const teams = readTable_(S.TEAMS);
  const players = readTable_(S.PLAYERS);
  const teamIds = {};
  teams.forEach(t => { teamIds[t.teamId] = true; });

  const teamsOut = teams.map(t => {
    const roster = players.filter(p => p.teamId === t.teamId && p.status !== 'Waitlist');
    const out = { id: t.teamId, name: t.name, eliminated: t.eliminated, playerCount: roster.length };
    if (isAdmin) {
      out.code = t.code;
      out.players = roster.map(playerOut_);
    }
    return out;
  });

  const waitlist = players.filter(p => p.status === 'Waitlist' || !teamIds[p.teamId]);

  const state = {
    isAdmin: !!isAdmin,
    serverTime: Date.now(),
    settings: {
      registrationOpen: settings.registrationOpen,
      waitlistOpen: settings.waitlistOpen,
      maxTeamSize: settings.maxTeamSize,
      waitlistTeamSize: settings.waitlistTeamSize,
    },
    teams: teamsOut,
    waitlistCount: waitlist.length,
    bracket: getBracket_(teams),
    timers: getTimers_(),
  };
  if (isAdmin) state.waitlist = waitlist.map(playerOut_);
  return state;
}

function playerOut_(p) {
  return {
    playerId: p.playerId,
    name: p.name,
    email: p.email,
    phone: p.phone,
    studentId: p.studentId,
    role: p.role || 'Player',
    checkedIn: !!p.checkedIn,
  };
}

/* =============================================================================
 *  REGISTRATION (public)
 * ========================================================================== */

function register_(p) {
  const settings = getSettings_();
  const mode = String(p.mode || '');
  if (['create', 'join', 'freeplay'].indexOf(mode) < 0) fail_('Unknown registration type.');

  if (mode === 'freeplay') {
    if (!settings.waitlistOpen) fail_('The waitlist is currently closed.');
  } else if (!settings.registrationOpen) {
    fail_('General registration is currently closed.');
  }

  const person = cleanPerson_(p.player || {});
  const teams = readTable_(S.TEAMS);
  const players = readTable_(S.PLAYERS);
  const now = new Date();

  if (mode === 'create') {
    const teamName = cleanText_(p.teamName, 40);
    if (!teamName) fail_('Team name is required.');
    if (teams.some(t => t.name.toLowerCase() === teamName.toLowerCase())) {
      fail_('A team named "' + teamName + '" already exists. Please pick another name.');
    }
    assertEmailAvailable_(person.email, teams, players);

    const seen = {};
    seen[person.email] = true;
    const extras = (Array.isArray(p.roster) ? p.roster : [])
      .map(r => ({
        name: cleanText_(r && r.name, 60),
        email: cleanEmail_(r && r.email),
        role: r && r.role === 'Alternate' ? 'Alternate' : 'Player',
      }))
      .filter(r => r.name);

    if (1 + extras.length > settings.maxTeamSize) {
      fail_('Teams are limited to ' + settings.maxTeamSize + ' players including the captain.');
    }
    extras.forEach(x => {
      if (!x.email) return;
      if (!isEmail_(x.email)) fail_('"' + x.email + '" is not a valid email address.');
      if (seen[x.email]) fail_('The email ' + x.email + ' is listed more than once.');
      seen[x.email] = true;
      assertEmailAvailable_(x.email, teams, players);
    });

    const team = {
      teamId: newId_('T'),
      name: teamName,
      code: uniqueTeamCode_(teams, p.teamCode),
      eliminated: false,
      createdAt: now,
      updatedAt: now,
    };
    teams.push(team);
    players.push(newPlayer_(team, person, 'Captain', now));
    extras.forEach(x => players.push(newPlayer_(team, { name: x.name, email: x.email, phone: '', studentId: '' }, x.role, now)));

    writeTable_(S.TEAMS, teams);
    writeTable_(S.PLAYERS, players);
    syncBracket_(teams);
    log_('register:create', team.name + ' (' + team.code + ') by ' + person.name + ' <' + person.email + '>, ' + (1 + extras.length) + ' players');
    return {
      message: 'Your team "' + team.name + '" has been created! Share your code (' + team.code + ') with teammates so they can join. ' +
        'Need to remove someone later? Use "Manage My Team" with the same code.',
      teamCode: team.code,
      teamName: team.name,
    };
  }

  if (mode === 'join') {
    const code = String(p.teamCode || '').trim().toUpperCase();
    if (!code) fail_('Please enter a team code.');
    const team = teams.find(t => String(t.code).toUpperCase() === code);
    if (!team) fail_('We couldn\'t find a team with the code ' + code + '. Please check and try again.');
    if (team.eliminated) fail_('"' + team.name + '" has been eliminated and can no longer add players.');

    // A captain may have pre-listed this player by email: claim that spot instead of duplicating.
    const preListed = players.find(pl => pl.teamId === team.teamId && !pl.studentId && pl.email && pl.email.toLowerCase() === person.email);
    if (preListed) {
      preListed.name = person.name;
      preListed.phone = person.phone;
      preListed.studentId = person.studentId;
      preListed.updatedAt = now;
      writeTable_(S.PLAYERS, players);
      log_('register:claim', person.name + ' <' + person.email + '> confirmed spot on ' + team.name);
      return { message: 'You have confirmed your spot on "' + team.name + '"!', teamName: team.name };
    }

    assertEmailAvailable_(person.email, teams, players);
    const rosterSize = players.filter(pl => pl.teamId === team.teamId && pl.status !== 'Waitlist').length;
    if (rosterSize >= settings.maxTeamSize) fail_('"' + team.name + '" is full (' + settings.maxTeamSize + ' players).');

    players.push(newPlayer_(team, person, 'Player', now));
    writeTable_(S.PLAYERS, players);
    log_('register:join', person.name + ' <' + person.email + '> joined ' + team.name);
    return { message: 'You have successfully joined "' + team.name + '"!', teamName: team.name };
  }

  // freeplay / waitlist
  assertEmailAvailable_(person.email, teams, players);
  players.push(newPlayer_(null, person, 'Player', now));
  writeTable_(S.PLAYERS, players);
  log_('register:waitlist', person.name + ' <' + person.email + '>');
  return { message: 'You have been added to the waitlist! We will place you on a team if spots become available.' };
}

function cleanPerson_(raw) {
  const person = {
    name: cleanText_(raw.name, 60),
    phone: cleanText_(raw.phone, 30),
    email: cleanEmail_(raw.email),
    studentId: cleanText_(raw.studentId, 30),
  };
  if (!person.name) fail_('Full name is required.');
  if (!person.phone) fail_('Phone number is required.');
  if (!person.email) fail_('Student email is required.');
  if (!isEmail_(person.email)) fail_('"' + person.email + '" is not a valid email address.');
  if (!person.studentId) fail_('Student ID is required.');
  return person;
}

function assertEmailAvailable_(email, teams, players) {
  if (!email) return;
  const teamById = {};
  teams.forEach(t => { teamById[t.teamId] = t; });
  const matches = players.filter(pl => pl.email && pl.email.toLowerCase() === email);
  if (!matches.length) return;
  if (matches.some(pl => teamById[pl.teamId] && teamById[pl.teamId].eliminated)) {
    fail_('The email ' + email + ' belongs to a player on an eliminated team. You cannot register or join another team.');
  }
  const team = teamById[matches[0].teamId];
  fail_('The email ' + email + ' is already registered' + (team ? ' on "' + team.name + '"' : ' on the waitlist') + '.');
}

function newPlayer_(team, person, role, now) {
  return {
    playerId: newId_('P'),
    teamId: team ? team.teamId : '',
    teamName: team ? team.name : '',
    status: team ? 'Rostered' : 'Waitlist',
    name: person.name,
    email: person.email,
    phone: person.phone || '',
    studentId: person.studentId || '',
    role: role,
    checkedIn: false,
    createdAt: now,
    updatedAt: now,
  };
}

/* =============================================================================
 *  TEAM SELF-SERVICE (public — whoever holds the team code can manage the team)
 * ========================================================================== */

function teamLookup_(p) {
  const team = teamByCode_(readTable_(S.TEAMS), p.teamCode);
  return { team: managedTeamOut_(team, readTable_(S.PLAYERS)) };
}

function teamRemovePlayer_(p) {
  const team = teamByCode_(readTable_(S.TEAMS), p.teamCode);
  const players = readTable_(S.PLAYERS);
  const removed = removePlayer_(players, p.playerId, team);
  log_('team:removePlayer', removed.name + ' <' + removed.email + '> removed from ' + team.name + ' (team code)');
  return { message: removed.name + ' was removed from "' + team.name + '".', team: managedTeamOut_(team, players) };
}

function teamDelete_(p) {
  const teams = readTable_(S.TEAMS);
  const team = teamByCode_(teams, p.teamCode);
  if (bracketStarted_()) fail_('The tournament has already started, so "' + team.name + '" can no longer be deleted. Please talk to an organizer.');
  const count = deleteTeam_(teams, team);
  log_('team:delete', team.name + ' (' + team.code + ') and ' + count + ' players deleted (team code)');
  return { message: '"' + team.name + '" and its roster have been deleted.' };
}

function teamByCode_(teams, code) {
  const c = String(code || '').trim().toUpperCase();
  if (!c) fail_('Please enter your team code.');
  const team = teams.find(t => String(t.code).toUpperCase() === c);
  if (!team) fail_('We couldn\'t find a team with the code ' + c + '. Please check and try again.');
  return team;
}

/** Roster as a team (not an admin) sees it: emails, IDs and phones stay redacted. */
function managedTeamOut_(team, players) {
  return {
    name: team.name,
    code: team.code,
    eliminated: team.eliminated,
    canDelete: !bracketStarted_(),
    maxTeamSize: getSettings_().maxTeamSize,
    players: players
      .filter(pl => pl.teamId === team.teamId && pl.status !== 'Waitlist')
      .map(pl => ({
        playerId: pl.playerId,
        name: pl.name,
        role: pl.role || 'Player',
        email: maskEmail_(pl.email),
        studentId: maskId_(pl.studentId),
        confirmed: !!pl.studentId,
      })),
  };
}

/** Removes a player row. If the captain leaves, the longest-standing teammate takes over. */
function removePlayer_(players, playerId, team) {
  const i = players.findIndex(pl => pl.playerId === playerId && (!team || pl.teamId === team.teamId));
  if (i < 0) fail_(team ? 'That player is not on this team.' : 'Player not found.');
  const removed = players.splice(i, 1)[0];
  if (removed.role === 'Captain' && removed.teamId) {
    const next = players
      .filter(pl => pl.teamId === removed.teamId && pl.status !== 'Waitlist')
      .sort((a, b) => (a.role === 'Alternate') - (b.role === 'Alternate') || toTime_(a.createdAt) - toTime_(b.createdAt))[0];
    if (next) {
      next.role = 'Captain';
      next.updatedAt = new Date();
    }
  }
  writeTable_(S.PLAYERS, players);
  return removed;
}

/** Deletes a team and every player on it. Returns how many players were removed. */
function deleteTeam_(teams, team) {
  const players = readTable_(S.PLAYERS);
  const keep = players.filter(pl => pl.teamId !== team.teamId);
  const remaining = teams.filter(t => t.teamId !== team.teamId);
  writeTable_(S.TEAMS, remaining);
  writeTable_(S.PLAYERS, keep);
  syncBracket_(remaining);
  return players.length - keep.length;
}

function maskEmail_(email) {
  const s = String(email || '');
  const at = s.indexOf('@');
  if (!s) return '';
  if (at < 1) return '••••••';
  return s.charAt(0) + '•••••' + s.slice(at);
}

function maskId_(id) {
  const s = String(id || '');
  if (!s) return '';
  return '•••••' + (s.length > 4 ? s.slice(-2) : '');
}

/* =============================================================================
 *  ADMIN AUTH
 * ========================================================================== */

function login_(p) {
  const cache = CacheService.getScriptCache();
  const fails = Number(cache.get('loginFails') || 0);
  if (fails >= APP.MAX_LOGIN_FAILURES) fail_('Too many failed attempts. Please wait 10 minutes and try again.', 'AUTH');

  const password = PropertiesService.getScriptProperties().getProperty('ADMIN_PASSWORD') || APP.DEFAULT_ADMIN_PASSWORD;
  if (String(p.password || '') !== password) {
    cache.put('loginFails', String(fails + 1), APP.LOGIN_LOCK_SECONDS);
    log_('login:failed', 'Incorrect password attempt');
    fail_('Incorrect admin password.', 'AUTH');
  }
  cache.remove('loginFails');
  const token = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
  cache.put('session:' + token, '1', APP.SESSION_SECONDS);
  log_('login', 'Admin logged in');
  return { token: token, state: buildState_(true) };
}

function logout_(p, isAdmin, token) {
  if (token) CacheService.getScriptCache().remove('session:' + token);
  return { state: buildState_(false) };
}

function isAdminToken_(token) {
  if (!token || typeof token !== 'string') return false;
  const cache = CacheService.getScriptCache();
  const key = 'session:' + token;
  if (!cache.get(key)) return false;
  cache.put(key, '1', APP.SESSION_SECONDS); // sliding expiry
  return true;
}

/* =============================================================================
 *  ADMIN ACTIONS
 * ========================================================================== */

function setSetting_(p) {
  const def = SETTINGS_DEFAULTS.find(d => d.key === p.key);
  if (!def) fail_('Unknown setting: ' + p.key);
  let value = coerceSetting_(p.value, def);
  if (def.type === 'number') {
    if (!(value >= def.min && value <= def.max)) fail_(def.key + ' must be between ' + def.min + ' and ' + def.max + '.');
  }
  const rows = readTable_(S.SETTINGS);
  const row = rows.find(r => r.key === def.key);
  if (row) row.value = value;
  else rows.push({ key: def.key, value: value, description: def.description });
  writeTable_(S.SETTINGS, rows);
  formatSettingsRows_(rows);
  log_('setting', def.key + ' = ' + value);
  return {};
}

function processWaitlist_() {
  const settings = getSettings_();
  const target = settings.waitlistTeamSize;
  const teams = readTable_(S.TEAMS);
  const players = readTable_(S.PLAYERS);
  const teamIds = {};
  teams.forEach(t => { teamIds[t.teamId] = true; });

  const unassigned = players
    .filter(p => p.status === 'Waitlist' || !teamIds[p.teamId])
    .sort((a, b) => toTime_(a.createdAt) - toTime_(b.createdAt));
  if (!unassigned.length) fail_('There are no free agents on the waitlist right now.');

  const now = new Date();
  const log = [];
  const assign = (p, team, role) => {
    p.teamId = team.teamId;
    p.teamName = team.name;
    p.status = 'Rostered';
    p.role = role;
    p.updatedAt = now;
  };

  teams.forEach(team => {
    if (team.eliminated) return;
    let size = players.filter(p => p.teamId === team.teamId && p.status !== 'Waitlist').length;
    while (size < target && unassigned.length) {
      const p = unassigned.shift();
      assign(p, team, 'Player');
      size++;
      log.push('Assigned ' + p.name + ' to ' + team.name);
    }
  });

  while (unassigned.length >= target) {
    const group = unassigned.splice(0, target);
    const team = {
      teamId: newId_('T'),
      name: uniqueTeamName_(teams, 'Waitlist Team'),
      code: uniqueTeamCode_(teams),
      eliminated: false,
      createdAt: now,
      updatedAt: now,
    };
    teams.push(team);
    group.forEach((p, i) => assign(p, team, i === 0 ? 'Captain' : 'Player'));
    log.push('Created new team ' + team.name + ' (' + team.code + ') with ' + target + ' free agents.');
  }

  writeTable_(S.TEAMS, teams);
  writeTable_(S.PLAYERS, players);
  syncBracket_(teams);
  log_('waitlist:process', log.join(' | ') || 'No changes');
  return { log: log, remaining: unassigned.length };
}

function resetBracket_() {
  const teams = readTable_(S.TEAMS);
  const now = new Date();
  teams.forEach(t => { t.eliminated = false; t.updatedAt = now; });
  writeTable_(S.TEAMS, teams);
  writeTable_(S.BRACKET, []);
  syncBracket_(teams);
  const props = PropertiesService.getScriptProperties();
  props.getKeys().forEach(k => { if (k.indexOf('checkInSnapshot:') === 0) props.deleteProperty(k); });
  log_('bracket:reset', 'All match progress cleared, all teams reinstated');
  return {};
}

function addTeam_(p) {
  const teams = readTable_(S.TEAMS);
  const now = new Date();
  const requested = cleanText_(p.name, 40);
  if (requested && teams.some(t => t.name.toLowerCase() === requested.toLowerCase())) {
    fail_('A team named "' + requested + '" already exists.');
  }
  const team = {
    teamId: newId_('T'),
    name: requested || uniqueTeamName_(teams, 'New Blank Team'),
    code: uniqueTeamCode_(teams),
    eliminated: false,
    createdAt: now,
    updatedAt: now,
  };
  teams.push(team);
  writeTable_(S.TEAMS, teams);
  syncBracket_(teams);
  log_('team:add', team.name + ' (' + team.code + ')');
  return { teamId: team.teamId };
}

function addPlayer_(p) {
  const teams = readTable_(S.TEAMS);
  const players = readTable_(S.PLAYERS);
  const team = teams.find(t => t.teamId === p.teamId);
  if (!team) fail_('Team not found.');

  const person = {
    name: cleanText_(p.name, 60),
    email: cleanEmail_(p.email),
    studentId: cleanText_(p.studentId, 30),
    phone: cleanText_(p.phone, 30),
  };
  if (!person.name || !person.email || !person.studentId) {
    fail_('Please fill out the Name, Email, and Student ID fields to add a player.');
  }
  if (!isEmail_(person.email)) fail_('"' + person.email + '" is not a valid email address.');
  assertEmailAvailable_(person.email, teams, players);

  const role = ['Player', 'Captain', 'Alternate'].indexOf(p.role) >= 0 ? p.role : 'Player';
  players.push(newPlayer_(team, person, role, new Date()));
  writeTable_(S.PLAYERS, players);
  log_('player:add', person.name + ' <' + person.email + '> → ' + team.name + ' as ' + role);
  return {};
}

function removePlayerAdmin_(p) {
  const players = readTable_(S.PLAYERS);
  const removed = removePlayer_(players, p.playerId, null);
  log_('player:remove', removed.name + ' <' + removed.email + '>' + (removed.teamName ? ' removed from ' + removed.teamName : ' removed from waitlist'));
  return {};
}

function deleteTeamAdmin_(p) {
  const teams = readTable_(S.TEAMS);
  const team = teams.find(t => t.teamId === p.teamId);
  if (!team) fail_('Team not found.');
  if (bracketStarted_()) fail_('Matches have already been played. Reset the bracket before deleting a team.');
  const count = deleteTeam_(teams, team);
  log_('team:delete', team.name + ' (' + team.code + ') and ' + count + ' players deleted by admin');
  return {};
}

function toggleCheckIn_(p) {
  const players = readTable_(S.PLAYERS);
  const player = players.find(pl => pl.playerId === p.playerId);
  if (!player) fail_('Player not found.');
  player.checkedIn = !player.checkedIn;
  player.updatedAt = new Date();
  writeTable_(S.PLAYERS, players);
  log_('checkin', player.name + ' → ' + (player.checkedIn ? 'IN' : 'OUT'));
  return {};
}

function setTeamCheckIn_(p) {
  const teams = readTable_(S.TEAMS);
  const team = teams.find(t => t.teamId === p.teamId);
  if (!team) fail_('Team not found.');
  const value = !!p.checkedIn;
  const now = new Date();
  const players = readTable_(S.PLAYERS);
  players.forEach(pl => {
    if (pl.teamId === team.teamId && pl.status !== 'Waitlist') {
      pl.checkedIn = value;
      pl.updatedAt = now;
    }
  });
  writeTable_(S.PLAYERS, players);
  log_('checkin:team', team.name + ' → ' + (value ? 'all IN' : 'reset'));
  return {};
}

function advanceTeam_(p) {
  const teams = readTable_(S.TEAMS);
  const rounds = getBracket_(teams);
  const r = Number(p.round), m = Number(p.pos), slot = Number(p.slot);
  if (!rounds[r] || !rounds[r][m] || r >= rounds.length - 1 || (slot !== 1 && slot !== 2)) fail_('Invalid match.');

  const match = rounds[r][m];
  const winnerId = slot === 1 ? match.team1Id : match.team2Id;
  const loserId = slot === 1 ? match.team2Id : match.team1Id;
  if (!winnerId) fail_('There is no team in that slot.');
  if (match.winnerId) {
    if (match.winnerId === winnerId) return {};
    fail_('That match already has a winner. Click the winner to undo the result first.');
  }
  if (!loserId && slotPending_(rounds, r, m, slot === 1 ? 2 : 1)) {
    fail_('The other team for this match hasn\'t been decided yet.');
  }
  const winner = teams.find(t => t.teamId === winnerId);
  if (!winner) fail_('That team no longer exists.');
  if (winner.eliminated) fail_('"' + winner.name + '" has already been eliminated.');

  const now = new Date();
  match.winnerId = winnerId;
  let loserName = 'Unassigned';
  if (loserId) {
    const loser = teams.find(t => t.teamId === loserId);
    if (loser) {
      loser.eliminated = true;
      loser.updatedAt = now;
      loserName = loser.name;
    }
  }
  const next = rounds[r + 1][Math.floor(m / 2)];
  next[m % 2 === 0 ? 'team1Id' : 'team2Id'] = winnerId;

  // Moving on to another match means checking in again; remember who was in so an undo can restore it.
  if (r + 1 < rounds.length - 1) {
    const players = readTable_(S.PLAYERS);
    const wasIn = [];
    players.forEach(pl => {
      if (pl.teamId === winnerId && pl.checkedIn) {
        wasIn.push(pl.playerId);
        pl.checkedIn = false;
        pl.updatedAt = now;
      }
    });
    PropertiesService.getScriptProperties().setProperty(checkInSnapshotKey_(r, m), JSON.stringify(wasIn));
    if (wasIn.length) writeTable_(S.PLAYERS, players);
  }

  writeTable_(S.TEAMS, teams);
  writeBracket_(rounds, teams);
  log_('bracket:advance', bracketLabel_(r, rounds.length) + ' match ' + (m + 1) + ': ' + winner.name + ' def. ' + loserName);
  return {};
}

function undoAdvance_(p) {
  const teams = readTable_(S.TEAMS);
  const rounds = getBracket_(teams);
  const r = Number(p.round), m = Number(p.pos);
  const match = rounds[r] && rounds[r][m];
  if (!match || r >= rounds.length - 1) fail_('Invalid match.');
  if (!match.winnerId) fail_('That match has no result to undo.');

  const winnerId = match.winnerId;
  const winner = teams.find(t => t.teamId === winnerId);
  const next = rounds[r + 1][Math.floor(m / 2)];
  if (next.winnerId) {
    fail_('"' + (winner ? winner.name : 'That team') + '" has already played its next match. Undo that result first.');
  }
  const key = m % 2 === 0 ? 'team1Id' : 'team2Id';
  if (next[key] === winnerId) next[key] = '';
  match.winnerId = '';

  const now = new Date();
  const loserId = match.team1Id === winnerId ? match.team2Id : match.team1Id;
  const loser = loserId && teams.find(t => t.teamId === loserId);
  if (loser) {
    loser.eliminated = false;
    loser.updatedAt = now;
  }

  const props = PropertiesService.getScriptProperties();
  const snapKey = checkInSnapshotKey_(r, m);
  const snap = props.getProperty(snapKey);
  if (snap) {
    const wasIn = {};
    JSON.parse(snap).forEach(id => { wasIn[id] = true; });
    const players = readTable_(S.PLAYERS);
    players.forEach(pl => {
      if (wasIn[pl.playerId] && pl.teamId === winnerId) {
        pl.checkedIn = true;
        pl.updatedAt = now;
      }
    });
    writeTable_(S.PLAYERS, players);
    props.deleteProperty(snapKey);
  }

  writeTable_(S.TEAMS, teams);
  const stillPlaying = rounds.some(round => round.some(x => x.winnerId));
  writeBracket_(stillPlaying ? rounds : computeBracket_(teams), teams);
  log_('bracket:undo', bracketLabel_(r, rounds.length) + ' match ' + (m + 1) + ': result for ' + (winner ? winner.name : winnerId) + ' undone');
  return {};
}

function checkInSnapshotKey_(r, m) {
  return 'checkInSnapshot:R' + (r + 1) + '-M' + (m + 1);
}

function timerAction_(p) {
  const rows = readTable_(S.TIMERS);
  const i = Number(p.index);
  const t = rows[i];
  if (!t) fail_('Timer not found.');
  const now = Date.now();

  switch (p.op) {
    case 'start':
      if (t.running) break;
      if (!(t.remainingSeconds > 0)) t.remainingSeconds = t.defaultSeconds;
      t.running = true;
      t.startedAt = now;
      break;
    case 'pause':
      t.remainingSeconds = Math.max(0, Math.ceil(timerRemaining_(t, now)));
      t.running = false;
      t.startedAt = '';
      break;
    case 'reset':
      t.running = false;
      t.startedAt = '';
      t.remainingSeconds = t.defaultSeconds;
      break;
    case 'setDefault': {
      const mins = parseInt(p.minutes, 10);
      if (!(mins >= 1 && mins <= 60)) fail_('Minutes must be between 1 and 60.');
      t.defaultSeconds = mins * 60;
      if (!t.running) t.remainingSeconds = t.defaultSeconds;
      break;
    }
    default:
      fail_('Unknown timer operation.');
  }
  t.updatedAt = new Date();
  writeTable_(S.TIMERS, rows);
  return {};
}

/* =============================================================================
 *  BRACKET
 * ========================================================================== */

/**
 * Single-elimination layout in Teams-sheet order (mirrored in index.html).
 * Every first-round match gets one team before any gets a second, so open
 * slots are spread out and no match is ever empty on both sides.
 */
function computeBracket_(teams) {
  const teamCount = Math.max(2, teams.length);
  const numRounds = Math.ceil(Math.log2(teamCount)) + 1; // last "round" is the champion slot
  const rounds = [];
  for (let r = 0; r < numRounds; r++) {
    const count = r === numRounds - 1 ? 1 : Math.pow(2, numRounds - r - 2);
    const round = [];
    for (let m = 0; m < count; m++) round.push({ round: r, pos: m, team1Id: '', team2Id: '', winnerId: '' });
    rounds.push(round);
  }
  const first = rounds[0];
  teams.forEach((t, i) => {
    if (i < first.length) first[i].team1Id = t.teamId;
    else if (i < first.length * 2) first[i - first.length].team2Id = t.teamId;
  });
  return rounds;
}

function bracketStarted_() {
  return readTable_(S.BRACKET).some(r => r.winnerId);
}

/** True while a slot is still waiting on an undecided match that has teams in it (shown as "TBD"). */
function slotPending_(rounds, r, m, slot) {
  if (r === 0) return false;
  const fm = 2 * m + slot - 1;
  const feeder = rounds[r - 1][fm];
  return !!feeder && !feeder.winnerId && subtreeHasTeams_(rounds, r - 1, fm);
}

function subtreeHasTeams_(rounds, r, m) {
  const match = rounds[r] && rounds[r][m];
  if (!match) return false;
  if (match.team1Id || match.team2Id) return true;
  return r > 0 && (subtreeHasTeams_(rounds, r - 1, 2 * m) || subtreeHasTeams_(rounds, r - 1, 2 * m + 1));
}

/** Stored bracket once play has started, otherwise a fresh layout from the current teams. */
function getBracket_(teams) {
  const rows = readTable_(S.BRACKET);
  if (!rows.some(r => r.winnerId)) return computeBracket_(teams);

  const numRounds = Math.max.apply(null, rows.map(r => Number(r.round) || 0));
  const rounds = [];
  for (let r = 0; r < numRounds; r++) {
    const count = r === numRounds - 1 ? 1 : Math.pow(2, numRounds - r - 2);
    const round = [];
    for (let m = 0; m < count; m++) round.push({ round: r, pos: m, team1Id: '', team2Id: '', winnerId: '' });
    rounds.push(round);
  }
  rows.forEach(row => {
    const match = rounds[Number(row.round) - 1] && rounds[Number(row.round) - 1][Number(row.position) - 1];
    if (!match) return;
    match.team1Id = row.team1Id || '';
    match.team2Id = row.team2Id || '';
    match.winnerId = row.winnerId || '';
  });
  return rounds;
}

/** Keep the Bracket sheet in step with the teams until the first result is recorded. */
function syncBracket_(teams) {
  const rows = readTable_(S.BRACKET);
  if (rows.some(r => r.winnerId)) return;
  writeBracket_(computeBracket_(teams), teams);
}

function writeBracket_(rounds, teams) {
  const names = {};
  teams.forEach(t => { names[t.teamId] = t.name; });
  const now = new Date();
  const rows = [];
  rounds.forEach((round, r) => round.forEach((m, i) => {
    rows.push({
      matchId: 'R' + (r + 1) + '-M' + (i + 1),
      label: bracketLabel_(r, rounds.length),
      round: r + 1,
      position: i + 1,
      team1Id: m.team1Id,
      team1Name: names[m.team1Id] || (m.team1Id ? '?' : ''),
      team2Id: m.team2Id,
      team2Name: names[m.team2Id] || (m.team2Id ? '?' : ''),
      winnerId: m.winnerId,
      winnerName: names[m.winnerId] || '',
      updatedAt: now,
    });
  }));
  writeTable_(S.BRACKET, rows);
}

function bracketLabel_(r, numRounds) {
  if (r === numRounds - 1) return 'Champion';
  if (r === numRounds - 2) return 'Finals';
  return 'Round ' + (r + 1);
}

/* =============================================================================
 *  TIMERS
 * ========================================================================== */

function getTimers_() {
  const now = Date.now();
  return readTable_(S.TIMERS).map(t => {
    const remaining = Math.max(0, timerRemaining_(t, now));
    const running = !!t.running && remaining > 0;
    return {
      name: t.court,
      defaultTime: Number(t.defaultSeconds) || APP.DEFAULT_TIMER_SECONDS,
      timeRemaining: Math.ceil(remaining),
      isRunning: running,
      // When the clock hits zero (absolute ms); kept after it finishes so clients can fire the alert.
      endsAt: t.running && t.startedAt ? Number(t.startedAt) + Number(t.remainingSeconds) * 1000 : null,
    };
  });
}

function timerRemaining_(t, now) {
  const base = Number(t.remainingSeconds) || 0;
  if (!t.running || !t.startedAt) return base;
  return base - (now - Number(t.startedAt)) / 1000;
}

/* =============================================================================
 *  SETTINGS
 * ========================================================================== */

function getSettings_() {
  const rows = readTable_(S.SETTINGS);
  const out = {};
  SETTINGS_DEFAULTS.forEach(def => {
    const row = rows.find(r => r.key === def.key);
    out[def.key] = row ? coerceSetting_(row.value, def) : def.value;
    if (def.type === 'number' && !(out[def.key] >= def.min && out[def.key] <= def.max)) out[def.key] = def.value;
  });
  return out;
}

function coerceSetting_(v, def) {
  if (def.type === 'bool') return toBool_(v);
  if (def.type === 'number') {
    const n = Number(v);
    return isNaN(n) ? def.value : Math.round(n);
  }
  return v;
}

/* =============================================================================
 *  SCHEMA / AUTO-SETUP
 * ========================================================================== */

/** Run once from the editor (or the Dodgeball menu). Safe to run again any time — it repairs, never deletes. */
function setup() {
  ensureSchema_(true);
  log_('setup', 'Sheets created/verified (schema v' + APP.SCHEMA_VERSION + ')', 'menu');
  const url = webAppUrl_();
  const msg = 'All sheets are ready.\n\n' + (url
    ? 'Web app URL:\n' + url
    : 'Next: Deploy ▸ New deployment ▸ Web app (Execute as: Me, Access: Anyone), then paste the /exec URL into API_URL in index.html.');
  notify_(msg);
}

function ensureSchema_(force) {
  const props = PropertiesService.getScriptProperties();
  const ss = ss_();
  const names = ss.getSheets().map(sh => sh.getName());
  const missing = Object.keys(SCHEMA).some(n => names.indexOf(n) < 0);
  if (!force && !missing && props.getProperty('SCHEMA_VERSION') === APP.SCHEMA_VERSION) return;

  withLock_(() => {
    Object.keys(SCHEMA).forEach((name, i) => setupSheet_(name, i));
    seedSettings_();
    seedTimers_();
    if (!props.getProperty('ADMIN_PASSWORD')) props.setProperty('ADMIN_PASSWORD', APP.DEFAULT_ADMIN_PASSWORD);
    removeBlankDefaultSheet_();
    props.setProperty('SCHEMA_VERSION', APP.SCHEMA_VERSION);
  });
}

function setupSheet_(name, index) {
  const ss = ss_();
  const def = SCHEMA[name];
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name, Math.min(index, ss.getSheets().length));

  // Keep any existing headers (and their order); append the ones that are missing.
  const lastCol = Math.max(sh.getLastColumn(), 1);
  const headers = sh.getRange(1, 1, 1, lastCol).getValues()[0].map(h => String(h).trim());
  while (headers.length && !headers[headers.length - 1]) headers.pop();
  def.columns.forEach(c => { if (headers.indexOf(c.header) < 0) headers.push(c.header); });

  if (sh.getMaxColumns() < headers.length) sh.insertColumnsAfter(sh.getMaxColumns(), headers.length - sh.getMaxColumns());
  if (sh.getMaxRows() < 2) sh.insertRowsAfter(sh.getMaxRows(), 100);

  sh.getRange(1, 1, 1, headers.length)
    .setValues([headers])
    .setFontWeight('bold')
    .setBackground(APP.HEADER_BG)
    .setFontColor(APP.HEADER_FG)
    .setVerticalAlignment('middle');
  sh.setFrozenRows(1);
  sh.setRowHeight(1, 30);
  if (def.tab) sh.setTabColor(def.tab);

  const bodyRows = sh.getMaxRows() - 1;
  def.columns.forEach(c => {
    const col = headers.indexOf(c.header) + 1;
    if (c.width) sh.setColumnWidth(col, c.width);
    const body = sh.getRange(2, col, bodyRows, 1);
    if (c.type === 'date') body.setNumberFormat(APP.DATE_FORMAT);
    else if (c.type === 'number') body.setNumberFormat('0');
  });
}

function seedSettings_() {
  const rows = readTable_(S.SETTINGS);
  SETTINGS_DEFAULTS.forEach(def => {
    const row = rows.find(r => r.key === def.key);
    if (row) row.description = def.description;
    else rows.push({ key: def.key, value: def.value, description: def.description });
  });
  writeTable_(S.SETTINGS, rows);
  formatSettingsRows_(rows);
}

/** Checkboxes on boolean setting values, so they can be flipped right in the Sheet. */
function formatSettingsRows_(rows) {
  const sh = sheet_(S.SETTINGS);
  const valueCol = headerIndex_(sh, 'Value');
  if (!valueCol) return;
  rows.forEach((row, i) => {
    const def = SETTINGS_DEFAULTS.find(d => d.key === row.key);
    const cell = sh.getRange(i + 2, valueCol);
    if (def && def.type === 'bool') {
      cell.setDataValidation(SpreadsheetApp.newDataValidation().requireCheckbox().build());
    } else {
      cell.clearDataValidations();
    }
  });
}

function seedTimers_() {
  if (readTable_(S.TIMERS).length) return;
  const now = new Date();
  writeTable_(S.TIMERS, APP.DEFAULT_COURTS.map(court => ({
    court: court,
    defaultSeconds: APP.DEFAULT_TIMER_SECONDS,
    remainingSeconds: APP.DEFAULT_TIMER_SECONDS,
    running: false,
    startedAt: '',
    updatedAt: now,
  })));
}

function removeBlankDefaultSheet_() {
  const ss = ss_();
  ['Sheet1', 'Sheet 1'].forEach(n => {
    const sh = ss.getSheetByName(n);
    if (sh && sh.getLastRow() === 0 && ss.getSheets().length > 1) ss.deleteSheet(sh);
  });
}

/* =============================================================================
 *  TABLE HELPERS (sheet rows <-> plain objects, matched by header text)
 * ========================================================================== */

function readTable_(name) {
  const def = SCHEMA[name];
  const sh = sheet_(name);
  const values = sh.getDataRange().getValues();
  if (values.length < 2) return [];

  const headers = values[0].map(h => String(h).trim());
  const known = {};
  def.columns.forEach(c => { known[c.header] = true; });
  const idx = {};
  def.columns.forEach(c => { idx[c.key] = headers.indexOf(c.header); });
  const idCol = idx[def.idKey];

  const rows = [];
  for (let r = 1; r < values.length; r++) {
    const row = values[r];
    if (idCol < 0 || row[idCol] === '' || row[idCol] === null) continue;
    const obj = {};
    def.columns.forEach(c => { obj[c.key] = fromCell_(idx[c.key] >= 0 ? row[idx[c.key]] : '', c.type); });
    const extra = {};
    headers.forEach((h, i) => { if (h && !known[h]) extra[h] = row[i]; });
    obj._extra = extra;
    rows.push(obj);
  }
  return rows;
}

function writeTable_(name, rows) {
  const def = SCHEMA[name];
  const sh = sheet_(name);
  const lastCol = sh.getLastColumn();
  const headers = sh.getRange(1, 1, 1, lastCol).getValues()[0].map(h => String(h).trim());
  const byHeader = {};
  def.columns.forEach(c => { byHeader[c.header] = c; });

  const out = rows.map(o => headers.map(h => {
    const c = byHeader[h];
    if (!c) return o._extra && h in o._extra ? o._extra[h] : '';
    return toCell_(o[c.key], c.type);
  }));

  const lastRow = sh.getLastRow();
  if (lastRow > 1) sh.getRange(2, 1, lastRow - 1, lastCol).clearContent();
  if (out.length > sh.getMaxRows() - 1) sh.insertRowsAfter(sh.getMaxRows(), out.length - (sh.getMaxRows() - 1) + 50);

  // Checkboxes only on populated rows.
  def.columns.forEach(c => {
    if (c.type !== 'bool') return;
    const col = headers.indexOf(c.header) + 1;
    if (!col) return;
    sh.getRange(2, col, sh.getMaxRows() - 1, 1).clearDataValidations();
    if (out.length) sh.getRange(2, col, out.length, 1).setDataValidation(SpreadsheetApp.newDataValidation().requireCheckbox().build());
  });

  if (out.length) sh.getRange(2, 1, out.length, lastCol).setValues(out);
}

function fromCell_(v, type) {
  switch (type) {
    case 'bool':   return toBool_(v);
    case 'number': return v === '' || v === null || isNaN(Number(v)) ? '' : Number(v);
    case 'date':   return v instanceof Date ? v : (v ? new Date(v) : '');
    case 'raw':    return v;
    default:       return v === null || v === undefined ? '' : String(v).trim();
  }
}

function toCell_(v, type) {
  switch (type) {
    case 'bool':   return !!v;
    case 'number': return v === '' || v === null || v === undefined || isNaN(Number(v)) ? '' : Number(v);
    case 'date':   return v instanceof Date ? v : (v ? new Date(v) : '');
    case 'raw':    return typeof v === 'string' ? safeText_(v) : v;
    default:       return safeText_(v);
  }
}

/**
 * Store user text as literal text: the leading apostrophe stops Sheets from
 * evaluating formulas (=IMPORTXML…) and from mangling IDs/phones ("00123", "+1…").
 */
function safeText_(v) {
  const s = v === null || v === undefined ? '' : String(v);
  return s ? "'" + s : '';
}

function headerIndex_(sh, header) {
  const headers = sh.getRange(1, 1, 1, Math.max(sh.getLastColumn(), 1)).getValues()[0].map(h => String(h).trim());
  return headers.indexOf(header) + 1;
}

/* =============================================================================
 *  SMALL UTILITIES
 * ========================================================================== */

function ss_() {
  return SpreadsheetApp.getActiveSpreadsheet();
}

function sheet_(name) {
  const sh = ss_().getSheetByName(name);
  if (!sh) fail_('Missing sheet "' + name + '". Run setup() from the Apps Script editor.');
  return sh;
}

function withLock_(fn) {
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) fail_('The server is busy. Please try again in a moment.', 'BUSY');
  try {
    return fn();
  } finally {
    SpreadsheetApp.flush();
    lock.releaseLock();
  }
}

function log_(action, details, source) {
  const sh = ss_().getSheetByName(S.LOG);
  if (!sh) return;
  sh.appendRow([new Date(), safeText_(action), safeText_(String(details || '').slice(0, 2000)), safeText_(source || 'web')]);
}

function fail_(message, code) {
  const err = new Error(message);
  err.code = code || 'ERROR';
  err.expected = true;
  throw err;
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

function newId_(prefix) {
  return prefix + '-' + Utilities.getUuid().replace(/-/g, '').slice(0, 8).toUpperCase();
}

function uniqueTeamCode_(teams, requested) {
  const used = {};
  teams.forEach(t => { used[String(t.code).toUpperCase()] = true; });
  const req = String(requested || '').trim().toUpperCase();
  if (/^[A-Z0-9]{4,10}$/.test(req) && !used[req]) return req;
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  for (;;) {
    let code = '';
    for (let i = 0; i < 6; i++) code += chars.charAt(Math.floor(Math.random() * chars.length));
    if (!used[code]) return code;
  }
}

function uniqueTeamName_(teams, base) {
  const taken = {};
  teams.forEach(t => { taken[t.name.toLowerCase()] = true; });
  for (let n = 1; ; n++) {
    const name = base + ' ' + n;
    if (!taken[name.toLowerCase()]) return name;
  }
}

function cleanText_(v, max) {
  return String(v === null || v === undefined ? '' : v).replace(/[\u0000-\u001f]/g, ' ').replace(/\s+/g, ' ').trim().slice(0, max || 100);
}

function cleanEmail_(v) {
  return cleanText_(v, 120).toLowerCase();
}

function isEmail_(v) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v);
}

function toBool_(v) {
  return v === true || /^(true|yes|y|1|x|open)$/i.test(String(v).trim());
}

function toTime_(v) {
  return v instanceof Date ? v.getTime() : (v ? new Date(v).getTime() || 0 : 0);
}

function webAppUrl_() {
  try { return ScriptApp.getService().getUrl() || ''; } catch (e) { return ''; }
}

function notify_(msg) {
  try {
    SpreadsheetApp.getUi().alert('Dodgeball After Dark', msg, SpreadsheetApp.getUi().ButtonSet.OK);
  } catch (e) {
    Logger.log(msg); // running from the script editor: check the Execution log
  }
}

/* =============================================================================
 *  SPREADSHEET MENU (Dodgeball ▸ …)
 * ========================================================================== */

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Dodgeball')
    .addItem('Set up / repair sheets', 'setup')
    .addItem('Set admin password', 'setAdminPassword')
    .addItem('Show web app URL & setup help', 'showSetupHelp')
    .addSeparator()
    .addItem('Load demo teams', 'loadDemoData')
    .addItem('Reset bracket progress', 'resetBracketFromMenu')
    .addItem('Stop & reset all timers', 'resetTimersFromMenu')
    .addSeparator()
    .addItem('Clear ALL tournament data…', 'clearAllData')
    .addToUi();
}

function setAdminPassword() {
  const ui = SpreadsheetApp.getUi();
  const res = ui.prompt('Set admin password', 'Enter the new admin password (min 6 characters):', ui.ButtonSet.OK_CANCEL);
  if (res.getSelectedButton() !== ui.Button.OK) return;
  const pw = res.getResponseText();
  if (!pw || pw.length < 6) {
    ui.alert('Password not changed — it must be at least 6 characters.');
    return;
  }
  PropertiesService.getScriptProperties().setProperty('ADMIN_PASSWORD', pw);
  log_('admin:password', 'Admin password changed', 'menu');
  ui.alert('Admin password updated. Existing admin sessions stay logged in until they expire.');
}

function showSetupHelp() {
  ensureSchema_();
  const url = webAppUrl_();
  notify_(
    (url ? 'Web app URL (paste into API_URL in index.html):\n' + url + '\n\n'
         : 'Not deployed yet.\nExtensions ▸ Apps Script ▸ Deploy ▸ New deployment ▸ Web app\nExecute as: Me · Who has access: Anyone\n\n') +
    'After changing the script: Deploy ▸ Manage deployments ▸ edit ▸ New version ▸ Deploy.'
  );
}

function loadDemoData() {
  ensureSchema_();
  withLock_(() => {
    const teams = readTable_(S.TEAMS);
    const players = readTable_(S.PLAYERS);
    const now = new Date();
    const demo = [
      ['Average Joes', 'Peter L', 'peter@test.com', '123'],
      ['Globo Gym', 'White G', 'white@test.com', '124'],
      ['Skillz That Killz', 'Bob', 'bob@test.com', '125'],
      ['Lumberjacks', 'Tim', 'tim@test.com', '126'],
      ['Tune Squad', 'Bugz', 'bugz@test.com', '127'],
    ];
    demo.forEach(d => {
      if (teams.some(t => t.name === d[0])) return;
      const team = { teamId: newId_('T'), name: d[0], code: uniqueTeamCode_(teams), eliminated: false, createdAt: now, updatedAt: now };
      teams.push(team);
      players.push(newPlayer_(team, { name: d[1], email: d[2], phone: '555-0100', studentId: d[3] }, 'Captain', now));
    });
    [['Free Agent 1', 'f1@test.com', '901', '555-101'], ['Free Agent 2', 'f2@test.com', '902', '555-102']].forEach(f => {
      if (players.some(p => p.email === f[1])) return;
      players.push(newPlayer_(null, { name: f[0], email: f[1], studentId: f[2], phone: f[3] }, 'Player', now));
    });
    writeTable_(S.TEAMS, teams);
    writeTable_(S.PLAYERS, players);
    syncBracket_(teams);
  });
  log_('demo', 'Demo teams loaded', 'menu');
  notify_('Demo teams and waitlist players loaded.');
}

function resetBracketFromMenu() {
  const ui = SpreadsheetApp.getUi();
  if (ui.alert('Reset bracket?', 'This clears all match results and un-eliminates every team.', ui.ButtonSet.YES_NO) !== ui.Button.YES) return;
  ensureSchema_();
  withLock_(() => resetBracket_());
  notify_('Bracket reset.');
}

function resetTimersFromMenu() {
  ensureSchema_();
  withLock_(() => {
    const rows = readTable_(S.TIMERS);
    const now = new Date();
    rows.forEach(t => {
      t.running = false;
      t.startedAt = '';
      t.remainingSeconds = t.defaultSeconds || APP.DEFAULT_TIMER_SECONDS;
      t.updatedAt = now;
    });
    writeTable_(S.TIMERS, rows);
  });
  notify_('All timers stopped and reset.');
}

function clearAllData() {
  const ui = SpreadsheetApp.getUi();
  const res = ui.prompt('Clear ALL tournament data',
    'This permanently deletes every team, player, bracket result and log entry (settings and timers are kept).\n\nType DELETE to confirm:',
    ui.ButtonSet.OK_CANCEL);
  if (res.getSelectedButton() !== ui.Button.OK || res.getResponseText().trim() !== 'DELETE') return;
  ensureSchema_();
  withLock_(() => {
    writeTable_(S.TEAMS, []);
    writeTable_(S.PLAYERS, []);
    writeTable_(S.BRACKET, []);
    writeTable_(S.LOG, []);
    syncBracket_([]);
  });
  log_('clear', 'All tournament data cleared', 'menu');
  notify_('All tournament data cleared.');
}
