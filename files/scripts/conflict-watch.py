#!/usr/bin/env python3
"""conflict-watch: which open Claude Code session is working in which unit, so two sessions do not
edit the same folder or repo without knowing.

A unit is a folder the rules in conflict-watch.conf name: a task folder, a first-level entry of
the workspace's plans/, notes/ or data/, or a whole code repo. A session holds every unit it
writes into for as long as it is open (the Claude Code registry, $CLAUDE_CONFIG_DIR/sessions),
until it or the user releases it. The root daemon (`run`) sees every close-after-write on the
mount holding ~/roost through fanotify — notification events only, so a dead or slow daemon
never blocks a write — and credits it to a session by walking the writer's parent chain to the
outermost registered claude process; the proc connector's fork events keep that chain for
writers that exit before their event is read (`sed -i`). A write into a unit another open session
holds puts a notice in both sessions' inboxes; the hook (hooks/conflict-watch-hook.sh) hands them
to the model and warns before an Edit/Write there, a Bash command naming it, or a repo-wide git
command that would change files another session wrote (`hook-git`). A warning is a deny, once per
session, unit and hold; the retry passes. Nothing ever raises a permission prompt. If the daemon
is down nothing is watched and nothing is blocked; the health check alerts.

    conflict-watch status                  which session holds which unit, and the counters
    conflict-watch release [UNIT|PATH ...] [--session NAME|ID]
                                           drop this session's holds (all of them without units)
    conflict-watch allow UNIT|PATH         the user said go ahead: work beside the holder, unflagged
    conflict-watch unit PATH               the unit a path belongs to
    conflict-watch run                     the daemon (root, conflict-watch.service)"""
import collections
import fnmatch
import json
import os
import shlex
import subprocess
import sys
import time

# The hook runs this script before repo-wide git commands, so start-up time is user-visible:
# modules only the daemon or the argument parser need are imported where they are used.


class Rules:
    """The unit rules from conflict-watch.conf (its header documents the format)."""

    def __init__(self, root, rules, skip_names, skip_writers):
        self.root = root.rstrip("/")
        self.rules = rules              # [(kind, [component globs])], first match wins
        self.skip_names = skip_names
        self.skip_writers = skip_writers
        self._repo_cache = {}

    @classmethod
    def load(cls, conf, root):
        rules, skip_names, skip_writers = [], [], []
        with open(conf) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                key, _, arg = line.partition(" ")
                arg = arg.strip()
                if key in ("ignore", "unit", "repos"):
                    rules.append((key, [c for c in arg.split("/") if c]))
                elif key == "skip-name":
                    skip_names += arg.split()
                elif key == "skip-writer":
                    skip_writers.append(arg)
                else:
                    raise ValueError(f"{conf}: unknown rule {key!r}")
        return cls(root, rules, skip_names, skip_writers)

    def unit_of(self, path):
        """(unit path, "folder" | "repo") for an absolute path, or None when no unit contains it."""
        if not path.startswith(self.root + "/"):
            return None
        parts = path[len(self.root) + 1:].split("/")
        if any(fnmatch.fnmatchcase(p, pat) for p in parts for pat in self.skip_names):
            return None
        for kind, globs in self.rules:
            n = len(globs)
            if len(parts) < n or not all(fnmatch.fnmatchcase(p, g) for p, g in zip(parts, globs)):
                continue
            if kind == "ignore":
                return None
            if kind == "unit":
                return os.path.join(self.root, *parts[:n]), "folder"
            # repos: innermost directory strictly below the base (and above the file) with a .git
            for depth in range(len(parts) - 1, n, -1):
                d = os.path.join(self.root, *parts[:depth])
                if self._has_git(d):
                    return d, "repo"
            return None
        return None

    def _has_git(self, d):
        hit = self._repo_cache.get(d)
        if hit is None:
            if len(self._repo_cache) > 20000:
                self._repo_cache.clear()
            hit = self._repo_cache[d] = os.path.lexists(os.path.join(d, ".git"))
        return hit

    def forget_repos(self):
        """Repos come and go (a worktree is added or removed): drop the cached lookups."""
        self._repo_cache.clear()

    def skip_writer(self, cmdline):
        return any(fnmatch.fnmatchcase(cmdline, pat) for pat in self.skip_writers)


# --- sessions and processes -------------------------------------------------

