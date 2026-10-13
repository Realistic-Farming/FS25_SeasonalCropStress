# SeasonalCropStress SCS-041 parcel-union raster battery: the union ops of
# src/maps/CropStressValueMap.lua and their parcel-domain callers in
# src/SoilMoistureSystem.lua (the native-map half of the owner-ratified
# field-boundary correction, Design return 2026-09-09 section 2). Rows live in
# scs041_parcel_union_raster_test.lua, with the older parcel rows in
# scs041_parcel_union_test.lua and the F245/F247 bars around them.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work.
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the one-grain margin on the union box: the harness places pixel centres at
#     .5 and the bars' polygons on integer edges, so no centre ever sits on the box
#     edge; the margin is for the engine's edge convention, which the bench cannot
#     model (it is what the in-game check reads);
#   - the mask width check (a work set built at another width is dropped): the
#     harness never changes the map's width after construction;
#   - a paint loop per polygon: a set is idempotent, so its pixel result equals the
#     union's; row R3 pins the single native set by count instead, which is the
#     "once per covered cell" wording of the return, and that row is the kill;
#   - a delta of zero raw steps: the caller quantises through quantiseDelta first,
#     as the one-polygon op already requires;
#   - (MAINTENANCE row 90) the box binds no longer use setParallelogramWorldCoords:
#     each is clear plus four polygon points as the engine binds a box, which row K
#     pins by recording the calls (M1-M4 below); the parallelogram-replaces-points
#     question is gone rather than assumed;
#   - (MAINTENANCE row 90) the drainage fence on a partial collection now has its
#     own bar, group P, with terrain and through the registered daily settle; M5
#     below is its kill.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_scs041_union.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

VM = "src/maps/CropStressValueMap.lua"
SMS = "src/SoilMoistureSystem.lua"

