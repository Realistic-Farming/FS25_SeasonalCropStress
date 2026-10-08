# MAINTENANCE row 250 mutation battery: the Agronomy dial scales finite irrigation water draw
# (src/IrrigationManager.lua: resolveFiniteWaterDrawScale, the SCS-023 build brief's section 5 call). Rows
# live in tools/test/lua/MAINT-250-agronomy_draw_scale_spec_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes. Targeted runs only (Tyson,
# 2026-09-30): each mutant runs SELECTED, every bench whose load list or text names src/IrrigationManager.lua
# or main.lua (main.lua loads it). This repo's runner has no selection, so the script writes a filtered copy
# of run-tests.mjs beside it for the run and deletes it after. Run ONE mutant per call, in the foreground,
# and check free memory by hand right before each (1 GB or more).
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why: the resolver-absent guard (the bundled resolver is always sourced, main.lua:66); the
# base and neutral values (1.0 each, the brief's declaration; a neutral mutant is the E3-E5 rows' business
# only through resolve's own contract); comments.
#
# Usage (from the repo root):
#        py tools/test/mutate_maint250.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint250.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint250.py --baseline  the selected tests, unmutated
#        py tools/test/mutate_maint250.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

IRR = "src/IrrigationManager.lua"

# Every bench whose --!load list or text names src/IrrigationManager.lua or main.lua (at 99d25f4 plus this PR's).
SELECTED = [
    "MAINT-165-console_heat_entry_test.lua",
    "MAINT-247-hud_soil_handle_entry_test.lua",
    "MAINT-250-agronomy_draw_scale_spec_test.lua",
    "MAINT-257-hub_selfpersisted_entry_test.lua",
    "MAINT-259-owner_broadcast_entry_test.lua",
    "MAINT-91-relief_latch_spec_test.lua",
    "RSF-F247-retry_membership_anchor_spec_test.lua",
    "RSF-F357-scs_caller_spec_test.lua",
    "SCS-023-finite-irrigation-water_spec_test.lua",
    "SCS-038-priced_draw_spec_test.lua",
    "SCS-046-pivot-rain-key_spec_test.lua",
    "f154_usedplus_wear_retirement_test.lua",
    "scs023_effective_mode_test.lua",
    "scs023_farm_state_test.lua",
    "scs023_finance_plan_test.lua",
    "scs023_irrigate_now_chain_test.lua",
    "scs042_runoff_system_test.lua",
    "scs046_command_revision_test.lua",
    "scs046_f200_settlement_test.lua",
    "scs046_join_push_test.lua",
    "scs046_persistence_gate_test.lua",
    "scs160_schedule_day_index_test.lua",
    "scs191_events_run_from_readstream_test.lua",
]
FILTER_FROM = 'const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua")).sort();'
FILTER_TO = ('const testFiles = readdirSync(LUA_DIR).filter((f) => f.endsWith("_test.lua") && '
             'process.env.MUTATE_SELECTED.split(",").includes(f)).sort();')

MUTATIONS = [
 ("M01-unassigned-handle", IRR,
  [("    local settingsHub = g_currentMission ~= nil and g_currentMission.settingsHub or nil\n",
    "    local settingsHub = g_currentMission ~= nil and g_currentMission.optionScalingResolver or nil\n", 1)],
  "the profile is read from the field no mod assigns, as before: always neutral (E1, E2)"),
 ("M02-agro-key", IRR,
  [('        dial = "agronomy",\n', '        dial = "AGRO",\n', 1)],
  "the declaration names the old \"AGRO\" key, not the spine's agronomy dial (E1, E2)"),
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
