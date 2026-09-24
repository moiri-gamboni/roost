#!/usr/bin/env python3
"""Tests for files/scripts/conflict-watch.py that need no root: unit mapping,
attribution through the registry and the process tree, the hold/release
lifecycle and the notices it produces, and the edit/git checks the hook calls.

    python3 tests/conflict-watch.py            # from the repo root

The daemon's fanotify + proc-connector loop needs root and is exercised by
tests/conflict-watch-daemon.sh."""
import importlib.util
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "files", "scripts", "conflict-watch.py")
CONF = os.path.join(HERE, "..", "files", "conflict-watch.conf")
sys.dont_write_bytecode = True        # importing the script must not leave a __pycache__ in the repo
spec = importlib.util.spec_from_file_location("cw", SRC)
cw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cw)

GIT_ENV = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, env=GIT_ENV, check=True, capture_output=True, text=True).stdout


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


class Fixture(unittest.TestCase):
    """A fake ~/roost with the real rules file: an apart-research workspace (a meta
    repo holding task folders, plans, notes, data, mirrors and nested repos), a
    code/ repo with a nested repo, and a worktree."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="cw-test.")
        self.root = os.path.join(self.tmp, "roost")
        r = self.root
        for d in ["apart-research", "apart-research/tasksync", "code/server", "code/server/files/private",
                  "code/notrepo", "worktrees/server/tree1"]:
            os.makedirs(os.path.join(r, d), exist_ok=True)
        git("init", "-q", cwd=f"{r}/apart-research")
        git("init", "-q", cwd=f"{r}/apart-research/tasksync")
        git("init", "-q", cwd=f"{r}/code/server")
        git("init", "-q", cwd=f"{r}/code/server/files/private")
        write(f"{r}/worktrees/server/tree1/.git", "gitdir: /nowhere\n")  # a linked worktree's .git file
        self.rules = cw.Rules.load(CONF, r)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def unit(self, rel):
        u = self.rules.unit_of(os.path.join(self.root, rel))
        return None if u is None else (os.path.relpath(u[0], self.root), u[1])


class UnitMapping(Fixture):
    def test_each_task_folder_is_its_own_unit(self):
        self.assertEqual(self.unit("apart-research/tasks/2026-09-01-foo/task.md"), ("apart-research/tasks/2026-09-01-foo", "folder"))
        self.assertEqual(self.unit("apart-research/tasks/2026-09-01-foo/sub/deep.md"), ("apart-research/tasks/2026-09-01-foo", "folder"))
        self.assertEqual(self.unit("apart-research/tasks/2026-09-02-bar/task.md"), ("apart-research/tasks/2026-09-02-bar", "folder"))

    def test_tasksync_state_is_not_a_unit(self):
        self.assertIsNone(self.unit("apart-research/tasks/.sync/base.json"))

    def test_plans_notes_data_first_level_entries_file_or_folder(self):
        self.assertEqual(self.unit("apart-research/plans/x.md"), ("apart-research/plans/x.md", "folder"))
        self.assertEqual(self.unit("apart-research/plans/big/y.md"), ("apart-research/plans/big", "folder"))
        self.assertEqual(self.unit("apart-research/notes/n.md"), ("apart-research/notes/n.md", "folder"))
        self.assertEqual(self.unit("apart-research/data/evals/r.json"), ("apart-research/data/evals", "folder"))

    def test_mirrors_and_granola_are_not_watched(self):
        self.assertIsNone(self.unit("apart-research/mirrors/notion/page.md"))
        self.assertIsNone(self.unit("apart-research/meetings/granola/2026/m.md"))

    def test_nested_repos_in_the_workspace_are_whole_units(self):
        self.assertEqual(self.unit("apart-research/tasksync/tasksync/cli.py"), ("apart-research/tasksync", "repo"))

    def test_the_workspace_meta_repo_itself_is_not_a_unit(self):
        self.assertIsNone(self.unit("apart-research/CLAUDE.md"))
        self.assertIsNone(self.unit("apart-research/scratchpad/s.md"))

    def test_code_repos_and_the_innermost_nested_repo(self):
        self.assertEqual(self.unit("code/server/files/hooks/h.sh"), ("code/server", "repo"))
        self.assertEqual(self.unit("code/server/files/private/g.md"), ("code/server/files/private", "repo"))
        self.assertIsNone(self.unit("code/notrepo/f.txt"))

    def test_worktrees_found_by_their_git_file(self):
        self.assertEqual(self.unit("worktrees/server/tree1/files/x"), ("worktrees/server/tree1", "repo"))

    def test_writes_inside_git_dirs_and_caches_never_count(self):
        self.assertIsNone(self.unit("code/server/.git/index"))
        self.assertIsNone(self.unit("code/server/pkg/__pycache__/m.cpython-312.pyc"))
        self.assertIsNone(self.unit("code/server/node_modules/x/index.js"))
        self.assertIsNone(self.unit("apart-research/tasks/t/.roughdraft-history/v1/a.md"))

    def test_outside_the_rules_is_not_watched(self):
        self.assertIsNone(self.unit("drop/f"))
        self.assertIsNone(self.rules.unit_of("/etc/passwd"))

    def test_skip_writer_matches_tasks_pull(self):
        self.assertTrue(self.rules.skip_writer("/usr/bin/python3 /home/moiri/roost/apart-research/tasksync/tasks pull --stage 1 --quiet"))
        self.assertFalse(self.rules.skip_writer("/usr/bin/python3 /home/moiri/roost/apart-research/tasksync/tasks log t 'x'"))


def proc_start(pid):
    with open(f"/proc/{pid}/stat") as f:
        return f.read().rsplit(")", 1)[1].split()[19]


class Procs:
    """Real processes standing in for sessions and their writers."""

    def __init__(self):
        self.procs = []

    def spawn(self, cmd, **kw):
        kw.setdefault("start_new_session", True)     # its own process group, so cleanup takes the children too
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True, **kw)
        self.procs.append(p)
        return p

    def kill_all(self):
        for p in self.procs:
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            p.wait()
            if p.stdout:
                p.stdout.close()


class RegistryFixture(Fixture):
    def setUp(self):
        super().setUp()
        self.reg = os.path.join(self.tmp, "sessions")
        os.makedirs(self.reg)
        self.procs = Procs()
        self.addCleanup(self.procs.kill_all)

    def register(self, pid, sid, name=None, status="busy", start=None):
        with open(os.path.join(self.reg, f"{pid}.json"), "w") as f:
            json.dump({"pid": pid, "sessionId": sid, "name": name or f"name-{sid}", "status": status,
                       "procStart": start or proc_start(pid), "cwd": self.root}, f)

    def session_proc(self, sid, **kw):
        """A shell standing in for a claude process, which starts one child and prints the child's pid."""
        p = self.procs.spawn(["bash", "-c", "sleep 60 & echo $!; wait"], **kw)
        child = int(p.stdout.readline())
        self.register(p.pid, sid)
        return p.pid, child


