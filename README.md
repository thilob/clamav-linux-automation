# ClamAV Linux Automation

Ein distributionsübergreifendes Setup für **Arch Linux, Manjaro, RHEL und Rocky Linux**.

## Funktionen

- automatische Erkennung der Distribution
- Installation von ClamAV und `clamonacc`
- dauerhafter `clamd`
- Bereitschaftsprüfung des `clamd`-Sockets vor dem Start von `clamonacc`
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

Der Installer bricht vor jeder Änderung ab, wenn ClamAV-Binaries, installierte
ClamAV-Pakete oder aktive beziehungsweise für den automatischen Start aktivierte
systemd-Units gefunden werden. Dieser Abbruch kann nicht erzwungen werden.

Werden ausschließlich inaktive Unit-Dateien oder Templates gefunden, weist der
Installer auf einen erforderlichen Neustart hin. Nach Prüfung und Neustart kann
nur dieser Konflikttyp bewusst übergangen werden:

```bash
sudo ./install.sh --force-install
```

```bash
unzip clamav-linux-automation.zip
cd clamav-linux-automation
sudo ./install.sh \
  --smtp-host 'smtp.example.org' \
  --smtp-port 587 \
  --smtp-security starttls \
  --smtp-user 'clamav@example.org' \
  --smtp-password 'GEHEIMES-PASSWORT' \
  --mail-from 'clamav@example.org' \
  --mail-to 'admin@example.org'
```

### Geführte Installation im AS/400-Stil

Alternativ steht eine dialogbasierte Terminaloberfläche zur Verfügung:

```bash
sudo ./install-tui.sh
```

Für den gleichen Ausnahmefall unterstützt die TUI ebenfalls
`sudo ./install-tui.sh --force-install`.

Sie fragt SMTP-Zugang, Mailadressen, Scanpfade, Scanlimits, Erkennungsoptionen,
Zeitpläne und Protokollaufbewahrung ab. Vertrauliche Passwörter erscheinen weder
in der Zusammenfassung noch auf dem Bildschirm. Benötigt wird das Programm
`dialog` (`pacman -S dialog` beziehungsweise `dnf install dialog`).

Die klassische Installation übernimmt die SMTP-Daten ausschließlich aus diesen
Kommandozeilenoptionen und schreibt sie direkt in die geschützte
Konfigurationsdatei. Werte mit Sonderzeichen sollten in einfachen Anführungszeichen
stehen. Achtung: Ein Passwort als Kommandozeilenargument kann in Shell-History und
kurzzeitig in der Prozessliste sichtbar sein. Spätere Änderungen sind möglich mit:

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

Beim ersten Start lädt `clamd` mehrere Millionen Signaturen in den
Arbeitsspeicher. Je nach CPU, Datenträger und Datenbankgröße kann das ungefähr
30 bis 180 Sekunden dauern. Der Installer zeigt währenddessen regelmäßig einen
Wartestatus an und startet `clamonacc` erst, wenn der projektspezifische Socket
erfolgreich auf einen Ping antwortet.

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
- Erreichbarkeit des projektspezifischen `clamd`-Sockets
- Übersicht der Signaturdateien
- Journalmeldungen von `clamd`, `clamonacc`, FreshClam und Daily Scan der
  letzten 24 Stunden

So fällt auch ein Scanner auf, der zwar keinen Virus meldet, aber aufgrund
eines technischen Fehlers nicht mehr arbeitet.

## Ergänzender Security Audit

ClamAV erkennt bekannte schädliche Inhalte. Der ergänzende Security Audit sucht
dagegen nach Veränderungen an Konten, Persistenzmechanismen, Paketdateien,
Repositories und weiteren sicherheitsrelevanten Systemzuständen. Er ist bewusst
kein EDR und führt keinerlei automatische Gegenmaßnahmen aus.

Distributionsübergreifend werden – jeweils konfigurierbar – geprüft:

- Benutzer, UID/GID, zusätzliche UID-0-Konten und Kontodatei-Hashes
- aktivierte systemd-Services/Timer, Unit-Dateien und auffällige `ExecStart`-Pfade
- Cronjobs und andere zeitgesteuerte Persistenz
- `authorized_keys` anhand von Datei- und einzelnen Key-Fingerprints
- SUID/SGID-Dateien und Linux File-Capabilities
- Repository-Konfigurationen und optional Listening Sockets
- Zustand von `clamd` und FreshClam-Timer

