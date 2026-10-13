# SeasonalCropStress MAINTENANCE row 91 battery: the relief latch (src/SoilMoistureSystem.lua,
# materialiseRelief, the pending hook in _collectAndCacheGeometry and door C's re-collect of a
# pending field). Rows live in MAINT-91-relief_latch_spec_test.lua; the scs018 relief bars run
# with it.
#
# SEPARATE FILE ON PURPOSE: each slice's battery belongs to its own work (the SCS-018 relief pass
# had none).
#
# Each mutation restores one piece of the defect or bends one clause and must be KILLED by a
# named row. For each: assert the edit LANDED (exact occurrence count), run the suite, record
# KILLED/SURVIVED with the named rows, restore byte-for-byte and PROVE the restore with a hash.
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the relief sampling below the latch (the threshold, the backstop cap, the offsets):
#     unchanged by this PR; scs018_relief_sparsity_test.lua is its bar.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_maint91_relief_latch.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

SMS = "src/SoilMoistureSystem.lua"

MUTATIONS = [
 ("L1-latch-before-the-collection", SMS,
  [("    local polys = self:_getCompleteFieldPolygons(fieldId)\n    if polys == nil then\n        self._reliefPending = self._reliefPending or {}\n",
    "    d.reliefScan = true\n    local polys = self:_getCompleteFieldPolygons(fieldId)\n    if polys == nil then\n        self._reliefPending = self._reliefPending or {}\n", 1)],
  "the pass latches before it collects: a failed first walk latches relief off for the mission (the defect)"),
 ("L2-partial-collection-accepted", SMS,
  [("    local polys = self:_getCompleteFieldPolygons(fieldId)\n    if polys == nil then\n        self._reliefPending = self._reliefPending or {}\n",
    "    local polys = self:_getFieldPolygons(fieldId)\n    if polys == nil then\n        self._reliefPending = self._reliefPending or {}\n", 1)],
  "relief runs on a partial parcel: the known field is materialised while the missing one waits"),
 ("L3-pending-pass-never-rerun", SMS,
  [("    if self._reliefPending ~= nil and self._reliefPending[fieldId] then\n        self:materialiseRelief(fieldId)\n    end\n", "", 1)],
  "a pass asked for during a failed collection never runs when the collection completes"),
 ("L4-door-c-does-not-recollect", SMS,
  [("        if self._reliefPending ~= nil and self._reliefPending[fieldId] then\n            self:_getFieldPolygons(fieldId)\n        end\n", "", 1)],
  "the server's hourly retry drops the entry but nothing re-collects it in the zone store"),
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
