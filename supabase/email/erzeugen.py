# Erzeugt die Lachwerk-E-Mail-Vorlagen für Supabase Auth (HTML mit Inline-Styles, mailtauglich)
import json, os, html
OUT = os.path.dirname(os.path.abspath(__file__))
Y, INK, PAPER, MUTED = '#ffc928', '#15172a', '#ffffff', '#5b5f78'
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

def page(preheader, emoji, title, paras, button=None, after=None, joke=None, why=''):
    btn = ''
    if button:
        label, url = button
        btn = f'''<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:26px 0 8px">
        <tr><td style="border-radius:999px;background:{INK}">
          <a href="{url}" style="display:inline-block;padding:15px 30px;font-family:{FONT};font-size:17px;font-weight:800;color:{Y};text-decoration:none;border-radius:999px">{label}</a>
        </td></tr></table>
        <p style="margin:14px 0 0;font-family:{FONT};font-size:12px;line-height:1.5;color:{MUTED}">Button funktioniert nicht? Kopiere diesen Link in deinen Browser:<br><a href="{url}" style="color:{MUTED};word-break:break-all">{url}</a></p>'''
    body = ''.join(f'<p style="margin:0 0 14px;font-family:{FONT};font-size:16px;line-height:1.55;color:{INK}">{p}</p>' for p in paras)
    jk = ''
    if joke:
        jk = f'''<tr><td style="padding:0 6px 22px">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:{INK};border-radius:18px">
        <tr><td style="padding:18px 22px;font-family:{FONT}">
          <div style="font-size:11px;font-weight:800;letter-spacing:.12em;text-transform:uppercase;color:{Y}">😂 Kleiner Witz zwischendurch</div>
          <div style="margin-top:8px;font-size:15px;line-height:1.5;color:#ffffff">{joke}</div>
        </td></tr></table>
    </td></tr>'''
    return f'''<!doctype html>
<html lang="de"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="light only"><title>{html.escape(title)}</title></head>
<body style="margin:0;padding:0;background:{Y}">
<div style="display:none;max-height:0;overflow:hidden;opacity:0">{preheader}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:{Y}">
  <tr><td align="center" style="padding:28px 14px 36px">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px">
      <tr><td style="padding:0 6px 20px">
        <table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>
          <td style="font-family:{FONT};font-size:30px;font-weight:800;color:{INK};letter-spacing:-.5px">Lach</td>
          <td style="padding-left:3px"><span style="display:inline-block;background:{INK};color:{Y};font-family:{FONT};font-size:30px;font-weight:800;letter-spacing:-.5px;padding:0 8px 2px;border-radius:7px">werk</span></td>
        </tr></table>
      </td></tr>
      <tr><td style="padding:0 6px 22px">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:{PAPER};border-radius:22px;border-bottom:6px solid {INK}">
          <tr><td style="padding:30px 28px 28px">
            <div style="font-size:40px;line-height:1">{emoji}</div>
            <h1 style="margin:14px 0 14px;font-family:{FONT};font-size:24px;line-height:1.25;font-weight:800;color:{INK}">{title}</h1>
            {body}
            {btn}
            {f'<p style="margin:18px 0 0;font-family:{FONT};font-size:14px;line-height:1.5;color:{MUTED}">{after}</p>' if after else ''}
          </td></tr>
        </table>
      </td></tr>
      {jk}
      <tr><td style="padding:0 10px;font-family:{FONT};font-size:12px;line-height:1.6;color:#4a3c06;text-align:center">
        {why}<br>
        <a href="https://lach-werk.de/" style="color:#4a3c06;font-weight:700">lach-werk.de</a> · Die besten Witze des Tages<br>
        Lachwerk ist ein privates Hobbyprojekt · <a href="https://lach-werk.de/impressum.html" style="color:#4a3c06">Impressum</a> · <a href="https://lach-werk.de/datenschutz.html" style="color:#4a3c06">Datenschutz</a>
      </td></tr>
    </table>
  </td></tr>
</table>
</body></html>'''

