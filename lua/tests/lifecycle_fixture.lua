-- Synthetic world positions for tools/lifecycle.lua tests. Preloaded ahead of
-- the private data.bot_lifecycle_positions module so tests never depend on
-- (or read) game-derived spawn data: the quest giver sits at (1100, 100), well
-- away from the origin, the home-zone warlock trainer beside her, the next-town
-- trainer far off, and the skull field at (1250, 0).
package.preload["data.bot_lifecycle_positions"] = function()
  return {
    creatures = {
      [2126] = { map = 0, x = 1104.0, y = 104.0, z = 10.0 },
      [2127] = { map = 0, x = 1500.0, y = -1300.0, z = 10.0 },
      [5667] = { map = 0, x = 1100.0, y = 100.0, z = 10.0 },
    },
    places = {
      skeleton_field = { map = 0, x = 1250.0, y = 0.0, z = 10.0 },
    },
  }
end
return true
