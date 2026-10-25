# Lachwerk

Witze-Web-App: Lesen, Liken und Bewerten im Swipe-Modus geht **ohne Konto**. Zum **Posten** registriert man sich mit E-Mail und Passwort.
Rankings für **Heute**, **Woche** und **Alltime**. Reine HTML/CSS/JS-Dateien, kein Build-Schritt.

## In 5 Minuten online (Demo-Modus)

1. Auf github.com ein neues Repository anlegen, z. B. `lachwerk` (öffentlich).
2. **Add file → Upload files** und alle Dateien aus diesem Ordner hineinziehen. Danach **Commit changes**.
3. **Settings → Pages → Build and deployment**: Source *Deploy from a branch*, Branch *main*, Ordner */ (root)*, **Save**.
4. Nach ca. 1 Minute ist die Seite erreichbar unter `https://lachwerk.github.io/`.

Im Demo-Modus läuft alles sofort mit 360 Startwitzen. Jeden Tag erscheint unter „Heute“ automatisch eine neue Auswahl. Stimmen und neue Witze bleiben aber **nur im Browser des jeweiligen Besuchers**.
Zum Ausprobieren reicht das. Für eine echte Community schaltest du den Live-Modus ein.

## Live schalten: gemeinsame Witze und Stimmen (ca. 10 Minuten)

GitHub Pages kann nur Dateien ausliefern und nichts speichern. Die Daten liegen deshalb in **Supabase** (kostenloser Plan reicht für den Start).