class Attribution(RegistryFixture):
    def attributor(self, lineage=None):
        return cw.Attributor(cw.Registry(self.reg), lineage or cw.Lineage())

    def test_a_registered_live_session_is_open(self):
        pid, _ = self.session_proc("A")
        self.assertEqual(cw.Registry(self.reg).open()[pid].sid, "A")

    def test_a_stale_registry_entry_is_not_open(self):
        pid, _ = self.session_proc("A")
        self.register(pid, "A", start="1")          # pid reused by another process
        dead = self.procs.spawn(["true"]); dead.wait()
        self.register(dead.pid, "B", start="123")
        self.assertEqual(cw.Registry(self.reg).open(), {})

    def test_the_claude_process_itself(self):
        pid, _ = self.session_proc("A")
        s, how = self.attributor().attribute(pid)
        self.assertEqual((s.sid, how), ("A", "claude"))

    def test_a_live_descendant(self):
        _, child = self.session_proc("A")
        s, how = self.attributor().attribute(child)
        self.assertEqual((s.sid, how), ("A", "tree"))

    def test_an_exited_writer_found_through_its_recorded_fork_parent(self):
        pid, _ = self.session_proc("A")
        gone = self.procs.spawn(["true"]); gone.wait()
        lin = cw.Lineage()
        lin.fork(pid, gone.pid)
        s, how = self.attributor(lin).attribute(gone.pid)
        self.assertEqual((s.sid, how), ("A", "lineage"))

    def test_an_exited_writer_with_no_lineage_is_unknown(self):
        self.session_proc("A")
        gone = self.procs.spawn(["true"]); gone.wait()
        self.assertEqual(self.attributor().attribute(gone.pid), (None, "gone"))

    def test_a_detached_process_through_its_environment(self):
        self.session_proc("A")
        p = self.procs.spawn(["sleep", "60"], env=dict(os.environ, CLAUDE_CODE_SESSION_ID="A"), start_new_session=True)
        s, how = self.attributor().attribute(p.pid)
        self.assertEqual((s.sid, how), ("A", "environ"))

    def test_a_process_of_no_session(self):
        self.session_proc("A")
        p = self.procs.spawn(["sleep", "60"], env={k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"})
        self.assertEqual(self.attributor().attribute(p.pid), (None, "none"))

    def test_a_session_started_inside_another_works_for_the_outer_one(self):
        # a `claude -p` run from a session's Bash registers as a session of its own, but its
        # writes are the outer session's work: never a conflict between a session and its helper
        outer = self.procs.spawn(["bash", "-c", "bash -c 'sleep 60 & echo $!; wait' & echo $!; wait"])
        inner = int(outer.stdout.readline())
        writer = int(outer.stdout.readline())
        self.register(outer.pid, "OUTER")
        self.register(inner, "INNER")
        a = self.attributor()
        s, how = a.attribute(writer)
        self.assertEqual((s.sid, how), ("OUTER", "tree"))
        s, how = a.attribute(inner)
        self.assertEqual((s.sid, how), ("OUTER", "claude"))

    def test_lineage_forgets_exited_processes_after_the_grace_period(self):
        lin = cw.Lineage(grace=10)
        lin.fork(1, 99999999)
        lin.exit(99999999, now=100)
        lin.expire(now=105)
        self.assertEqual(lin.parent(99999999), 1)
        lin.expire(now=111)
        self.assertIsNone(lin.parent(99999999))


class WatchFixture(RegistryFixture):
    """Two open sessions, S and T, and a Watch writing into a scratch run directory."""

    def setUp(self):
        super().setUp()
        self.run = os.path.join(self.tmp, "run")
        self.s_pid, self.s_child = self.session_proc("S")
        self.t_pid, self.t_child = self.session_proc("T")
        self.registry = cw.Registry(self.reg)
        self.watch = cw.Watch(self.rules, self.registry, self.run)
        self.task = os.path.join(self.root, "apart-research/tasks/t1")
        self.repo = os.path.join(self.root, "code/server")

    def sess(self, sid):
        return self.registry.by_sid(force=True)[sid]

    def write(self, sid, path, by_claude=False):
        self.watch.record(self.sess(sid), path, by_claude=by_claude, comm="a `sed` process")

    def inbox(self, sid):
        p = os.path.join(self.run, "inbox", sid)
        return open(p).read() if os.path.exists(p) else ""

    def consume(self, sid):
        os.remove(os.path.join(self.run, "inbox", sid))


class HoldLifecycle(WatchFixture):
    def test_a_first_write_holds_the_unit_silently(self):
        self.write("S", f"{self.task}/task.md")
        self.assertEqual(self.watch.holders(self.task), ["S"])
        self.assertEqual((self.inbox("S"), self.inbox("T")), ("", ""))

    def test_a_second_session_writing_by_bash_is_told_to_stop_and_the_holder_is_told(self):
        self.write("S", f"{self.task}/task.md")
        self.write("T", f"{self.task}/body-draft.md")
        t = self.inbox("T")
        self.assertIn("Stop changing anything", t)
        self.assertIn("name-S", t)
        self.assertIn("busy", t)
        self.assertIn(f"{self.task}/body-draft.md", t)
        self.assertNotIn("agent-worktree isolate", t)           # a task folder: no worktree offer
        s = self.inbox("S")
        self.assertIn("name-T", s)
        self.assertIn("conflict-watch release", s)

    def test_a_repo_unit_offers_the_worktree(self):
        self.write("S", f"{self.repo}/a.py")
        self.write("T", f"{self.repo}/b.py")
        self.assertIn(f"agent-worktree isolate {self.repo}", self.inbox("T"))

    def test_notices_are_coalesced_until_the_inbox_is_read(self):
        self.write("S", f"{self.task}/task.md")
        for i in range(5):
            self.write("T", f"{self.task}/f{i}.md")
        self.assertEqual(self.inbox("T").count("Stop changing anything"), 1)
        self.assertEqual(self.inbox("S").count("Conflict watch:"), 1)
        self.consume("T")
        self.consume("S")
        self.write("T", f"{self.task}/again.md")
        self.assertEqual(self.inbox("T").count("Stop changing anything"), 1)   # told again after reading
        self.assertEqual(self.inbox("S"), "")                           # the holder once per writer and unit

    def test_an_edit_by_the_claude_process_itself_was_already_asked(self):
        self.write("S", f"{self.task}/task.md")
        self.write("T", f"{self.task}/task.md", by_claude=True)
        self.assertEqual(self.inbox("T"), "")
        self.assertIn("name-T", self.inbox("S"))

    def test_a_granted_unit_is_not_flagged_again(self):
        self.write("S", f"{self.task}/task.md")
        cw.add_grant(self.run, "T", self.task, [("S", self.watch.since(self.task, "S"))])
        self.write("T", f"{self.task}/x.md")
        self.assertEqual(self.inbox("T"), "")

    def test_a_grant_covers_only_the_hold_it_named(self):
        self.write("S", f"{self.task}/task.md")
        cw.add_grant(self.run, "T", self.task, [("S", self.watch.since(self.task, "S") - 1)])   # an earlier hold of S
        self.write("T", f"{self.task}/x.md")
        self.assertIn("Stop changing anything", self.inbox("T"))

    def test_a_holder_that_closed_holds_nothing(self):
        self.write("S", f"{self.task}/task.md")
        os.kill(self.s_pid, signal.SIGKILL)
        os.waitpid(self.s_pid, 0)
        self.registry.open(force=True)
        self.watch.prune()
        self.write("T", f"{self.task}/x.md")
        self.assertEqual(self.inbox("T"), "")
        self.assertEqual(self.watch.holders(self.task), ["T"])

    def test_release_frees_the_unit_and_a_new_write_holds_it_again(self):
        self.write("S", f"{self.task}/task.md")
        self.watch.release("S", self.task)
        self.write("T", f"{self.task}/x.md")
        self.assertEqual(self.inbox("T"), "")
        self.write("S", f"{self.task}/task.md")
        self.assertEqual(sorted(self.watch.holders(self.task)), ["S", "T"])

    def test_release_of_everything_a_session_holds(self):
        self.write("S", f"{self.task}/task.md")
        self.write("S", f"{self.repo}/a.py")
        self.watch.release("S", None)
        self.assertEqual((self.watch.holders(self.task), self.watch.holders(self.repo)), ([], []))

    def test_release_requests_from_the_cli_are_applied(self):
        self.write("S", f"{self.task}/task.md")
        cw.request_release(self.run, "S", [self.task], wait=0)
        self.watch.process_requests()
        self.assertEqual(self.watch.holders(self.task), [])
        self.assertEqual(os.listdir(os.path.join(self.run, "requests")), [])

    def test_a_hold_made_only_of_ignored_files_is_no_hold(self):
        write(f"{self.repo}/.gitignore", "dist/\n")
        self.write("S", f"{self.repo}/dist/bundle.js")          # a test run's output
        self.write("T", f"{self.repo}/b.py")
        self.assertEqual(self.inbox("T"), "")
        self.watch.flush()
        held_by = [l.split("\t")[2] for l in open(os.path.join(self.run, "holds.tsv")).read().splitlines()[1:]]
        self.assertEqual(held_by, ["T"])

    def test_writing_an_ignored_file_in_a_held_repo_is_no_conflict(self):
        write(f"{self.repo}/.gitignore", "dist/\n")
        self.write("S", f"{self.repo}/a.py")
        self.write("T", f"{self.repo}/dist/bundle.js")
        self.assertEqual((self.inbox("T"), self.inbox("S")), ("", ""))

    def test_state_survives_a_restart(self):
        self.write("S", f"{self.task}/task.md")
        self.watch.flush()
        again = cw.Watch.load(self.rules, cw.Registry(self.reg), self.run)
        self.assertEqual(again.holders(self.task), ["S"])

    def test_the_published_holds_table(self):
        self.write("S", f"{self.task}/task.md")
        self.watch.flush()
        lines = open(os.path.join(self.run, "holds.tsv")).read().splitlines()
        self.assertEqual(lines[0], f"#daemon\t{os.getpid()}")
        unit, kind, sid, pid, start, since, name, last, lastfile = lines[1].split("\t")
        self.assertEqual((unit, kind, sid, int(pid), name, lastfile), (self.task, "folder", "S", self.s_pid, "name-S", f"{self.task}/task.md"))


class GitClassification(unittest.TestCase):
    CASES = {
        "git add -A": "sweep", "git add .": "sweep", "git add --all": "sweep", "git add -u": "sweep",
        "git add src/a.py": None,
        "git commit -a -m x": "sweep", "git commit -am x": "sweep", "git commit -m 'fix -a flag'": None,
        "git commit -m x": None,
        "git stash": "sweep", "git stash push": "sweep", "git stash list": None,
        "git checkout -- .": "sweep", "git checkout .": "sweep", "git checkout -- a.py": None,
        "git checkout main": "move", "git checkout -b new": None,
        "git restore .": "sweep", "git restore a.py": None,
        "git reset --hard": "sweep", "git reset HEAD~1": None,
        "git clean -fd": "sweep", "git clean -n": None,
        "git switch main": "move", "git pull": "move", "git rebase main": "move", "git rebase --continue": None,
        "git status": None, "git diff": None, "git log -5": None, "echo git add -A": None,
        "git -C sub add -A": "sweep", "GIT_EDITOR=true git commit -a": "sweep",
    }

    def test_repo_wide_commands(self):
        for cmd, want in self.CASES.items():
            got = cw.classify_git(cw.split_segments(cmd)[0])
            self.assertEqual(got[0] if got else None, want, cmd)

    def test_segments_and_directories(self):
        segs = cw.split_segments("cd sub && git -C inner add -A; echo 'a;b'")
        self.assertEqual(segs, [["cd", "sub"], ["git", "-C", "inner", "add", "-A"], ["echo", "a;b"]])
        self.assertEqual(cw.classify_git(segs[1]), ("sweep", ["inner"]))


class GitCheck(WatchFixture):
    """The PreToolUse(Bash) check before a repo-wide git command."""

    def setUp(self):
        super().setUp()
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init", cwd=self.repo)
        self.cfg = {"run": self.run}

    def check(self, command, sid="T", cwd=None):
        payload = {"session_id": sid, "cwd": cwd or self.repo, "tool_input": {"command": command}}
        return cw.hook_git(self.cfg, self.rules, self.registry, payload, {sid})

    def test_asks_listing_the_other_sessions_uncommitted_files(self):
        write(f"{self.repo}/s.py")
        self.write("S", f"{self.repo}/s.py")
        self.watch.flush()
        out = self.check("git add -A && git commit -m wip")
        self.assertEqual(out["permissionDecision"], "ask")
        self.assertIn("name-S", out["permissionDecisionReason"])
        self.assertIn("s.py", out["permissionDecisionReason"])

    def test_files_the_holder_already_committed_do_not_count(self):
        write(f"{self.repo}/s.py")
        self.write("S", f"{self.repo}/s.py")
        git("add", "s.py", cwd=self.repo)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "s", cwd=self.repo)
        self.watch.flush()
        self.assertIsNone(self.check("git add -A"))

    def test_own_files_and_scoped_commands_pass(self):
        write(f"{self.repo}/t.py")
        self.write("T", f"{self.repo}/t.py")
        write(f"{self.repo}/s.py")
        self.write("S", f"{self.repo}/s.py")
        self.watch.flush()
        self.assertIsNone(self.check("git add t.py && git commit -m t"))
        self.assertIn("name-T", self.check("git add -A", sid="S")["permissionDecisionReason"])   # sweeps T's file

    def test_a_sweep_over_only_your_own_work_passes(self):
        write(f"{self.repo}/t.py")
        self.write("T", f"{self.repo}/t.py")
        self.watch.flush()
        self.assertIsNone(self.check("git commit -am mine"))

    def test_a_cd_into_the_repo_counts(self):
        write(f"{self.repo}/s.py")
        self.write("S", f"{self.repo}/s.py")
        self.watch.flush()
        self.assertIsNotNone(self.check("cd code/server && git stash", cwd=self.root))

    def test_a_branch_switch_asks_whenever_someone_works_in_the_repo(self):
        write(f"{self.repo}/s.py")
        self.write("S", f"{self.repo}/s.py")
        git("add", "s.py", cwd=self.repo)
        git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "s", cwd=self.repo)
        self.watch.flush()
        self.assertEqual(self.check("git switch -c x; git checkout main")["permissionDecision"], "ask")


if __name__ == "__main__":
    unittest.main(verbosity=1)