def proc_stat(pid):
    """(ppid, start time in clock ticks, state) from /proc/<pid>/stat, or None once the process is reaped."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
    except (FileNotFoundError, ProcessLookupError):
        return None
    return int(fields[1]), fields[19], fields[0]


def proc_environ_sid(pid):
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            env = f.read()
    except (FileNotFoundError, ProcessLookupError, PermissionError):
        return None
    for item in env.split(b"\0"):
        if item.startswith(b"CLAUDE_CODE_SESSION_ID="):
            return item.split(b"=", 1)[1].decode(errors="replace")
    return None


def proc_cmdline(pid):
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            return f.read().replace(b"\0", b" ").decode(errors="replace").strip()
    except (FileNotFoundError, ProcessLookupError):
        return None


class Session:
    __slots__ = ("pid", "sid", "name", "status", "start")

    def __init__(self, pid, sid, name, status, start):
        self.pid, self.sid, self.name, self.status, self.start = pid, sid, name, status, start


class Registry:
    """Claude Code's presence registry ($CLAUDE_CONFIG_DIR/sessions/<pid>.json). A session is
    open while its pid is alive with the recorded start time (a reused pid is not the session)."""

    REFRESH = 2.0

    def __init__(self, directory):
        self.dir = directory
        self._open = {}
        self._mtime = None
        self._at = 0.0

    def open(self, force=False):
        now = time.monotonic()
        try:
            mtime = os.stat(self.dir).st_mtime_ns
        except FileNotFoundError:
            return {}
        if force or mtime != self._mtime or now - self._at > self.REFRESH:
            self._mtime, self._at = mtime, now
            self._open = self._scan()
        return self._open

    def _scan(self):
        found = {}
        for name in os.listdir(self.dir):
            if not name.endswith(".json"):
                continue
            try:
                with open(os.path.join(self.dir, name)) as f:
                    rec = json.load(f)
                pid, sid = int(rec["pid"]), rec["sessionId"]
            except (OSError, ValueError, KeyError, TypeError):
                continue            # a registry file mid-rewrite, or not a session record
            st = proc_stat(pid)
            if st is None or st[1] != str(rec.get("procStart")) or st[2] == "Z":
                continue
            found[pid] = Session(pid, sid, rec.get("name") or sid[:8], rec.get("status") or "?", st[1])
        return found

    def by_sid(self, force=False):
        return {s.sid: s for s in self.open(force).values()}


class Lineage:
    """Fork parents as the proc connector reported them. /proc forgets a process the moment its
    parent reaps it, and a short-lived writer (`sed -i`) is often reaped before its write event is
    read; this remembers who forked it for `grace` seconds after it exits."""

    def __init__(self, grace=30.0):
        self.grace = grace
        self._parent = {}
        self._exited = {}                   # pid → exit time
        self._order = collections.deque()   # (exit time, pid), oldest first: expiry touches only what expires

    def fork(self, parent, child):
        self._parent[child] = parent
        self._exited.pop(child, None)

    def exit(self, pid, now):
        if pid in self._parent:
            self._exited[pid] = now
            self._order.append((now, pid))

    def parent(self, pid):
        return self._parent.get(pid)

    def expire(self, now):
        while self._order and now - self._order[0][0] > self.grace:
            t, pid = self._order.popleft()
            if self._exited.get(pid) == t:          # not forked again under the same pid since
                del self._exited[pid]
                self._parent.pop(pid, None)

    def __len__(self):
        return len(self._parent)


class Attributor:
    """Which open session wrote: the outermost ancestor that is a registered claude process. A
    `claude -p` started from a session's Bash registers as a session of its own, but it is that
    session's helper; the outermost one is the session the user is working with."""

    MAX_DEPTH = 64

    def __init__(self, registry, lineage):
        self.registry, self.lineage = registry, lineage

    def attribute(self, pid):
        """(Session | None, method): method is claude (a session process itself: Edit/Write, which
        went through the hook), tree (a live descendant), lineage (the writer or an ancestor was
        already reaped and was found through recorded forks), environ (a detached process carrying
        the session id), none (not a session's process), gone (reaped before it could be traced)."""
        sessions = self.registry.open()
        p, reaped, found, first = pid, False, None, None
        for depth in range(self.MAX_DEPTH):
            s = sessions.get(p)
            if s is not None:
                found = s
                if first is None:
                    first = depth
            parent = self.lineage.parent(p)
            if parent is None:
                st = proc_stat(p)
                if st is None:
                    if depth == 0:
                        return None, "gone"
                    break
                parent = st[0]
            elif proc_stat(p) is None:
                reaped = True
            if parent <= 1:
                break
            p = parent
        if found is not None:
            return found, "claude" if first == 0 else ("lineage" if reaped else "tree")
        sid = proc_environ_sid(pid)
        if sid:
            s = self.registry.by_sid().get(sid)
            if s is not None:
                return s, "environ"
        return None, "none"


# --- shared state files -------------------------------------------------------
#
# Everything lives in the run directory (/run/conflict-watch, group = the user's, setgid 2770):
#   holds.tsv        the daemon's published holds, read by the hook on every relevant call
#   state.json       the daemon's full state (per-file writes, counters); reloaded on restart
#   inbox/<sid>      notices for a session; the daemon appends, the hook takes the whole file
#   grants/<sid>     units the user let this session into (unit, holder, since|*): `allow`
#   acks/<sid>       holds this session was already warned about (unit, holder, since)
#   requests/        release requests from the CLI

SUBDIRS = ("inbox", "grants", "acks", "requests")


