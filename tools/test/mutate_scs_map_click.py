# SCS map-click page gate mutation battery (targeted, a small logic change): the
# isMapFrameCurrentPage guard in src/ui/CsMapHooks.lua and its check in isCsPageActive.
# Rows live in SCS-map_click_guard_current_page_spec_test.lua; every other bar runs with it.
#
# Each mutation removes or bends one clause and must be KILLED by a named row. For each:
# assert the edit LANDED (exact occurrence count), run the suite, record KILLED/SURVIVED
# with the named rows, restore byte-for-byte and PROVE the restore with a hash. "DID NOT
# APPLY" never counts as a kill. KILLED* means killed only by a Lua error (a crash, or a
# group that raised): a weak kill, treated as a failure.
#
# scs018_decay_catchup_test.lua reads ../FS25_TimeGuard/src beside the repo; run this where
# that sibling exists, or the baseline is not green.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_scs_map_click.py [id-prefix ...]
import hashlib, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MH = "src/ui/CsMapHooks.lua"

MUTATIONS = [
 ("C1-gate-removed", MH,
  [("    if not isMapFrameCurrentPage(frame) then\n        return false\n    end\n", "", 1)],
  "the remembered layer alone decides again: clicks on other Esc pages open the PDA or change the density"),
 ("C2-no-gui-closed", MH,
  [("    if g_gui == nil or InGameMenu == nil then return true end\n", "    if g_gui == nil or InGameMenu == nil then return false end\n", 1)],
  "with no g_gui the map frame refuses every click instead of behaving as before"),
 ("C3-no-current-page-closed", MH,
  [("    if inGameMenu == nil or inGameMenu.currentPage == nil then return true end\n", "    if inGameMenu == nil or inGameMenu.currentPage == nil then return false end\n", 1)],
  "an undeterminable menu refuses the click instead of staying permissive"),
 ("C4-no-ingamemenu-fallback", MH,
  [("g_gui.screenControllers[InGameMenu] or g_inGameMenu\n", "g_gui.screenControllers[InGameMenu]\n", 1)],
  "without a screen controller the guard never reads g_inGameMenu"),
 ("C5-comparison-inverted", MH,
  [("    return inGameMenu.currentPage == frame\n", "    return inGameMenu.currentPage ~= frame\n", 1)],
  "the displayed map frame declines and every other page takes the click"),
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
    # A group that raised is a Lua error, not a named row: a kill by it alone is weak.
    rows = [l for l in named if "[group raised:" not in l]
    if rc != 0:
        killed.append(mid)
        tag = "KILLED  "
        if not rows:
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
