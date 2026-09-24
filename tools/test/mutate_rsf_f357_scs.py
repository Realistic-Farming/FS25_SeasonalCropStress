# RSF-F357 section 7, the SCS caller mutation battery: src/NPCIntegration.lua (the claim, the
# getter read, the capability gate, the retry, the identity view, the bounded alert queue, the
# retained legacy scalar), src/SaveLoadHandler.lua (the two save writers) and
# src/ui/CsRfPdaGuest.lua (the consultant reader). Rows live in RSF-F357-scs_caller_spec_test.lua,
# which drives the REAL NPCFavor host (tools/test/fixtures/npcfavor_host, see PIN.md).
#
# KILLED* means killed only by a Lua error: a weak kill, treated as a failure.
#
# NOT RUN, and why:
#   - the claim position's finite check (claimPosition): the host validates the position itself
#     and refuses a non-finite one (its own spec, K9), so a caller passing NaN is refused, not
#     harmful; the caller's check only chooses the origin over a bad player position. Declared
#     defence in depth, not run.
#   - the load-side applyLoadedState guard for a non-number: SaveLoadHandler only calls it with a
#     number above zero (its own guards at :470 and :649), so the caller's type test is
#     unreachable from production. Declared equivalent.
#
# Anchors are written with "\n"; in a CRLF file they are matched after normalising.
#
# RUN IT ALONE, through the test lock. A battery edits production files in place.
#
# Usage: py tools/test/mutate_rsf_f357_scs.py [id-prefix ...]
import hashlib, os, subprocess, sys

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def p(rel): return os.path.join(ROOT, rel)

INT = "src/NPCIntegration.lua"
SLH = "src/SaveLoadHandler.lua"
PDA = "src/ui/CsRfPdaGuest.lua"