def fmt_age(seconds):
    s = max(0, int(seconds))
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h{s % 3600 // 60:02d}m"
    return f"{s // 86400}d{s % 86400 // 3600:02d}h"


def read_grants(run, sid):
    """{(unit, holder): {since, …}} the user approved for this session; since "*" covers any hold."""
    out = {}
    try:
        with open(os.path.join(run, "grants", sid)) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 3:
                    out.setdefault((parts[0], parts[1]), set()).add(parts[2])
    except FileNotFoundError:
        pass
    return out


def add_grant(run, sid, unit, holders):
    """Let session `sid` into `unit` past each (holder, since) — and each holder past `sid` there:
    the user approved the two working side by side, so neither is warned about the other again."""
    with open(os.path.join(run, "grants", sid), "a") as f:
        for holder, since in holders:
            f.write(f"{unit}\t{holder}\t{since}\n")
    for holder, _ in holders:
        with open(os.path.join(run, "grants", holder), "a") as f:
            f.write(f"{unit}\t{sid}\t*\n")


def read_cleared(run, sid):
    """{(unit, holder): {since, …}} this session was already warned about (acks) or let into by
    the user (grants); since "*" covers any hold."""
    out = read_grants(run, sid)
    try:
        with open(os.path.join(run, "acks", sid)) as f:
            for line in f:
                parts = line.rstrip("\n").split("\t")
                if len(parts) == 3:
                    out.setdefault((parts[0], parts[1]), set()).add(parts[2])
    except FileNotFoundError:
        pass
    return out


def add_acks(run, sid, holds):
    """Record that this session was warned about each (unit, holder, since): the retry passes."""
    with open(os.path.join(run, "acks", sid), "a") as f:
        for unit, holder, since in holds:
            f.write(f"{unit}\t{holder}\t{since}\n")


def cleared_hold(cleared, unit, holder, since):
    return granted(cleared, unit, holder, since)


def granted(grants, unit, holder, since):
    s = grants.get((unit, holder))
    return bool(s) and ("*" in s or str(since) in s)


def request_release(run, sid, units, wait=3.0):
    """Ask the daemon to drop holds: `sid` None = every holder, `units` None = everything `sid`
    holds. Waits up to `wait` seconds for the daemon to apply it; returns whether it did."""
    name = os.path.join(run, "requests", f"{time.time():.6f}-{os.getpid()}")
    with open(name + ".tmp", "w") as f:
        json.dump({"op": "release", "sid": sid, "units": units}, f)
    os.rename(name + ".tmp", name)
    deadline = time.monotonic() + wait
    while os.path.exists(name):
        if time.monotonic() > deadline:
            return False
        time.sleep(0.05)
    return True


def git_ignored(repo, paths, owner=None):
    """The subset of `paths` git ignores in `repo`, asked as the repo owner (never as root: git
    refuses a repo owned by someone else, and a hook or filter in it must not run privileged).
    Unknown (not a repo, git error) = nothing ignored."""
    if not paths:
        return set()
    kw = {}
    if owner is not None and os.geteuid() == 0:
        kw = {"user": owner[0], "group": owner[1], "env": {"HOME": owner[2], "PATH": "/usr/bin:/bin"}}
    try:
        r = subprocess.run(["git", "-C", repo, "check-ignore", "--stdin", "-z"], input="\0".join(paths) + "\0",
                           capture_output=True, text=True, timeout=10, **kw)
    except (OSError, subprocess.TimeoutExpired):
        return set()
    return {p for p in r.stdout.split("\0") if p} if r.returncode in (0, 1) else set()


class Watch:
    """Holds (unit → session → its writes there), the notices they produce, and the files the
    hook and the CLI read. Driven by the daemon; every method is plain state manipulation."""

    MAX_FILES = 500             # per hold: enough to list what a session wrote, bounded for npm-style bursts
    SESSION_FILE_GRACE = 600    # a per-session file of a sid that is not open is removed after this long

    def __init__(self, rules, registry, run_dir, owner=None, now=time.time):
        self.rules, self.registry, self.run, self.owner, self.now = rules, registry, run_dir, owner, now
        self.holds = {}          # unit → sid → {kind, since, last, file, pid, start, name, files: {path: [ts, real]}}
        self.told = set()        # (holder, writer, unit): the holder heard about this writer here
        self.pending = {}        # sid → (inbox inode, keys already in that inbox)
        self.stats = {}
        self.dirty = False
        os.makedirs(run_dir, exist_ok=True)
        for d in SUBDIRS:
            os.makedirs(os.path.join(run_dir, d), exist_ok=True)
        if owner is not None and os.geteuid() == 0:
            for d in (run_dir, *(os.path.join(run_dir, x) for x in SUBDIRS)):
                os.chown(d, 0, owner[1])
                os.chmod(d, 0o2770)

    @classmethod
    def load(cls, rules, registry, run_dir, owner=None, now=time.time):
        w = cls(rules, registry, run_dir, owner, now)
        try:
            with open(os.path.join(run_dir, "state.json")) as f:
                st = json.load(f)
            w.holds, w.stats = st.get("holds", {}), st.get("stats", {})
        except FileNotFoundError:
            pass
        w.prune()
        return w

    def count(self, key, n=1):
        self.stats[key] = self.stats.get(key, 0) + n

    # --- queries -----------------------------------------------------------

    def holders(self, unit):
        return list(self.holds.get(unit, {}))

    def since(self, unit, sid):
        return self.holds[unit][sid]["since"]

    def _real(self, rec):
        """A repo hold counts only through a file git does not ignore (build output, logs and
        caches a test run leaves behind are not work in progress). Unchecked counts as real."""
        return rec["kind"] != "repo" or any(v[1] is not False for v in rec["files"].values())

    # --- the write path ---------------------------------------------------------

    def record(self, session, path, by_claude, comm):
        u = self.rules.unit_of(path)
        if u is None:
            return
        unit, kind = u
        now = self.now()
        h = self.holds.setdefault(unit, {})
        rec = h.get(session.sid)
        if rec is None:
            rec = h[session.sid] = {"kind": kind, "since": round(now, 3), "files": {}}
        rec.update(last=now, file=path, pid=session.pid, start=session.start, name=session.name)
        files = rec["files"]
        files[path] = [now, files.get(path, [0, None])[1]]
        if len(files) > self.MAX_FILES:
            for old in sorted(files, key=lambda p: files[p][0])[: len(files) - self.MAX_FILES]:
                del files[old]
        self.dirty = True
        open_sids = self.registry.by_sid()
        others = [(sid, r) for sid, r in h.items() if sid != session.sid and sid in open_sids]
        if not others:
            return
        if kind == "repo":
            self._check_ignored(unit, [(rec, [path])] + [(r, [p for p, v in r["files"].items() if v[1] is None]) for _, r in others])
            if files[path][1] is False:
                return                        # an ignored file (build output) is nobody's work
            others = [(sid, r) for sid, r in others if self._real(r)]
            if not others:
                return
        self.count("conflict_writes")
        grants = read_grants(self.run, session.sid)
        unapproved = [(sid, r) for sid, r in others if not granted(grants, unit, sid, r["since"])]
        if unapproved and not by_claude:
            # an Edit/Write by the claude process passed the hook's warning already
            self._notify(session.sid, ("stop", unit), self._stop_text(session, path, unit, kind, unapproved, comm, open_sids))
        for sid, r in others:
            if (sid, session.sid, unit) not in self.told:
                self.told.add((sid, session.sid, unit))
                self._notify(sid, ("holder", session.sid, unit),
                             self._holder_text(session, path, unit, r, approved=(sid, r) not in unapproved))

    def _check_ignored(self, unit, batches):
        todo = sorted({p for rec, paths in batches for p in paths if rec["files"].get(p, [0, True])[1] is None})
        if not todo:
            return
        ign = git_ignored(unit, todo, self.owner)
        for rec, paths in batches:
            for p in paths:
                if p in rec["files"] and rec["files"][p][1] is None:
                    rec["files"][p][1] = p not in ign

    # --- notices -------------------------------------------------------------------

    def _describe(self, sid, rec, open_sids, now):
        s = open_sids.get(sid)
        status = s.status if s else "?"
        return f"'{rec['name']}' ({status}, last wrote there {fmt_age(now - rec['last'])} ago: {rec['file']})"

    def _stop_text(self, session, path, unit, kind, others, comm, open_sids):
        now = self.now()
        who = "; ".join(self._describe(sid, r, open_sids, now) for sid, r in others)
        names = " or ".join(f"'{r['name']}'" for _, r in others)
        worktree = (f", or to move this work into a worktree of that repo with `agent-worktree isolate {unit}` "
                    "and continue there" if kind == "repo" else "")
        return (f"Conflict watch: this session just wrote {path} (by {comm}) inside {unit}, which "
                f"another open session holds: {who}. Stop changing anything in {unit} and ask the user before "
                f"you go on there: whether to message {names} (SendMessage) to coordinate{worktree}. This is not "
                "yours to decide, whatever that session's idle time. If the user approves working there anyway, "
                f"run `conflict-watch allow {unit}` so your writes are not flagged again.")

    def _holder_text(self, writer, path, unit, rec, approved):
        what = ("The user approved that session working there." if approved else
                "That session has been told to stop and ask the user.")
        return (f"Conflict watch: session '{writer.name}' wrote {path} inside {unit}, which this session holds "
                f"(you last wrote there {fmt_age(self.now() - rec['last'])} ago). {what} If you are finished in "
                f"{unit}, run `conflict-watch release {unit}` so others can work there; if you are not, consider "
                f"messaging '{writer.name}' (SendMessage) to coordinate.")

    def _notify(self, sid, key, text):
        """Append a notice to the session's inbox, at most once per key until the hook takes the inbox."""
        path = os.path.join(self.run, "inbox", sid)
        try:
            ino = os.stat(path).st_ino
        except FileNotFoundError:
            ino = None
        seen_ino, keys = self.pending.get(sid, (None, set()))
        if ino is None or ino != seen_ino:
            keys = set()
        if key in keys:
            return
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o660)
        try:
            os.write(fd, (text + "\n\n").encode())
            ino = os.fstat(fd).st_ino
        finally:
            os.close(fd)
        self.pending[sid] = (ino, keys | {key})
        self.count("notices")

    # --- lifecycle ---------------------------------------------------------------------

    def release(self, sid, unit):
        units = [unit] if unit is not None else [u for u, h in self.holds.items() if sid in h]
        for u in units:
            h = self.holds.get(u, {})
            targets = list(h) if sid is None else [sid]
            for s in targets:
                if h.pop(s, None) is not None:
                    self.dirty = True
                    self.count("released")
                self.told = {t for t in self.told if not (t[2] == u and s in (t[0], t[1]))}
            if not h:
                self.holds.pop(u, None)

    def process_requests(self):
        d = os.path.join(self.run, "requests")
        for name in sorted(os.listdir(d)):
            if name.endswith(".tmp"):
                continue
            p = os.path.join(d, name)
            try:
                with open(p) as f:
                    req = json.load(f)
                if req.get("op") == "release":
                    units = req.get("units")
                    for u in (units if units else [None]):
                        if req.get("sid") is None and u is not None:
                            self.release(None, u)
                        elif req.get("sid") is not None:
                            self.release(req["sid"], u)
            except (OSError, ValueError) as e:
                log(f"dropped a malformed request {name}: {e}")
            os.unlink(p)

    def prune(self):
        """Holds of sessions that are no longer open go; so do their per-session files."""
        open_sids = self.registry.by_sid(force=True)
        for u in list(self.holds):
            for sid in [s for s in self.holds[u] if s not in open_sids]:
                self.release(sid, u)
        now = time.time()
        for d in ("inbox", "grants", "acks"):
            for name in os.listdir(os.path.join(self.run, d)):
                sid = name.lstrip(".").split(".")[0]
                p = os.path.join(self.run, d, name)
                if sid not in open_sids:
                    try:
                        if now - os.lstat(p).st_mtime > self.SESSION_FILE_GRACE:
                            os.unlink(p)
                    except FileNotFoundError:
                        pass

    def flush(self):
        """Publish holds.tsv (what the hook reads) and state.json (what a restart reloads)."""
        for unit, h in self.holds.items():
            for rec in h.values():
                if rec["kind"] == "repo":
                    self._check_ignored(unit, [(rec, list(rec["files"]))])
        open_sids = self.registry.by_sid()
        lines = [f"#daemon\t{os.getpid()}"]
        for unit, h in sorted(self.holds.items()):
            for sid, r in h.items():
                if sid in open_sids and self._real(r):
                    lines.append("\t".join(map(str, (unit, r["kind"], sid, r["pid"], r["start"], r["since"],
                                                     r["name"].replace("\t", " "), int(r["last"]), r["file"]))))
        self._atomic("holds.tsv", "\n".join(lines) + "\n")
        self._atomic("state.json", json.dumps({"daemon": os.getpid(), "holds": self.holds, "stats": self.stats}))
        self.dirty = False

    def _atomic(self, name, text):
        tmp = os.path.join(self.run, f".{name}.tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o640)
        try:
            os.write(fd, text.encode())
        finally:
            os.close(fd)
        os.rename(tmp, os.path.join(self.run, name))


def log(msg):
    print(msg, file=sys.stderr, flush=True)


# --- the daemon ---------------------------------------------------------------------

FAN_CLASS_NOTIF, FAN_CLOEXEC, FAN_NONBLOCK, FAN_UNLIMITED_QUEUE = 0x0, 0x1, 0x2, 0x10
FAN_MARK_ADD, FAN_MARK_MOUNT = 0x1, 0x10
FAN_CLOSE_WRITE, FAN_Q_OVERFLOW = 0x8, 0x4000
EVENT = "=IBBHQii"                        # fanotify_event_metadata: len, vers, reserved, metadata_len, mask, fd, pid
NETLINK_CONNECTOR, CN_IDX_PROC, PROC_CN_MCAST_LISTEN = 11, 1, 1
PROC_EVENT_FORK, PROC_EVENT_EXIT = 0x1, 0x80000000


def fanotify_open(mount_path):
    """A notification-only group (never a permission group: a dead or slow daemon must not be
    able to block a write) with a close-after-write mark on the mount holding `mount_path`."""
    import ctypes
    libc = ctypes.CDLL("libc.so.6", use_errno=True)
    libc.fanotify_mark.argtypes = [ctypes.c_int, ctypes.c_uint, ctypes.c_uint64, ctypes.c_int, ctypes.c_char_p]
    fd = libc.fanotify_init(FAN_CLASS_NOTIF | FAN_CLOEXEC | FAN_NONBLOCK | FAN_UNLIMITED_QUEUE,
                            os.O_RDONLY | os.O_LARGEFILE | os.O_CLOEXEC)
    if fd < 0:
        e = ctypes.get_errno()
        raise OSError(e, f"fanotify_init: {os.strerror(e)}")
    if libc.fanotify_mark(fd, FAN_MARK_ADD | FAN_MARK_MOUNT, FAN_CLOSE_WRITE, -100, mount_path.encode()) < 0:
        e = ctypes.get_errno()
        raise OSError(e, f"fanotify_mark {mount_path}: {os.strerror(e)}")
    return fd


def proc_connector_open():
    import socket
    import struct
    s = socket.socket(socket.AF_NETLINK, socket.SOCK_DGRAM, NETLINK_CONNECTOR)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    s.bind((os.getpid(), CN_IDX_PROC))
    op = struct.pack("=I", PROC_CN_MCAST_LISTEN)
    cn = struct.pack("=IIIIHH", CN_IDX_PROC, 1, 0, 0, len(op), 0) + op
    s.send(struct.pack("=IHHII", 16 + len(cn), 3, 0, 0, os.getpid()) + cn)     # NLMSG_DONE
    s.setblocking(False)
    return s


class Daemon:
    def __init__(self, rules, registry, run_dir, owner):
        self.rules, self.registry = rules, registry
        self.watch = Watch.load(rules, registry, run_dir, owner)
        self.lineage = Lineage()
        self.attributor = Attributor(registry, self.lineage)
        self.me = os.getpid()
        self.prefix = rules.root + "/"
        self.settling = []      # (time, event fd, session, by claude, writer) awaiting settle()

    def drain_lineage(self, sock):
        import errno
        import struct
        now = time.time()
        while True:
            try:
                buf = sock.recv(65536)
            except BlockingIOError:
                return
            except OSError as e:
                if e.errno == errno.ENOBUFS:       # a fork storm outran us: some short-lived writers go unattributed
                    self.watch.count("lineage_overflow")
                    continue
                raise
            off = 0
            while off + 52 <= len(buf):
                nl_len = struct.unpack_from("=I", buf, off)[0]
                what = struct.unpack_from("=I", buf, off + 36)[0]
                if what == PROC_EVENT_FORK:
                    _, ptgid, cpid, ctgid = struct.unpack_from("=IIII", buf, off + 52)
                    if cpid == ctgid:
                        self.lineage.fork(ptgid, ctgid)
                elif what == PROC_EVENT_EXIT:
                    pid, tgid = struct.unpack_from("=II", buf, off + 52)
                    if pid == tgid:
                        self.lineage.exit(tgid, now)
                if nl_len <= 0:
                    break
                off += (nl_len + 3) & ~3

    def drain_writes(self, fan, nl):
        import struct
        event = struct.Struct(EVENT)
        while True:
            self.drain_lineage(nl)      # a writer's fork is queued before its write: read forks first, every batch
            try:
                buf = os.read(fan, 65536)
            except BlockingIOError:
                return
            off = 0
            while off + event.size <= len(buf):
                ev_len, _, _, _, mask, efd, pid = event.unpack_from(buf, off)
                off += ev_len
                if mask & FAN_Q_OVERFLOW:
                    self.watch.count("fanotify_overflow")
                    log("fanotify queue overflow: some writes were not seen")
                    continue
                if efd < 0:                     # the kernel could not open the file for us (fd limit)
                    self.watch.count("no_fd")
                    continue
                try:
                    path = os.readlink(f"/proc/self/fd/{efd}")
                except OSError:
                    os.close(efd)
                    continue
                if pid == self.me or not path.startswith(self.prefix) or not self.on_write(path, pid, efd):
                    os.close(efd)

    def on_write(self, path, pid, efd):
        """Credit the write now, while its writer is most likely still there to be traced; keep the
        event's fd to name the file once it has settled. True when the fd was kept."""
        if self.rules.unit_of(path) is None:
            return False
        self.watch.count("watched_writes")
        session, how = self.attributor.attribute(pid)
        self.watch.count("by_" + how)
        if session is None:
            return False
        cmd = proc_cmdline(pid)
        if cmd and self.rules.skip_writer(cmd):
            self.watch.count("skip_writer")
            return False
        try:
            with open(f"/proc/{pid}/comm") as f:
                comm = f"a `{f.read().strip()}` process"
        except OSError:
            comm = "a process that has since exited"
        self.settling.append((time.monotonic(), path, efd, session, how == "claude", comm))
        return True

    SETTLE = 0.2
    MAX_SETTLING = 4096         # a burst beyond this is named early rather than hold more fds

    def settle(self, everything=False):
        """Name the files written SETTLE seconds ago. Editors, Claude Code's Edit/Write and `sed -i`
        write a temp file and rename it over the target right after closing it; the event's fd
        follows the rename, so reading its path a moment later gives the file that was changed.
        When the file is gone by then (replaced by a later rename, or a temp file removed), the
        name it was written under is the best there is."""
        now = time.monotonic()
        while self.settling and (everything or len(self.settling) > self.MAX_SETTLING
                                 or now - self.settling[0][0] >= self.SETTLE):
            _, first, efd, session, by_claude, comm = self.settling.pop(0)
            try:
                path = os.readlink(f"/proc/self/fd/{efd}")
            except OSError:
                path = first
            finally:
                os.close(efd)
            if path.endswith(" (deleted)"):
                path = first[:-10] if first.endswith(" (deleted)") else first
            self.watch.record(session, path, by_claude=by_claude, comm=comm)

    def run(self):
        import resource
        import select
        import signal
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))      # settling writes hold their fds
        fan = fanotify_open(self.rules.root)
        nl = proc_connector_open()
        stop = []
        signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
        signal.signal(signal.SIGINT, lambda *_: stop.append(1))
        self.watch.flush()
        log(f"watching {self.rules.root} (pid {self.me})")
        last_prune = last_flush = last_chores = time.monotonic()
        while not stop:
            # Woken by writes only: the box forks ~100 times a second, and the connector's 8 MB
            # buffer holds minutes of that, so forks are drained on each wake (before the writes,
            # whose forks they are) and on a 0.25 s clock.
            try:
                select.select([fan], [], [], self.SETTLE / 2 if self.settling else 0.25)
            except InterruptedError:
                continue
            self.drain_writes(fan, nl)
            self.settle()
            now = time.monotonic()
            if now - last_chores < 0.25:
                continue
            last_chores = now
            self.watch.process_requests()
            self.lineage.expire(time.time())
            if now - last_prune > 5:
                self.watch.prune()
                self.rules.forget_repos()
                last_prune = now
            if self.watch.dirty and now - last_flush > 0.5:
                self.watch.flush()
                last_flush = now
        self.settle(everything=True)
        self.watch.flush()
        log("stopped")


