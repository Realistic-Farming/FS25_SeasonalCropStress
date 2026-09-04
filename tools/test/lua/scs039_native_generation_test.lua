-- scs039_native_generation_test.lua
-- SCS-039 / GRID-1 (SDS 3.5): generation-qualified native file naming and the
-- plumbing that writes the CANDIDATE COMPLETE generation to its own file so a
-- save never overwrites the legacy baseline or either retained complete pair.
--!load: src/SoilMoistureSystem.lua, src/maps/CropStressValueMap.lua

-- 1. GENERATION FILE NAMES: generation 0 (and nil) is the legacy baseline.
do
  T.eq("name.legacyZero", CropStressValueMap.generationFileName(0), "csMoistureMap.grle")
  T.eq("name.legacyNil", CropStressValueMap.generationFileName(nil), "csMoistureMap.grle")
  T.eq("name.generationOne", CropStressValueMap.generationFileName(1), "csMoistureMap.g1.grle")
  T.eq("name.generationFive", CropStressValueMap.generationFileName(5), "csMoistureMap.g5.grle")
  T.eq("name.qualifiedNeverEqualsLegacy", CropStressValueMap.generationFileName(3) ~= CropStressValueMap.generationFileName(0), true)
end

-- 2. THE MAP WRITES TO THE QUALIFIED NAME WHEN GIVEN A GENERATION, else legacy.
do
  local original = saveBitVectorMapToFile
  local capturedPath = nil
  saveBitVectorMapToFile = function(_bvm, path)
    capturedPath = path
    return true
  end
  local m = setmetatable({ available = true, bvm = 1 }, { __index = CropStressValueMap })
  T.eq("map.qualifiedSaveOk", m:saveToSavegame("save-root", 3), true)
  T.eq("map.qualifiedPath", capturedPath, "save-root/csMoistureMap.g3.grle")
  T.eq("map.legacySaveOk", m:saveToSavegame("save-root"), true)
  T.eq("map.legacyPath", capturedPath, "save-root/csMoistureMap.grle")
  saveBitVectorMapToFile = original
end

-- 3. SOIL SYSTEM PASSES THE CANDIDATE GENERATION THROUGH TO THE NATIVE SAVE.
do
  local sys = SoilMoistureSystem.new({})
  local seenDir, seenGen = nil, nil
  sys.valueMap = {
    available = true,
    saveToSavegame = function(_self, dir, generation)
      seenDir, seenGen = dir, generation
      return true
    end,
  }
  sys.providerMode = "TRUTH"
  T.eq("soil.generationPassedOk", sys:saveNativeMap("/saves", 4), true)
  T.eq("soil.generationSeen", seenGen, 4)
  T.eq("soil.dirSeen", seenDir, "/saves")
  T.eq("soil.keepsTruth", sys.providerMode, "TRUTH")
end

-- 4. A QUALIFIED NATIVE SAVE REFUSAL STILL FAILS THE PROVIDER CLOSED (SDS 3.3).
do
  local sys = SoilMoistureSystem.new({})
  sys.valueMap = { available = true, saveToSavegame = function() return false end }
  sys.providerMode = "TRUTH"
  T.eq("refusal.reportsFalse", sys:saveNativeMap("/saves", 4), false)
  T.eq("refusal.failsClosed", sys.providerMode, "UNAVAILABLE_PENDING_RELOAD")
end

T.summary()
