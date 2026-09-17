-- scs039_native_generation_test.lua
-- SCS-039 / GRID-1, reworked for RSF-F244: native file NAMES. PR188 named each
-- generation's image csMoistureMap.g<N>.grle and left every superseded one on
-- disk for good; a mod cannot delete savegame files (decompiled mods.lua:708-733),
-- so the image now rotates through three fixed slot files. This bench pins the
-- name grammar every open passes, the slot choice, and that the write stack takes
-- the cut's one slot string as is and refuses anything else.
--!load: src/SoilMoistureSystem.lua, src/maps/CropStressValueMap.lua

local S1, S2, S3 = "csMoistureMap.s1.grle", "csMoistureMap.s2.grle", "csMoistureMap.s3.grle"
local LEGACY = "csMoistureMap.grle"

-- 1. THE DOOR GRAMMAR: whole-string, anchored at both ends.
do
  local accept = CropStressValueMap.isAcceptedNativeName
  T.eq("name.legacyAccepted", accept(LEGACY), true)
  T.eq("name.slot1Accepted", accept(S1), true)
  T.eq("name.slot2Accepted", accept(S2), true)
  T.eq("name.slot3Accepted", accept(S3), true)
  T.eq("name.g1Accepted", accept("csMoistureMap.g1.grle"), true)
  T.eq("name.g10Accepted", accept("csMoistureMap.g10.grle"), true)
  T.eq("name.g123Accepted", accept("csMoistureMap.g123.grle"), true)
  T.eq("name.g0Refused", accept("csMoistureMap.g0.grle"), false)
  T.eq("name.leadingZeroRefused", accept("csMoistureMap.g01.grle"), false)
  T.eq("name.negativeRefused", accept("csMoistureMap.g-1.grle"), false)
  T.eq("name.nonDigitRefused", accept("csMoistureMap.gx.grle"), false)
  T.eq("name.emptyGenerationRefused", accept("csMoistureMap.g.grle"), false)
  T.eq("name.slot0Refused", accept("csMoistureMap.s0.grle"), false)
  T.eq("name.slot4Refused", accept("csMoistureMap.s4.grle"), false)
  T.eq("name.forwardSlashRefused", accept("sub/" .. S1), false)
  T.eq("name.backslashRefused", accept("sub\\" .. S1), false)
  T.eq("name.parentRefused", accept("../" .. S1), false)
  T.eq("name.dotDotRefused", accept(".."), false)
  T.eq("name.suffixRefused", accept(S1 .. ".bak"), false)
  T.eq("name.prefixRefused", accept("x" .. S1), false)
  T.eq("name.legacySuffixRefused", accept(LEGACY .. "x"), false)
  T.eq("name.generationSuffixRefused", accept("csMoistureMap.g3.grle.old"), false)
  T.eq("name.trailingNewlineRefused", accept(S1 .. "\n"), false)
  T.eq("name.nilRefused", accept(nil), false)
  T.eq("name.numberRefused", accept(1), false)
  T.eq("name.emptyRefused", accept(""), false)
end