# --- the CLI ------------------------------------------------------------------------

def defaults():
    """Locations, from where this script is deployed (~/roost/claude/scripts/conflict-watch.py):
    the root is ~/roost, the rules file ~/roost/claude/conflict-watch.conf. Environment overrides
    exist for tests."""
    here = os.path.dirname(os.path.realpath(__file__))
    root = os.environ.get("CONFLICT_WATCH_ROOT") or os.path.dirname(os.path.dirname(here))
    return {
        "root": root,
        "conf": os.environ.get("CONFLICT_WATCH_CONF") or os.path.join(os.path.dirname(here), "conflict-watch.conf"),
        "registry": os.environ.get("CONFLICT_WATCH_REGISTRY")
                    or os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(root, "claude"), "sessions"),
        "run": os.environ.get("CONFLICT_WATCH_RUN") or "/run/conflict-watch",
    }


def read_state(run):
    try:
        with open(os.path.join(run, "state.json")) as f:
            st = json.load(f)
    except FileNotFoundError:
        return None
    return st if proc_stat(st.get("daemon", 0)) else None


def my_sid():
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or None


def resolve_session(registry, ref):
    """A session by id, id prefix or name (as ListAgents shows it)."""
    sessions = registry.by_sid(force=True)
    hits = [s for s in sessions.values() if s.sid == ref or s.name == ref] or \
           [s for s in sessions.values() if s.sid.startswith(ref)]
    if len(hits) != 1:
        raise SystemExit(f"conflict-watch: no single open session matches {ref!r}")
    return hits[0].sid


