# SeasonalCropStress SCS-042 mutation battery: the one-hop runoff module
# (src/RunoffSystem.lua), its construction and teardown in
# src/CropStressManager.lua, and the parcel-cell enumeration of the coverage act
# in src/IrrigationManager.lua (SCS-023 COVER, brief section 6). Rows live in
# scs042_runoff_system_test.lua; the certified bar SCS-042-runoff_spec_test.lua
# models the contract and its Group A pins the shipped surfaces.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the windowCount guard alone (positiveInteger to finiteInteger): a zero or negative
#     window count gives a candidateTotal of zero or less, refused at the next line as
#     INVALID_SPAN before anything is read, so the two guards mask each other (equivalent);
#   - main.lua's source() line for RunoffSystem.lua: this repo has no load-path
#     gate (StockGuard's is fixture-based and does not run here); the bench loads
#     modules from each file's --!load list. The pre-commit syntax gate parses
#     main.lua; the order is read by eye in the PR body.
#   - the diagnostic stats counters beyond offers/routed/refused: nothing reads
#     them yet (csStatus does not), so their exact shape is not a contract.
#   - the topology grain relabelled as the provider grain: the route carries
#     topologyGrainMetres and the request carries providerGrainMetres as separate
#     arguments; V2 pins the former and the certified bar's F5 the pair.
#   - the scheduled and immediate pivot/drip writes now enumerate through the same
#     _parcelCells as the coverage act; their filters are unchanged and covered by
#     the SCS-023 rows already in the suite.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_scs042.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

RS = "src/RunoffSystem.lua"
CM = "src/CropStressManager.lua"
IM = "src/IrrigationManager.lua"

MUTATIONS = [
 # ── the entry ──────────────────────────────────────────────────────────────
 ("R1-client-offers", RS,
  [("    if g_server == nil then return 0 end\n    if not finiteNumber(fieldId)", "    if not finiteNumber(fieldId)", 1)],
  "a pure client routes water"),
 ("R2-source-position-not-forwarded", RS,
  [("        providerGrainMetres, firstWindowId, windowCount, candidateGainPerWindow, sourceWorldX, sourceWorldZ)",
    "        providerGrainMetres, firstWindowId, windowCount, candidateGainPerWindow, route.x, route.z)", 1)],
  "the destination stands in for the source: the fence sees the destination's own field"),
 ("R3-over-acceptance-kept", RS,
  [("    if not ok or not finiteNumber(accepted) or accepted < 0 or accepted > candidateTotal then",
    "    if not ok or not finiteNumber(accepted) or accepted < 0 then", 1)],
  "a destination answering more than the candidate total is believed"),
 ("R4-negative-answer-kept", RS,
  [("    if not ok or not finiteNumber(accepted) or accepted < 0 or accepted > candidateTotal then",
    "    if not ok or not finiteNumber(accepted) or accepted > candidateTotal then", 1)],
  "a negative destination answer is returned as accepted runoff"),
 ("R5-thrown-destination-uncaught", RS,
  [("    local ok, accepted = pcall(soil._acceptRunoffDestinationSpan, soil, fieldId, route.x, route.z,\n        providerGrainMetres, firstWindowId, windowCount, candidateGainPerWindow, sourceWorldX, sourceWorldZ)",
    "    local ok, accepted = true, soil._acceptRunoffDestinationSpan(soil, fieldId, route.x, route.z,\n        providerGrainMetres, firstWindowId, windowCount, candidateGainPerWindow, sourceWorldX, sourceWorldZ)", 1)],
  "a thrown destination helper escapes the entry uncounted"),

 # ── the route ──────────────────────────────────────────────────────────────
 ("T1-stale-source-routed", RS,
  [("    if source.stale ~= false then return nil, \"SOURCE_STALE\" end\n", "", 1)],
  "the shaped stale default is routed on as a real height"),
 ("T2-flat-source-routed", RS,
  [("    if source.slope == \"flat\" then return nil, \"SOURCE_FLAT\" end\n", "", 1)],
  "a measured flat source routes"),
 ("T3-sink-routed", RS,
  [("    if source.sink == true then return nil, \"SOURCE_SINK\" end\n", "", 1)],
  "a sink gives its water away"),
 ("T4-thrown-cardinal-tolerated", RS,
  [("        if not ok then return nil, \"CARDINAL_THREW\" end\n", "        if not ok then c = nil end\n", 1)],
  "one thrown cardinal read is skipped and the rest routes"),
 ("T5-higher-neighbour-accepted", RS,
  [("           and c.height < source.height then", "           and c.height ~= source.height then", 1)],
  "a higher neighbour is a destination"),
 ("T6-stale-neighbour-accepted", RS,
  [("        if type(c) == \"table\" and c.stale == false and finiteNumber(c.height)", "        if type(c) == \"table\" and finiteNumber(c.height)", 1)],
  "a stale height-zero neighbour is a pit"),
 ("T7-tie-goes-to-the-later-cardinal", RS,
  [("            if best == nil or c.height < best.height then", "            if best == nil or c.height <= best.height then", 1)],
  "an equal-height tie chooses the later cardinal"),
 ("T8-grid-not-validated", RS,
  [("    if not gridOk or not finiteNumber(cellSize) or cellSize <= 0\n       or not positiveInteger(axisX) or not positiveInteger(axisZ)\n       or not finiteNumber(terrainSize) or terrainSize <= 0 then\n        return nil, \"NO_GRID\"\n    end",
    "    if not gridOk then\n        return nil, \"NO_GRID\"\n    end\n    cellSize = cellSize or 12", 1)],
  "a grid that answers nothing usable is routed on at a made-up size"),

 # ── the wiring ─────────────────────────────────────────────────────────────
 ("W1-manager-builds-no-runoff", CM,
  [("    self.runoffSystem       = (RunoffSystem ~= nil) and RunoffSystem.new(self) or nil\n", "", 1)],
  "the manager never constructs the sibling: every candidate stays local"),
 ("W2-teardown-keeps-runoff", CM,
  [("    if self.runoffSystem ~= nil then\n        self.runoffSystem:delete()\n        self.runoffSystem = nil\n    end\n", "", 1)],
  "the local runoff object outlives the mission"),

 # ── the parcel cells ───────────────────────────────────────────────────────
 ("P1-shared-cells-counted-twice", IM,
  [("                if not seen[k] then\n                    seen[k] = true\n                    out[#out + 1] = entry\n                end",
    "                out[#out + 1] = entry", 1)],
  "a cell reached from two touching fields is two provider positions"),
 ("P2-cells-not-sorted", IM,
  [("    table.sort(out, function(a, b)\n        local ax, bx = a.cellX or a.wx, b.cellX or b.wx\n        if ax ~= bx then return ax < bx end\n        return (a.cellZ or a.wz) < (b.cellZ or b.wz)\n    end)\n", "", 1)],
  "the act's order is the engine's field order, not cellX then cellZ"),
 ("P3-first-field-only", IM,
  [("    for _, field in ipairs(self:_fieldsForId(fieldId)) do\n        local vx, vz, n = self:getFieldPolygonWorld(field)\n        if vx ~= nil then\n            for _, entry in ipairs(self:_cellsInPolygon(vx, vz, n, cellSize)) do\n                local kx, kz",
    "    for _, field in ipairs({ self:_fieldsForId(fieldId)[1] }) do\n        local vx, vz, n = self:getFieldPolygonWorld(field)\n        if vx ~= nil then\n            for _, entry in ipairs(self:_cellsInPolygon(vx, vz, n, cellSize)) do\n                local kx, kz", 1)],
  "the act waters only the first field of the parcel"),
]


