#!/usr/bin/env python3
import argparse
import configparser
import datetime as dt
import email.message
import os
import shlex
import smtplib
import socket
import ssl
import subprocess
import sys
from pathlib import Path

CONFIG = Path("/etc/clamav-automation/clamav-automation.conf")

def shell_var(name: str) -> str:
    # Bash wird nur zum Einlesen der vom Administrator kontrollierten Konfigurationsdatei benutzt.
    cmd = [
        "/bin/bash", "-c",
        f"set -a; source {shlex.quote(str(CONFIG))}; printf '%s' \"${{{name}:-}}\""
    ]
    return subprocess.check_output(cmd, text=True)

def expand(text: str, values: dict[str, str]) -> str:
    for key, value in values.items():
        text = text.replace("{" + key + "}", value)
    return text

def main() -> int:
    p = argparse.ArgumentParser(description="SMTP mail helper for ClamAV automation")
    p.add_argument("--kind", choices=["virus", "scan-error", "heartbeat", "test"], required=True)
    p.add_argument("--virus", default="")
    p.add_argument("--file", default="")
    p.add_argument("--details", default="")
    args = p.parse_args()

    host = shell_var("SMTP_HOST")
    port = int(shell_var("SMTP_PORT") or "587")
    security = (shell_var("SMTP_SECURITY") or "starttls").lower()
    username = shell_var("SMTP_USER")
    password = shell_var("SMTP_PASSWORD")
    mail_from = shell_var("MAIL_FROM")
    mail_to = shell_var("MAIL_TO")

    if args.kind == "virus":
        subject = shell_var("VIRUS_MAIL_SUBJECT")
        body = shell_var("VIRUS_MAIL_TEXT")
    elif args.kind == "scan-error":
        subject = shell_var("SCAN_ERROR_MAIL_SUBJECT")
        body = shell_var("SCAN_ERROR_MAIL_TEXT")
    elif args.kind == "heartbeat":
        subject = shell_var("HEARTBEAT_MAIL_SUBJECT")
        body = shell_var("HEARTBEAT_MAIL_TEXT")
    else:
        subject = "[ClamAV] SMTP-Test von {hostname}"
        body = """Dies ist eine Testnachricht der ClamAV-Automation.

Host: {hostname}
Zeit: {date}

Wenn diese Nachricht angekommen ist, funktioniert der SMTP-Versand.
"""

    if not host or not mail_from or not mail_to:
        print("SMTP_HOST, MAIL_FROM und MAIL_TO müssen gesetzt sein.", file=sys.stderr)
        return 2

    if security not in {"starttls", "ssl", "plain"}:
        print(f"Ungültiges SMTP_SECURITY: {security}", file=sys.stderr)
        return 2

    values = {
        "hostname": socket.getfqdn(),
        "date": dt.datetime.now().astimezone().isoformat(sep=" ", timespec="seconds"),
        "virus": args.virus or "unbekannt",
        "file": args.file or "unbekannt",
        "details": args.details,
    }
    subject = expand(subject, values)
    body = expand(body, values)

    msg = email.message.EmailMessage()
    msg["From"] = mail_from
    msg["To"] = mail_to
    msg["Subject"] = subject
    msg.set_content(body)

    context = ssl.create_default_context()
    smtp = None
    try:
        if security == "ssl":
            smtp = smtplib.SMTP_SSL(host, port, timeout=30, context=context)
        else:
            smtp = smtplib.SMTP(host, port, timeout=30)
            smtp.ehlo()
            if security == "starttls":
                smtp.starttls(context=context)
                smtp.ehlo()

        if username:
            smtp.login(username, password)

        smtp.send_message(msg)
        return 0
    finally:
        if smtp is not None:
            try:
                smtp.quit()
            except Exception:
                pass

if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Mailversand fehlgeschlagen: {exc}", file=sys.stderr)
        raise SystemExit(1)