def unit_arg(rules, arg):
    path = os.path.abspath(os.path.expanduser(arg))
    u = rules.unit_of(path) or rules.unit_of(os.path.join(path, ".probe"))
    if u is None:
        raise SystemExit(f"conflict-watch: {path} is in no unit")
    return u[0]


def cmd_status(cfg, rules, registry, args):
    st = read_state(cfg["run"])
    if st is None:
        print("conflict-watch: the daemon is not running; nothing is watched")
        return 1
    sessions = registry.by_sid(force=True)
    now = time.time()
    print(f"{'UNIT':<60} {'SESSION':<34} {'STATE':<6} {'LAST WRITE':>10}  FILES")
    for unit, h in sorted(st["holds"].items()):
        for sid, r in h.items():
            s = sessions.get(sid)
            if s is None:
                continue
            print(f"{os.path.relpath(unit, rules.root):<60} {s.name[:34]:<34} {s.status:<6} "
                  f"{fmt_age(now - r['last']) + ' ago':>10}  {len(r['files'])}")
    stats = st.get("stats", {})
    print("counters: " + ", ".join(f"{k}={v}" for k, v in sorted(stats.items())))
    return 0


def cmd_release(cfg, rules, registry, args):
    sid = resolve_session(registry, args.session) if args.session else my_sid()
    units = [unit_arg(rules, a) for a in args.units] or None
    if sid is None and units is None:
        raise SystemExit("conflict-watch: outside a session, name the units or --session")
    if read_state(cfg["run"]) is None:
        print("conflict-watch: the daemon is not running; there are no holds to release")
        return 0
    ok = request_release(cfg["run"], sid, units)
    what = ", ".join(os.path.relpath(u, rules.root) for u in units) if units else "every unit"
    who = f"session {sid}" if sid else "every session"
    print(f"released {what} for {who}" if ok else "conflict-watch: the daemon did not pick up the request within 3s")
    return 0 if ok else 1


