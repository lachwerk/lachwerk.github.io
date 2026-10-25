-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – 31 neue Witze (Oktober 2026), u. a. passend zur Fitness-Challenge
-- Im Supabase SQL Editor einfügen und „Run“ klicken. Mehrfach ausführen ist unschädlich.
-- Die ersten 10 erscheinen sofort, danach etwa alle 6 Stunden einer.
-- ═══════════════════════════════════════════════════════════════════

with neu as (
  insert into public.jokes (category_id, body, author_name, author_device, created_at)
  select c.id, t.body, 'Lachwerk', '00000000-0000-0000-0000-000000000000',
         case when t.nr <= 10 then now() - (11 - t.nr) * interval '20 minutes'
              else now() + (t.nr - 10) * interval '6 hours' end
  from (values
    (1, 'flachwitze', 'Warum geht der Hantel nie auf Partys?
Zu viel Gewicht auf den Schultern.'),
    (2, 'flachwitze', 'Mein Trainer sagt, ich soll mehr Gemüse essen.
Jetzt nehme ich Ketchup zu den Pommes.'),
    (3, 'flachwitze', 'Was sagt das Laufband nach Feierabend?
„Endlich läuft mal nichts.“'),
    (4, 'flachwitze', 'Ich mache jeden Morgen Liegestütze.
Erst liegen, dann stützen auf die Snooze-Taste.'),
    (5, 'einzeiler', 'Mein Fitnessarmband hat mir heute gratuliert: Ich habe mein Ruheziel erreicht.'),
    (6, 'einzeiler', 'Ich gehe nicht ins Fitnessstudio, ich bin einfach in Form. Rund ist auch eine Form.'),
    (7, 'buero', 'Kollege: „Ich trainiere jetzt in der Mittagspause.“
„Ich auch. Ich hebe die Gabel.“'),
    (8, 'flachwitze', 'Warum stehen Störche auf einem Bein?
Weil sie sonst umfallen würden.'),
    (9, 'flachwitze', 'Was ist durchsichtig und riecht nach Möhren?
Ein Kaninchenpups.'),
    (10, 'flachwitze', 'Wie nennt man einen Elefanten, der Geige spielt?
Ein Elefant, der Geige spielt. Was denn sonst?'),
    (11, 'tiere', 'Treffen sich zwei Fische. Fragt der eine: „Was macht dein Vater?“
„Der arbeitet in einer Dose.“'),
    (12, 'tiere', 'Welches Tier kann am höchsten springen?
Der Floh. Ein Haus kann nämlich gar nicht springen.'),
    (13, 'tiere', 'Ein Pinguin beim Arzt: „Herr Doktor, mir ist so kalt.“
„Gratuliere, dann sind Sie kerngesund.“'),
    (14, 'schule', 'Lehrerin: „Nenn mir ein Tier, das in Afrika lebt.“ – „Ein Löwe.“ – „Und noch eins?“
„Noch ein Löwe.“'),
    (15, 'schule', 'Lehrer: „Wenn ich sage ‚Ich war hungrig‘, welche Zeit ist das?“
„Mittagszeit.“'),
    (16, 'schule', '„Fritzchen, warum ist deine Hausaufgabe in der Schrift deines Vaters?“
„Ich hab seinen Füller benutzt.“'),
    (17, 'schule', 'Mutter: „Warum hast du eine Sechs in Mathe?“
„Die Lehrerin hat gesagt, mehr gibt es nicht.“'),
    (18, 'buero', 'Chef: „Können Sie mit Druck umgehen?“
„Klar, ich hab schon mal einen Drucker repariert.“'),
    (19, 'buero', 'Das Meeting hätte eine E-Mail sein können.
Die E-Mail hätte ein Nicken sein können.'),
    (20, 'nerd', 'Was sagt ein Router zum anderen?
„Wir haben eine echte Verbindung.“'),
    (21, 'schwarz', 'Der Bestatter fragt: „Möchten Sie die Asche Ihres Mannes in einer Urne?“
„Nein, in einer Sanduhr. Dann arbeitet er wenigstens mal.“'),
    (22, 'schwarz', '„Herr Doktor, werde ich die Operation überleben?“
„Ganz sicher. Ich habe sie schon 99 Mal schlecht gemacht, einmal muss es ja klappen.“'),
    (23, 'einzeiler', 'Ich habe einen Witz über Zeitlupe. Er dauert nur etwas.'),
    (24, 'einzeiler', 'Ich wäre gern spontaner, aber das muss ich erst mal planen.'),
    (25, 'einzeiler', 'Mein Gehirn hat heute 15 Tabs offen. Drei davon spielen Musik, und ich finde sie nicht.'),
    (26, 'flachwitze', 'Warum ging das Laufband in Rente?
Es wollte endlich mal stillstehen.'),
    (27, 'tiere', 'Zwei Igel im Nebel. Sagt der eine: „Komm, wir kuscheln.“
„Lieber nicht, das gibt nur wieder Stress.“'),
    (28, 'tiere', 'Was macht ein Hai auf dem Laufband?
Flossen-Training.'),
    (29, 'schule', 'Lehrer: „Fritzchen, nenn mir fünf Dinge, die Milch enthalten.“
„Butter, Käse, Joghurt und zwei Kühe.“'),
    (30, 'buero', 'Chef: „Ab heute duzen wir uns alle.“
Seitdem nennt ihn keiner mehr beim Namen.'),
    (31, 'nerd', 'Mein Passwort ist jetzt sehr sicher.
Nicht mal ich komme mehr rein.')
  ) as t(nr, cat, body)
  join public.categories c on c.slug = t.cat
  where not exists (
    select 1 from public.jokes j
    where j.status <> 'removed'
      and extensions.similarity(j.body_norm, public.normalize_joke(t.body)) >= 0.6
  )
  returning 1
)
select count(*) as neu_eingefuegt from neu;
