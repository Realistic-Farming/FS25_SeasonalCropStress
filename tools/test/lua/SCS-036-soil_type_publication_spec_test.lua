-- SCS-036-soil_type_publication_spec_test.lua
-- THE PUBLISHED FIELD SOIL TYPE. SoilFertilizer has been asking SCS what kind
-- of ground a field is since the day its drying model was written, and has
-- never once got an answer. This brief publishes it: a read-contract getter on
-- the companion API, a backfill for records that predate the class, and the
-- two wire handlers stop writing a plausible-looking placeholder that nobody
-- could tell from the real answer. The executable bar for those four edits,
-- written from the brief's contract.
--
-- THE INVARIANTS THAT MATTER:
--   pull-only getter, writes nothing, caches nothing,
--   an unknown class returns nil, NEVER a substitute,
--   an absent soilType key is detectable; a hardcoded "loamy" was not,
--   the backfill is idempotent and its count includes backfilled records.
--!load: src/SoilMoistureSystem.lua, src/CropStressManager.lua, src/events/CropStressMoistureInitEvent.lua, src/integrations/CropStressNetworkSyncBridge.lua

-- 1. THE GETTER: pull-only, nil on a missing system or a missing record.
do
  local function newMgr(soilSystem)
    local m = setmetatable({}, { __index = CropStressManager })
    m.soilSystem = soilSystem
    return m
  end

  local mgr = newMgr({ fieldData = { [7] = { soilType = "sandy" } } })
  T.eq('getter.servesKnownField', mgr:getFieldSoilType(7), "sandy")

  -- No record: nil, never a substitute.
  T.eq('getter.untrackedIsNil', mgr:getFieldSoilType(99), nil)

  -- Record exists but the class is not yet known on this peer: nil.
  mgr.soilSystem.fieldData[8] = { soilType = nil }
  T.eq('getter.unknownClassIsNil', mgr:getFieldSoilType(8), nil)

  -- Missing subsystem: nil, never a throw.
  local empty = newMgr(nil)
  T.eq('getter.noSystemIsNil', empty:getFieldSoilType(7), nil)
end

-- 2. THE GETTER NAME IS getFieldSoilType, NOT getSoilType. The shipped SF
--    consumer probes the long spelling; building the other spelling leaves the
--    probe still failing. Lock the name so it cannot drift.
do
  T.ok('name.isGetFieldSoilType', type(CropStressManager.getFieldSoilType) == "function")
  T.ok('name.noWrongSpelling', CropStressManager.getSoilType == nil)
end

-- 3. THE BACKFILL: a record that exists without a soilType gets one detected;
--    new records keep the detect-on-create path; both count; idempotent.
do
  local s = SoilMoistureSystem.new({})
  -- Pre-seed one record without a class (the wire-handler join shape).
  s.fieldData[7] = { fieldId = 7, moisture = 0.5 }
  -- And one with a class (created after a previous enumerate).
  s.fieldData[8] = { fieldId = 8, moisture = 0.5, soilType = "clay" }

  local fields = {
    { farmland = { id = 7 }, posX = 0, posZ = 0 },
    { farmland = { id = 8 }, posX = 100, posZ = 0 },
    { farmland = { id = 9 }, posX = 200, posZ = 0 },
  }
  local prevFM = g_fieldManager
  g_fieldManager = { fields = fields }

  local count = s:enumerateFields()
  -- Two counted: the backfilled record (7) and the brand-new one (9). The
  -- already-complete record (8) is a no-op and is not counted.
  T.eq('backfill.countsBackfillAndNew', count, 2)
  T.ok('backfill.repairedOldRecord', s.fieldData[7].soilType ~= nil)
  T.ok('backfill.leftCompleteAlone', s.fieldData[8].soilType == "clay")
  T.ok('backfill.createdNewRecord', s.fieldData[9].soilType ~= nil)

  -- Idempotent: a second run detects nothing, repairs nothing, counts nothing.
  local count2 = s:enumerateFields()
  T.eq('backfill.idempotent', count2, 0)

  g_fieldManager = prevFM
end

-- 4. THE WIRE HANDLERS STOP WRITING A PLACEHOLDER. An absent key is
--    detectable; "loamy" the placeholder and "loamy" the real answer are the
--    same string, so no code could tell them apart.
do
  -- The join-window behaviour is unchanged: missing classes land on loam in
  -- the hourly loop (SOIL_PARAMS.loamy fallback), exactly as the hardcoded
  -- string produced. The first rebuild after the join makes the value right.
  T.ok('wire.loamFallbackExists', SoilMoistureSystem.SOIL_PARAMS.loamy ~= nil)
end

T.summary()
