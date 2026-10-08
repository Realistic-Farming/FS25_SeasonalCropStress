# MAINTENANCE row 289 mutation battery: SCS's per-player settings (hudVisible, alertsEnabled, alertCooldown) stay
# per player (src/settings/SettingsHubBridge.lua: LOCAL_KEYS, applyChange's local branch, the registration's scopes;
# src/settings/CropStressSettingsPanel.lua: localOnly on the two alert keys; src/events/CropStressSettingsSyncEvent.lua:
# BULK_COUNT, the bulk write, the bulk and single applies). Rows live in
# tools/test/lua/MAINT-289-per_player_settings_stay_local_entry_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes, one mutant per defense. The bulk path
# has two (the write drops the keys, the apply skips them), so each has its own row (J0 the write, J2 the apply) and
# neither mutant is shadowed by the other. Targeted runs only (Tyson, 2026-09-30): each mutant runs SELECTED, this
# PR's bench; the eight other benches that load a changed file ran once, unmutated, as the PR's selection baseline.
# This repo's runner has no selection, so the script writes a filtered copy of run-tests.mjs beside it for the run
# and deletes it after. Run ONE mutant per call, in the foreground, and check free memory by hand right before each.
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error or a crashed group: a weak kill.
#
# NOT RUN, and why: comments; the save inside the local branch (the bench has no file system to read back).
#
# Usage (from the repo root):
#        py tools/test/mutate_maint289.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint289.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint289.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_maint289.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

BRIDGE = "src/settings/SettingsHubBridge.lua"
PANEL = "src/settings/CropStressSettingsPanel.lua"
EVENT = "src/events/CropStressSettingsSyncEvent.lua"

SELECTED = [
    "MAINT-289-per_player_settings_stay_local_entry_test.lua",
]
FILTER_FROM = 'const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();'
FILTER_TO = ('const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua") && '
             'process.env.MUTATE_SELECTED.split(",").includes(f)).sort();')

