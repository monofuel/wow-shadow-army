-- SYNTHETIC fixture in the tools/gen_quest_data.py emit layout. Invented ids,
-- names and spots only; no game data.

ShadowArmyQuestZones = {
[9900] = "Synthetic Field",
}

ShadowArmyQuestData = {
["Mixed Hunt"] = {
id = 9301, level = 4, minLevel = 2, zone = 9900,
objectives = {
{ label = "North Raider", kind = "mob", count = 8, spots = { {zone = 9900, x = 50.0, y = 49.0} } },
{ label = "South Raider", kind = "mob", count = 5, spots = { {zone = 9900, x = 35.0, y = 50.0} } },
{ label = "Raider Satchel", kind = "item", count = 8, from = { "North Raider", "South Raider", "West Raider" }, spots = { {zone = 9900, x = 50.0, y = 49.0}, {zone = 9900, x = 35.0, y = 50.0} } },
},
},
["Pure Satchel"] = {
id = 9302, level = 4, minLevel = 2, zone = 9900,
objectives = {
{ label = "North Pouch", kind = "item", count = 4, from = { "North Raider" }, spots = { {zone = 9900, x = 50.0, y = 65.0} } },
},
},
["Untyped Hunt"] = {
id = 9303, level = 4, minLevel = 2, zone = 9900,
objectives = {
{ label = "East Raider", kind = "mob", count = 7, spots = { {zone = 9900, x = 25.0, y = 50.0} } },
{ label = "East Fang", kind = "item", count = 2, from = { "East Raider" }, spots = { {zone = 9900, x = 25.0, y = 50.0} } },
},
},
}
