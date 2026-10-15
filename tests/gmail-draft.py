#!/usr/bin/env python3
"""Tests for files/scripts/gmail-draft.py: the message it builds keeps every link and header as
given, a reply carries the parent's threading headers and quotes it as Gmail does, and a draft
call sends what Gmail needs. No network: the Gmail calls are replaced by the responses captured
in tests/fixtures/gmail-draft/ (the From address and Received project number replaced in
drafts-get-metadata.json and messages-get-raw.json, and a name in the latter's body).

    python3 tests/gmail-draft.py            # from the repo root"""
import base64
import email
import email.policy
import email.utils
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "files", "scripts", "gmail-draft.py")
FIXTURES = os.path.join(HERE, "fixtures", "gmail-draft")
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("gd", SRC)
gd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gd)

LONG_URL = "https://example.com/a/very/long/path/that/runs/past/the/seventy-eight/column/limit?x=1&y=two%20words#frag"
TEXT = f"Hi Zoë,\n\nBare: {LONG_URL}\nDomain only: example.org\n"
HTML = f'<p>Anchor: <a href="{LONG_URL}">the page</a></p>'


def parse(raw):
    return email.message_from_bytes(raw, policy=email.policy.default)


def header(msg, name):
    """A header's value as Gmail reads it: Python keeps the space a folded header continues with."""
    return str(msg[name]).strip()


def content(part):
    """A part's decoded text with the wire's CRLF line ends read back as LF."""
    return part.get_content().replace("\r\n", "\n")


def fixture(name):
    with open(os.path.join(FIXTURES, name)) as f:
        return json.load(f)


def captured_parent():
    """The parent message of the captured reply, parsed from its messages.get RAW response."""
    return parse(base64.urlsafe_b64decode(fixture("messages-get-raw.json")["raw"]))


def message(text=None, html=None, **headers):
    """A synthetic parent: headers from keywords (Message_ID -> Message-ID), a text and/or HTML body."""
    msg = email.message.EmailMessage()
    for name, value in headers.items():
        msg[name.replace("_", "-")] = value
    if text is not None:
        msg.set_content(text)
    if html is not None:
        msg.add_alternative(html, subtype="html") if text is not None else msg.set_content(html, subtype="html")
    return parse(msg.as_bytes())


class BuildMessage(unittest.TestCase):
    def test_plain_body_is_kept_verbatim(self):
        msg = parse(gd.build_message(["a@example.com", "B <b@example.com>"], ["c@example.com"], ["d@example.com"],
                                     "Links", TEXT, None, {}))
        self.assertEqual(msg.get_content_type(), "text/plain")
        self.assertEqual(content(msg), TEXT)
        self.assertEqual(msg["To"], "a@example.com, B <b@example.com>")
        self.assertEqual((msg["Cc"], msg["Bcc"], msg["Subject"]), ("c@example.com", "d@example.com", "Links"))

    def test_html_is_an_alternative_to_the_plain_body(self):
        msg = parse(gd.build_message(["a@example.com"], [], [], "Links", TEXT, HTML, {}))
        self.assertEqual(msg.get_content_type(), "multipart/alternative")
        parts = {p.get_content_type(): content(p) for p in msg.iter_parts()}
        self.assertEqual(parts["text/plain"], TEXT)
        self.assertEqual(parts["text/html"].rstrip("\n"), HTML)

    def test_absent_fields_leave_no_header(self):
        msg = parse(gd.build_message([], [], [], None, "x\n", None, {}))
        for name in ("To", "Cc", "Bcc", "Subject"):
            self.assertNotIn(name, msg)

    def test_extra_headers_are_set(self):
        msg = parse(gd.build_message(["a@example.com"], [], [], "Re: x", "x\n", None,
                                     {"In-Reply-To": "<p@mail>", "References": "<g@mail> <p@mail>"}))
        self.assertEqual((msg["In-Reply-To"], msg["References"]), ("<p@mail>", "<g@mail> <p@mail>"))


