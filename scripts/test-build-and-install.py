#!/usr/bin/env python3
"""Black-box installer tests: stdlib only, no Xcode, keychain or app launches."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / "build-and-install.sh"

# One dispatcher installed under every mocked command name. Filesystem writes
# are guarded even if an installer regression accidentally uses /Applications.
MOCK = r'''
import json, os, pathlib, shutil, signal, subprocess, sys, time
p = pathlib.Path
root = p(os.environ["TEST_ROOT"]).resolve()
name, args = p(sys.argv[0]).name, sys.argv[1:]
mode = os.environ["TEST_MODE"]
dest = os.environ["ICE_INSTALL_APP_PATH"]
with p(os.environ.get("TEST_EVENTS", root / "events")).open("a") as f:
    f.write(json.dumps([name, args]) + "\n")
def safe(value):
    path = p(value)
    # No "..": mkdir -p creates each component before resolving the next one.
    assert ".." not in path.parts, value
    # Check the parent without following the last component (symlink fixtures).
    assert path.is_absolute() and path.parent.resolve().is_relative_to(root), value
    return path
def fail():
    sys.exit(23)
def interrupt():
    # Like a closed terminal: bash runs its EXIT trap once this command returns.
    os.kill(os.getppid(), signal.SIGTERM)
def wait_at_gate():
    # Hold this installer inside its critical section until the test releases it.
    gate = root / "gate"
    gate.mkdir(exist_ok=True)
    (gate / "reached").write_text(str(os.getppid()))
    deadline = time.time() + 15
    while not (gate / "release").exists():
        if time.time() > deadline:
            fail()
        time.sleep(0.02)
if name == "security":
    if args[0] == "default-keychain":
        print('"' + str(root / "fake.keychain-db") + '"')
    elif args[0] == "find-identity":
        if mode not in ("missing", "import_fail", "export_fail"):
            print('  1) ' + 'A'*40 + ' "Ice Local Development"')
    elif args[0] == "import":
        assert args[args.index("-k") + 1] == str(root / "fake.keychain-db")
        fail()
    else:
        raise AssertionError(args)
elif name == "openssl":
    for flag in ("-keyout", "-out"):
        if flag in args:
            safe(args[args.index(flag) + 1]).write_text("fake secret")
    if mode == "missing" or (mode == "export_fail" and args[0] == "pkcs12"):
        fail()
elif name == "codesign":
    target = safe(args[-1])
    if "--verify" in args:
        if mode == "stage_verify_fail" and str(target) != dest:
            fail()
        if mode in ("verify_fail", "restore_move_fail", "restore_remove_fail", "interrupt_during_restore") and str(target) == dest:
            fail()
    else:
        if mode == "sign_fail" or (mode == "nested_sign_fail" and target.suffix == ".xpc"):
            fail()
        (target / "signed").write_text(args[args.index("--sign") + 1])
elif name == "ditto":
    assert args[:2] == ["--norsrc", "--noextattr"], args
    source, target = map(safe, args[-2:])
    if (mode == "stage_copy_fail" and str(target) != dest) or (mode == "copy_fail" and str(target) == dest):
        target.mkdir(parents=True, exist_ok=True)
        (target / "partial").write_text("incomplete")
        fail()
    if mode == "interrupt_during_copy" and str(target) == dest:
        target.mkdir(parents=True, exist_ok=True)
        (target / "partial").write_text("incomplete")
        interrupt()
        sys.exit(0)
    if mode == "block_during_copy" and str(target) == dest:
        target.mkdir(parents=True, exist_ok=True)
        (target / "partial").write_text("incomplete")
        wait_at_gate()
    shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)
elif name == "mv":
    source, target = map(safe, args)
    if mode == "backup_move_fail" and str(source) == dest:
        fail()
    if mode == "backup_partial_fail" and str(source) == dest:
        # Cross-filesystem mv copies first: a failed copy leaves a partial backup.
        target.mkdir(parents=True)
        (target / "partial").write_text("incomplete")
        fail()
    if mode == "interrupt_during_backup" and str(source) == dest:
        # The signal arrives while mv is still running; mv finishes afterwards.
        interrupt()
        time.sleep(0.5)
    if mode == "restore_move_fail" and str(target) == dest:
        fail()
    if mode == "interrupt_during_restore" and str(target) == dest:
        # A second signal while rollback's mv runs must not start recovery again.
        interrupt()
        time.sleep(0.5)
    # Match mv's existing-directory semantics (important for collision tests).
    shutil.move(str(source), str(target))
    if mode == "interrupt_after_backup" and str(source) == dest:
        interrupt()
elif name == "rm":
    for arg in args:
        if arg.startswith("-"):
            continue
        target = safe(arg)
        if mode == "restore_remove_fail" and str(target) == dest:
            fail()
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)
elif name == "date":
    print("20261029-120000")
elif name == "find":
    safe(args[0])
    if mode == "find_fail":
        fail()
    sys.exit(subprocess.call([os.environ["TEST_REAL_FIND"], *args]))
elif name in ("ln", "readlink"):
    safe(args[-1])
    sys.exit(subprocess.call([os.environ["TEST_REAL_" + name.upper()], *args]))
elif name == "mkdir":
    for arg in args:
        if not arg.startswith("-"):
            safe(arg)
    sys.exit(subprocess.call([os.environ["TEST_REAL_MKDIR"], *args]))
elif name == "mktemp":
    # Require an explicit template: without one, macOS ignores TMPDIR.
    templates = [arg for arg in args if not arg.startswith("-")]
    assert templates and "-t" not in args, args
    for template in templates:
        safe(template)
    created = subprocess.run([os.environ["TEST_REAL_MKTEMP"], *args],
                             check=True, text=True, stdout=subprocess.PIPE).stdout
    for line in created.splitlines():
        safe(line)
    sys.stdout.write(created)
elif name in ("open", "pkill", "sleep"):
    if name == "open":
        assert args == [dest]
    if name == "pkill" and mode == "not_running":
        sys.exit(1)
    if name == "sleep" and mode == "block_after_preflight":
        # The backup name is chosen but the old app not yet moved: the race window.
        wait_at_gate()
else:
    raise AssertionError(name)
'''


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ice installer tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source = self.root / "source" / "Ice.app"
        self.dest = self.root / "Applications" / "Ice.app"
        self.backups = self.dest.parent / "Ice-backups.noindex"
        self.backup = self.backups / "Ice-20261029-120000.app"
        self.lock = self.dest.parent / ".Ice.app.install-lock"
        self.gate = self.root / "gate"
        self.bin = self.root / "bin"
        self.tmp = self.root / "tmp"
        for directory in (self.bin, self.tmp, self.dest.parent, self.root / "home"):
            directory.mkdir(parents=True)
        for app, version in ((self.source, "new"), (self.dest, "old")):
            (app / "Contents").mkdir(parents=True)
            (app / "Contents" / "version").write_text(version)
        (self.source / "Contents" / "Helper.xpc").mkdir()
        (self.source / "Contents" / "Framework.framework").mkdir()
        # A closed PATH prevents fallback to real security/openssl/open/pkill.
        for command in ("bash", "sed", "awk", "tail"):
            executable = shutil.which(command)
            self.assertIsNotNone(executable, command)
            (self.bin / command).symlink_to(executable)
        # env, not the interpreter path: the kernel splits a shebang at spaces.
        (self.bin / "python3").symlink_to(sys.executable)
        for command in ("security", "openssl", "codesign", "ditto", "mv", "rm", "date", "open", "pkill", "sleep", "find", "mkdir", "mktemp", "ln", "readlink"):
            script = self.bin / command
            script.write_text("#!/usr/bin/env python3\n" + MOCK)
            script.chmod(0o755)
        self.env = {
            "PATH": str(self.bin), "HOME": str(self.root / "home"),
            "TEST_REAL_FIND": shutil.which("find"),
            "TEST_REAL_MKDIR": shutil.which("mkdir"),
            "TEST_REAL_MKTEMP": shutil.which("mktemp"),
            "TEST_REAL_LN": shutil.which("ln"),
            "TEST_REAL_READLINK": shutil.which("readlink"),
            "TMPDIR": str(self.tmp), "TEST_ROOT": str(self.root),
            "ICE_INSTALL_SOURCE": str(self.source),
            "ICE_INSTALL_APP_PATH": str(self.dest),
            "ICE_INSTALL_NO_STOP": "1", "ICE_INSTALL_NO_LAUNCH": "1",
        }

    def run_install(self, mode="success", *, stop=False, launch=False):
        self.env.update(TEST_MODE=mode, TEST_EVENTS=str(self.root / "events"), ICE_INSTALL_NO_STOP="0" if stop else "1",
                        ICE_INSTALL_NO_LAUNCH="0" if launch else "1")
        self.result = subprocess.run([str(self.bin / "bash"), str(INSTALLER)],
                                     env=self.env, cwd=self.root, text=True,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     timeout=20)
        self.events = [json.loads(line) for line in (self.root / "events").read_text().splitlines()]
        return self.result

    def assert_clean(self):
        self.assertEqual(list(self.tmp.iterdir()), [], self.result.stdout)
        self.assertEqual((self.source / "Contents/version").read_text(), "new")
        self.assertFalse((self.source / "signed").exists())
        # Every exit path, including signals, releases the install lock.
        self.assertFalse(self.lock.is_symlink() or self.lock.exists(), self.result.stdout)

    def assert_old(self):
        self.assertEqual((self.dest / "Contents/version").read_text(), "old", self.result.stdout)
        self.assertEqual(sorted(p.name for p in self.dest.iterdir()), ["Contents"])

    def assert_failed_before_stop(self, mode):
        self.assertNotEqual(self.run_install(mode, stop=True, launch=True).returncode, 0)
        self.assert_old()
        self.assertFalse(self.backups.exists())
        self.assertFalse(any(name in ("pkill", "open", "mv") for name, _ in self.events))
        self.assert_clean()

    def test_missing_identity(self):
        self.assert_failed_before_stop("missing")
        self.assertFalse(any(name == "codesign" for name, _ in self.events))

    def test_import_failure_cleans_key_material(self):
        self.assert_failed_before_stop("import_fail")
        self.assertTrue(any(name == "security" and args[0] == "import" for name, args in self.events))

    def test_export_failure_cleans_key_material(self):
        self.assert_failed_before_stop("export_fail")

    def test_sign_failure(self):
        self.assert_failed_before_stop("sign_fail")

    def test_nested_sign_failure(self):
        self.assert_failed_before_stop("nested_sign_fail")

    def test_stage_verification_failure(self):
        self.assert_failed_before_stop("stage_verify_fail")

    def test_stage_copy_failure(self):
        self.assert_failed_before_stop("stage_copy_fail")

    def test_bundle_enumeration_failure(self):
        self.assert_failed_before_stop("find_fail")

    def test_copy_failure_restores_and_relaunches(self):
        self.assertEqual(self.run_install("copy_fail", stop=True, launch=True).returncode, 23)
        self.assert_old()
        self.assertFalse(self.backup.exists())
        self.assertEqual(self.events[-1][0], "rm")  # staging cleanup after restore
        self.assertEqual([args for name, args in self.events if name == "open"], [[str(self.dest)]])
        self.assert_clean()

    def test_destination_verification_failure(self):
        self.assertEqual(self.run_install("verify_fail").returncode, 23)
        self.assert_old()
        self.assertFalse(self.backup.exists())
        self.assertFalse(any(name == "open" for name, _ in self.events))
        self.assert_clean()

    def test_collision_directory(self):
        self.backup.mkdir(parents=True)
        (self.backup / "sentinel").write_text("keep")
        self.assertNotEqual(self.run_install(stop=True, launch=True).returncode, 0)
        self.assert_old()
        self.assertEqual((self.backup / "sentinel").read_text(), "keep")
        self.assertFalse(any(name in ("pkill", "open", "mv") for name, _ in self.events))
        self.assert_clean()

    def test_collision_dangling_symlink(self):
        self.backups.mkdir()
        self.backup.symlink_to(self.root / "missing")
        self.assertNotEqual(self.run_install(stop=True, launch=True).returncode, 0)
        self.assert_old()
        self.assertTrue(self.backup.is_symlink())
        self.assertFalse(any(name in ("pkill", "open", "mv") for name, _ in self.events))
        self.assert_clean()

    def test_collision_regular_file(self):
        self.backups.mkdir()
        self.backup.write_text("keep")
        self.assertNotEqual(self.run_install(stop=True).returncode, 0)
        self.assert_old()
        self.assertEqual(self.backup.read_text(), "keep")
        self.assertFalse(any(name == "pkill" for name, _ in self.events))
        self.assert_clean()

    def test_failed_first_install_removes_partial_app(self):
        shutil.rmtree(self.dest)
        self.assertEqual(self.run_install("copy_fail").returncode, 23)
        self.assertFalse(self.dest.exists(), self.result.stdout)
        self.assert_clean()

    def test_failed_first_verification_removes_app(self):
        shutil.rmtree(self.dest)
        self.assertEqual(self.run_install("verify_fail").returncode, 23)
        self.assertFalse(self.dest.exists(), self.result.stdout)
        self.assert_clean()

    def test_rollback_does_not_launch_when_app_was_not_running(self):
        # Stop skipped: rollback must not start an app it did not stop.
        self.assertEqual(self.run_install("verify_fail", launch=True).returncode, 23)
        self.assert_old()
        self.assertFalse(any(name == "open" for name, _ in self.events))
        self.assert_clean()

    def test_backup_move_failure_leaves_app(self):
        self.assertEqual(self.run_install("backup_move_fail").returncode, 23)
        self.assert_old()
        self.assert_clean()

    def test_backup_dir_failure_leaves_app(self):
        self.backups.write_text("not a directory")  # mkdir -p fails
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assert_old()
        self.assert_clean()

    def test_restore_move_failure_keeps_backup_and_cleans_staging(self):
        self.assertEqual(self.run_install("restore_move_fail").returncode, 23)
        self.assertEqual((self.backup / "Contents/version").read_text(), "old")
        self.assertIn(str(self.backup), self.result.stdout)
        self.assert_clean()

    def test_restore_remove_failure_never_nests_backup(self):
        self.assertEqual(self.run_install("restore_remove_fail").returncode, 23)
        self.assertEqual((self.backup / "Contents/version").read_text(), "old")
        self.assertFalse((self.dest / self.backup.name).exists())
        self.assertIn(str(self.backup), self.result.stdout)
        self.assert_clean()

    def test_failed_first_install_remove_failure_reports_app(self):
        shutil.rmtree(self.dest)
        self.assertEqual(self.run_install("restore_remove_fail").returncode, 23)
        self.assertIn("Could not remove the incomplete app at " + str(self.dest), self.result.stdout)
        self.assertNotIn("previous app remains", self.result.stdout)
        self.assert_clean()

    def test_interrupt_after_backup_restores_app(self):
        # SIGTERM lands between moving the old app away and copying the new one.
        self.assertEqual(self.run_install("interrupt_after_backup", stop=True, launch=True).returncode, -signal.SIGTERM)
        self.assert_old()
        self.assertFalse(self.backup.exists())
        self.assertEqual([args for name, args in self.events if name == "open"], [[str(self.dest)]])
        self.assertFalse(any(name == "ditto" and args[-1] == str(self.dest) for name, args in self.events))
        self.assert_clean()

    def test_interrupt_during_backup_move_restores_app(self):
        # Recovery must wait for the running mv, not race it.
        self.assertEqual(self.run_install("interrupt_during_backup", stop=True, launch=True).returncode, -signal.SIGTERM)
        self.assert_old()
        self.assertFalse(self.backup.exists())
        self.assertEqual([args for name, args in self.events if name == "open"], [[str(self.dest)]])
        self.assert_clean()

    def test_partial_backup_keeps_original(self):
        self.assertEqual(self.run_install("backup_partial_fail").returncode, 23)
        self.assert_old()
        self.assertTrue((self.backup / "partial").exists())
        self.assert_clean()

    def test_interrupt_during_restore_keeps_restored_app(self):
        self.assertEqual(self.run_install("interrupt_during_restore").returncode, -signal.SIGTERM)
        self.assert_old()
        self.assertFalse(self.backup.exists())
        self.assert_clean()

    def test_interrupt_during_copy_restores_app(self):
        self.assertEqual(self.run_install("interrupt_during_copy").returncode, -signal.SIGTERM)
        self.assert_old()
        self.assertFalse(self.backup.exists())
        self.assert_clean()

    def test_success_keeps_backup_and_verifies_before_launch(self):
        self.assertEqual(self.run_install(stop=True, launch=True).returncode, 0, self.result.stdout)
        self.assertEqual((self.dest / "Contents/version").read_text(), "new")
        self.assertEqual((self.backup / "Contents/version").read_text(), "old")
        commands = [name for name, _ in self.events]
        self.assertLess(commands.index("codesign"), commands.index("pkill"))
        self.assertLess(max(i for i, n in enumerate(commands) if n == "codesign"), commands.index("open"))
        signed = [args[-1] for name, args in self.events if name == "codesign" and "--sign" in args]
        self.assertEqual(Path(signed[-1]).name, "Ice.app")
        self.assertEqual({Path(x).suffix for x in signed[:-1]}, {".xpc", ".framework"})
        self.assert_clean()

    # Concurrency: a second installer runs while the first is held at a gate.
    def start_install(self, mode, label, *, stop=False):
        env = dict(self.env, TEST_MODE=mode, TEST_EVENTS=str(self.root / f"events-{label}"),
                   ICE_INSTALL_NO_STOP="0" if stop else "1")
        process = subprocess.Popen([str(self.bin / "bash"), str(INSTALLER)], env=env, cwd=self.root,
                                   text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.addCleanup(self.stop_process, process)
        return process

    def stop_process(self, process):
        self.release_gate()
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=20)

    def wait_for_gate(self, process):
        deadline = time.monotonic() + 15
        while not (self.gate / "reached").exists():
            if process.poll() is not None:
                self.fail("first installer exited early:\n" + process.communicate()[0])
            self.assertLess(time.monotonic(), deadline, "first installer never reached the gate")
            time.sleep(0.02)

    def release_gate(self):
        self.gate.mkdir(exist_ok=True)
        (self.gate / "release").touch()

    def lock_owner_pid(self):
        return int(os.readlink(self.lock).split("-")[0])

    def assert_refused_untouched(self, status=75):
        self.assertEqual(self.result.returncode, status, self.result.stdout)
        self.assertIn("nothing was changed", self.result.stdout)
        # The refused installer only read the keychain path and tried the lock.
        self.assertLessEqual({name for name, _ in self.events}, {"security", "ln", "readlink"}, self.events)

    def finish_first(self, first):
        self.release_gate()
        output = first.communicate(timeout=20)[0]
        self.assertEqual(first.returncode, 0, output)
        self.assertEqual((self.dest / "Contents/version").read_text(), "new")
        self.assertEqual((self.backup / "Contents/version").read_text(), "old")
        self.assertEqual(list(self.backups.iterdir()), [self.backup])
        self.assert_clean()

    def test_second_installer_refused_in_backup_name_window(self):
        # The first installer picked the backup name but has not moved the app yet.
        # Without a lock the second picks the same name (the clock is mocked to
        # one second) and both move or replace the same app.
        first = self.start_install("block_after_preflight", "first", stop=True)
        self.wait_for_gate(first)
        self.run_install()
        self.assert_refused_untouched()
        self.assertIn(f"(PID {first.pid})", self.result.stdout)
        self.assertIn("Wait for it to finish", self.result.stdout)
        self.assert_old()
        self.assertFalse(self.backups.exists())
        self.assertEqual(self.lock_owner_pid(), first.pid)
        self.finish_first(first)

    def test_second_installer_refused_during_copy(self):
        first = self.start_install("block_during_copy", "first")
        self.wait_for_gate(first)
        self.run_install()
        self.assert_refused_untouched()
        # Neither the half-copied destination nor the backup were touched.
        self.assertEqual(sorted(x.name for x in self.dest.iterdir()), ["partial"])
        self.assertEqual((self.backup / "Contents/version").read_text(), "old")
        self.assertEqual(list(self.backups.iterdir()), [self.backup])
        self.assertEqual(self.lock_owner_pid(), first.pid)
        self.finish_first(first)

    def test_lock_released_after_failure_allows_next_install(self):
        self.assertEqual(self.run_install("copy_fail").returncode, 23)
        self.assert_old()
        self.assert_clean()
        self.assertEqual(self.run_install().returncode, 0, self.result.stdout)
        self.assertEqual((self.dest / "Contents/version").read_text(), "new")
        self.assert_clean()

    def test_sigkill_leaves_stale_lock_that_is_reported_not_broken(self):
        # SIGKILL runs no trap: the lock stays, and later installers refuse until
        # someone removes it; they never guess that the owner is gone.
        first = self.start_install("block_after_preflight", "first", stop=True)
        self.wait_for_gate(first)
        first.kill()
        first.communicate(timeout=20)
        self.release_gate()
        self.run_install()
        self.assert_refused_untouched()
        self.assertIn(f"PID {first.pid} is not running", self.result.stdout)
        self.assertEqual(self.lock_owner_pid(), first.pid)
        self.assert_old()
        self.assertFalse(self.backups.exists())
        # The killed installer's staging copy is left behind as well.
        leftovers = list(self.tmp.iterdir())
        self.assertEqual(len(leftovers), 1)
        self.remove_lock_as_printed()
        self.assertEqual(self.run_install().returncode, 0, self.result.stdout)
        self.assertEqual(list(self.tmp.iterdir()), leftovers)
        self.assertFalse(self.lock.is_symlink())

    def remove_lock_as_printed(self):
        # Run the printed recovery command with the real rm, as a user would paste it.
        command = self.result.stdout.split("remove the lock: ", 1)[1].splitlines()[0]
        subprocess.run([os.path.realpath(self.bin / "bash"), "-c", command], check=True)
        self.assertFalse(self.lock.is_symlink() or self.lock.exists(), command)

    def test_stale_lock_command_quotes_path(self):
        # An apostrophe in the folder must not break the printed rm command.
        folder = self.root / "Mario's Apps"
        self.dest.parent.rename(folder)
        self.dest, self.lock = folder / "Ice.app", folder / ".Ice.app.install-lock"
        self.backups = folder / "Ice-backups.noindex"
        self.env["ICE_INSTALL_APP_PATH"] = str(self.dest)
        dead = subprocess.Popen([sys.executable, "-c", ""])
        dead.wait()
        os.symlink(f"{dead.pid}-1", self.lock)
        self.run_install()
        self.assert_refused_untouched()
        self.assertIn(f"PID {dead.pid} is not running", self.result.stdout)
        self.remove_lock_as_printed()
        self.assertEqual(self.run_install().returncode, 0, self.result.stdout)
        self.assertEqual((self.dest / "Contents/version").read_text(), "new")
        self.assert_clean()

    def test_first_install_creates_missing_destination_folder(self):
        # e.g. ICE_INSTALL_APP_PATH=~/Applications/Ice.app on a fresh account.
        shutil.rmtree(self.dest.parent)
        self.assertEqual(self.run_install().returncode, 0, self.result.stdout)
        self.assertEqual((self.dest / "Contents/version").read_text(), "new")
        self.assertFalse(self.backups.exists())
        self.assert_clean()

    def test_lock_owned_by_live_process_is_respected(self):
        # A matching PID with another token is still someone else's lock.
        os.symlink(f"{os.getpid()}-1", self.lock)
        self.run_install()
        self.assert_refused_untouched()
        self.assertIn("Wait for it to finish", self.result.stdout)
        self.assertEqual(os.readlink(self.lock), f"{os.getpid()}-1")
        self.assert_old()
        self.assertFalse(self.backups.exists())

    def test_occupied_lock_path_is_not_used(self):
        # ln would create its link inside a directory; refuse instead.
        self.lock.mkdir()
        self.run_install()
        self.assert_refused_untouched(status=1)
        self.assertIn("occupied", self.result.stdout)
        self.assertEqual(list(self.lock.iterdir()), [])
        self.assert_old()

    def test_harness_rejects_parent_traversal(self):
        escaped = self.root.parent / (self.root.name + "-escaped")
        self.addCleanup(shutil.rmtree, escaped, ignore_errors=True)
        sneaky = f"{self.root}/../{escaped.name}/../{self.root.name}/backup"
        self.env["TEST_MODE"] = "success"
        result = subprocess.run([str(self.bin / "mkdir"), "-p", sneaky], env=self.env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(escaped.exists())

    def test_explicit_adhoc(self):
        self.env["ICE_ADHOC_SIGNING"] = "1"
        self.assertEqual(self.run_install().returncode, 0, self.result.stdout)
        self.assertEqual((self.dest / "signed").read_text(), "-")
        self.assertFalse(any(name == "openssl" for name, _ in self.events))
        self.assert_clean()


if __name__ == "__main__":
    unittest.main(verbosity=2)
