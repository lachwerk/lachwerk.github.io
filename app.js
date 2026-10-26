/* Lachwerk – App ohne Anmeldung.
 * Live-Modus: spricht direkt mit den Supabase-Funktionen aus supabase.sql.
 * Demo-Modus: gleiche Oberfläche, Daten nur im Browser (localStorage).
 */
(function () {
  "use strict";

  const CFG = window.LACHWERK_CONFIG || {};
  const LIVE = Boolean(CFG.supabaseUrl && CFG.supabaseAnonKey);
  const CATS = { flachwitze: "Flachwitze", wortspiele: "Wortspiele", tiere: "Tiere", schule: "Schule", buero: "Büro", nerd: "Nerd", schwarz: "Schwarzer Humor", einzeiler: "Einzeiler" };
  const RANGES = {
    new: { label: "Newcomer: neue Witze der letzten 6 Stunden, neueste zuerst", best: "Ganz frisch" },
    day: { label: "Beste Witze der letzten 24 Stunden", best: "Tages&shy;bester" },
    week: { label: "Beste Witze der letzten 7 Tage", best: "Wochen&shy;bester" },
    all: { label: "Beste Witze aller Zeiten (ab 20 Stimmen)", best: "Rekord" },
  };
  const PAGE = 30;
  const DUP_THRESHOLD = 0.6;
  const DEMO_ADMIN_KEY = "demo-moderation";

  /* ───────── Speicher & Geräte-ID ───────── */
  const memory = {};
  const store = {
    get(k, d) { try { const v = localStorage.getItem("lw_" + k); return v ? JSON.parse(v) : d; } catch (e) { return k in memory ? memory[k] : d; } },
    set(k, v) { try { localStorage.setItem("lw_" + k, JSON.stringify(v)); } catch (e) { memory[k] = v; } },
  };
  const session = {
    get(k) { try { return sessionStorage.getItem("lw_" + k); } catch (e) { return memory["s_" + k] || null; } },
    set(k, v) { try { v == null ? sessionStorage.removeItem("lw_" + k) : sessionStorage.setItem("lw_" + k, v); } catch (e) { memory["s_" + k] = v; } },
  };
  function uuid() {
    if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => { const r = (Math.random() * 16) | 0; return (c === "x" ? r : (r & 3) | 8).toString(16); });
  }
  let DEVICE = store.get("device", null);
  if (!DEVICE) { DEVICE = uuid(); store.set("device", DEVICE); }

  /* ───────── Hilfen ───────── */
  const $ = (s) => document.querySelector(s);
  const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  /* ───────── Saisonale Deko (Halloween, Advent, Ostern …) ───────── */
  // Ostersonntag (gregorianisch, Gauß/Meeus)
  function easterUtc(y) {
    const a = y % 19, b = Math.floor(y / 100), c = y % 100, d = Math.floor(b / 4), e = b % 4, f = Math.floor((b + 8) / 25), g = Math.floor((b - f + 1) / 3);
    const h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4, l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
    const n = h + l - 7 * m + 114; return Date.UTC(y, Math.floor(n / 31) - 1, (n % 31) + 1);
  }
  // [Hauptsymbol am Logo, zwei Deko-Symbole, Gruß]
  const SEASONS = {
    neujahr: ["🎆", ["🥂", "✨"], "Frohes neues Jahr!"], valentin: ["❤️", ["💌", "🌹"], "Schönen Valentinstag!"],
    karneval: ["🎭", ["🎉", "🤡"], "Helau und Alaaf!"], april: ["🤡", ["🃏", "😜"], "Vorsicht, heute ist der 1. April!"],
    ostern: ["🐣", ["🥚", "🌷"], "Frohe Ostern!"], weltlachtag: ["😂", ["🎈", "🤣"], "Heute ist Weltlachtag!"],
    muttertag: ["💐", ["❤️", "🌷"], "Alles Liebe zum Muttertag!"], vatertag: ["🍺", ["🥨", "🚲"], "Schönen Vatertag!"],
    sommer: ["☀️", ["🍦", "🏖️"], "Schönen Sommeranfang!"], witztag: ["🤣", ["🎤", "😆"], "Heute ist Welttag des Witzes!"],
    einheit: ["🇩🇪", ["🎉", "🕊️"], "Schönen Tag der Deutschen Einheit!"], halloween: ["🎃", ["🦇", "👻"], "Happy Halloween!"],
    martin: ["🏮", ["🌙", "🐴"], "Schönen Martinstag!"], nikolaus: ["🎅", ["🍫", "🥾"], "Schönen Nikolaustag!"],
    advent: ["🎄", ["⭐", "🕯️"], "Schöne Adventszeit!"], weihnachten: ["🎄", ["🎁", "⭐"], "Frohe Weihnachten!"],
    silvester: ["🎆", ["🥂", "🍀"], "Guten Rutsch!"],
  };
  function seasonFor(date) {
    const s = date.toLocaleDateString("sv-SE", { timeZone: "Europe/Berlin" }), y = +s.slice(0, 4), m = +s.slice(5, 7), d = +s.slice(8, 10);
    const t = Date.UTC(y, m - 1, d), DAY = 864e5, md = m * 100 + d, e = easterUtc(y);
    const sunday = (mon, n) => { const w = new Date(Date.UTC(y, mon - 1, 1)).getUTCDay(); return Date.UTC(y, mon - 1, 1 + ((7 - w) % 7) + 7 * (n - 1)); };
    if (md <= 102) return "neujahr";
    if (md === 213 || md === 214) return "valentin";
    if (t >= e - 52 * DAY && t <= e - 46 * DAY) return "karneval";      // Weiberfastnacht bis Aschermittwoch
    if (md === 401) return "april";
    if (t >= e - 3 * DAY && t <= e + DAY) return "ostern";              // Gründonnerstag bis Ostermontag
    if (t === sunday(5, 1)) return "weltlachtag";
    if (t === e + 39 * DAY) return "vatertag";                          // Christi Himmelfahrt
    if (t === sunday(5, 2)) return "muttertag";
    if (md === 621) return "sommer";
    if (md === 701) return "witztag";
    if (md === 1003) return "einheit";
    if (md >= 1024 && md <= 1101) return "halloween";
    if (md === 1110 || md === 1111) return "martin";
    if (md === 1206) return "nikolaus";
    if (md >= 1224 && md <= 1226) return "weihnachten";
    if (md >= 1201 && md <= 1223) return "advent";
    if (md >= 1227) return "silvester";
    return null;
  }
  // Zum Ausprobieren: ?saison=ostern (oder ?saison=aus) in der Adresse, gilt für diese Sitzung
  const SEASON = (() => {
    let q = null; try { q = new URLSearchParams(location.search).get("saison"); } catch (e) { /* egal */ }
    if (q) session.set("season", q.toLowerCase());
    const o = session.get("season");
    if (o === "aus") return null;
    const k = o && SEASONS[o] ? o : seasonFor(new Date());
    return k ? { key: k, main: SEASONS[k][0], side: SEASONS[k][1], greet: SEASONS[k][2] } : null;
  })();
  const seasonBadge = () => (SEASON ? `<i class="season-badge" aria-hidden="true">${SEASON.main}</i>` : "");
  function applySeason() {
    if (!SEASON) return;
    document.body.dataset.season = SEASON.key;
    const logo = document.querySelector("header .logo");
    if (logo && !logo.querySelector(".season-badge")) { logo.insertAdjacentHTML("beforeend", seasonBadge()); logo.title = SEASON.greet; }
    document.body.insertAdjacentHTML("beforeend", `<div class="season-side" aria-hidden="true"><i>${SEASON.side[0]}</i><i>${SEASON.side[1]}</i><i>${SEASON.main}</i></div>`);
    const f = document.querySelector("footer"); if (f) f.insertAdjacentHTML("afterbegin", `<p class="season-greet">${SEASON.main} ${esc(SEASON.greet)}</p>`);
  }

  const fmt = (n) => Number(n).toLocaleString("de-DE");
  function ago(iso) {
    const h = (Date.now() - new Date(iso).getTime()) / 36e5;
    if (h < 1) return "gerade eben";
    if (h < 24) return `vor ${Math.round(h)} Std.`;
    const d = Math.round(h / 24);
    return d === 1 ? "vor 1 Tag" : `vor ${d} Tagen`;
  }
  function wilson(up, down) {
    const n = up + down; if (n <= 0) return 0;
    const z = 1.96, p = up / n;
    return (p + (z * z) / (2 * n) - z * Math.sqrt((p * (1 - p) + (z * z) / (4 * n)) / n)) / (1 + (z * z) / n);
  }
  function norm(t) { return t.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim(); }
  function trigrams(t) {
    const s = new Set();
    for (const w of norm(t).split(" ")) { if (!w) continue; const p = "  " + w + " "; for (let i = 0; i < p.length - 2; i++) s.add(p.slice(i, i + 3)); }
    return s;
  }
  function similarity(a, b) {
    const A = trigrams(a), B = trigrams(b); if (!A.size || !B.size) return 0;
    let i = 0; for (const x of A) if (B.has(x)) i++;
    return i / (A.size + B.size - i);
  }
  const ERRORS = {
    own_joke: "Eigene Witze kannst du nicht bewerten.",
    rate_limited: "Zu viele Anfragen in kurzer Zeit. Mach kurz Pause.",
    invalid_config: "Diese Einstellungen lassen sich nicht speichern.",
    ip_limit: "Von deinem Anschluss wurde dieser Witz schon oft bewertet.",
    joke_not_found: "Diesen Witz gibt es nicht mehr.",
    post_limit: "Du hast heute schon 10 Witze gepostet. Morgen geht es weiter.",
    invalid_name: "Dein Name braucht 2 bis 24 Zeichen.",
    not_logged_in: "Bitte melde dich an, um Witze zu posten.",
    invalid_username: "Der Benutzername braucht 3 bis 20 Zeichen: Buchstaben, Zahlen, Punkt oder Unterstrich.",
    username_taken: "Dieser Benutzername ist schon vergeben.",
    invalid_email: "Bitte gib eine gültige E-Mail-Adresse ein.",
    password_short: "Das Passwort braucht mindestens 8 Zeichen.",
    weak_password: "Das Passwort ist zu schwach. Nimm mindestens 8 Zeichen.",
    email_exists: "Mit dieser E-Mail gibt es schon ein Konto. Melde dich an.",
    invalid_credentials: "E-Mail oder Passwort stimmt nicht.",
    email_not_confirmed: "Bitte bestätige zuerst deine E-Mail-Adresse über den Link in deinem Postfach.",
    consent_missing: "Bitte bestätige, dass du die Datenschutzerklärung gelesen hast.",
    email_rate_limit: "Gerade wurden zu viele E-Mails verschickt. Versuch es in einer Stunde noch einmal.",
    password_mismatch: "Die beiden Passwörter stimmen nicht überein.",
    invalid_body: "Ein Witz braucht 10 bis 500 Zeichen.",
    invalid_category: "Wähle eine Kategorie.",
    not_admin: "Der Schlüssel stimmt nicht.",
    invalid_value: "Ungültige Eingabe.",
    demo_only: "Im Demo-Modus nicht verfügbar.",
    bad_words: "Bitte formuliere das ohne Beleidigungen.",
    battle_closed: "Dieses Battle ist schon vorbei. Schau dir das heutige an!",
    battle_limit: "Du hast heute schon 3 Pointen eingereicht. Morgen gibt es ein neues Battle.",
    duplicate_punchline: "Genau diese Pointe gibt es schon.",
    duplicate: "Diesen oder einen sehr ähnlichen Witz gibt es schon.",
    invalid_punchline: "Eine Pointe braucht 2 bis 200 Zeichen.",
    banned: "Dein Konto ist gesperrt. Bei Fragen schreib uns über die Adresse im Impressum.",
    user_not_found: "Diesen Nutzer gibt es nicht.",
    owner_only: "Das darf nur, wer den Admin-Schlüssel hat.",
    invalid_sponsor: "Bitte prüfe die Angaben: Name 2–60 Zeichen, Link mit https://, Logo höchstens ca. 100 KB.",
    network: "Keine Verbindung. Prüfe dein Internet und versuch es noch einmal.",
  };
  const errorText = (e) => ERRORS[e && e.code] || "Das hat nicht geklappt. Versuch es noch einmal.";

  /* ───────── Konto (Supabase Auth, ohne Fremdbibliothek) ───────── */
  const SITE_URL = location.href.split("#")[0].split("?")[0];
  const USERNAME_RE = /^[A-Za-z0-9_.äöüÄÖÜß]{3,20}$/;
  let AUTH = store.get("auth", null); // { access_token, refresh_token, expires_at, email, username } bzw. { demo: true, … }
  if (AUTH && LIVE === Boolean(AUTH.demo)) AUTH = null;     // Demo-Konto nicht im Live-Modus verwenden und umgekehrt
  function setAuth(a) { AUTH = a; store.set("auth", a); if (typeof renderNav === "function") renderNav(route().view); }
  const authError = (code) => { const e = new Error(code); e.code = code; return e; };
  function mapAuthError(data, status) {
    const c = data.error_code || data.code || data.error || "";
    const m = String(data.msg || data.error_description || data.message || "").toLowerCase();
    if (c === "email_not_confirmed" || m.includes("not confirmed")) return "email_not_confirmed";
    if (c === "invalid_credentials" || c === "invalid_grant" || m.includes("invalid login")) return "invalid_credentials";
    if (c === "weak_password" || m.includes("password should")) return "weak_password";
    if (c === "user_already_exists" || c === "email_exists" || m.includes("already registered")) return "email_exists";
    if (c === "email_address_invalid" || c === "validation_failed" || m.includes("invalid format")) return "invalid_email";
    if (String(c).includes("rate_limit") || status === 429) return "email_rate_limit";
    return "auth_failed";
  }
  async function authReq(path, { method = "POST", body, token } = {}) {
    const headers = { "Content-Type": "application/json", apikey: CFG.supabaseAnonKey };
    if (token) headers.Authorization = "Bearer " + token;
    let res;
    try { res = await fetch(CFG.supabaseUrl.replace(/\/$/, "") + "/auth/v1/" + path, { method, headers, body: body ? JSON.stringify(body) : undefined }); }
    catch (e) { throw authError("network"); }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { const e = authError(mapAuthError(data, res.status)); e.status = res.status; throw e; }
    return data;
  }
  async function startSession(data) {
    const a = {
      access_token: data.access_token, refresh_token: data.refresh_token,
      expires_at: Number(data.expires_at) || Math.floor(Date.now() / 1000) + Number(data.expires_in || 3600),
      email: (data.user && data.user.email) || "", username: "",
    };
    AUTH = a; // vorläufig, damit my_profile mit Token läuft
    try { const r = (await rpc("my_profile", {}))[0]; a.username = (typeof r === "string" ? r : r && r.username) || ""; a.banned = !!(r && r.banned); a.role = (r && r.role) || null; } catch (e) { /* Name folgt beim nächsten Laden */ }
    setAuth(a);
  }
  let refreshing = null;
  async function getToken() {
    if (!LIVE || !AUTH || AUTH.demo) return null;
    if (AUTH.expires_at * 1000 > Date.now() + 60000) return AUTH.access_token;
    if (!refreshing) {
      refreshing = authReq("token?grant_type=refresh_token", { body: { refresh_token: AUTH.refresh_token } })
        .then((d) => { setAuth({ ...AUTH, access_token: d.access_token, refresh_token: d.refresh_token, expires_at: Number(d.expires_at) || Math.floor(Date.now() / 1000) + Number(d.expires_in || 3600) }); })
        .catch(() => setAuth(null))
        .finally(() => { refreshing = null; });
    }
    await refreshing;
    return AUTH ? AUTH.access_token : null;
  }
  const liveAuth = {
    async signUp(username, email, password) {
      if (!(await rpc("username_available", { p_name: username }))) throw authError("username_taken");
      const data = await authReq("signup?redirect_to=" + encodeURIComponent(SITE_URL), { body: { email, password, data: { username } } });
      if (data.access_token) { await startSession(data); return { confirmed: true }; } // E-Mail-Bestätigung abgeschaltet
      const user = data.user || data;
      if (Array.isArray(user.identities) && user.identities.length === 0) throw authError("email_exists");
      return { confirmed: false };
    },
    async signIn(email, password) { await startSession(await authReq("token?grant_type=password", { body: { email, password } })); },
    async signOut() { const t = AUTH && AUTH.access_token; setAuth(null); if (t) authReq("logout", { token: t }).catch(() => {}); },
    async recover(email) { await authReq("recover?redirect_to=" + encodeURIComponent(SITE_URL), { body: { email } }); },
    async updatePassword(password) { const t = await getToken(); if (!t) throw authError("not_logged_in"); await authReq("user", { method: "PUT", body: { password }, token: t }); },
  };
  // Rückkehr aus der Bestätigungs- oder Passwort-E-Mail: Supabase hängt die Anmeldung an die Adresse (#access_token=…)
  async function handleAuthRedirect() {
    const h = location.hash;
    if (!/access_token=|error_description=/.test(h)) return null;
    const p = new URLSearchParams(h.replace(/^#\/?/, ""));
    history.replaceState(null, "", location.pathname + location.search + "#/");
    if (p.get("error_description")) return { error: p.get("error_code") || "link_invalid" };
    const data = { access_token: p.get("access_token"), refresh_token: p.get("refresh_token"), expires_at: p.get("expires_at"), expires_in: p.get("expires_in") };
    try { data.user = await authReq("user", { method: "GET", token: data.access_token }); } catch (e) { return { error: "link_invalid" }; }
    await startSession(data);
    return { type: p.get("type") };
  }

  /* ───────── Live-API (Supabase) ───────── */
  async function rpc(fn, args, retried) {
    const key = CFG.supabaseAnonKey;
    const headers = { "Content-Type": "application/json", apikey: key };
    const token = await getToken();
    if (token) headers.Authorization = "Bearer " + token;          // angemeldet: Konto mitschicken
    else if (key.startsWith("eyJ")) headers.Authorization = "Bearer " + key; // alte JWT-Keys
    let res;
    try {
      res = await fetch(CFG.supabaseUrl.replace(/\/$/, "") + "/rest/v1/rpc/" + fn, { method: "POST", headers, body: JSON.stringify(args) });
    } catch (e) { const err = new Error("network"); err.code = "network"; throw err; }
    const data = await res.json().catch(() => null);
    if (res.status === 401 && token && !retried) { setAuth(null); return rpc(fn, args, true); } // abgelaufene Anmeldung: als Gast weiter
    if (!res.ok) { const err = new Error((data && data.message) || "request_failed"); err.code = data && data.message; err.details = data && data.details; throw err; }
    return data;
  }
  const fromRow = (r) => ({
    id: Number(r.id), text: r.body, cat: r.category_slug, author: r.author_name, created: r.created_at,
    up: r.up_count, down: r.down_count, score: r.score ?? wilson(r.up_count, r.down_count),
    own: !!r.is_own, myVote: r.my_vote || 0, reports: r.report_count || 0, status: r.status || "visible",
  });
  const liveApi = {
    async ranking(range, cat, limit, offset) { return (await rpc("get_ranking", { p_device: DEVICE, p_range: range, p_category: cat, p_limit: limit, p_offset: offset })).map(fromRow); },
    async joke(id) { const rows = await rpc("get_joke", { p_device: DEVICE, p_id: id }); return rows.length ? fromRow(rows[0]) : null; },
    async unrated(exclude) { return (await rpc("get_unrated2", { p_device: DEVICE, p_exclude: exclude, p_limit: 10, p_cats: S.favs.length ? S.favs : null })).map(fromRow); },
    async similar(text) { const rows = await rpc("find_similar", { p_body: text }); return rows.length ? { id: Number(rows[0].id), text: rows[0].body, match: rows[0].match } : null; },
    async vote(id, value) { const rows = await rpc("cast_vote", { p_device: DEVICE, p_joke: id, p_value: value }); return { up: rows[0].up_count, down: rows[0].down_count }; },
    async post(cat, text, challenge) {
      const args = { p_device: DEVICE, p_category: cat, p_body: text };
      if (challenge) args.p_challenge = challenge;
      try { return Number(await rpc("post_joke", args)); }
      catch (e) { if (e.code === "duplicate") e.duplicateId = Number(e.details); throw e; }
    },
    async report(id) { await rpc("report_joke", { p_device: DEVICE, p_joke: id }); },
    async adminCheck(key) { return rpc("admin_check", { p_key: key }); },
    async adminList(key, view) { return (await rpc("admin_list", { p_key: key, p_view: view })).map(fromRow); },
    async adminSet(key, id, status) { await rpc("admin_set_status", { p_key: key, p_joke: id, p_status: status }); },
    // Erweiterung
    async daily(limit) { return (await rpc("get_daily", { p_device: DEVICE, p_limit: limit })).map((r) => ({ ...fromRow(r), day: r.day })); },
    async reactions(ids) {
      if (!ids.length) return {};
      const out = {};
      for (const r of await rpc("get_reactions", { p_device: DEVICE, p_ids: ids })) out[Number(r.joke_id)] = { lol: r.lol, sigh: r.sigh, dead: r.dead, mine: r.mine || null };
      return out;
    },
    async react(id, kind) { await rpc("set_reaction", { p_device: DEVICE, p_joke: id, p_kind: kind || "" }); },
    async reactionTop(kind, limit) { return (await rpc("get_reaction_top", { p_device: DEVICE, p_kind: kind, p_limit: limit })).map((r) => ({ ...fromRow(r), n: r.n })); },
    async duel() { return (await rpc("get_duel2", { p_device: DEVICE, p_cats: S.favs.length ? S.favs : null })).map(fromRow); },
    async duelVote(winner, loser) { await rpc("cast_duel", { p_device: DEVICE, p_winner: winner, p_loser: loser }); },
    async duelRanking(limit) { return (await rpc("get_duel_ranking", { p_device: DEVICE, p_limit: limit })).map((r) => ({ ...fromRow(r), elo: r.elo, duels: r.duels })); },
    async authors(range) { return rpc("get_author_ranking", { p_range: range, p_limit: 30 }); },
    async profile(name) { const rows = await rpc("get_profile", { p_name: name }); return rows.length ? rows[0] : null; },
    async profileJokes(name) { return (await rpc("get_profile_jokes", { p_device: DEVICE, p_name: name, p_limit: 50, p_offset: 0 })).map(fromRow); },
    async highlights() { return AUTH ? rpc("my_highlights", {}) : []; },
    async challenges() { return rpc("get_challenges", {}); },
    async challengeRanking(id) { return (await rpc("get_challenge_ranking", { p_device: DEVICE, p_challenge: id, p_limit: 50 })).map(fromRow); },
    async adminStats(key, days) { return rpc("admin_stats", { p_key: key, p_days: days }); },
    async adminTotals(key) { return (await rpc("admin_totals", { p_key: key }))[0]; },
    async adminCatStats(key) { return rpc("admin_category_stats", { p_key: key }); },
    async adminBulkAdd(key, cat, bodies, perDay) { return (await rpc("admin_bulk_add", { p_key: key, p_category: cat, p_bodies: bodies, p_per_day: perDay }))[0]; },
    async battleToday() { return (await rpc("get_battle_today", {}))[0] || null; },
    async battleEntries(prompt) { return (await rpc("get_battle_entries", { p_device: DEVICE, p_prompt: prompt })).map((r) => ({ id: Number(r.id), text: r.body, author: r.author_name, created: r.created_at, up: r.up_count, down: r.down_count, score: r.score, own: !!r.is_own, myVote: r.my_vote || 0 })); },
    async battleArchive(limit) { return rpc("get_battle_archive", { p_limit: limit }); },
    async postPunchline(prompt, text) { return Number(await rpc("post_punchline", { p_device: DEVICE, p_prompt: prompt, p_body: text })); },
    async votePunchline(id, value) { const r = (await rpc("vote_punchline", { p_device: DEVICE, p_entry: id, p_value: value }))[0]; return { up: r.up_count, down: r.down_count }; },
    async seasonWinners() { return rpc("get_season_winners", { p_limit: 12 }); },
    async adminWords(key) { return (await rpc("admin_get_words", { p_key: key })).map((r) => (typeof r === "string" ? r : r.word)); },
    async adminSetWords(key, words) { return rpc("admin_set_words", { p_key: key, p_words: words }); },
    async adminAddPrompts(key, setups) { return rpc("admin_add_prompts", { p_key: key, p_setups: setups }); },
    async adminBattle(key) { return rpc("admin_battle", { p_key: key }); },
    async adminRemovePunchline(key, id) { await rpc("admin_remove_punchline", { p_key: key, p_entry: id }); },
    async announcement() { return rpc("get_announcement", {}); },
    async sponsors() { const out = {}; for (const r of await rpc("get_sponsors", {})) out[r.placement] = r; return out; },
    async sponsor(id) { return (await rpc("get_sponsor", { p_id: id }))[0] || null; },
    async sponsorClick(id) { await rpc("sponsor_click", { p_id: id }); },
    async adminGroups(key) { return rpc("admin_groups", { p_key: key }); },
    async adminVisits(key, days) { return rpc("admin_visits", { p_key: key, p_days: days }); },
    async adminVisitBreakdown(key, days) { return rpc("admin_visit_breakdown", { p_key: key, p_days: days }); },
    async contact() { return rpc("get_contact", {}); },
    async adminSponsors(key) { return rpc("admin_sponsors", { p_key: key }); },
    async adminSaveSponsor(key, x) { return rpc("admin_save_sponsor", { p_key: key, p_id: x.id || null, p_name: x.name, p_claim: x.claim, p_url: x.url, p_logo: x.logo, p_placement: x.placement, p_starts: x.starts, p_ends: x.ends }); },
    async adminDeleteSponsor(key, id) { await rpc("admin_delete_sponsor", { p_key: key, p_id: id }); },
    async adminSetContact(key, email) { await rpc("admin_set_contact", { p_key: key, p_email: email }); },
    async deleteAccount(withContent) { await rpc("delete_my_account", { p_with_content: !!withContent }); },
    async reportPunch(id) { await rpc("report_punchline", { p_device: DEVICE, p_entry: id }); },
    async adminApprovePunch(key, id) { await rpc("admin_approve_punchline", { p_key: key, p_entry: id }); },
    async adminOpenPunch(key) { return rpc("admin_open_punch_reports", { p_key: key }); },
    async adminPushStats(key) { return (await rpc("admin_push_stats", { p_key: key }))[0]; },
    async adminSetRole(key, name, admin) { await rpc("admin_set_role", { p_key: key, p_username: name, p_admin: admin }); },
    async adminOverview(key) { return rpc("admin_overview", { p_key: key }); },
    async adminActivity(key) { return rpc("admin_activity", { p_key: key, p_limit: 30 }); },
    async adminSearch(key, q) { return rpc("admin_search_jokes", { p_key: key, p_query: q.q || null, p_category: q.cat || null, p_status: q.status || null, p_author: q.author || null, p_limit: 30, p_offset: q.offset || 0 }); },
    async adminUpdateJoke(key, id, body, cat) { await rpc("admin_update_joke", { p_key: key, p_id: id, p_body: body, p_category: cat }); },
    async adminUsers(key, q) { return rpc("admin_users", { p_key: key, p_query: q || null, p_limit: 200 }); },
    async adminUsers2(key, q) { return rpc("admin_users2", { p_key: key, p_query: q || null, p_limit: 1000 }); },
    async adminDashboard(key) { return rpc("admin_dashboard", { p_key: key }); },
    async adminSecurity(key) { return rpc("admin_security", { p_key: key }); },
    async adminLog(key, limit, offset, target) { return rpc("admin_log_list", { p_key: key, p_limit: limit, p_offset: offset || 0, p_target: target || null }); },
    async adminUserDetail(key, name) { return rpc("admin_user_detail", { p_key: key, p_username: name }); },
    async adminSetNote(key, name, note) { await rpc("admin_set_note", { p_key: key, p_username: name, p_note: note }); },
    async adminBulkStatus(key, ids, status) { return rpc("admin_bulk_status", { p_key: key, p_ids: ids, p_status: status }); },
    async adminBulkCategory(key, ids, cat) { return rpc("admin_bulk_category", { p_key: key, p_ids: ids, p_category: cat }); },
    async adminPostJoke(key, cat, body, mode, at) { return rpc("admin_post_joke", { p_key: key, p_category: cat, p_body: body, p_mode: mode, p_at: at || null }); },
    async adminBan(key, name, ban, reason) { await rpc("admin_ban_user", { p_key: key, p_username: name, p_ban: ban, p_reason: reason || null }); },
    async adminRemoveUserContent(key, name) { return rpc("admin_remove_user_content", { p_key: key, p_username: name }); },
    async adminTop(key) { return rpc("admin_top", { p_key: key }); },
    async adminExport(key) { return rpc("admin_export", { p_key: key }); },
    async adminSetAnnouncement(key, text) { await rpc("admin_set_announcement", { p_key: key, p_text: text }); },
    async adminSaveChallenge(key, c) { return rpc("admin_save_challenge", { p_key: key, p_id: c.id || null, p_title: c.title, p_description: c.description, p_starts: c.starts, p_ends: c.ends }); },
  };

  const dayKeyLocal = (t) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };

  /* ───────── Demo-API (nur Browser) ───────── */
  function mulberry(a) { return () => { a |= 0; a = (a + 0x6d2b79f5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
  const demo = (() => {
    const rnd = mulberry(20261015);
    const authors = ["kalauerkönig", "mia_lacht", "bytebert", "montagsmuffel", "pointenpaul", "fritzchen_fan", "lena.lol", "witzbold42", "lachsack", "frau_flach"];
    // Tägliche Auswahl: Jeder Witz hat einen festen Tag in einem 30-Tage-Zyklus.
    // So erscheinen jeden Tag rund 12 „neue“ Witze unter „Heute“, egal wann jemand die Seite öffnet.
    const PERIOD = 30, DAY = 864e5, now = Date.now();
    const midnight = new Date(); midnight.setHours(0, 0, 0, 0);
    const today0 = midnight.getTime();
    const dayIdx = Math.round((today0 - midnight.getTimezoneOffset() * 6e4) / DAY);
    const seed = [];
    let id = 1, k = 0;
    for (const [cat, list] of Object.entries(window.STARTWITZE || {})) for (const text of list) {
      const slot = (k++ * 7 + 3) % PERIOD;                 // gleichmäßig über die 30 Tage verteilt
      const ageDays = (((dayIdx - slot) % PERIOD) + PERIOD) % PERIOD;
      const hour = rnd(), rate = 3 + rnd() * 45, ratio = 0.5 + rnd() * 0.46;
      const created = ageDays === 0 ? today0 + hour * (now - today0) : today0 - ageDays * DAY + hour * DAY;
      const n = Math.floor(((now - created) / DAY) * rate);
      const up = Math.round(n * ratio);
      seed.push({ id: id++, cat, text, author: authors[Math.floor(rnd() * authors.length)], created: new Date(created).toISOString(), up, down: n - up, status: "visible", reports: 0 });
    }
    const base = now;
    seed.push({ id: id++, cat: "flachwitze", text: "GRATIS FOLLOWER!!! Klick auf meinen Kanal, 1000 Abos in 24 Stunden", author: "promo_profi", created: new Date(base - 3 * 36e5).toISOString(), up: 0, down: 6, status: "hidden", reports: 4 });
    const st = { votes: store.get("demo_votes", {}), posted: store.get("demo_posted", []), mod: store.get("demo_mod", {}), reported: store.get("demo_reported", []),
      reacts: store.get("demo_reacts", {}), duels: store.get("demo_duels", {}), elo: store.get("demo_elo", {}), duelCount: store.get("demo_duelcount", {}),
      punch: store.get("demo_punch", []), pvotes: store.get("demo_pvotes", {}) };
    const save = () => { store.set("demo_votes", st.votes); store.set("demo_posted", st.posted); store.set("demo_mod", st.mod); store.set("demo_reported", st.reported);
      store.set("demo_reacts", st.reacts); store.set("demo_duels", st.duels); store.set("demo_elo", st.elo); store.set("demo_duelcount", st.duelCount);
      store.set("demo_punch", st.punch); store.set("demo_pvotes", st.pvotes); };
    const all = () => [...st.posted, ...seed].map((j) => {
      const m = st.mod[j.id] || {}, v = st.votes[j.id] || 0;
      const up = j.up + (v === 1 ? 1 : 0), down = j.down + (v === -1 ? 1 : 0);
      return { ...j, status: m.status || j.status, reports: m.reports ?? j.reports, reviewed: !!m.reviewed, up, down, score: wilson(up, down), own: j.device === DEVICE, myVote: v };
    });
    const visible = (j) => j.status === "visible" && !st.reported.includes(j.id);
    const ageH = (j) => (Date.now() - new Date(j.created).getTime()) / 36e5;
    const fail = (code) => { const e = new Error(code); e.code = code; return e; };
    const wait = (v) => new Promise((r) => setTimeout(() => r(v), 60));
    return {
      ranking(range, cat, limit, offset) {
        const h = range === "new" ? 6 : range === "day" ? 24 : range === "week" ? 168 : Infinity;
        return wait(all().filter((j) => visible(j) && ageH(j) < h && (!cat || j.cat === cat) && (range !== "all" || j.up + j.down >= 20))
          .sort((a, b) => (range === "new" ? new Date(b.created) - new Date(a.created) : 0) || b.score - a.score || b.up + b.down - (a.up + a.down)).slice(offset, offset + limit));
      },
      joke(id) { return wait(all().find((j) => j.id === id && visible(j)) || null); },
      unrated(exclude) {
        return wait(all().filter((j) => visible(j) && !j.own && !j.myVote && !exclude.includes(j.id) && (!S.favs.length || S.favs.includes(j.cat)))
          .map((j) => ({ j, k: (j.up + j.down >= 20 ? 2 : 0) + (ageH(j) > 168 ? 1 : 0), r: Math.random() }))
          .sort((a, b) => a.k - b.k || a.r - b.r).slice(0, 10).map((x) => x.j));
      },
      similar(text) {
        let best = null;
        for (const j of all()) { if (j.status !== "visible") continue; const s = similarity(text, j.text); if (s >= DUP_THRESHOLD && (!best || s > best.match)) best = { id: j.id, text: j.text, match: s }; }
        return wait(best);
      },
      vote(id, value) {
        const j = all().find((x) => x.id === id);
        if (!j || !visible(j)) return Promise.reject(fail("joke_not_found"));
        if (j.own) return Promise.reject(fail("own_joke"));
        if (value === 0) delete st.votes[id]; else st.votes[id] = value;
        save();
        const n = all().find((x) => x.id === id);
        return wait({ up: n.up, down: n.down });
      },
      async post(cat, text, challenge) {
        if (!AUTH) throw fail("not_logged_in");
        const name = AUTH.username;
        const dup = await this.similar(text);
        if (dup) { const e = fail("duplicate"); e.duplicateId = dup.id; throw e; }
        const id = Date.now();
        st.posted.unshift({ id, cat, text, author: name, created: new Date().toISOString(), up: 0, down: 0, status: "visible", reports: 0, device: DEVICE, challenge: challenge || null });
        save();
        return id;
      },
      report(id) {
        const j = all().find((x) => x.id === id); if (!j) return wait();
        const reports = j.reports + 1, limit = j.reviewed ? 10 : 3;
        st.mod[id] = { ...(st.mod[id] || {}), reports, status: reports >= limit ? "hidden" : j.status };
        st.reported.push(id); save(); return wait();
      },
      adminCheck(key) { return wait(key === DEMO_ADMIN_KEY); },
      adminList(key, view) {
        if (key !== DEMO_ADMIN_KEY) return Promise.reject(fail("not_admin"));
        const list = view === "neu"
          ? all().filter((j) => j.status === "visible").sort((a, b) => new Date(b.created) - new Date(a.created)).slice(0, 50)
          : all().filter((j) => j.status === "hidden" || (j.status === "visible" && j.reports > 0)).sort((a, b) => (a.status === "hidden" ? 0 : 1) - (b.status === "hidden" ? 0 : 1) || b.reports - a.reports);
        return wait(list);
      },
      adminSet(key, id, status) {
        if (key !== DEMO_ADMIN_KEY) return Promise.reject(fail("not_admin"));
        st.mod[id] = status === "visible" ? { status: "visible", reports: 0, reviewed: true } : { ...(st.mod[id] || {}), status: "removed" };
        st.reported = st.reported.filter((x) => x !== id || status !== "visible");
        save(); return wait();
      },
      // ── Erweiterung (Demo: alles nur in diesem Browser) ──
      daily(limit) {
        const out = [], used = new Set(), list = all().filter(visible);
        const end0 = new Date(); end0.setHours(20, 0, 0, 0);
        if (Date.now() < end0.getTime()) end0.setDate(end0.getDate() - 1);
        for (let k = 0; k < Math.min(limit, 14); k++) {
          const end = end0.getTime() - k * DAY, start = end - DAY;
          const best = list.filter((j) => !used.has(j.id) && j.up > 0 && new Date(j.created).getTime() > start && new Date(j.created).getTime() <= end).sort((a, b) => b.score - a.score)[0];
          if (!best) continue;
          used.add(best.id);
          const d = new Date(end); out.push({ ...best, day: `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}` });
        }
        return wait(out);
      },
      reactions(ids) {
        const out = {};
        for (const id of ids) {
          const r = mulberry(id * 7919), mine = st.reacts[id] || null;
          const c = { lol: Math.floor(r() * 9), sigh: Math.floor(r() * 4), dead: Math.floor(r() * 3) };
          if (mine) c[mine]++;
          out[id] = { ...c, mine };
        }
        return wait(out);
      },
      react(id, kind) { if (kind) st.reacts[id] = kind; else delete st.reacts[id]; save(); return wait(); },
      async reactionTop(kind, limit) {
        const list = all().filter((j) => visible(j) && ageH(j) < 168);
        const counts = await this.reactions(list.map((j) => j.id));
        return list.map((j) => ({ ...j, n: counts[j.id][kind] })).filter((j) => j.n > 0).sort((a, b) => b.n - a.n).slice(0, limit);
      },
      duel() {
        const list = all().filter((j) => visible(j) && !j.own && (!S.favs.length || S.favs.includes(j.cat)));
        const a = list[Math.floor(Math.random() * list.length)];
        if (!a) return wait([]);
        const rest = list.filter((j) => j.id !== a.id && !st.duels[[Math.min(a.id, j.id), Math.max(a.id, j.id)].join("-")]);
        const b = rest[Math.floor(Math.random() * rest.length)];
        return wait(a && b ? [a, b] : []);
      },
      duelVote(w, l) {
        const key = [Math.min(w, l), Math.max(w, l)].join("-");
        if (st.duels[key]) return wait();
        st.duels[key] = w;
        const ew = st.elo[w] || 1000, el = st.elo[l] || 1000, e = 1 / (1 + Math.pow(10, (el - ew) / 400));
        st.elo[w] = ew + 24 * (1 - e); st.elo[l] = el - 24 * (1 - e);
        st.duelCount[w] = (st.duelCount[w] || 0) + 1; st.duelCount[l] = (st.duelCount[l] || 0) + 1;
        save(); return wait();
      },
      duelRanking(limit) {
        return wait(all().filter((j) => visible(j) && st.duelCount[j.id]).map((j) => ({ ...j, elo: Math.round(st.elo[j.id]), duels: st.duelCount[j.id] }))
          .sort((a, b) => b.elo - a.elo).slice(0, limit));
      },
      authors(range) {
        const by = {};
        for (const j of all()) {
          if (!visible(j) || (range === "week" && ageH(j) > 168)) continue;
          const a = (by[j.author] = by[j.author] || { username: j.author, jokes: 0, up_count: 0, down_count: 0 });
          a.jokes++; a.up_count += j.up; a.down_count += j.down;
        }
        return wait(Object.values(by).filter((a) => a.up_count + a.down_count >= (range === "all" ? 20 : 5))
          .map((a) => ({ ...a, score: wilson(a.up_count, a.down_count) })).sort((a, b) => b.score - a.score).slice(0, 30));
      },
      async profile(name) {
        const mine = all().filter((j) => visible(j) && j.author.toLowerCase() === name.toLowerCase());
        if (!mine.length && !(AUTH && AUTH.username.toLowerCase() === name.toLowerCase())) return null;
        const daily = await this.daily(14), today = await this.ranking("day", null, 100, 0);
        const rank = today.findIndex((j) => j.author.toLowerCase() === name.toLowerCase());
        return {
          username: mine[0] ? mine[0].author : AUTH.username, member_since: null, jokes: mine.length,
          up_count: mine.reduce((s, j) => s + j.up, 0), down_count: mine.reduce((s, j) => s + j.down, 0),
          top_up: Math.max(0, ...mine.map((j) => j.up)), crowns: daily.filter((d) => d.author.toLowerCase() === name.toLowerCase()).length,
          challenge_wins: 0, best_rank: rank < 0 ? null : rank + 1,
        };
      },
      profileJokes(name) { return wait(all().filter((j) => visible(j) && j.author.toLowerCase() === name.toLowerCase()).sort((a, b) => b.score - a.score).slice(0, 50)); },
      highlights() { return wait([]); },
      challenges() {
        const end = new Date(); end.setHours(20, 0, 0, 0); end.setDate(end.getDate() + ((7 - end.getDay()) % 7));
        if (end.getTime() <= Date.now()) end.setDate(end.getDate() + 7);
        return wait([{ id: 1, title: "Witze übers Fitnessstudio", description: "Hanteln, Laufband, Neujahrsvorsätze: Dein bester Witz rund ums Training.",
          starts_at: new Date(Date.now() - DAY).toISOString(), ends_at: end.toISOString(), active: true, entries: st.posted.filter((j) => j.challenge === 1).length, winner_name: null, winner_joke: null }]);
      },
      challengeRanking(id) { return wait(all().filter((j) => visible(j) && j.challenge === id).sort((a, b) => b.score - a.score)); },
      adminStats(key, days) {
        if (key !== DEMO_ADMIN_KEY) return Promise.reject(fail("not_admin"));
        return wait(Array.from({ length: days }, (_, i) => { const d = new Date(Date.now() - (days - 1 - i) * DAY); const r = mulberry(d.getDate()); return { day: d.toISOString().slice(0, 10), votes: Math.floor(r() * 300), voters: Math.floor(r() * 60), reactions: Math.floor(r() * 80), duels: Math.floor(r() * 120), new_jokes: Math.floor(r() * 6), signups: Math.floor(r() * 3) }; }));
      },
      adminTotals(key) {
        if (key !== DEMO_ADMIN_KEY) return Promise.reject(fail("not_admin"));
        const l = all(); return wait({ jokes: l.filter(visible).length, user_jokes: st.posted.length, users: Object.keys(store.get("demo_accounts", {})).length, votes: Object.keys(st.votes).length, devices: 1, queued: 0, queue_until: null });
      },
      adminCatStats(key) {
        if (key !== DEMO_ADMIN_KEY) return Promise.reject(fail("not_admin"));
        return wait(Object.entries(CATS).map(([slug, name]) => ({ slug, name, jokes: all().filter((j) => visible(j) && j.cat === slug).length, queued: 0, votes_week: 0 })));
      },
      battleToday() {
        const P = ["Treffen sich zwei Hanteln im Fitnessstudio. Sagt die eine: …", "Was sagt der Toaster morgens zum Kühlschrank?", "Warum hat die Giraffe kein Handy?", "Was sagt das WLAN, wenn es Feierabend hat?", "Der Wecker klingelt. Ich: …"];
        const d = Math.floor((Date.now() - new Date().getTimezoneOffset() * 6e4) / DAY);
        return wait({ id: d, setup: P[d % P.length], day: dayKeyLocal(Date.now()), entries: st.punch.filter((e) => e.prompt === d).length });
      },
      battleEntries(prompt) {
        return wait(st.punch.filter((e) => e.prompt === prompt).map((e) => ({ ...e, up: e.up + (st.pvotes[e.id] === 1 ? 1 : 0), down: e.down + (st.pvotes[e.id] === -1 ? 1 : 0), myVote: st.pvotes[e.id] || 0, own: e.device === DEVICE }))
          .map((e) => ({ ...e, score: wilson(e.up, e.down) })).sort((a, b) => b.score - a.score));
      },
      battleArchive() { return wait([]); },
      async postPunchline(prompt, text) {
        if (!AUTH) throw fail("not_logged_in");
        if (st.punch.filter((e) => e.prompt === prompt && e.device === DEVICE).length >= 3) throw fail("battle_limit");
        const id = Date.now(); st.punch.push({ id, prompt, text, author: AUTH.username, created: new Date().toISOString(), up: 0, down: 0, device: DEVICE }); save(); return id;
      },
      async votePunchline(id, value) { if (value) st.pvotes[id] = value; else delete st.pvotes[id]; save(); const e = (await this.battleEntries(st.punch.find((x) => x.id === id).prompt)).find((x) => x.id === id); return { up: e.up, down: e.down }; },
      seasonWinners() { return wait([]); },
      adminWords(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : wait(["arschloch", "fick*"]); },
      adminSetWords(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
      adminAddPrompts(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
      adminBattle(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : wait([]); },
      adminRemovePunchline(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
      announcement() { return wait(null); },
      sponsors() { return wait({}); },
      sponsor() { return wait(null); },
      sponsorClick() { return wait(); },
      contact() { return wait(null); },
      adminSponsors() { return wait([]); },
      adminSaveSponsor() { return Promise.reject(fail("demo_only")); },
      adminDeleteSponsor() { return Promise.reject(fail("demo_only")); },
      adminSetContact() { return Promise.reject(fail("demo_only")); },
      adminSetRole() { return Promise.reject(fail("demo_only")); },
      adminPushStats() { return wait(null); },
      async deleteAccount() { const a = store.get("demo_accounts", {}); delete a[(AUTH.email || "").toLowerCase()]; store.set("demo_accounts", a); },
      reportPunch() { return wait(); },
      adminApprovePunch() { return Promise.reject(fail("demo_only")); },
      adminOpenPunch() { return wait(0); },
      adminOverview(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
      adminActivity() { return wait([]); },
      adminSearch(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
      adminUpdateJoke() { return Promise.reject(fail("demo_only")); },
      adminUsers(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
      adminUsers2(key) { return this.adminUsers(key); },
      adminDashboard() { return wait(null); }, adminSecurity() { return wait(null); }, adminLog() { return wait([]); },
      adminUserDetail() { return Promise.reject(fail("demo_only")); }, adminSetNote() { return Promise.reject(fail("demo_only")); },
      adminBulkStatus() { return Promise.reject(fail("demo_only")); }, adminBulkCategory() { return Promise.reject(fail("demo_only")); },
      adminPostJoke() { return Promise.reject(fail("demo_only")); },
      adminBan() { return Promise.reject(fail("demo_only")); },
      adminRemoveUserContent() { return Promise.reject(fail("demo_only")); },
      adminTop() { return wait([]); },
      adminExport() { return Promise.reject(fail("demo_only")); },
      adminSetAnnouncement() { return Promise.reject(fail("demo_only")); },
      adminBulkAdd(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
      adminSaveChallenge(key) { return key !== DEMO_ADMIN_KEY ? Promise.reject(fail("not_admin")) : Promise.reject(fail("demo_only")); },
    };
  })();

  // Demo-Konten: nur in diesem Browser, kein echtes Konto und kein gespeichertes Passwort
  const demoAuth = {
    async signUp(username, email) {
      const accts = store.get("demo_accounts", {});
      if (Object.values(accts).some((a) => a.username.toLowerCase() === username.toLowerCase())) throw authError("username_taken");
      if (accts[email.toLowerCase()]) throw authError("email_exists");
      accts[email.toLowerCase()] = { username };
      store.set("demo_accounts", accts);
      setAuth({ demo: true, email, username });
      return { confirmed: true };
    },
    async signIn(email) {
      const a = store.get("demo_accounts", {})[email.toLowerCase()];
      if (!a) throw authError("invalid_credentials");
      setAuth({ demo: true, email, username: a.username });
    },
    async signOut() { setAuth(null); },
    async recover() {},
    async updatePassword() {},
  };

  const API = LIVE ? liveApi : demo;
  const AUTH_API = LIVE ? liveAuth : demoAuth;

  /* ───────── Zustand & Navigation ───────── */
  const S = {
    range: "day", cat: null, shown: PAGE, rows: [], hasMore: false, detail: null,
    queue: [], seen: new Set(), rated: 0, swipeLoading: false, swipeDone: false,
    adminKey: session.get("admin"), adminView: "uebersicht", adminQ: { q: "", cat: "", status: "", author: "", offset: 0 }, adminUserQ: "", editJoke: null, announcement: null,
    hiddenForMe: new Set(store.get("hidden", [])),
    react: {}, challenges: null, hl: [], daily: null, authorRange: "week", editChallenge: null,
    favs: store.get("favs", []).filter((c) => c in CATS), battle: null, punch: [],
  };
  let renderToken = 0;

  function route() {
    const h = location.hash.replace(/^#\/?/, "");
    if (h.startsWith("witz/")) return { view: "detail", id: Number(h.slice(5)) };
    if (h === "bewerten") return { view: "swipe" };
    if (h === "duell") return { view: "duel" };
    if (h === "highlights") return { view: "highlights" };
    if (h === "autoren") return { view: "authors" };
    if (h === "challenge") return { view: "challenge" };
    if (h === "battle") return { view: "list" };   // Pointen-Battle ist abgeschaltet
    if (h === "tv" || h.startsWith("tv?")) { const q = new URLSearchParams(h.slice(3)); return { view: "tv", ...tvOpts(q), raw: Object.fromEntries(q) }; }
    if (h.startsWith("tv/")) return { view: "tv", code: h.slice(3).replace(/[^0-9a-z]/gi, "").slice(0, 8).toUpperCase() };
    if (h === "bildschirm" || h.startsWith("bildschirm?")) return { view: "screen", q: new URLSearchParams(h.slice(11)) };
    if (h === "quiz" || h.startsWith("quiz?")) return { view: "list" };   // Quiz ist abgeschaltet
    if (h.startsWith("live/")) return { view: "live", code: h.slice(5).replace(/[^0-9a-z]/gi, "").slice(0, 8).toUpperCase() };
    if (h === "gruppen") return { view: "groups" };
    if (h === "suche" || h.startsWith("suche?")) { let q = new URLSearchParams(h.slice(6)).get("q") || ""; return { view: "search", q }; }
    if (h.startsWith("gruppe/")) return { view: "group", code: h.slice(7).replace(/[^0-9a-z]/gi, "").slice(0, 8).toUpperCase() };
    if (h.startsWith("kategorie/")) return { view: "list", cat: h.slice(10) };
    if (h.startsWith("u/")) { let n = h.slice(2); try { n = decodeURIComponent(n); } catch (e) { /* roh lassen */ } return { view: "profile", name: n }; }
    if (h === "admin") return { view: "admin" };
    return { view: "list" };
  }
  function renderNav(view) {
    const items = [["#/", "list", "Bestenliste"], ["#/bewerten", "swipe", "Bewerten"], ["#/duell", "duel", "Duell"], ["#/highlights", "highlights", "Highlights"], ["#/autoren", "authors", "Autoren"], ["#/suche", "search", "🔍 Suche"]];
    if (S.adminKey || view === "admin" || isRoleAdmin()) items.push(["#/admin", "admin", "Moderation"]);
    $("#nav").innerHTML = items.map(([href, v, l]) => `<a href="${href}" ${view === v ? 'aria-current="page"' : ""}>${l}</a>`).join("");
    $("#listControls").style.display = view === "list" ? "grid" : "none";
    $("#postBtn").hidden = ["swipe", "admin", "duel", "screen", "quiz", "live", "search"].includes(view);
    const cur = document.querySelector('.nav [aria-current="page"]'); if (cur && cur.scrollIntoView) cur.scrollIntoView({ block: "nearest", inline: "nearest" });
    $("#who").textContent = AUTH ? "@" + (AUTH.username || "Konto") : "Anmelden";
    $("#who").title = AUTH ? "Dein Konto" : "Anmelden oder registrieren (nur zum Posten nötig)";
  }
  const isRoleAdmin = () => !!(AUTH && AUTH.role === "admin");
  const AK = () => S.adminKey || "";   // Admin-Schlüssel oder leer (dann zählt das angemeldete Admin-Konto)
  function renderChips() {
    $("#chips").innerHTML = [[null, "Alle"], ...Object.entries(CATS)].map(([k, v]) => `<button class="chip" aria-pressed="${k === S.cat}" data-cat="${k || ""}">${v}</button>`).join("");
  }
  async function render() {
    const r = route(), token = ++renderToken;
    document.body.classList.toggle("tv-mode", r.view === "tv");
    if (r.view !== "tv") { stopTv(); document.body.style.background = document.documentElement.style.background = ""; }
    if (r.view !== "live") stopLive();
    if (r.cat && CATS[r.cat] && S.cat !== r.cat) { S.cat = r.cat; S.rows = []; renderChips(); }
    renderNav(r.view);
    syncPushUser();
    trackView(r);
    try {
      if (r.view === "list") await renderList(token);
      else if (r.view === "swipe") await renderSwipe(token);
      else if (r.view === "detail") await renderDetail(token, r.id);
      else if (r.view === "duel") await renderDuel(token);
      else if (r.view === "highlights") { await renderHighlights(token); if (!stale(token)) drawPushBox(); }
      else if (r.view === "authors") await renderAuthors(token);
      else if (r.view === "profile") await renderProfile(token, r.name);
      else if (r.view === "challenge") await renderChallenge(token);
      else if (r.view === "battle") await renderBattle(token);
      else if (r.view === "tv") await renderTv(token, r);
      else if (r.view === "screen") await renderScreen(token, r);
      else if (r.view === "quiz") await renderQuiz(token, r.mode);
      else if (r.view === "live") await renderLive(token, r.code);
      else if (r.view === "groups") await renderGroups(token);
      else if (r.view === "search") await renderSearch(token, r.q);
      else if (r.view === "group") await renderGroup(token, r.code);
      else await renderAdmin(token);
    } catch (e) {
      if (token !== renderToken) return;
      console.error(e);
      $("#main").innerHTML = `<div class="view"><p class="empty">${esc(errorText(e))}<br><button class="btn ghost" data-retry style="margin-top:12px">Erneut laden</button></p></div>`;
    }
  }
  const stale = (token) => token !== renderToken;

  /* ───────── Karten ───────── */
  const ICON_UP = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M5 12l7-7 7 7"/></svg>';
  const ICON_DOWN = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M19 12l-7 7-7-7"/></svg>';
  function cardHtml(j, rank, badge) {
    const n = j.up + j.down, pct = Math.round((j.up / Math.max(n, 1)) * 100), single = rank == null;
    const dis = j.own ? ' disabled title="Eigene Witze kannst du nicht bewerten"' : "";
    return `<li class="card${single ? " single" : ""}${!single && rank <= 3 ? " top" : ""}" data-card="${j.id}">
      ${single ? "" : `<div class="rank">${rank}${badge ? `<small>${badge}</small>` : ""}</div>`}
      <div class="body"><div class="tag">${CATS[j.cat] || ""}</div>
        ${single ? `<p class="joke">${esc(j.text)}</p>` : `<a class="joke" href="#/witz/${j.id}">${esc(j.text)}</a>`}</div>
      <div class="foot">
        <button class="vote up" data-vote="1" data-id="${j.id}" aria-pressed="${j.myVote === 1}" aria-label="Gefällt mir"${dis}>${ICON_UP}${fmt(j.up)}</button>
        <button class="vote down" data-vote="-1" data-id="${j.id}" aria-pressed="${j.myVote === -1}" aria-label="Gefällt mir nicht"${dis}>${ICON_DOWN}${fmt(j.down)}</button>
        <span class="score">${n ? pct + " % Lacher" : "noch keine Stimmen"}<br>Score ${(j.score * 100).toFixed(1)}</span>
      </div>
      <div class="meter"><i style="width:${pct}%"></i></div>
      <div class="reacts" data-reacts="${j.id}">${reactsHtml(j)}</div>
      <div class="by"><span>${authorLink(j.author)} · ${ago(j.created)}${j.own ? " · dein Witz" : ""}</span>
        <span class="by-actions">${single ? "" : `<a class="link" href="#/witz/${j.id}">Teilen</a>`}${j.own ? "" : `<button class="link" data-report="${j.id}">Melden</button>`}</span></div>
    </li>`;
  }

  function authorLink(name) {
    return name === "Lachwerk" ? "@Lachwerk" : `<a class="author" href="#/u/${encodeURIComponent(name)}">@${esc(name)}</a>`;
  }
  const REACTS = [["lol", "😂", "Zum Brüllen"], ["sigh", "🙄", "Seufz"], ["dead", "💀", "Rabenschwarz"]];
  function reactsHtml(j) {
    const r = S.react[j.id] || { lol: 0, sigh: 0, dead: 0, mine: null };
    return REACTS.map(([k, emo, label]) => `<button class="react" data-react="${k}" data-id="${j.id}" aria-pressed="${r.mine === k}" aria-label="${label}" title="${label}"${j.own ? " disabled" : ""}><span aria-hidden="true">${emo}</span>${r[k] ? fmt(r[k]) : ""}</button>`).join("");
  }
  async function loadReactions(list) {
    const ids = list.map((j) => j.id).filter((id) => !(id in S.react));
    if (!ids.length) return;
    try {
      const got = await API.reactions(ids);
      for (const id of ids) S.react[id] = got[id] || { lol: 0, sigh: 0, dead: 0, mine: null };
      for (const j of list) { const el = document.querySelector(`[data-reacts="${j.id}"]`); if (el) el.innerHTML = reactsHtml(j); }
    } catch (e) { /* Reaktionen sind Beiwerk */ }
  }
  async function react(id, kind, j) {
    const r = S.react[id] || { lol: 0, sigh: 0, dead: 0, mine: null };
    const prev = { ...r };
    const next = r.mine === kind ? null : kind;
    if (r.mine) r[r.mine] = Math.max(0, r[r.mine] - 1);
    if (next) r[next]++;
    r.mine = next; S.react[id] = r;
    const el = document.querySelector(`[data-reacts="${id}"]`); if (el && j) el.innerHTML = reactsHtml(j);
    try { await API.react(id, next); markActivity(); }
    catch (e) { S.react[id] = prev; if (el && j) el.innerHTML = reactsHtml(j); toast(errorText(e)); }
  }

  /* ───────── Bestenliste ───────── */
  async function renderList(token) {
    if (!S.rows.length) $("#main").innerHTML = '<p class="loading">Lade Bestenliste …</p>';
    let rows = await API.ranking(S.range, S.cat, S.shown + 1, 0);
    S.fallback = null;
    // Noch nichts los? Dann die Besten des nächstgrößeren Zeitraums zeigen statt einer leeren Seite.
    for (const wider of S.range === "day" ? ["week", "all"] : S.range === "week" ? ["all"] : []) {
      if (rows.length) break;
      rows = await API.ranking(wider, S.cat, S.shown + 1, 0);
      if (rows.length) S.fallback = wider;
    }
    if (stale(token)) return;
    S.hasMore = rows.length > S.shown;
    S.rows = rows.slice(0, S.shown).filter((j) => !S.hiddenForMe.has(j.id));
    drawList();
    warmUp();
    loadReactions(S.rows);
    loadChallenge().then(() => { if (!stale(token)) drawListBanners(); });
    loadSponsors().then(() => { const el = $("#spList"); if (el && !stale(token)) el.innerHTML = sponsorHtml("list"); });
    if (S.announcement === null) API.announcement().then((a) => { S.announcement = a || ""; if (!stale(token)) drawListBanners(); }).catch(() => { S.announcement = ""; });
    loadHighlights().then(() => { if (!stale(token)) drawListBanners(); });
  }
  function drawList() {
    const r = RANGES[S.fallback || S.range];
    const fallbackNote = S.fallback
      ? `<div class="notice">${S.range === "day" ? "Heute gibt es noch keine neuen Witze." : "Diese Woche gibt es noch keine neuen Witze."} Hier sind die ${S.fallback === "week" ? "Besten der Woche" : "Besten aller Zeiten"}. Poste den ersten von heute!</div>`
      : "";
    $("#main").innerHTML = `<div class="view">
      <div id="listBanners" class="banners">${bannersHtml()}</div>
      <a class="cta" href="#/bewerten"><span><strong>Neue Witze bewerten</strong><br>Wisch dich durch frische Einsendungen und entscheide mit, wer nach oben kommt.</span><span class="arrow" aria-hidden="true">→</span></a>
      <div id="spList">${sponsorHtml("list")}</div>
      ${fallbackNote}
      <div class="meta-row"><span>${r.label}</span><span>${S.rows.length === 1 ? "1 Witz" : S.rows.length + (S.hasMore ? "+" : "") + " Witze"}</span></div>
      ${S.rows.length ? `<ol class="list">${S.rows.map((j, i) => cardHtml(j, i + 1, i === 0 ? r.best : "")).join("")}</ol>`
        : `<p class="empty">${S.range === "all" ? "Noch hat kein Witz 20 Stimmen. Hilf mit und bewerte neue Witze!" : S.range === "new" ? "In den letzten 6 Stunden wurde noch kein Witz gepostet. Sei der Erste!" : "Hier gibt es noch keine Witze. Poste den ersten!"}</p>`}
      ${S.hasMore ? '<button class="btn ghost more" data-more>Weitere Witze</button>' : ""}
      <section class="how"><h2>So funktioniert das Ranking</h2>
        <p>Sortiert wird nach dem Wilson-Score: der vorsichtigen Schätzung, wie viel Prozent aller Leser den Witz mögen. Ein Witz mit 4 von 4 Likes landet deshalb hinter einem mit 180 von 200.</p>
        <p>„Neu“ zeigt die Newcomer der letzten 6 Stunden, die neuesten zuerst, damit frische Witze schnell Stimmen bekommen. „Heute“ zeigt Witze der letzten 24 Stunden, „Woche“ der letzten 7 Tage. Für „Alltime“ braucht ein Witz mindestens 20 Stimmen.</p></section>
    </div>`;
  }

  // Nach dem ersten Laden Duell und Battle schon im Hintergrund vorbereiten
  let warmed = false;
  function warmUp() {
    if (warmed) return; warmed = true;
    const go = () => { fillDuel(); };
    if (window.requestIdleCallback) requestIdleCallback(go, { timeout: 3000 }); else setTimeout(go, 1500);
  }

  /* ───────── Abstimmen (sofort anzeigen, bei Fehler zurück) ───────── */
  // Witz in der gerade angezeigten Liste finden (Bestenliste, Suche, Gruppe oder Einzelansicht)
  const otherList = () => (route().view === "search" ? S.searchRows : route().view === "group" ? S.groupRows : null) || [];
  function findRow(id) { return S.rows.find((j) => j.id === id) || otherList().find((j) => j.id === id) || (S.detail && S.detail.id === id ? S.detail : null); }
  async function vote(id, value) {
    const j = findRow(id); if (!j || j.own) return;
    const prev = { up: j.up, down: j.down, myVote: j.myVote };
    const next = j.myVote === value ? 0 : value;
    if (j.myVote === 1) j.up--; if (j.myVote === -1) j.down--;
    if (next === 1) j.up++; if (next === -1) j.down++;
    j.myVote = next; j.score = wilson(j.up, j.down);
    redrawCard(j);
    try { const r = await API.vote(id, next); j.up = r.up; j.down = r.down; j.score = wilson(j.up, j.down); redrawCard(j); if (next) markActivity(); }
    catch (e) { Object.assign(j, prev); j.score = wilson(j.up, j.down); redrawCard(j); toast(errorText(e)); }
  }
  function redrawCard(j) {
    const el = document.querySelector(`[data-card="${j.id}"]`); if (!el) return;
    const single = el.classList.contains("single");
    const inList = S.rows.includes(j), rank = single ? null : (inList ? S.rows.indexOf(j) : otherList().indexOf(j)) + 1;
    el.outerHTML = cardHtml(j, rank, inList && rank === 1 ? RANGES[S.range].best : "");
  }

  /* ───────── Swipe-Modus ───────── */
  let refillPromise = null;
  function refill() {
    if (S.swipeDone) return Promise.resolve();
    if (refillPromise) return refillPromise;
    refillPromise = (async () => {
      const exclude = [...S.seen, ...S.queue.map((j) => j.id)];
      const more = (await API.unrated(exclude)).filter((j) => !exclude.includes(j.id) && !S.hiddenForMe.has(j.id));
      if (!more.length) S.swipeDone = true;
      S.queue.push(...more);
    })().finally(() => { refillPromise = null; });
    return refillPromise;
  }
  async function renderSwipe(token) {
    if (S.queue.length < 3 && !S.swipeDone) {
      if (!S.queue.length) $("#main").innerHTML = '<p class="loading">Lade neue Witze …</p>';
      await refill();
      if (stale(token)) return;
    }
    drawSwipe();
  }
  let drag = null, leaving = false;
  function drawSwipe() {
    const cur = S.queue[0], next = S.queue[1];
    const sn = streakCount();
    const intro = `<div><h1>Neue Witze bewerten</h1><p class="muted">Wisch nach rechts, wenn du lachen musstest, nach links, wenn nicht.${sn >= 2 ? ` <span class="streak-pill">🔥 ${sn} Tage in Folge</span>` : ""}</p></div>${favsHtml()}`;
    if (!cur) {
      $("#main").innerHTML = `<div class="view">${intro}<div class="swipe-empty"><h2>Alles bewertet!</h2>
        <p class="muted">${S.rated ? `Du hast ${S.rated} ${S.rated === 1 ? "Witz" : "Witze"} bewertet. ` : ""}Gerade gibt es keine neuen Witze für dich.</p>
        <div class="row center"><a class="btn ghost" href="#/">Zur Bestenliste</a><button class="btn accent" data-post>Selbst einen posten</button></div></div></div>`;
      return;
    }
    const n = cur.up + cur.down;
    $("#main").innerHTML = `<div class="view">${intro}
      <div class="swipe-stage">
        ${next ? `<div class="swipe-card behind" aria-hidden="true"><div class="tag">${CATS[next.cat] || ""}</div><p class="swipe-text">${esc(next.text)}</p></div>` : ""}
        <div class="swipe-card" id="swipeCard">
          <span class="stamp like" id="stampLike">Lustig</span><span class="stamp nope" id="stampNope">Nicht lustig</span>
          <div class="tag">${CATS[cur.cat] || ""}</div>
          <p class="swipe-text">${esc(cur.text)}</p>
          <div class="swipe-meta">@${esc(cur.author)} · ${ago(cur.created)} · ${n === 0 ? "noch keine Stimmen" : fmt(n) + " Stimmen"}</div>
        </div>
      </div>
      <div class="swipe-actions">
        <button class="round nope" data-swipe="-1" aria-label="Nicht lustig"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
        <button class="btn ghost" data-swipe="0">Überspringen</button>
        <button class="round like" data-swipe="1" aria-label="Lustig"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg></button>
      </div>
      <p class="swipe-hint">${S.rated ? S.rated + " bewertet" : ""}<span class="kbd-hint">${S.rated ? " · " : ""}Tastatur: ← nicht lustig · → lustig · ↓ überspringen</span></p>
    </div>`;
    const card = $("#swipeCard");
    const setDx = (dx) => {
      card.style.transform = `translateX(${dx}px) rotate(${dx / 18}deg)`;
      $("#stampLike").style.opacity = Math.min(Math.max(dx / 110, 0), 1);
      $("#stampNope").style.opacity = Math.min(Math.max(-dx / 110, 0), 1);
    };
    card.addEventListener("pointerdown", (e) => { if (leaving) return; card.setPointerCapture(e.pointerId); drag = { x: e.clientX, dx: 0 }; card.classList.add("dragging"); });
    card.addEventListener("pointermove", (e) => { if (!drag) return; drag.dx = e.clientX - drag.x; setDx(drag.dx); });
    card.addEventListener("pointerup", () => { if (!drag) return; const dx = drag.dx; drag = null; card.classList.remove("dragging"); if (dx > 110) decide(1); else if (dx < -110) decide(-1); else setDx(0); });
    card.addEventListener("pointercancel", () => { drag = null; card.classList.remove("dragging"); setDx(0); });
  }
  function decide(d) {
    const cur = S.queue[0]; if (!cur || leaving) return;
    leaving = true;
    S.seen.add(cur.id);
    if (d !== 0) {
      S.rated++;
      API.vote(cur.id, d).then(markActivity).catch((e) => toast(errorText(e)));
    }
    const card = $("#swipeCard");
    if (card) {
      if (d === 1) $("#stampLike").style.opacity = 1;
      if (d === -1) $("#stampNope").style.opacity = 1;
      card.classList.add("leaving");
      card.style.transform = d === 0 ? "translateY(-40px) scale(.96)" : `translateX(${d * 130}%) rotate(${d * 14}deg)`;
    }
    setTimeout(() => {
      S.queue.shift(); leaving = false;
      if (route().view !== "swipe") return;
      const needsMore = S.queue.length < 3 && !S.swipeDone;
      const wasEmpty = !S.queue.length;
      if (wasEmpty && needsMore) $("#main").innerHTML = '<p class="loading">Lade neue Witze …</p>';
      else drawSwipe();
      if (needsMore) refill().then(() => { if (wasEmpty && route().view === "swipe") drawSwipe(); }).catch((e) => toast(errorText(e)));
    }, 230);
  }

  /* ───────── Witz-Seite & Teilen ───────── */
  const shareUrl = (id) => location.origin + location.pathname + "#/witz/" + id;
  async function renderDetail(token, id) {
    $("#main").innerHTML = '<p class="loading">Lade Witz …</p>';
    const j = await API.joke(id);
    if (stale(token)) return;
    S.detail = j;
    if (!j || S.hiddenForMe.has(j.id)) {
      $("#main").innerHTML = `<div class="view"><p class="empty">Diesen Witz gibt es nicht (mehr).</p><a class="btn ghost" href="#/">Zur Bestenliste</a></div>`;
      return;
    }
    if (!S.daily) { try { S.daily = await API.daily(30); } catch (e) { S.daily = []; } if (stale(token)) return; }
    await loadSponsors(); if (stale(token)) return;
    const crown = S.daily.find((d) => d.id === j.id);
    j.label = crown ? "Witz des Tages · " + fmtDay(crown.day) : null;
    j.sponsor = crown && S.sponsors.daily ? S.sponsors.daily.name : null;
    const url = shareUrl(j.id);
    const wa = "https://wa.me/?text=" + encodeURIComponent(j.text + "\n\nMehr davon: " + url.replace("#", "?s=wa#"));
    $("#main").innerHTML = `<div class="view">
      <div><a class="link" href="#/" style="font-size:.88rem">← Zur Bestenliste</a></div>
      ${crown ? `<div class="crown-badge">👑 Witz des Tages am ${fmtDay(crown.day)}</div>${sponsorHtml("daily")}` : ""}
      <ol class="list">${cardHtml(j)}</ol>
      <section class="share" aria-label="Teilen">
        <h2>Witz teilen</h2>
        <div class="share-grid">
          <div class="share-buttons">
            <a class="btn wa" href="${wa}" target="_blank" rel="noopener noreferrer">Per WhatsApp schicken</a>
            <button class="btn ghost" data-share-image>Als Bild teilen</button>
            <button class="btn ghost" data-card-open>Als Grußkarte</button>
            <button class="btn ghost" data-share-link>Link teilen</button>
            ${crown ? '<button class="btn ghost" data-share-channel>Text für WhatsApp-Kanal kopieren</button>' : ""}
            <p class="muted small" id="shareMsg" role="status"></p>
          </div>
          <canvas id="storyCanvas" aria-label="Vorschau des Story-Bilds"></canvas>
        </div>
      </section>
      ${cardBoxHtml()}
      ${j.own ? '<div id="minePush"></div>' : ""}
      <div class="row"><button class="btn ghost" data-morecat="${j.cat}">Mehr ${CATS[j.cat] || ""}</button><a class="btn ghost" href="#/bewerten">Neue Witze bewerten</a></div>
    </div>`;
    drawStory($("#storyCanvas"), j);
    loadReactions([j]);
    if (j.own) drawMinePush();
  }

  function wrapLines(c, text, maxW) {
    const out = [];
    for (const para of text.split("\n")) {
      let line = "";
      for (const w of para.split(/\s+/)) { const t = line ? line + " " + w : w; if (c.measureText(t).width > maxW && line) { out.push(line); line = w; } else line = t; }
      out.push(line);
    }
    return out;
  }
  function rr(c, x, y, w, h, r) { c.beginPath(); c.moveTo(x + r, y); c.arcTo(x + w, y, x + w, y + h, r); c.arcTo(x + w, y + h, x, y + h, r); c.arcTo(x, y + h, x, y, r); c.arcTo(x, y, x + w, y, r); c.closePath(); }
  function drawStory(canvas, j) {
    const W = 1080, H = 1920, pad = 80, c = canvas.getContext("2d");
    canvas.width = W; canvas.height = H;
    const DISPLAY = getComputedStyle(document.documentElement).getPropertyValue("--f-display");
    const BODY = getComputedStyle(document.documentElement).getPropertyValue("--f-body");
    const host = location.host || "lachwerk";
    c.fillStyle = "#ffc928"; c.fillRect(0, 0, W, H); c.textBaseline = "top";
    const ls = 64, ly = 130;
    c.font = `800 ${ls}px ${DISPLAY}`; c.fillStyle = "#15172a"; c.fillText("Lach", pad, ly);
    const lw = c.measureText("Lach").width, ww = c.measureText("werk").width;
    rr(c, pad + lw + 4, ly - ls * 0.12, ww + ls * 0.36, ls * 1.18, ls * 0.18); c.fill();
    c.fillStyle = "#ffc928"; c.fillText("werk", pad + lw + 4 + ls * 0.18, ly);
    const fs = 38, fy = H - 130 - fs;
    c.font = `600 ${fs}px ${BODY}`; c.fillStyle = "#15172a"; c.fillText("Bewerte ihn auf " + host, pad, fy);
    if (j.sponsor) { c.font = `500 30px ${BODY}`; c.fillStyle = "#4a3c06"; c.fillText("präsentiert von " + j.sponsor, pad, fy - 52); }
    let top = ly + ls * 1.4 + 60;
    if (j.label) {
      c.font = `800 40px ${DISPLAY}`;
      const t = "👑 " + j.label.toUpperCase(), tw = c.measureText(t).width;
      c.fillStyle = "#15172a"; rr(c, pad, top, tw + 56, 76, 38); c.fill();
      c.fillStyle = "#ffc928"; c.fillText(t, pad + 28, top + 18);
      top += 76 + 40;
    }
    const cp = 60, maxW = W - 2 * pad - 2 * cp, avail = fy - 60 - top;
    let size = 84, lines, lh;
    for (;;) { c.font = `500 ${size}px ${BODY}`; lines = wrapLines(c, j.text, maxW); lh = size * 1.28; if (cp * 2 + 30 + 18 + lines.length * lh + 24 + 30 <= avail || size <= 28) break; size -= 2; }
    const ch = cp * 2 + 30 + 18 + lines.length * lh + 24 + 30, cy = top + Math.max(0, (avail - ch) / 2);
    c.fillStyle = "#15172a"; rr(c, pad, cy + 12, W - 2 * pad, ch, 48); c.fill();
    c.fillStyle = "#ffffff"; rr(c, pad, cy, W - 2 * pad, ch, 48); c.fill();
    let y = cy + cp;
    c.fillStyle = "#5b5f78"; c.font = `600 30px ${BODY}`; c.fillText((CATS[j.cat] || "").toUpperCase(), pad + cp, y);
    y += 48; c.fillStyle = "#15172a"; c.font = `500 ${size}px ${BODY}`;
    for (const l of lines) { c.fillText(l, pad + cp, y); y += lh; }
    y += 24; c.fillStyle = "#5b5f78"; c.font = `500 30px ${BODY}`; c.fillText("@" + j.author, pad + cp, y);
  }
  async function shareImage() {
    const j = S.detail, msg = $("#shareMsg"), canvas = $("#storyCanvas"); if (!j || !canvas) return;
    const blob = await new Promise((r) => canvas.toBlob(r, "image/png"));
    if (!blob) { msg.textContent = "Das Bild konnte nicht erstellt werden."; return; }
    const file = new File([blob], `lachwerk-witz-${j.id}.png`, { type: "image/png" });
    try {
      if (navigator.canShare && navigator.canShare({ files: [file] })) { await navigator.share({ files: [file], text: shareUrl(j.id) }); return; }
    } catch (e) { if (e.name === "AbortError") return; }
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob); a.download = file.name; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    msg.textContent = "Bild gespeichert. Du kannst es jetzt in deiner Story posten.";
  }
  async function shareChannel() {
    const j = S.detail, msg = $("#shareMsg"); if (!j) return;
    const crown = (S.daily || []).find((d) => d.id === j.id);
    const t = `👑 Witz des Tages${crown ? " vom " + fmtDay(crown.day) : ""}\n\n${j.text}\n\n😂 Mehr Witze und mitbewerten: ${shareUrl(j.id)}`;
    try { await navigator.clipboard.writeText(t); msg.textContent = "Text kopiert. Jetzt im Kanal einfügen und das Story-Bild dazu anhängen."; }
    catch (e) { msg.textContent = t; }
  }
  async function shareLink() {
    const j = S.detail, msg = $("#shareMsg"); if (!j) return;
    const url = shareUrl(j.id);
    if (navigator.share) { try { await navigator.share({ title: "Witz auf Lachwerk", text: j.text, url }); return; } catch (e) { if (e.name === "AbortError") return; } }
    try { await navigator.clipboard.writeText(url); msg.textContent = "Link kopiert."; } catch (e) { msg.textContent = url; }
  }

  /* ───────── Zeit-Helfer ───────── */
  const parseDay = (d) => new Date(String(d).slice(0, 10) + "T12:00:00");
  const fmtDay = (d) => parseDay(d).toLocaleDateString("de-DE", { day: "numeric", month: "long" });
  const fmtShort = (d) => parseDay(d).toLocaleDateString("de-DE", { weekday: "short", day: "numeric", month: "numeric" });
  function until(iso) {
    const m = Math.max(0, (new Date(iso).getTime() - Date.now()) / 6e4);
    if (m < 60) return `noch ${Math.max(1, Math.round(m))} Min.`;
    const h = Math.floor(m / 60), d = Math.floor(h / 24);
    if (d >= 1) return `noch ${d} ${d === 1 ? "Tag" : "Tage"}${h % 24 ? ` ${h % 24} Std.` : ""}`;
    return `noch ${h} Std.`;
  }
  function nextCrown() { const t = new Date(); t.setHours(20, 0, 0, 0); if (t.getTime() <= Date.now()) t.setDate(t.getDate() + 1); return t; }
  const dayKey = (t) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };

  /* ───────── Bewertungs-Serie (nur in diesem Browser) ───────── */
  function streakCount() {
    const days = new Set(store.get("streak", []));
    let n = 0, t = Date.now();
    if (!days.has(dayKey(t))) t -= 864e5;              // heute noch nicht bewertet: Serie von gestern zählt noch
    while (days.has(dayKey(t))) { n++; t -= 864e5; }
    return n;
  }
  function markActivity() {
    const today = dayKey(Date.now()), days = store.get("streak", []);
    if (days.includes(today)) return;
    days.push(today); store.set("streak", days.slice(-60));
    const n = streakCount();
    if (n >= 2) toast(`🔥 ${n} Tage in Folge dabei!${[3, 7, 30].includes(n) ? " Neues Abzeichen!" : ""}`);
  }
  const STREAK_BADGES = [[3, "Stammgast", "3 Tage in Folge bewertet"], [7, "Wochen-Held", "7 Tage in Folge"], [30, "Lach-Legende", "30 Tage in Folge"]];

  /* ───────── Challenge & Hinweise (für Banner) ───────── */
  let challengeLoad = null;
  function loadChallenge(force) {
    if (S.challenges && !force) return Promise.resolve(S.challenges);
    if (!challengeLoad || force) challengeLoad = API.challenges().then((c) => (S.challenges = c)).catch(() => (S.challenges = [])).finally(() => { challengeLoad = null; });
    return challengeLoad;
  }
  const activeChallenge = () => (S.challenges || []).find((c) => c.active) || null;
  async function loadHighlights() {
    if (!AUTH || !LIVE) { S.hl = []; return; }
    try {
      const seen = new Set(store.get("hl_seen", []));
      S.hl = (await API.highlights()).filter((h) => !seen.has(`${h.kind}:${h.joke_id}:${h.value}`));
    } catch (e) { S.hl = []; }
  }
  function hlText(h) {
    if (h.kind === "rank") return h.value === 1 ? "🏆 Dein Witz steht gerade auf Platz 1 von heute!" : `🥈 Dein Witz ist gerade auf Platz ${h.value} von heute!`;
    if (h.kind === "crown") return `👑 Dein Witz wurde zum Witz des Tages gekrönt (${fmtDay(String(h.value).replace(/(\d{4})(\d\d)(\d\d)/, "$1-$2-$3"))})!`;
    return `🎉 Dein Witz hat ${fmt(h.value)} Likes geknackt!`;
  }
  function bannersHtml() {
    const out = [];
    const ann = S.announcement;
    if (ann && store.get("ann_hidden", "") !== ann) out.push(`<div class="banner ann"><span>📣 ${esc(ann)}</span><button class="x" data-ann-dismiss aria-label="Hinweis schließen">×</button></div>`);
    for (const h of (S.hl || []).slice(0, 2)) {
      out.push(`<div class="banner hl"><a href="#/witz/${h.joke_id}">${hlText(h)}</a><button class="x" data-hl-dismiss="${esc(`${h.kind}:${h.joke_id}:${h.value}`)}" aria-label="Hinweis schließen">×</button></div>`);
    }
    const c = activeChallenge();
    if (c && !store.get("challenge_hidden_" + c.id, false)) out.push(`<a class="banner ch" href="#/challenge"><span class="ch-k">Challenge der Woche</span><strong>${esc(c.title)}</strong><span class="ch-m">${until(c.ends_at)} · Mitmachen →</span></a>`);
    return out.join("");
  }
  function drawListBanners() { const el = $("#listBanners"); if (el) el.innerHTML = bannersHtml(); }

  /* ───────── Sponsoren ───────── */
  let sponsorLoad = null;
  function loadSponsors() {
    if (S.sponsors) return Promise.resolve(S.sponsors);
    if (!sponsorLoad) sponsorLoad = API.sponsors().then((x) => (S.sponsors = x)).catch(() => (S.sponsors = {}));
    return sponsorLoad;
  }
  // Gekennzeichnet als „Sponsor“ (Werbung muss erkennbar sein). Link öffnet in neuem Tab.
  function sponsorHtml(place, dark) {
    const sp = S.sponsors && S.sponsors[place]; if (!sp) return "";
    const inner = `<span class="sp-k">Sponsor</span>${sp.logo ? `<img src="${sp.logo}" alt="">` : ""}<span class="sp-t"><b>präsentiert von ${esc(sp.name)}</b>${sp.claim ? `<small>${esc(sp.claim)}</small>` : ""}</span>`;
    return sp.url ? `<a class="sponsor${dark ? " dark" : ""}" href="${esc(sp.url)}" target="_blank" rel="sponsored noopener" data-sponsor="${sp.id}">${inner}</a>`
      : `<div class="sponsor${dark ? " dark" : ""}">${inner}</div>`;
  }

  /* ───────── Kleine Karte (Highlights, Archiv) ───────── */
  function miniHtml(j, label, extra) {
    return `<a class="mini" href="#/witz/${j.id}"><span class="mini-k">${label}</span><span class="mini-t">${esc(j.text)}</span><span class="mini-m">@${esc(j.author)}${extra ? " · " + extra : ""}</span></a>`;
  }

  /* ───────── Highlights ───────── */
  async function renderHighlights(token) {
    $("#main").innerHTML = '<p class="loading">Lade Highlights …</p>';
    const safe = (p, d) => p.catch(() => d);
    const [daily, authors, champs, lol, sigh, dead, battle, seasons] = await Promise.all([
      safe(API.daily(7), []), safe(API.authors("week"), []), safe(API.duelRanking(3), []),
      safe(API.reactionTop("lol", 1), []), safe(API.reactionTop("sigh", 1), []), safe(API.reactionTop("dead", 1), []),
      Promise.resolve(null), safe(API.seasonWinners(), []), loadChallenge(), loadSponsors(),
    ]);
    if (stale(token)) return;
    S.daily = daily;
    const top = daily[0], c = activeChallenge(), past = (S.challenges || []).filter((x) => !x.active && x.winner_joke);
    const n = streakCount(), wb = authors[0];
    const reactRows = [[lol[0], "😂 Lacher der Woche"], [sigh[0], "🙄 Größter Seufzer der Woche"], [dead[0], "💀 Schwärzester der Woche"]].filter(([j]) => j);
    $("#main").innerHTML = `<div class="view">
      <h1>Highlights</h1>
      <section class="crown">
        <div class="crown-k">👑 Witz des Tages${top ? " · " + fmtDay(top.day) : ""}</div>
        ${top ? `<p class="crown-t">${esc(top.text)}</p>
          <div class="crown-m">${authorLink(top.author)} · ${fmt(top.up)} Likes</div>
          <div class="row"><a class="btn" href="#/witz/${top.id}">Als Story teilen</a></div>`
        : `<p class="crown-t small">Noch kein Witz gekrönt. Bewerte fleißig mit!</p>`}
        ${sponsorHtml("daily", true)}
        <p class="crown-n">Nächste Krönung: ${nextCrown().toLocaleDateString("de-DE", { weekday: "long" })}, 20:00 Uhr (${until(nextCrown().toISOString())})</p>
      </section>
      ${daily.length > 1 ? `<section class="hl-sec"><h2>Die letzten Tage</h2><div class="minis">${daily.slice(1).map((d) => miniHtml(d, "👑 " + fmtShort(d.day))).join("")}</div></section>` : ""}
      ${c ? `<a class="banner ch" href="#/challenge"><span class="ch-k">Challenge der Woche</span><strong>${esc(c.title)}</strong><span class="ch-m">${c.entries} ${c.entries === 1 ? "Beitrag" : "Beiträge"} · ${until(c.ends_at)} · Mitmachen →</span></a>` : ""}
      ${battle ? `<a class="banner ch battle-b" href="#/battle"><span class="ch-k">🥊 Pointen-Battle von heute</span><strong>${esc(battle.setup)}</strong><span class="ch-m">${battle.entries} ${battle.entries === 1 ? "Pointe" : "Pointen"} · Mitmachen →</span></a>` : ""}
      ${seasons[0] ? `<a class="mini" href="#/u/${encodeURIComponent(seasons[0].username)}"><span class="mini-k">🏆 Witzbold des Monats · ${parseDay(seasons[0].month).toLocaleDateString("de-DE", { month: "long" })}</span><span class="mini-t">@${esc(seasons[0].username)}</span></a>` : ""}
      <section class="hl-sec"><h2>Witzbold der Woche</h2>
        ${wb ? `<a class="mini" href="#/u/${encodeURIComponent(wb.username)}"><span class="mini-k">🃏 Meiste Lacher in 7 Tagen</span><span class="mini-t">@${esc(wb.username)}</span><span class="mini-m">${wb.jokes} ${wb.jokes === 1 ? "Witz" : "Witze"} · ${fmt(wb.up_count)} Likes · Score ${(wb.score * 100).toFixed(1)}</span></a>
          <a class="link more-link" href="#/autoren">Alle Autoren ansehen</a>`
        : `<p class="muted small on-y">Noch kein Witzbold diese Woche. Poste Witze und sammle Lacher!</p>`}
      </section>
      ${reactRows.length ? `<section class="hl-sec"><h2>Reaktionen der Woche</h2><div class="minis">${reactRows.map(([j, l]) => miniHtml(j, l, `${fmt(j.n)}×`)).join("")}</div></section>` : ""}
      ${champs.length ? `<section class="hl-sec"><h2>Duell-Champions</h2><div class="minis">${champs.map((j, i) => miniHtml(j, `⚔️ Platz ${i + 1}`, `${j.duels} Duelle`)).join("")}</div><a class="link more-link" href="#/duell">Selbst Duelle entscheiden</a></section>` : ""}
      ${past.length ? `<section class="hl-sec"><h2>Challenge-Sieger</h2><div class="minis">${past.map((x) => `<a class="mini" href="#/witz/${x.winner_joke}"><span class="mini-k">🏅 ${esc(x.title)}</span><span class="mini-t">@${esc(x.winner_name || "")}</span></a>`).join("")}</div></section>` : ""}
      <section class="hl-sec"><h2>Deine Serie</h2>
        <div class="streak"><span class="streak-n">🔥 ${n}</span><span>${n === 1 ? "Tag" : "Tage"} in Folge bewertet</span></div>
        <div class="badges">${STREAK_BADGES.map(([d, name, desc]) => `<span class="bdg${n >= d ? " on" : ""}" title="${desc}">${name}<small>${desc}</small></span>`).join("")}</div>
        ${installHtml()}
      </section>
      <section class="hl-sec" id="push"><h2>Benachrichtigungen</h2><div id="pushBox"></div></section>
    </div>`;
  }

  /* ───────── Duell ───────── */
  // (Benachrichtigungen werden nach dem Zeichnen der Highlights nachgeladen, siehe render())
  // Duelle werden im Hintergrund vorgeladen, damit nach einem Tipp sofort das nächste erscheint
  const D = { pair: [], next: [], done: 0, busy: false, decided: new Set(), filling: null, gen: 0 };
  const pairKey = (p) => p.map((j) => j.id).sort((a, b) => a - b).join("-");
  function fillDuel() {
    if (D.filling || D.next.length >= 2) return D.filling || Promise.resolve();
    const gen = D.gen;
    D.filling = API.duel().then((p) => {
      if (gen !== D.gen) return false;   // Themen wurden inzwischen geändert
      const k = p.length === 2 ? pairKey(p) : null;
      if (k && !D.decided.has(k) && k !== pairKey(D.pair) && !D.next.some((x) => pairKey(x) === k)) D.next.push(p);
      return p.length === 2;
    }).catch(() => false).finally(() => { D.filling = null; }).then((ok) => { if (ok && D.next.length < 2) fillDuel(); });
    return D.filling;
  }
  async function renderDuel(token) {
    if (D.pair.length < 2 && D.next.length) D.pair = D.next.shift();
    if (D.pair.length < 2) {
      $("#main").innerHTML = '<p class="loading">Lade Duell …</p>';
      D.pair = await API.duel();
      if (stale(token)) return;
    }
    drawDuel();
    fillDuel();
  }
  function drawDuel() {
    const [a, b] = D.pair;
    const intro = `<div><h1>Witze-Duell</h1><p class="muted">Welcher ist lustiger? Tipp auf deinen Favoriten.</p></div>${favsHtml()}`;
    if (!a || !b) {
      $("#main").innerHTML = `<div class="view">${intro}<div class="swipe-empty"><h2>Keine Duelle mehr</h2><p class="muted">Du hast alle Paarungen entschieden. Schau später wieder vorbei!</p><div class="row center"><a class="btn ghost" href="#/highlights">Highlights</a></div></div></div>`;
      return;
    }
    const card = (j, k) => `<button class="duel-card" data-duel="${j.id}" data-other="${(k ? a : b).id}"><span class="tag">${CATS[j.cat] || ""}</span><span class="duel-t">${esc(j.text)}</span><span class="duel-pick">Der ist besser</span></button>`;
    $("#main").innerHTML = `<div class="view">${intro}
      <div class="duel-grid">${card(a, 0)}<div class="vs" aria-hidden="true">VS</div>${card(b, 1)}</div>
      <div class="row center"><button class="btn ghost" data-duel-skip>Beide gleich – nächstes Duell</button></div>
      <p class="swipe-hint">${D.done ? D.done + " entschieden" : ""}<span class="kbd-hint">${D.done ? " · " : ""}Tastatur: 1 = oben · 2 = unten · ↓ überspringen</span></p>
    </div>`;
  }
  async function duelPick(winner, loser) {
    if (D.busy) return;
    D.busy = true;
    D.decided.add(pairKey(D.pair));
    D.next = D.next.filter((p) => !D.decided.has(pairKey(p)));
    if (winner) {
      document.querySelectorAll(".duel-card").forEach((el) => el.classList.add(Number(el.dataset.duel) === winner ? "won" : "lost"));
      D.done++;
      API.duelVote(winner, loser).then(markActivity).catch((e) => toast(errorText(e)));
    }
    const wait = new Promise((r) => setTimeout(r, winner ? 260 : 0));
    let next = D.next.shift();
    if (!next) { await fillDuel(); next = D.next.shift() || (await API.duel().catch(() => [])); }
    await wait;
    D.pair = next; D.busy = false;
    if (route().view === "duel") drawDuel();
    fillDuel();
  }

  /* ───────── Autoren ───────── */
  async function renderAuthors(token) {
    $("#main").innerHTML = '<p class="loading">Lade Autoren …</p>';
    const [rows, seasons] = await Promise.all([API.authors(S.authorRange), API.seasonWinners().catch(() => [])]);
    if (stale(token)) return;
    const monthName = new Date().toLocaleDateString("de-DE", { month: "long" });
    const next1 = new Date(); next1.setMonth(next1.getMonth() + 1, 1); next1.setHours(0, 0, 0, 0);
    $("#main").innerHTML = `<div class="view">
      <div><h1>Witzbolde</h1><p class="muted">Die Autoren mit den meisten Lachern. Eigene Liga für Studio, Firma oder Freunde? <a href="#/gruppen">Gruppe gründen</a></p></div>
      <div class="tabs" role="tablist">
        <button role="tab" data-authrange="week" aria-selected="${S.authorRange === "week"}">Woche</button>
        <button role="tab" data-authrange="month" aria-selected="${S.authorRange === "month"}">Saison</button>
        <button role="tab" data-authrange="all" aria-selected="${S.authorRange === "all"}">Alltime</button>
      </div>
      ${rows.length ? `<ol class="authors">${rows.map((a, i) => `<li><a href="#/u/${encodeURIComponent(a.username)}">
          <span class="a-rank">${i + 1}</span>
          <span class="a-name">@${esc(a.username)}${i === 0 ? ` <span class="pill">${{ week: "Witzbold der Woche", month: "Führt die Saison", all: "Allzeit-Bester" }[S.authorRange]}</span>` : ""}</span>
          <span class="a-meta">${a.jokes} ${a.jokes === 1 ? "Witz" : "Witze"} · ${fmt(a.up_count)} Likes · Score ${(a.score * 100).toFixed(1)}</span></a></li>`).join("")}</ol>`
        : `<p class="empty">${{ week: "Diese Woche hat noch kein Autor genug Stimmen (mind. 5).", month: "In dieser Saison hat noch kein Autor 10 Stimmen gesammelt.", all: "Noch hat kein Autor 20 Stimmen gesammelt." }[S.authorRange]} Poste Witze und teil sie!</p>`}
      ${S.authorRange === "month" ? `<p class="muted small on-y">Saison ${monthName}: Am ${next1.toLocaleDateString("de-DE", { day: "numeric", month: "long" })} wird der Witzbold des Monats gekrönt und bekommt ein Abzeichen. Danach beginnt eine neue Saison.</p>` : ""}
      ${seasons.length ? `<section class="hl-sec"><h2>Witzbolde des Monats</h2><div class="minis">${seasons.map((x) => `<a class="mini" href="#/u/${encodeURIComponent(x.username)}"><span class="mini-k">🏆 ${parseDay(x.month).toLocaleDateString("de-DE", { month: "long", year: "numeric" })}</span><span class="mini-t">@${esc(x.username)}</span></a>`).join("")}</div></section>` : ""}
      <section class="how"><h2>So wird gezählt</h2><p>Alle Likes und Dislikes der Witze eines Autors zusammen, bewertet mit dem Wilson-Score. Wer viele mittelmäßige Witze postet, landet deshalb nicht automatisch vorn. Mindestens 5 Stimmen pro Woche, 10 pro Saison (Kalendermonat) bzw. 20 insgesamt. Witze der Lachwerk-Redaktion zählen nicht mit.</p></section>
    </div>`;
  }

  /* ───────── Profil ───────── */
  const BADGES = [
    ["Erster Witz", "Den ersten Witz gepostet", (p) => p.jokes >= 1],
    ["Fleißig", "10 Witze gepostet", (p) => p.jokes >= 10],
    ["Auf dem Podest", "Gerade unter den Top 3 von heute", (p) => p.best_rank && p.best_rank <= 3],
    ["Witz des Tages", "Einmal zum Witz des Tages gekrönt", (p) => p.crowns >= 1],
    ["Dauerbrenner", "3× Witz des Tages", (p) => p.crowns >= 3],
    ["Publikumsliebling", "Ein Witz mit 100 Likes", (p) => p.top_up >= 100],
    ["Lachmaschine", "500 Likes insgesamt", (p) => p.up_count >= 500],
    ["Challenge-Sieger", "Eine Wochen-Challenge gewonnen", (p) => p.challenge_wins >= 1],
    ["Witzbold des Monats", "Eine Monats-Saison gewonnen", (p) => p.season_wins >= 1],
  ];
  async function renderProfile(token, name) {
    $("#main").innerHTML = '<p class="loading">Lade Profil …</p>';
    if (name === "Lachwerk") {
      $("#main").innerHTML = `<div class="view"><div class="profile-head"><div class="avatar" aria-hidden="true">L</div><div><h1>@Lachwerk</h1><p class="muted">Die Redaktion. Wir sorgen für Nachschub, bis die Community übernimmt.</p></div></div><a class="btn ghost" href="#/autoren">Zu den Autoren</a></div>`;
      return;
    }
    const [p, jokes] = await Promise.all([API.profile(name), API.profileJokes(name)]);
    if (stale(token)) return;
    if (!p) { $("#main").innerHTML = `<div class="view"><p class="empty">Dieses Profil gibt es nicht.</p><a class="btn ghost" href="#/autoren">Zu den Autoren</a></div>`; return; }
    const isMe = AUTH && AUTH.username && AUTH.username.toLowerCase() === p.username.toLowerCase();
    const n = p.up_count + p.down_count;
    S.rows = jokes;
    $("#main").innerHTML = `<div class="view">
      <div class="profile-head"><div class="avatar" aria-hidden="true">${esc(p.username.slice(0, 1).toUpperCase())}</div>
        <div><h1>@${esc(p.username)}</h1><p class="muted">${p.member_since ? "Dabei seit " + new Date(p.member_since).toLocaleDateString("de-DE", { month: "long", year: "numeric" }) : "Witzbold"}${isMe ? " · Das bist du" : ""}</p></div></div>
      <div class="stats">
        <div><b>${fmt(p.jokes)}</b><span>Witze</span></div>
        <div><b>${fmt(p.up_count)}</b><span>Likes</span></div>
        <div><b>${n ? Math.round((p.up_count / n) * 100) + " %" : "–"}</b><span>Lacher-Quote</span></div>
        <div><b>${fmt(p.crowns)}</b><span>× Witz des Tages</span></div>
      </div>
      <section class="hl-sec"><h2>Abzeichen</h2><div class="badges">${BADGES.map(([b, d, ok]) => `<span class="bdg${ok(p) ? " on" : ""}" title="${d}">${b}<small>${d}</small></span>`).join("")}</div></section>
      <div class="meta-row"><span>Beste Witze von @${esc(p.username)}</span><span>${jokes.length} ${jokes.length === 1 ? "Witz" : "Witze"}</span></div>
      ${jokes.length ? `<ol class="list">${jokes.map((j, i) => cardHtml(j, i + 1, "")).join("")}</ol>` : `<p class="empty">${isMe ? "Du hast noch keinen Witz gepostet. Leg los!" : "Noch keine Witze."}</p>`}
      ${isMe ? `<div class="row center"><button class="btn accent" data-post>Neuen Witz posten</button></div>` : ""}
    </div>`;
    loadReactions(jokes);
  }

  /* ───────── Challenge ───────── */
  async function renderChallenge(token) {
    $("#main").innerHTML = '<p class="loading">Lade Challenge …</p>';
    await Promise.all([loadChallenge(true), loadSponsors()]);
    const c = activeChallenge();
    const rows = c ? await API.challengeRanking(c.id) : [];
    if (stale(token)) return;
    S.rows = rows;
    const past = (S.challenges || []).filter((x) => !x.active);
    $("#main").innerHTML = `<div class="view">
      ${c ? `<section class="crown ch-hero"><div class="crown-k">Challenge der Woche · ${until(c.ends_at)}</div>
          <h1>${esc(c.title)}</h1>${c.description ? `<p>${esc(c.description)}</p>` : ""}
          <p class="crown-n">Endet ${new Date(c.ends_at).toLocaleString("de-DE", { weekday: "long", hour: "2-digit", minute: "2-digit" })} Uhr · ${c.entries} ${c.entries === 1 ? "Beitrag" : "Beiträge"}</p>
          <div class="row"><button class="btn" data-challenge-join>Witz einreichen</button></div>${sponsorHtml("challenge", true)}</section>
        <div class="meta-row"><span>Rangliste der Challenge</span><span>${rows.length} ${rows.length === 1 ? "Witz" : "Witze"}</span></div>
        ${rows.length ? `<ol class="list">${rows.map((j, i) => cardHtml(j, i + 1, i === 0 ? "Vorn" : "")).join("")}</ol>` : `<p class="empty">Noch keine Beiträge. Reich den ersten ein!</p>`}`
      : `<p class="empty">Gerade läuft keine Challenge. Die nächste kommt bestimmt!</p>`}
      ${past.length ? `<section class="hl-sec"><h2>Frühere Challenges</h2><div class="minis">${past.map((x) => x.winner_joke
        ? `<a class="mini" href="#/witz/${x.winner_joke}"><span class="mini-k">🏅 ${esc(x.title)}</span><span class="mini-t">Gewonnen von @${esc(x.winner_name || "")}</span><span class="mini-m">${x.entries} Beiträge</span></a>`
        : `<div class="mini"><span class="mini-k">${esc(x.title)}</span><span class="mini-t">Ohne Sieger</span></div>`).join("")}</div></section>` : ""}
    </div>`;
    loadReactions(rows);
  }

  /* ───────── Lieblingskategorien (für Bewerten und Duell) ───────── */
  function favsHtml() {
    return `<div class="favs"><span class="favs-k">Meine Themen:</span><div class="chips static">${Object.entries(CATS).map(([k, v]) => `<button class="chip" data-fav="${k}" aria-pressed="${S.favs.includes(k)}">${v}</button>`).join("")}</div>
      <span class="muted small on-y">${S.favs.length ? "Nur gewählte Themen. Nochmal tippen zum Abwählen." : "Alle Themen. Tipp an, was du am liebsten magst."}</span></div>`;
  }
  function toggleFav(k) {
    S.favs = S.favs.includes(k) ? S.favs.filter((x) => x !== k) : [...S.favs, k];
    store.set("favs", S.favs);
    S.queue = []; S.seen = new Set(); S.swipeDone = false; D.pair = []; D.next = []; D.gen++;
    render();
  }

  /* ───────── Pointen-Battle ───────── */
  // Battle: zuletzt geladenen Stand sofort zeigen, im Hintergrund aktualisieren
  let battleCache = null;
  async function fetchBattle() {
    const today = dayKey(Date.now());
    const known = battleCache && battleCache.b && battleCache.b.day === today ? battleCache.b.id : null;
    const [b, archive, early] = await Promise.all([API.battleToday(), API.battleArchive(7).catch(() => []), known ? API.battleEntries(known) : null]);
    const entries = b ? (early && known === b.id ? early : await API.battleEntries(b.id)) : [];
    battleCache = { b, entries, archive, at: Date.now() };
    return battleCache;
  }
  async function renderBattle(token) {
    if (battleCache) {
      drawBattle(battleCache);
      fetchBattle().then((c) => { if (!stale(token) && !document.activeElement.closest("#punchForm")) drawBattle(c); }).catch(() => {});
      return;
    }
    $("#main").innerHTML = '<p class="loading">Lade Battle …</p>';
    const [c] = await Promise.all([fetchBattle(), loadSponsors()]);
    if (stale(token)) return;
    drawBattle(c);
  }
  function drawBattle({ b, entries, archive }) {
    const hidden = new Set(store.get("hidden_punch", []));
    entries = entries.filter((e) => !hidden.has(e.id));
    S.battle = b; S.punch = entries;
    const end = new Date(); end.setHours(24, 0, 0, 0);
    const mine = entries.filter((e) => e.own).length;
    $("#main").innerHTML = `<div class="view">
      <div><h1>Pointen-Battle</h1><p class="muted">Jeden Tag ein Witz ohne Pointe. Du schreibst die Pointe, alle stimmen ab.</p></div>
      ${b ? `<section class="crown battle-hero">
          <div class="crown-k">Battle von heute · ${until(end.toISOString())}</div>
          <p class="crown-t">${esc(b.setup)}</p>
          ${AUTH ? (mine >= 3 ? `<p class="crown-n">Du hast heute schon 3 Pointen eingereicht. Jetzt fleißig abstimmen!</p>`
            : `<form id="punchForm" class="punch-form"><textarea id="punchText" maxlength="200" rows="2" placeholder="Deine Pointe …"></textarea>
               <p class="err" id="punchErr"></p><div class="row"><button class="btn">Pointe einreichen</button><span class="crown-n">${3 - mine} von 3 übrig</span></div></form>`)
          : `<div class="row"><button class="btn" data-punch-login>Anmelden und mitmachen</button></div>`}
          ${sponsorHtml("battle", true)}
        </section>
        <div class="meta-row"><span>Pointen von heute</span><span>${entries.length} ${entries.length === 1 ? "Pointe" : "Pointen"}</span></div>
        ${entries.length ? `<ol class="list punches">${entries.map((e, i) => punchHtml(e, i + 1)).join("")}</ol>` : `<p class="empty">Noch keine Pointe. Sei die oder der Erste!</p>`}`
      : `<p class="empty">Heute gibt es kein Battle. Morgen geht's weiter!</p>`}
      ${archive.length ? `<section class="hl-sec"><h2>Gewinner der letzten Tage</h2><div class="minis">${archive.map((a) => `<div class="mini"><span class="mini-k">🥊 ${fmtShort(a.day)}${a.entries ? ` · ${a.entries} Pointen` : ""}</span><span class="mini-t">${esc(a.setup)}${a.winner_body ? `\n<b>${esc(a.winner_body)}</b>` : ""}</span>${a.winner_name ? `<span class="mini-m">Gewonnen von @${esc(a.winner_name)} · ${a.winner_up} Likes</span>` : '<span class="mini-m">Ohne Sieger</span>'}</div>`).join("")}</div></section>` : ""}
    </div>`;
  }
  function punchHtml(e, rank) {
    const dis = e.own ? ' disabled title="Eigene Pointen kannst du nicht bewerten"' : "";
    return `<li class="card punch${rank <= 3 ? " top" : ""}" data-punch="${e.id}"><div class="rank">${rank}</div>
      <div class="body"><p class="joke">${esc(e.text)}</p></div>
      <div class="foot"><button class="vote up" data-pvote="1" data-id="${e.id}" aria-pressed="${e.myVote === 1}" aria-label="Gute Pointe"${dis}>${ICON_UP}${fmt(e.up)}</button>
        <button class="vote down" data-pvote="-1" data-id="${e.id}" aria-pressed="${e.myVote === -1}" aria-label="Schwache Pointe"${dis}>${ICON_DOWN}${fmt(e.down)}</button>
        <span class="score">${authorLink(e.author)}${e.own ? " · deine" : ` · <button class="link" data-report-punch="${e.id}">Melden</button>`}</span></div></li>`;
  }
  async function votePunch(id, value) {
    const e = S.punch.find((x) => x.id === id); if (!e || e.own) return;
    const prev = { up: e.up, down: e.down, myVote: e.myVote }, next = e.myVote === value ? 0 : value;
    if (e.myVote === 1) e.up--; if (e.myVote === -1) e.down--; if (next === 1) e.up++; if (next === -1) e.down++;
    e.myVote = next;
    const el = () => document.querySelector(`[data-punch="${id}"]`);
    const redraw = () => { const x = el(); if (x) x.outerHTML = punchHtml(e, S.punch.indexOf(e) + 1); };
    redraw();
    try { const r = await API.votePunchline(id, next); e.up = r.up; e.down = r.down; redraw(); if (next) markActivity(); }
    catch (err) { Object.assign(e, prev); redraw(); toast(errorText(err)); }
  }
  async function submitPunch() {
    const text = $("#punchText").value.trim(), err = $("#punchErr");
    if (text.length < 2 || text.length > 200) { err.textContent = ERRORS.invalid_punchline; return; }
    const btn = $("#punchForm button"); btn.disabled = true; err.textContent = "";
    try { await API.postPunchline(S.battle.id, text); toast("Pointe eingereicht. Viel Glück!"); battleCache = null; render(); }
    catch (ex) { if (ex.code === "not_logged_in") { setAuth(null); openAuth("login", ERRORS.not_logged_in, "battle"); } else err.textContent = errorText(ex); btn.disabled = false; }
  }

  /* ───────── QR-Code (Version 3, Fehlerkorrektur M, Byte-Modus, bis 42 Zeichen) ───────── */
  const qrSvg = (() => {
    const SIZE = 29, NDATA = 44, NEC = 26, EXP = new Array(512).fill(0), LOG = new Array(256).fill(0);
    for (let i = 0, x = 1; i < 255; i++) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 0x100) x ^= 0x11d; }
    for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
    const mul = (a, b) => (a && b ? EXP[LOG[a] + LOG[b]] : 0);
    let gen = [1];
    for (let i = 0; i < NEC; i++) { const ng = new Array(gen.length + 1).fill(0); gen.forEach((c, j) => { ng[j] ^= c; ng[j + 1] ^= mul(c, EXP[i]); }); gen = ng; }
    const ecc = (data) => { const res = [...data, ...new Array(NEC).fill(0)]; for (let i = 0; i < data.length; i++) { const c = res[i]; if (c) for (let j = 1; j < gen.length; j++) res[i + j] ^= mul(gen[j], c); } return res.slice(data.length); };
    const MASKS = [(r, c) => (r + c) % 2 === 0, (r) => r % 2 === 0, (r, c) => c % 3 === 0, (r, c) => (r + c) % 3 === 0,
      (r, c) => (Math.floor(r / 2) + Math.floor(c / 3)) % 2 === 0, (r, c) => ((r * c) % 2) + ((r * c) % 3) === 0,
      (r, c) => (((r * c) % 2) + ((r * c) % 3)) % 2 === 0, (r, c) => (((r + c) % 2) + ((r * c) % 3)) % 2 === 0];
    const fmtBits = (mask) => { const d = (0 << 3) | mask; let v = d << 10; for (let i = 14; i >= 10; i--) if (v & (1 << i)) v ^= 0x537 << (i - 10); return ((d << 10) | v) ^ 0x5412; };
    return (text) => {
      const bytes = [...new TextEncoder().encode(text)]; if (bytes.length > 42) return "";
      let bits = "0100" + bytes.length.toString(2).padStart(8, "0") + bytes.map((b) => b.toString(2).padStart(8, "0")).join("");
      bits += "0".repeat(Math.min(4, NDATA * 8 - bits.length)); bits += "0".repeat((8 - (bits.length % 8)) % 8);
      const cw = []; for (let i = 0; i < bits.length; i += 8) cw.push(parseInt(bits.slice(i, i + 8), 2));
      for (let i = 0; cw.length < NDATA; i++) cw.push(i % 2 ? 0x11 : 0xec);
      const all = [...cw, ...ecc(cw)];
      const M = Array.from({ length: SIZE }, () => new Array(SIZE).fill(null));
      const finder = (r, c) => { for (let dr = -1; dr < 8; dr++) for (let dc = -1; dc < 8; dc++) { const rr = r + dr, cc = c + dc; if (rr < 0 || cc < 0 || rr >= SIZE || cc >= SIZE) continue;
        M[rr][cc] = ((dr >= 0 && dr <= 6 && (dc === 0 || dc === 6)) || (dc >= 0 && dc <= 6 && (dr === 0 || dr === 6)) || (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4)) ? 1 : 0; } };
      finder(0, 0); finder(0, SIZE - 7); finder(SIZE - 7, 0);
      for (let i = 8; i < SIZE - 8; i++) M[6][i] = M[i][6] = i % 2 === 0 ? 1 : 0;
      for (let dr = -2; dr <= 2; dr++) for (let dc = -2; dc <= 2; dc++) M[22 + dr][22 + dc] = Math.max(Math.abs(dr), Math.abs(dc)) !== 1 ? 1 : 0;
      M[SIZE - 8][8] = 1;
      const res = M.map((row) => row.map((v) => v !== null));
      const pos1 = [[8, 0], [8, 1], [8, 2], [8, 3], [8, 4], [8, 5], [8, 7], [8, 8], [7, 8], [5, 8], [4, 8], [3, 8], [2, 8], [1, 8], [0, 8]];
      const pos2 = [[SIZE - 1, 8], [SIZE - 2, 8], [SIZE - 3, 8], [SIZE - 4, 8], [SIZE - 5, 8], [SIZE - 6, 8], [SIZE - 7, 8], [8, SIZE - 8], [8, SIZE - 7], [8, SIZE - 6], [8, SIZE - 5], [8, SIZE - 4], [8, SIZE - 3], [8, SIZE - 2], [8, SIZE - 1]];
      [...pos1, ...pos2].forEach(([r, c]) => (res[r][c] = true));
      const dbits = all.map((b) => b.toString(2).padStart(8, "0")).join("");
      for (let c = SIZE - 1, k = 0, up = true; c > 0; c -= 2, up = !up) {
        if (c === 6) c--;
        for (let n = 0; n < SIZE; n++) { const r = up ? SIZE - 1 - n : n; for (const cc of [c, c - 1]) if (!res[r][cc]) { M[r][cc] = k < dbits.length ? +dbits[k] : 0; k++; } }
      }
      const build = (mask) => {
        const A = M.map((row, r) => row.map((v, c) => (!res[r][c] && MASKS[mask](r, c) ? v ^ 1 : v)));
        const f = fmtBits(mask);
        for (let i = 0; i < 15; i++) { const bit = (f >> (14 - i)) & 1; A[pos1[i][0]][pos1[i][1]] = bit; A[pos2[i][0]][pos2[i][1]] = bit; }
        return A;
      };
      const penalty = (A) => {
        let p = 0; const cols = A[0].map((_, c) => A.map((row) => row[c]));
        for (const line of [...A, ...cols]) { let run = 1; for (let i = 1; i < SIZE; i++) { if (line[i] === line[i - 1]) run++; else { if (run >= 5) p += run - 2; run = 1; } } if (run >= 5) p += run - 2; }
        for (let r = 0; r < SIZE - 1; r++) for (let c = 0; c < SIZE - 1; c++) if (A[r][c] === A[r][c + 1] && A[r][c] === A[r + 1][c] && A[r][c] === A[r + 1][c + 1]) p += 3;
        const dark = A.flat().reduce((s, v) => s + v, 0); p += Math.abs(Math.floor((dark * 20) / (SIZE * SIZE)) - 10) * 10;
        return p;
      };
      let best = 0, bp = Infinity; for (let m = 0; m < 8; m++) { const p = penalty(build(m)); if (p < bp) { bp = p; best = m; } }
      const A = build(best), q = 4, n = SIZE + 2 * q;
      let d = ""; for (let r = 0; r < SIZE; r++) for (let c = 0; c < SIZE; c++) if (A[r][c]) d += `M${c + q} ${r + q}h1v1h-1z`;
      return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${n} ${n}" shape-rendering="crispEdges"><rect width="${n}" height="${n}" fill="#fff"/><path fill="#15172a" d="${d}"/></svg>`;
    };
  })();

  const baseUrl = () => location.origin + location.pathname.replace(/[^/]*$/, "");
  const liveOnly = () => `<div class="view"><p class="empty">Diese Funktion gibt es nur in der Live-Version mit Datenbank.</p></div>`;

  /* ───────── Errate die Pointe ───────── */
  const QZ = { list: [], i: 0, mode: "daily", picked: null, answers: [], streak: 0, loading: false };
  const berlinDay = () => new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Berlin" });
  const quizRow = (r) => ({ id: Number(r.id), setup: r.setup, options: r.options, correct: Number(r.correct), cat: r.cat, author: r.author });
  const quizEmoji = (a) => a.map((x) => (x ? "🟩" : "🟥")).join("");
  async function renderQuiz(token, mode) {
    if (!LIVE) { $("#main").innerHTML = liveOnly(); return; }
    const today = berlinDay(), done = store.get("quiz_daily", null);
    QZ.picked = null;
    if (mode !== "endless" && done && done.day === today) { QZ.mode = "result"; drawQuiz(); return; }
    $("#main").innerHTML = '<p class="loading">Lade Quiz …</p>';
    if (mode === "endless") {
      QZ.mode = "endless"; QZ.i = 0; QZ.streak = 0;
      QZ.list = (await rpc("get_quiz", { p_daily: false, p_n: 10, p_cats: S.favs.length ? S.favs : null })).map(quizRow);
    } else {
      QZ.mode = "daily";
      QZ.list = (await rpc("get_quiz", { p_daily: true, p_n: 5 })).map(quizRow);
      const prog = store.get("quiz_progress", null);
      QZ.answers = prog && prog.day === today ? prog.answers : [];
      QZ.i = Math.min(QZ.answers.length, QZ.list.length);
      if (QZ.i >= QZ.list.length && QZ.list.length) { await finishDaily(); return; }
    }
    if (stale(token)) return;
    drawQuiz();
  }
  function drawQuiz() {
    const best = store.get("quiz_best", 0);
    if (QZ.mode === "result") {
      const d = store.get("quiz_daily", {}), a = d.answers || [], score = a.filter(Boolean).length, c = d.cmp;
      const pct = c && c.players > 1 ? Math.round(((c.worse + Math.max(c.same - 1, 0) / 2) / (c.players - 1)) * 100) : null;
      $("#main").innerHTML = `<div class="view quiz">
        <div><h1>Errate die Pointe</h1><p class="muted">Jeden Tag 5 Witzanfänge, für alle dieselben. Welche Pointe gehört dazu?</p></div>
        <section class="panel quiz-result">
          <span class="quiz-k">Tagesquiz ${new Date().toLocaleDateString("de-DE", { day: "numeric", month: "long" })}</span>
          <div class="quiz-emoji">${quizEmoji(a)}</div>
          <b class="quiz-score">${score} von ${a.length} richtig</b>
          <p class="muted">${score === 5 ? "Perfekt! Du kennst deine Pointen." : score >= 3 ? "Starke Leistung!" : "Morgen gibt es neue Chancen."}${pct ? ` Besser als ${pct} % der ${fmt(c.players)} Spieler von heute.` : c && c.players > 1 ? ` Heute haben schon ${fmt(c.players)} Leute mitgerätselt.` : ""}</p>
          <div class="row"><button class="btn" data-quiz-share>Ergebnis teilen</button><a class="btn ghost" href="#/quiz?endlos">Endlos weiterspielen</a></div>
          <p class="small muted">Das nächste Tagesquiz gibt es ab Mitternacht.${best ? ` Dein Rekord im Endlos-Modus: ${best} in Folge.` : ""}</p>
        </section>
      </div>`;
      return;
    }
    const q = QZ.list[QZ.i];
    if (!q) { $("#main").innerHTML = `<div class="view"><p class="empty">Gerade gibt es keine passenden Witze für das Quiz.</p></div>`; return; }
    const answered = QZ.picked != null, right = answered && QZ.picked === q.correct;
    const head = QZ.mode === "daily"
      ? `<span class="quiz-k">Tagesquiz · Frage ${QZ.i + 1} von ${QZ.list.length}</span><span class="quiz-dots">${QZ.list.map((_, i) => `<i class="${i < QZ.answers.length ? (QZ.answers[i] ? "ok" : "no") : i === QZ.i ? "now" : ""}"></i>`).join("")}</span>`
      : `<span class="quiz-k">Endlos · Serie ${QZ.streak}</span><span class="quiz-k">Rekord ${best}</span>`;
    const last = QZ.mode === "daily" && QZ.i === QZ.list.length - 1;
    $("#main").innerHTML = `<div class="view quiz">
      <div><h1>Errate die Pointe</h1><p class="muted">Welche Pointe gehört zu diesem Witz?</p></div>
      <section class="panel quiz-card">
        <div class="quiz-head">${head}</div>
        <p class="quiz-setup">${esc(q.setup)}</p>
        <div class="quiz-opts">${q.options.map((o, i) => {
          const n = i + 1, cls = answered ? (n === q.correct ? " right" : n === QZ.picked ? " wrong" : " dim") : "";
          return `<button class="quiz-opt${cls}" data-quiz-opt="${n}"${answered ? " disabled" : ""}><b>${"ABC"[i]}</b><span>${esc(o)}</span></button>`;
        }).join("")}</div>
        ${answered ? `<div class="quiz-after">
          <b class="quiz-verdict ${right ? "ok" : "no"}">${right ? "Richtig! 🎉" : QZ.mode === "endless" ? `Daneben. Deine Serie: ${QZ.streak}` : "Leider daneben."}</b>
          <span class="muted small">Witz von ${authorLink(q.author)} · ${CATS[q.cat] || ""} · <a href="#/witz/${q.id}">Witz ansehen</a></span>
          <button class="btn" data-quiz-next>${last ? "Ergebnis ansehen" : QZ.mode === "endless" && !right ? "Neue Serie" : "Weiter"}</button>
        </div>` : `<p class="small muted quiz-hint">Tipp: Die Tasten 1, 2 und 3 gehen auch.</p>`}
      </section>
      ${QZ.mode === "endless" ? `<p class="small muted on-y"><a href="#/quiz">Zum Tagesquiz</a></p>` : ""}
    </div>`;
  }
  function quizAnswer(n) {
    const q = QZ.list[QZ.i]; if (!q || QZ.picked != null) return;
    QZ.picked = n; const ok = n === q.correct;
    if (QZ.mode === "daily") { QZ.answers = [...QZ.answers, ok]; store.set("quiz_progress", { day: berlinDay(), answers: QZ.answers }); }
    else { if (ok) { QZ.streak++; if (QZ.streak > store.get("quiz_best", 0)) store.set("quiz_best", QZ.streak); } }
    markActivity && markActivity();
    drawQuiz();
  }
  async function quizNext() {
    const q = QZ.list[QZ.i]; if (!q || QZ.picked == null) return;
    const wasRight = QZ.picked === q.correct;
    QZ.picked = null; QZ.i++;
    if (QZ.mode === "daily") { if (QZ.i >= QZ.list.length) { await finishDaily(); return; } }
    else {
      if (!wasRight) QZ.streak = 0;
      if (QZ.i >= QZ.list.length - 3 && !QZ.loading) {
        QZ.loading = true;
        try { const more = (await rpc("get_quiz", { p_daily: false, p_n: 10, p_cats: S.favs.length ? S.favs : null })).map(quizRow); const seen = new Set(QZ.list.map((x) => x.id)); QZ.list.push(...more.filter((x) => !seen.has(x.id))); }
        catch (e) { /* später erneut */ }
        QZ.loading = false;
      }
    }
    drawQuiz();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }
  async function finishDaily() {
    const answers = QZ.answers, score = answers.filter(Boolean).length, day = berlinDay();
    let cmp = null; try { cmp = (await rpc("submit_quiz", { p_device: DEVICE, p_score: score }))[0] || null; } catch (e) { /* ohne Vergleich */ }
    store.set("quiz_daily", { day, answers, cmp });
    QZ.mode = "result"; drawQuiz();
  }
  async function quizShare() {
    const d = store.get("quiz_daily", {}), a = d.answers || [];
    const text = `Lachwerk-Tagesquiz ${new Date().toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" })}\n${quizEmoji(a)} ${a.filter(Boolean).length}/${a.length}\nErrätst du die Pointen?`;
    const url = baseUrl() + "#/quiz";
    if (navigator.share) { try { await navigator.share({ text, url }); return; } catch (e) { if (e.name === "AbortError") return; } }
    const all = text + "\n" + url;
    if (navigator.clipboard) navigator.clipboard.writeText(all).then(() => toast("Ergebnis kopiert."), () => window.open("https://wa.me/?text=" + encodeURIComponent(all), "_blank"));
    else window.open("https://wa.me/?text=" + encodeURIComponent(all), "_blank");
  }

  /* ───────── Live-Duell: Abstimmen am Handy (#/live/CODE) ───────── */
  const LV = { timer: null, clock: null, code: null, round: null, skew: 0, key: "" };
  function stopLive() { clearTimeout(LV.timer); clearInterval(LV.clock); LV.timer = LV.clock = null; }
  const lvLeft = (r) => Math.max(0, Math.ceil((new Date(r.ends_at).getTime() - (Date.now() - LV.skew)) / 1000));
  const lvPct = (r) => { const n = r.a_votes + r.b_votes; return n ? [Math.round((r.a_votes / n) * 100), 100 - Math.round((r.a_votes / n) * 100)] : [0, 0]; };
  async function renderLive(token, code) {
    stopLive(); LV.code = code; LV.key = ""; LV.round = null;
    if (!LIVE) { $("#main").innerHTML = liveOnly(); return; }
    $("#main").innerHTML = '<p class="loading">Verbinde mit dem Bildschirm …</p>';
    LV.clock = setInterval(() => { const el = $("#lvSec"); if (el && LV.round) el.textContent = lvLeft(LV.round); }, 500);
    await liveTick(token);
  }
  async function liveTick(token) {
    if (stale(token)) return;
    let r = null;
    try { r = (await rpc("live_round", { p_screen: LV.code, p_device: DEVICE, p_start: false }))[0] || null; }
    catch (e) { if (e.code === "invalid_screen") { stopLive(); $("#main").innerHTML = `<div class="view"><p class="empty">Diesen Bildschirm-Code gibt es nicht. Scanne den QR-Code am Bildschirm noch einmal.</p></div>`; return; } }
    if (stale(token)) return;
    if (r) { LV.skew = Date.now() - new Date(r.server_now).getTime(); r.a_votes = Number(r.a_votes); r.b_votes = Number(r.b_votes); }
    if (!(LV.round && r && LV.round.id === r.id && LV.round.my_choice && !r.my_choice)) LV.round = r; else LV.round = { ...r, my_choice: LV.round.my_choice };
    drawLive();
    LV.timer = setTimeout(() => liveTick(token), r && !r.finished ? 2000 : 3000);
  }
  function drawLive() {
    const r = LV.round;
    const fresh = r && (!r.finished || Date.now() - LV.skew - new Date(r.ends_at).getTime() < 40000);
    const key = !fresh ? "wait" : `${r.id}-${r.finished}-${r.my_choice || 0}`;
    if (key === LV.key && fresh) { // nur Zahlen aktualisieren
      const [pa, pb] = lvPct(r);
      [[1, pa, r.a_votes], [2, pb, r.b_votes]].forEach(([n, p, v]) => { const b = $(`#lvBar${n}`), t = $(`#lvPct${n}`); if (b) b.style.width = p + "%"; if (t) t.textContent = `${p} % · ${fmt(v)} ${v === 1 ? "Stimme" : "Stimmen"}`; });
      return;
    }
    LV.key = key;
    if (!fresh) {
      $("#main").innerHTML = `<div class="view live"><section class="panel live-wait"><span class="live-k">⚡ Live-Duell</span><h1>Gleich geht's los</h1>
        <p class="muted">Schau auf den Bildschirm: Sobald dort das nächste Duell startet, kannst du hier abstimmen. Diese Seite aktualisiert sich von selbst.</p>
        <p class="loading">Warte auf die nächste Runde …</p></section>
        <p class="small muted on-y">Zwischendurch: <a href="#/">Bestenliste</a> · <a href="#/duell">Duell</a></p></div>`;
      return;
    }
    const [pa, pb] = lvPct(r), voted = !!r.my_choice, show = voted || r.finished, win = r.finished ? (r.a_votes > r.b_votes ? 1 : r.b_votes > r.a_votes ? 2 : 0) : 0;
    const card = (n, text, p, v) => `<button class="live-opt${r.my_choice === n ? " mine" : ""}${win === n ? " win" : ""}${win && win !== n ? " lose" : ""}" data-live-vote="${n}"${r.finished ? " disabled" : ""}>
        <b class="live-l">${"AB"[n - 1]}</b><span class="live-t">${esc(text)}</span>
        ${show ? `<span class="live-bar"><i id="lvBar${n}" style="width:${p}%"></i></span><span class="live-pct" id="lvPct${n}">${p} % · ${fmt(v)} ${v === 1 ? "Stimme" : "Stimmen"}</span>` : `<span class="live-pick">Der ist lustiger</span>`}
      </button>`;
    $("#main").innerHTML = `<div class="view live">
      <div class="live-head"><span class="live-k">⚡ Live-Duell</span>${r.finished ? `<b>${win ? `${"AB"[win - 1]} gewinnt!` : r.a_votes + r.b_votes ? "Unentschieden!" : "Runde vorbei"}</b>` : `<b>Noch <span id="lvSec">${lvLeft(r)}</span> s</b>`}</div>
      <p class="muted on-y">${r.finished ? "Die nächste Runde startet gleich auf dem Bildschirm." : voted ? "Danke! Du kannst deine Wahl bis zum Ende noch ändern." : "Welcher Witz ist lustiger? Tippe auf deinen Favoriten."}</p>
      <div class="live-pair">${card(1, r.a_text, pa, r.a_votes)}${card(2, r.b_text, pb, r.b_votes)}</div>
    </div>`;
  }
  async function liveVote(n) {
    const r = LV.round; if (!r || r.finished) return;
    const prev = r.my_choice; if (prev === n) return;
    if (prev === 1) r.a_votes--; if (prev === 2) r.b_votes--;
    if (n === 1) r.a_votes++; else r.b_votes++;
    r.my_choice = n; drawLive();
    try { await rpc("live_vote", { p_device: DEVICE, p_round: r.id, p_choice: n }); }
    catch (e) { toast(e.code === "round_over" ? "Diese Runde ist schon vorbei." : errorText(e)); }
  }

  /* ───────── Gruppen und Ligen ───────── */
  const GR_ERR = { group_not_found: "Diese Gruppe gibt es nicht. Prüfe den Code.", group_limit: "Du kannst höchstens 5 Gruppen gründen und in 30 Gruppen Mitglied sein.",
    group_full: "Diese Gruppe ist voll.", owner_cannot_leave: "Als Gründer kannst du nicht austreten. Du kannst die Gruppe aber löschen.", not_owner: "Das darf nur der Gründer der Gruppe.",
    invalid_group_name: "Der Gruppenname braucht 3 bis 40 Zeichen." };
  Object.assign(ERRORS, GR_ERR, { invalid_screen: "Diesen Bildschirm-Code gibt es nicht.", round_over: "Diese Runde ist schon vorbei." });
  const groupUrl = (code) => baseUrl() + "g/" + code;
  async function renderGroups(token) {
    if (!LIVE) { $("#main").innerHTML = liveOnly(); return; }
    $("#main").innerHTML = '<p class="loading">Lade Gruppen …</p>';
    const mine = AUTH ? await rpc("my_groups", {}).catch(() => []) : [];
    if (stale(token)) return;
    $("#main").innerHTML = `<div class="view groups">
      <div><h1>Gruppen</h1><p class="muted">Eure eigene Liga: für Studio, Firma, Verein, Klasse oder Freundeskreis. Alle posten wie gewohnt, die Gruppe bekommt ihre eigene Bestenliste und ihren Witzbold des Monats. Auf Wunsch auch auf dem Bildschirm im Studio oder Büro.</p></div>
      ${AUTH ? `${mine.length ? `<section class="hl-sec"><h2>Deine Gruppen</h2><ul class="grp-list">${mine.map((g) => `<li><a href="#/gruppe/${g.code}"><b>${esc(g.name)}</b><span>${fmt(g.members)} ${g.members === 1 ? "Mitglied" : "Mitglieder"}${g.is_owner ? " · von dir gegründet" : ""}</span></a></li>`).join("")}</ul></section>` : ""}
        <div class="grp-forms">
          <form class="panel form" id="groupCreate"><h2>Gruppe gründen</h2>
            <label>Name der Gruppe<input type="text" id="groupName" maxlength="40" placeholder="z. B. Kollegen vom 3. Stock" required autocomplete="off"></label>
            <button class="btn">Gründen</button><p class="err small" id="groupCreateErr"></p></form>
          <form class="panel form" id="groupJoin"><h2>Gruppe beitreten</h2>
            <label>Einladungscode<input type="text" id="groupCode" maxlength="6" placeholder="z. B. K7P2QX" required autocomplete="off" autocapitalize="characters" spellcheck="false"></label>
            <button class="btn ghost">Beitreten</button><p class="err small" id="groupJoinErr"></p></form>
        </div>`
      : `<section class="panel"><p>Zum Gründen und Beitreten brauchst du ein Konto. Das geht in einer Minute und ohne E-Mail-Bestätigung.</p><div><button class="btn" data-group-login>Anmelden oder registrieren</button></div></section>`}
      <section class="how"><h2>So funktioniert's</h2><p>Gründe eine Gruppe und teile den Einladungslink. Wer beitritt, zählt mit seinen Witzen für die Gruppe: Bestenliste der Woche, des Monats und aller Zeiten, dazu die witzigsten Mitglieder. Die Witze bleiben ganz normale öffentliche Lachwerk-Witze.</p></section>
    </div>`;
  }
  async function renderGroup(token, code) {
    if (!LIVE) { $("#main").innerHTML = liveOnly(); return; }
    $("#main").innerHTML = '<p class="loading">Lade Gruppe …</p>';
    const range = S.groupRange || "week";
    const [g, jokes, members] = await Promise.all([rpc("get_group", { p_code: code }).then((x) => x[0] || null),
      rpc("group_ranking", { p_device: DEVICE, p_code: code, p_range: range, p_limit: 20 }).then((x) => x.map(fromRow)).catch(() => []),
      rpc("group_members_ranking", { p_code: code, p_range: range }).catch(() => [])]);
    if (stale(token)) return;
    if (!g) { $("#main").innerHTML = `<div class="view"><p class="empty">Diese Gruppe gibt es nicht (mehr).<br><a class="btn" href="#/gruppen" style="margin-top:12px">Zu den Gruppen</a></p></div>`; return; }
    S.groupRows = jokes;
    const url = groupUrl(g.code), active = members.filter((m) => m.jokes > 0);
    const title = { week: "Witzbold der Woche", month: "Witzbold des Monats", all: "Allzeit-Bester" }[range];
    const invite = `Mach mit in unserer Witze-Liga „${g.name}“ auf Lachwerk: ${url}`;
    $("#main").innerHTML = `<div class="view group">
      <section class="grp-hero">
        <span class="live-k">👥 Gruppe</span>
        <h1>${esc(g.name)}</h1>
        <p>${fmt(g.members)} ${g.members === 1 ? "Mitglied" : "Mitglieder"} · gegründet von @${esc(g.owner_name || "?")}</p>
        <div class="row">${g.is_member ? `<span class="pill">Du bist dabei</span>` : `<button class="btn" data-group-join="${g.code}">Beitreten</button>`}
          ${g.is_member ? `<button class="btn ghost on-dark" data-post-open>Witz posten</button>` : ""}</div>
      </section>
      <div class="tabs" role="tablist">${[["week", "Woche"], ["month", "Monat"], ["all", "Gesamt"]].map(([k, l]) => `<button role="tab" data-grouprange="${k}" aria-selected="${range === k}">${l}</button>`).join("")}</div>
      <section class="hl-sec"><h2>Witzigste Mitglieder</h2>
        ${active.length ? `<ol class="authors">${active.slice(0, 10).map((a, i) => `<li><a href="#/u/${encodeURIComponent(a.username)}"><span class="a-rank">${i + 1}</span>
          <span class="a-name">@${esc(a.username)}${i === 0 ? ` <span class="pill">${title}</span>` : ""}</span>
          <span class="a-meta">${a.jokes} ${a.jokes === 1 ? "Witz" : "Witze"} · ${fmt(a.up_count)} Likes</span></a></li>`).join("")}</ol>`
        : `<p class="empty">${range === "all" ? "Noch hat niemand aus der Gruppe einen Witz gepostet." : "In diesem Zeitraum hat noch niemand aus der Gruppe gepostet."} Fang an!</p>`}
      </section>
      <section class="hl-sec"><h2>Beste Witze der Gruppe</h2>
        ${jokes.length ? `<ol class="list">${jokes.map((j, i) => cardHtml(j, i + 1, "")).join("")}</ol>` : `<p class="empty">Noch keine Witze in diesem Zeitraum.</p>`}
      </section>
      <section class="panel grp-invite"><h2>Leute einladen</h2>
        <p class="muted small">Einladungscode <b class="grp-code">${g.code}</b> oder Link teilen:</p>
        <input type="text" readonly value="${esc(url)}" aria-label="Einladungslink">
        <div class="row"><button class="btn" data-group-copy="${esc(url)}">Link kopieren</button><a class="btn ghost" href="https://wa.me/?text=${encodeURIComponent(invite)}" target="_blank" rel="noopener">Per WhatsApp</a><button class="btn ghost" data-group-qr>QR-Code</button></div>
        <div class="grp-qr" id="groupQr" hidden>${qrSvg(url)}<span>Zum Aushängen: scannen und beitreten</span></div>
      </section>
      ${g.is_owner ? `<details class="panel grp-admin"><summary>Gruppe verwalten</summary>
        <form class="form" data-group-manage="rename"><label>Neuer Name<input type="text" name="v" maxlength="40" value="${esc(g.name)}"></label><button class="btn ghost">Umbenennen</button></form>
        <form class="form" data-group-manage="remove"><label>Mitglied entfernen (Benutzername)<input type="text" name="v" maxlength="24" placeholder="@name"></label><button class="btn ghost">Entfernen</button></form>
        <p><a class="btn ghost" href="#/bildschirm?g=${g.code}">Bildschirm-Link für diese Gruppe</a></p>
        <p><button class="btn danger" data-group-delete="${g.code}">Gruppe löschen</button></p>
      </details>` : g.is_member ? `<p class="small on-y"><button class="link" data-group-leave="${g.code}">Gruppe verlassen</button></p>` : ""}
    </div>`;
  }
  async function groupAction(fn, args, okMsg, then) {
    try { const r = await rpc(fn, args); if (okMsg) toast(okMsg); if (then) then(r); else render(); }
    catch (e) { toast(errorText(e)); }
  }
  function groupJoin(code) {
    if (!AUTH) { openAuth("signup", "Zum Beitreten brauchst du ein Konto. Danach bist du sofort dabei.", () => groupJoin(code)); return; }
    groupAction("join_group", { p_code: code }, null, (name) => { toast(`Willkommen in „${name}“!`); const c = code.toUpperCase(); if (location.hash === "#/gruppe/" + c) render(); else location.hash = "#/gruppe/" + c; });
  }
  async function adminGroupsHtml() {
    const rows = API.adminGroups ? await API.adminGroups(AK()).catch(() => []) : [];
    return `<section class="panel"><h2>Gruppen (${rows.length})</h2>${rows.length ? `<ul class="mod-list">${rows.map((g) => `<li><b><a href="#/gruppe/${g.code}">${esc(g.name)}</a></b>
      <span class="muted small">${g.code} · ${fmt(g.members)} Mitglieder · von @${esc(g.owner_name || "?")} · ${new Date(g.created_at).toLocaleDateString("de-DE")}</span>
      <div class="row"><button class="btn danger" data-admin-group-del="${g.code}">Löschen</button></div></li>`).join("")}</ul>` : '<p class="muted small">Noch keine Gruppen.</p>'}</section>`;
  }

  /* ───────── Bildschirm-Modus (z. B. für Fernseher im Studio) ───────── */
  // Einstellungen aus dem Link: k=Kategorien, s=Sponsor, f=hoch|quer, dreh=r|l (gedreht montiert),
  // bg/ac/card=Farben (Hex ohne #), n=Firmenname, t=Sekunden pro Folie, live=1|2 (Live-Duell im Wechsel | nur), g=Gruppen-Code
  const HEX6 = (v) => (/^[0-9a-f]{6}$/i.test(v || "") ? "#" + v.toLowerCase() : null);
  function tvOpts(q) {
    const get = (k) => (q.get(k) || "").trim();
    return {
      cats: get("k").split(",").filter((c) => c in CATS), sponsor: Number(get("s")) || null,
      format: ["hoch", "quer"].includes(get("f")) ? get("f") : null, rot: ["l", "r"].includes(get("dreh")) ? get("dreh") : null,
      bg: HEX6(get("bg")), ac: HEX6(get("ac")), card: HEX6(get("card")),
      name: get("n").slice(0, 40), sec: Math.min(60, Math.max(6, Number(get("t")) || 12)),
      live: ["1", "2"].includes(get("live")) ? get("live") : null, mot: get("mot") === "1", group: get("g").replace(/[^0-9a-z]/gi, "").slice(0, 6).toUpperCase() || null,
      preview: get("vorschau") === "1",
    };
  }
  const rgb = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
  const lum = (h) => { const c = rgb(h).map((v) => v / 255).map((v) => (v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4)); return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]; };
  const contrast = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05); };
  const mixHex = (a, b, t) => "#" + rgb(a).map((v, i) => Math.round(v * (1 - t) + rgb(b)[i] * t).toString(16).padStart(2, "0")).join("");
  const bestOn = (bg) => (contrast("#111111", bg) >= contrast("#ffffff", bg) ? "#111111" : "#ffffff");
  // Farben als CSS-Variablen; Schrift wird automatisch dunkel/hell, wenn die Akzentfarbe schlecht lesbar wäre
  function tvTheme(o) {
    if (!o.bg && !o.ac && !o.card) return "";
    const bg = o.bg || "#ffc928", ac = o.ac || "#15172a", card = o.card || "#ffffff";
    const tx = contrast(ac, bg) >= 3 ? ac : bestOn(bg), ctx = contrast(ac, card) >= 4.5 ? ac : bestOn(card);
    return `--yellow:${bg};--ink:${ac};--paper:${card};--tv-tx:${tx};--tv-ctx:${ctx};--muted-on-yellow:${mixHex(tx, bg, 0.25)}`;
  }
  // Motivationssprüche für Bildschirme in Studios (Option „mot=1“), bewusst positiv und ohne Diät- oder Körperdruck
  const MOTIVATION = [
    "Jeder Satz zählt. Auch der letzte.", "Der schwerste Teil des Trainings ist die Tür zum Studio. Den hast du schon geschafft.",
    "Kleine Schritte sind auch Schritte.", "Du musst nicht perfekt sein. Du musst nur anfangen.", "Stark ist, wer weitermacht, auch wenn es keiner sieht.",
    "Dein einziger Gegner ist dein Ich von gestern.", "Heute trainieren, morgen stolz sein.", "Muskelkater ist der Beweis, dass du gestern da warst.",
    "Langsam ist auch eine Geschwindigkeit.", "Kein Training bereut man. Nur das, das man ausgelassen hat.", "Jeder Profi war mal Anfänger.",
    "Atmen. Wasser trinken. Weiter geht's.", "Der Körper schafft mehr, als der Kopf glaubt.", "Fortschritt schlägt Perfektion.",
    "Du bist heute näher dran als gestern.", "Motivation bringt dich hin. Gewohnheit hält dich dran.", "Gute Laune ist auch ein Muskel. Trainier ihn.",
    "Lachen ist das beste Workout fürs Gesicht.", "Heute ist ein guter Tag für einen neuen Rekord. Oder wenigstens fürs Dabeisein.",
    "Wer lacht, hält länger durch.", "Sei stolz auf jede Wiederholung.", "Erholung gehört zum Training. Schlaf heute gut.",
    "Dein Körper hört alles, was dein Kopf sagt. Sag was Nettes.", "Stärker werden heißt: einmal öfter aufstehen als hinfallen.",
    "Vergleich dich nicht. Verbessere dich.", "Pause machen ist erlaubt. Aufgeben nicht.", "Genau da, wo es anstrengend wird, wächst du.",
    "Du bist hier. Das ist schon mehr als die Hälfte.", "Ein Training ist immer besser als kein Training.", "Schritt für Schritt. Satz für Satz. Tag für Tag.",
  ];
  const TV = { timer: null, refresh: null, poll: null, clock: null, reveal: null, slides: [], i: 0, opt: {}, active: false, gen: 0, live: null, revealed: false };
  function stopTv() {
    TV.active = false; TV.gen++; TV.live = null;
    clearTimeout(TV.timer); clearInterval(TV.refresh); clearInterval(TV.poll); clearInterval(TV.clock); clearTimeout(TV.reveal);
    TV.timer = TV.refresh = TV.poll = TV.clock = TV.reveal = null;
  }
  async function loadTv(opt) {
    const safe = (p, d) => p.catch(() => d);
    const cats = (opt && opt.cats) || [], grp = opt && opt.group && LIVE ? opt.group : null;
    const [daily, todayAll, battle, brand, quiz, group, gJokes, gMembers] = await Promise.all([safe(API.daily(1), []), safe(API.ranking("day", null, cats.length ? 60 : 6, 0), []), null,
      opt && opt.sponsor ? safe(API.sponsor(opt.sponsor), null) : opt && opt.name ? null : loadSponsors().then((x) => x.tv || null),
      [],
      grp ? safe(rpc("get_group", { p_code: grp }).then((x) => x[0] || null), null) : null,
      grp ? safe(rpc("group_ranking", { p_device: DEVICE, p_code: grp, p_range: "week", p_limit: 5 }).then((x) => x.map(fromRow)), []) : [],
      grp ? safe(rpc("group_members_ranking", { p_code: grp, p_range: "month" }), []) : []]);
    let today = cats.length ? todayAll.filter((j) => cats.includes(j.cat)) : todayAll;
    if (cats.length && today.length < 3) today = (await safe(API.ranking("week", null, 80, 0), [])).filter((j) => cats.includes(j.cat));
    TV.brand = brand || (opt && opt.name ? { name: opt.name } : null);
    TV.group = group;
    let best = battle ? (await safe(API.battleEntries(battle.id), []))[0] : null;
    const slides = [];
    if (opt && opt.live === "2") { TV.slides = [{ live: true }]; return; }
    if (group) {
      const top = gMembers.find((m) => m.jokes > 0);
      if (top) slides.push({ k: `🏆 Witzigstes Mitglied im ${new Date().toLocaleDateString("de-DE", { month: "long" })}`, t: `@${top.username}\n${fmt(top.up_count)} Likes mit ${top.jokes} ${top.jokes === 1 ? "Witz" : "Witzen"}`, m: group.name });
      gJokes.forEach((j, i) => slides.push({ k: `${group.name} · Platz ${i + 1} der Woche`, t: j.text, m: `@${j.author} · ${fmt(j.up)} Likes` }));
    }
    if (daily[0] && (!cats.length || cats.includes(daily[0].cat))) slides.push({ k: "👑 Witz des Tages · " + fmtDay(daily[0].day), t: daily[0].text, m: "@" + daily[0].author });
    today.slice(0, group ? 3 : cats.length ? 8 : 5).forEach((j, i) => slides.push({ k: cats.length ? CATS[j.cat] : `Heute auf Platz ${i + 1}`, t: j.text, m: `@${j.author} · ${fmt(j.up)} Likes` }));
    if (quiz[0]) slides.splice(Math.min(2, slides.length), 0, { k: "🤔 Errate die Pointe", quiz: quizRow(quiz[0]), t: quiz[0].setup, m: "Auflösung gleich …" });
    if (battle) slides.push({ k: "🥊 Pointen-Battle von heute", t: battle.setup + (best ? "\n" + best.text : "\n… und deine Pointe?"), m: best ? "Führt gerade: @" + best.author : "Schreib die beste Pointe!" });
    if (opt && opt.mot) {   // nach jeder zweiten Folie ein Motivationsspruch
      const pool = MOTIVATION.slice().sort(() => Math.random() - 0.5);
      for (let i = 2, n = 0; i <= slides.length; i += 3, n++) slides.splice(i, 0, { k: "💪 Motivation", t: pool[n % pool.length], m: "", mot: true });
    }
    if (opt && opt.live === "1") slides.push({ live: true });
    else slides.push({ k: "Mach mit!", t: "Bewerte die Witze von heute und entscheide, wer Witz des Tages wird.", m: "lach-werk.de", qr: true });
    TV.slides = slides;
  }
  // Größe, Seitenverhältnis und Drehung der Bildschirm-Fläche berechnen
  function tvBox(o) {
    const W = window.innerWidth, H = window.innerHeight, rot = o.rot;
    let w = rot ? H : W, h = rot ? W : H;              // Fläche aus Sicht des Inhalts
    const fmt = o.format || (h > w ? "hoch" : "quer");
    if (o.format) { const r = fmt === "hoch" ? 9 / 16 : 16 / 9; if (w / h > r) w = h * r; else h = w / r; }
    const fixed = !!(o.format || rot);
    const style = fixed ? `width:${w}px;height:${h}px;left:${(W - w) / 2}px;top:${(H - h) / 2}px;--vh:${h / 100}px;--vw:${w / 100}px;` + (rot ? `transform:rotate(${rot === "r" ? -90 : 90}deg);` : "") : "";
    return { fmt, fixed, style };
  }
  const tvBrandHtml = () => (TV.brand ? `<span class="tv-brand">${TV.brand.logo ? `<img src="${TV.brand.logo}" alt="">` : ""}<span>präsentiert von <b>${esc(TV.brand.name)}</b></span></span>` : "");
  function tvFrame(inner, extraCls) {
    const box = tvBox(TV.opt), theme = tvTheme(TV.opt);
    // Rand außerhalb der Bildschirm-Fläche in der Hintergrundfarbe (statt Lachwerk-Gelb)
    const page = theme ? TV.opt.bg || "#ffc928" : "";
    document.body.style.background = document.documentElement.style.background = page;
    $("#main").innerHTML = `<div class="tv ${box.fmt}${box.fixed ? " fix" : ""}${extraCls || ""}" style="${theme};${box.style}" title="Tippen für Vollbild">${inner}</div>`;
  }
  const tvDots = () => { const real = TV.slides.filter((x) => !x.live); return real.length > 1 ? `<div class="tv-dots">${real.map((x) => `<i${x === TV.slides[TV.i % TV.slides.length] ? ' class="on"' : ""}></i>`).join("")}</div>` : ""; };
  function drawTv() {
    const s = TV.slides[TV.i % TV.slides.length]; if (!s) return;
    if (s.live) { drawLiveTv(); return; }
    const len = s.t.length, size = len > 160 ? "s" : len > 90 ? "m" : "l";
    const quiz = s.quiz ? `<div class="tv-quiz">${s.quiz.options.map((o, i) => `<span class="${i + 1 === s.quiz.correct ? "ok" : "no"}"><b>${"ABC"[i]}</b>${esc(o)}</span>`).join("")}</div>` : "";
    tvFrame(`<div class="tv-top"><span class="logo">Lach<span>werk</span>${seasonBadge()}</span><span class="tv-k">${esc(s.k)}</span></div>
      <div class="tv-mid${s.quiz ? " has-quiz" : ""}"><p class="tv-t tv-${s.qr || s.quiz ? "m" : size}${s.mot ? " tv-mot" : ""}">${esc(s.t)}</p>${quiz}</div>
      <div class="tv-bot"><div class="tv-left"><span class="tv-m">${esc(s.quiz && TV.revealed ? `Witz von @${s.quiz.author}` : s.m)}</span>${tvBrandHtml()}</div>
        <div class="tv-qr"><img src="qr.svg" alt="QR-Code zu lach-werk.de"><span>${s.quiz ? "Mehr Quiz: QR scannen" : "Jetzt mitbewerten"}</span></div></div>
      ${tvDots()}`, s.quiz && TV.revealed ? " reveal" : "");
  }
  // Ablauf: jede Folie bekommt ihre Zeit, Quiz-Folien etwas mehr, Live-Duelle laufen bis zum Rundenende
  function tvShow() {
    clearTimeout(TV.timer); clearInterval(TV.poll); clearInterval(TV.clock); clearTimeout(TV.reveal);
    if (!TV.active) return;
    const s = TV.slides[TV.i % TV.slides.length]; if (!s) return;
    TV.revealed = false; TV.live = null;
    if (s.live) { tvLive(); return; }
    drawTv();
    let ms = TV.opt.sec * 1000;
    if (s.quiz) { ms = Math.round(ms * 1.7); TV.reveal = setTimeout(() => { TV.revealed = true; drawTv(); }, Math.round(ms * 0.6)); }
    TV.timer = setTimeout(() => { TV.i++; tvShow(); }, ms);
  }
  const liveUrl = () => baseUrl() + "l/" + TV.code;
  async function tvLive() {
    const gen = ++TV.gen;
    if (TV.opt.preview || !LIVE || !TV.code) {   // Vorschau: Beispielrunde ohne Datenbank
      const pool = await API.ranking("week", null, 6, 0).catch(() => []);
      if (gen !== TV.gen) return;
      const [a, b] = pool;
      TV.live = { id: 0, a_text: a ? a.text : "Witz A", b_text: b ? b.text : "Witz B", a_votes: 7, b_votes: 5, ends_at: new Date(Date.now() + 45000).toISOString(), finished: false };
      TV.skew = 0; drawLiveTv();
      TV.clock = setInterval(updateLiveTv, 1000);
      TV.timer = setTimeout(() => { TV.i++; tvShow(); }, TV.slides.length > 1 ? TV.opt.sec * 1000 : 3600000);
      return;
    }
    const get = (start) => rpc("live_round", { p_screen: TV.code, p_device: DEVICE, p_start: start, p_cats: TV.opt.cats.length ? TV.opt.cats : null }).then((x) => x[0] || null);
    const norm = (r) => (r ? { ...r, a_votes: Number(r.a_votes), b_votes: Number(r.b_votes) } : r);
    let r = null; try { r = norm(await get(true)); } catch (e) { r = null; }
    if (gen !== TV.gen) return;
    if (!r) { TV.timer = setTimeout(() => { TV.i++; tvShow(); }, TV.slides.length > 1 ? 1000 : 15000); return; }
    TV.live = r; TV.skew = Date.now() - new Date(r.server_now).getTime(); TV.liveDone = false;
    drawLiveTv();
    const finish = () => {
      if (TV.liveDone) return; TV.liveDone = true;
      clearInterval(TV.poll); clearInterval(TV.clock); TV.live.finished = true; drawLiveTv();
      TV.timer = setTimeout(() => { TV.i++; tvShow(); }, 9000);
    };
    if (r.finished) { finish(); return; }
    TV.clock = setInterval(() => { updateLiveTv(); if (lvLeftTv() <= 0) setTimeout(async () => { try { const x = norm(await get(false)); if (gen === TV.gen && x && x.id === TV.live.id) TV.live = x; } catch (e) { /* letzter Stand */ } if (gen === TV.gen) finish(); }, 1200); }, 1000);
    TV.poll = setInterval(async () => {
      try { const x = norm(await get(false)); if (gen !== TV.gen || !x || x.id !== TV.live.id) return; TV.live = x; if (x.finished) finish(); else updateLiveTv(); } catch (e) { /* nächster Versuch */ }
    }, 2500);
  }
  const lvLeftTv = () => (TV.live ? Math.max(0, Math.ceil((new Date(TV.live.ends_at).getTime() - (Date.now() - (TV.skew || 0))) / 1000)) : 0);
  function drawLiveTv() {
    const r = TV.live; if (!r) return;
    const n = r.a_votes + r.b_votes, pa = n ? Math.round((r.a_votes / n) * 100) : 50, pb = n ? 100 - pa : 50;
    const win = r.finished ? (r.a_votes > r.b_votes ? 1 : r.b_votes > r.a_votes ? 2 : 0) : 0;
    const size = (t) => (t.length > 150 ? "s" : t.length > 80 ? "m" : "l");
    const card = (k, t, p) => `<div class="lv-c${win === k ? " win" : ""}${win && win !== k ? " lose" : ""}"><b class="lv-ab">${win === k ? "🏆" : "AB"[k - 1]}</b><p class="lv-t lv-${size(t)}">${esc(t)}</p>
      <div class="lv-bar"><i id="tvBar${k}" style="width:${n ? p : 0}%"></i></div><span class="lv-p" id="tvPct${k}">${n ? p + " %" : "–"}</span></div>`;
    const info = r.finished ? (win ? `${"AB"[win - 1]} gewinnt mit ${win === 1 ? pa : pb} %!` : n ? "Unentschieden!" : "Keine Stimmen. Nächste Runde gleich!") : `Noch ${lvLeftTv()} s · ${fmt(n)} ${n === 1 ? "Stimme" : "Stimmen"}`;
    if (!TV.qrCode || TV.qrFor !== TV.code) { TV.qrCode = TV.code ? qrSvg(liveUrl()) : ""; TV.qrFor = TV.code; }
    tvFrame(`<div class="tv-top"><span class="logo">Lach<span>werk</span>${seasonBadge()}</span><span class="tv-k">⚡ Live-Duell · Welcher ist lustiger?</span></div>
      <div class="lv-pair">${card(1, r.a_text, pa)}${card(2, r.b_text, pb)}</div>
      <div class="tv-bot"><div class="tv-left"><span class="tv-m lv-info" id="tvLvInfo">${esc(info)}</span>${tvBrandHtml()}</div>
        <div class="tv-qr">${TV.qrCode ? `<div class="tv-qrbox">${TV.qrCode}</div>` : `<img src="qr.svg" alt="">`}<span>Handy zücken &amp; abstimmen</span></div></div>`, " tv-live");
  }
  function updateLiveTv() {
    const r = TV.live; if (!r || r.finished) return;
    const n = r.a_votes + r.b_votes, pa = n ? Math.round((r.a_votes / n) * 100) : 0, pb = n ? 100 - pa : 0;
    [[1, pa], [2, pb]].forEach(([k, p]) => { const b = document.getElementById("tvBar" + k), t = document.getElementById("tvPct" + k); if (b) b.style.width = p + "%"; if (t) t.textContent = n ? p + " %" : "–"; });
    const i = document.getElementById("tvLvInfo"); if (i) i.textContent = `Noch ${lvLeftTv()} s · ${fmt(n)} ${n === 1 ? "Stimme" : "Stimmen"}`;
  }
  window.addEventListener("resize", () => { if (TV.active) { if (TV.live) drawLiveTv(); else drawTv(); } });
  async function renderTv(token, r) {
    stopTv();
    $("#main").innerHTML = '<p class="loading">Lade Bildschirm-Modus …</p>';
    let opt = r; TV.code = null;
    if (r.code) {   // Kurzlink: Einstellungen aus der Datenbank holen
      const cfg = LIVE ? await rpc("get_tv_screen", { p_code: r.code }).catch(() => null) : null;
      if (stale(token)) return;
      if (!cfg) { $("#main").innerHTML = `<div class="view"><p class="empty">Den Bildschirm-Code „${esc(r.code)}“ gibt es nicht.<br><a class="btn" href="#/bildschirm" style="margin-top:12px">Neuen Bildschirm-Link erstellen</a></p></div>`; document.body.classList.remove("tv-mode"); return; }
      opt = tvOpts(new URLSearchParams(cfg)); TV.code = r.code;
    } else if (opt.live && LIVE && !opt.preview) {
      // Live-Duell braucht einen Bildschirm-Code: gleiche Einstellungen ergeben denselben Code
      TV.code = await rpc("save_tv_screen", { p_config: r.raw || {} }).catch(() => null);
      if (stale(token)) return;
    }
    TV.opt = opt;
    await loadTv(opt);
    if (stale(token)) return;
    TV.i = 0; TV.active = true; tvShow();
    TV.refresh = setInterval(() => loadTv(opt).catch(() => {}), 10 * 60000);
  }

  /* ───────── Bildschirm-Link gestalten (#/bildschirm) ───────── */
  const TV_PRESETS = [["Lachwerk", "ffc928", "15172a", "ffffff"], ["Nacht", "15172a", "ffc928", "ffffff"], ["Weiß & Blau", "f4f6fb", "1d4ed8", "ffffff"],
    ["Rot", "d62828", "ffffff", "ffffff"], ["Grün", "1f7a4d", "ffffff", "ffffff"], ["Schwarz & Weiß", "111111", "ffffff", "ffffff"], ["Orange", "ff7a00", "1a1a1a", "ffffff"], ["Türkis", "0fb5ae", "0b2540", "ffffff"]];
  const SCR = { cfg: null, timer: null };
  function screenCfg() {
    const c = SCR.cfg, out = {};
    out.f = c.f; if (c.f === "hoch" && c.dreh) out.dreh = c.dreh;
    if (c.bg !== "ffc928" || c.ac !== "15172a" || c.card !== "ffffff") { out.bg = c.bg; out.ac = c.ac; out.card = c.card; }
    if (c.k.length) out.k = c.k.join(","); if (c.n) out.n = c.n.slice(0, 40); if (c.s) out.s = String(c.s); if (c.t !== 12) out.t = String(c.t);
    if (c.live) out.live = c.live; if (c.g) out.g = c.g; if (c.mot) out.mot = "1";
    return out;
  }
  const tvUrl = (cfg) => location.origin + location.pathname + "#/tv" + (Object.keys(cfg).length ? "?" + new URLSearchParams(cfg).toString() : "");
  async function renderScreen(token, r) {
    const q = r.q, o = tvOpts(q);
    SCR.cfg = { f: o.format || "quer", dreh: o.rot || "", bg: (o.bg || "#ffc928").slice(1), ac: (o.ac || "#15172a").slice(1), card: (o.card || "#ffffff").slice(1), k: o.cats, n: o.name, s: o.sponsor, t: o.sec, live: o.live || "", g: o.group || "", mot: o.mot };
    const c = SCR.cfg, sp = c.s && LIVE ? await API.sponsor(c.s).catch(() => null) : null;
    if (stale(token)) return;
    const color = (id, label, v) => `<label class="scr-color">${label}<span><input type="color" id="${id}C" value="#${v}"><input type="text" id="${id}" value="#${v}" maxlength="7" spellcheck="false" autocomplete="off" inputmode="text"></span></label>`;
    $("#main").innerHTML = `<div class="view scr">
      <div><h1>Bildschirm-Link</h1><p class="muted">Lachwerk für Fernseher, Stelen und Tablets: Witz des Tages und die besten Witze von heute im Wechsel, auf Wunsch mit Live-Duell, und mit QR-Code zum Mitmachen. Einmal gestalten, Link am Bildschirm öffnen, fertig. Er aktualisiert sich von selbst.</p></div>
      <div class="scr-grid">
        <section class="panel form scr-form">
          <fieldset class="scr-fmt"><legend>Format</legend>
            <label><input type="radio" name="scrF" value="quer" ${c.f === "quer" ? "checked" : ""}><span><i class="scr-ic q"></i><b>Querformat 16:9</b><small>Fernseher, Monitor</small></span></label>
            <label><input type="radio" name="scrF" value="hoch" ${c.f === "hoch" ? "checked" : ""}><span><i class="scr-ic h"></i><b>Hochformat 9:16</b><small>Stele, hochkant montierter Fernseher</small></span></label>
          </fieldset>
          <label id="scrRotBox" ${c.f === "hoch" ? "" : "hidden"}>Wie ist der Bildschirm montiert?<select id="scrRot">
            <option value="">Gerät zeigt selbst hochkant an (Stele, Tablet)</option>
            <option value="r" ${c.dreh === "r" ? "selected" : ""}>Fernseher um 90° nach rechts gedreht</option>
            <option value="l" ${c.dreh === "l" ? "selected" : ""}>Fernseher um 90° nach links gedreht</option></select>
            <small class="muted">Steht das Bild auf dem gedrehten Fernseher quer, einfach die andere Richtung wählen.</small></label>
          <div class="scr-sec"><b>Farben (Firmen-CI)</b>
            <div class="chips static scr-presets">${TV_PRESETS.map(([n, bg, ac, card]) => `<button type="button" class="chip scr-pre" data-scr-pre="${bg},${ac},${card}" title="${esc(n)}"><i style="background:#${bg};border-color:#${ac}"></i>${esc(n)}</button>`).join("")}</div>
            <div class="scr-colors">${color("scrBg", "Hintergrund", c.bg)}${color("scrAc", "Akzent & Schrift", c.ac)}${color("scrCard", "Witz-Karte", c.card)}</div>
            <p class="small muted">Hex-Codes aus dem Corporate Design einfach eintragen, z. B. #E30613.</p>
            <p class="small scr-warn" id="scrWarn" hidden></p></div>
          <label>Firmenname (optional)<input type="text" id="scrName" maxlength="40" value="${esc(c.n)}" placeholder="z. B. Bäckerei Sonnenschein" autocomplete="off"><small class="muted">Erscheint unten als „präsentiert von …“.</small></label>
          ${sp ? `<p class="small">Mit Branding von Sponsor <b>${esc(sp.name)}</b>${sp.logo ? ` <img class="sp-mini" src="${sp.logo}" alt="">` : ""}.</p>` : ""}
          <div class="scr-sec"><b>Nur bestimmte Kategorien (optional)</b>
            <div class="chips static">${Object.entries(CATS).map(([k, l]) => `<label class="chip-check"><input type="checkbox" class="scrCat" value="${k}" ${c.k.includes(k) ? "checked" : ""}> ${l}</label>`).join("")}</div></div>
          <label class="check scr-check"><input type="checkbox" id="scrMot" ${c.mot ? "checked" : ""}> <span><b>💪 Motivationssprüche zwischendurch</b><br><small class="muted">Nach jeder zweiten Folie ein kurzer, positiver Spruch, z. B. „Jeder Satz zählt. Auch der letzte.“ Ideal fürs Fitnessstudio.</small></span></label>
          <label>⚡ Live-Duell<select id="scrLive">
            <option value="">Aus</option>
            <option value="1" ${c.live === "1" ? "selected" : ""}>Im Wechsel mit den Witzen</option>
            <option value="2" ${c.live === "2" ? "selected" : ""}>Nur Live-Duell</option></select>
            <small class="muted">Zwei Witze treten gegeneinander an. Zuschauer scannen den QR-Code und stimmen per Handy ab, die Balken wachsen live. Ideal für Wartebereiche.</small></label>
          <label>👥 Gruppe (optional)<input type="text" id="scrGroup" maxlength="6" value="${esc(c.g)}" placeholder="Einladungscode, z. B. K7P2QX" autocomplete="off" spellcheck="false" autocapitalize="characters">
            <small class="muted">Zeigt zusätzlich die besten Witze und das witzigste Mitglied eurer <a href="#/gruppen">Gruppe</a>.</small></label>
          <label>Wechsel alle<select id="scrT">${[8, 12, 15, 20, 30].map((t) => `<option value="${t}" ${c.t === t ? "selected" : ""}>${t} Sekunden</option>`).join("")}</select></label>
        </section>
        <section class="scr-side">
          <div class="scr-prev-wrap"><div class="scr-prev ${c.f}" id="scrPrev"><iframe id="scrFrame" title="Vorschau des Bildschirms" tabindex="-1"></iframe></div></div>
          <div class="panel scr-out">
            <b>Dein Link</b>
            <p class="scr-short" id="scrShort" hidden></p>
            <input type="text" id="scrUrl" readonly aria-label="Bildschirm-Link">
            <div class="row"><button class="btn" data-scr-copy>Link kopieren</button><a class="btn ghost" id="scrOpen" target="_blank" rel="noopener">Öffnen</a>${LIVE ? '<button class="btn ghost" data-scr-short>Kurzlink zum Eintippen</button>' : ""}</div>
            <p class="small muted">Tipp: Am Fernseher den Browser öffnen (z. B. Fire-TV-Stick mit „Silk“ oder den Browser des Smart-TV), Link eingeben und einmal auf das Bild tippen bzw. OK drücken für Vollbild. Der Kurzlink ist leichter mit der Fernbedienung einzutippen.</p>
          </div>
        </section>
      </div>
    </div>`;
    updateScreen(true);
  }
  function readScreenForm() {
    const c = SCR.cfg, hex = (id) => { const v = $("#" + id).value.trim().replace(/^#/, ""); return /^[0-9a-f]{6}$/i.test(v) ? v.toLowerCase() : /^[0-9a-f]{3}$/i.test(v) ? v.replace(/./g, "$&$&").toLowerCase() : null; };
    c.f = (document.querySelector('input[name="scrF"]:checked') || {}).value || "quer";
    c.dreh = $("#scrRot").value;
    for (const [id, key] of [["scrBg", "bg"], ["scrAc", "ac"], ["scrCard", "card"]]) { const v = hex(id); if (v) { c[key] = v; $("#" + id + "C").value = "#" + v; } }
    c.k = [...document.querySelectorAll(".scrCat:checked")].map((x) => x.value);
    c.n = $("#scrName").value.trim(); c.t = Number($("#scrT").value) || 12;
    c.mot = $("#scrMot").checked; c.live = $("#scrLive").value; c.g = $("#scrGroup").value.replace(/[^0-9a-z]/gi, "").slice(0, 6).toUpperCase();
  }
  function updateScreen(now) {
    if (!$("#scrUrl")) return;
    readScreenForm();
    const c = SCR.cfg, cfg = screenCfg(), url = tvUrl(cfg);
    $("#scrRotBox").hidden = c.f !== "hoch";
    $("#scrUrl").value = url; $("#scrOpen").href = url;
    $("#scrShort").hidden = true; SCR.short = null;
    $("#scrPrev").className = "scr-prev " + c.f;
    const w = contrast("#" + c.ac, "#" + c.bg) < 3 ? "Akzent und Hintergrund sind sich sehr ähnlich, das Logo und die Rubrik sind dann schlecht lesbar. Die Witze selbst bleiben lesbar." : "";
    $("#scrWarn").textContent = w; $("#scrWarn").hidden = !w;
    // Vorschau ohne Drehung, damit man das Ergebnis aufrecht sieht
    const prev = { ...cfg, vorschau: "1" }; delete prev.dreh;
    clearTimeout(SCR.timer);
    SCR.timer = setTimeout(() => { const f = $("#scrFrame"); if (f) f.src = tvUrl(prev); }, now ? 0 : 500);
  }
  async function screenShortLink() {
    const btn = document.querySelector("[data-scr-short]"); if (btn) btn.disabled = true;
    try {
      const code = await rpc("save_tv_screen", { p_config: screenCfg() });
      const url = location.origin + location.pathname.replace(/[^/]*$/, "") + "tv/" + code;
      SCR.short = url;
      $("#scrShort").innerHTML = `<span>${esc(url.replace(/^https?:\/\//, ""))}</span><small>Code: <b>${esc(code)}</b></small>`; $("#scrShort").hidden = false;
      $("#scrUrl").value = url; $("#scrOpen").href = url;
      navigator.clipboard && navigator.clipboard.writeText(url).then(() => toast("Kurzlink kopiert."), () => {});
    } catch (e) { toast(errorText(e)); }
    if (btn) btn.disabled = false;
  }


  /* ───────── Anonyme Besucherzählung (ohne Cookies, ohne Geräte-Kennung) ───────── */
  // Gezählt wird nur „Bereich X wurde aufgerufen“ plus grobe Herkunft und Gerätetyp. Eindeutige Besucher
  // erkennt der Server über einen täglich wechselnden Hash; im Browser wird dafür nichts gespeichert.
  const VISIT = (() => {
    let src = "direkt";
    try {
      const q = new URLSearchParams(location.search), ref = document.referrer ? new URL(document.referrer).hostname : "";
      if (q.has("qr")) src = "qr";
      else if (q.get("s") === "wa" || /whatsapp|wa\.me/.test(ref)) src = "whatsapp";
      else if (/google\./.test(ref)) src = "google";
      else if (/facebook\.|fb\./.test(ref)) src = "facebook";
      else if (/instagram\./.test(ref)) src = "instagram";
      else if (ref && ref !== location.hostname) src = "andere";
      // Herkunfts-Merkmal aus der Adresse entfernen, damit es beim Teilen nicht weitergegeben wird
      if (q.has("qr") || q.has("s")) { q.delete("qr"); q.delete("s"); history.replaceState(null, "", location.pathname + (q.toString() ? "?" + q : "") + location.hash); }
    } catch (e) { /* egal */ }
    const ua = navigator.userAgent || "";
    const device = /iPad|Tablet|PlayBook|Silk/i.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? "tablet" : /Mobi|Android|iPhone|iPod/i.test(ua) ? "mobil" : "computer";
    const off = navigator.globalPrivacyControl === true || navigator.doNotTrack === "1";
    return { src, device, off, last: null };
  })();
  function trackView(r) {
    if (!LIVE || VISIT.off || r.view === "admin" || S.adminKey || isRoleAdmin() || r.preview || (r.view === "tv" && /vorschau=1/.test(location.hash))) return;
    const key = r.view === "list" ? "list:" + (S.range === "new" ? "new" : "") : location.hash.split("?")[0];
    if (key === VISIT.last) return;
    VISIT.last = key;
    const route = r.view === "list" && S.range === "new" ? "new" : r.view;
    rpc("track_view", { p_route: route, p_source: VISIT.src, p_device: VISIT.device }).catch(() => {});
  }

  /* ───────── Push-Nachrichten ───────── */
  const PUSH_OK = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  const FN_URL = LIVE ? CFG.supabaseUrl.replace(/\/$/, "") + "/functions/v1/push" : null;
  const PUSH_TOPICS = [["daily", "👑 Witz des Tages (jeden Abend um 20 Uhr)"], ["mine", "🏆 Erfolge meiner Witze (Top 3 von heute, Likes, Witz des Tages)"]];
  function b64u(s) { const p = "=".repeat((4 - (s.length % 4)) % 4); const b = atob((s + p).replace(/-/g, "+").replace(/_/g, "/")); return Uint8Array.from(b, (c) => c.charCodeAt(0)); }
  const callFn = (body) => fetch(FN_URL, { method: "POST", headers: { "Content-Type": "application/json", apikey: CFG.supabaseAnonKey }, body: JSON.stringify(body) }).then((r) => r.json());
  async function pushSub() { if (!PUSH_OK || !LIVE) return null; const reg = await navigator.serviceWorker.ready; return reg.pushManager.getSubscription(); }
  async function pushEnable(topics) {
    const perm = await Notification.requestPermission();
    if (perm !== "granted") { const e = new Error("push_denied"); e.code = "push_denied"; throw e; }
    let key = await rpc("get_push_key", {});
    if (!key) key = (await callFn({ type: "setup" })).publicKey;
    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64u(key) });
    await rpc("push_subscribe", { p_device: DEVICE, p_sub: sub.toJSON(), p_topics: topics });
    store.set("push_topics", topics);
  }
  async function pushDisable() { const sub = await pushSub(); if (sub) { await rpc("push_unsubscribe", { p_endpoint: sub.endpoint }).catch(() => {}); await sub.unsubscribe(); } }
  async function drawPushBox() {
    const box = $("#pushBox"); if (!box) return;
    if (!LIVE) { box.innerHTML = '<p class="muted small on-y">Im Demo-Modus gibt es keine Benachrichtigungen.</p>'; return; }
    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
    if (!PUSH_OK) { box.innerHTML = `<p class="muted small on-y">${ios && !isStandalone() ? "Auf dem iPhone gehen Benachrichtigungen nur, wenn Lachwerk installiert ist: in Safari auf „Teilen“ → „Zum Home-Bildschirm“, dann die App öffnen und hier einschalten." : "Dein Browser unterstützt leider keine Benachrichtigungen."}</p>`; return; }
    if (Notification.permission === "denied") { box.innerHTML = '<p class="muted small on-y">Du hast Benachrichtigungen für Lachwerk blockiert. Du kannst sie in den Einstellungen deines Browsers bzw. Handys wieder erlauben.</p>'; return; }
    const sub = await pushSub().catch(() => null);
    const topics = store.get("push_topics", ["daily", "mine"]);
    box.innerHTML = `<div class="install push">
      <strong>${sub ? "🔔 Benachrichtigungen sind an" : "🔔 Nichts mehr verpassen"}</strong>
      <div class="push-topics">${PUSH_TOPICS.map(([k, l]) => `<label class="check"><input type="checkbox" value="${k}"${topics.includes(k) ? " checked" : ""}> <span>${l}</span></label>`).join("")}</div>
      ${!AUTH ? '<span class="small">„Erfolge meiner Witze“ klappt nur, wenn du angemeldet bist.</span>' : ""}
      <div class="row">${sub ? '<button class="btn ghost" data-push-save>Speichern</button><button class="btn ghost" data-push-test>Test senden</button><button class="btn ghost" data-push-off>Ausschalten</button>' : '<button class="btn" data-push-on>Benachrichtigungen einschalten</button>'}</div>
    </div>`;
  }
  async function pushAction(kind, btn) {
    const topics = [...document.querySelectorAll("#pushBox input:checked")].map((x) => x.value);
    btn.disabled = true;
    try {
      if (kind === "on" || kind === "save") { if (!topics.length) { toast("Wähle mindestens ein Thema."); return; } await pushEnable(topics); toast(kind === "on" ? "Benachrichtigungen sind an." : "Gespeichert."); }
      else if (kind === "off") { await pushDisable(); toast("Benachrichtigungen sind aus."); }
      else if (kind === "test") { const sub = await pushSub(); const r = await callFn({ type: "test", endpoint: sub.endpoint }); toast(r.sent && r.sent.ok ? "Test verschickt. Gleich sollte er ankommen." : "Der Test hat nicht geklappt."); }
    } catch (e) { toast(e.code === "push_denied" ? "Du hast die Benachrichtigungen nicht erlaubt." : errorText(e)); }
    finally { btn.disabled = false; drawPushBox(); }
  }

  /* ───────── Suche (#/suche?q=…) ───────── */
  const SR = { timer: null, q: "", seq: 0 };
  const SEARCH_TIPS = ["Chef", "Kaffee", "Fritzchen", "Montag", "Arzt", "Katze", "Ehe", "Computer"];
  async function renderSearch(token, q) {
    SR.q = q || "";
    $("#main").innerHTML = `<div class="view search">
      <div><h1>Witze suchen</h1><p class="muted">Finde Witze zu deinem Thema, zum Beispiel für die nächste Rede oder die Kaffeepause.</p></div>
      <form class="search-bar" id="searchForm" role="search"><input type="search" id="searchQ" value="${esc(SR.q)}" placeholder="Stichwort, z. B. Chef oder Kaffee" maxlength="60" autocomplete="off" enterkeyhint="search" aria-label="Suchbegriff"><button class="btn">Suchen</button></form>
      <div class="chips static search-tips">${SEARCH_TIPS.map((t) => `<button class="chip" data-search-tip="${t}">${t}</button>`).join("")}</div>
      <div id="searchOut"></div>
    </div>`;
    if (!SR.q && matchMedia("(pointer: fine)").matches) $("#searchQ").focus();
    await runSearch(token);
  }
  async function runSearch(token) {
    const out = $("#searchOut"); if (!out) return;
    const q = SR.q.trim(), seq = ++SR.seq;
    if (q.replace(/[^0-9a-zäöüß]/gi, "").length < 2) { out.innerHTML = q ? `<p class="muted on-y">Bitte mindestens 2 Buchstaben eingeben.</p>` : ""; return; }
    out.innerHTML = '<p class="loading">Suche …</p>';
    let rows = [];
    try { rows = LIVE ? (await rpc("search_jokes", { p_device: DEVICE, p_query: q, p_category: null, p_limit: 40, p_offset: 0 })).map(fromRow)
      : (await API.ranking("all", null, 400, 0).catch(() => [])).concat(await API.ranking("week", null, 400, 0).catch(() => []))
          .filter((j, i, a) => a.findIndex((x) => x.id === j.id) === i && q.toLowerCase().split(/\s+/).every((t) => j.text.toLowerCase().includes(t))); }
    catch (e) { if (seq === SR.seq) out.innerHTML = `<p class="empty">${esc(errorText(e))}</p>`; return; }
    if (seq !== SR.seq || (token != null && stale(token))) return;
    rows = rows.filter((j) => !S.hiddenForMe.has(j.id));
    S.searchRows = rows;
    out.innerHTML = rows.length
      ? `<div class="meta-row"><span>Treffer für „${esc(q)}“, die besten zuerst</span><span>${rows.length === 40 ? "40+" : rows.length} ${rows.length === 1 ? "Witz" : "Witze"}</span></div>
         <ol class="list">${rows.map((j, i) => cardHtml(j, i + 1, "")).join("")}</ol>`
      : `<p class="empty">Zu „${esc(q)}“ gibt es noch keinen Witz. Kennst du einen? <button class="link" data-post-open>Jetzt posten</button></p>`;
    loadReactions(rows);
  }
  function searchInput(v) {
    SR.q = v; clearTimeout(SR.timer);
    SR.timer = setTimeout(() => { history.replaceState(null, "", "#/suche" + (SR.q.trim() ? "?q=" + encodeURIComponent(SR.q.trim()) : "")); runSearch(null); }, 350);
  }

  /* ───────── Witz als Grußkarte ───────── */
  const OCCASIONS = [
    ["einfach", "😄", "Ein Witz für dich", "#ffc928"], ["geburtstag", "🎂", "Alles Gute zum Geburtstag", "#ff9eb5"],
    ["morgen", "☀️", "Guten Morgen", "#ffd27a"], ["montag", "☕", "Schönen Montag", "#9fd3ea"],
    ["wochenende", "🎉", "Schönes Wochenende", "#c9b6e4"], ["feierabend", "🍻", "Schönen Feierabend", "#f6b37e"],
    ["besserung", "🍀", "Gute Besserung", "#a7dcb8"], ["danke", "💛", "Danke dir", "#ffe08a"],
  ];
  const GC = { occ: "einfach", to: "", from: "" };
  function cardBoxHtml() {
    return `<section class="gcard" id="gcard" hidden aria-label="Grußkarte">
      <h2>Als Grußkarte verschicken</h2>
      <div class="chips static">${OCCASIONS.map(([k, e, t]) => `<button class="chip" data-card-occ="${k}" aria-pressed="${GC.occ === k}">${e} ${esc(t.replace(/^Alles Gute zum /, "").replace(/^Schönen |^Schönes |^Guten /, ""))}</button>`).join("")}</div>
      <div class="gcard-in"><label>Für<input type="text" id="gcTo" maxlength="24" value="${esc(GC.to)}" placeholder="z. B. Sönke" autocomplete="off"></label>
        <label>Von<input type="text" id="gcFrom" maxlength="24" value="${esc(GC.from)}" placeholder="z. B. Hans" autocomplete="off"></label></div>
      <canvas id="gcCanvas" aria-label="Vorschau der Grußkarte"></canvas>
      <div class="row"><button class="btn" data-card-share>Karte verschicken</button><button class="btn ghost" data-card-close>Schließen</button></div>
      <p class="muted small" id="gcMsg" role="status"></p>
    </section>`;
  }
  function drawCard() {
    const canvas = $("#gcCanvas"), j = S.detail; if (!canvas || !j) return;
    const [, emoji, title, bg] = OCCASIONS.find((o) => o[0] === GC.occ) || OCCASIONS[0];
    const W = 1080, H = 1350, pad = 76, c = canvas.getContext("2d");
    canvas.width = W; canvas.height = H;
    const DISPLAY = getComputedStyle(document.documentElement).getPropertyValue("--f-display");
    const BODY = getComputedStyle(document.documentElement).getPropertyValue("--f-body");
    c.fillStyle = bg; c.fillRect(0, 0, W, H); c.textBaseline = "top";
    // Konfetti-Punkte am Rand
    const dots = ["#15172a", "#ffffff"]; for (let i = 0; i < 36; i++) { const x = (i * 97 + 31) % W, y = (i * 211 + 17) % H; if (y > 330 && y < H - 200 && x > 60 && x < W - 60) continue; c.globalAlpha = 0.18; c.fillStyle = dots[i % 2]; c.beginPath(); c.arc(x, y, 8 + (i % 4) * 4, 0, Math.PI * 2); c.fill(); }
    c.globalAlpha = 1;
    c.font = `110px ${BODY}`; c.fillText(emoji, pad, 70);
    const head = GC.to ? `${title}, ${GC.to}!` : `${title}!`;
    let hs = 78; c.fillStyle = "#15172a";
    for (;;) { c.font = `800 ${hs}px ${DISPLAY}`; if (wrapLines(c, head, W - 2 * pad).length <= 2 || hs <= 46) break; hs -= 4; }
    const hl = wrapLines(c, head, W - 2 * pad); let y = 210; for (const l of hl) { c.fillText(l, pad, y); y += hs * 1.15; }
    const top = y + 40, bottom = H - 170, cp = 56, maxW = W - 2 * pad - 2 * cp;
    let size = 64, lines, lh;
    for (;;) { c.font = `500 ${size}px ${BODY}`; lines = wrapLines(c, j.text, maxW); lh = size * 1.3; if (cp * 2 + lines.length * lh <= bottom - top || size <= 26) break; size -= 2; }
    const ch = cp * 2 + lines.length * lh - (lh - size), cy = top + Math.max(0, (bottom - top - ch) / 2);
    c.fillStyle = "#15172a"; rr(c, pad, cy + 12, W - 2 * pad, ch, 44); c.fill();
    c.fillStyle = "#ffffff"; rr(c, pad, cy, W - 2 * pad, ch, 44); c.fill();
    c.fillStyle = "#15172a"; c.font = `500 ${size}px ${BODY}`; let ty = cy + cp; for (const l of lines) { c.fillText(l, pad + cp, ty); ty += lh; }
    // Fußzeile: Absender links, Lachwerk rechts
    const fy = H - 110;
    if (GC.from) { c.font = `700 40px ${BODY}`; c.fillStyle = "#15172a"; c.fillText("Von " + GC.from, pad, fy); }
    const ls = 40; c.font = `800 ${ls}px ${DISPLAY}`; const lw = c.measureText("Lach").width, ww = c.measureText("werk").width, lx = W - pad - lw - ww - ls * 0.36 - 4;
    c.fillStyle = "#15172a"; c.fillText("Lach", lx, fy); rr(c, lx + lw + 4, fy - ls * 0.12, ww + ls * 0.36, ls * 1.18, ls * 0.18); c.fill();
    c.fillStyle = bg; c.fillText("werk", lx + lw + 4 + ls * 0.18, fy);
    c.fillStyle = "#15172a"; c.font = `500 26px ${BODY}`; const host = location.host || "lach-werk.de"; c.fillText(host, W - pad - c.measureText(host).width, fy + 56);
  }
  async function shareCard() {
    const j = S.detail, msg = $("#gcMsg"), canvas = $("#gcCanvas"); if (!j || !canvas) return;
    const blob = await new Promise((r) => canvas.toBlob(r, "image/png"));
    if (!blob) { msg.textContent = "Die Karte konnte nicht erstellt werden."; return; }
    const file = new File([blob], `lachwerk-grusskarte-${j.id}.png`, { type: "image/png" });
    const text = (GC.to ? `Für ${GC.to}: ` : "") + "Ein Witz für dich 😄 Mehr davon: " + shareUrl(j.id);
    try { if (navigator.canShare && navigator.canShare({ files: [file] })) { await navigator.share({ files: [file], text }); return; } }
    catch (e) { if (e.name === "AbortError") return; }
    const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = file.name; document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 2000);
    msg.textContent = "Karte gespeichert. Jetzt in WhatsApp oder per Mail als Bild verschicken.";
  }

  /* ───────── Erfolge eigener Witze: Benachrichtigung anbieten ───────── */
  async function drawMinePush() {
    const box = $("#minePush"); if (!box) return;
    if (!LIVE || !PUSH_OK || !AUTH || (typeof Notification !== "undefined" && Notification.permission === "denied")) { box.remove(); return; }
    const sub = await pushSub().catch(() => null), topics = store.get("push_topics", []);
    if (sub && topics.includes("mine")) { box.innerHTML = `<p class="small muted">🔔 Du bekommst Bescheid, wenn dieser Witz in die Top 3 kommt oder Likes sammelt.</p>`; return; }
    box.innerHTML = `<div class="install push"><strong>🔔 Wie läuft dein Witz?</strong><span>Wir sagen dir Bescheid, wenn er in die Top 3 von heute kommt oder 10, 25, 50 und 100 Likes knackt.</span><div><button class="btn" data-push-mine>Benachrichtigen</button></div></div>`;
  }
  // Angemeldet und Benachrichtigungen an: Abo einmal pro Sitzung mit dem Konto verknüpfen
  async function syncPushUser() {
    if (!LIVE || !PUSH_OK || !AUTH || session.get("push_synced") === AUTH.username) return;
    try { const sub = await pushSub(); if (!sub) return; await rpc("push_subscribe", { p_device: DEVICE, p_sub: sub.toJSON(), p_topics: store.get("push_topics", ["daily", "mine"]) }); session.set("push_synced", AUTH.username); } catch (e) { /* später erneut */ }
  }

  /* ───────── App installieren (PWA) ───────── */
  let installEvt = null;
  window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); installEvt = e; });
  const isStandalone = () => (window.matchMedia && matchMedia("(display-mode: standalone)").matches) || navigator.standalone === true;
  function installHtml() {
    if (isStandalone()) return "";
    const ios = /iphone|ipad|ipod/i.test(navigator.userAgent);
    return `<div class="install"><strong>Lachwerk als App</strong><span>${ios ? "In Safari auf „Teilen“ und dann „Zum Home-Bildschirm“ tippen." : "Mit einem Tipp auf deinen Startbildschirm, ganz ohne App-Store."}</span>${ios ? "" : `<button class="btn ghost" data-install>App installieren</button>`}</div>`;
  }
  async function doInstall() {
    if (installEvt) { installEvt.prompt(); try { await installEvt.userChoice; } catch (e) { /* egal */ } installEvt = null; return; }
    toast("Öffne das Browser-Menü (⋮) und wähle „App installieren“ bzw. „Zum Startbildschirm“.");
  }

  /* ───────── Moderation ───────── */
  async function renderAdmin(token) {
    if (!S.adminKey && !isRoleAdmin()) {
      $("#main").innerHTML = `<div class="view"><h1>Moderation</h1>
        <form class="form" id="adminForm">
          <label>Admin-Schlüssel<input type="password" id="adminKey" autocomplete="current-password"></label>
          ${LIVE ? "" : `<p class="muted small">Demo-Modus: Der Schlüssel ist <code>${DEMO_ADMIN_KEY}</code>.</p>`}
          <p class="err" id="adminErr"></p>
          <div><button class="btn">Anmelden</button></div>
        </form></div>`;
      return;
    }
    $("#main").innerHTML = '<p class="loading">Lade Moderation …</p>';
    const v = S.adminView;
    let rows, extra;
    try {
      if (v === "uebersicht") extra = await Promise.all([API.adminOverview(S.adminKey), API.adminActivity(S.adminKey), API.adminPushStats(S.adminKey).catch(() => null), API.adminOpenPunch(S.adminKey).catch(() => 0),
        API.adminDashboard(S.adminKey).catch(() => null), API.adminSecurity(S.adminKey).catch(() => null)]);
      else if (v === "nutzer" && S.adminUser) extra = await API.adminUserDetail(S.adminKey, S.adminUser);
      else if (v === "protokoll") extra = await Promise.all([API.adminSecurity(S.adminKey).catch(() => null), API.adminLog(S.adminKey, S.logLimit || 50, 0).catch(() => [])]);
      else if (v === "witze") extra = S.adminRows = await API.adminSearch(S.adminKey, S.adminQ).then((r) => (S.adminQ.offset ? [...(S.adminRowsPrev || []), ...r] : r));
      else if (v === "nutzer") extra = await API.adminUsers2(S.adminKey, S.adminUserQ).catch(() => API.adminUsers(S.adminKey, S.adminUserQ));
      else if (v === "settings") extra = await Promise.all([API.adminOverview(S.adminKey), API.contact().catch(() => null)]);
      else if (v === "sponsoren") extra = await API.adminSponsors(S.adminKey);
      else if (v === "stats") extra = await Promise.all([API.adminTotals(S.adminKey), API.adminStats(S.adminKey, 14), API.adminCatStats(S.adminKey), API.adminTop(S.adminKey).catch(() => []),
        API.adminVisits ? API.adminVisits(AK(), 14).catch(() => []) : [], API.adminVisitBreakdown ? API.adminVisitBreakdown(AK(), 7).catch(() => []) : []]);
      else if (v === "vorrat") extra = await Promise.all([API.adminTotals(S.adminKey), API.adminCatStats(S.adminKey)]);
      else if (v === "challenge") extra = await loadChallenge(true);
      else if (v === "battle") extra = await API.adminBattle(S.adminKey);
      else if (v === "filter") extra = await API.adminWords(S.adminKey);
      else rows = await API.adminList(S.adminKey, v);
    }
    catch (e) { if (e.code === "not_admin") { S.adminKey = null; session.set("admin", null); if (AUTH && AUTH.role) setAuth({ ...AUTH, role: null }); return render(); } throw e; }
    if (stale(token)) return;
    const label = { visible: "Sichtbar", hidden: "Ausgeblendet", removed: "Entfernt" };
    const head = `<div class="row" style="justify-content:space-between;align-items:center"><h1>Moderation</h1>${S.adminKey ? '<button class="link" data-admin-logout>Abmelden</button>' : `<span class="muted small on-y">als Admin @${esc(AUTH.username)}</span>`}</div>
      <div class="tabs admin-tabs" role="tablist">
        ${[["uebersicht", "Übersicht"], ["gemeldet", "Zu prüfen"], ["witze", "Witze"], ["nutzer", "Nutzer"], ["stats", "Statistik"], ["protokoll", "Protokoll"], ["vorrat", "Vorrat"], ["challenge", "Challenge"], ["filter", "Wortfilter"], ["sponsoren", "Sponsoren"], ["settings", "Einstellungen"]].map(([k, l]) => `<button role="tab" data-adminview="${k}" aria-selected="${v === k}">${l}</button>`).join("")}
      </div>`;
    S.adminHead = head;
    if (v === "uebersicht") { S.dash = extra[4]; $("#main").innerHTML = `<div class="view">${head}${adminOverviewHtml(...extra)}</div>`; return; }
    if (v === "nutzer" && S.adminUser) { $("#main").innerHTML = `<div class="view">${head}${adminUserDetailHtml(extra)}</div>`; return; }
    if (v === "protokoll") { $("#main").innerHTML = `<div class="view">${head}${adminProtocolHtml(...extra)}</div>`; return; }
    if (v === "witze") { S.adminRowsPrev = S.adminRows; drawAdminJokes(); return; }
    if (v === "nutzer") { $("#main").innerHTML = `<div class="view">${head}${adminUsersHtml(extra)}${await adminGroupsHtml()}</div>`; return; }
    if (v === "settings") { $("#main").innerHTML = `<div class="view">${head}${adminSettingsHtml(...extra)}</div>`; return; }
    if (v === "sponsoren") { S.adminSponsors = extra; $("#main").innerHTML = `<div class="view">${head}${adminSponsorsHtml(extra)}</div>`; return; }
    if (v === "stats") { $("#main").innerHTML = `<div class="view">${head}${adminVisitsHtml(extra[4], extra[5])}${adminStatsHtml(...extra.slice(0, 4))}</div>`; return; }
    if (v === "vorrat") { $("#main").innerHTML = `<div class="view">${head}${adminQueueHtml(...extra)}</div>`; return; }
    if (v === "challenge") { $("#main").innerHTML = `<div class="view">${head}${adminChallengeHtml(extra)}</div>`; return; }
    if (v === "battle") { $("#main").innerHTML = `<div class="view">${head}${adminBattleHtml(extra)}</div>`; return; }
    if (v === "filter") { $("#main").innerHTML = `<div class="view">${head}${adminFilterHtml(extra)}</div>`; return; }
    $("#main").innerHTML = `<div class="view">
      ${head}
      ${rows.length ? `<ul class="mod-list">${rows.map((j) => `<li class="mod-item st-${j.status}">
        <div class="mod-head"><span class="pill st-${j.status}">${label[j.status] || j.status}</span>
          ${j.reports ? `<span class="pill reports">${j.reports} ${j.reports === 1 ? "Meldung" : "Meldungen"}</span>` : ""}
          <span class="muted small">${CATS[j.cat] || ""} · @${esc(j.author)} · ${ago(j.created)} · ${fmt(j.up + j.down)} Stimmen</span></div>
        <p class="txt">${esc(j.text)}</p>
        <div class="row">
          ${j.status === "hidden" || j.reports > 0 ? `<button class="btn ghost" data-approve="${j.id}">${j.status === "hidden" ? "Freigeben" : "Meldungen verwerfen"}</button>` : ""}
          <button class="btn danger" data-remove="${j.id}">Entfernen</button>
        </div></li>`).join("")}</ul>`
        : `<p class="empty">${S.adminView === "neu" ? "Noch keine Witze." : "Keine gemeldeten Witze. Alles ruhig."}</p>`}
      <p class="muted small">Ein freigegebener Witz wird erst nach 10 neuen Meldungen wieder automatisch ausgeblendet.</p>
    </div>`;
  }


  const VISIT_LABELS = { list: "Bestenliste", new: "Neu", swipe: "Bewerten", duel: "Duell", highlights: "Highlights", authors: "Autoren", detail: "Einzelne Witze",
    profile: "Profile", groups: "Gruppen-Übersicht", group: "Gruppen", search: "Suche", screen: "Bildschirm-Gestalter", tv: "Bildschirm-Modus", live: "Live-Duell (Handy)",
    challenge: "Challenge", andere: "Sonstiges", direkt: "Direkt / unbekannt", whatsapp: "WhatsApp", google: "Google", qr: "QR-Code", facebook: "Facebook",
    instagram: "Instagram", mobil: "Handy", tablet: "Tablet", computer: "Computer" };
  function adminVisitsHtml(days, parts) {
    if (!days || !days.length) return "";
    const max = Math.max(1, ...days.map((d) => d.uniques)), today = days[days.length - 1], week = days.slice(-7);
    const sum = (a, k) => a.reduce((s, d) => s + d[k], 0);
    const list = (kind, title) => {
      const rows = (parts || []).filter((p) => p.kind === kind && p.views > 0), tot = rows.reduce((s, p) => s + p.views, 0) || 1;
      return `<div><h3>${title}</h3>${rows.length ? `<ul class="visit-list">${rows.map((p) => `<li><span>${esc(VISIT_LABELS[p.label] || p.label)}</span><i style="width:${Math.round((p.views / tot) * 100)}%"></i><b>${fmt(p.views)}</b></li>`).join("")}</ul>` : '<p class="muted small">Noch keine Daten.</p>'}</div>`;
    };
    return `<section class="panel"><h2>Alle Besucher (anonym)</h2>
      <div class="stats">${[[today.uniques, "Besucher heute"], [today.views, "Aufrufe heute"], [sum(week, "uniques"), "Besucher 7 Tage"], [sum(week, "views"), "Aufrufe 7 Tage"]].map(([n, l]) => `<div><b>${fmt(n)}</b><span>${l}</span></div>`).join("")}</div>
      <table class="tbl"><thead><tr><th>Tag</th><th>Besucher</th><th></th><th>Aufrufe</th></tr></thead><tbody>
      ${days.slice().reverse().map((d) => `<tr><td>${fmtShort(d.day)}</td><td>${fmt(d.uniques)}</td><td class="bar"><i style="width:${Math.round((d.uniques / max) * 100)}%"></i></td><td>${fmt(d.views)}</td></tr>`).join("")}
      </tbody></table>
      <div class="visit-grid">${list("route", "Beliebteste Bereiche (Aufrufe, 7 Tage)")}${list("source", "Herkunft (Besucher, 7 Tage)")}${list("device", "Geräte (Besucher, 7 Tage)")}</div>
      <p class="muted small">Ohne Cookies und ohne Geräte-Kennung: Besucher werden pro Tag über einen täglich wechselnden, nicht umkehrbaren Code gezählt. Wer „Do Not Track“ bzw. Global Privacy Control eingeschaltet hat, wird nicht gezählt, ebenso Suchmaschinen-Bots. Daher sind die Zahlen eher etwas zu niedrig.</p>
    </section>`;
  }
  function adminStatsHtml(t, days, cats, top) {
    const max = Math.max(1, ...days.map((d) => d.votes + d.reactions + d.duels));
    const tile = (n, l) => `<div><b>${n}</b><span>${l}</span></div>`;
    return `<div class="stats">${tile(fmt(t.jokes), "Witze sichtbar")}${tile(fmt(t.user_jokes), "von Nutzern")}${tile(fmt(t.users), "Konten")}${tile(fmt(t.votes), "Stimmen gesamt")}${tile(fmt(t.devices), "Geräte haben abgestimmt")}${tile(fmt(t.queued), "im Vorrat")}</div>
      <section class="panel"><h2>Letzte 14 Tage</h2>
        <table class="tbl"><thead><tr><th>Tag</th><th>Aktivität</th><th>Bewerter</th><th>Stimmen</th><th>Reakt.</th><th>Duelle</th><th>Witze</th><th>Konten</th></tr></thead><tbody>
        ${days.slice().reverse().map((d) => `<tr><td>${fmtShort(d.day)}</td><td class="bar"><i style="width:${Math.round(((d.votes + d.reactions + d.duels) / max) * 100)}%"></i></td><td>${d.voters}</td><td>${d.votes}</td><td>${d.reactions}</td><td>${d.duels}</td><td>${d.new_jokes}</td><td>${d.signups}</td></tr>`).join("")}
        </tbody></table>
        <p class="muted small"><a href="#/bildschirm">Bildschirm-Link gestalten</a> · <a href="plakat.html" target="_blank" rel="noopener">QR-Plakat drucken</a></p>
        <p class="muted small">Bewerter = verschiedene Geräte, die an dem Tag abgestimmt, reagiert oder ein Duell entschieden haben. Alle Besucher inklusive reiner Leser stehen oben unter „Alle Besucher“.</p></section>
      <section class="panel"><h2>Kategorien</h2>
        <table class="tbl"><thead><tr><th>Kategorie</th><th>Witze</th><th>im Vorrat</th><th>Stimmen 7 Tage</th></tr></thead><tbody>
        ${cats.map((c) => `<tr><td>${esc(c.name)}</td><td>${c.jokes}</td><td>${c.queued}</td><td>${c.votes_week}</td></tr>`).join("")}</tbody></table></section>
      ${(top || []).length ? `<section class="panel"><h2>Bestenlisten</h2><div class="top-grid">${[["week", "Beste der Woche", "Stimmen"], ["all", "Meiste Likes", "Likes"], ["flop", "Flops der Woche", "Dislikes"], ["reacted", "Meiste Reaktionen", "Reaktionen"], ["duel", "Duell-Elo", "Duelle"], ["reported", "Meistgemeldet", "Meldungen"]].map(([k, l, u]) => {
        const rows = top.filter((x) => x.kind === k);
        return `<div><h3>${l}</h3>${rows.length ? `<ol class="top-list">${rows.map((x) => `<li><a href="#/witz/${x.id}">${esc(x.body.split("\n")[0].slice(0, 70))}</a><span>@${esc(x.author_name)} · ${fmt(x.n)} ${u}</span></li>`).join("")}</ol>` : '<p class="muted small">Noch nichts.</p>'}</div>`;
      }).join("")}</div></section>` : ""}`;
  }
  function adminQueueHtml(t, cats) {
    return `<section class="panel"><h2>Witz-Vorrat</h2>
        <p class="muted small">${t.queued ? `${fmt(t.queued)} Witze sind eingeplant und erscheinen nach und nach, der letzte am ${new Date(t.queue_until).toLocaleDateString("de-DE", { day: "numeric", month: "long" })}.` : "Der Vorrat ist leer. „Heute“ füllt sich nur noch durch Beiträge der Nutzer."}</p>
        <div class="chips static">${cats.filter((c) => c.queued).map((c) => `<span class="chip">${esc(c.name)}: ${c.queued}</span>`).join("")}</div></section>
      <form class="panel form" id="bulkForm">
        <h2>Witze nachlegen</h2>
        <label>Kategorie<select id="bulkCat">${Object.entries(CATS).map(([k, l]) => `<option value="${k}">${l}</option>`).join("")}</select></label>
        <label>Witze (durch eine Leerzeile getrennt)<textarea id="bulkText" rows="10" placeholder="Erster Witz …\nPointe in der zweiten Zeile.\n\nZweiter Witz …"></textarea></label>
        <label>Wie viele pro Tag?<input type="number" id="bulkPer" min="1" max="48" value="3" inputmode="numeric"></label>
        <p class="muted small">Die Witze erscheinen im Anschluss an den schon geplanten Vorrat, als Autor steht „Lachwerk“. Doppelte werden übersprungen.</p>
        <p class="err" id="bulkErr"></p>
        <div><button class="btn">Einplanen</button></div>
      </form>`;
  }
  function adminBattleHtml(rows) {
    const pool = rows.filter((r) => r.kind === "prompt"), entries = rows.filter((r) => r.kind === "entry"), reported = rows.filter((r) => r.kind === "reported");
    return `<form class="panel form" id="promptForm">
        <h2>Witzanfänge für das Battle</h2>
        <p class="muted small">Noch ${pool.length} ${pool.length === 1 ? "Anfang" : "Anfänge"} im Vorrat, also Battles für ${pool.length} ${pool.length === 1 ? "Tag" : "Tage"}. Jeden Tag kommt automatisch der nächste dran.</p>
        <label>Neue Anfänge (einer pro Zeile)<textarea id="promptText" rows="6" placeholder="Warum hat der Kühlschrank Lampenfieber?"></textarea></label>
        <p class="err" id="promptErr"></p>
        <div><button class="btn">Hinzufügen</button></div>
        ${pool.length ? `<details><summary class="small">Vorrat ansehen</summary><ol class="small">${pool.map((p) => `<li>${esc(p.text1)}</li>`).join("")}</ol></details>` : ""}
      </form>
      ${reported.length ? `<section class="panel"><h2>Gemeldete Pointen</h2><ul class="mod-list">${reported.map((e) => `<li class="mod-item st-hidden"><span class="muted small">@${esc(e.text2)} · ${ago(e.at)}</span><p class="txt">${esc(e.text1)}</p><div class="row"><button class="btn ghost" data-approve-punch="${e.id}">Freigeben</button><button class="btn danger" data-rm-punch="${e.id}">Entfernen</button></div></li>`).join("")}</ul></section>` : ""}
      <section class="panel"><h2>Neueste Pointen</h2>
        ${entries.length ? `<ul class="mod-list">${entries.map((e) => `<li class="mod-item"><span class="muted small">@${esc(e.text2)} · ${ago(e.at)}</span><p class="txt">${esc(e.text1)}</p><div><button class="btn danger" data-rm-punch="${e.id}">Entfernen</button></div></li>`).join("")}</ul>` : '<p class="muted small">Noch keine Pointen.</p>'}
      </section>`;
  }
  function adminFilterHtml(words) {
    return `<form class="panel form" id="filterForm">
        <h2>Wortfilter</h2>
        <p class="muted small">Witze und Pointen mit diesen Wörtern werden beim Posten abgelehnt. Ein Wort pro Zeile, nur Kleinbuchstaben. Mit * am Ende zählt das Wort als Wortanfang (z. B. <code>fick*</code> trifft auch „ficken“).</p>
        <label>Gesperrte Wörter<textarea id="filterText" rows="12">${esc(words.join("\n"))}</textarea></label>
        <p class="err" id="filterErr"></p>
        <div><button class="btn">Speichern</button></div>
      </form>`;
  }
  const KPI = [["visitors", "Bewerter"], ["votes", "Stimmen"], ["reactions", "Reaktionen"], ["duels", "Duelle"], ["jokes", "Neue Witze (Nutzer)"], ["signups", "Neue Konten"], ["reports", "Meldungen"]];
  function adminOverviewHtml(o, act, push, punchReports, dash, sec) {
    const delta = (a, b) => { const d = a - b; return d === 0 ? '<span class="delta">±0</span>' : `<span class="delta ${d > 0 ? "up" : "down"}">${d > 0 ? "▲" : "▼"} ${Math.abs(d)}</span>`; };
    const days = o.queue_until ? Math.floor((new Date(o.queue_until) - Date.now()) / 864e5) : 0;
    const warn = (cond) => (cond ? " warn" : "");
    const icon = { joke: "😂", punchline: "🥊", signup: "👋", report: "🚩" };
    const what = { joke: "neuer Witz", punchline: "neue Pointe", signup: "hat sich registriert", report: "Meldung" };
    return `<section class="panel"><h2>Heute <span class="muted small">(im Vergleich zu gestern)</span></h2>
        <div class="kpis">${dash && dash.days ? `<div><b>${fmt(dash.days[dash.days.length - 1].visitors)}</b><span>Besucher</span>${delta(dash.days[dash.days.length - 1].visitors, dash.days[dash.days.length - 2].visitors)}</div>` : ""}${KPI.map(([k, l]) => `<div><b>${fmt(o.today[k])}</b><span>${l}</span>${delta(o.today[k], o.yesterday[k])}</div>`).join("")}</div>
        <p class="muted small"><b>Besucher</b> = alle, die die Seite geöffnet haben (anonym gezählt, Admins nicht mitgezählt). <b>Bewerter</b> = Geräte, die abgestimmt, reagiert oder ein Duell entschieden haben.</p></section>
      ${adminDashHtml(dash, sec)}
      <div class="status-grid">
        <button class="status${warn(o.open_reports > 0)}" data-adminview="gemeldet"><b>${o.open_reports}</b><span>${o.open_reports === 1 ? "Witz" : "Witze"} zu prüfen</span></button>
        ${false && punchReports ? `<button class="status warn" data-adminview="battle"><b>${punchReports}</b><span>${punchReports === 1 ? "Pointe" : "Pointen"} gemeldet</span></button>` : ""}
        <button class="status" data-adminview="nutzer"><b>${fmt(o.users)}</b><span>Konten${o.banned ? ` · ${o.banned} gesperrt` : ""}</span></button>
        <button class="status${warn(days < 7)}" data-adminview="vorrat"><b>${fmt(o.queued)}</b><span>im Vorrat${o.queue_until ? ` · reicht ${days} ${days === 1 ? "Tag" : "Tage"}` : " · leer"}</span></button>
        <button class="status" data-adminview="protokoll"><b>📋</b><span>Protokoll & Sicherheit</span></button>
        ${push ? `<div class="status"><b>${fmt(push.subs)}</b><span>Push-Abos · ${push.daily} mit Witz des Tages${push.last_daily ? " · zuletzt " + fmtShort(push.last_daily) : ""}</span></div>` : ""}
      </div>
      <section class="panel"><h2>Gerade läuft</h2>
        <ul class="facts">
          <li><b>👑 Witz des Tages</b>${o.crown ? `<a href="#/witz/${o.crown.id}">${esc(o.crown.body.split("\n")[0].slice(0, 80))}</a><span>@${esc(o.crown.author)} · ${fmtDay(o.crown.day)}</span>` : "<span>Noch keiner gekrönt.</span>"}</li>
          <li><b>🏋️ Challenge</b>${o.challenge ? `<a href="#/challenge">${esc(o.challenge.title)}</a><span>${o.challenge.entries} Beiträge · ${until(o.challenge.ends_at)}</span>` : '<span>Keine aktiv. <button class="link" data-adminview="challenge">Neue anlegen</button></span>'}</li>
          <li><b>📣 Ankündigung</b>${o.announcement ? `<span>${esc(o.announcement)}</span>` : '<span>Keine. <button class="link" data-adminview="settings">Eine anlegen</button></span>'}</li>
        </ul></section>
      <section class="panel"><h2>Letzte Aktivitäten</h2>
        ${act.length ? `<ul class="feed">${act.map((a) => `<li><span class="fi">${icon[a.kind] || "•"}</span><div><span class="fm">${a.who ? `<a href="#/u/${encodeURIComponent(a.who)}">@${esc(a.who)}</a>` : ""} ${what[a.kind] || a.kind} · ${ago(a.at)}</span>${a.body ? (a.kind === "joke" || a.kind === "report" ? `<a class="ft" href="#/witz/${a.ref}">${esc(a.body.split("\n")[0].slice(0, 90))}</a>` : `<span class="ft">${esc(a.body.slice(0, 90))}</span>`) : ""}</div></li>`).join("")}</ul>` : '<p class="muted small">Noch keine Aktivität von Nutzern.</p>'}
      </section>
      <p class="muted small"><a href="#/bildschirm">Bildschirm-Link</a> · <a href="plakat.html" target="_blank" rel="noopener">QR-Plakat</a> · <a href="https://supabase.com/dashboard" target="_blank" rel="noopener">Supabase</a></p>`;
  }
  const STATUS_LABEL = { visible: "Sichtbar", hidden: "Ausgeblendet", removed: "Entfernt", queued: "Geplant" };
  /* ───────── Admin: Dashboard, Protokoll, Nutzer-Details ───────── */
  const DASH_METRICS = [["visitors", "Besucher"], ["voters", "Bewerter"], ["votes", "Stimmen"], ["jokes", "Neue Witze (Nutzer)"], ["signups", "Neue Konten"], ["reports", "Meldungen"]];
  function pctDelta(a, b, invert) {
    if (!b) return a ? `<span class="delta ${invert ? "down" : "up"}">neu</span>` : '<span class="delta">±0</span>';
    const p = Math.round(((a - b) / b) * 100);
    if (p === 0) return '<span class="delta">±0 %</span>';
    return `<span class="delta ${(p > 0) !== !!invert ? "up" : "down"}">${p > 0 ? "▲" : "▼"} ${Math.abs(p)} %</span>`;
  }
  function secWarnings(s) {
    if (!s) return [];
    const w = [];
    (s.flood_users || []).forEach((u) => w.push(`@${u.username} hat in 24 Std. ${u.n} Witze gepostet.`));
    (s.flood_devices || []).forEach((x) => w.push(`Ein Gerät (${x.dev}…) hat in 24 Std. ${fmt(x.n)} Stimmen abgegeben.`));
    if (s.flood_ips) w.push(`${s.flood_ips} Internet-${s.flood_ips === 1 ? "Anschluss hat" : "Anschlüsse haben"} in 24 Std. über 400 Stimmen abgegeben.`);
    (s.reported_users || []).forEach((u) => w.push(`Witze von @${u.username} wurden in 7 Tagen ${u.n}× gemeldet.`));
    (s.shared_devices || []).forEach((x) => w.push(`Mehrere Konten posten vom selben Gerät: ${x.names}.`));
    if (s.signups_24h >= 20) w.push(`${s.signups_24h} neue Konten in 24 Std.`);
    return w;
  }
  function dashChartHtml(d) {
    const days = d.days, m = S.dashMetric || "visitors", max = Math.max(1, ...days.map((x) => x[m])), tot = days.reduce((a, x) => a + x[m], 0);
    return `<div class="spark" role="img" aria-label="${esc((DASH_METRICS.find((x) => x[0] === m) || [0, ""])[1])} der letzten 30 Tage">${days.map((x) => `<i style="height:${Math.max(2, Math.round((x[m] / max) * 100))}%" title="${fmtShort(x.day)}: ${fmt(x[m])}"></i>`).join("")}</div>
      <div class="spark-axis"><span>${fmtShort(days[0].day)}</span><span>Summe ${fmt(tot)} · Spitze ${fmt(max)}</span><span>heute</span></div>`;
  }
  function adminDashHtml(d, sec) {
    const warns = secWarnings(sec);
    const warnBox = warns.length ? `<button class="panel warn-box" data-adminview="protokoll"><b>⚠️ ${warns.length} ${warns.length === 1 ? "Hinweis" : "Hinweise"} zur Sicherheit</b><span>${esc(warns[0])}${warns.length > 1 ? " Mehr im Protokoll ›" : ""}</span></button>` : "";
    if (!d || !d.days) return warnBox;
    const days = d.days, last7 = days.slice(-7), prev7 = days.slice(-14, -7);
    const sum = (a, k) => a.reduce((s, x) => s + (x[k] || 0), 0);
    const m = S.dashMetric || "visitors", f = d.funnel, fmax = Math.max(1, f.visitors, f.voters, f.signups, f.posters);
    const hours = d.hours || [], hmax = Math.max(1, ...hours);
    return `${warnBox}
      <section class="panel"><h2>Letzte 7 Tage <span class="muted small">(im Vergleich zur Woche davor)</span></h2>
        <div class="kpis">${DASH_METRICS.map(([k, l]) => `<div><b>${fmt(sum(last7, k))}</b><span>${l}</span>${pctDelta(sum(last7, k), sum(prev7, k), k === "reports")}</div>`).join("")}</div></section>
      <section class="panel"><h2>Verlauf 30 Tage</h2>
        <div class="chips static dash-chips">${DASH_METRICS.map(([k, l]) => `<button class="chip" data-dash-metric="${k}" aria-pressed="${k === m}">${l}</button>`).join("")}</div>
        <div id="dashChart">${dashChartHtml(d)}</div></section>
      <section class="panel"><h2>Vom Besuch zum Beitrag <span class="muted small">(7 Tage)</span></h2>
        <ul class="funnel">${[[f.visitors, "Besucher"], [f.voters, "haben bewertet"], [f.signups, "neue Konten"], [f.posters, "haben gepostet"]].map(([n, l], i) => `<li><span>${l}</span><i style="width:${Math.max(2, Math.round((n / fmax) * 100))}%"></i><b>${fmt(n)}${i && f.visitors >= f.voters ? ` <small>${Math.round((n / f.visitors) * 100)} %</small>` : ""}</b></li>`).join("")}</ul>
        ${days.slice(-14).some((x) => !x.visitors) ? '<p class="muted small">ℹ️ Besucher werden erst seit dem 25.10. gezählt. Vergleiche mit der Vorwoche sind darum erst ab Anfang November aussagekräftig.</p>' : ""}
        <p class="muted small">👍-Anteil aller Stimmen: ${d.like_rate ?? "–"} % · Ø ${d.votes_per_joke ?? "–"} Stimmen pro neuem Witz · aktive Autoren: ${d.authors_7} in 7 Tagen, ${d.authors_30} in 30 Tagen</p></section>
      <section class="panel"><h2>Stimmen der letzten 24 Stunden</h2>
        <div class="spark hours">${hours.map((n, i) => `<i style="height:${Math.max(2, Math.round((n / hmax) * 100))}%" title="vor ${23 - i} Std.: ${n}"></i>`).join("")}</div>
        <div class="spark-axis"><span>vor 24 Std.</span><span>${fmt(hours.reduce((a, b) => a + b, 0))} Stimmen</span><span>jetzt</span></div></section>
      <section class="panel"><h2>Top-Autoren <span class="muted small">(Stimmen der letzten 30 Tage)</span></h2>
        ${(d.top_authors || []).length ? `<ol class="top-list">${d.top_authors.map((a) => `<li><button class="link" data-admin-user="${esc(a.username)}">@${esc(a.username)}</button><span>${fmt(a.likes)} 👍 · ${fmt(a.dislikes)} 👎 · ${a.jokes} ${a.jokes === 1 ? "Witz" : "Witze"}</span></li>`).join("")}</ol>` : '<p class="muted small">Noch keine Stimmen für Witze von Nutzern.</p>'}
        ${(d.top_cats || []).length ? `<p class="muted small">Meiste Stimmen in 7 Tagen: ${d.top_cats.map((c) => `${esc(c.name)} (${fmt(c.votes)})`).join(" · ")}</p>` : ""}</section>`;
  }
  const LOG_TEXT = {
    joke_hide: ["🙈", "hat ausgeblendet:"], joke_remove: ["🗑️", "hat entfernt:"], joke_restore: ["✅", "hat freigegeben:"], reports_clear: ["🧹", "hat Meldungen verworfen:"],
    joke_edit: ["✏️", "hat bearbeitet:"], joke_category: ["🏷️", "hat die Kategorie geändert:"], joke_add: ["➕", "hat {w} veröffentlicht"], joke_plan: ["🗓️", "hat {w} eingeplant"],
    user_ban: ["⛔", "hat gesperrt:"], user_unban: ["🔓", "hat entsperrt:"], role_on: ["⭐", "hat zum Admin gemacht:"], role_off: ["⭐", "hat Admin-Rechte entzogen:"],
    user_note: ["📝", "hat eine Notiz geschrieben zu"], words_save: ["🔤", "hat den Wortfilter gespeichert"], announcement: ["📣", "hat die Ankündigung geändert"],
    contact: ["✉️", "hat die Kontakt-E-Mail geändert"], challenge_save: ["🏋️", "hat eine Challenge gespeichert"], sponsor_save: ["🤝", "hat einen Sponsor gespeichert"],
    sponsor_delete: ["🤝", "hat einen Sponsor gelöscht"], group_delete: ["👥", "hat eine Gruppe gelöscht"],
  };
  function logTarget(t) {
    if (!t) return "";
    if (t[0] === "#") return `<button class="link" data-admin-find="${esc(t.slice(1))}">Witz ${esc(t)}</button>`;
    if (t[0] === "@") return `<button class="link" data-admin-user="${esc(t.slice(1))}">${esc(t)}</button>`;
    return "";
  }
  function logItemHtml(l) {
    const [ic, txt] = LOG_TEXT[l.action] || ["•", l.action];
    const w = l.n > 1 ? `${l.n} Witze` : "einen Witz";
    return `<li><span class="fi">${ic}</span><div><span class="fm"><b>${esc(l.actor)}</b> ${txt.replace("{w}", w)} ${logTarget(l.target)} · ${ago(l.at)}</span>${l.detail ? `<span class="ft">${esc(l.detail)}</span>` : ""}</div></li>`;
  }
  function adminProtocolHtml(sec, log) {
    const w = secWarnings(sec), s = sec || {};
    return `<section class="panel"><h2>🛡️ Sicherheit</h2>
        ${w.length ? `<ul class="warn-list">${w.map((x) => `<li>⚠️ ${esc(x)}</li>`).join("")}</ul>` : '<p class="ok-line">✅ Keine Auffälligkeiten in den letzten 24 Stunden.</p>'}
        <ul class="facts">
          <li><b>Wer hier Admin ist</b><span>Inhaber mit Admin-Schlüssel${(s.admins || []).map((a) => ` · <button class="link" data-admin-user="${esc(a)}">@${esc(a)}</button>`).join("")}</span></li>
          <li><b>Neue Konten in 24 Std.</b><span>${fmt(s.signups_24h || 0)}</span></li>
          <li><b>Gesperrte Konten</b>${(s.banned || []).length ? s.banned.map((b) => `<span><button class="link" data-admin-user="${esc(b.username)}">@${esc(b.username)}</button> · seit ${fmtShort(b.banned_at)}${b.ban_reason ? " · " + esc(b.ban_reason) : ""}</span>`).join("") : "<span>Keine.</span>"}</li>
        </ul>
        <p class="muted small">Automatisch geprüft: mehr als 4 Witze eines Kontos in 24 Std., 150+ Stimmen von einem Gerät oder 400+ von einem Internet-Anschluss in 24 Std., Konten mit 3+ Meldungen in 7 Tagen und mehrere Konten, die vom selben Gerät posten (kann auch eine Familie sein).</p></section>
      <section class="panel"><h2>🚩 Meldungen der letzten 30 Tage</h2>
        ${(s.recent_reports || []).length ? `<ul class="feed">${s.recent_reports.map((r) => `<li><span class="fi">🚩</span><div><span class="fm">${r.n}× gemeldet · @${esc(r.author_name)} · ${ago(r.at)} · <span class="pill st-${r.status}">${STATUS_LABEL[r.status] || r.status}</span></span><button class="link ft" data-admin-find="${r.id}">${esc(r.body)}</button></div></li>`).join("")}</ul>` : '<p class="muted small">Keine Meldungen.</p>'}</section>
      <section class="panel"><h2>📋 Moderations-Protokoll</h2>
        <p class="muted small">Jede Aktion im Admin-Bereich mit Person und Zeitpunkt. Einträge werden nach einem Jahr gelöscht.</p>
        ${log.length ? `<ul class="feed">${log.map(logItemHtml).join("")}</ul>${log.length >= (S.logLimit || 50) ? '<button class="btn ghost more" data-log-more>Ältere laden</button>' : ""}` : '<p class="muted small">Noch keine Einträge. Ab jetzt wird jede Admin-Aktion hier festgehalten.</p>'}</section>`;
  }
  const USORT = [["neu", "Neueste"], ["likes", "Meiste Likes"], ["witze", "Meiste Witze"], ["aktiv", "Zuletzt aktiv"], ["meldungen", "Meldungen"]];
  function sortUsers(users) {
    const k = S.userSort || "neu", t = (x) => (x ? new Date(x).getTime() : 0);
    const by = { likes: (a, b) => b.up_count - a.up_count, witze: (a, b) => b.jokes - a.jokes, aktiv: (a, b) => t(b.last_activity) - t(a.last_activity), meldungen: (a, b) => b.reports - a.reports };
    return by[k] ? users.slice().sort((a, b) => by[k](a, b) || t(b.created_at) - t(a.created_at)) : users;
  }
  function userPills(u) {
    return `${u.role === "admin" ? '<span class="pill st-visible">Admin</span>' : ""}${u.banned_at ? '<span class="pill st-hidden">Gesperrt</span>' : ""}${u.has_note || u.note ? '<span class="pill">📝 Notiz</span>' : ""}${u.push ? '<span class="pill">🔔</span>' : ""}`;
  }
  function adminUserDetailHtml(u) {
    const tot = u.up + u.down, rate = tot ? Math.round((u.up / tot) * 100) + " %" : "–", all = u.visible + u.queued + u.hidden + u.removed;
    const dt = (x) => new Date(x).toLocaleDateString("de-DE", { day: "numeric", month: "long", year: "numeric" });
    return `<button class="link back-link" data-admin-user-back>‹ Alle Nutzer</button>
      <section class="panel"><div class="mod-head"><h2 class="uname">@${esc(u.username)}</h2>${userPills(u)}</div>
        ${u.banned_at ? `<p class="err">Gesperrt seit ${fmtShort(u.banned_at)}${u.ban_reason ? ": " + esc(u.ban_reason) : ""}</p>` : ""}
        ${(u.same_device || []).length ? `<p class="warn-line">⚠️ Postet vom selben Gerät wie ${u.same_device.map((n) => `<button class="link" data-admin-user="${esc(n)}">@${esc(n)}</button>`).join(", ")}</p>` : ""}
        <div class="kpis">${[[u.visible, "Witze sichtbar"], [u.queued, "geplant"], [u.hidden + u.removed, "ausgebl./entfernt"], [u.up, "👍 erhalten"], [u.down, "👎 erhalten"], [rate, "Zustimmung"], [u.reports, "Meldungen"], [u.votes_given, "Stimmen abgegeben"]].map(([n, l]) => `<div><b>${typeof n === "number" ? fmt(n) : n}</b><span>${l}</span></div>`).join("")}</div>
        <ul class="facts">
          <li><b>Dabei seit</b><span>${dt(u.created_at)}</span></li>
          <li><b>Erster / letzter Witz</b><span>${u.first_joke ? dt(u.first_joke) : "–"} / ${u.last_joke ? ago(u.last_joke) : "–"}</span></li>
          <li><b>Geräte · Push · Gruppen</b><span>${u.devices} ${u.devices === 1 ? "Gerät" : "Geräte"} · Push ${u.push ? "an" : "aus"} · in ${u.groups} ${u.groups === 1 ? "Gruppe" : "Gruppen"}${u.groups_owned ? `, ${u.groups_owned} selbst gegründet` : ""}</span></li>
          ${u.best ? `<li><b>Bester Witz</b><a href="#/witz/${u.best.id}">${esc(u.best.body.split("\n")[0])}</a><span>${fmt(u.best.up)} 👍</span></li>` : ""}
        </ul>
        <div class="row btns">
          <a class="btn ghost" href="#/u/${encodeURIComponent(u.username)}">Öffentliches Profil</a>
          ${all ? `<button class="btn ghost" data-adminview="witze" data-author="${esc(u.username)}">In „Witze“ öffnen</button>` : ""}
          ${u.visible + u.queued + u.hidden ? `<button class="btn ghost" data-wipe="${esc(u.username)}">Alle Inhalte entfernen</button>` : ""}
          ${S.adminKey ? (u.role === "admin" ? `<button class="btn ghost" data-set-role="${esc(u.username)}" data-role-on="0">Admin-Rechte entziehen</button>` : (u.banned_at ? "" : `<button class="btn ghost" data-set-role="${esc(u.username)}" data-role-on="1">Zum Admin machen</button>`)) : ""}
        </div>
        ${u.banned_at ? `<div><button class="btn ghost" data-unban="${esc(u.username)}">Entsperren</button></div>`
          : `<form class="ban-form row" data-name="${esc(u.username)}"><input type="text" placeholder="Grund der Sperre (optional)" maxlength="80"><button class="btn danger">Sperren</button></form>`}
      </section>
      <form class="panel form" id="noteForm" data-name="${esc(u.username)}"><h2>📝 Interne Notiz</h2>
        <p class="muted small">Nur für Admins sichtbar, z. B. „Am 26.10. verwarnt“.</p>
        <textarea id="noteText" rows="3" maxlength="500">${esc(u.note || "")}</textarea><p class="err" id="noteErr"></p>
        <div><button class="btn">Notiz speichern</button></div></form>
      <section class="panel"><h2>Witze (${all})</h2>
        ${(u.jokes || []).length ? `<ul class="mod-list">${u.jokes.map((j) => `<li class="mod-item st-${j.status}"><div class="mod-head"><span class="pill st-${j.status}">${STATUS_LABEL[j.status] || j.status}</span><span class="muted small">#${j.id} · ${CATS[j.category_slug] || ""} · ${ago(j.created_at)} · ${fmt(j.up_count)} 👍 ${fmt(j.down_count)} 👎${j.report_count ? ` · 🚩 ${j.report_count}` : ""}</span></div>
          <p class="txt">${esc(j.body)}</p>
          <div class="row">${j.status === "removed" || j.status === "hidden" ? `<button class="btn ghost" data-admin-restore="${j.id}">Wiederherstellen</button>` : `<button class="btn ghost" data-admin-hide="${j.id}">Ausblenden</button><button class="btn danger" data-admin-remove-j="${j.id}">Entfernen</button>`}</div></li>`).join("")}</ul>${all > 40 ? '<p class="muted small">Die neuesten 40 werden angezeigt.</p>' : ""}` : '<p class="muted small">Noch keine Witze.</p>'}</section>
      <section class="panel"><h2>Protokoll zu diesem Konto</h2>
        ${(u.log || []).length ? `<ul class="feed">${u.log.map(logItemHtml).join("")}</ul>` : '<p class="muted small">Noch keine Admin-Aktionen.</p>'}</section>`;
  }
  function bulkBarHtml() {
    const n = S.adminSel ? S.adminSel.size : 0;
    return `<b>${n} ausgewählt</b>
      <div class="bulk-actions"><button class="btn ghost" data-bulk="visible">Freigeben</button><button class="btn ghost" data-bulk="hidden">Ausblenden</button><button class="btn danger" data-bulk="removed">Entfernen</button>
        <select id="bulkCatSel" aria-label="Kategorie ändern"><option value="">Kategorie ändern …</option>${Object.entries(CATS).map(([k, l]) => `<option value="${k}">${l}</option>`).join("")}</select></div>
      <div class="bulk-links"><button class="link" data-sel-all>Alle auf der Seite</button><button class="link" data-sel-none>Auswahl aufheben</button></div>`;
  }
  async function bulkApply(status, cat, el) {
    const ids = [...(S.adminSel || [])]; if (!ids.length) return;
    const label = { visible: "freigegeben", hidden: "ausgeblendet", removed: "entfernt" };
    if (status === "removed" && el.dataset.armed !== "1") { el.dataset.armed = "1"; el.textContent = `${ids.length} wirklich entfernen?`; return; }
    el.disabled = true;
    try {
      const n = cat ? await API.adminBulkCategory(S.adminKey, ids, cat) : await API.adminBulkStatus(S.adminKey, ids, status);
      toast(cat ? `${n} ${n === 1 ? "Witz" : "Witze"} in „${CATS[cat]}“ verschoben.` : `${n} ${n === 1 ? "Witz" : "Witze"} ${label[status]}.`);
      S.adminSel.clear(); S.adminQ.offset = 0; S.adminRowsPrev = []; render();
    } catch (ex) { el.disabled = false; toast(errorText(ex)); }
  }
  function drawBulkBar() { const b = $("#bulkBar"); if (!b) return; b.hidden = !(S.adminSel && S.adminSel.size); b.innerHTML = bulkBarHtml(); }

  function drawAdminJokes() {
    const q = S.adminQ, rows = S.adminRows || [];
    const opt = (v, l, cur) => `<option value="${v}"${v === cur ? " selected" : ""}>${l}</option>`;
    if (!S.adminSel) S.adminSel = new Set();
    $("#main").innerHTML = `<div class="view">${S.adminHead}
      <details class="panel post-box"${S.postOpen ? " open" : ""}><summary><b>＋ Witz als „Lachwerk“ posten</b></summary>
        <form class="form" id="adminPostForm">
          <label>Kategorie<select id="apCat">${Object.entries(CATS).map(([k, l]) => `<option value="${k}">${l}</option>`).join("")}</select></label>
          <label>Witz<textarea id="apText" rows="4" maxlength="500" placeholder="Witz … (Pointe gern in eine neue Zeile)"></textarea></label>
          <label>Wann?<select id="apMode"><option value="now">Sofort veröffentlichen</option><option value="queue">Hinten in den Vorrat einreihen</option><option value="at">Zu einem bestimmten Zeitpunkt</option></select></label>
          <label id="apAtWrap" hidden>Zeitpunkt<input type="datetime-local" id="apAt"></label>
          <p class="err" id="apErr"></p><div><button class="btn">Posten</button></div></form></details>
      <form class="panel form search-form" id="adminSearchForm">
        <div class="sf-row"><input type="text" id="aqText" placeholder="Text oder Nummer suchen" value="${esc(q.q)}"><button class="btn">Suchen</button></div>
        <div class="sf-row">
          <select id="aqCat">${opt("", "Alle Kategorien", q.cat)}${Object.entries(CATS).map(([k, l]) => opt(k, l, q.cat)).join("")}</select>
          <select id="aqStatus">${opt("", "Alle", q.status)}${opt("visible", "Sichtbar", q.status)}${opt("queued", "Geplant", q.status)}${opt("hidden", "Ausgeblendet", q.status)}${opt("removed", "Entfernt", q.status)}</select>
          <input type="text" id="aqAuthor" placeholder="Autor" value="${esc(q.author)}">
        </div>
      </form>
      ${rows.length ? `<ul class="mod-list">${rows.map((j) => S.editJoke === Number(j.id) ? `<li class="mod-item"><form class="form" id="editJokeForm" data-id="${j.id}">
          <label>Kategorie<select id="ejCat">${Object.entries(CATS).map(([k, l]) => opt(k, l, j.category_slug)).join("")}</select></label>
          <label>Text<textarea id="ejText" rows="4" maxlength="500">${esc(j.body)}</textarea></label>
          <p class="err" id="ejErr"></p>
          <div class="row"><button type="button" class="btn ghost" data-admin-edit-cancel>Abbrechen</button><button class="btn">Speichern</button></div></form></li>`
        : `<li class="mod-item st-${j.status}">
          <div class="mod-head"><label class="sel" title="Auswählen"><input type="checkbox" class="sel-joke" value="${j.id}"${S.adminSel.has(Number(j.id)) ? " checked" : ""}></label><span class="pill st-${j.status}">${STATUS_LABEL[j.status] || j.status}</span>
            ${j.report_count ? `<span class="pill reports">${j.report_count} Meldungen</span>` : ""}
            <span class="muted small">#${j.id} · ${CATS[j.category_slug] || ""} · @${esc(j.author_name)}${j.is_user ? "" : " (Redaktion)"} · ${j.status === "queued" ? "erscheint " + new Date(j.created_at).toLocaleString("de-DE", { day: "numeric", month: "numeric", hour: "2-digit", minute: "2-digit" }) : ago(j.created_at)} · ${fmt(j.up_count)} 👍 ${fmt(j.down_count)} 👎</span></div>
          <p class="txt">${esc(j.body)}</p>
          <div class="row">
            <button class="btn ghost" data-admin-edit="${j.id}">Bearbeiten</button>
            ${j.status === "removed" || j.status === "hidden" ? `<button class="btn ghost" data-admin-restore="${j.id}">Wiederherstellen</button>` : `<button class="btn ghost" data-admin-hide="${j.id}">Ausblenden</button><button class="btn danger" data-admin-remove-j="${j.id}">Entfernen</button>`}
            ${j.status === "visible" ? `<a class="btn ghost" href="#/witz/${j.id}">Ansehen</a>` : ""}
          </div></li>`).join("")}</ul>
        ${rows.length % 30 === 0 ? '<button class="btn ghost more" data-admin-more>Weitere laden</button>' : ""}`
      : '<p class="empty">Keine Witze gefunden.</p>'}
      <div id="bulkBar" class="bulk-bar"${S.adminSel.size ? "" : " hidden"}>${bulkBarHtml()}</div>
    </div>`;
  }
  function adminUserSummaryHtml(users) {
    const wk = Date.now() - 7 * 864e5, t = (x) => (x ? new Date(x).getTime() : 0);
    const tiles = [[users.length, "Konten"], [users.filter((u) => t(u.created_at) > wk).length, "neu (7 Tage)"], [users.filter((u) => t(u.last_activity) > wk).length, "aktiv (7 Tage)"],
      [users.filter((u) => u.jokes > 0).length, "mit Witzen"], [users.filter((u) => u.push).length, "mit Push"], [users.filter((u) => u.banned_at).length, "gesperrt"]];
    return `<div class="kpis user-kpis">${tiles.map(([n, l]) => `<div><b>${fmt(n)}</b><span>${l}</span></div>`).join("")}</div>
      <div class="chips static">${USORT.map(([k, l]) => `<button class="chip" data-usort="${k}" aria-pressed="${(S.userSort || "neu") === k}">${l}</button>`).join("")}</div>`;
  }
  function adminUsersHtml(users) {
    return `<form class="panel form search-form" id="userSearchForm"><div class="sf-row"><input type="text" id="uqText" placeholder="Benutzername suchen" value="${esc(S.adminUserQ)}"><button class="btn">Suchen</button></div>
        <p class="muted small">${users.length} ${users.length === 1 ? "Konto" : "Konten"}${S.adminUserQ ? " gefunden" : ", Admins und neueste zuerst"}. E-Mail-Adressen siehst du aus Datenschutzgründen nur in Supabase (Authentication → Users).</p>
        ${S.adminKey ? "" : `</form><form class="panel form" id="ownerKeyForm"><p class="small"><b>Weitere Admins ernennen:</b> Das darf nur, wer den Admin-Schlüssel hat. Gib ihn hier ein, dann erscheint bei jedem Konto „Zum Admin machen“.</p>
          <div class="sf-row"><input type="password" id="ownerKey" placeholder="Admin-Schlüssel" autocomplete="current-password"><button class="btn">Freischalten</button></div><p class="err" id="ownerErr"></p>`}
        ${S.adminKey ? '<p class="muted small"><b>Weitere Admins:</b> Mit „Zum Admin machen“ bekommt ein Konto vollen Zugriff auf diesen Bereich. Die Person meldet sich einfach mit ihrem Lachwerk-Konto an und findet oben „Moderation“. Rechte vergeben und entziehen kannst nur du mit dem Admin-Schlüssel.</p>' : ""}</form>
      ${adminUserSummaryHtml(users)}
      ${users.length ? `<ul class="user-list">${sortUsers(users).map((u) => `<li><button class="user-row${u.banned_at ? " banned" : ""}" data-admin-user="${esc(u.username)}">
          <span class="ur-name"><b>@${esc(u.username)}</b>${userPills(u)}</span>
          <span class="muted small">seit ${new Date(u.created_at).toLocaleDateString("de-DE")} · ${u.jokes} Witze · ${fmt(u.up_count)} 👍 ${fmt(u.down_count)} 👎${u.reports ? ` · 🚩 ${u.reports}` : ""}${u.last_activity ? " · aktiv " + ago(u.last_activity) : ""}</span>
          <span class="ur-go" aria-hidden="true">›</span></button></li>`).join("")}</ul>` : '<p class="empty">Keine Konten gefunden.</p>'}`;
  }
  function adminSettingsHtml(o, contact) {
    return `<form class="panel form" id="contactForm">
        <h2>Kontakt-E-Mail für Firmen</h2>
        <p class="muted small">Wird auf der (derzeit ausgeblendeten) Seite „Für Unternehmen“ als Anfrage-Knopf angezeigt. Leer lassen, um den Knopf auszublenden.</p>
        <input type="email" id="contactEmail" value="${esc(contact || "")}" placeholder="z. B. hallo@lachwerk.de">
        <p class="err" id="contactErr"></p>
        <div><button class="btn">Speichern</button></div>
      </form>
      <form class="panel form" id="annForm">
        <h2>Ankündigung auf der Startseite</h2>
        <p class="muted small">Erscheint oben in der Bestenliste, bis du sie entfernst. Besucher können sie für sich wegklicken. Max. 280 Zeichen.</p>
        <textarea id="annText" rows="3" maxlength="280" placeholder="z. B. Neue Challenge ab Montag: Witze über Kollegen!">${esc(o.announcement || "")}</textarea>
        <p class="err" id="annErr"></p>
        <div class="row"><button class="btn">Speichern</button>${o.announcement ? '<button type="button" class="btn ghost" data-ann-clear>Entfernen</button>' : ""}</div>
      </form>
      <section class="panel"><h2>Export</h2>
        <p class="muted small">Alle Witze mit Kategorie, Autor, Datum, Stimmen und Status als CSV-Datei, z. B. für Excel.</p>
        <div><button class="btn ghost" data-export-csv>Witze als CSV herunterladen</button></div>
      </section>
      <section class="panel"><h2>Werkzeuge</h2>
        <ul class="facts">
          <li><b>📺 Bildschirm-Modus</b><a href="#/bildschirm">Bildschirm-Link gestalten</a><span>Quer- oder Hochformat, eigene Farben, Kurzlink zum Eintippen.</span></li>
          <li><b>🖨️ QR-Plakat</b><a href="plakat.html" target="_blank" rel="noopener">plakat.html</a><span>A4 zum Ausdrucken.</span></li>
          <li><b>🔑 Admin-Schlüssel ändern</b><span>Im Supabase SQL Editor: <code>select public.set_admin_key('neuer-schlüssel');</code></span></li>
        </ul></section>`;
  }
  async function exportCsv(btn) {
    btn.disabled = true; const label = btn.textContent; btn.textContent = "Wird erstellt …";
    try {
      const rows = await API.adminExport(S.adminKey);
      const cell = (v) => `"${String(v == null ? "" : v).replace(/"/g, '""')}"`;
      const head = ["Nr", "Kategorie", "Witz", "Autor", "Erstellt", "Likes", "Dislikes", "Meldungen", "Status"];
      const csv = "\ufeff" + [head.map(cell).join(";"), ...rows.map((r) => [r.id, CATS[r.category] || r.category, r.body, r.author, new Date(r.created_at).toLocaleString("de-DE"), r.up_count, r.down_count, r.report_count, STATUS_LABEL[r.status] || r.status].map(cell).join(";"))].join("\r\n");
      const a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" }));
      a.download = `lachwerk-witze-${dayKey(Date.now())}.csv`; document.body.appendChild(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 2000);
      toast(`${rows.length} Witze exportiert.`);
    } catch (e) { toast(errorText(e)); }
    finally { btn.disabled = false; btn.textContent = label; }
  }
  const PLACES = { daily: "Witz des Tages (inkl. Story-Bild)", challenge: "Wochen-Challenge", list: "Bestenliste (Startseite)", tv: "Bildschirm-Modus" };
  function adminSponsorsHtml(list) {
    const e = S.editSponsor || {};
    S.spLogo = e.logo || "";
    const now = new Date(), end0 = new Date(); end0.setMonth(end0.getMonth() + 1);
    const state = (x) => (x.active ? ["Läuft", "st-visible"] : new Date(x.starts_at) > now ? ["Geplant", ""] : ["Beendet", "st-hidden"]);
    return `<form class="panel form" id="sponsorForm">
        <h2>${e.id ? "Sponsor bearbeiten" : "Neuer Sponsor"}</h2>
        <label>Name<input type="text" id="spName" maxlength="60" value="${esc(e.name || "")}" placeholder="z. B. Café Sonnenschein"></label>
        <label>Kurzer Satz (optional)<input type="text" id="spClaim" maxlength="120" value="${esc(e.claim || "")}" placeholder="z. B. Der beste Kaffee in Bad Bramstedt"></label>
        <label>Link (optional)<input type="url" id="spUrl" value="${esc(e.url || "")}" placeholder="https://…"></label>
        <label>Platzierung<select id="spPlace">${Object.entries(PLACES).map(([k, l]) => `<option value="${k}"${(e.placement || "daily") === k ? " selected" : ""}>${l}</option>`).join("")}</select></label>
        <div class="sf-row"><label>Start<input type="datetime-local" id="spStart" value="${toLocalInput(e.starts_at || now.toISOString())}"></label>
          <label>Ende<input type="datetime-local" id="spEnd" value="${toLocalInput(e.ends_at || end0.toISOString())}"></label></div>
        <label>Logo (optional, wird automatisch verkleinert)<input type="file" id="spLogoFile" accept="image/png,image/jpeg,image/webp"></label>
        <div id="spLogoPrev" class="sp-prev">${e.logo ? `<img src="${e.logo}" alt=""><button type="button" class="link" data-sp-logo-clear>Logo entfernen</button>` : ""}</div>
        <p class="muted small">Pro Platzierung wird der zuletzt gestartete laufende Sponsor gezeigt, immer mit dem Hinweis „Sponsor“. Klicks auf den Link werden gezählt, ohne Daten über die Person.</p>
        <p class="err" id="spErr"></p>
        <div class="row">${e.id ? '<button type="button" class="btn ghost" data-sp-new>Abbrechen</button>' : ""}<button class="btn">Speichern</button></div>
      </form>
      <section class="panel"><h2>Sponsoren</h2>
        ${list.length ? `<ul class="mod-list">${list.map((x) => { const [l, c] = state(x); return `<li class="mod-item">
            <div class="mod-head"><span class="pill ${c}">${l}</span><b>${esc(x.name)}</b>${x.logo ? `<img class="sp-mini" src="${x.logo}" alt="">` : ""}</div>
            <span class="muted small">${PLACES[x.placement]} · ${new Date(x.starts_at).toLocaleDateString("de-DE")} – ${new Date(x.ends_at).toLocaleDateString("de-DE")} · <b>${fmt(x.clicks)}</b> Klicks${x.url ? " · " + esc(x.url) : ""}</span>
            <div class="row"><button class="btn ghost" data-sp-edit="${x.id}">Bearbeiten</button><button class="btn danger" data-sp-del="${x.id}">Löschen</button>${x.placement === "tv" || x.active ? `<button class="btn ghost" data-tv-link data-sp="${x.id}">Bildschirm-Link</button>` : ""}</div></li>`; }).join("")}</ul>` : '<p class="muted small">Noch keine Sponsoren.</p>'}
      </section>
      <section class="panel form" id="tvLinkBox"><h2>Bildschirm-Link für eine Firma</h2>
        <p class="muted small">Kategorien und auf Wunsch das Logo eines laufenden Sponsors wählen. Format, Farben und Kurzlink stellst du danach im Bildschirm-Gestalter ein.</p>
        <div class="chips static">${Object.entries(CATS).map(([k, l]) => `<label class="chip-check"><input type="checkbox" value="${k}"> ${l}</label>`).join("")}</div>
        <label>Mit Branding von<select id="tvSp"><option value="">ohne</option>${list.filter((x) => x.active).map((x) => `<option value="${x.id}">${esc(x.name)}</option>`).join("")}</select></label>
        <div><button class="btn ghost" data-tv-link>Im Bildschirm-Gestalter öffnen</button></div>
      </section>`;
  }
  function buildTvLink() {
    const box = $("#tvLinkBox"); if (!box) return;
    const cats = [...box.querySelectorAll("input[type=checkbox]:checked")].map((x) => x.value), sp = $("#tvSp").value;
    const q = new URLSearchParams(); if (cats.length) q.set("k", cats.join(",")); if (sp) q.set("s", sp);
    location.hash = "#/bildschirm" + (q.toString() ? "?" + q.toString() : "");
  }

  // Logo im Browser verkleinern (max. 400 × 160 Pixel), damit es klein in der Datenbank liegt
  function shrinkLogo(file) {
    return new Promise((resolve, reject) => {
      const img = new Image(); const url = URL.createObjectURL(file);
      img.onload = () => {
        const k = Math.min(1, 400 / img.width, 160 / img.height);
        const c = document.createElement("canvas"); c.width = Math.round(img.width * k); c.height = Math.round(img.height * k);
        c.getContext("2d").drawImage(img, 0, 0, c.width, c.height); URL.revokeObjectURL(url);
        let out = c.toDataURL("image/webp", 0.85); if (!out.startsWith("data:image/webp")) out = c.toDataURL("image/png");
        resolve(out);
      };
      img.onerror = () => reject(new Error("bad image")); img.src = url;
    });
  }
  const toLocalInput = (iso) => { const d = new Date(iso); d.setMinutes(d.getMinutes() - d.getTimezoneOffset()); return d.toISOString().slice(0, 16); };
  function adminChallengeHtml(list) {
    const e = S.editChallenge || {};
    const start = e.starts_at ? toLocalInput(e.starts_at) : toLocalInput(new Date().toISOString());
    const end0 = new Date(); end0.setDate(end0.getDate() + 7); end0.setHours(20, 0, 0, 0);
    const end = e.ends_at ? toLocalInput(e.ends_at) : toLocalInput(end0.toISOString());
    return `<form class="panel form" id="challengeForm">
        <h2>${e.id ? "Challenge bearbeiten" : "Neue Challenge"}</h2>
        <label>Thema<input type="text" id="chTitle" maxlength="80" value="${esc(e.title || "")}" placeholder="z. B. Witze über Kollegen"></label>
        <label>Beschreibung<textarea id="chDesc" maxlength="300" rows="3">${esc(e.description || "")}</textarea></label>
        <label>Start<input type="datetime-local" id="chStart" value="${start}"></label>
        <label>Ende<input type="datetime-local" id="chEnd" value="${end}"></label>
        <p class="err" id="chErr"></p>
        <div class="row">${e.id ? '<button type="button" class="btn ghost" data-ch-new>Abbrechen</button>' : ""}<button class="btn">Speichern</button></div>
      </form>
      <section class="panel"><h2>Bisherige Challenges</h2>
        ${list.length ? `<ul class="mod-list">${list.map((c) => `<li class="mod-item"><div class="mod-head"><span class="pill${c.active ? " st-visible" : ""}">${c.active ? "Läuft" : "Beendet"}</span><strong>${esc(c.title)}</strong></div>
          <span class="muted small">${new Date(c.starts_at).toLocaleDateString("de-DE")} – ${new Date(c.ends_at).toLocaleString("de-DE", { day: "numeric", month: "numeric", hour: "2-digit", minute: "2-digit" })} · ${c.entries} Beiträge${c.winner_name ? " · Sieger @" + esc(c.winner_name) : ""}</span>
          <div><button class="btn ghost" data-ch-edit="${c.id}">Bearbeiten</button></div></li>`).join("")}</ul>` : '<p class="muted small">Noch keine.</p>'}
        <p class="muted small">Geplante Challenges, die noch nicht begonnen haben, erscheinen hier erst ab ihrem Start.</p></section>`;
  }

  /* ───────── Posten ───────── */
  let simTimer = null, simSeq = 0;
  function showDup(d) {
    const box = $("#dupBox");
    box.hidden = !d;
    $("#postSubmit").disabled = !!d;
    if (d) box.innerHTML = `<div class="dup"><strong>Diesen Witz gibt es schon${d.match ? ` (${Math.round(d.match * 100)} % ähnlich)` : ""}.</strong>
      ${d.text ? `<q>${esc(d.text)}</q>` : ""}<div><a class="btn ghost" href="#/witz/${d.id}" data-close>Zum Original</a></div></div>`;
  }
  function checkSimilar() {
    clearTimeout(simTimer);
    const t = $("#postText").value.trim();
    if (t.length < 10) { showDup(null); return; }
    const seq = ++simSeq;
    simTimer = setTimeout(() => { API.similar(t).then((d) => { if (seq === simSeq) showDup(d); }).catch(() => {}); }, 350);
  }
  function openSheet(id) { $(id).hidden = false; const f = $(id).querySelector("textarea") || $(id).querySelector("input"); if (f) setTimeout(() => f.focus(), 30); }
  function closeSheets() { document.querySelectorAll(".scrim").forEach((s) => (s.hidden = true)); }
  function toast(m) { const t = $("#toast"); t.textContent = m; t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => (t.hidden = true), 2600); }

  /* ───────── Ereignisse ───────── */
  let reportId = null, reportKind = "joke";
  document.addEventListener("click", (e) => {
    if (e.target.classList && e.target.classList.contains("scrim")) { closeSheets(); return; }
    if (e.target.closest && e.target.closest(".tv")) {
      const el = document.documentElement;
      if (!document.fullscreenElement && el.requestFullscreen) el.requestFullscreen().catch(() => {});
      else if (document.exitFullscreen) document.exitFullscreen().catch(() => {});
      return;
    }
    const t = e.target.closest("button, a"); if (!t) return;
    const d = t.dataset;
    if ("close" in d) { closeSheets(); if (t.tagName === "BUTTON") return; }
    if (d.range) { S.range = d.range; S.shown = PAGE; S.rows = []; document.querySelectorAll("[data-range]").forEach((b) => b.setAttribute("aria-selected", b === t)); render(); return; }
    if (d.cat !== undefined && t.classList.contains("chip")) { S.cat = d.cat || null; S.shown = PAGE; S.rows = []; renderChips(); render(); return; }
    if (d.morecat) { S.cat = d.morecat; S.range = "all"; S.rows = []; document.querySelectorAll("[data-range]").forEach((b) => b.setAttribute("aria-selected", b.dataset.range === "all")); renderChips(); location.hash = "#/"; return; }
    if ("more" in d) { S.shown += PAGE; render(); return; }
    if ("retry" in d) { render(); return; }
    if (d.vote) { vote(Number(d.id), Number(d.vote)); return; }
    if (d.react) { const id = Number(d.id); react(id, d.react, findRow(id) || { id, own: false }); return; }
    if (d.duel) { duelPick(Number(d.duel), Number(d.other)); return; }
    if ("duelSkip" in d) { duelPick(null, null); return; }
    if (d.authrange) { S.authorRange = d.authrange; render(); return; }
    if (d.hlDismiss) { store.set("hl_seen", [...store.get("hl_seen", []), d.hlDismiss].slice(-200)); S.hl = S.hl.filter((h) => `${h.kind}:${h.joke_id}:${h.value}` !== d.hlDismiss); drawListBanners(); return; }
    if ("challengeJoin" in d) { openPost(true); return; }
    if ("annDismiss" in d) { store.set("ann_hidden", S.announcement); drawListBanners(); return; }
    if (d.adminEdit) { S.editJoke = Number(d.adminEdit); drawAdminJokes(); return; }
    if ("adminEditCancel" in d) { S.editJoke = null; drawAdminJokes(); return; }
    if (d.adminHide || d.adminRestore || d.adminRemoveJ) {
      const id = Number(d.adminHide || d.adminRestore || d.adminRemoveJ); t.disabled = true;
      const job = d.adminHide ? API.adminBulkStatus(S.adminKey, [id], "hidden") : API.adminSet(S.adminKey, id, d.adminRestore ? "visible" : "removed");
      job.then(() => { toast(d.adminRestore ? "Wiederhergestellt." : d.adminHide ? "Ausgeblendet." : "Entfernt."); render(); }).catch((err) => { t.disabled = false; toast(errorText(err)); });
      return;
    }
    if (d.adminUser) { S.adminView = "nutzer"; S.adminUser = d.adminUser; window.scrollTo({ top: 0 }); render(); return; }
    if ("adminUserBack" in d) { S.adminUser = null; render(); return; }
    if (d.adminFind) { S.adminView = "witze"; S.adminUser = null; S.adminQ = { q: d.adminFind, cat: "", status: "", author: "", offset: 0 }; S.adminRowsPrev = []; window.scrollTo({ top: 0 }); render(); return; }
    if (d.usort) { S.userSort = d.usort; render(); return; }
    if (d.dashMetric) { S.dashMetric = d.dashMetric; document.querySelectorAll("[data-dash-metric]").forEach((b) => b.setAttribute("aria-pressed", b === t)); if (S.dash && $("#dashChart")) $("#dashChart").innerHTML = dashChartHtml(S.dash); return; }
    if ("logMore" in d) { S.logLimit = (S.logLimit || 50) + 50; render(); return; }
    if ("selAll" in d) { document.querySelectorAll(".sel-joke").forEach((c) => { c.checked = true; S.adminSel.add(Number(c.value)); }); drawBulkBar(); return; }
    if ("selNone" in d) { S.adminSel.clear(); document.querySelectorAll(".sel-joke").forEach((c) => { c.checked = false; }); drawBulkBar(); return; }
    if (d.bulk) { bulkApply(d.bulk, null, t); return; }
    if ("adminMore" in d) { S.adminQ.offset += 30; render(); return; }
    if (d.unban) { API.adminBan(S.adminKey, d.unban, false).then(() => { toast("Entsperrt."); render(); }).catch((err) => toast(errorText(err))); return; }
    if (d.wipe) {
      if (t.dataset.armed !== "1") { t.dataset.armed = "1"; t.textContent = "Wirklich alles entfernen? Nochmal tippen"; return; }
      t.disabled = true;
      API.adminRemoveUserContent(S.adminKey, d.wipe).then((n) => { toast(`${n} Beiträge entfernt.`); render(); }).catch((err) => { t.disabled = false; toast(errorText(err)); });
      return;
    }
    if ("exportCsv" in d) { exportCsv(t); return; }
    if (d.setRole) {
      const on = d.roleOn === "1";
      if (on && t.dataset.armed !== "1") { t.dataset.armed = "1"; t.textContent = "Wirklich vollen Admin-Zugriff geben? Nochmal tippen"; return; }
      API.adminSetRole(S.adminKey, d.setRole, on).then(() => { toast(on ? `@${d.setRole} ist jetzt Admin.` : `@${d.setRole} ist kein Admin mehr.`); render(); }).catch((err) => toast(errorText(err)));
      return;
    }
    if (d.sponsor) { API.sponsorClick(Number(d.sponsor)).catch(() => {}); return; }
    if (d.spEdit) { S.editSponsor = (S.adminSponsors || []).find((x) => x.id === Number(d.spEdit)) || null; render(); return; }
    if ("spNew" in d) { S.editSponsor = null; render(); return; }
    if (d.spDel) {
      if (t.dataset.armed !== "1") { t.dataset.armed = "1"; t.textContent = "Wirklich löschen? Nochmal tippen"; return; }
      API.adminDeleteSponsor(S.adminKey, Number(d.spDel)).then(() => { toast("Sponsor gelöscht."); S.editSponsor = null; render(); }).catch((err) => toast(errorText(err)));
      return;
    }
    if ("tvLink" in d) { if (d.sp && $("#tvSp")) $("#tvSp").value = d.sp; buildTvLink(); return; }
    if ("scrPre" in d) { const [bg, ac, card] = d.scrPre.split(","); $("#scrBg").value = "#" + bg; $("#scrAc").value = "#" + ac; $("#scrCard").value = "#" + card; updateScreen(); return; }
    if ("scrCopy" in d) { const u = $("#scrUrl").value; navigator.clipboard ? navigator.clipboard.writeText(u).then(() => toast("Link kopiert."), () => { $("#scrUrl").select(); }) : $("#scrUrl").select(); return; }
    if ("scrShort" in d) { screenShortLink(); return; }
    if ("cardOpen" in d) { const g = $("#gcard"); g.hidden = false; drawCard(); g.scrollIntoView({ behavior: "smooth", block: "start" }); return; }
    if (d.cardOcc) { GC.occ = d.cardOcc; document.querySelectorAll("[data-card-occ]").forEach((b) => b.setAttribute("aria-pressed", b === t)); drawCard(); return; }
    if ("cardShare" in d) { shareCard(); return; }
    if ("cardClose" in d) { $("#gcard").hidden = true; return; }
    if (d.searchTip) { $("#searchQ").value = d.searchTip; SR.q = d.searchTip; history.replaceState(null, "", "#/suche?q=" + encodeURIComponent(d.searchTip)); runSearch(null); return; }
    if ("pushMine" in d) { t.disabled = true; pushEnable([...new Set([...store.get("push_topics", ["daily"]), "mine"])]).then(() => { toast("Alles klar, wir melden uns!"); drawMinePush(); }, (e) => { t.disabled = false; toast(e.code === "push_denied" ? "Du hast die Benachrichtigungen nicht erlaubt." : errorText(e)); }); return; }
    if (d.quizOpt) { quizAnswer(Number(d.quizOpt)); return; }
    if ("quizNext" in d) { quizNext(); return; }
    if ("quizShare" in d) { quizShare(); return; }
    if (d.liveVote) { liveVote(Number(d.liveVote)); return; }
    if (d.grouprange) { S.groupRange = d.grouprange; render(); return; }
    if ("groupLogin" in d) { openAuth("signup", "Mit Konto kannst du Gruppen gründen und beitreten.", () => render()); return; }
    if (d.groupJoin) { groupJoin(d.groupJoin); return; }
    if (d.groupCopy) { navigator.clipboard ? navigator.clipboard.writeText(d.groupCopy).then(() => toast("Link kopiert."), () => {}) : toast(d.groupCopy); return; }
    if ("groupQr" in d) { const q = $("#groupQr"); if (q) q.hidden = !q.hidden; return; }
    if (d.groupLeave) { groupAction("leave_group", { p_code: d.groupLeave }, "Du hast die Gruppe verlassen."); return; }
    if (d.groupDelete) {
      if (t.dataset.armed !== "1") { t.dataset.armed = "1"; t.textContent = "Wirklich löschen? Nochmal tippen"; setTimeout(() => { if (t.isConnected) { t.dataset.armed = ""; t.textContent = "Gruppe löschen"; } }, 4000); return; }
      groupAction("manage_group", { p_code: d.groupDelete, p_action: "delete" }, "Gruppe gelöscht.", () => { location.hash = "#/gruppen"; }); return;
    }
    if (d.adminGroupDel) {
      if (t.dataset.armed !== "1") { t.dataset.armed = "1"; t.textContent = "Wirklich?"; return; }
      groupAction("admin_delete_group", { p_key: AK(), p_code: d.adminGroupDel }, "Gruppe gelöscht."); return;
    }
    if ("postOpen" in d) { openPost(false); return; }
    if ("spLogoClear" in d) { S.spLogo = ""; $("#spLogoPrev").innerHTML = ""; return; }
    if ("annClear" in d) { API.adminSetAnnouncement(S.adminKey, "").then(() => { S.announcement = null; toast("Ankündigung entfernt."); render(); }).catch((err) => toast(errorText(err))); return; }
    if ("punchLogin" in d) { openAuth("login", "Zum Mitmachen beim Pointen-Battle brauchst du ein Konto. Abstimmen geht auch ohne.", "battle"); return; }
    if ("install" in d) { doInstall(); return; }
    if ("pushOn" in d) { pushAction("on", t); return; }
    if ("pushSave" in d) { pushAction("save", t); return; }
    if ("pushOff" in d) { pushAction("off", t); return; }
    if ("pushTest" in d) { pushAction("test", t); return; }
    if (d.chEdit) { S.editChallenge = (S.challenges || []).find((c) => c.id === Number(d.chEdit)) || null; render(); return; }
    if ("chNew" in d) { S.editChallenge = null; render(); return; }
    if (d.swipe !== undefined) { decide(Number(d.swipe)); return; }
    if (d.report) { reportId = Number(d.report); reportKind = "joke"; openSheet("#reportSheet"); return; }
    if (d.reportPunch) { reportId = Number(d.reportPunch); reportKind = "punch"; openSheet("#reportSheet"); return; }
    if (d.approvePunch) { t.disabled = true; API.adminApprovePunch(S.adminKey, Number(d.approvePunch)).then(() => { toast("Freigegeben."); render(); }).catch((err) => { t.disabled = false; toast(errorText(err)); }); return; }
    if ("post" in d) { openPost(false); return; }
    if ("shareImage" in d) { shareImage(); return; }
    if ("shareLink" in d) { shareLink(); return; }
    if ("shareChannel" in d) { shareChannel(); return; }
    if (d.fav !== undefined) { toggleFav(d.fav); return; }
    if (d.pvote) { votePunch(Number(d.id), Number(d.pvote)); return; }
    if (d.rmPunch) { t.disabled = true; API.adminRemovePunchline(S.adminKey, Number(d.rmPunch)).then(() => { toast("Pointe entfernt."); render(); }).catch((err) => { t.disabled = false; toast(errorText(err)); }); return; }
    if (d.adminview) { S.adminView = d.adminview; S.adminUser = null; if (S.adminSel) S.adminSel.clear(); S.adminQ.offset = 0; S.adminRowsPrev = []; S.editJoke = null; if (d.author !== undefined) S.adminQ = { q: "", cat: "", status: "", author: d.author, offset: 0 }; window.scrollTo({ top: 0 }); render(); return; }
    if ("adminLogout" in d) { S.adminKey = null; session.set("admin", null); location.hash = "#/"; return; }
    if (d.approve || d.remove) {
      const id = Number(d.approve || d.remove);
      t.disabled = true;
      API.adminSet(S.adminKey, id, d.approve ? "visible" : "removed")
        .then(() => { toast(d.approve ? "Freigegeben." : "Entfernt."); render(); })
        .catch((err) => { t.disabled = false; toast(errorText(err)); });
      return;
    }
  });
  document.addEventListener("change", (e) => {
    if (e.target.id === "aqCat" || e.target.id === "aqStatus") $("#adminSearchForm").requestSubmit();
    if (e.target.classList.contains("sel-joke")) { const id = Number(e.target.value); if (e.target.checked) S.adminSel.add(id); else S.adminSel.delete(id); drawBulkBar(); }
    if (e.target.id === "bulkCatSel" && e.target.value) bulkApply(null, e.target.value, e.target);
    if (e.target.id === "apMode") { $("#apAtWrap").hidden = e.target.value !== "at"; if (e.target.value === "at" && !$("#apAt").value) { const x = new Date(Date.now() + 864e5); x.setMinutes(0, 0, 0); $("#apAt").value = new Date(x - x.getTimezoneOffset() * 6e4).toISOString().slice(0, 16); } }
    if (e.target.id === "spLogoFile" && e.target.files[0]) {
      shrinkLogo(e.target.files[0]).then((data) => {
        if (data.length > 140000) { $("#spErr").textContent = "Das Logo ist auch verkleinert noch zu groß. Bitte ein einfacheres Bild wählen."; return; }
        S.spLogo = data; $("#spLogoPrev").innerHTML = `<img src="${data}" alt=""><button type="button" class="link" data-sp-logo-clear>Logo entfernen</button>`;
      }).catch(() => { $("#spErr").textContent = "Das Bild konnte nicht gelesen werden."; });
    }
  });
  $("#reportConfirm").addEventListener("click", async () => {
    const id = reportId; closeSheets();
    if (reportKind === "punch") {
      store.set("hidden_punch", [...store.get("hidden_punch", []), id].slice(-300));
      try { await API.reportPunch(id); toast("Gemeldet. Danke!"); } catch (e) { toast(errorText(e)); }
      battleCache = null; render(); return;
    }
    S.hiddenForMe.add(id); store.set("hidden", [...S.hiddenForMe]);
    try { await API.report(id); toast("Gemeldet. Danke!"); } catch (e) { toast(errorText(e)); }
    S.rows = S.rows.filter((j) => j.id !== id);
    if (route().view === "detail") location.hash = "#/"; else render();
  });
  /* ───────── Anmelden, Registrieren, Passwort ───────── */
  let authMode = "login", afterLogin = null;
  function openAuth(mode, reason, next) {
    authMode = mode; afterLogin = next || null;
    $("#authReason").textContent = reason || "Lesen, Liken und Bewerten geht auch ohne Konto. Zum Posten brauchst du eins.";
    $("#authErr").textContent = ""; $("#authOk").hidden = true; $("#authFields").hidden = false;
    drawAuthMode(); openSheet("#authSheet");
  }
  function drawAuthMode() {
    const titles = { login: "Anmelden", signup: "Registrieren", forgot: "Passwort vergessen" };
    $("#authTitle").textContent = titles[authMode];
    $("#authTabs").hidden = authMode === "forgot";
    document.querySelectorAll("[data-authmode]").forEach((b) => b.setAttribute("aria-selected", b.dataset.authmode === authMode));
    $("#authNameRow").hidden = authMode !== "signup";
    $("#authConsentRow").hidden = authMode !== "signup";
    $("#authPwRow").hidden = authMode === "forgot";
    $("#authPw").autocomplete = authMode === "signup" ? "new-password" : "current-password";
    $("#forgotBtn").hidden = authMode !== "login";
    $("#authSubmit").textContent = { login: "Anmelden", signup: "Konto erstellen", forgot: "Link schicken" }[authMode];
    $("#authDemo").hidden = LIVE;
  }
  $("#who").addEventListener("click", () => {
    if (!AUTH) { openAuth("login"); return; }
    $("#accountInfo").textContent = `Angemeldet als @${AUTH.username || "…"}${AUTH.email ? " (" + AUTH.email + ")" : ""}.`;
    $("#accountPw").hidden = !LIVE;
    $("#accountProfile").href = "#/u/" + encodeURIComponent(AUTH.username || "");
    openSheet("#accountSheet");
  });
  $("#authForm").addEventListener("click", (e) => {
    const b = e.target.closest("[data-authmode]");
    if (b) { authMode = b.dataset.authmode; $("#authErr").textContent = ""; drawAuthMode(); }
  });
  $("#forgotBtn").addEventListener("click", () => { authMode = "forgot"; $("#authErr").textContent = ""; drawAuthMode(); });
  $("#authForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const name = $("#authName").value.trim(), email = $("#authEmail").value.trim(), pw = $("#authPw").value, err = $("#authErr");
    err.textContent = "";
    if (authMode === "signup" && !USERNAME_RE.test(name)) { err.textContent = ERRORS.invalid_username; return; }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) { err.textContent = ERRORS.invalid_email; return; }
    if (authMode !== "forgot" && pw.length < (authMode === "signup" ? 8 : 1)) { err.textContent = ERRORS.password_short; return; }
    if (authMode === "signup" && !$("#authConsent").checked) { err.textContent = ERRORS.consent_missing; return; }
    const btn = $("#authSubmit"), label = btn.textContent; btn.disabled = true; btn.textContent = "Einen Moment …";
    try {
      if (authMode === "login") {
        await AUTH_API.signIn(email, pw);
        closeSheets(); toast(`Hallo @${AUTH.username}!`); render();
        if (typeof afterLogin === "function") afterLogin();
        if (afterLogin === "battle") location.hash = "#/battle";
        if (afterLogin === "post" || afterLogin === "challenge") openPost(afterLogin === "challenge");
      } else if (authMode === "signup") {
        const r = await AUTH_API.signUp(name, email, pw);
        if (r.confirmed) { closeSheets(); toast(`Willkommen, @${AUTH.username}!`); render(); if (typeof afterLogin === "function") afterLogin(); if (afterLogin === "battle") location.hash = "#/battle"; if (afterLogin === "post" || afterLogin === "challenge") openPost(afterLogin === "challenge"); }
        else { $("#authFields").hidden = true; $("#authOk").hidden = false; $("#authOk").textContent = `Fast geschafft: Wir haben dir eine E-Mail an ${email} geschickt. Klick auf den Link darin, dann bist du angemeldet. Schau auch im Spam-Ordner nach.`; }
      } else {
        await AUTH_API.recover(email);
        $("#authFields").hidden = true; $("#authOk").hidden = false;
        $("#authOk").textContent = LIVE ? `Falls es ein Konto mit ${email} gibt, ist jetzt eine E-Mail mit einem Link zum Zurücksetzen unterwegs.` : "Im Demo-Modus gibt es keine Passwörter. Melde dich einfach mit deiner E-Mail an.";
      }
    } catch (ex) { err.textContent = errorText(ex); }
    finally { btn.disabled = false; btn.textContent = label; }
  });
  $("#accountDelete").addEventListener("click", () => {
    closeSheets(); $("#delErr").textContent = ""; $("#delName").value = ""; $("#delContent").checked = false;
    $("#delHint").textContent = `Zur Bestätigung gib deinen Benutzernamen ein: ${AUTH ? AUTH.username : ""}`;
    openSheet("#deleteSheet");
  });
  $("#deleteForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    if (!AUTH) { closeSheets(); return; }
    if ($("#delName").value.trim().toLowerCase() !== (AUTH.username || "").toLowerCase()) { $("#delErr").textContent = "Der Benutzername stimmt nicht."; return; }
    const btn = $("#deleteForm .btn.danger"); btn.disabled = true;
    try {
      await API.deleteAccount($("#delContent").checked);
      setAuth(null); closeSheets(); toast("Dein Konto wurde gelöscht."); S.rows = []; location.hash = "#/"; render();
    } catch (ex) { $("#delErr").textContent = errorText(ex); }
    finally { btn.disabled = false; }
  });
  $("#logoutBtn").addEventListener("click", async () => { await AUTH_API.signOut(); closeSheets(); toast("Abgemeldet."); render(); });
  $("#accountPw").addEventListener("click", () => { closeSheets(); $("#pwErr").textContent = ""; openSheet("#pwSheet"); });
  $("#pwForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const a = $("#pwNew").value, b = $("#pwNew2").value, err = $("#pwErr");
    if (a.length < 8) { err.textContent = ERRORS.password_short; return; }
    if (a !== b) { err.textContent = ERRORS.password_mismatch; return; }
    try { await AUTH_API.updatePassword(a); $("#pwNew").value = $("#pwNew2").value = ""; closeSheets(); toast("Neues Passwort gespeichert."); }
    catch (ex) { err.textContent = errorText(ex); }
  });
  async function openPost(forChallenge) {
    if (!AUTH) { openAuth("login", "Zum Posten brauchst du ein Konto. Lesen, Liken und Bewerten geht auch ohne.", forChallenge ? "challenge" : "post"); return; }
    $("#postAs").textContent = AUTH.banned ? ERRORS.banned : `Du postest als @${AUTH.username}.`;
    $("#postErr").textContent = "";
    showDup(null); checkSimilar();
    openSheet("#postSheet");
    await loadChallenge();
    const c = activeChallenge();
    $("#postChallengeRow").hidden = !c;
    if (c) { $("#postChallengeName").textContent = c.title; $("#postChallenge").checked = !!forChallenge || route().view === "challenge"; }
  }
  $("#postBtn").addEventListener("click", () => openPost(false));
  $("#postCat").innerHTML = Object.entries(CATS).map(([k, v]) => `<option value="${k}">${v}</option>`).join("");
  $("#postText").addEventListener("input", checkSimilar);
  // Bildschirm-Link: jede Änderung sofort in Link und Vorschau übernehmen
  document.addEventListener("input", (e) => {
    if (e.target.id === "searchQ") { searchInput(e.target.value); return; }
    if (e.target.id === "gcTo" || e.target.id === "gcFrom") { GC.to = $("#gcTo").value.trim(); GC.from = $("#gcFrom").value.trim(); drawCard(); return; }
    if (!e.target.closest || !e.target.closest(".scr-form")) return;
    if (e.target.type === "color") $("#" + e.target.id.slice(0, -1)).value = e.target.value;
    updateScreen();
  });
  $("#postForm").addEventListener("submit", async (e) => {
    e.preventDefault();
    const text = $("#postText").value.trim(), cat = $("#postCat").value, err = $("#postErr");
    if (text.length < 10 || text.length > 500) { err.textContent = ERRORS.invalid_body; return; }
    const btn = $("#postSubmit"); btn.disabled = true; btn.textContent = "Wird veröffentlicht …"; err.textContent = "";
    try {
      const c = activeChallenge();
      const id = await API.post(cat, text, c && !$("#postChallengeRow").hidden && $("#postChallenge").checked ? c.id : null);
      S.challenges = null;
      $("#postText").value = ""; closeSheets();
      S.rows = []; S.range = "day"; S.cat = null;
      document.querySelectorAll("[data-range]").forEach((b) => b.setAttribute("aria-selected", b.dataset.range === "day")); renderChips();
      location.hash = "#/witz/" + id;
      toast("Veröffentlicht. Teil ihn, damit er Stimmen bekommt!");
    } catch (ex) {
      if (ex.code === "duplicate") { showDup({ id: ex.duplicateId }); }
      else if (ex.code === "not_logged_in") { setAuth(null); closeSheets(); openAuth("login", ERRORS.not_logged_in, "post"); }
      else err.textContent = errorText(ex);
    } finally { btn.textContent = "Veröffentlichen"; btn.disabled = !$("#dupBox").hidden; }
  });
  document.addEventListener("submit", async (e) => {
    if (e.target.id === "searchForm") { e.preventDefault(); clearTimeout(SR.timer); SR.q = $("#searchQ").value; history.replaceState(null, "", "#/suche?q=" + encodeURIComponent(SR.q.trim())); $("#searchQ").blur(); runSearch(null); return; }
    if (e.target.id === "groupCreate" || e.target.id === "groupJoin") {
      e.preventDefault();
      const create = e.target.id === "groupCreate", err = $(create ? "#groupCreateErr" : "#groupJoinErr"), btn = e.target.querySelector("button");
      err.textContent = ""; btn.disabled = true;
      try {
        if (create) { const code = await rpc("create_group", { p_name: $("#groupName").value }); toast("Gruppe gegründet! Jetzt Leute einladen."); location.hash = "#/gruppe/" + code; }
        else { const code = $("#groupCode").value.replace(/[^0-9a-z]/gi, "").toUpperCase(); const name = await rpc("join_group", { p_code: code }); toast(`Willkommen in „${name}“!`); location.hash = "#/gruppe/" + code; }
      } catch (ex) { err.textContent = errorText(ex); btn.disabled = false; }
      return;
    }
    if (e.target.dataset && e.target.dataset.groupManage) {
      e.preventDefault();
      const code = route().code, act = e.target.dataset.groupManage, v = e.target.querySelector("input").value;
      groupAction("manage_group", { p_code: code, p_action: act, p_value: v }, act === "rename" ? "Name geändert." : "Mitglied entfernt.");
      return;
    }
    if (e.target.id === "bulkForm") {
      e.preventDefault();
      const bodies = $("#bulkText").value.split(/\n\s*\n/).map((x) => x.trim()).filter(Boolean);
      if (!bodies.length) { $("#bulkErr").textContent = "Bitte mindestens einen Witz eingeben."; return; }
      const btn = e.target.querySelector("button"); btn.disabled = true;
      try { const r = await API.adminBulkAdd(S.adminKey, $("#bulkCat").value, bodies, Number($("#bulkPer").value) || 3); toast(`${r.inserted} eingeplant${r.skipped ? `, ${r.skipped} übersprungen (doppelt oder zu kurz)` : ""}.`); render(); }
      catch (ex) { $("#bulkErr").textContent = errorText(ex); btn.disabled = false; }
      return;
    }
    if (e.target.id === "adminSearchForm") {
      e.preventDefault();
      S.adminQ = { q: $("#aqText").value.trim(), cat: $("#aqCat").value, status: $("#aqStatus").value, author: $("#aqAuthor").value.trim(), offset: 0 };
      S.adminRowsPrev = []; S.editJoke = null; render(); return;
    }
    if (e.target.id === "editJokeForm") {
      e.preventDefault();
      const id = Number(e.target.dataset.id);
      try { await API.adminUpdateJoke(S.adminKey, id, $("#ejText").value.trim(), $("#ejCat").value); S.editJoke = null; toast("Gespeichert."); S.adminQ.offset = 0; S.adminRowsPrev = []; render(); }
      catch (ex) { $("#ejErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "ownerKeyForm") {
      e.preventDefault();
      const key = $("#ownerKey").value.trim();
      // Prüft den Schlüssel, ohne etwas zu ändern: bei richtigem Schlüssel kommt „Nutzer gibt es nicht“
      try { await API.adminSetRole(key, "__schluessel_pruefen__", false); }
      catch (ex) {
        if (ex.code === "user_not_found") { S.adminKey = key; session.set("admin", key); toast("Freigeschaltet. Du kannst jetzt Admins ernennen."); render(); }
        else $("#ownerErr").textContent = ex.code === "owner_only" ? "Der Admin-Schlüssel stimmt nicht." : errorText(ex);
      }
      return;
    }
    if (e.target.id === "adminPostForm") {
      e.preventDefault();
      const mode = $("#apMode").value, at = mode === "at" && $("#apAt").value ? new Date($("#apAt").value).toISOString() : null, btn = e.target.querySelector("button");
      if (mode === "at" && !at) { $("#apErr").textContent = "Bitte einen Zeitpunkt wählen."; return; }
      btn.disabled = true;
      try {
        const when = await API.adminPostJoke(S.adminKey, $("#apCat").value, $("#apText").value, mode, at);
        S.postOpen = false; S.adminQ.offset = 0; S.adminRowsPrev = [];
        toast(mode === "now" ? "Veröffentlicht." : `Eingeplant für ${new Date(when).toLocaleString("de-DE", { weekday: "short", day: "numeric", month: "numeric", hour: "2-digit", minute: "2-digit" })} Uhr.`);
        render();
      } catch (ex) { btn.disabled = false; $("#apErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "noteForm") {
      e.preventDefault();
      try { await API.adminSetNote(S.adminKey, e.target.dataset.name, $("#noteText").value); toast("Notiz gespeichert."); render(); }
      catch (ex) { $("#noteErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "userSearchForm") { e.preventDefault(); S.adminUserQ = $("#uqText").value.trim(); render(); return; }
    if (e.target.classList.contains("ban-form")) {
      e.preventDefault();
      const name = e.target.dataset.name, reason = e.target.querySelector("input").value.trim();
      try { await API.adminBan(S.adminKey, name, true, reason); toast(`@${name} ist gesperrt.`); render(); } catch (ex) { toast(errorText(ex)); }
      return;
    }
    if (e.target.id === "sponsorForm") {
      e.preventDefault();
      const x = { id: S.editSponsor && S.editSponsor.id, name: $("#spName").value.trim(), claim: $("#spClaim").value.trim(), url: $("#spUrl").value.trim(), logo: S.spLogo || "",
        placement: $("#spPlace").value, starts: new Date($("#spStart").value).toISOString(), ends: new Date($("#spEnd").value).toISOString() };
      if (x.name.length < 2) { $("#spErr").textContent = "Bitte einen Namen eingeben."; return; }
      if (x.url && !/^https?:\/\//.test(x.url)) { $("#spErr").textContent = "Der Link muss mit https:// beginnen."; return; }
      if (!(new Date(x.ends) > new Date(x.starts))) { $("#spErr").textContent = "Das Ende muss nach dem Start liegen."; return; }
      try { await API.adminSaveSponsor(S.adminKey, x); S.editSponsor = null; S.sponsors = null; sponsorLoad = null; toast("Sponsor gespeichert."); render(); }
      catch (ex) { $("#spErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "contactForm") {
      e.preventDefault();
      const v = $("#contactEmail").value.trim();
      try { await API.adminSetContact(S.adminKey, v); toast(v ? "Kontakt gespeichert." : "Kontakt entfernt."); } catch (ex) { $("#contactErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "annForm") {
      e.preventDefault();
      const text = $("#annText").value.trim();
      try { await API.adminSetAnnouncement(S.adminKey, text); S.announcement = null; toast(text ? "Ankündigung gespeichert." : "Ankündigung entfernt."); render(); }
      catch (ex) { $("#annErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "promptForm") {
      e.preventDefault();
      const lines = $("#promptText").value.split("\n").map((x) => x.trim()).filter(Boolean);
      if (!lines.length) { $("#promptErr").textContent = "Bitte mindestens einen Anfang eingeben."; return; }
      try { const n = await API.adminAddPrompts(S.adminKey, lines); toast(`${n} hinzugefügt${lines.length - n ? `, ${lines.length - n} übersprungen (doppelt oder zu kurz)` : ""}.`); render(); }
      catch (ex) { $("#promptErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "filterForm") {
      e.preventDefault();
      const words = $("#filterText").value.split(/[\n,]/).map((x) => x.trim().toLowerCase()).filter(Boolean);
      try { const n = await API.adminSetWords(S.adminKey, words); toast(`${n} Wörter gespeichert.`); render(); }
      catch (ex) { $("#filterErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id === "punchForm") {
      e.preventDefault();
      submitPunch();
      return;
    }
    if (e.target.id === "challengeForm") {
      e.preventDefault();
      const c = { id: S.editChallenge && S.editChallenge.id, title: $("#chTitle").value.trim(), description: $("#chDesc").value.trim(), starts: new Date($("#chStart").value).toISOString(), ends: new Date($("#chEnd").value).toISOString() };
      if (c.title.length < 3) { $("#chErr").textContent = "Das Thema braucht mindestens 3 Zeichen."; return; }
      if (!(new Date(c.ends) > new Date(c.starts))) { $("#chErr").textContent = "Das Ende muss nach dem Start liegen."; return; }
      try { await API.adminSaveChallenge(S.adminKey, c); S.editChallenge = null; S.challenges = null; toast("Challenge gespeichert."); render(); }
      catch (ex) { $("#chErr").textContent = errorText(ex); }
      return;
    }
    if (e.target.id !== "adminForm") return;
    e.preventDefault();
    const key = $("#adminKey").value.trim();
    try {
      if (await API.adminCheck(key)) { S.adminKey = key; session.set("admin", key); render(); }
      else $("#adminErr").textContent = ERRORS.not_admin;
    } catch (ex) { $("#adminErr").textContent = errorText(ex); }
  });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") { closeSheets(); return; }
    if (document.querySelector(".scrim:not([hidden])")) return;
    if (e.target.closest && e.target.closest("input, textarea, select")) return;
    if (route().view === "quiz") {
      if (["1", "2", "3"].includes(e.key) && document.querySelector(`[data-quiz-opt="${e.key}"]:not([disabled])`)) { e.preventDefault(); quizAnswer(Number(e.key)); }
      else if ((e.key === "Enter" || e.key === "ArrowRight") && document.querySelector("[data-quiz-next]")) { e.preventDefault(); quizNext(); }
      return;
    }
    if (route().view === "duel") {
      const cards = document.querySelectorAll(".duel-card");
      if ((e.key === "1" || e.key === "2") && cards.length === 2) { e.preventDefault(); const w = cards[Number(e.key) - 1]; duelPick(Number(w.dataset.duel), Number(w.dataset.other)); }
      else if (e.key === "ArrowDown") { e.preventDefault(); duelPick(null, null); }
      return;
    }
    if (route().view !== "swipe") return;
    if (e.key === "ArrowRight") { e.preventDefault(); decide(1); }
    else if (e.key === "ArrowLeft") { e.preventDefault(); decide(-1); }
    else if (e.key === "ArrowDown") { e.preventDefault(); decide(0); }
  });
  window.addEventListener("hashchange", () => {
    if (LIVE && /access_token=|error_description=/.test(location.hash)) { handleAuthLink(); return; } // Link aus der E-Mail im selben Tab
    window.scrollTo({ top: 0 }); if (route().view === "swipe") { S.queue = []; S.seen = new Set(); S.rated = 0; S.swipeDone = false; } render();
  });

  $("#demoBanner").hidden = LIVE;
  renderChips();
  function handleAuthLink() {
    return (LIVE ? handleAuthRedirect() : Promise.resolve(null)).then((r) => {
      render();
      if (!r) return;
      closeSheets();
      if (r.error) { toast("Der Link ist abgelaufen oder ungültig. Melde dich an oder fordere einen neuen an."); openAuth("login"); }
      else if (r.type === "recovery") { $("#pwErr").textContent = ""; openSheet("#pwSheet"); toast("Lege jetzt ein neues Passwort fest."); }
      else toast(`E-Mail bestätigt. Willkommen, @${AUTH ? AUTH.username : ""}!`);
    }).catch(() => render());
  }
  applySeason();
  handleAuthLink();

  // Installierbar machen und offline anzeigen (nur über https oder localhost)
  if ("serviceWorker" in navigator && (location.protocol === "https:" || location.hostname === "localhost")) {
    window.addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
  }
})();