class ReplyHeaders(unittest.TestCase):
    def test_captured_message(self):
        got = gd.reply_headers(captured_parent())
        msgid = gd.header_map(fixture("drafts-get-metadata.json")["message"])["in-reply-to"]
        self.assertEqual(got, {"In-Reply-To": msgid, "References": msgid, "Subject": "Re: [test] gmail-draft parent"})

    def test_references_extend_the_parents(self):
        folded = parse(b"Message-Id: <p@m>\r\nReferences: <a@m>\r\n\t<b@m>\r\nSubject: Plan\r\n\r\nx\r\n")
        got = gd.reply_headers(folded)
        self.assertEqual(got, {"In-Reply-To": "<p@m>", "References": "<a@m> <b@m> <p@m>", "Subject": "Re: Plan"})

    def test_parent_in_reply_to_stands_in_for_missing_references(self):
        got = gd.reply_headers(message(Message_ID="<p@m>", In_Reply_To="<a@m>", Subject="RE: Plan"))
        self.assertEqual(got, {"In-Reply-To": "<p@m>", "References": "<a@m> <p@m>", "Subject": "RE: Plan"})

    def test_first_message_of_a_thread(self):
        got = gd.reply_headers(message(Message_ID="<p@m>", Subject="Plan"))
        self.assertEqual(got, {"In-Reply-To": "<p@m>", "References": "<p@m>", "Subject": "Re: Plan"})


class Quote(unittest.TestCase):
    """quote_reply: Gmail's attribution line, '>' prefixes in text, a gmail_quote blockquote in HTML."""
    HEAD = dict(From="Ann Lee <ann@example.com>", Date="Tue, 13 Oct 2026 14:58:00 -0400")
    ON = "On Tue, Oct 13, 2026 at 2:58 PM"

    def test_text_and_html_parent(self):
        parent = message("Hi,\n\n> older line\nBye\n", "<html><head><style>p{}</style></head><body><p>Hi</p></body></html>",
                         **self.HEAD)
        text, html = gd.quote_reply("My answer.\n", None, parent)
        self.assertEqual(text, f"My answer.\n\n{self.ON} Ann Lee <ann@example.com> wrote:\n\n> Hi,\n>\n>> older line\n> Bye\n")
        self.assertTrue(html.startswith('<div dir="ltr">My answer.</div><br><div class="gmail_quote gmail_quote_container">'))
        self.assertIn(f'{self.ON} Ann Lee &lt;<a href="mailto:ann@example.com">ann@example.com</a>&gt; wrote:<br>', html)
        self.assertIn(f'<blockquote class="gmail_quote" style="{gd.QUOTE_STYLE}"><p>Hi</p></blockquote>', html)
        self.assertNotIn("<style>", html)

    def test_given_html_body_is_kept(self):
        _, html = gd.quote_reply("My answer.\n", "<p>My <b>answer</b>.</p>", message("Hi\n", **self.HEAD))
        self.assertTrue(html.startswith("<p>My <b>answer</b>.</p><br><div class=\"gmail_quote"))

    def test_text_only_parent_is_quoted_as_escaped_html(self):
        _, html = gd.quote_reply("x\n", None, message("a < b\nc\n", **self.HEAD))
        self.assertIn('padding-left:1ex">a &lt; b<br>\nc<br>\n</blockquote>', html)

    def test_html_only_parent_gives_the_plain_quote_its_text(self):
        text, _ = gd.quote_reply("x\n", None, message(html="<div>Hi &amp; bye</div><div>Second<br>third</div>", **self.HEAD))
        self.assertTrue(text.endswith("wrote:\n\n> Hi & bye\n> Second\n> third\n"), text)

    def test_captured_parent(self):
        text, html = gd.quote_reply("x\n", None, captured_parent())
        self.assertIn("On Thu, Oct 15, 2026 at 1:31 PM Test Sender <sender@example.com> wrote:", text)
        self.assertIn("> Long: https://example.com/a/very/long/path/that/runs/past/the/seventy-eight/column/limit?x=1&y=two%20words#frag\n", text)
        self.assertIn("> Accent: Zoë\n", text)
        self.assertIn('<a href="https://example.com/a/very/long/path/that/runs/past/the/seventy-eight/column/limit?x=1&amp;y=two%20words#frag">the page</a>', html)

    def test_text_to_html_links_urls_without_trailing_punctuation(self):
        self.assertEqual(gd.text_to_html("See https://example.com/a?b=1&c=2. Or <x>\n"),
                         '<div dir="ltr">See <a href="https://example.com/a?b=1&amp;c=2">https://example.com/a?b=1&amp;c=2</a>. Or &lt;x&gt;</div>')


