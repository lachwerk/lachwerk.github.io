// Lachwerk – Edge Function „push“: verschickt Push-Nachrichten (Web Push).
// Im Supabase-Dashboard unter Edge Functions als „push“ anlegen und „Verify JWT“ ausschalten.
//
// Aufrufe (POST, JSON):
//   {"type":"setup"}                 Schlüssel anlegen (falls nötig), öffentlichen Schlüssel zurückgeben
//   {"type":"daily"}                 Witz des Tages an alle Abos mit Thema „daily“ (ab 20 Uhr, einmal pro Tag)
//   {"type":"battle"}                Neues Pointen-Battle an Thema „battle“ (ab 12 Uhr, einmal pro Tag)
//   {"type":"test","endpoint":"…"}   Test-Nachricht an genau ein Abo
// Jeder Versand läuft höchstens einmal pro Tag, wiederholte Aufrufe schaden nicht.
import { createClient } from "npm:@supabase/supabase-js@2.45.4";
import webpush from "npm:web-push@3.6.7";

const SITE = "https://lachwerk.github.io/";
// Server-Schlüssel: neue „secret“-Keys (SUPABASE_SECRET_KEYS) oder der klassische service_role-Key
function serverKey(): string {
  try { const k = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"); const v = Object.values(k)[0]; if (typeof v === "string" && v) return v; } catch { /* weiter */ }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
}
const sb = createClient(Deno.env.get("SUPABASE_URL")!, serverKey(), { auth: { persistSession: false } });
const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info", "Access-Control-Allow-Methods": "POST, OPTIONS" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });

async function getSetting(key: string): Promise<string | null> {
  const { data } = await sb.from("settings").select("value").eq("key", key).maybeSingle();
  return data?.value ?? null;
}
async function setSetting(key: string, value: string) {
  const { error } = await sb.from("settings").upsert({ key, value });
  if (error) throw error;
}

// VAPID-Schlüssel: beim ersten Mal erzeugen und in der Datenbank ablegen
async function initKeys(): Promise<string> {
  let pub = await getSetting("vapid_public");
  let priv = await getSetting("vapid_private");
  if (!pub || !priv) {
    const k = webpush.generateVAPIDKeys();
    await setSetting("vapid_private", k.privateKey);
    await setSetting("vapid_public", k.publicKey);
    pub = k.publicKey; priv = k.privateKey;
  }
  const contact = (await getSetting("contact_email")) || "noreply@lachwerk.github.io";
  webpush.setVapidDetails("mailto:" + contact, pub, priv);
  return pub;
}

// Uhrzeit und Datum in Deutschland
function berlin() {
  const s = new Date().toLocaleString("sv-SE", { timeZone: "Europe/Berlin" }); // "2026-10-25 20:05:00"
  return { day: s.slice(0, 10), hour: Number(s.slice(11, 13)) };
}

type Sub = { endpoint: string; p256dh: string; auth: string; fails: number };
async function sendAll(subs: Sub[], payload: Record<string, unknown>) {
  let ok = 0, gone = 0, failed = 0;
  const body = JSON.stringify(payload);
  for (let i = 0; i < subs.length; i += 25) {
    await Promise.all(subs.slice(i, i + 25).map(async (s) => {
      try {
        await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, body, { TTL: 6 * 3600, urgency: "normal" });
        ok++;
        await sb.from("push_subscriptions").update({ last_sent: new Date().toISOString(), fails: 0 }).eq("endpoint", s.endpoint);
      } catch (e) {
        const code = (e as { statusCode?: number }).statusCode;
        if (code === 404 || code === 410 || s.fails >= 4) { gone++; await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint); }
        else { failed++; await sb.from("push_subscriptions").update({ fails: s.fails + 1 }).eq("endpoint", s.endpoint); }
      }
    }));
  }
  return { ok, gone, failed };
}
const short = (t: string, n = 170) => (t.length > n ? t.slice(0, n - 1) + "…" : t);

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  let input: { type?: string; endpoint?: string } = {};
  try { input = await req.json(); } catch { /* leer */ }
  try {
    const pub = await initKeys();
    const { day, hour } = berlin();

    if (input.type === "setup") return json({ publicKey: pub });

    if (input.type === "test") {
      if (!input.endpoint) return json({ error: "endpoint fehlt" }, 400);
      const { data } = await sb.from("push_subscriptions").select("endpoint, p256dh, auth, fails").eq("endpoint", input.endpoint);
      if (!data || !data.length) return json({ error: "Abo nicht gefunden" }, 404);
      const r = await sendAll(data as Sub[], { title: "🎉 Push-Nachrichten sind an", body: "So sieht es aus, wenn der Witz des Tages gekrönt wird.", url: SITE + "#/highlights" });
      return json({ sent: r });
    }

    if (input.type === "daily") {
      if (hour < 20) return json({ skipped: "vor 20 Uhr" });
      if ((await getSetting("push_last_daily")) === day) return json({ skipped: "heute schon verschickt" });
      await sb.rpc("crown_pending");
      const { data: w } = await sb.from("daily_winners").select("day, joke_id").order("day", { ascending: false }).limit(1).maybeSingle();
      if (!w || w.day !== day) return json({ skipped: "heute kein Witz des Tages" });
      const { data: j } = await sb.from("jokes").select("id, body, author_user, author_name").eq("id", w.joke_id).single();
      await setSetting("push_last_daily", day);   // vor dem Versand setzen: kein doppelter Versand bei parallelen Aufrufen
      const { data: subs } = await sb.from("push_subscriptions").select("endpoint, p256dh, auth, fails, user_id, topics");
      const all = (subs || []) as (Sub & { user_id: string | null; topics: string[] })[];
      const mine = all.filter((s) => j.author_user && s.user_id === j.author_user && s.topics.includes("mine"));
      const rest = all.filter((s) => s.topics.includes("daily") && !mine.includes(s));
      const url = SITE + "#/witz/" + j.id;
      const r1 = await sendAll(rest, { title: "👑 Der Witz des Tages ist da", body: short(j.body.replace(/\n/g, " ")), url });
      const r2 = await sendAll(mine, { title: "👑 Dein Witz ist Witz des Tages!", body: short(j.body.replace(/\n/g, " ")), url });
      return json({ daily: r1, mine: r2 });
    }

    if (input.type === "battle") {
      if (hour < 12) return json({ skipped: "vor 12 Uhr" });
      if ((await getSetting("push_last_battle")) === day) return json({ skipped: "heute schon verschickt" });
      const { data: b } = await sb.rpc("get_battle_today");
      const prompt = Array.isArray(b) ? b[0] : b;
      if (!prompt) return json({ skipped: "heute kein Battle" });
      await setSetting("push_last_battle", day);
      const { data: subs } = await sb.from("push_subscriptions").select("endpoint, p256dh, auth, fails").contains("topics", ["battle"]);
      const r = await sendAll((subs || []) as Sub[], { title: "🥊 Neues Pointen-Battle", body: short(prompt.setup) + " Deine Pointe?", url: SITE + "#/battle" });
      return json({ battle: r });
    }

    return json({ error: "unbekannter type" }, 400);
  } catch (e) {
    console.error(e);
    return json({ error: String((e as Error).message || e) }, 500);
  }
});
