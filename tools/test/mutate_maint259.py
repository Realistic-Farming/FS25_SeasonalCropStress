# MAINTENANCE row 259 mutation battery: SCS's settings owner broadcasts once on the server, for every origin
# (src/CropStressManager.lua: applyAuthoritativeSettingChange; src/events/CropStressSettingsSyncEvent.lua and
# src/settings/CropStressSettingsPanel.lua: their own broadcasts gone where the owner runs). Rows live in
# tools/test/lua/MAINT-259-owner_broadcast_entry_test.lua.
#
# TARGETED (Tyson, 2026-09-25 and 2026-09-26, R-25a): the lines this PR changes. This repo's runner has no
# selection, so each mutant runs the whole suite. Run ONE mutant per call, in the foreground, and check free
# memory first.
#
# The edit is proved to LAND (exact occurrence count) and the restore is proved by a hash. KILLED* means
# killed only by a Lua error: a weak kill, a failure.
#
# NOT RUN, and why:
#   - the owner's `g_server ~= nil` guard: every caller reaches the owner on the server only (the panel and
#     the event gate on g_server; SettingsHub calls a selfPersisted module's onChange on the server only), so
#     no reachable path runs the owner without a server;
#   - the broadcasts kept in the no-owner fallbacks: the owner is defined in CropStressManager itself, so
#     neither fallback is reachable in SCS;
#   - comments.
#
# Usage (from the repo root):
#        py tools/test/mutate_maint259.py <id>        one mutant (prefix match must be unique)
#        py tools/test/mutate_maint259.py --check     every anchor matches its count; runs nothing
#        py tools/test/mutate_maint259.py --baseline  the suite, unmutated
#        py tools/test/mutate_maint259.py --list
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

MGR = "src/CropStressManager.lua"
EVT = "src/events/CropStressSettingsSyncEvent.lua"
PANEL = "src/settings/CropStressSettingsPanel.lua"

OWNER = ("    if g_server ~= nil and CropStressSettingsSyncEvent ~= nil then\n"
         "        g_server:broadcastEvent(CropStressSettingsSyncEvent.newSingle(key, self.settings[key]), false)\n"
         "    end\n")
EVT_MARK = "        -- [MAINTENANCE row 259] The owner broadcast the change to every client, once.\n"
PANEL_OWNER = ('            if not self.manager:applyAuthoritativeSettingChange(id, value, "panel") then\n'
               "                return\n"
               "            end\n")

MUTATIONS = [
 ("M01-owner-silent", MGR, [(OWNER, "", 1)],
  "the owner broadcasts nothing, as before: a hub-path change reaches no client (H1, H2)"),
 ("M02-owner-raw-value", MGR,
  [("newSingle(key, self.settings[key]), false)", "newSingle(key, value), false)", 1)],
  "the owner broadcasts the value it was given, not the validated one (H1)"),
 ("M03-owner-to-itself", MGR,
  [("newSingle(key, self.settings[key]), false)", "newSingle(key, self.settings[key]), true)", 1)],
  "the owner's broadcast also goes to the host itself (H1)"),
 ("M04-event-broadcasts-again", EVT,
  [(EVT_MARK, EVT_MARK + "        g_server:broadcastEvent(CropStressSettingsSyncEvent.newSingle(key, value), false)\n", 1)],
  "the settings event broadcasts after the owner did: twice (V1)"),
 ("M05-panel-broadcasts-again", PANEL,
  [(PANEL_OWNER, PANEL_OWNER + "            g_server:broadcastEvent(CropStressSettingsSyncEvent.newSingle(id, value), false)\n", 1)],
  "the panel broadcasts after the owner did: twice (P1)"),
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
    r = subprocess.run(["node", "run-tests.mjs"], cwd=os.path.join(ROOT, "tools", "test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
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
    for f in shown[:4]: print("    " + f[:220])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