def cmd_allow(cfg, rules, registry, args):
    sid = my_sid()
    if sid is None:
        raise SystemExit("conflict-watch: allow is run by the session the user let in (no CLAUDE_CODE_SESSION_ID here)")
    unit = unit_arg(rules, args.unit)
    st = read_state(cfg["run"]) or {"holds": {}}
    sessions = registry.by_sid(force=True)
    holders = [(h, r["since"]) for h, r in st["holds"].get(unit, {}).items() if h != sid and h in sessions]
    if not holders:
        print(f"no other open session holds {unit}")
        return 0
    add_grant(cfg["run"], sid, unit, holders)
    print(f"allowed: this session and {', '.join(sessions[h].name for h, _ in holders)} both work in {unit}")
    return 0


def cmd_unit(cfg, rules, registry, args):
    u = rules.unit_of(os.path.abspath(args.path))
    print(f"{u[0]}\t{u[1]}" if u else "none")
    return 0


# Repo-wide git commands, by what they can change: `sweep` ones act on every uncommitted file in
# the tree (they stage, stash or discard other people's work), `paths` ones discard the changes to
# the paths they name, `move` ones rewrite the checkout to another commit.
VALUE_OPTS = {
    "merge": {"-m", "-F", "-s", "-X", "--message", "--file", "--strategy", "--strategy-option", "--into-name"},
    "rebase": {"-s", "-X", "-x", "--strategy", "--strategy-option", "--exec"},
    "pull": {"-s", "-X", "--strategy", "--strategy-option", "--depth"},
    "checkout": {"-b", "-B", "--orphan", "--conflict"},
    "switch": {"-c", "-C", "--create", "--force-create", "--orphan", "--conflict"},
    "restore": {"-s", "--source"},
}


def positionals(sub, args):
    """The non-option arguments, skipping the values of options that take one."""
    out, skip = [], False
    takes = VALUE_OPTS.get(sub, set())
    for a in args:
        if skip:
            skip = False
        elif a == "--":
            continue
        elif a.startswith("-"):
            skip = a in takes
        else:
            out.append(a)
    return out


