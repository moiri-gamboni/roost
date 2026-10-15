#!/usr/bin/env python3
"""Tests for files/scripts/gmail-draft.py: the message it builds keeps every link and header as
given, a reply carries the parent's threading headers and quotes it as Gmail does, and a draft
call sends what Gmail needs. No network: the Gmail calls are replaced by the responses captured
in tests/fixtures/gmail-draft/ (in drafts-get-raw.json and messages-get-raw.json the account's
name and address replaced in the headers and the quote, and the Received project number).

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
    return gd.parse_raw(fixture("messages-get-raw.json")["raw"])


def captured_reply():
    """The captured reply draft (Cc, Bcc, report.pdf and notes.txt attached), parsed."""
    return gd.parse_raw(fixture("drafts-get-raw.json")["message"]["raw"])


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

    def test_long_message_ids_are_written_as_given(self):
        exchange = "<DM6PR12MB4251E1CE9E5C1C2F5F1D7A1BCA9A9@DM6PR12MB4251.namprd12.prod.outlook.com>"
        raw = gd.build_message(["a@example.com"], [], [], "Re: x", "x\n", None,
                               {"In-Reply-To": exchange, "References": f"<g@mail> {exchange}"})
        self.assertIn(f"In-Reply-To: {exchange}\r\nReferences: <g@mail>\r\n {exchange}\r\n".encode(), raw)
        msg = parse(raw)
        self.assertEqual((header(msg, "In-Reply-To"), " ".join(str(msg["References"]).split())), (exchange, f"<g@mail> {exchange}"))

    def test_extra_headers_are_set(self):
        msg = parse(gd.build_message(["a@example.com"], [], [], "Re: x", "x\n", None,
                                     {"In-Reply-To": "<p@mail>", "References": "<g@mail> <p@mail>"}))
        self.assertEqual((msg["In-Reply-To"], msg["References"]), ("<p@mail>", "<g@mail> <p@mail>"))


class ReplyHeaders(unittest.TestCase):
    def test_captured_message(self):
        got = gd.reply_headers(captured_parent())
        msgid = gd.header_value(captured_reply(), "In-Reply-To")
        self.assertEqual(got, {"In-Reply-To": msgid, "References": msgid, "Subject": "Re: [test] gmail-draft parent 2"})

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
        self.assertIn("On Thu, Oct 15, 2026 at 2:44 PM Test Sender <sender@example.com> wrote:\n\n"
                      "> Parent for the attachment test, from Zoë. Link https://example.com/p\n", text)
        self.assertIn("Parent for the attachment test, from Zoë. Link https://example.com/p<br>", html)

    def test_cid_images_are_dropped_from_the_quote(self):
        parent = message("Hi\n", '<body><p>Hi</p><img width="80" src="cid:image001.png@01DB"><img src="https://example.com/x.png"></body>',
                         **self.HEAD)
        _, html = gd.quote_reply("x\n", None, parent)
        self.assertNotIn("cid:", html)
        self.assertIn('<img src="https://example.com/x.png">', html)

    def test_head_and_styles_stay_out_of_both_quotes(self):
        page = "<html><head><title>Big Sale</title><style>body { margin:0 }</style></head><div>Deal</div></html>"
        text, html = gd.quote_reply("x\n", None, message(html=page, **self.HEAD))
        self.assertTrue(text.endswith("wrote:\n\n> Deal\n"), text)
        self.assertNotIn("body { margin", html)
        self.assertNotIn("Big Sale", html)

    def test_text_to_html_url_edges(self):
        for given, href, after in (("see <https://example.com/foo> now", "https://example.com/foo", "&gt; now"),
                                   ("https://en.wikipedia.org/wiki/Python_(programming_language)",
                                    "https://en.wikipedia.org/wiki/Python_(programming_language)", ""),
                                   ("(see https://example.com/a)", "https://example.com/a", ")"),
                                   ("Is it https://example.com/q?", "https://example.com/q", "?")):
            self.assertIn(f'<a href="{href}">{href}</a>{after}', gd.text_to_html(given), given)

    def test_text_to_html_links_urls_without_trailing_punctuation(self):
        self.assertEqual(gd.text_to_html("See https://example.com/a?b=1&c=2. Or <x>\n"),
                         '<div dir="ltr">See <a href="https://example.com/a?b=1&amp;c=2">https://example.com/a?b=1&amp;c=2</a>. Or &lt;x&gt;</div>')


class Upload(unittest.TestCase):
    def test_http_sends_the_draft_as_a_multipart_upload(self):
        seen = {}

        class Response(io.BytesIO):
            status = 200
            def __enter__(self): return self
            def __exit__(self, *a): pass

        def urlopen(request, timeout):
            seen["request"] = request
            return Response(b'{"id": "r1"}')

        raw = gd.build_message(["a@example.com"], [], [], "Hi", "Body\n", None, {})
        with unittest.mock.patch.object(gd.urllib.request, "urlopen", urlopen):
            self.assertEqual(gd.http("POST", gd.UPLOAD + "/drafts?uploadType=multipart",
                                     upload=({"message": {"threadId": "t1"}}, raw), token="tok"), {"id": "r1"})
        request = seen["request"]
        self.assertEqual(request.get_header("Authorization"), "Bearer tok")
        body = parse(f"Content-Type: {request.get_header('Content-type')}\r\n\r\n".encode() + request.data)
        meta, message = body.iter_parts()
        self.assertEqual(body.get_content_type(), "multipart/related")
        self.assertEqual((meta.get_content_type(), json.loads(meta.get_content())), ("application/json", {"message": {"threadId": "t1"}}))
        self.assertEqual(message.get_content_type(), "message/rfc822")
        self.assertEqual(content(message.get_content()), "Body\n")


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
                   unittest.mock.patch.object(gd, "TZ_FILE", os.path.join(self.tmp.name, "no-timezone")),
                   unittest.mock.patch.object(gd, "access_token", lambda saved: "t"),
                   unittest.mock.patch.object(gd, "http", self.fake_http)]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    parent_gone = False
    thread = None    # what threads.get returns; None: a thread holding only the captured parent
    parent = None    # what messages.get returns; None: the captured parent

    def fake_http(self, method, url, *, body=None, upload=None, token=None, **_):
        self.calls.append((method, url, body if upload is None else upload))
        if "/messages?" in url:
            return fixture("messages-list-empty.json" if self.parent_gone else "messages-list.json")
        if "/threads/" in url:
            p = fixture("messages-get-raw.json")
            return self.thread or {"id": p["threadId"], "messages": [{"id": p["id"], "threadId": p["threadId"], "labelIds": ["INBOX"]}]}
        if "/messages/" in url:
            return self.parent or fixture("messages-get-raw.json")
        if method == "GET":
            return fixture("drafts-get-raw.json")
        return fixture("drafts-create.json")

    def run_draft(self, *argv, stdin="Body https://example.com/x?y=1\n"):
        with unittest.mock.patch.object(sys, "argv", ["gmail-draft", *argv]), \
             unittest.mock.patch.object(sys, "stdin", io.StringIO(stdin)), \
             unittest.mock.patch("sys.stderr", new_callable=io.StringIO) as err, \
             unittest.mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            gd.main()
        self.stderr = err.getvalue()
        return out.getvalue()

    def sent(self, call):
        """The message an upload call sent; call[2] is its (Draft metadata, message bytes)."""
        return parse(call[2][1])

    def test_new_draft(self):
        out = self.run_draft("--to", "a@example.com", "--subject", "Hello")
        (method, url, (meta, _)), = self.calls
        self.assertEqual((method, url), ("POST", f"{gd.UPLOAD}/drafts?uploadType=multipart"))
        self.assertEqual(meta, {"message": {}})
        self.assertEqual(content(self.sent(self.calls[0])), "Body https://example.com/x?y=1\n")
        created = fixture("drafts-create.json")
        self.assertIn(f"draft {created['id']}", out)
        self.assertIn(f"thread-f:{int(created['message']['threadId'], 16)}%2Bmsg-a:{created['id']}", out)

    def assert_quotes_parent(self, msg):
        parts = {p.get_content_type(): content(p) for p in msg.walk() if not p.is_multipart() and not p.get_filename()}
        self.assertIn("Test Sender <sender@example.com> wrote:\n\n> Parent for the attachment test", parts["text/plain"])
        self.assertIn('<blockquote class="gmail_quote"', parts["text/html"])

    def test_reply_goes_into_the_parents_thread_and_quotes_it(self):
        parent = fixture("messages-get-raw.json")
        self.run_draft("--to", "a@example.com", "--reply-to", parent["id"])
        get, thread, create = self.calls    # the parent is its thread's first message, and its only one
        self.assertEqual((get[0], get[1]), ("GET", f"{gd.API}/messages/{parent['id']}?format=raw"))
        self.assertEqual(thread[1], f"{gd.API}/threads/{parent['threadId']}?format=minimal")
        self.assertEqual(create[2][0], {"message": {"threadId": parent["threadId"]}})
        msg, want = self.sent(create), gd.reply_headers(captured_parent())
        self.assertEqual(tuple(header(msg, n) for n in ("In-Reply-To", "References", "Subject")),
                         (want["In-Reply-To"], want["References"], want["Subject"]))
        self.assert_quotes_parent(msg)

    def test_a_thread_id_answers_the_threads_newest_message(self):
        self.thread = fixture("threads-get-minimal.json")
        first, newest = self.thread["messages"][0]["id"], self.thread["messages"][-1]["id"]
        self.parent = {**fixture("messages-get-raw.json"), "id": first, "threadId": self.thread["id"]}
        self.run_draft("--to", "a@example.com", "--reply-to", first)
        self.assertEqual([c[1] for c in self.calls[:3]], [f"{gd.API}/messages/{first}?format=raw",
                                                           f"{gd.API}/threads/{first}?format=minimal",
                                                           f"{gd.API}/messages/{newest}?format=raw"])
        self.assertIn(f"replying to the thread's newest message, {newest}", self.stderr)

    def test_drafts_in_the_thread_are_not_its_newest_message(self):
        self.thread = fixture("threads-get-minimal.json")
        self.thread["messages"].append({"id": "d1", "threadId": self.thread["id"], "labelIds": ["DRAFT"]})
        first, newest = self.thread["messages"][0]["id"], self.thread["messages"][-2]["id"]
        self.parent = {**fixture("messages-get-raw.json"), "id": first, "threadId": self.thread["id"]}
        self.run_draft("--to", "a@example.com", "--reply-to", first)
        self.assertEqual(self.calls[2][1], f"{gd.API}/messages/{newest}?format=raw")

    def test_a_later_message_id_is_answered_as_given(self):
        self.parent = {**fixture("messages-get-raw.json"), "id": "m2", "threadId": "t1"}
        self.run_draft("--to", "a@example.com", "--reply-to", "m2")
        self.assertEqual([c[0] + " " + c[1] for c in self.calls], [f"GET {gd.API}/messages/m2?format=raw",
                                                                    f"POST {gd.UPLOAD}/drafts?uploadType=multipart"])
        self.assertEqual(self.stderr, "")

    def test_update_keeps_what_it_is_not_given_and_quotes_again(self):
        old, thread = captured_reply(), fixture("drafts-get-raw.json")["message"]["threadId"]
        h = {name: gd.header_value(old, name) for name in ("to", "cc", "bcc", "subject", "in-reply-to", "references")}
        self.assertTrue(all(h.values()), "the fixture must be a reply with Cc and Bcc")
        self.run_draft("--update", "r123")
        get, search, parent, put = self.calls
        self.assertEqual(get[:2], ("GET", f"{gd.API}/drafts/r123?format=raw"))
        self.assertEqual(search[:2], ("GET", f"{gd.API}/messages?" + urllib.parse.urlencode({"q": f"rfc822msgid:{h['in-reply-to']}"})))
        self.assertEqual(parent[1], f"{gd.API}/messages/{fixture('messages-list.json')['messages'][0]['id']}?format=raw")
        self.assertEqual((put[0], put[1]), ("PUT", f"{gd.UPLOAD}/drafts/r123?uploadType=multipart"))
        self.assertEqual(put[2][0], {"id": "r123", "message": {"threadId": thread}})
        msg = self.sent(put)
        for name in h:
            self.assertEqual(gd.header_value(msg, name), h[name], name)
        self.assert_quotes_parent(msg)
        self.assertEqual(self.attachments(msg), self.attachments(old))

    def attachments(self, msg):
        return [(p.get_filename(), p.get_content_type(), p.get_payload(decode=True)) for p in msg.iter_attachments()]

    def test_update_attach_adds_and_replaces_by_file_name(self):
        notes, extra = os.path.join(self.tmp.name, "notes.txt"), os.path.join(self.tmp.name, "extra.csv")
        for path, data in ((notes, "v2 notes\n"), (extra, "a,b\n")):
            with open(path, "w") as f:
                f.write(data)
        self.run_draft("--update", "r123", "--attach", notes, "--attach", extra)
        got = self.attachments(self.sent(self.calls[-1]))
        report = [a for a in self.attachments(captured_reply()) if a[0] == "report.pdf"]
        self.assertEqual(got, report + [("notes.txt", "text/plain", b"v2 notes\n"), ("extra.csv", "text/csv", b"a,b\n")])

    def test_update_takes_what_it_is_given(self):
        self.run_draft("--update", "r123", "--to", "new@example.com", "--subject", "New")
        msg = self.sent(self.calls[-1])
        self.assertEqual((msg["To"], msg["Subject"]), ("new@example.com", "New"))
        self.assertEqual(msg["Cc"], gd.header_value(captured_reply(), "Cc"))

    def test_update_of_a_reply_whose_parent_is_gone_writes_nothing(self):
        self.parent_gone = True
        with self.assertRaises(SystemExit):
            self.run_draft("--update", "r123")
        self.assertNotIn("PUT", [c[0] for c in self.calls])

    def test_attachments_ride_along(self):
        path = os.path.join(self.tmp.name, "notes.pdf")
        with open(path, "wb") as f:
            f.write(b"%PDF-1.4 x")
        self.run_draft("--to", "a@example.com", "--subject", "Hello", "--attach", path)
        att, = self.sent(self.calls[0]).iter_attachments()
        self.assertEqual((att.get_content_type(), att.get_filename(), att.get_content()), ("application/pdf", "notes.pdf", b"%PDF-1.4 x"))

    def test_missing_attachment_is_refused_before_any_request(self):
        with self.assertRaises(SystemExit):
            self.run_draft("--to", "a@example.com", "--subject", "Hello", "--attach", "/nonexistent/file.pdf")
        self.assertEqual(self.calls, [])

    def test_reply_quote_uses_the_configured_zone(self):
        tz_file = os.path.join(self.tmp.name, "timezone")
        with open(tz_file, "w") as f:
            f.write("Europe/Paris\n")
        with unittest.mock.patch.object(gd, "TZ_FILE", tz_file):
            self.run_draft("--to", "a@example.com", "--reply-to", fixture("messages-get-raw.json")["id"])
        # the captured parent is dated 14:44 -0400, 20:44 in Paris
        self.assertIn("On Thu, Oct 15, 2026 at 8:44 PM Test Sender", content(self.sent(self.calls[-1]).get_body(("plain",))))

    def test_empty_body_is_refused_before_any_request(self):
        with self.assertRaises(SystemExit):
            self.run_draft("--to", "a@example.com", "--subject", "Hello", stdin=" \n")
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
