-- ═══════════════════════════════════════════════════════════════════
-- Lachwerk – Erweiterung 10: Pointen-Battle abgeschaltet → keine Battle-Push-Nachrichten mehr
-- Mehrfach ausführen ist unschädlich. Zum Wiedereinschalten den Zeitplan aus erweiterung5.sql erneut anlegen.
-- ═══════════════════════════════════════════════════════════════════
select cron.unschedule(j.jobid) from cron.job j where j.jobname = 'lachwerk-battle-push';
select j.jobname, j.schedule from cron.job j order by j.jobname;
