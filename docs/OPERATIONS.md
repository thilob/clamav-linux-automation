# Betrieb und Fehlersuche

## Debian

Der Installer unterstützt Debian mit systemd und installiert über APT die
Pakete `clamav`, `clamav-daemon`, `clamav-freshclam` und `clamdscan`. Die
Programme `clamd` und `clamonacc` liegen bei Debian unter `/usr/sbin`; der
Installer richtet dafür bei Bedarf die von den Projekt-Units erwarteten Links
unter `/usr/bin` ein.

Vor dem Start der Projekt-Units werden die Debian-Dienste
`clamav-daemon.service`, `clamav-daemon.socket`, `clamav-clamonacc.service` und
`clamav-freshclam.service` deaktiviert. Zur Kontrolle dürfen anschließend nur
die Units mit Präfix `clamav-auto-` aktiv beziehungsweise aktiviert sein:

```bash
systemctl list-unit-files 'clamav*' --no-pager
systemctl list-units 'clamav*' --all --no-pager
```

Ubuntu, Raspberry Pi OS und andere Debian-Derivate werden nicht automatisch
über `ID_LIKE=debian` freigeschaltet und gelten nicht als getestet.

## Schnellcheck

```bash
sudo systemctl --failed
sudo systemctl list-timers 'clamav-auto-*'
sudo systemctl status clamav-auto-clamd clamav-auto-onaccess
sudo /usr/local/libexec/clamav-automation/clamav-selftest.sh
```

## clamd-Start und Bereitschaft

`clamd` lädt beim Start die vollständige Signaturdatenbank in den Arbeitsspeicher.
Bei mehreren Millionen Signaturen sind 30 bis 180 Sekunden Startzeit möglich.
Der Fortschritt ist im Journal sichtbar:

```bash
journalctl -fu clamav-auto-clamd.service
```

Ein erfolgreicher Start enthält nacheinander Meldungen wie `Reading databases`,
`Loaded ... signatures` und `Unix socket file /run/clamav-automation/clamd.sock`.
Die tatsächliche Erreichbarkeit lässt sich mit dem installierten Helfer prüfen:

```bash
sudo /usr/local/libexec/clamav-automation/clamav-wait-for-clamd.sh 180
```

Direkt mit `clamdscan` muss bei ClamAV 1.5 die Anzahl der Ping-Versuche angegeben
werden:

```bash
sudo clamdscan \
  --config-file=/etc/clamav-automation/clamd.conf \
  --ping=1
```

`--ping` ohne Argument ist ungültig und darf nicht als Bereitschaftsprüfung
verwendet werden.

`clamonacc` läuft für Fanotify als root, während `clamd` als `clamav-auto`
arbeitet. Die Projekt-Unit verwendet deshalb `--fdpass` und übergibt geöffnete
Dateideskriptoren an den Daemon. Ohne diese Option erscheinen bei privaten
Home-Verzeichnissen trotz laufender Dienste Meldungen wie `File path check
failure: Permission denied`.

Falls `Can't open/parse the config file` erscheint, Rechte kontrollieren:

```bash
sudo stat -c '%U:%G %a %n' \
  /etc/clamav-automation \
  /etc/clamav-automation/clamd.conf
```

Erwartet werden `root:clamav-auto 750` für das Verzeichnis und
`root:clamav-auto 640` für `clamd.conf`.

Damit `/tmp` per On-Access-Scan überwacht werden kann, verwendet `clamd`
`/var/lib/clamav-automation/tmp` als eigenes temporäres Verzeichnis. Die Meldung
`ClamOnAcc should not watch the directory clamd is using for temp files` weist
darauf hin, dass diese Trennung in der laufenden Konfiguration fehlt.

## FreshClam

Manuell:

```bash
sudo systemctl start clamav-auto-freshclam.service
```

Log:

```bash
journalctl -u clamav-auto-freshclam.service -n 100 --no-pager
```

## Daily Scan

Manuell:

```bash
sudo systemctl start clamav-auto-scan.service
```

Log:

```bash
journalctl -u clamav-auto-scan.service -n 100 --no-pager
```

## YARA-Forge-Core-Regeln

Die optionale Installation beziehungsweise Aktualisierung erfolgt zusammen mit
einem Projektupgrade:

```bash
sudo ./install.sh --upgrade --install-yara-core
```

Installierte Datei und lokale Prüfsumme kontrollieren:

```bash
sudo sha256sum -c /etc/clamav-security/yara/yara-forge-core.yar.sha256 \
  --ignore-missing
sudo yara -w /etc/clamav-security/yara/yara-forge-core.yar /dev/null
```

Der zweite Befehl kompiliert den vollständigen Regelsatz und kann einige Zeit
benötigen. Die Regeln werden nicht automatisch unabhängig vom Projektupgrade
aktualisiert; dadurch ändert sich der Audit-Regelbestand nicht unbemerkt.

Da Regeldateien Malware-Signaturen als Daten enthalten, ist ausschließlich
`/etc/clamav-security/yara` in `clamd.conf` per `OnAccessExcludePath` und im
täglichen `clamdscan` per Pfad-RegEx ausgenommen. Diese Ausnahme verhindert
Selbsttreffer auf den Regelbestand; sie deaktiviert nicht die Anwendung der
YARA-Regeln durch den Security-Audit.

Detailprotokoll:

```bash
sudo ls -lh /var/log/clamav-automation/
```

## Heartbeat manuell senden

```bash
sudo systemctl start clamav-auto-heartbeat.service
```

