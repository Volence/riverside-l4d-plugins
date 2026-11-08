/*
 * l4d_nav_no_mobs: mark nav areas NO_MOBS from mapinfo, for ground the commons cannot leave.
 *
 * Carried Off 4 (cwm4_building) ends on a roof whose only way down is the stair hut's doorway, and commons do not
 * make it through: they climb the hut and its door, drop back and climb again (video from a PUG, 2026-11-07). The
 * roof is FINALE ground, so the escape horde spawned there while the survivors were still floors below and those
 * commons looped at the hut for the rest of the run, using up the common limit. Match fd4d95a3 map 4: 65 of 596
 * commons spawned on the roof, and 34 of the 44 that looped at the hut for 8 s or more were roof spawns.
 *
 * ZombieManager::AccumulateSpawnAreaCollection skips NO_MOBS areas (0x2000) for the escape horde, the boom mob
 * and the director's mobs. This sets the bit on every nav area whose centre is inside a box listed in the map's
 * mapinfo block, when the map starts:
 *
 *	"nav_no_mobs"
 *	{
 *		"<what the box covers>"
 *		{
 *			"mins"	"x y z"
 *			"maxs"	"x y z"
 *		}
 *	}
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <left4dhooks>

#define PLUGIN_VERSION	"1.0"
#define SPAWN_NO_MOBS	0x2000

public Plugin myinfo =
{
	name = "l4d_nav_no_mobs",
	author = "Malevolence",
	description = "Mark nav areas NO_MOBS from mapinfo (ground commons cannot leave)",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnMapStart()
{
	char path[PLATFORM_MAX_PATH], map[64];
	BuildPath(Path_SM, path, sizeof(path), "data/mapinfo.txt");
	GetCurrentMap(map, sizeof(map));

	KeyValues kv = new KeyValues("MapInfo");
	if (!kv.ImportFromFile(path))
	{
		LogError("Couldn't load %s", path);
		delete kv;
		return;
	}
	if (!kv.JumpToKey(map) || !kv.JumpToKey("nav_no_mobs") || !kv.GotoFirstSubKey())
	{
		delete kv;
		return;
	}

	ArrayList areas = new ArrayList();
	L4D_GetAllNavAreas(areas);
	char name[64];
	float mins[3], maxs[3], center[3];
	do
	{
		kv.GetSectionName(name, sizeof(name));
		if (!ReadVector(kv, "mins", mins) || !ReadVector(kv, "maxs", maxs))
		{
			LogError("%s: nav_no_mobs \"%s\" needs \"mins\" and \"maxs\"", map, name);
			continue;
		}
		int marked = 0;
		for (int i = 0; i < areas.Length; i++)
		{
			Address area = areas.Get(i);
			L4D_GetNavAreaCenter(area, center);
			if (!InBox(center, mins, maxs))
				continue;
			L4D_SetNavArea_SpawnAttributes(area, L4D_GetNavArea_SpawnAttributes(area) | SPAWN_NO_MOBS);
			marked++;
		}
		LogMessage("%s: \"%s\" marked %d nav areas NO_MOBS", map, name, marked);
	}
	while (kv.GotoNextKey());

	delete areas;
	delete kv;
}

bool ReadVector(KeyValues kv, const char[] key, float vec[3])
{
	char s[64], parts[3][16];
	kv.GetString(key, s, sizeof(s));
	if (ExplodeString(s, " ", parts, 3, 16) != 3)
		return false;
	for (int i = 0; i < 3; i++)
		vec[i] = StringToFloat(parts[i]);
	return true;
}

bool InBox(const float p[3], const float mins[3], const float maxs[3])
{
	for (int i = 0; i < 3; i++)
	{
		if (p[i] < mins[i] || p[i] > maxs[i])
			return false;
	}
	return true;
}