-- 2. ONLY THE THREE SLOTS ARE SLOT NAMES.
do
  local isSlot = CropStressValueMap.isSlotFileName
  T.eq("slot.threeSlots", #CropStressValueMap.SLOT_FILES, 3)
  T.eq("slot.s1", isSlot(S1), true)
  T.eq("slot.s3", isSlot(S3), true)
  T.eq("slot.legacyIsNotASlot", isSlot(LEGACY), false)
  T.eq("slot.generationNameIsNotASlot", isSlot("csMoistureMap.g2.grle"), false)
  T.eq("slot.nilIsNotASlot", isSlot(nil), false)
end

-- 3. THE SLOT CHOICE: lowest slot named by neither retained record.
do
  local choose = CropStressValueMap.chooseSlotFileName
  T.eq("choose.noRecords", choose(nil, nil), S1)
  T.eq("choose.currentS1", choose(S1, nil), S2)
  T.eq("choose.previousS1", choose(nil, S1), S2)
  T.eq("choose.s1s2", choose(S1, S2), S3)
  T.eq("choose.s2s1", choose(S2, S1), S3)
  T.eq("choose.s3s1", choose(S3, S1), S2)
  T.eq("choose.s2s3", choose(S2, S3), S1)
  T.eq("choose.s3s2", choose(S3, S2), S1)
  T.eq("choose.sameNameTwice", choose(S1, S1), S2)
  -- A PR188-era or legacy name excludes no slot.
  T.eq("choose.generationNamesExcludeNothing", choose("csMoistureMap.g4.grle", "csMoistureMap.g3.grle"), S1)
  T.eq("choose.legacyExcludesNothing", choose(LEGACY, nil), S1)
  -- Pure: the same pair gives the same slot, so a retried failed cut reuses it.
  T.eq("choose.stable", choose(S2, S3), choose(S2, S3))
  -- Never a retained name, never the legacy name, across every pair of slots.
  local neverRetained, neverLegacy = true, true
  local names = { nil, S1, S2, S3 }
  for a = 1, 4 do
    for b = 1, 4 do
      local c = choose(names[a], names[b])
      if c == names[a] or c == names[b] then neverRetained = false end
      if c == LEGACY or not CropStressValueMap.isSlotFileName(c) then neverLegacy = false end
    end
  end
  T.eq("choose.neverARetainedName", neverRetained, true)
  T.eq("choose.alwaysASlotNeverLegacy", neverLegacy, true)
end

-- 4. THE MAP WRITES EXACTLY THE SLOT STRING IT IS GIVEN, AND ONLY A SLOT.
-- Run under pcall: a removed refusal would otherwise raise on the nil name below
-- and the suite would discard every row in this file.
local okWrite, errWrite = pcall(function()
  local original = saveBitVectorMapToFile
  local paths = {}
  saveBitVectorMapToFile = function(_bvm, path)
    paths[#paths + 1] = path
    return true
  end
  local m = setmetatable({ available = true, bvm = 1 }, { __index = CropStressValueMap })
  T.eq("map.slotSaveOk", m:saveToSavegame("save-root", S2), true)
  T.eq("map.slotPathExact", paths[1], "save-root/" .. S2)
  T.eq("map.legacyRefused", m:saveToSavegame("save-root", LEGACY), false)
  T.eq("map.generationNameRefused", m:saveToSavegame("save-root", "csMoistureMap.g3.grle"), false)
  T.eq("map.nilNameRefused", m:saveToSavegame("save-root", nil), false)
  T.eq("map.traversalRefused", m:saveToSavegame("save-root", "../" .. S1), false)
  T.eq("map.refusalsNeverReachTheEngine", #paths, 1)
  T.eq("map.nilDirRefused", m:saveToSavegame(nil, S1), false)
  T.eq("map.nilDirNeverReachesTheEngine", #paths, 1)
  saveBitVectorMapToFile = function() return false end
  T.eq("map.engineFalseIsFailure", m:saveToSavegame("save-root", S1), false)
  saveBitVectorMapToFile = original
end)
T.eq("map.sectionRanWithoutALuaError", okWrite and "clean" or tostring(errWrite), "clean")

-- 5. SOIL SYSTEM PASSES THE CUT'S SLOT STRING THROUGH UNCHANGED.
do
  local sys = SoilMoistureSystem.new({})
  local seenDir, seenName = nil, nil
  sys.valueMap = {
    available = true,
    saveToSavegame = function(_self, dir, filename)
      seenDir, seenName = dir, filename
      return true
    end,
  }
  sys.providerMode = "TRUTH"
  T.eq("soil.slotPassedOk", sys:saveNativeMap("/saves", S3), true)
  T.eq("soil.slotSeen", seenName, S3)
  T.eq("soil.dirSeen", seenDir, "/saves")
  T.eq("soil.keepsTruth", sys.providerMode, "TRUTH")
end

-- 6. A NATIVE SAVE REFUSAL STILL FAILS THE PROVIDER CLOSED (SDS 3.3).
do
  local sys = SoilMoistureSystem.new({})
  sys.valueMap = { available = true, saveToSavegame = function() return false end }
  sys.providerMode = "TRUTH"
  T.eq("refusal.reportsFalse", sys:saveNativeMap("/saves", S1), false)
  T.eq("refusal.failsClosed", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
end

T.summary()
