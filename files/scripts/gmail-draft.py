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
(pass --to). It quotes that message as Gmail does: "On <date> <sender> wrote:", then its text
with "> " prefixes in the plain part and its HTML in a gmail_quote blockquote in the HTML part
(made from the plain body, URLs linked, when --html-file is not given). --update replaces a
draft's message: the recipients, subject and thread it is not given are kept from the draft, as
the connector's update_draft does, and a reply's quote is rebuilt from the message it answers, but
the body is always given again. Its id is the one this tool printed or the connector's list_drafts
shows. An empty body is refused. No attachments, forwards or sending. Prints the draft
id, the thread id and a link that opens the draft (the form the connector's own viewUrl takes).

OAuth: the Desktop client in ~/.config/attention-queue/gmail-oauth-client.env (the mailbox's own
Workspace project), scopes gmail.compose (drafts; the scope would also let the token send, which
this tool never does) and gmail.readonly (the message --reply-to quotes; it covers the whole
mailbox); the refresh token is kept in ~/.config/gmail-draft/token.json. Nothing listens on the
redirect's loopback port, so the browser ends on a connection error whose address bar holds the
URL `auth` takes; the code in it is single-use and useless without the verifier kept here.
GMAIL_DRAFT_DEBUG=1 prints each Gmail API request and raw response to stderr."""
import argparse
import base64
import email
import email.policy
import email.utils
import hashlib
import html
import json
import os
import re
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
QUOTE_STYLE = "margin:0px 0px 0px 0.8ex;border-left:1px solid rgb(204,204,204);padding-left:1ex"


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
    """Threading headers for a reply to `original`, the parsed parent message (RFC 5322 3.6.4:
    References is the parent's References, or else its In-Reply-To, then its Message-ID)."""
    def h(name):
        return " ".join(str(original[name] or "").split())    # unfolded
    parent_refs = h("References") or h("In-Reply-To")
    subject = h("Subject")
    return {
        "In-Reply-To": h("Message-ID"),
        "References": f"{parent_refs} {h('Message-ID')}".strip(),
        "Subject": subject if subject.lower().startswith("re:") else f"Re: {subject}",
    }


def part_text(msg, subtype):
    """The decoded text of `msg`'s text/<subtype> body, or None when it has none."""
    part = msg.get_body(preferencelist=(subtype,))
    return part.get_content() if part is not None else None


def split_url(url):
    """A matched URL and the punctuation after it: a trailing ".,;:!?'" ends the sentence, and a
    trailing ")" closes a parenthesis opened before the URL unless the URL opened one itself."""
    end = len(url)
    while url[end - 1] in ".,;:!?'" or (url[end - 1] == ")" and url[:end].count(")") > url[:end].count("(")):
        end -= 1
    return url[:end], url[end:]


def text_to_html(text):
    """Plain text as HTML with its http(s) URLs linked: a reply needs an HTML part for the quote."""
    pieces = re.split(r"(https?://[^\s<>\"]+)", text.rstrip("\n"))    # odd pieces are URLs
    out = []
    for i, piece in enumerate(pieces):
        if i % 2:
            url, tail = split_url(piece)
            out.append(f'<a href="{html.escape(url)}">{html.escape(url, quote=False)}</a>{html.escape(tail, quote=False)}')
        else:
            out.append(html.escape(piece, quote=False))
    return '<div dir="ltr">' + "".join(out).replace("\n", "<br>\n") + "</div>"


def without_head(markup):
    """HTML without its <head>, <style> and <script> blocks, which must not leak into a quote."""
    return re.sub(r"(?is)<(head|style|script)\b.*?</\1\s*>", "", markup)


def quote_reply(text, html_body, original):
    """The reply's plain and HTML bodies with `original` quoted below them as Gmail quotes it."""
    name, addr = email.utils.parseaddr(str(original["From"] or ""))
    when = email.utils.parsedate_to_datetime(str(original["Date"]))
    on = f"On {when:%a, %b} {when.day}, {when.year} at {when.hour % 12 or 12}:{when:%M %p}"
    parent_html, parent_text = part_text(original, "html"), part_text(original, "plain")
    if parent_text is None:    # an HTML-only message: its text, tags dropped, for the plain part
        parent_text = html.unescape(re.sub(r"<[^>]+>", "", re.sub(r"(?i)<br\s*/?>|</p>|</div>", "\n",
                                                                  without_head(parent_html or ""))))
    lines = parent_text.replace("\r\n", "\n").rstrip("\n").split("\n")
    quoted = "\n".join(">" + ("" if not line or line.startswith(">") else " ") + line for line in lines)
    who = f"{name} <{addr}>" if name else f"<{addr}>"
    who_html = (f"{html.escape(name)} " if name else "") + f'&lt;<a href="mailto:{html.escape(addr)}">{html.escape(addr)}</a>&gt;'
    if parent_html is not None:
        body = re.search(r"<body[^>]*>(.*)</body>", parent_html, re.S | re.I)
        inner = body[1] if body else without_head(parent_html)
        # inline images (an Outlook signature logo) live in parts the draft does not carry
        inner = re.sub(r"""(?i)<img\b[^>]*\bsrc\s*=\s*["']?cid:[^>]*>""", "", inner)
    else:
        inner = html.escape(parent_text, quote=False).replace("\n", "<br>\n")
    if html_body is None:
        html_body = text_to_html(text)
    return (f"{text.rstrip()}\n\n{on} {who} wrote:\n\n{quoted}\n",
            f'{html_body}<br><div class="gmail_quote gmail_quote_container"><div dir="ltr" class="gmail_attr">{on} {who_html} wrote:<br></div>'
            f'<blockquote class="gmail_quote" style="{QUOTE_STYLE}">{inner}</blockquote></div>')


def build_message(to, cc, bcc, subject, text, html_body, msgid_headers):
    """The draft as RFC 5322 bytes. msgid_headers (In-Reply-To, References) are written as given, one
    id per line: the email policy would RFC 2047-encode an id longer than a line (Exchange's are
    80+ characters), and no mail client threads on an encoded id."""
    msg = EmailMessage()
    for name, addrs in (("To", to), ("Cc", cc), ("Bcc", bcc)):
        if addrs:
            msg[name] = ", ".join(addrs)
    if subject is not None:
        msg["Subject"] = subject
    msg.set_content(text)
    if html_body is not None:
        msg.add_alternative(html_body, subtype="html")
    ids = "".join(f"{name}: " + "\r\n ".join(value.split()) + "\r\n" for name, value in msgid_headers.items())
    return ids.encode() + msg.as_bytes(policy=SMTP)


def draft(args):
    text = open(args.body_file).read() if args.body_file else sys.stdin.read()
    if not text.strip():
        die("empty body: give it on stdin or with --body-file")
    html_body = open(args.html_file).read() if args.html_file else None
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
        if "in-reply-to" in h and not args.reply_to:    # a reply: its new body needs the quote again
            found = http("GET", f"{API}/messages?" + urllib.parse.urlencode({"q": f"rfc822msgid:{h['in-reply-to']}"}),
                         token=token)
            if "messages" not in found:
                die(f"draft {args.update} answers {h['in-reply-to']}, which is no longer in the mailbox: pass --reply-to")
            args.reply_to = found["messages"][0]["id"]
    if args.reply_to:
        parent = http("GET", f"{API}/messages/{args.reply_to}?format=raw", token=token)
        original = email.message_from_bytes(base64.urlsafe_b64decode(parent["raw"]), policy=email.policy.default)
        extra, thread_id = reply_headers(original), parent["threadId"]
        subject = extra.pop("Subject")
        if args.subject is None:
            args.subject = subject
        text, html_body = quote_reply(text, html_body, original)
    raw = build_message(args.to, args.cc, args.bcc, args.subject, text, html_body, extra)
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
