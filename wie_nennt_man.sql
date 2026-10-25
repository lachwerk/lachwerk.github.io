-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – 40 neue „Wie nennt man …?“-Witze
-- Im Supabase SQL Editor einfügen und „Run“ klicken. Mehrfach ausführen ist unschädlich.
-- Die ersten 10 erscheinen sofort, danach etwa alle 6 Stunden einer.
-- ═══════════════════════════════════════════════════════════════════

with neu as (
  insert into public.jokes (category_id, body, author_name, author_device, created_at)
  select c.id, t.body, 'Lachwerk', '00000000-0000-0000-0000-000000000000',
         case when t.nr <= 10 then now() - (11 - t.nr) * interval '20 minutes'
              else now() + (t.nr - 10) * interval '6 hours' end
  from (values
    (1, 'wortspiele', 'Wie nennt man einen Keks unter einem Baum?
Ein schattiges Plätzchen.'),
    (2, 'wortspiele', 'Wie nennt man einen Cowboy ohne Pferd?
Sattelschlepper.'),
    (3, 'wortspiele', 'Wie nennt man eine Gruppe von Wölfen?
Wolfgang.'),
    (4, 'tiere', 'Wie nennt man einen schlafenden Stier?
Bulldozer.'),
    (5, 'tiere', 'Wie nennt man ein Schaf ohne Beine?
Wolke.'),
    (6, 'flachwitze', 'Wie nennt man einen dicken Vegetarier?
Biotonne.'),
    (7, 'flachwitze', 'Wie nennt man jemanden, der im Fitnessstudio nur Selfies macht?
Spiegeltrainer.'),
    (8, 'nerd', 'Wie nennt man ein WLAN ohne Passwort?
Nachbarschaftshilfe.'),
    (9, 'buero', 'Wie nennt man ein Meeting, das auch eine E-Mail hätte sein können?
Ein Meeting.'),
    (10, 'flachwitze', 'Wie nennt man ein Skelett, das nicht arbeiten will?
Stinkfaul bis auf die Knochen.'),
    (11, 'wortspiele', 'Wie nennt man einen Spanier ohne Auto?
Carlos.'),
    (12, 'tiere', 'Wie nennt man einen Igel in der Wüste?
Kaktus.'),
    (13, 'tiere', 'Wie nennt man einen Pinguin in der Wüste?
Verlaufen.'),
    (14, 'wortspiele', 'Wie nennt man jemanden, der Angst vor dem Weihnachtsmann hat?
Claustrophobiker.'),
    (15, 'tiere', 'Wie nennt man einen ängstlichen Dinosaurier?
Nervosaurus.'),
    (16, 'wortspiele', 'Wie nennt man einen Dinosaurier, der unglaublich viele Wörter kennt?
Thesaurus.'),
    (17, 'flachwitze', 'Wie nennt man einen Schneemann im Sommer?
Pfütze.'),
    (18, 'tiere', 'Wie nennt man einen Vogel, der auf dem Bau arbeitet?
Kranich.'),
    (19, 'tiere', 'Wie nennt man einen Hai, der ständig Witze erzählt?
Einen Haiterkeitsbringer.'),
    (20, 'tiere', 'Wie nennt man eine Ente, die immer lügt?
Zeitungsente.'),
    (21, 'flachwitze', 'Wie nennt man einen völlig erschöpften Zahnarzt?
Ausgebohrt.'),
    (22, 'nerd', 'Wie nennt man acht Hobbits?
Ein Hobbyte.'),
    (23, 'nerd', 'Wie nennt man einen Programmierer, der nie Feierabend macht?
Endlosschleife.'),
    (24, 'flachwitze', 'Wie nennt man ein Fitnessstudio für Zwerge?
Kleinkraftwerk.'),
    (25, 'flachwitze', 'Wie nennt man Hanteln, die seit Februar niemand mehr angefasst hat?
Neujahrsvorsätze.'),
    (26, 'buero', 'Wie nennt man einen Chef, der nie da ist?
Eine Abwesenheitsnotiz mit Gehalt.'),
    (27, 'schule', 'Wie nennt man ein Schaf, das richtig gut rechnen kann?
Mähthematiker.'),
    (28, 'flachwitze', 'Wie nennt man ein Ei, das Witze erzählt?
Einen Spaßvogel in Ausbildung.'),
    (29, 'wortspiele', 'Wie nennt man einen Mann mit einer Schaufel?
Grabowski.'),
    (30, 'schwarz', 'Wie nennt man einen Hund ohne Beine?
Egal, er kommt sowieso nicht.'),
    (31, 'schwarz', 'Wie nennt man eine Kuh ohne Beine?
Gehacktes.'),
    (32, 'wortspiele', 'Wie nennt man ein Gespenst, das immer pünktlich ist?
Zeitgeist.'),
    (33, 'flachwitze', 'Wie nennt man einen Kürbis eine Woche nach Halloween?
Kompost mit Gesicht.'),
    (34, 'schule', 'Wie nennt man einen Lehrer, der nie Hausaufgaben aufgibt?
Ein Märchen.'),
    (35, 'nerd', 'Wie nennt man einen Drucker, der einfach funktioniert?
Einen Mythos.'),
    (36, 'buero', 'Wie nennt man einen Montag, der sich wie Freitag anfühlt?
Einen Traum.'),
    (37, 'flachwitze', 'Wie nennt man eine Brille, die man überall sucht?
Die Brille auf deinem Kopf.'),
    (38, 'buero', 'Wie nennt man Kaffee ohne Koffein?
Sinnlos.'),
    (39, 'tiere', 'Wie nennt man eine Katze, die Kriminalfälle löst?
Miez Marple.'),
    (40, 'flachwitze', 'Wie nennt man einen Hamburger in Lübeck?
Tourist.')
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
