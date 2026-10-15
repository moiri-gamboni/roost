#!/usr/bin/env python3
"""gmail-draft: write a Gmail draft through the Gmail REST API, so its links stay as written.

The claude.ai Gmail connector's draft and send tools rewrite every URL in a body, a bare domain
included and in the plain-text and HTML parts alike, into
https://www.google.com/url?q=<url>&source=gmail&ust=<time>&sa=E, which recipients meet as a
Redirect Notice page (a bug in Google's Gmail MCP backend,
https://github.com/anthropics/claude-code/issues/66010). users.drafts.create with a raw RFC 2822
message stores the body verbatim. Drafts only: sending stays in Gmail.

    gmail-draft auth                    print the consent URL (once per box)
    gmail-draft auth REDIRECT_URL       finish: the URL the browser landed on after consent
    gmail-draft [--to ADDR ...] [--cc ADDR ...] [--bcc ADDR ...] [--subject TEXT]
                [--body-file FILE] [--html-file FILE] [--reply-to MESSAGE_ID] [--update DRAFT_ID]

The body is plain text from FILE, or stdin without --body-file; --html-file adds an HTML
alternative to it. --reply-to takes a Gmail message id (the connector's search_threads and
get_thread show them) and files the draft in that message's thread with In-Reply-To, References
and its subject, "Re: " added unless already there, so it refuses --subject; it sets no recipients
(pass --to) and does not quote the original. --update replaces a draft's message: the recipients,
subject and thread it is not given are kept from the draft, as the connector's update_draft does,
but the body is always given again. Its id is the one this tool printed or the connector's
list_drafts shows. An empty body is refused. No attachments, forwards or sending. Prints the draft
id, the thread id and a link that opens the draft (the form the connector's own viewUrl takes).

OAuth: the Desktop client in ~/.config/attention-queue/gmail-oauth-client.env (the mailbox's own
Workspace project), scopes gmail.compose (drafts; the scope would also let the token send, which
this tool never does) and gmail.readonly (the headers --reply-to reads; it covers the whole
mailbox); the refresh token is kept in ~/.config/gmail-draft/token.json. Nothing listens on the
redirect's loopback port, so the browser ends on a connection error whose address bar holds the
URL `auth` takes; the code in it is single-use and useless without the verifier kept here.
GMAIL_DRAFT_DEBUG=1 prints each Gmail API request and raw response to stderr."""
import argparse
import base64
import hashlib
import json
import os
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
from email.message import EmailMessage
from email.policy import SMTP
from typing import NoReturn

CLIENT_FILE = os.path.expanduser("~/.config/attention-queue/gmail-oauth-client.env")
STATE_DIR = os.path.expanduser("~/.config/gmail-draft")
TOKEN_FILE = os.path.join(STATE_DIR, "token.json")
PENDING_FILE = os.path.join(STATE_DIR, "pending-auth.json")
SCOPES = "https://www.googleapis.com/auth/gmail.compose https://www.googleapis.com/auth/gmail.readonly"
REDIRECT_URI = "http://127.0.0.1:8766/callback"
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
API = "https://gmail.googleapis.com/gmail/v1/users/me"
DEBUG = os.environ.get("GMAIL_DRAFT_DEBUG") == "1"


def die(msg) -> NoReturn:
    sys.exit(f"gmail-draft: {msg}")


def http(method, url, *, form=None, body=None, token=None, log=True):
    """One request; returns the parsed JSON. A non-2xx raises SystemExit carrying the raw body."""
    headers, data = {}, None
    if form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if DEBUG and log:
        print(f"> {method} {url}\n{data.decode() if data else ''}", file=sys.stderr)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data, headers, method=method), timeout=60) as r:
            status, raw = r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        die(f"{method} {url} -> {e.code}\n{e.read().decode(errors='replace')}")
    if DEBUG and log:
        print(f"< {status}\n{raw}", file=sys.stderr)
    return json.loads(raw)


def read_client():
    try:
        with open(CLIENT_FILE) as f:
            env = dict(line.strip().split("=", 1) for line in f if "=" in line)
    except FileNotFoundError:
        die(f"no OAuth client file at {CLIENT_FILE}")
    return env["GMAIL_OAUTH_CLIENT_ID"], env["GMAIL_OAUTH_CLIENT_SECRET"]


def write_private(path, obj):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(obj, f)
    os.replace(path + ".tmp", path)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def auth_start():
    client_id, _ = read_client()
    verifier, state = secrets.token_urlsafe(64), secrets.token_urlsafe(16)
    write_private(PENDING_FILE, {"verifier": verifier, "state": state})
    print(AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": client_id, "redirect_uri": REDIRECT_URI, "response_type": "code", "scope": SCOPES,
        "code_challenge": b64url(hashlib.sha256(verifier.encode()).digest()), "code_challenge_method": "S256",
        "state": state, "access_type": "offline", "prompt": "consent"}))