def sha(b): return hashlib.sha256(b).hexdigest()


def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = r.stdout + r.stderr
    strip = lambda l: (re.sub(r"\x1b\[[0-9;]*m", "", l).strip()
                       .encode("ascii", "replace").decode("ascii"))
    fails = [strip(l) for l in out.splitlines() if "FAIL" in l and "assertions passed" not in l]
    crashes = [strip(l) for l in out.splitlines() if "Lua error while loading/running" in l]
    return r.returncode, fails, crashes


only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]:
        print("   " + l)
    sys.exit(2)
print("baseline green")

killed, crashkills, survived, badedit = [], [], [], []

for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only):
        continue
    path = p(rel)
    with open(path, "rb") as f:
        original = f.read()
    crlf = b"\r\n" in original
    enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")

    ok, mutated = True, original
    for old, new, want in edits:
        ob, nb = enc(old), enc(new)
        n = mutated.count(ob)
        if n != want:
            badedit.append((mid, "anchor matched %dx, expected %d" % (n, want)))
            print("  !! %s: ANCHOR MISMATCH (%d != %d), mutation NOT applied" % (mid, n, want))
            ok = False
            break
        mutated = mutated.replace(ob, nb, want)
    if not ok:
        continue

    with open(path, "wb") as f:
        f.write(mutated)
    with open(path, "rb") as f:
        landed = f.read()
    if landed == original or landed != mutated:
        with open(path, "wb") as f:
            f.write(original)
        badedit.append((mid, "edit did not land"))
        print("  !! %s: EDIT DID NOT LAND" % mid)
        continue

    try:
        rc, fails, crashes = run_suite()
    finally:
        with open(path, "wb") as f:
            f.write(original)
    with open(path, "rb") as f:
        if sha(f.read()) != sha(original):
            print("  !! %s: RESTORE FAILED, stopping" % mid)
            sys.exit(3)

    named = [l for l in fails if l.startswith("FAIL ")]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if crashes and not named:
            crashkills.append(mid)
            tag = "KILLED* "
    else:
        survived.append((mid, why))
        tag = "SURVIVED"
    print("  %s %s  [%s]" % (tag, mid, rel))
    print("        (%s)" % why)
    for l in named[:4]:
        print("        " + l[:170])
    for l in crashes[:2]:
        print("        CRASH " + l[:170])

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (len(killed), len(crashkills)))
print("survived %d" % len(survived))
print("bad edit %d" % len(badedit))
for mid, why in survived:
    print("--- SURVIVED %s: %s" % (mid, why))
for mid, msg in badedit:
    print("--- BAD EDIT %s: %s" % (mid, msg))
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(1 if (survived or badedit or crashkills) else 0)
