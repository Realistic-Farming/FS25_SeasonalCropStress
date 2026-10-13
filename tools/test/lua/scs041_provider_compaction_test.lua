-- scs041_provider_compaction_test.lua
-- SCS-041 §5: the provider-cell resolver and the SoilFertilizer compaction read,
-- driven on a real SoilMoistureSystem instance. The spec bar's Group A tracks
-- surface existence; this proves the shipped helpers resolve TRUTH/ZONE identity
-- and read compaction guarded, neutral-when-absent.
--!load: src/SoilMoistureSystem.lua

local function newSys()
  return SoilMoistureSystem.new({})
end

-- 1. ZONE fallback: no value map, so the provider is the 10-40 m cell.
do
  local s = newSys()
  s.valueMap = nil
  s.providerMode = "ZONE"
  s._cellSize = 10
  local cell = s:_resolveProviderCell(25, 35)
  T.eq("zone.mode", cell.mode, "ZONE")
  T.eq("zone.grain", cell.grain, 10)
  T.eq("zone.cellX", cell.cellX, 2)
  T.eq("zone.cellZ", cell.cellZ, 3)
  T.near("zone.centreX", cell.centerX, 25, 1e-9)   -- (2 + 0.5) * 10
  T.near("zone.centreZ", cell.centerZ, 35, 1e-9)   -- (3 + 0.5) * 10
  T.eq("zone.key", cell.cellKey, "ZONE:10:2:3")
  local again = s:_resolveProviderCell(25, 35)
  T.eq("zone.stableKey", again.cellKey, cell.cellKey)
end

-- 2. TRUTH: a native value map answers pixel, grain, coords and pixel centre.
do
  local s = newSys()
  local vm = {
    available = true,
    terrainSize = 2048,
    resolution = 1024,   -- 2 m/pixel
    worldToPixel = function(_self, _x, _z) return 100, 200 end,
    getGrainMetres = function(self) return self.terrainSize / self.resolution end,
    pixelCentreWorld = function(self, px, pz)
      local half = self.terrainSize * 0.5
      return (px + 0.5) / self.resolution * self.terrainSize - half,
             (pz + 0.5) / self.resolution * self.terrainSize - half
    end,
  }
  s.valueMap = vm
  s.providerMode = "TRUTH"
  local cell = s:_resolveProviderCell(-500, -400)
  T.eq("truth.mode", cell.mode, "TRUTH")
  T.near("truth.grain", cell.grain, 2, 1e-9)
  T.eq("truth.cellX", cell.cellX, 100)
  T.eq("truth.cellZ", cell.cellZ, 200)
  T.eq("truth.key", cell.cellKey, "TRUTH:2:100:200")
  T.near("truth.centreX", cell.centerX, (100 + 0.5) / 1024 * 2048 - 1024, 1e-9)
  T.near("truth.centreZ", cell.centerZ, (200 + 0.5) / 1024 * 2048 - 1024, 1e-9)

  -- an unresolved native pixel returns nil so the caller takes the neutral route
  vm.worldToPixel = function() return nil, nil end
  T.eq("truth.unresolvedPixelNil", s:_resolveProviderCell(9999, 9999), nil)
end

-- 3. a non-finite or missing world position refuses.
do
  local s = newSys(); s.valueMap = nil; s.providerMode = "ZONE"; s._cellSize = 10
  T.eq("resolve.infNil", s:_resolveProviderCell(math.huge, 0), nil)
  T.eq("resolve.nilArg", s:_resolveProviderCell(nil, 5), nil)
end

-- 4. compaction read: present manager + valid value returns value + grain,
--    and every missing/invalid path is neutral (nil).
do
  local s = newSys()
  local prev = g_currentMission

  g_currentMission = { soilFertilityManager = {
    getSoilValueAtWorld = function(_self, key)
      if key == "compaction" then return 50, 2 end
      return nil
    end } }
  local v, grain = s:_readCompactionAtWorld(10, 20)
  T.eq("comp.value", v, 50)
  T.eq("comp.grain", grain, 2)

  g_currentMission = {}
  T.eq("comp.noMgrNil", s:_readCompactionAtWorld(10, 20), nil)

  g_currentMission = { soilFertilityManager = {
    getSoilValueAtWorld = function() return 150, 2 end } }
  T.eq("comp.badRangeNil", s:_readCompactionAtWorld(10, 20), nil)

  g_currentMission = { soilFertilityManager = {
    getSoilValueAtWorld = function() return 40 end } }   -- one-value getter, no grain
  T.eq("comp.noGrainNil", s:_readCompactionAtWorld(10, 20), nil)

  g_currentMission = { soilFertilityManager = {
    getSoilValueAtWorld = function() error("boom") end } }
  T.eq("comp.throwNil", s:_readCompactionAtWorld(10, 20), nil)

  g_currentMission = prev
end