def classify_git(tokens):
    """(kind, repo dir option list, subcommand, its arguments) for a tokenized command that runs a
    repo-wide git command, else None."""
    i = 0
    while i < len(tokens) and "=" in tokens[i] and not tokens[i].startswith("-"):
        i += 1                                  # VAR=value prefixes
    if i >= len(tokens) or os.path.basename(tokens[i]) != "git":
        return None
    i += 1
    dirs = []
    while i < len(tokens) and tokens[i].startswith("-"):
        if tokens[i] == "-C" and i + 1 < len(tokens):
            dirs.append(tokens[i + 1])
            i += 2
        elif tokens[i] in ("-c", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(tokens):
            i += 2
        else:
            i += 1
    if i >= len(tokens):
        return None
    sub, args = tokens[i], tokens[i + 1:]
    opts = set(a for a in args if a.startswith("-"))
    everything = {".", ":/", ":/*", "*"}
    kind = None
    if sub == "add" and ({"-A", "--all", "-u", "--update"} & opts or everything & set(args)):
        kind = "sweep"
    elif sub == "commit" and any(o in ("-a", "--all") or (not o.startswith("--") and "a" in o[1:] and o[1:].isalpha()) for o in opts):
        kind = "sweep"
    elif sub == "stash" and not (args and args[0] in ("list", "show")):
        kind = "sweep"
    elif sub == "checkout":
        if "--" in args:
            paths = args[args.index("--") + 1:]
            kind = "sweep" if everything & set(paths) else ("paths" if paths else None)
        elif everything & set(args) or {"-f", "--force"} & opts:
            kind = "sweep"
        elif {"-b", "-B", "--orphan"} & opts:
            kind = "move" if positionals(sub, args) else None     # a start point moves the checkout
        elif positionals(sub, args):
            kind = "move"
    elif sub == "switch":
        pos = positionals(sub, args)
        if {"-c", "-C", "--create", "--force-create", "--orphan"} & opts:
            kind = "move" if pos else None
        elif pos:
            kind = "move"
    elif sub == "restore" and not ("--staged" in opts and not {"-W", "--worktree"} & opts):
        pos = positionals(sub, args)
        kind = "sweep" if everything & set(pos) else ("paths" if pos else None)
    elif sub == "reset" and "--hard" in opts:
        kind = "sweep"
    elif sub == "clean" and any(o.startswith("-") and not o.startswith("--") and "f" in o or o == "--force" for o in opts):
        kind = "sweep"
    elif sub in ("pull", "merge", "rebase") and not {"--abort", "--continue", "--quit", "--skip"} & opts:
        kind = "move"
    return (kind, dirs, sub, args) if kind else None


def split_segments(command):
    """Shell command → list of token lists, one per simple command (split on ; & | && || and newlines)."""
    lex = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    lex.whitespace = " \t\r"
    lex.whitespace_split = True
    segs, cur = [], []
    try:
        for tok in lex:
            if tok and set(tok) <= set(";&|()\n"):
                if cur:
                    segs.append(cur)
                cur = []
            else:
                cur.append(tok)
    except ValueError:                          # unbalanced quotes: nothing reliable to parse
        return segs
    if cur:
        segs.append(cur)
    return segs


def git_lines(repo, *args):
    """Output lines of a git command in `repo`, or None when it fails."""
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=20)
    return [l for l in r.stdout.split("\0" if "-z" in args else "\n") if l] if r.returncode == 0 else None


def dirty_files(top):
    entries = git_lines(top, "status", "--porcelain", "-z", "--untracked-files=all") or []
    out, i = set(), 0
    while i < len(entries):
        e = entries[i]
        if len(e) > 3:
            out.add(os.path.join(top, e[3:]))
            if e[0] in "RC":                    # a rename carries its source as the next entry
                i += 1
        i += 1
    return out


def move_targets(sub, args):
    """(refs, diff form) a move command takes the checkout to, or None when that cannot be told
    from the command alone. merge/rebase/pull bring in what changed on the incoming side since the
    merge base (HEAD...ref); checkout/switch replace HEAD's tree with the target's (HEAD ref)."""
    pos = positionals(sub, args)
    if sub in ("checkout", "switch"):
        if len(pos) != 1 and not ({"-b", "-B", "--orphan", "-c", "-C", "--create", "--force-create"} & set(args) and pos):
            return None
        return ["@{-1}" if pos[-1] == "-" else pos[-1]], "direct"
    if sub == "merge":
        return (pos or ["@{u}"]), "incoming"
    if sub == "rebase":
        if {"--onto", "--root", "-i", "--interactive"} & set(args) or len(pos) > 1:
            return None
        return (pos or ["@{u}"]), "incoming"
    if sub == "pull":                           # compared with what is fetched already
        if not pos:
            return ["@{u}"], "incoming"
        return ([f"{pos[0]}/{pos[1]}"], "incoming") if len(pos) == 2 else None
    return None


def affected_files(top, d, kind, sub, args):
    """The files under `top` the command would change, or None when that cannot be computed
    cheaply (then every file another session wrote there counts)."""
    if kind == "sweep":
        return dirty_files(top)
    if kind == "paths":
        specs = [os.path.normpath(os.path.join(d, p)) for p in positionals(sub, args[args.index("--") + 1:] if "--" in args else args)]
        return {f for f in dirty_files(top)
                if any(f == sp or f.startswith(sp + "/") or fnmatch.fnmatchcase(f, sp) for sp in specs)}
    t = move_targets(sub, args)
    if t is None:
        return None
    refs, form = t
    out = set()
    for ref in refs:
        if git_lines(top, "rev-parse", "--verify", "--quiet", ref + "^{commit}") is None:
            if sub == "checkout" and len(refs) == 1 and os.path.exists(os.path.join(d, ref)):
                return {f for f in dirty_files(top) if f == os.path.normpath(os.path.join(d, ref))}  # checkout <path>
            return None
        names = git_lines(top, "diff", "--name-only", "-z", f"HEAD...{ref}" if form == "incoming" else "HEAD", *([ref] if form == "direct" else []))
        if names is None:
            return None
        out |= {os.path.join(top, n) for n in names}
    return out