MUTATIONS = [
 # ── the capability gate ─────────────────────────────────────────────────────
 ("M01-old-host-treated-as-paired", INT,
  [("""    if sys.savedNeighbourIdentityVersion ~= NPCIntegration.HOST_IDENTITY_VERSION
        or type(sys.claimCropStressConsultant) ~= "function"
        or type(sys.getCropStressConsultantId) ~= "function" then
""",
    """    if type(sys.claimCropStressConsultant) ~= "function"
        or type(sys.getCropStressConsultantId) ~= "function" then
""", 1)],
  "a host with the functions but another identity version is claimed against"),
 ("M02-legacy-insert-path-restored", INT,
  [("""    if sys.savedNeighbourIdentityVersion ~= NPCIntegration.HOST_IDENTITY_VERSION
        or type(sys.claimCropStressConsultant) ~= "function"
        or type(sys.getCropStressConsultantId) ~= "function" then
        return sys, NPCIntegration.AVAIL_OLD_HOST, "cs_consultant_host_old"
    end
""",
    """    if type(sys.claimCropStressConsultant) ~= "function" then
        -- the pre-F357 path: adopt a namesake or insert one directly
        local name = consultantDisplayName()
        for _, existing in ipairs(sys.activeNPCs or {}) do
            if existing.name == name then
                self.consultantNPCId, self.isRegistered = existing.id, true
                self.availability, self.reasonKey = NPCIntegration.AVAIL_READY, ""
                return sys, nil, nil
            end
        end
        local npc = sys:createNPCAtLocation({ x = 0, y = 0, z = 0 })
        if npc ~= nil then
            table.insert(sys.activeNPCs, npc)
            self.consultantNPCId, self.isRegistered = npc.id, true
            self.availability, self.reasonKey = NPCIntegration.AVAIL_READY, ""
        end
        return sys, nil, nil
    end
""", 1)],
  "an old host gets the pre-F357 name adoption and direct insert"),
 ("M03-name-adoption-restored", INT,
  [("""    local id, why
    if self:isServerSide(sys) then
        id, why = sys:claimCropStressConsultant(consultantDisplayName(), self:claimPosition(sys))
""",
    """    local id, why
    local name = consultantDisplayName()
    for _, existing in ipairs(sys.activeNPCs or {}) do
        if existing.name == name then id = existing.id end
    end
    if id == nil and self:isServerSide(sys) then
        id, why = sys:claimCropStressConsultant(name, self:claimPosition(sys))
""", 1)],
  "a namesake in the host's town is adopted as the consultant"),
 # ── the claim and the read ──────────────────────────────────────────────────
 ("M04-client-claims", INT,
  [("""    if self:isServerSide(sys) then
        id, why = sys:claimCropStressConsultant(consultantDisplayName(), self:claimPosition(sys))
    else
        id, why = sys:getCropStressConsultantId()
    end
""",
    """    id, why = sys:claimCropStressConsultant(consultantDisplayName(), self:claimPosition(sys))
""", 1)],
  "a pure client tries to claim (the host refuses it as server-only) and never reads the getter"),
 ("M05-no-retry-throttle", INT,
  [("""    if self.lastAttemptMs ~= nil and now >= self.lastAttemptMs
        and now - self.lastAttemptMs < NPCIntegration.RETRY_INTERVAL_MS then
        return
    end
""", "", 1)],
  "the host is claimed or read every frame"),
 ("M06-stale-registration-kept", INT,
  [("""    if self.isRegistered then
        -- The host still proves the same person, or the registration is stale.
        local id = sys:getCropStressConsultantId()
        if id == self.consultantNPCId then return end
        self:clearRegistration(NPCIntegration.AVAIL_WAITING, "cs_consultant_waiting")
    end
""",
    """    if self.isRegistered then return end
""", 1)],
  "a consultant the host no longer proves stays registered"),
 ("M07-conflict-read-as-waiting", INT,
  [("""    if why == "npc_person_identity_conflict" then
        self.availability = NPCIntegration.AVAIL_CONFLICT
        self.reasonKey    = "cs_consultant_conflict"
    else
""",
    """    if false then
""", 1)],
  "a duplicate-record conflict reads as an ordinary wait"),
 ("M08-display-name-unguarded", INT,
  [("""            if lower ~= NPCIntegration.NPC_NAME and not lower:find("^missing") and text ~= ("$l10n_" .. NPCIntegration.NPC_NAME) then
                return text
            end
""",
    """            return text
""", 1)],
  "a missing locale key becomes the consultant's display name"),
 # ── the identity view and the trust read ────────────────────────────────────
 ("M09-trust-zero-when-unproved", INT,
  [("""    if not self.isRegistered or self.consultantNPCId == nil then return nil end
    local npcSystem = getNPCSystem()
    if npcSystem == nil or type(npcSystem.getNPCById) ~= "function" then return nil end
""",
    """    if not self.isRegistered or self.consultantNPCId == nil then return 0 end
    local npcSystem = getNPCSystem()
    if npcSystem == nil or type(npcSystem.getNPCById) ~= "function" then return 0 end
""", 1)],
  "an unproved consultant reads a fake zero trust"),
 ("M10-view-ready-whenever-a-host-exists", INT,
  [("""    if self.isRegistered then
        view.personId = self.consultantNPCId
        view.trust = self:getRelationshipLevel()
    end
    return view
""",
    """    view.personId = self.consultantNPCId
    view.trust = self:getRelationshipLevel()
    view.availability = (getNPCSystem() ~= nil) and NPCIntegration.AVAIL_READY or NPCIntegration.AVAIL_ABSENT
    return view
""", 1)],
  "the view claims READY for any present host, proved or not"),
 ("M11-old-host-alerts-queued", INT,
  [("""    if self.availability == NPCIntegration.AVAIL_ABSENT or self.availability == NPCIntegration.AVAIL_OLD_HOST then
        return false
    end
""", "", 1)],
  "alerts on an old or absent host are queued forever instead of left to the standalone consultant"),
 ("M12-alert-queue-unbounded", INT,
  [("""        while #self.pendingAlerts > NPCIntegration.MAX_PENDING_ALERTS do
            table.remove(self.pendingAlerts, 1)
        end
""", "", 1)],
  "the pending alert queue grows without bound"),
 ("M13-replay-keeps-the-queue", INT,
  [("""    local queued = self.pendingAlerts
    self.pendingAlerts = {}
    for _, alertData in ipairs(queued) do
""",
    """    local queued = self.pendingAlerts
    for _, alertData in ipairs(queued) do
""", 1)],
  "replayed alerts stay queued and replay again"),
 # ── the retained legacy scalar ──────────────────────────────────────────────
 ("M14-legacy-floor-restored", INT,
  [("""        csLog(string.format("NPCIntegration: Alex Chen linked to the host's person #%s", tostring(id)))
        self:noticeLegacyTrust()
""",
    """        csLog(string.format("NPCIntegration: Alex Chen linked to the host's person #%s", tostring(id)))
        if self.legacyTrust ~= nil and type(sys.getNPCById) == "function" then
            local npc = sys:getNPCById(id)
            if npc ~= nil then npc.relationship = math.max(npc.relationship or 0, self.legacyTrust) end
        end
        self:noticeLegacyTrust()
""", 1)],
  "the legacy scalar is applied as a floor on the host's person"),
 ("M15-legacy-notice-repeats", INT,
  [("""    if self.legacyTrust == nil or self.legacyTrustNoticed then return end
    self.legacyTrustNoticed = true
""",
    """    if self.legacyTrust == nil then return end
""", 1)],
  "the farmer is told on every re-registration"),
 ("M16-xml-writes-the-live-trust", SLH,
  [("""    if npcInt ~= nil and type(npcInt.getRetainedLegacyTrust) == "function" then
        local legacy = npcInt:getRetainedLegacyTrust()
        if type(legacy) == "number" and legacy > 0 then
            setInt(root .. ".npc#relationship", legacy)
        end
    end
""",
    """    if npcInt ~= nil and type(npcInt.getRelationshipLevel) == "function" then
        local rel = npcInt:getRelationshipLevel()
        if type(rel) == "number" and rel > 0 then
            setInt(root .. ".npc#relationship", rel)
        end
    end
""", 1)],
  "the own XML writes the live host score as the scalar (a second trust authority)"),
 ("M17-ledger-writes-the-live-trust", SLH,
  [("""    if npcInt ~= nil and type(npcInt.getRetainedLegacyTrust) == "function" then
        local legacy = npcInt:getRetainedLegacyTrust()
        if type(legacy) == "number" and legacy > 0 then out.npcRelationship = legacy end
    end
""",
    """    if npcInt ~= nil and type(npcInt.getRelationshipLevel) == "function" then
        local rel = npcInt:getRelationshipLevel()
        if type(rel) == "number" and rel > 0 then out.npcRelationship = rel end
    end
""", 1)],
  "the ledger table writes the live host score as the scalar"),
 ("M18-legacy-not-retained-on-load", INT,
  [("""    if type(relationship) == "number" and relationship == relationship and relationship > 0 then
        self.legacyTrust = math.floor(relationship)
""",
    """    if false then
        self.legacyTrust = math.floor(relationship)
""", 1)],
  "the loaded scalar is dropped instead of retained"),
 # ── the PDA reader ──────────────────────────────────────────────────────────
 ("M19-pda-prints-a-fake-zero", PDA,
  [("""    if view.availability == "READY" and type(view.trust) == "number" then
        local text = string.format(tr(fmtKey, fmtFallback), view.trust)
""",
    """    if view.availability ~= "ABSENT" then
        local text = string.format(tr(fmtKey, fmtFallback), view.trust or 0)
""", 1)],
  "the PDA prints 0 / 100 for an unproved consultant"),
 ("M20-pda-prints-something-for-no-host", PDA,
  [("""    if view.availability == "ABSENT" or view.reasonKey == nil or view.reasonKey == "" then return nil end
""",
    """    if view.reasonKey == nil or view.reasonKey == "" then return nil end
""", 1)],
  "the PDA paints a consultant line with no host at all"),
 ("M21-pda-drops-the-legacy-note", PDA,
  [("""        if view.legacyTrustHeld then
            text = text .. " " .. tr("cs_consultant_legacy_trust_held_short", "(old trust kept aside)")
        end
""", "", 1)],
  "an old scalar kept aside is not said on the PDA"),
]