Arch und Manjaro ergänzen `pacman -Qm`, bevorzugt `paccheck` und ersatzweise
`pacman -Qk`. RHEL und Rocky ergänzen `rpm -Va`, RPM-GPG-Key-Baselines und
DNF/YUM-Repositoryprüfungen. Konfigurationsabweichungen unter `/etc` werden nicht
pauschal als Angriff eingestuft.

Optional können lokal vorhandene AUR-Quellverzeichnisse über
`SECURITY_AUR_SOURCE_DIRS` statisch auf auffällige Konstrukte geprüft werden.
Treffer sind ausdrücklich Heuristiken und werden nicht als Malware-Beweis
behandelt; PKGBUILDs oder Installskripte werden niemals ausgeführt.

### Daily, Weekly und Incident

```bash
sudo /usr/local/libexec/clamav-automation/security-audit.sh --daily
sudo /usr/local/libexec/clamav-automation/security-audit.sh --weekly
sudo /usr/local/libexec/clamav-automation/security-audit.sh --incident
```

Daily führt die leichteren Zustandsprüfungen aus. Weekly ergänzt
Paketintegritäts- und YARA-Prüfungen. Incident führt den vollständigen Audit aus
und hängt Prozessbaum, Sockets, Kernelmodule, Login-Historie und relevante
Journalmeldungen an einen separaten Report an. `flock` verhindert überlappende
systemd-Läufe.

Ein ungefährlicher Testlauf ohne dauerhafte Baseline, Report oder Mail:

```bash
sudo /usr/local/libexec/clamav-automation/security-audit.sh --weekly --dry-run
```

### Baselines

Beim ersten Lauf wird je Prüftyp eine restriktiv geschützte Baseline unter
`/var/lib/clamav-security/baselines` erzeugt. Bestehende Einträge lösen dabei
keinen Alarm aus. Spätere Zustände und Diffs werden unter
`/var/log/clamav-security` abgelegt; Änderungen überschreiben die Baseline nicht.

Eine Baseline wird nur ausdrücklich aktualisiert:

```bash
sudo /usr/local/libexec/clamav-automation/security-audit.sh \
  --weekly --update-baseline
```

> Baselines müssen auf einem als vertrauenswürdig angesehenen Systemzustand
> erzeugt werden.

### Severity und Mail

- `INFO`: Initialisierung, entfernte Einträge und fehlende optionale Werkzeuge
- `WARNING`: neue Dienste, Cronjobs, Fremdpakete, Listener oder Integritätsabweichungen
- `CRITICAL`: zusätzliche UID-0-Konten, kritische SUID-/Capability-Funde,
  root-SSH-Key-Änderungen oder Persistenz aus temporären Pfaden

Benachrichtigungen verwenden ausschließlich den vorhandenen SMTP-Client. Mit
`SECURITY_NOTIFY_INFO`, `SECURITY_NOTIFY_WARNING` und
`SECURITY_NOTIFY_CRITICAL` wird festgelegt, welche Severity eine Mail auslöst.
Ein kurzer OK-Heartbeat ist separat konfigurierbar.

### YARA

YARA ist optional. Lokale Regeln mit Endung `.yar` oder `.yara` werden unter
`/etc/clamav-security/yara` abgelegt. Scanpfade stehen in
`SECURITY_YARA_SCAN_PATHS`. Es werden keine Regeln aus dem Internet geladen und
kein vollständiger Root-Dateisystemscan erzwungen. Fehlt `yara`, wird lediglich
ein INFO-Eintrag protokolliert.

### Datenschutz und Einschränkungen

Reports und Baselines sind nur für root lesbar. `/etc/shadow` wird ausschließlich
gehasht; sein Inhalt erscheint nie im Report. SSH-Schlüssel werden nicht
ausgegeben, sondern einzeln gehasht. Gefundene Dateien oder Inhalte werden nie
ausgeführt. Der Audit löscht oder deaktiviert keine Dateien, Konten, Pakete,
Dienste oder Schlüssel.

> Ein erfolgreicher Audit ohne Findings ist kein Beweis dafür, dass ein System
> nicht kompromittiert wurde.

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
│   ├── security-audit.sh
│   └── render-config.sh
├── systemd/
│   ├── clamav-auto-clamd.service
│   ├── clamav-auto-freshclam.service
│   ├── clamav-auto-heartbeat.service
│   ├── clamav-auto-onaccess.service
│   ├── clamav-auto-security-daily.service
│   ├── clamav-auto-security-weekly.service
│   └── clamav-auto-scan.service
└── tests/
    ├── security-audit-test.conf
    └── static-check.sh
```