def owned_by(path, top):
    """True when `top` is the repo holding `path`: no directory between them has its own .git."""
    if not path.startswith(top + "/"):
        return False
    d = os.path.dirname(path)
    while len(d) > len(top):
        if os.path.lexists(os.path.join(d, ".git")):
            return False
        d = os.path.dirname(d)
    return True


def hook_git(cfg, rules, registry, payload, self_sids):
    """PreToolUse(Bash): stop, once, a repo-wide git command that would change files another open
    session wrote. Returns the hook's decision fields, or None to let it run."""
    st = read_state(cfg["run"])
    if st is None:
        return None
    command = (payload.get("tool_input") or {}).get("command") or ""
    base = payload.get("cwd") or os.getcwd()
    sid = payload.get("session_id") or ""
    sessions = registry.by_sid(force=True)
    cleared = read_cleared(cfg["run"], sid)
    now = time.time()
    for toks in split_segments(command):
        if toks and toks[0] == "cd" and len(toks) > 1:
            base = os.path.normpath(os.path.join(base, os.path.expanduser(toks[1])))
            continue
        c = classify_git(toks)
        if c is None:
            continue
        kind, dirs, sub, args = c
        d = base
        for x in dirs:
            d = os.path.normpath(os.path.join(d, os.path.expanduser(x)))
        top = git_lines(d, "rev-parse", "--show-toplevel")
        if not top:
            continue
        top = top[0]
        candidates = []                         # (session, unit, hold, its files in this repo), not yet warned about
        for unit, h in st["holds"].items():
            if not (unit == top or unit.startswith(top + "/") or top.startswith(unit + "/")):
                continue
            for hsid, rec in h.items():
                if hsid in self_sids or hsid not in sessions or cleared_hold(cleared, unit, hsid, rec["since"]):
                    continue
                files = [p for p in rec["files"] if owned_by(p, top)]
                if files:
                    candidates.append((sessions[hsid], unit, rec, files))
        if not candidates:
            continue
        affected = affected_files(top, d, kind, sub, args)
        found = [(s, u, rec, sorted(f for f in files if affected is None or f in affected))
                 for s, u, rec, files in candidates]
        found = [x for x in found if x[3]]
        if not found:
            continue
        add_acks(cfg["run"], sid, [(u, s.sid, rec["since"]) for s, u, rec, _ in found])
        who = "; ".join(f"'{s.name}' ({s.status}, last wrote there {fmt_age(now - rec['last'])} ago) wrote "
                        + ", ".join(os.path.relpath(p, top) for p in files[:15]) + (" …" if len(files) > 15 else "")
                        for s, _, rec, files in found)
        names = " or ".join(f"'{s.name}'" for s, _, _, _ in found)
        repo_unit = any(u == top for _, u, _, _ in found)
        worktree = (f", or to move your work into a worktree of this repo (`agent-worktree isolate {top}`) and "
                    "continue there" if repo_unit else "")
        reason = (f"Conflict watch: `{' '.join(toks)}` would change files in {top} that another open session "
                  f"wrote: {who}. Stopped once, as a warning. Do not decide this yourself, whatever that "
                  f"session's idle time: ask the user whether to message {names} (SendMessage) to "
                  f"coordinate{worktree}. Committing, staging or restoring only your own files by path is "
                  "always fine. If the user says to go ahead, re-run the command: it passes now.")
        return {"permissionDecision": "deny", "permissionDecisionReason": reason}
    return None


def own_sessions(registry, sid):
    """This session and the sessions above this process: a `claude -p` run from a session's Bash
    registers as a session of its own, and its parent's work is its own."""
    mine = {sid} if sid else set()
    sessions = registry.open(force=True)
    p = os.getppid()
    for _ in range(64):
        if p <= 1:
            break
        if p in sessions:
            mine.add(sessions[p].sid)
        st = proc_stat(p)
        if st is None:
            break
        p = st[0]
    return mine


def cmd_hook_git(cfg, rules, registry, args):
    payload = json.load(sys.stdin)
    self_sids = own_sessions(registry, payload.get("session_id"))
    out = hook_git(cfg, rules, registry, payload, self_sids)
    extra = os.environ.get("CW_CONTEXT") or ""
    if out is None and not extra:
        return 0
    out = out or {}
    if extra and out.get("permissionDecision") == "deny":
        out["permissionDecisionReason"] += "\n\n" + extra      # a deny drops additionalContext
    elif extra:
        out["additionalContext"] = extra
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", **out}}))
    return 0


def cmd_run(cfg, rules, registry, args):
    st = os.stat(cfg["registry"])
    import pwd
    owner = (st.st_uid, st.st_gid, pwd.getpwuid(st.st_uid).pw_dir)
    os.umask(0o007)
    Daemon(rules, registry, cfg["run"], owner).run()
    return 0


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(prog="conflict-watch", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("run", help="the daemon (root, under systemd)")
    sub.add_parser("status", help="which session holds which unit")
    p = sub.add_parser("release", help="drop holds: this session's (default) or --session's; no units = all of them")
    p.add_argument("units", nargs="*", metavar="UNIT_OR_PATH")
    p.add_argument("--session", help="a session id, id prefix or name (ListAgents)")
    p = sub.add_parser("allow", help="once the user said go ahead: work in a unit another session holds, "
                                     "without its warnings or notices (both ways)")
    p.add_argument("unit", metavar="UNIT_OR_PATH")
    p = sub.add_parser("unit", help="the unit a path belongs to")
    p.add_argument("path")
    sub.add_parser("hook-git", help="(for the hook) PreToolUse payload on stdin")
    args = ap.parse_args(argv)
    cfg = defaults()
    rules = Rules.load(cfg["conf"], cfg["root"])
    registry = Registry(cfg["registry"])
    fn = {"run": cmd_run, "status": cmd_status, "release": cmd_release, "allow": cmd_allow,
          "unit": cmd_unit, "hook-git": cmd_hook_git}[args.cmd]
    return fn(cfg, rules, registry, args)


if __name__ == "__main__":
    sys.exit(main())
