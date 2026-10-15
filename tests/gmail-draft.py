#!/usr/bin/env python3
"""Tests for files/scripts/gmail-draft.py: the message it builds keeps every link and header as
given, a reply carries the parent's threading headers, and a draft call sends what Gmail needs.
No network: the Gmail calls are replaced by the responses captured in tests/fixtures/gmail-draft/
(drafts-get-metadata.json with its From address and Received project number replaced).

    python3 tests/gmail-draft.py            # from the repo root"""
import base64
import email
import email.policy
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import unittest.mock

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
    def metadata(self, **headers):
        return {"payload": {"headers": [{"name": k.replace("_", "-"), "value": v} for k, v in headers.items()]}}

    def test_captured_message(self):
        original = fixture("messages-get-metadata.json")
        h = {x["name"].lower(): x["value"] for x in original["payload"]["headers"]}
        got = gd.reply_headers(original)
        self.assertEqual(got["In-Reply-To"], h["message-id"])
        self.assertTrue(got["References"].endswith(h["message-id"]))
        self.assertTrue(got["Subject"].lower().startswith("re:"))

    def test_references_extend_the_parents(self):
        got = gd.reply_headers(self.metadata(Message_Id="<p@m>", References="<a@m> <b@m>", Subject="Plan"))
        self.assertEqual(got, {"In-Reply-To": "<p@m>", "References": "<a@m> <b@m> <p@m>", "Subject": "Re: Plan"})

    def test_parent_in_reply_to_stands_in_for_missing_references(self):
        got = gd.reply_headers(self.metadata(Message_ID="<p@m>", In_Reply_To="<a@m>", Subject="RE: Plan"))
        self.assertEqual(got, {"In-Reply-To": "<p@m>", "References": "<a@m> <p@m>", "Subject": "RE: Plan"})

    def test_first_message_of_a_thread(self):
        got = gd.reply_headers(self.metadata(Message_ID="<p@m>", Subject="Plan"))
        self.assertEqual(got, {"In-Reply-To": "<p@m>", "References": "<p@m>", "Subject": "Re: Plan"})


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

    def fake_http(self, method, url, *, body=None, token=None, **_):
        self.calls.append((method, url, body))
        if "/messages/" in url:
            return fixture("messages-get-metadata.json")
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

    def test_reply_goes_into_the_parents_thread(self):
        original = fixture("messages-get-metadata.json")
        self.run_draft("--to", "a@example.com", "--reply-to", original["id"])
        get, create = self.calls
        self.assertEqual(get[0], "GET")
        self.assertIn(f"/messages/{original['id']}?format=metadata", get[1])
        self.assertEqual(create[2]["message"]["threadId"], original["threadId"])
        msg, want = self.sent(create), gd.reply_headers(original)
        self.assertEqual(tuple(header(msg, n) for n in ("In-Reply-To", "References", "Subject")),
                         (want["In-Reply-To"], want["References"], want["Subject"]))

    def test_update_keeps_what_it_is_not_given(self):
        old = fixture("drafts-get-metadata.json")["message"]
        h = gd.header_map(old)
        self.assertTrue({"to", "cc", "bcc", "in-reply-to"} <= h.keys(), "the fixture must be a reply with Cc and Bcc")
        self.run_draft("--update", "r123")
        get, put = self.calls
        self.assertEqual((get[0], get[1]), ("GET", f"{gd.API}/drafts/r123?format=metadata"))
        self.assertEqual((put[0], put[1], put[2]["id"]), ("PUT", f"{gd.API}/drafts/r123", "r123"))
        self.assertEqual(put[2]["message"]["threadId"], old["threadId"])
        msg = self.sent(put)
        for name in ("to", "cc", "bcc", "subject", "in-reply-to", "references"):
            self.assertEqual(header(msg, name), h[name], name)

    def test_update_takes_what_it_is_given(self):
        self.run_draft("--update", "r123", "--to", "new@example.com", "--subject", "New")
        msg = self.sent(self.calls[1])
        self.assertEqual((msg["To"], msg["Subject"]), ("new@example.com", "New"))
        self.assertEqual(msg["Cc"], gd.header_map(fixture("drafts-get-metadata.json")["message"])["cc"])

    def test_empty_body_is_refused_before_any_request(self):
        with self.assertRaises(SystemExit):
            self.run_draft("--to", "a@example.com", "--subject", "Hello", stdin=" \n")
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