class Draft(unittest.TestCase):
    """draft() end to end with the Gmail calls replaced by captured responses."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        token = os.path.join(self.tmp.name, "token.json")
        with open(token, "w") as f:
            json.dump({"refresh_token": "r", "scope": gd.SCOPES, "email": "me@example.com"}, f)
        self.calls = []
        patches = [unittest.mock.patch.object(gd, "TOKEN_FILE", token),
                   unittest.mock.patch.object(gd, "access_token", lambda saved: "t"),
                   unittest.mock.patch.object(gd, "http", self.fake_http)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    parent_gone = False

    def fake_http(self, method, url, *, body=None, token=None, **_):
        self.calls.append((method, url, body))
        if "/messages?" in url:
            return fixture("messages-list-empty.json" if self.parent_gone else "messages-list.json")
        if "/messages/" in url:
            return fixture("messages-get-raw.json")
        if method == "GET":
            return fixture("drafts-get-metadata.json")
        return fixture("drafts-create.json")

    def run_draft(self, *argv, stdin="Body https://example.com/x?y=1\n"):
        with unittest.mock.patch.object(sys, "argv", ["gmail-draft", *argv]), \
             unittest.mock.patch.object(sys, "stdin", io.StringIO(stdin)), \
             unittest.mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            gd.main()
        return out.getvalue()

    def sent(self, call):
        return parse(base64.urlsafe_b64decode(call[2]["message"]["raw"]))

    def test_new_draft(self):
        out = self.run_draft("--to", "a@example.com", "--subject", "Hello")
        (method, url, body), = self.calls
        self.assertEqual((method, url), ("POST", f"{gd.API}/drafts"))
        self.assertNotIn("threadId", body["message"])
        self.assertEqual(content(self.sent(self.calls[0])), "Body https://example.com/x?y=1\n")
        created = fixture("drafts-create.json")
        self.assertIn(f"draft {created['id']}", out)
        self.assertIn(f"thread-f:{int(created['message']['threadId'], 16)}%2Bmsg-a:{created['id']}", out)

    def assert_quotes_parent(self, msg):
        parts = {p.get_content_type(): content(p) for p in msg.iter_parts()}
        self.assertIn("Test Sender <sender@example.com> wrote:\n\n> Plain links test.\n", parts["text/plain"])
        self.assertIn('<blockquote class="gmail_quote"', parts["text/html"])

    def test_reply_goes_into_the_parents_thread_and_quotes_it(self):
        parent = fixture("messages-get-raw.json")
        self.run_draft("--to", "a@example.com", "--reply-to", parent["id"])
        get, create = self.calls
        self.assertEqual((get[0], get[1]), ("GET", f"{gd.API}/messages/{parent['id']}?format=raw"))
        self.assertEqual(create[2]["message"]["threadId"], parent["threadId"])
        msg, want = self.sent(create), gd.reply_headers(captured_parent())
        self.assertEqual(tuple(header(msg, n) for n in ("In-Reply-To", "References", "Subject")),
                         (want["In-Reply-To"], want["References"], want["Subject"]))
        self.assert_quotes_parent(msg)

    def test_update_keeps_what_it_is_not_given_and_quotes_again(self):
        old = fixture("drafts-get-metadata.json")["message"]
        h = gd.header_map(old)
        self.assertTrue({"to", "cc", "bcc", "in-reply-to"} <= h.keys(), "the fixture must be a reply with Cc and Bcc")
        self.run_draft("--update", "r123")
        get, search, parent, put = self.calls
        self.assertEqual(get[:2], ("GET", f"{gd.API}/drafts/r123?format=metadata"))
        self.assertEqual(search[:2], ("GET", f"{gd.API}/messages?" + urllib.parse.urlencode({"q": f"rfc822msgid:{h['in-reply-to']}"})))
        self.assertEqual(parent[1], f"{gd.API}/messages/{fixture('messages-list.json')['messages'][0]['id']}?format=raw")
        self.assertEqual((put[0], put[1], put[2]["id"]), ("PUT", f"{gd.API}/drafts/r123", "r123"))
        self.assertEqual(put[2]["message"]["threadId"], old["threadId"])
        msg = self.sent(put)
        for name in ("to", "cc", "bcc", "subject", "in-reply-to", "references"):
            self.assertEqual(header(msg, name), h[name], name)
        self.assert_quotes_parent(msg)

    def test_update_takes_what_it_is_given(self):
        self.run_draft("--update", "r123", "--to", "new@example.com", "--subject", "New")
        msg = self.sent(self.calls[-1])
        self.assertEqual((msg["To"], msg["Subject"]), ("new@example.com", "New"))
        self.assertEqual(msg["Cc"], gd.header_map(fixture("drafts-get-metadata.json")["message"])["cc"])

    def test_update_of_a_reply_whose_parent_is_gone_writes_nothing(self):
        self.parent_gone = True
        with self.assertRaises(SystemExit):
            self.run_draft("--update", "r123")
        self.assertNotIn("PUT", [c[0] for c in self.calls])

    def test_empty_body_is_refused_before_any_request(self):
        with self.assertRaises(SystemExit):
            self.run_draft("--to", "a@example.com", "--subject", "Hello", stdin=" \n")
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