NOTME = 'Du warst das nicht? Dann kannst du diese E-Mail einfach ignorieren, es passiert nichts.'
T = {
 'confirmation': ('Willkommen bei Lachwerk! Bitte bestätige deine E-Mail 😄', page(
    'Ein Klick noch, dann kannst du Witze posten.', '🎉', 'Schön, dass du da bist!',
    ['Hallo und herzlich willkommen bei Lachwerk!', 'Bitte bestätige noch kurz deine E-Mail-Adresse. Danach kannst du eigene Witze posten, Likes sammeln und vielleicht schon heute Abend zum <b>Witz des Tages</b> gekrönt werden. 👑'],
    ('E-Mail bestätigen', '{{ .ConfirmationURL }}'), NOTME,
    'Treffen sich zwei Magnete. Sagt der eine: „Was soll ich heute bloß anziehen?“',
    'Du bekommst diese E-Mail, weil sich jemand mit dieser Adresse bei Lachwerk registriert hat.')),
 'recovery': ('Dein neues Lachwerk-Passwort wartet 🔑', page(
    'Hier kannst du ein neues Passwort festlegen.', '🔑', 'Passwort vergessen? Passiert den Besten.',
    ['Kein Problem! Mit einem Klick auf den Button legst du ein neues Passwort für dein Lachwerk-Konto fest.', 'Der Link ist aus Sicherheitsgründen nur kurze Zeit gültig.'],
    ('Neues Passwort festlegen', '{{ .ConfirmationURL }}'), NOTME + ' Dein altes Passwort bleibt dann gültig.',
    'Mein Passwort ist jetzt „falsch“. Wenn ich es vergesse, sagt der Computer: „Dein Passwort ist falsch.“',
    'Du bekommst diese E-Mail, weil für deine Adresse ein neues Passwort angefordert wurde.')),
 'magic_link': ('Dein Anmelde-Link für Lachwerk ✨', page(
    'Mit einem Klick bist du angemeldet.', '✨', 'Einmal klicken, schon bist du drin',
    ['Hier ist dein persönlicher Anmelde-Link für Lachwerk. Kein Passwort nötig.', 'Falls du lieber einen Code eingibst: <b style="font-size:20px;letter-spacing:3px">{{ .Token }}</b>'],
    ('Bei Lachwerk anmelden', '{{ .ConfirmationURL }}'), NOTME,
    'Was macht ein Pirat am Computer? Er drückt die Enter-Taste.',
    'Du bekommst diese E-Mail, weil eine Anmeldung mit dieser Adresse angefordert wurde.')),
 'invite': ('Du bist zu Lachwerk eingeladen 😂', page(
    'Jemand möchte mit dir lachen.', '💌', 'Du bist eingeladen!',
    ['Du wurdest zu <b>Lachwerk</b> eingeladen, der Seite, auf der jeden Abend der beste Witz des Tages gekrönt wird.', 'Mit einem Klick nimmst du die Einladung an und legst dein Konto an.'],
    ('Einladung annehmen', '{{ .ConfirmationURL }}'), 'Keine Lust? Dann ignoriere diese E-Mail einfach.',
    'Warum können Geister so schlecht lügen? Weil man durch sie hindurchsieht.',
    'Du bekommst diese E-Mail, weil dich jemand zu Lachwerk eingeladen hat.')),
 'email_change': ('Bitte bestätige deine neue E-Mail-Adresse 📬', page(
    'Ein Klick, dann ist die neue Adresse aktiv.', '📬', 'Neue Adresse, gleicher Humor',
    ['Du möchtest die E-Mail-Adresse deines Lachwerk-Kontos von <b>{{ .Email }}</b> auf <b>{{ .NewEmail }}</b> ändern.', 'Bitte bestätige das mit einem Klick.'],
    ('Neue Adresse bestätigen', '{{ .ConfirmationURL }}'), 'Du hast das nicht veranlasst? Dann ignoriere diese E-Mail. Deine bisherige Adresse bleibt aktiv.',
    'Ich habe meiner Frau gesagt, sie soll mich nicht unterbrechen. Seitdem schreibt sie mir E-Mails.',
    'Du bekommst diese E-Mail, weil eine Änderung der Adresse angefordert wurde.')),
 'reauthentication': ('Dein Bestätigungscode für Lachwerk 🔐', page(
    'Dein Code für die Bestätigung.', '🔐', 'Kurz bestätigen, dass du es bist',
    ['Für eine wichtige Änderung an deinem Konto brauchen wir eine kurze Bestätigung. Gib diesen Code in der App ein:', f'<span style="display:inline-block;background:{Y};border-radius:12px;padding:10px 18px;font-size:28px;font-weight:800;letter-spacing:6px;color:{INK}">{{{{ .Token }}}}</span>'],
    None, NOTME,
    'Warum nehmen Geheimagenten immer Kaffee mit? Weil sie bohnenstark sein müssen.',
    'Du bekommst diese E-Mail, weil eine Bestätigung für dein Konto angefordert wurde.')),
 'password_changed_notification': ('Dein Lachwerk-Passwort wurde geändert ✅', page(
    'Nur zur Info: Dein Passwort ist neu.', '✅', 'Passwort erfolgreich geändert',
    ['Das Passwort deines Lachwerk-Kontos (<b>{{ .Email }}</b>) wurde gerade geändert.', 'Wenn du das warst: alles gut, nichts weiter zu tun.'],
    None, 'Du warst das nicht? Dann setze sofort über „Passwort vergessen“ ein neues Passwort und schreib uns an <a href="mailto:kontakt@lach-werk.de" style="color:#5b5f78">kontakt@lach-werk.de</a>.',
    None, 'Du bekommst diese E-Mail zur Sicherheit deines Kontos.')),
 'email_changed_notification': ('Deine E-Mail-Adresse bei Lachwerk wurde geändert ✅', page(
    'Nur zur Info: Deine Adresse ist neu.', '✅', 'E-Mail-Adresse geändert',
    ['Die E-Mail-Adresse deines Lachwerk-Kontos wurde geändert.', 'Wenn du das warst: alles gut, nichts weiter zu tun.'],
    None, 'Du warst das nicht? Dann schreib uns bitte an <a href="mailto:kontakt@lach-werk.de" style="color:#5b5f78">kontakt@lach-werk.de</a>.',
    None, 'Du bekommst diese E-Mail zur Sicherheit deines Kontos.')),
}
os.makedirs(OUT, exist_ok=True)
for k, (subj, h) in T.items():
    open(f'{OUT}/{k}.html', 'w').write(h)
json.dump({k: {'subject': s, 'html': h} for k, (s, h) in T.items()}, open(f'{OUT}/templates.json', 'w'), ensure_ascii=False, indent=1)
print(len(T), 'Vorlagen')