def auth_finish(redirect_url):
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(redirect_url).query)
    if "error" in query:
        die(f"consent refused: {query['error'][0]}")
    try:
        with open(PENDING_FILE) as f:
            pending = json.load(f)
    except FileNotFoundError:
        die("no consent in progress: run `gmail-draft auth` first")
    if query.get("state", [""])[0] != pending["state"]:
        die("this URL is from another consent than the last `gmail-draft auth` started")
    client_id, client_secret = read_client()
    grant = http("POST", TOKEN_URL, log=False, form={
        "client_id": client_id, "client_secret": client_secret, "code": query["code"][0],
        "code_verifier": pending["verifier"], "grant_type": "authorization_code", "redirect_uri": REDIRECT_URI})
    profile = http("GET", f"{API}/profile", token=grant["access_token"])
    write_private(TOKEN_FILE, {"refresh_token": grant["refresh_token"], "scope": grant["scope"],
                               "email": profile["emailAddress"]})
    os.remove(PENDING_FILE)
    print(f"authorized as {profile['emailAddress']} ({grant['scope']})")


def access_token(saved):
    client_id, client_secret = read_client()
    return http("POST", TOKEN_URL, log=False, form={
        "client_id": client_id, "client_secret": client_secret,
        "grant_type": "refresh_token", "refresh_token": saved["refresh_token"]})["access_token"]


def header_map(message):
    """A Gmail message resource's headers (METADATA format) by lowercased name."""
    return {x["name"].lower(): x["value"] for x in message["payload"]["headers"]}


def reply_headers(original):
    """Threading headers for a reply to `original`, a messages.get response in METADATA format
    (RFC 5322 3.6.4: References is the parent's References, or else its In-Reply-To, then its
    Message-ID)."""
    h = header_map(original)
    parent_refs = h.get("references") or h.get("in-reply-to") or ""
    subject = h.get("subject", "")
    return {
        "In-Reply-To": h["message-id"],
        "References": f"{parent_refs} {h['message-id']}".strip(),
        "Subject": subject if subject.lower().startswith("re:") else f"Re: {subject}",
    }


def build_message(to, cc, bcc, subject, text, html, extra_headers):
    msg = EmailMessage()
    for name, addrs in (("To", to), ("Cc", cc), ("Bcc", bcc)):
        if addrs:
            msg[name] = ", ".join(addrs)
    for name, value in extra_headers.items():
        msg[name] = value
    if subject is not None:
        msg["Subject"] = subject
    msg.set_content(text)
    if html is not None:
        msg.add_alternative(html, subtype="html")
    return msg.as_bytes(policy=SMTP)


def draft(args):
    text = open(args.body_file).read() if args.body_file else sys.stdin.read()
    if not text.strip():
        die("empty body: give it on stdin or with --body-file")
    html = open(args.html_file).read() if args.html_file else None
    try:
        with open(TOKEN_FILE) as f:
            saved = json.load(f)
    except FileNotFoundError:
        die("not authorized yet: run `gmail-draft auth`")
    token = access_token(saved)
    extra, thread_id = {}, None
    if args.update:
        # drafts.update replaces the whole message: keep what this call leaves out, as the
        # connector's update_draft does, so a partial update loses no recipient and no thread.
        old = http("GET", f"{API}/drafts/{args.update}?format=metadata", token=token)["message"]
        h = header_map(old)
        for field in ("to", "cc", "bcc"):
            if not getattr(args, field) and field in h:
                setattr(args, field, [h[field]])
        if args.subject is None and not args.reply_to:
            args.subject = h.get("subject")
        if "in-reply-to" in h and not args.reply_to:
            extra = {"In-Reply-To": h["in-reply-to"], "References": h.get("references", h["in-reply-to"])}
            thread_id = old["threadId"]
    if args.reply_to:
        original = http("GET", f"{API}/messages/{args.reply_to}?format=metadata&" + urllib.parse.urlencode(
            [("metadataHeaders", n) for n in ("Message-ID", "References", "In-Reply-To", "Subject")]), token=token)
        extra, thread_id = reply_headers(original), original["threadId"]
        args.subject = extra.pop("Subject")
    raw = build_message(args.to, args.cc, args.bcc, args.subject, text, html, extra)
    message = {"raw": base64.urlsafe_b64encode(raw).decode()}
    if thread_id:
        message["threadId"] = thread_id
    if args.update:
        result = http("PUT", f"{API}/drafts/{args.update}", body={"id": args.update, "message": message}, token=token)
    else:
        result = http("POST", f"{API}/drafts", body={"message": message}, token=token)
    tid = result["message"]["threadId"]
    print(f"draft {result['id']}  thread {tid}\nhttps://mail.google.com/mail/?authuser={saved['email']}"
          f"#all?compose=thread-f:{int(tid, 16)}%2Bmsg-a:{result['id']}")


def main():
    if sys.argv[1:2] == ["auth"]:
        if len(sys.argv) > 3:
            die("usage: gmail-draft auth [REDIRECT_URL]")
        return auth_finish(sys.argv[2]) if len(sys.argv) == 3 else auth_start()
    p = argparse.ArgumentParser(prog="gmail-draft", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--to", action="append", default=[])
    p.add_argument("--cc", action="append", default=[])
    p.add_argument("--bcc", action="append", default=[])
    p.add_argument("--subject")
    p.add_argument("--body-file")
    p.add_argument("--html-file")
    p.add_argument("--reply-to", metavar="MESSAGE_ID")
    p.add_argument("--update", metavar="DRAFT_ID")
    args = p.parse_args()
    if args.reply_to and args.subject is not None:
        p.error("a reply takes its subject from the message it answers (Gmail threads only on a matching subject)")
    draft(args)


if __name__ == "__main__":
    main()
