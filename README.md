# ClamAV Linux Automation

Ein distributionsübergreifendes Setup für **Arch Linux, Manjaro, RHEL und Rocky Linux**.

## Funktionen

- automatische Erkennung der Distribution
- Installation von ClamAV und `clamonacc`
- dauerhafter `clamd`
- dauerhafter On-Access-Scanner (`clamonacc`/fanotify)
- Signaturupdate viermal täglich, also alle sechs Stunden
- täglicher sinnvoll eingegrenzter Dateiscan
- SMTP-Mail bei Malwarefund
- SMTP-Mail bei Fehler des täglichen Scans
- tägliche Heartbeat-Mail inklusive `systemctl`-Status und `journalctl` der letzten 24 Stunden
- zentrale Konfiguration
- systemd-Timer
- interaktiver Selbsttest inkl. optionalem SMTP- und EICAR-Test
- Uninstaller
- keine automatische Löschung oder Quarantäne

## Unterstützte Distributionen

| Distribution | Installation |
|---|---|
| Arch Linux | `pacman`, Paket `clamav` |
| Manjaro | `pacman`, Paket `clamav` |
| Rocky Linux | `dnf`, EPEL |
| RHEL | `dnf`, EPEL |

Bei RHEL/Rocky werden nach Aktivierung von EPEL fehlende Programme zusätzlich über
`dnf repoquery --whatprovides` ermittelt. Dadurch ist das Setup weniger abhängig
von der genauen RPM-Aufteilung einer einzelnen EPEL-Version.

## Installation

```bash
unzip clamav-linux-automation.zip
cd clamav-linux-automation
sudo ./install.sh
```

Danach unbedingt die SMTP-Konfiguration anpassen:

```bash
sudo editor /etc/clamav-automation/clamav-automation.conf
```

Wesentliche Werte:

```bash
SMTP_HOST="smtp.example.org"
SMTP_PORT="587"
SMTP_SECURITY="starttls"
SMTP_USER="clamav@example.org"
SMTP_PASSWORD="..."
MAIL_FROM="clamav@example.org"
MAIL_TO="admin@example.org"
```

Die Konfigurationsdatei wird mit `0640 root:clamav-auto` installiert.

## SMTP-Modi

### STARTTLS, normalerweise Port 587

```bash
SMTP_PORT="587"
SMTP_SECURITY="starttls"
```

### SMTPS, normalerweise Port 465

```bash
SMTP_PORT="465"
SMTP_SECURITY="ssl"
```

### unverschlüsseltes SMTP

```bash
SMTP_SECURITY="plain"
```

`plain` sollte nur in einem vertrauenswürdigen internen Netz verwendet werden.

## Scanpfade

Standardmäßig:

```bash
DAILY_SCAN_PATHS=(
    "/home"
    "/root"
    "/etc"
    "/usr/local"
    "/opt"
    "/srv"
    "/var/www"
    "/tmp"
    "/var/tmp"
)
```

Absichtlich nicht als pauschaler Scan von `/`. Virtuelle Dateisysteme und große
Container-Layer können einen vollständigen Root-Scan unnötig langsam machen.

Für Datenserver bietet sich z. B. an:

```bash
DAILY_SCAN_PATHS=(
    "/home"
    "/srv"
    "/data"
)
```

Der tägliche Scan verwendet `clamdscan --fdpass`. Damit wird die vom Daemon
bereits geladene Signaturdatenbank wiederverwendet und root kann nicht direkt
lesbare Dateien per File Descriptor an den unprivilegierten Daemon übergeben.

## On-Access-Scanning

Standard:

```bash
ONACCESS_PATHS=(
    "/home"
    "/tmp"
    "/var/tmp"
)

ONACCESS_PREVENTION="no"
```

`/` darf nicht als On-Access-Pfad verwendet werden. Das Rendering-Skript lehnt
diese Konfiguration ausdrücklich ab.

Nach Änderungen:

```bash
sudo /usr/local/libexec/clamav-automation/render-config.sh
sudo systemctl restart clamav-auto-clamd.service
sudo systemctl restart clamav-auto-onaccess.service
```

### Prevention Mode

Mit

```bash
ONACCESS_PREVENTION="yes"
```

wird der Zugriff auf schädliche Dateien durch fanotify verhindert.

Für den Einstieg ist `no` konservativer, weil On-Access-Blocking bei stark
frequentierten Verzeichnissen Auswirkungen auf die I/O-Latenz haben kann.

## Zeitplan

Standard:

```text
00:15 / 06:15 / 12:15 / 18:15  FreshClam
02:30                         täglicher Scan
06:45                         Heartbeat
```

Zusätzlich verwendet systemd eine kleine zufällige Verzögerung.

Konfigurierbar mit:

```bash
FRESHCLAM_CALENDAR="*-*-* 00,06,12,18:15:00"
DAILY_SCAN_CALENDAR="*-*-* 02:30:00"
HEARTBEAT_CALENDAR="*-*-* 06:45:00"
```

Nach Timeränderungen:

```bash
sudo /usr/local/libexec/clamav-automation/render-config.sh
sudo systemctl restart clamav-auto-freshclam.timer
sudo systemctl restart clamav-auto-scan.timer
sudo systemctl restart clamav-auto-heartbeat.timer
```

## Dienste

```bash
systemctl status clamav-auto-clamd.service
systemctl status clamav-auto-onaccess.service
```

Timer:

```bash
systemctl list-timers 'clamav-auto-*'
```

Logs:

```bash
journalctl -u clamav-auto-clamd.service
journalctl -u clamav-auto-onaccess.service
journalctl -u clamav-auto-freshclam.service
journalctl -u clamav-auto-scan.service
```

Scanprotokolle:

```text
/var/log/clamav-automation/
```

## Selbsttest

```bash
sudo /usr/local/libexec/clamav-automation/clamav-selftest.sh
```

Der Test prüft:

1. benötigte Programme
2. clamd-Socket
3. systemd-Dienste
4. Timer
5. fanotify
6. Verbindung zu clamd
7. SELinux-Grundeinstellung
8. optional SMTP
9. optional EICAR

Der EICAR-String befindet sich **nicht fertig im Projektarchiv**. Er wird erst
während des Tests aus zwei Teilen zusammengesetzt. Dadurch wird vermieden, dass
das ZIP selbst von Virenscannern als EICAR-Testdatei blockiert wird.

## Virusmeldungen

Für Echtzeitfunde ist in `clamd.conf` ein `VirusEvent` eingetragen:

```text
/usr/local/libexec/clamav-automation/clamav-virus-event.sh
```

Es ruft den Python-SMTP-Client auf.

Der tägliche Scan verwendet dieselbe Mailfunktion.

Es erfolgt absichtlich **keine automatische Löschung** infizierter Dateien.

## Heartbeat

Die tägliche Heartbeat-Mail enthält:

- Status der ClamAV-Dienste
- Status der Timer
- ClamAV-Version
- Übersicht der Signaturdateien
- Journalmeldungen von `clamd`, `clamonacc`, FreshClam und Daily Scan der
  letzten 24 Stunden

So fällt auch ein Scanner auf, der zwar keinen Virus meldet, aber aufgrund
eines technischen Fehlers nicht mehr arbeitet.

## SELinux

Unter RHEL/Rocky aktiviert der Installer – soweit verfügbar:

```bash
setsebool -P antivirus_can_scan_system 1
```

Bei individuellen SELinux-Policies kann trotzdem eine zusätzliche Policy
erforderlich sein.

Diagnose:

```bash
sudo ausearch -m AVC -ts recent
```

## Konfiguration neu rendern

Die zentrale Konfiguration wird in die von ClamAV benötigte Konfiguration und
die Timer umgesetzt:

```bash
sudo /usr/local/libexec/clamav-automation/render-config.sh
```

## Statischer Projekttest

Vor der Installation:

```bash
./tests/static-check.sh
```

Er prüft Bash- und Python-Syntax.

## Deinstallation

Automation entfernen, Konfiguration behalten:

```bash
sudo ./uninstall.sh
```

Konfiguration ebenfalls entfernen:

```bash
sudo ./uninstall.sh --purge-config
```

Zusätzlich ClamAV-Pakete entfernen:

```bash
sudo ./uninstall.sh --purge-config --remove-packages
```

## Sicherheitshinweise

- SMTP-Passwort wird lokal in `/etc/clamav-automation/clamav-automation.conf`
  gespeichert.
- Dateirechte sind standardmäßig `0640 root:clamav-auto`.
- Das Projekt löscht Funde nicht automatisch.
- `clamonacc` läuft als root, weil fanotify die entsprechenden Rechte benötigt.
- `clamd` selbst wechselt über `User clamav-auto` in einen unprivilegierten
  Benutzer.
- On-Access-Scanning ersetzt keine Updates, Backups, Least Privilege und andere
  Schutzmaßnahmen.

## Projektstruktur

```text
clamav-linux-automation/
├── README.md
├── install.sh
├── uninstall.sh
├── config/
│   └── clamav-automation.conf.example
├── scripts/
│   ├── clamav-daily-scan.sh
│   ├── clamav-heartbeat.sh
│   ├── clamav-mail.py
│   ├── clamav-selftest.sh
│   ├── clamav-virus-event.sh
│   └── render-config.sh
├── systemd/
│   ├── clamav-auto-clamd.service
│   ├── clamav-auto-freshclam.service
│   ├── clamav-auto-heartbeat.service
│   ├── clamav-auto-onaccess.service
│   └── clamav-auto-scan.service
└── tests/
    └── static-check.sh
```
