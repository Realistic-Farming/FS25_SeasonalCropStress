# MAINTENANCE row 165 battery (targeted, R-25): consoleSimulateHeat returns nothing
# (src/CropStressManager.lua). The entry-point bar is MAINT-165-console_heat_entry_test.lua.
#
# One mutant per changed line of the handler. A mutant counts as KILLED only when the suite
# ran to its summary, failed, and every assertion the mutant targets in the MAINT-165 bar is
# among the FAIL lines. Anything else is SURVIVED.
#
# Each run asserts the edit LANDED (exact occurrence count), restores byte-for-byte and PROVES
# the restore with a hash.
#
# Anchors are written with "\n"; in a CRLF file they are matched as "\r\n".
#
# RUN IT ALONE. A battery edits a production file in place.
#
# Usage: py tools/test/mutate_maint165_console_heat.py
import hashlib, os, re, subprocess, sys

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TEST_DIR = os.path.join(ROOT, "tools", "test")
TARGET = os.path.join(ROOT, "src", "CropStressManager.lua")
BAR = "MAINT-165-console_heat_entry_test.lua"

HANDLER = ('function CropStressManager:consoleSimulateHeat(daysStr)\n'
           '    local _, text = self:requestHeatWave(daysStr, "console")\n'
           '    print(text)\n'
           'end\n')

# (id, new handler, assertion ids in the bar that must fail)
MUTANTS = [
    ("M1-status-word-returned",
     'function CropStressManager:consoleSimulateHeat(daysStr)\n'
     '    local status, text = self:requestHeatWave(daysStr, "console")\n'
     '    print(text)\n'
     '    return status\n'
     'end\n', ["H1", "H2", "C1", "C2", "R1", "R2"]),
    ("M2-text-returned",
     'function CropStressManager:consoleSimulateHeat(daysStr)\n'
     '    local _, text = self:requestHeatWave(daysStr, "console")\n'
     '    print(text)\n'
     '    return text\n'
     'end\n', ["H1", "H2", "C1", "C2", "R1", "R2"]),
    ("M3-status-word-printed",
     'function CropStressManager:consoleSimulateHeat(daysStr)\n'
     '    local text = self:requestHeatWave(daysStr, "console")\n'
     '    print(text)\n'
     'end\n', ["H3", "C5", "R3"]),
    ("M4-explicit-nil-returned",
     'function CropStressManager:consoleSimulateHeat(daysStr)\n'
     '    local _, text = self:requestHeatWave(daysStr, "console")\n'
     '    print(text)\n'
     '    return nil\n'
     'end\n', ["H1", "H2", "C1", "C2", "R1", "R2"]),
]

def sha(b): return hashlib.sha256(b).hexdigest()
def run():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=TEST_DIR,
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = re.sub(r"\x1b\[[0-9;]*m", "", r.stdout + r.stderr)
    lines = out.splitlines()
    summary = any(re.match(r"^(PASS|FAIL) - \d+ assertions? passed", l) for l in lines)
    bar_fails, in_bar = [], False
    for l in lines:
        if re.match(r"^[✓✗] ", l):
            in_bar = BAR in l
        elif in_bar and l.strip().startswith("FAIL "):
            m = re.match(r"\s*FAIL ([A-Z]\d+) ", l)
            if m:
                bar_fails.append(m.group(1))
    crashed = any(BAR in l and "Lua error" in l for l in lines)
    return r.returncode, summary, bar_fails, crashed

rc, summary, bar_fails, crashed = run()
if rc != 0 or not summary or bar_fails or crashed:
    print("BASELINE IS NOT GREEN; fix that before trusting the battery.")
    sys.exit(2)
print("baseline green")

original = open(TARGET, "rb").read()
crlf = b"\r\n" in original
enc = lambda s: (s.replace("\n", "\r\n") if crlf else s).encode("utf-8")
killed = survived = bad = 0
for mid, new, want in MUTANTS:
    n = original.count(enc(HANDLER))
    if n != 1:
        bad += 1
        print("  !! %s: ANCHOR MISMATCH (%d != 1), mutation NOT applied" % (mid, n))
        continue
    line = original[:original.index(enc(HANDLER))].count(b"\n") + 1
    mutated = original.replace(enc(HANDLER), enc(new), 1)
    open(TARGET, "wb").write(mutated)
    try:
        assert open(TARGET, "rb").read() == mutated and mutated != original, "edit did not land"
        rc, summary, bar_fails, crashed = run()
    finally:
        open(TARGET, "wb").write(original)
    if sha(open(TARGET, "rb").read()) != sha(original):
        print("  !! RESTORE FAILED after %s" % mid)
        sys.exit(3)
    ok = rc != 0 and summary and not crashed and all(w in bar_fails for w in want)
    killed += 1 if ok else 0
    survived += 0 if ok else 1
    print("  %s %s  [CropStressManager.lua:%d]  target %s, bar failed %s%s" % (
        "KILLED  " if ok else "SURVIVED", mid, line, "+".join(want), ",".join(bar_fails) or "nothing",
        " (bar crashed)" if crashed else ""))

print("\n==== MUTATION RESULT ====")
print("killed   %d (each on an assertion in its target rows)" % killed)
print("survived %d" % survived)
print("bad edit %d" % bad)
print("all files restored byte-identical (hash-checked)")
sys.exit(0 if survived == 0 and bad == 0 else 1)