1. Auf [supabase.com](https://supabase.com) ein Projekt anlegen. Region: **Central EU (Frankfurt)**.
2. Im Projekt **SQL Editor → New query**, den kompletten Inhalt von `supabase.sql` einfügen und **Run** klicken.
   Das legt Tabellen, Schutzregeln und die 360 Startwitze an. Sie sind über 35 Tage vorgeplant:
   Jeden Tag erscheinen etwa 10 neue, damit „Heute“ auch ohne Beiträge von Besuchern gefüllt ist.
3. Admin-Schlüssel für die Moderation setzen (mindestens 12 Zeichen, gut merken):
   ```sql
   select public.set_admin_key('hier-dein-geheimer-schluessel');
   ```
4. Unter **Project Settings → API** (bzw. **API Keys**) die **Project URL** und den **anon / publishable** Key kopieren.
5. In GitHub die Datei `config.js` öffnen, auf den Stift klicken, beide Werte eintragen, **Commit changes**:
   ```js
   window.LACHWERK_CONFIG = {
     supabaseUrl: "https://abcdefgh.supabase.co",
     supabaseAnonKey: "eyJhbGciOi...",
   };
   ```
   Der anon-Key ist öffentlich und darf dort stehen. Den **service_role / secret** Key niemals eintragen.

6. Unter **Authentication → URL Configuration**:
   - **Site URL:** `https://lachwerk.github.io/`
   - **Redirect URLs:** dieselbe Adresse hinzufügen
   Dorthin führen die Links in den Bestätigungs- und Passwort-E-Mails.
7. Optional: Unter **Authentication → Emails** die Texte der E-Mails auf Deutsch anpassen.
   Der eingebaute E-Mail-Versand von Supabase schafft nur wenige E-Mails pro Stunde. Für mehr Nutzer unter **Authentication → SMTP** einen eigenen Versand eintragen (z. B. Brevo, kostenlos bis 300/Tag).

Nach etwa einer Minute ist die Seite live. Der gelbe Demo-Hinweis unten verschwindet.

## Weitere Witze nachladen

Du hast `supabase.sql` schon früher ausgeführt? Dann führe im SQL Editor `weitere_witze.sql` aus.
Es kommen bis zu 210 neue Witze dazu. Witze, die es schon gibt, werden übersprungen. Mehrfach ausführen ist unschädlich.
Bei einer Neueinrichtung brauchst du die Datei nicht, `supabase.sql` enthält bereits alle 360.

### Zusätzliche Witz-Pakete

- `ruhrpott_witze.sql`: 25 Witze im Ruhrpott-Stil, erscheinen nach und nach über rund 10 Tage
- `schwarzer_humor.sql`: Kategorie „Schwarzer Humor“ mit 17 Witzen, erscheinen über rund 9 Tage
- `einzeiler.sql`: Kategorie „Einzeiler“ mit 30 kurzen Witzen, erscheinen über rund 12 Tage
- `chef_sprueche.sql`: 25 Chef-Sprüche in der Kategorie „Büro“, erscheinen über rund 8 Tage
- `top_witze.sql`: 117 der beliebtesten deutschen Witze aus dem Netz (nacherzählt), alle sofort sichtbar
- `neue_witze_oktober.sql`: 31 neue Witze (u. a. Fitness), 10 sofort, der Rest alle 6 Stunden

Jeweils im SQL Editor ausführen. Vorhandene Witze werden übersprungen.

## Funktionen der Erweiterung

Für eine schon eingerichtete Datenbank einmal `erweiterung.sql` im SQL Editor ausführen (bei Neueinrichtung steckt sie in `supabase.sql`).

| Funktion | So funktioniert es |
|---|---|
| Witz des Tages | Jeden Abend um 20 Uhr (deutsche Zeit) wird der beste Witz der letzten 24 Stunden gekrönt. Ohne Zeitplan: Die Krönung passiert beim nächsten Seitenaufruf danach. Zu sehen unter `#/highlights`, das Story-Bild trägt dann die Krone. |
| Reaktionen | 😂 🙄 💀 unter jedem Witz, eine pro Gerät. Daraus: „Lacher“, „Größter Seufzer“ und „Schwärzester“ der Woche. |
| Duell | `#/duell`: zwei Witze, einer gewinnt. Eigene Elo-Wertung, beeinflusst das normale Ranking nicht. Duell-Champions ab 5 Duellen. |
| Autoren | `#/autoren`: Witzbold der Woche und Alltime (Wilson-Score über alle Stimmen eines Autors, mind. 5 bzw. 20 Stimmen). |
| Profile | `#/u/NAME`: Witze, Likes, Lacher-Quote und Abzeichen. Erreichbar über den Namen unter jedem Witz. |
| Hinweise | Angemeldete Autoren sehen oben in der Bestenliste, wenn ihr Witz in den Top 3 ist, gekrönt wurde oder 10/25/50/100 … Likes geknackt hat. |
| Serie | Wer an mehreren Tagen in Folge bewertet, sammelt eine Serie (🔥) mit Abzeichen nach 3, 7 und 30 Tagen. Nur im Browser gespeichert. |
| Challenge | Wochenthema mit eigener Rangliste unter `#/challenge`. Beim Posten ankreuzen. Neue Challenges legst du unter `#/admin` → Challenge an. |
| Statistik | `#/admin` → Statistik: Besucher (abstimmende Geräte), Stimmen, Reaktionen, Duelle, neue Witze und Konten pro Tag. |
| Vorrat | `#/admin` → Vorrat: Witze einfügen (Leerzeile trennt Witze), Anzahl pro Tag wählen, fertig. Sie erscheinen nach und nach. |
| App | Installierbar (PWA): Symbol auf dem Startbildschirm, Kurzbefehle, funktioniert auch bei Funkloch. |
| Google | `witze/` enthält statische Seiten je Kategorie, dazu `sitemap.xml` und `robots.txt`. Bei Google Search Console die Sitemap einreichen. |

### Erweiterung 2 (`erweiterung2.sql`, bei Neueinrichtung in `supabase.sql` enthalten)

| Funktion | So funktioniert es |
|---|---|
| Pointen-Battle | `#/battle`: Jeden Tag ein Witzanfang ohne Pointe. Angemeldete schreiben bis zu 3 Pointen, alle stimmen ab. Neue Anfänge unter `#/admin` → Battle (einer pro Zeile). |
| Monats-Saison | `#/autoren` → Saison: Rangliste des Kalendermonats (mind. 10 Stimmen). Am Monatsersten wird der Witzbold des Monats gekrönt und bekommt ein Abzeichen. |
| Lieblingsthemen | Beim Bewerten und im Duell lassen sich Kategorien wählen (im Browser gespeichert). |
| Wortfilter | Witze und Pointen mit gesperrten Wörtern werden abgelehnt. Liste unter `#/admin` → Wortfilter, `wort*` sperrt alle Wörter, die so beginnen. |
| Bildschirm-Modus | `#/bildschirm` öffnet den Gestalter: Querformat 16:9 oder Hochformat 9:16 (auch für gedreht montierte Fernseher), Firmenfarben (Hintergrund, Akzent, Karte), Firmenname, Kategorien und Wechselzeit, mit Live-Vorschau. Ergebnis ist ein Link `#/tv?f=hoch&bg=…&ac=…&card=…&n=…&k=…&t=…` oder ein Kurzlink `lachwerk.github.io/tv/CODE` (Erweiterung 7, `404.html` leitet um). Antippen für Vollbild. |
| Errate die Pointe | `#/quiz`: Tagesquiz mit 5 Witzanfängen (für alle gleich, Ergebnis teilbar, Vergleich mit anderen Spielern) und Endlos-Modus mit Serie. Pointe = letzte Zeile eines Witzes, falsche Antworten sind Pointen anderer Witze. Läuft auch als Folie im Bildschirm-Modus. |
| Live-Duell | Bildschirm-Option `live=1` (im Wechsel) oder `live=2` (nur Duell): zwei Witze, 45 Sekunden, Zuschauer scannen den QR-Code (`/l/CODE` → `#/live/CODE`) und stimmen per Handy ab, die Balken wachsen live. |
| Gruppen | `#/gruppen`, `#/gruppe/CODE`, Einladung über `/g/CODE`: eigene Bestenliste (Woche, Monat, Gesamt) und witzigste Mitglieder. Gründer kann umbenennen, Mitglieder entfernen, löschen. Bildschirm-Option `g=CODE`. Admin-Bereich → Nutzer zeigt alle Gruppen. |
| Plakat | `plakat.html`: A4-Plakat mit QR-Code zum Ausdrucken (Hintergrundgrafiken einschalten). |
| WhatsApp-Kanal | Beim Witz des Tages auf der Witz-Seite: „Text für WhatsApp-Kanal kopieren“ und das Story-Bild dazu teilen. |

## Moderation

Der Admin-Bereich (`#/admin`, ab Erweiterung 3) hat diese Reiter:

- **Übersicht:** Kennzahlen heute im Vergleich zu gestern, offene Meldungen, Vorrat, laufende Challenge und Battle, letzte Aktivitäten
- **Zu prüfen:** gemeldete und ausgeblendete Witze freigeben oder entfernen
- **Witze:** alle Witze durchsuchen (Text, Kategorie, Status, Autor), bearbeiten, entfernen, wiederherstellen
- **Nutzer:** alle Konten mit Zahlen, sperren (kann nichts mehr posten) und entsperren, alle Inhalte eines Nutzers entfernen
- **Statistik:** 14-Tage-Verlauf, Kategorien, Bestenlisten (beste und schlechteste Witze, meiste Reaktionen, Duell-Elo, meistgemeldet)
- **Vorrat, Challenge, Battle, Wortfilter:** siehe oben
- **Einstellungen:** Ankündigungs-Banner für die Startseite, Export aller Witze als CSV
- **Sponsoren** (Erweiterung 4): Sponsor mit Name, Satz, Link, Logo und Zeitraum für eine Platzierung (Witz des Tages inkl. Story-Bild, Battle, Challenge, Startseite, Bildschirm). Gekennzeichnet als „Sponsor“, Klicks werden gezählt. Dazu ein Bildschirm-Link für Firmen mit eigenen Kategorien und Logo (`#/tv?k=buero,nerd&s=ID`).
- **Weitere Admins** (Erweiterung 4): Unter „Nutzer“ mit „Zum Admin machen“. Die Person meldet sich mit ihrem Lachwerk-Konto an und sieht „Moderation“. Rechte vergeben und entziehen kann nur, wer den Admin-Schlüssel hat.

### Push-Nachrichten (Erweiterung 5)

1. `erweiterung5.sql` im SQL Editor ausführen (legt Abos, Zeitplan mit pg_cron und pg_net an).
2. Im Supabase-Dashboard unter **Edge Functions → Deploy a new function → Via Editor** eine Funktion namens `push` anlegen, den Inhalt von `supabase/functions/push/index.ts` einfügen und deployen. In den Einstellungen der Funktion **„Verify JWT with legacy secret“ / „Enforce JWT verification“ ausschalten**.
3. Fertig: Die Funktion erzeugt ihre Schlüssel beim ersten Aufruf selbst. Nutzer schalten Benachrichtigungen unter Highlights ein (Witz des Tages um 20 Uhr, Battle mittags, eigener Witz gekrönt). Auf dem iPhone nur in der installierten App (ab iOS 16.4).

`partner.html` ist die Angebotsseite „Lachwerk für Unternehmen“ (Bildschirme und Sponsoring). Die Kontakt-E-Mail dafür steht im Admin-Bereich unter „Einstellungen“.

Seite mit `#/admin` am Ende aufrufen, z. B. `https://lachwerk.github.io/#/admin`, und den Admin-Schlüssel eingeben.
Dort siehst du gemeldete und ausgeblendete Witze und kannst sie **freigeben** oder **entfernen**.
Im Demo-Modus lautet der Schlüssel `demo-moderation`. Konten gelten dort nur im jeweiligen Browser und haben kein echtes Passwort.

## So funktioniert es ohne Anmeldung

| Thema | Umsetzung |
|---|---|
| Konto | Nur zum Posten nötig. Registrierung mit Benutzername, E-Mail und Passwort über Supabase Auth und „Passwort vergessen“. E-Mail-Bestätigung ist derzeit abgeschaltet (Authentication → Sign In / Providers → Confirm email). Der Benutzername erscheint unter den Witzen. |
| Gäste | Jeder Browser bekommt eine zufällige Geräte-ID (localStorage). Damit funktionieren Liken, Bewerten und Melden ohne Konto. |
| Ein Vote pro Person | Pro Witz und Geräte-ID genau eine Stimme. Zusätzlich max. 5 Stimmen pro Witz und Internetanschluss, max. 300 Stimmen pro Stunde und Anschluss. |
| Eigene Witze | Können nicht selbst bewertet werden, auch nicht von einem anderen Gerät aus. |
| Posten | Nur mit Konto. Max. 10 Witze pro Konto und 20 pro Anschluss in 24 Stunden. |
| Duplikate | Ähnlichkeitsvergleich (pg_trgm). Ab 60 % Übereinstimmung wird das Posten abgelehnt und das Original verlinkt. Schon beim Tippen erscheint ein Hinweis. |
| Ranking | Wilson-Score: fair auch bei wenigen Stimmen. Heute = 24 h, Woche = 7 Tage, Alltime = ab 20 Stimmen. Ist ein Zeitraum leer, zeigt die Seite automatisch die Besten der Woche bzw. aller Zeiten. |
| Swipe-Modus | Zeigt zuerst Witze mit unter 20 Stimmen, damit jeder neue Witz eine Chance bekommt. |
| Melden | Ab 3 Meldungen von verschiedenen Anschlüssen wird ein Witz ausgeblendet. Nach einer Freigabe erst ab 10. |
| Teilen | WhatsApp-Link, Link teilen und „Als Bild teilen“ (Story-Bild 1080×1920, wird im Browser erzeugt). |
| Datenschutz | Keine Cookies, keine externen Schriften, kein Tracking. IP-Adressen werden nur gesalzen gehasht gespeichert. Besucher können keine Tabelle direkt lesen, nur die freigegebenen Funktionen aufrufen. |

**Grenzen bei Gast-Stimmen:** Wer es darauf anlegt, kann mit gelöschtem Browser-Speicher erneut abstimmen. Das IP-Limit bremst das stark, verhindert es aber nicht ganz.
Wenn die Seite wächst: Cloudflare Turnstile (unsichtbares Captcha) ergänzen oder auch das Liken an ein Konto binden.

## Dateien

```
index.html        Seite
app.js            App-Logik (Demo- und Live-Modus)
style.css         Gestaltung
config.js         Supabase-Zugang (leer = Demo-Modus)
startwitze.js     360 Startwitze für den Demo-Modus
supabase.sql      Datenbank: Tabellen, Schutzregeln, Funktionen, Startwitze
weitere_witze.sql 210 neue Witze für eine schon eingerichtete Datenbank
erweiterung.sql   Witz des Tages, Duell, Reaktionen, Profile, Challenge, Statistik, Vorrat
erweiterung2.sql  Pointen-Battle, Monats-Saison, Lieblingsthemen, Wortfilter
erweiterung3.sql  größerer Admin-Bereich, Nutzer sperren, Ankündigung, Export
erweiterung4.sql  Sponsoren, Kontakt, weitere Admins
erweiterung5.sql  Push-Nachrichten (dazu supabase/functions/push/index.ts)
erweiterung6.sql  Konto selbst löschen, Pointen melden
erweiterung7.sql  Kurzlinks für Bildschirme (lachwerk.github.io/tv/CODE)
erweiterung8.sql  Errate die Pointe, Live-Duell am Bildschirm, Gruppen und Ligen
erweiterung9.sql  Bestenliste „Neu“ (letzte 6 Stunden, neueste zuerst)
partner.html      Angebotsseite für Unternehmen
plakat.html, qr.svg  Plakat mit QR-Code
manifest.webmanifest, sw.js, icons/   installierbare App
witze/            statische Kategorie-Seiten für Google
sitemap.xml, robots.txt
impressum.html    Vorlage, bitte ausfüllen
datenschutz.html  Vorlage, bitte ausfüllen
og-image.png      Vorschaubild beim Teilen
favicon.svg       Icon
```

## Vor dem Veröffentlichen

- [ ] `impressum.html` und `datenschutz.html` ausfüllen (für eine öffentliche Seite in Deutschland Pflicht)
- [ ] In `index.html` bei `og:image` die volle Adresse eintragen, z. B. `https://lachwerk.github.io/og-image.png`. Dann zeigt WhatsApp das Vorschaubild.
- [ ] Startwitze durchsehen. Die Liste steht unten in `supabase.sql` und in `startwitze.js`.
- [ ] Moderation testen: einen Witz melden und unter `#/admin` freigeben
- [ ] Eigene Domain (optional): Settings → Pages → Custom domain

## Lokal ausprobieren

`index.html` per Doppelklick im Browser öffnen. Der Demo-Modus funktioniert ohne Server.
