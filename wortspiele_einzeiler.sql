-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – 23 Wortspiele und 24 Einzeiler
-- Im Supabase SQL Editor einfügen und „Run“ klicken. Mehrfach ausführen ist unschädlich.
-- Die ersten 10 erscheinen sofort, danach etwa alle 6 Stunden einer.
-- ═══════════════════════════════════════════════════════════════════

with neu as (
  insert into public.jokes (category_id, body, author_name, author_device, created_at)
  select c.id, t.body, 'Lachwerk', '00000000-0000-0000-0000-000000000000',
         case when t.nr <= 10 then now() - (11 - t.nr) * interval '20 minutes'
              else now() + (t.nr - 10) * interval '6 hours' end
  from (values
    (1, 'wortspiele', 'Was macht ein Clown im Büro?
Faxen.'),
    (2, 'wortspiele', 'Was ist orange und geht über die Berge?
Eine Wanderine.'),
    (3, 'wortspiele', 'Was ist grün und klopft an die Tür?
Ein Klopfsalat.'),
    (4, 'wortspiele', 'Was liegt am Strand und spricht undeutlich?
Eine Nuschel.'),
    (5, 'wortspiele', 'Wo wohnen Katzen am liebsten?
Im Miezhaus.'),
    (6, 'wortspiele', 'Welcher Bus fährt über den Ozean?
Kolumbus.'),
    (7, 'wortspiele', 'Wie heißt der Bruder von Elvis?
Zwölfis.'),
    (8, 'wortspiele', 'Treffen sich zwei Kerzen. Sagt die eine:
„Ist Wachs los?“'),
    (9, 'wortspiele', 'Was macht ein Mathematiker im Garten?
Wurzeln ziehen.'),
    (10, 'wortspiele', 'Warum sind Fische so schlau?
Weil sie in Schulen leben.'),
    (11, 'wortspiele', 'Was ist braun, klebrig und läuft durch die Wüste?
Ein Karamel.'),
    (12, 'wortspiele', 'Was macht ein Dieb im Zirkus?
Er klaut die Show.'),
    (13, 'wortspiele', 'Was lernen Bienen im Matheunterricht?
Summieren.'),
    (14, 'wortspiele', 'Was sagt der große Stift zum kleinen Stift?
„Wachs mal, Stift!“'),
    (15, 'wortspiele', 'Was sagt die Null zur Acht?
„Schicker Gürtel!“'),
    (16, 'wortspiele', 'Was ist das Lieblingsgetränk von Gespenstern?
Buhttermilch.'),
    (17, 'wortspiele', 'Warum gehen Ameisen nicht in die Kirche?
Weil sie In-Sekten sind.'),
    (18, 'wortspiele', 'Was steht auf dem Grabstein eines Mathematikers?
„Damit hat er nicht gerechnet.“'),
    (19, 'wortspiele', 'Warum können Seeräuber keinen Kreisumfang berechnen?
Weil sie Pi raten.'),
    (20, 'wortspiele', 'Was ist das Gegenteil von Reformhaus?
Reh hinterm Haus.'),
    (21, 'wortspiele', 'Was sagt der Ozean zum Strand?
Nichts, er winkt nur.'),
    (22, 'wortspiele', 'Warum tragen Kühe Glocken?
Weil ihre Hörner nicht funktionieren.'),
    (23, 'wortspiele', 'Was ist rot und schlecht für die Zähne?
Ein Ziegelstein.'),
    (24, 'einzeiler', 'Ich habe einen Witz über Bauarbeiten, aber ich arbeite noch daran.'),
    (25, 'einzeiler', 'Ich wollte heute etwas Produktives machen. Dann bin ich aufgewacht.'),
    (26, 'einzeiler', 'Ich bin nicht faul, ich bin im Energiesparmodus.'),
    (27, 'einzeiler', 'Wer zuletzt lacht, hat den Witz nicht verstanden.'),
    (28, 'einzeiler', 'Ordnung ist das halbe Leben. Ich lebe in der anderen Hälfte.'),
    (29, 'einzeiler', 'Geduld ist eine Tugend. Ich hätte gern sofort welche.'),
    (30, 'einzeiler', 'Ich bin nicht unpünktlich, ich bin zeitlich flexibel.'),
    (31, 'einzeiler', 'Früher war ich unentschlossen. Heute bin ich mir da nicht mehr so sicher.'),
    (32, 'einzeiler', 'Mein Bett und ich sind füreinander bestimmt, aber mein Wecker ist dagegen.'),
    (33, 'einzeiler', 'Wer Rechtschreibfehler findet, darf sie behalten.'),
    (34, 'einzeiler', 'Mein Gehirn hat zu viele Tabs offen.'),
    (35, 'einzeiler', 'Ich habe heute nichts geschafft, aber das sehr gründlich.'),
    (36, 'einzeiler', 'Der Montag ist der beste Beweis, dass das Wochenende zu kurz ist.'),
    (37, 'einzeiler', 'Ich mache keine Fehler, ich erschaffe Lerngelegenheiten.'),
    (38, 'einzeiler', '„Sport ist Mord“, sagt meine Couch. Und wer bin ich, ihr zu widersprechen?'),
    (39, 'einzeiler', 'Ich esse gesund: Auf der Pizza sind Tomaten, und Tomaten sind Gemüse.'),
    (40, 'einzeiler', 'Mein Handy hat mehr Akku als ich Energie.'),
    (41, 'einzeiler', 'Optimisten sagen: Das Glas ist halb voll. Ich sage: Wer hat aus meinem Glas getrunken?'),
    (42, 'einzeiler', 'Ich bin kein Morgenmensch und kein Abendmensch. Ich bin ein Mittagsschlafmensch.'),
    (43, 'einzeiler', 'Mein Kühlschrank und ich haben etwas gemeinsam: Wenn jemand reinschaut, sind wir beide leer.'),
    (44, 'einzeiler', 'Ich habe beschlossen, weniger zu prokrastinieren. Morgen fange ich an.'),
    (45, 'einzeiler', 'Ich treibe Sport: Ich renne jeden Morgen meinem Bus hinterher.'),
    (46, 'einzeiler', 'Mein Lieblingsplatz im Fitnessstudio ist der Parkplatz.'),
    (47, 'einzeiler', 'Ich wollte abnehmen, aber der Kühlschrank hat so traurig geguckt.')
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