MUTATIONS = [
 ("M01-hub-local-through-owner", BRIDGE,
  [("    if LOCAL_KEYS[key] then\n", "    if false then\n", 1)],
  "a Tablet change to a per-player key goes through the owner and broadcasts again, the #226 regression (T1)"),
 ("M02-alerts-registered-admin", BRIDGE,
  [('adminOnly = false, label = "Stress Alerts" },\n', 'adminOnly = true,  label = "Stress Alerts" },\n', 1)],
  "the hub registers Stress Alerts as a server setting: a non-admin cannot change it, and the host's broadcasts (R1, T1)"),
 ("M03-debug-registered-local", BRIDGE,
  [('adminOnly = true,  label = "Debug Mode" },\n', 'adminOnly = false, label = "Debug Mode" },\n', 1)],
  "the hub registers Debug Mode player-local again, against SCS's panel (R1, A1)"),
 ("M04-panel-alerts-broadcast", PANEL,
  [('        stype = "bool",\n        localOnly = true,\n    },\n', '        stype = "bool",\n    },\n', 1)],
  "SCS's own panel sends Crop Alerts through the owner and broadcasts it (P1)"),
 ("M05-panel-cooldown-broadcast", PANEL,
  [("        localOnly = true,   -- [MAINTENANCE row 289] per player\n", "", 1)],
  "SCS's own panel sends Alert Cooldown through the owner and broadcasts it (P1)"),
 ("M06-bulk-writes-hud", EVENT,
  [("CropStressSettingsSyncEvent.BULK_COUNT = 9\n", "CropStressSettingsSyncEvent.BULK_COUNT = 10\n", 1),
   ('        self:writeSetting(streamId, "difficulty",         settings.difficulty)\n',
    '        self:writeSetting(streamId, "difficulty",         settings.difficulty)\n'
    '        self:writeSetting(streamId, "hudVisible",         settings.hudVisible)\n', 1)],
  "the bulk event carries the host's HUD visibility again (J0)"),
 ("M07-bulk-applies-per-player", EVENT,
  [("        if not CropStressSettingsSyncEvent.PER_PLAYER[key] then\n", "        if true then\n", 1)],
  "a bulk table that carries a per-player key overwrites the client's own (J2)"),
 ("M08-single-applies-per-player", EVENT,
  [("    if CropStressSettingsSyncEvent.PER_PLAYER[key] then return end\n", "", 1)],
  "a single event that carries a per-player key overwrites the client's own (S1)"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def read(rel):
    with open(p(rel), "rb") as f: return f.read()


def anchors(rel, edits):
    data = read(rel)
    crlf = b"\r\n" in data
    out = []
    for old, new, want in edits:
        o = old.encode("utf-8")
        n = new.encode("utf-8")
        if crlf:
            o = o.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            n = n.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
        out.append((o, n, want, data.count(o)))
    return data, out


def run_suite():
    here = os.path.join(ROOT, "tools", "test")
    runner = open(os.path.join(here, "run-tests.mjs"), encoding="utf-8").read()
    if runner.count(FILTER_FROM) != 1:
        raise SystemExit("run-tests.mjs changed: the selection anchor is not found once")
    sel = os.path.join(here, "_mutate_selected_runner.mjs")
    with open(sel, "w", encoding="utf-8", newline="\n") as f:
        f.write(runner.replace(FILTER_FROM, FILTER_TO))
    try:
        env = dict(os.environ, MUTATE_SELECTED=",".join(SELECTED))
        r = subprocess.run(["node", "_mutate_selected_runner.mjs"], cwd=here, env=env,
                           capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        os.remove(sel)
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip().encode("ascii", "replace").decode("ascii"))
    lines = [strip(l) for l in out.splitlines()]
    fails = [l for l in lines if l.startswith("FAIL ") or "Lua error" in l or "crashed" in l]
    return r.returncode, fails, out


def main(argv):
    if not argv or argv[0] == "--list":
        for mid, rel, _, why in MUTATIONS: print(f"{mid:34s} {rel}  {why}")
        return 0
    if argv[0] == "--check":
        bad = 0
        for mid, rel, edits, _ in MUTATIONS:
            _, found = anchors(rel, edits)
            for i, (_, _, want, got) in enumerate(found):
                if got != want:
                    bad += 1
                    print(f"ANCHOR {mid} edit {i + 1}: want {want}, found {got}")
        print(f"{len(MUTATIONS)} mutants, {bad} bad anchor(s)")
        return 1 if bad else 0
    if argv[0] == "--baseline":
        rc, fails, out = run_suite()
        tail = [l for l in out.strip().splitlines() if l.strip()]
        print(re.sub(r"\x1b\[[0-9;]*m", "", tail[-1]) if tail else "(no output)")
        return rc
    picked = [m for m in MUTATIONS if m[0].startswith(argv[0])]
    if len(picked) != 1:
        print(f"'{argv[0]}' matches {len(picked)} mutants; name exactly one")
        return 2
    mid, rel, edits, why = picked[0]
    data, found = anchors(rel, edits)
    for i, (_, _, want, got) in enumerate(found):
        if got != want:
            print(f"{mid}: ANCHOR edit {i + 1} want {want}, found {got}; nothing changed")
            return 2
    before = sha(data)
    mutated = data
    for o, n, _, _ in found: mutated = mutated.replace(o, n)
    if mutated == data:
        print(f"{mid}: the edit changed nothing; not run")
        return 2
    try:
        with open(p(rel), "wb") as f: f.write(mutated)
        rc, fails, _ = run_suite()
    finally:
        with open(p(rel), "wb") as f: f.write(data)
    after = sha(read(rel))
    if after != before:
        print(f"{mid}: RESTORE FAILED ({before[:12]} -> {after[:12]})")
        return 3
    assertion = [f for f in fails if "Lua error" not in f and "crashed" not in f and not f.startswith("FAIL -")]
    verdict = "SURVIVED" if rc == 0 else ("KILLED" if assertion else "KILLED*")
    print(f"{mid}: {verdict}  ({why}); restored {before[:12]}")
    shown = assertion + [f for f in fails if f not in assertion]
    for f in shown[:12]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
