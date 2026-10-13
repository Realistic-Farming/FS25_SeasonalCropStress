# MAINTENANCE row 269 mutation battery: with SCS switched off, the companion facade answers as SCS absent,
# the harvest hook takes no cut, and SCS's own PDA and HUD list show no reading.
# Rows live in tools/test/lua/MAINT-269-switch_off_reads_absent_entry_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes. Targeted runs only (Tyson,
# 2026-09-30): each mutant runs SELECTED, the one bench that switches SCS off. The 23 other benches that load
# a changed file never switch SCS off, so none of them can reach a gate in its off state; they ran once,
# unmutated, as the PR's selection baseline. This repo's runner has no selection, so the script writes a
# filtered copy of run-tests.mjs beside it for the run and deletes it after. Run ONE mutant per call, in the
# foreground, and check free memory by hand right before each (1 GB or more).
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error or a crashed group: a weak kill.
#
# NOT RUN, and why: the getCriticalAlertHint gate (with no AutoDrive in the bench world the hint is nil with
# or without the gate, so no row can fail); the moisture map overlay's three gates (CsMoistureMapOverlay.lua
# is not in the bench world); CropConsultant's `or 0` (the consultant runs only from the hourly tick, which
# the switch already stops); comments.
#
# Usage (from the repo root):
#        py tools/test/mutate_maint269.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint269.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint269.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_maint269.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MGR = "src/CropStressManager.lua"
MOD = "src/CropStressModifier.lua"
PDA = "src/ui/CsRfPdaGuest.lua"
HUD = "src/HUDOverlay.lua"

# The one bench that switches SCS off (see the header).
SELECTED = [
    "MAINT-269-switch_off_reads_absent_entry_test.lua",
]
FILTER_FROM = 'const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();'
FILTER_TO = ('const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua") && '
             'process.env.MUTATE_SELECTED.split(",").includes(f)).sort();')

MUTATIONS = [
 ("M01-switch-never-off", MGR,
  [("    return self.settings ~= nil and not self.settings.enabled\n",
    "    return false\n", 1)],
  "isSwitchedOff never answers true: every gate stays open while off (group F)"),
 ("M02-switch-inverted", MGR,
  [("    return self.settings ~= nil and not self.settings.enabled\n",
    "    return self.settings ~= nil and self.settings.enabled == true\n", 1)],
  "the gate reads the switch backwards: on reads as off (groups N and R)"),
 ("M03-no-gate-getMoisture", MGR,
  [("function CropStressManager:getMoisture(fieldId, x, z)\n    if self:isSwitchedOff() then return nil end   -- [MAINTENANCE row 269]\n",
    "function CropStressManager:getMoisture(fieldId, x, z)\n", 1)],
  "the moisture read answers while off (F getMoisture, F Soil's read)"),
 ("M04-no-gate-getStress", MGR,
  [("function CropStressManager:getStress(fieldId)\n    if self:isSwitchedOff() then return nil end   -- [MAINTENANCE row 269]\n",
    "function CropStressManager:getStress(fieldId)\n", 1)],
  "the stress read answers while off (F getStress)"),
 ("M05-no-gate-getYieldKeepFactor", MGR,
  [("function CropStressManager:getYieldKeepFactor(fieldId)\n    if self:isSwitchedOff() then return nil end   -- [MAINTENANCE row 269]\n",
    "function CropStressManager:getYieldKeepFactor(fieldId)\n", 1)],
  "the keep factor answers while off (F getYieldKeepFactor)"),
 ("M06-no-gate-getRainOutlook", MGR,
  [("function CropStressManager:getRainOutlook(daysAhead)\n    if self:isSwitchedOff() then return nil end   -- [MAINTENANCE row 269]\n",
    "function CropStressManager:getRainOutlook(daysAhead)\n", 1)],
  "the outlook answers while off, so Soil's drilling advisory speaks (F getRainOutlook)"),
 ("M07-no-gate-getTemperature", MGR,
  [("function CropStressManager:getTemperature()\n    if self:isSwitchedOff() then return nil end   -- [MAINTENANCE row 269]\n",
    "function CropStressManager:getTemperature()\n", 1)],
  "the temperature answers while off (F getTemperature)"),
 ("M08-no-gate-getEvaporativeDemand", MGR,
  [("function CropStressManager:getEvaporativeDemand()\n    if self:isSwitchedOff() then return nil end   -- [MAINTENANCE row 269]\n",
    "function CropStressManager:getEvaporativeDemand()\n", 1)],
  "the evaporative demand answers while off (F getEvaporativeDemand)"),
 ("M09-harvest-cuts-while-off", MOD,
  [("            if g_cropStressManager.isSwitchedOff ~= nil and g_cropStressManager:isSwitchedOff() then\n",
    "            if false then\n", 1)],
  "the harvest hook cuts from frozen stress while off (F cut yields in full)"),
 ("M10-pda-reading-while-off", PDA,
  [("        if not off and entry.aggregateState ~= \"UNAVAILABLE\" and type(entry.moisture) == \"number\" then\n",
    "        if entry.aggregateState ~= \"UNAVAILABLE\" and type(entry.moisture) == \"number\" then\n", 1)],
  "the PDA glance counts the frozen moisture while off (F PDA glance)"),
 ("M11-pda-stress-while-off", PDA,
  [("        local s = (not off and stressMod and stressMod.fieldStress and stressMod.fieldStress[fid]) or 0\n",
    "        local s = (stressMod and stressMod.fieldStress and stressMod.fieldStress[fid]) or 0\n", 1)],
  "the PDA glance counts the frozen stress while off (F PDA glance)"),
 ("M12-hud-reading-while-off", HUD,
  [("    if self.manager.isSwitchedOff ~= nil and self.manager:isSwitchedOff() then\n        local blank = {}\n",
    "    if false then\n        local blank = {}\n", 1)],
  "the HUD list shows the frozen moisture while off (F HUD list)"),
 ("M13-hud-stress-unguarded", HUD,
  [("            stress = self.manager:getStress(entry.fieldId) or 0   -- nil while switched off (row 269)\n",
    "            stress = self.manager:getStress(entry.fieldId)\n", 1)],
  "the HUD row takes getStress's nil while off (F HUD list)"),
 ("M14-console-unguarded", MGR,
  [("                f.fieldId, f.moisture * 100, stress ~= nil and string.format(\"%.2f\", stress) or \"n/a (switched off)\"))\n",
    "                f.fieldId, f.moisture * 100, string.format(\"%.2f\", stress)))\n", 1)],
  "csStatus formats getStress's nil while off (F csStatus)"),
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
