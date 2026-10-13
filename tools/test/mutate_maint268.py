# MAINTENANCE row 268 mutation battery: the moisture store's Time Guard version-skew guard reads the class
# list through the instance (src/SoilMoistureSystem.lua: registerDailyAccrual). Rows live in
# tools/test/lua/MAINT-268-timeguard_skew_guard_entry_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes. Targeted runs only (Tyson,
# 2026-09-30): each mutant runs SELECTED, the two benches that call registerDailyAccrual (this PR's and
# scs041_parcel_union_raster_test.lua, whose fixture this PR corrects). The 45 other benches that load
# src/SoilMoistureSystem.lua never reach the registration; they ran once, unmutated, as the PR's selection
# baseline. This repo's runner has no selection, so the script writes a filtered copy of run-tests.mjs beside
# it for the run and deletes it after. Run ONE mutant per call, in the foreground, and check free memory by
# hand right before each (1 GB or more).
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error or a crashed group: a weak kill.
#
# NOT RUN, and why: comments; the scs041 fixture change (a bench file, not code under test).
#
# Usage (from the repo root):
#        py tools/test/mutate_maint268.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint268.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint268.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_maint268.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SMS = "src/SoilMoistureSystem.lua"
READ = '    local fc = type(tg.scheduler) == "table" and tg.scheduler.FLOW_CLASSES or nil\n'
TEST = '    if type(fc) == "table" and fc.simulation ~= true then\n'

SELECTED = [
    "MAINT-268-timeguard_skew_guard_entry_test.lua",
    "scs041_parcel_union_raster_test.lua",
]
FILTER_FROM = 'const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();'
FILTER_TO = ('const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua") && '
             'process.env.MUTATE_SELECTED.split(",").includes(f)).sort();')

MUTATIONS = [
 ("M01-old-field", SMS,
  [(READ, "    local fc = tg.flowClasses\n", 1)],
  "the store reads the field Time Guard never publishes, as before: v1.0.0.0 registers (E2)"),
 ("M02-bare-global", SMS,
  [(READ, "    local fc = TimeGuardScheduler ~= nil and TimeGuardScheduler.FLOW_CLASSES or nil\n", 1)],
  "the store reads Time Guard's own-environment global, as before: v1.0.0.0 registers (E2)"),
 ("M03-inverted", SMS,
  [(TEST, '    if type(fc) == "table" and fc.simulation == true then\n', 1)],
  "the store refuses a current Time Guard and accepts v1.0.0.0 (E1, E2, scs041 P0)"),
 ("M04-not-nil-safe", SMS,
  [(READ, "    local fc = tg.scheduler.FLOW_CLASSES\n", 1)],
  "the store indexes a missing scheduler: the updater raises and nothing registers (E3)"),
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
