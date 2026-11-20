-- SYNTHETIC fixture in the tools/gen_quest_data.py emit layout. Invented ids,
-- names and spots only; no game data.

ShadowArmyQuestZones = {
[9900] = "Synthetic Field",
}

ShadowArmyQuestData = {
["Two Satchels"] = {
id = 9101, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Alpha Satchel", kind = "item", count = 4, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
{ label = "Beta Satchel", kind = "item", count = 6, from = { "Beta Raider" }, spots = { {zone = 9900, x = 50.0, y = 57.5} } },
},
alts = {
{
id = 9106, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Patched Alpha", kind = "item", count = 2, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
{ label = "Patched Beta", kind = "item", count = 3, from = { "Beta Raider" }, spots = { {zone = 9900, x = 50.0, y = 57.5} } },
},
},
},
},
["One Survivor"] = {
id = 9102, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Kept Satchel", kind = "item", count = 1, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
},
},
["Count Drift"] = {
id = 9103, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Drift A", kind = "item", count = 4, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
{ label = "Drift B", kind = "item", count = 6, from = { "Beta Raider" }, spots = { {zone = 9900, x = 50.0, y = 57.5} } },
},
},
["Twin Ids"] = {
id = 9104, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Twin A", kind = "item", count = 1, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
{ label = "Twin B", kind = "item", count = 1, from = { "Beta Raider" }, spots = { {zone = 9900, x = 50.0, y = 57.5} } },
},
},
["Conflicted"] = {
id = 9105, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Conf A", kind = "item", count = 1, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
{ label = "Conf B", kind = "item", count = 1, from = { "Beta Raider" }, spots = { {zone = 9900, x = 50.0, y = 57.5} } },
},
},
["Undefined"] = {
id = 9107, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Undef A", kind = "item", count = 1, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
{ label = "Undef B", kind = "item", count = 1, from = { "Beta Raider" }, spots = { {zone = 9900, x = 50.0, y = 57.5} } },
},
},
["Handed Over"] = {
id = 9108, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Hunted A", kind = "item", count = 2, from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
{ label = "Hunted B", kind = "item", count = 2, from = { "Beta Raider" }, spots = { {zone = 9900, x = 50.0, y = 57.5} } },
},
},
["Mixed Work"] = {
id = 9109, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Gamma Raider", kind = "mob", count = 5, spots = { {zone = 9900, x = 25.0, y = 50.0} } },
{ label = "Signal Post", kind = "object", count = 1, spots = { {zone = 9900, x = 75.0, y = 50.0} } },
{ label = "Gamma Tooth", kind = "item", count = 3, from = { "Gamma Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
},
},
["No Count"] = {
id = 9110, level = 5, minLevel = 3, zone = 9900,
objectives = {
{ label = "Old A", kind = "item", from = { "Alpha Raider" }, spots = { {zone = 9900, x = 50.0, y = 35.0} } },
},
},
}
