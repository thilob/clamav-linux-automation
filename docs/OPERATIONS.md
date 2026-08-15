# Betrieb und Fehlersuche

## Schnellcheck

```bash
sudo systemctl --failed
sudo systemctl list-timers 'clamav-auto-*'
sudo systemctl status clamav-auto-clamd clamav-auto-onaccess
sudo /usr/local/libexec/clamav-automation/clamav-selftest.sh
```

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