def sha(b): return hashlib.sha256(b).hexdigest()

def run_suite():
    r = subprocess.run(["node", "run-tests.mjs"], cwd=p("tools/test"),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    out = (r.stdout or "") + (r.stderr or "")
    fails = [l.strip() for l in out.splitlines() if "FAIL " in l and "##" not in l and l.strip().startswith("FAIL")]
    crashes = [l.strip() for l in out.splitlines() if "Lua error" in l or "attempt to" in l or "group crashed" in l]
    return r.returncode, fails, crashes

only = sys.argv[1:]
rc, fails, crashes = run_suite()
if rc != 0:
    print("BASELINE IS NOT GREEN; fix that before trusting any mutation result.")
    for l in fails[:10]: print("   " + l)
    for l in crashes[:5]: print("   " + l)
    sys.exit(2)
print("baseline green")

killed, survived, bad, weak = 0, 0, 0, 0
for mid, rel, edits, why in MUTATIONS:
    if only and not any(mid.startswith(o) for o in only): continue
    path = p(rel)
    original = open(path, "rb").read()
    before = sha(original)
    crlf = b"\r\n" in original
    text = original.decode("utf-8").replace("\r\n", "\n")
    ok = True
    for old, new, count in edits:
        if text.count(old) != count:
            print("  BAD EDIT %s: anchor found %d times, want %d" % (mid, text.count(old), count)); ok = False; break
        text = text.replace(old, new)
    if not ok: bad += 1; continue
    open(path, "wb").write((text.replace("\n", "\r\n") if crlf else text).encode("utf-8"))
    try:
        rc, fails, crashes = run_suite()
    finally:
        open(path, "wb").write(original)
        assert sha(open(path, "rb").read()) == before, "restore failed for " + rel
    if rc != 0:
        killed += 1
        # A group that crashed reports as a FAIL row of its own ("[group crashed]"); it is a
        # weak kill unless an ordinary assertion failed too.
        ordinary = [l for l in fails if "[group crashed]" not in l]
        star = "*" if len(ordinary) == 0 else " "
        if star == "*": weak += 1
        print("  KILLED%s  %s  [%s]" % (star, mid, rel))
        for l in fails[:4]: print("        " + l)
    else:
        survived += 1
        print("  SURVIVED %s  [%s]  (%s)" % (mid, rel, why))

print("\n==== MUTATION RESULT ====")
print("killed   %d (of which %d only by a Lua error, marked KILLED*)" % (killed, weak))
print("survived %d" % survived)
print("bad edit %d" % bad)
print("all files restored byte-identical (hash-checked per mutation)")
sys.exit(0 if survived == 0 and bad == 0 and weak == 0 else 1)