MUTATIONS = [
 # ── the union ops ──────────────────────────────────────────────────────────
 ("U1-delta-looped-per-polygon", VM,
  [("    if not self:_bindUnion(polys) then return 0 end\n    local m, f = self.modifier, self.filter\n    local ok = pcall(function()\n        if rawDelta > 0 then",
    "    local total = 0\n    for pi = 1, #polys do total = self:applyDeltaToPolygon(polys[pi].vx, polys[pi].vz, polys[pi].n, delta) end\n    do return total end\n    if not self:_bindUnion(polys) then return 0 end\n    local m, f = self.modifier, self.filter\n    local ok = pcall(function()\n        if rawDelta > 0 then", 1)],
  "an additive delta is applied once per polygon, twice on an overlap"),
 ("U2-mean-of-polygon-means", VM,
  [("    if collectionBox(polys) == nil then return \"INVALID_FIELD_GEOMETRY\", nil, nil end\n    if not self.available then return \"PROVIDER_REFUSAL\", nil, nil end",
    "    do\n        local sum, n = 0, 0\n        for pi = 1, #polys do\n            local o, mean = self:readAverageOfPolygon(polys[pi].vx, polys[pi].vz, polys[pi].n)\n            if o == \"OK\" and mean ~= nil then sum = sum + mean; n = n + 1 end\n        end\n        if n > 0 then return \"OK\", sum / n, self:getGrainMetres() end\n    end\n    if collectionBox(polys) == nil then return \"INVALID_FIELD_GEOMETRY\", nil, nil end\n    if not self.available then return \"PROVIDER_REFUSAL\", nil, nil end", 1)],
  "the parcel mean averages polygon averages"),
 ("U3-mean-counts-unwritten-cells", VM,
  [("        f:setValueCompareParams(DensityValueCompareType.BETWEEN, RAW_MIN, RAW_MAX)\n        return m:executeGet(f, self.maskFilter)",
    "        return m:executeGet(self.maskFilter)", 1)],
  "an unwritten cell of the union counts as a zero sample"),
 ("U4-paint-set-per-polygon", VM,
  [("    local ok = pcall(function() self.modifier:executeSet(raw, self.maskFilter) end)\n    self:_releaseUnion()\n    return ok",
    "    local ok = pcall(function()\n        for pi = 1, #polys do\n            self:_setPolygonRegion(polys[pi].vx, polys[pi].vz, polys[pi].n)\n            self.modifier:executeSet(raw)\n        end\n    end)\n    self:_releaseUnion()\n    return ok", 1)],
  "paint writes once per polygon, twice on an overlap"),
 ("U5-union-not-released", VM,
  [("    self:_releaseUnion()\n    return ok\nend", "    return ok\nend", 1)],
  "the work set keeps the last parcel's cells after a paint"),
 ("U6-no-preclear-of-the-box", VM,
  [("        bindBox(mm, x0, z0, x1, z1)\n        mm:executeSet(0)\n        for pi = 1, #polys do",
    "        for pi = 1, #polys do", 1)],
  "a stale work-set cell joins the next parcel"),
 ("U7-single-polygon-takes-the-union-path", VM,
  [("    if #polys == 1 then\n        local p = polys[1]\n        return self:paintPolygon(p.vx, p.vz, p.n, value)\n    end\n", "", 1)],
  "a one-polygon parcel builds a work set and leaves the one-polygon op"),
 ("U8-mask-failure-falls-back-to-first-polygon", VM,
  [("    if not self:_ensureUnionMask() then return false, \"PROVIDER_REFUSAL\" end\n    -- One grain of margin",
    "    if not self:_ensureUnionMask() then\n        local p = polys[1]\n        return self:_setPolygonRegion(p.vx, p.vz, p.n), \"PROVIDER_REFUSAL\"\n    end\n    -- One grain of margin", 1)],
  "with no work set the parcel is its first field"),
 ("U9-malformed-member-tolerated", VM,
  [("        if type(p) ~= \"table\" or type(p.vx) ~= \"table\" or type(p.vz) ~= \"table\"\n           or type(p.n) ~= \"number\" or p.n < 3 then\n            return nil\n        end",
    "        if type(p) ~= \"table\" or type(p.vx) ~= \"table\" or type(p.vz) ~= \"table\"\n           or type(p.n) ~= \"number\" or p.n < 3 then\n            p = { vx = {}, vz = {}, n = 0 }\n        end", 1)],
  "a malformed polygon in the collection is skipped instead of refusing the parcel"),
 ("U10-thrown-add-keeps-the-add-path", VM,
  [("        csvmLog(\"Moisture map: executeAdd unavailable on the parcel union; disabling the add path\")\n        self.hasExecuteAdd = false\n        return 0",
    "        csvmLog(\"Moisture map: executeAdd unavailable on the parcel union; disabling the add path\")\n        return 0", 1)],
  "a thrown union add leaves the add path enabled"),
 ("U11-mask-filter-not-armed", VM,
  [("        self.maskFilter:setValueCompareParams(DensityValueCompareType.EQUAL, 1)\n", "        self.maskFilter:setValueCompareParams(DensityValueCompareType.BETWEEN, 0, 1)\n", 1)],
  "the box, gaps included, is the region"),
 ("U12-work-set-failure-not-latched", VM,
  [("    if self.maskFailedWidth == self.resolution then return false end\n", "", 1)],
  "a refused work set is asked for and logged on every union call"),

 # ── the partial fence (brief :28) ──────────────────────────────────────────
 ("F1-partial-fence-removed", SMS,
  [("    if entry ~= nil and entry.partial == true then return nil, \"PARTIAL\" end\n", "", 1)],
  "a partial collection is a parcel: seeded, shifted, published and committed"),
 ("F2-seed-unfenced", SMS,
  [("partial collection is not seeded (brief :28); the retry doors re-collect it.\n    local polys = self:_getCompleteFieldPolygons(fieldId)",
    "partial collection is not seeded (brief :28); the retry doors re-collect it.\n    local polys = self:_getFieldPolygons(fieldId)", 1)],
  "the seed paints a partial parcel's known fields"),
 ("F3-hourly-unfenced", SMS,
  [("                local polys = self:_getCompleteFieldPolygons(fieldId)\n                if polys == nil then\n                    data.mapPending = pending\n                else",
    "                local polys = self:_getFieldPolygons(fieldId)\n                if false then\n                else", 1)],
  "the hourly weather shifts a partial parcel and forgets the rest"),
 ("F4-refresh-unfenced", SMS,
  [("        local polys = self:_getCompleteFieldPolygons(fieldId)\n        if polys == nil then\n            outcome = \"INVALID_FIELD_GEOMETRY\"",
    "        local polys = self:_getFieldPolygons(fieldId)\n        if polys == nil then\n            outcome = \"INVALID_FIELD_GEOMETRY\"", 1)],
  "the publication refresh reads a partial parcel as the aggregate"),
 ("F5-replacement-unfenced", SMS,
  [("        local polys = self:_getCompleteFieldPolygons(fieldId)\n        local painted = false",
    "        local polys = self:_getFieldPolygons(fieldId)\n        local painted = false", 1)],
  "csSetMoisture commits a partial parcel as a completed operation"),
 ("F6-settle-unfenced", SMS,
  [("                local polys = self:_getCompleteFieldPolygons(fieldId)\n                if polys == nil then\n                    outcome = \"INVALID_FIELD_GEOMETRY\"",
    "                local polys = self:_getFieldPolygons(fieldId)\n                if polys == nil then\n                    outcome = \"INVALID_FIELD_GEOMETRY\"", 1)],
  "the daily settle re-derives a partial parcel as the aggregate"),

 # ── the parcel-domain callers ──────────────────────────────────────────────
 ("C1-hourly-delta-on-the-first-polygon", SMS,
  [("                    local moved = self.valueMap:applyDeltaToPolygons(polys, applied)",
    "                    local moved = self.valueMap:applyDeltaToPolygons({ polys[1] }, applied)", 1)],
  "the hourly weather reaches only the first field of a parcel"),
 ("C2-refresh-reads-the-first-polygon", SMS,
  [("            outcome, mean = self.valueMap:readAverageOfPolygons(polys)\n        end\n    end\n    if outcome == \"OK\" and mean ~= nil then\n        self:_markAggregateCurrent(d, mean)\n        d.aggregateDirty = false\n    elseif outcome == \"PROVIDER_REFUSAL\" then\n        if g_server ~= nil then",
    "            outcome, mean = self.valueMap:readAverageOfPolygons({ polys[1] })\n        end\n    end\n    if outcome == \"OK\" and mean ~= nil then\n        self:_markAggregateCurrent(d, mean)\n        d.aggregateDirty = false\n    elseif outcome == \"PROVIDER_REFUSAL\" then\n        if g_server ~= nil then", 1)],
  "the published scalar is the first field's mean"),
 ("C3-replacement-paints-the-first-polygon", SMS,
  [("            painted = self.valueMap:paintPolygons(polys, newValue) == true",
    "            painted = self.valueMap:paintPolygons({ polys[1] }, newValue) == true", 1)],
  "csSetMoisture and the sprayer repaint only the first field"),
 ("C4-seed-paints-the-first-polygon", SMS,
  [("    self.valueMap:paintPolygons(polys, base)\n", "    self.valueMap:paintPolygons({ polys[1] }, base)\n", 1)],
  "the seed leaves the parcel's other fields unwritten"),
 ("C5-settle-reads-the-first-polygon", SMS,
  [("                    outcome, mean = self.valueMap:readAverageOfPolygons(polys)\n                end\n            end\n            if outcome == \"OK\" and mean ~= nil then\n                self:_markAggregateCurrent(d, mean)\n                d.aggregateDirty = false\n            elseif outcome == \"PROVIDER_REFUSAL\" then\n                self:_markAggregateUnavailable(d, \"PROVIDER_REFUSAL\")",
    "                    outcome, mean = self.valueMap:readAverageOfPolygons({ polys[1] })\n                end\n            end\n            if outcome == \"OK\" and mean ~= nil then\n                self:_markAggregateCurrent(d, mean)\n                d.aggregateDirty = false\n            elseif outcome == \"PROVIDER_REFUSAL\" then\n                self:_markAggregateUnavailable(d, \"PROVIDER_REFUSAL\")", 1)],
  "the daily re-derive is the first field's mean"),
 ("C6-relief-per-polygon", SMS,
  [("            if pointInAnyPolygon(x, z, polys) then\n                local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, x, 0, z)",
    "            if csPointInPolygon(x, z, polys[1].vx, polys[1].vz, polys[1].n) then\n                local ok, h = pcall(getTerrainHeightAtWorldPos, g_terrainNode, x, 0, z)", 1)],
  "the relief seed samples only the first field"),
 ("C7-drainage-first-polygon-only", SMS,
  [("    for pi = 1, #polys do\n        local p = polys[pi]\n        local vx, vz, n = p.vx, p.vz, p.n\n        local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge",
    "    for pi = 1, 1 do\n        local p = polys[pi]\n        local vx, vz, n = p.vx, p.vz, p.n\n        local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge", 1)],
  "only the first field drains"),
 ("C8-drainage-samples-shared-blocks-twice", SMS,
  [("                if csPointInPolygon(x, z, vx, vz, n) and not pointInEarlierPolygon(x, z, polys, pi) then",
    "                if csPointInPolygon(x, z, vx, vz, n) then", 1)],
  "a block centre inside two fields is drained by both"),
 ("C9-drainage-crosses-between-fields", SMS,
  [("        if count >= 2 then\n            -- Pass 2: the drift.", "        if count >= 2 and pi == #polys then\n            -- Pass 2: the drift.", 1),
   ("        local bx, bz, bh, bm = {}, {}, {}, {}\n        local count = 0\n        local x = minX + half\n        while x <= maxX and total + count < limit do",
    "        local bx, bz, bh, bm = self._dbx or {}, self._dbz or {}, self._dbh or {}, self._dbm or {}\n        local count = self._dcount or 0\n        local x = minX + half\n        while x <= maxX and total + count < limit do", 1),
   ("        total = total + count\n", "        total = count\n        self._dbx, self._dbz, self._dbh, self._dbm, self._dcount = bx, bz, bh, bm, count\n", 1)],
  "one block set over the whole parcel: water levels between its fields"),
 # ── MAINTENANCE row 90 (targeted battery of that PR: run with the prefix M) ──
 ("M1-map-box-bound-as-parallelogram", VM,
  [("        bindBox(self.modifier, x0, z0, x1, z1)\n",
    "        self.modifier:clearPolygonPoints()\n        self.modifier:setParallelogramWorldCoords(x0, z0, x1, z0, x0, z1, DensityCoordType.POINT_POINT_POINT)\n", 1)],
  "the moisture modifier's union box is bound through setParallelogramWorldCoords again"),
 ("M2-mask-box-bound-as-parallelogram", VM,
  [("        bindBox(mm, x0, z0, x1, z1)\n        mm:executeSet(0)\n",
    "        mm:clearPolygonPoints()\n        mm:setParallelogramWorldCoords(x0, z0, x1, z0, x0, z1, DensityCoordType.POINT_POINT_POINT)\n        mm:executeSet(0)\n", 1)],
  "the work set's box is cleared through setParallelogramWorldCoords again"),
 ("M3-release-bound-as-parallelogram", VM,
  [("        bindBox(mm, box[1], box[2], box[3], box[4])\n",
    "        mm:clearPolygonPoints()\n        mm:setParallelogramWorldCoords(box[1], box[2], box[3], box[2], box[1], box[4], DensityCoordType.POINT_POINT_POINT)\n", 1)],
  "the release clears its box through setParallelogramWorldCoords again"),
 ("M4-box-fourth-corner-wrong", VM,
  [("    mod:addPolygonPointWorldCoords(x1, z1)\n", "    mod:addPolygonPointWorldCoords(x0, z1)\n", 1)],
  "the box's fourth corner is the height corner: a degenerate outline, not the box"),
 ("M5-drainage-unfenced", SMS,
  [("    -- overwrite the earlier field's within 8 m of the seam, exactly as one field's\n    -- squares already reach 8 m beyond its outline today.\n    local polys = self:_getCompleteFieldPolygons(fieldId)\n",
    "    -- overwrite the earlier field's within 8 m of the seam, exactly as one field's\n    -- squares already reach 8 m beyond its outline today.\n    local polys = self:_getFieldPolygons(fieldId)\n", 1)],
  "the daily drainage runs on a partial parcel: its known field settles while the missing one waits"),
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