Der Heartbeat übergibt Journalinhalte über eine temporäre Datei an den
Mailversand. Dadurch greift die Linux-Grenze für die Länge eines einzelnen
Kommandozeilenarguments nicht. `HEARTBEAT_JOURNAL_LINES` begrenzt zusätzlich
die Zahl der enthaltenen Journalzeilen (Standard: 2000).

## Signaturdatenbank

Die Automation verwaltet ihre Signaturen unabhängig von Distributionsdiensten
unter `/var/lib/clamav-automation/database`. Das verhindert, dass Paketupdates
oder systemd-tmpfiles die Besitzrechte des von `freshclam` benötigten
Verzeichnisses auf den Distributionsbenutzer zurücksetzen. Bei einem Upgrade
übernimmt der Installer vorhandene `.cvd`- und `.cld`-Dateien aus
`/var/lib/clamav`, verändert dieses Verzeichnis aber nicht.

Eine bestehende Projektinstallation wird mit `sudo ./install.sh --upgrade`
aktualisiert. Konfiguration und SMTP-Zugangsdaten bleiben erhalten. Vor jeder
Änderung entsteht ein Backup unter `/var/backups/clamav-automation/`. Scheitert
Freshclam, startet der Upgradepfad `clamd` und `clamonacc` dennoch wieder und
beendet sich anschließend mit einer aussagekräftigen Fehlermeldung.

## SMTP separat testen

```bash
sudo /usr/local/libexec/clamav-automation/clamav-mail.py --kind test
```

## EICAR-Erkennung testen

Der interaktive Selbsttest kann eine EICAR-Testdatei in einem überwachten Pfad
erzeugen:

```bash
sudo /usr/local/libexec/clamav-automation/clamav-selftest.sh
```

Bei der EICAR-Abfrage mit `j` bestätigen. Ein erfolgreicher Test erzeugt sowohl
bei `clamd` als auch bei `clamonacc` eine Meldung `Eicar-Signature FOUND` und
ruft das konfigurierte Virus-Event auf. Dadurch wird auch die Malwarefund-Mail
ausgelöst. Die Testdatei wird anschließend entfernt.

Kontrolle:

```bash
journalctl --since '5 minutes ago' --no-pager \
  -u clamav-auto-clamd.service \
  -u clamav-auto-onaccess.service | grep -i eicar
```

## On-Access

```bash
systemctl status clamav-auto-onaccess
journalctl -fu clamav-auto-onaccess
```

Kernel:

```bash
ls -la /proc/sys/fs/fanotify/
```

## Konfiguration geändert

```bash
sudo /usr/local/libexec/clamav-automation/render-config.sh
sudo systemctl restart clamav-auto-clamd
sudo systemctl restart clamav-auto-onaccess
```

Bei Zeitplanänderungen zusätzlich:

```bash
sudo systemctl restart clamav-auto-freshclam.timer \
    clamav-auto-scan.timer \
    clamav-auto-heartbeat.timer
```

## SELinux

Auf RHEL/Rocky übernimmt der Installer die vorhandene SELinux-Pfadzuordnung von
`/var/lib/clamav` dauerhaft für `/var/lib/clamav-automation`. Ein lediglich mit
`restorecon` behandeltes Projektverzeichnis behält sonst den generischen Typ
`var_lib_t`; Freshclam kann dann trotz korrekter Unix-Rechte kein Verzeichnis
`database/tmp.*` erzeugen.

Manuelle Reparatur einer bereits betroffenen Installation:

```bash
sudo semanage fcontext -a -e /var/lib/clamav /var/lib/clamav-automation
sudo restorecon -RFv /var/lib/clamav-automation
sudo systemctl start clamav-auto-freshclam.service
```

Falls die Zuordnung bereits existiert, wird sie statt mit `-a` aktualisiert:

```bash
sudo semanage fcontext -m -e /var/lib/clamav /var/lib/clamav-automation
sudo restorecon -RFv /var/lib/clamav-automation
```

```bash
getenforce
getsebool antivirus_can_scan_system
sudo ausearch -m AVC -ts recent
```

## systemd-Zeitplan kontrollieren

```bash
systemd-analyze calendar '*-*-* 00,06,12,18:15:00'
systemd-analyze calendar '*-*-* 02:30:00'
systemd-analyze calendar '*-*-* 06:45:00'
```

## Security Audit betreiben

Timer und letzte Läufe:

```bash
systemctl list-timers 'clamav-auto-security-*'
journalctl -u clamav-auto-security-daily.service -n 100 --no-pager
journalctl -u clamav-auto-security-weekly.service -n 100 --no-pager
```

Manuelle Modi:

```bash
sudo /usr/local/libexec/clamav-automation/security-audit.sh --daily
sudo /usr/local/libexec/clamav-automation/security-audit.sh --weekly
sudo /usr/local/libexec/clamav-automation/security-audit.sh --incident
```

Reports liegen standardmäßig unter `/var/log/clamav-security`, unveränderliche
Vergleichsbaselines unter `/var/lib/clamav-security/baselines`. Eine Änderung
wird erst nach fachlicher Prüfung ausdrücklich als neuer Sollzustand übernommen:

```bash
sudo /usr/local/libexec/clamav-automation/security-audit.sh \
  --weekly --update-baseline
```

YARA-Regeln werden ausschließlich lokal als `.yar` oder `.yara` unter
`/etc/clamav-security/yara` verwaltet. Fehlende optionale Programme wie `yara`,
`paccheck` oder `getcap` brechen den Audit nicht ab.
