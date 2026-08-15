# Betrieb und Fehlersuche

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

Falls `Can't open/parse the config file` erscheint, Rechte kontrollieren:

```bash
sudo stat -c '%U:%G %a %n' \
  /etc/clamav-automation \
  /etc/clamav-automation/clamd.conf
```

Erwartet werden `root:clamav-auto 750` für das Verzeichnis und
`root:clamav-auto 640` für `clamd.conf`.

Damit `/tmp` per On-Access-Scan überwacht werden kann, verwendet `clamd`
`/var/lib/clamav/tmp` als eigenes temporäres Verzeichnis. Die Meldung
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

Detailprotokoll:

```bash
sudo ls -lh /var/log/clamav-automation/
```

## Heartbeat manuell senden

```bash
sudo systemctl start clamav-auto-heartbeat.service
```

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
