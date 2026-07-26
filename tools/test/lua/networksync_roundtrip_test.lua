-- networksync_roundtrip_test.lua - NetworkSync moisture/stress serializer round-trip.
-- Proves serializeFields() <-> deserializeFields() is lossless for the per-field
-- moisture/stress payload SCS batches over NetworkSync, so a client rebuilds exactly
-- what the server flattened. This is the A2-substitute coverage for the bridge's wire
-- format (write order == read order, no count drift, clamped on read).
--!load: src/integrations/CropStressNetworkSyncBridge.lua

local B = CropStressNetworkSyncBridge

-- Full round-trip across several fields, moisture + stress both carried.
do
  local fieldData = {
    [1] = { moisture = 0.42, soilType = "clay" },   -- soilType is NOT on the wire
    [7] = { moisture = 0.63 },
    [12] = { moisture = 0.00 },
  }
  local fieldStress = { [1] = 0.10, [7] = 0.55, [12] = 0.90 }

  local arr = B.serializeFields(fieldData, fieldStress)
  T.eq("wire: array starts with field count", arr[1], 3)

  local dstData, dstStress = B.deserializeFields(arr)

  T.ok("roundtrip: field 1 present", dstData[1] ~= nil)
  T.ok("roundtrip: field 7 present", dstData[7] ~= nil)
  T.ok("roundtrip: field 12 present", dstData[12] ~= nil)

  T.near("roundtrip: field 1 moisture", dstData[1].moisture, 0.42)
  T.near("roundtrip: field 7 moisture", dstData[7].moisture, 0.63)
  T.near("roundtrip: field 12 moisture", dstData[12].moisture, 0.00)

  T.near("roundtrip: field 1 stress", dstStress[1], 0.10)
  T.near("roundtrip: field 7 stress", dstStress[7], 0.55)
  T.near("roundtrip: field 12 stress", dstStress[12], 0.90)

  -- soilType is deliberately not synced (clients keep their own).
  T.ok("roundtrip: soilType not on the wire", dstData[1].soilType == nil)
end

-- Missing stress entry defaults to 0.0 (never nil on the wire).
do
  local dstData, dstStress = B.deserializeFields(B.serializeFields({ [5] = { moisture = 0.5 } }, {}))
  T.near("default: absent stress = 0", dstStress[5], 0.0)
  T.near("default: moisture carried", dstData[5].moisture, 0.5)
end

-- Clamping: out-of-range moisture/stress pulled back into 0..1 on read.
do
  local dstData, dstStress = B.deserializeFields(B.serializeFields(
    { [2] = { moisture = 1.8 }, [3] = { moisture = -0.4 } },
    { [2] = 2.5, [3] = -1.0 }
  ))
  T.near("clamp: moisture capped at 1", dstData[2].moisture, 1.0)
  T.near("clamp: moisture floored at 0", dstData[3].moisture, 0.0)
  T.near("clamp: stress capped at 1", dstStress[2], 1.0)
  T.near("clamp: stress floored at 0", dstStress[3], 0.0)
end

-- Defensive: non-table / nil input degrades to zero fields, never crashes.
do
  local d1 = B.deserializeFields(nil)
  T.eq("guard: nil input = 0 fields", next(d1) == nil and 0 or 1, 0)
  local d2 = B.deserializeFields({ 0 })
  T.eq("guard: empty array = 0 fields", next(d2) == nil and 0 or 1, 0)
end
