#include <sourcemod>
#include <sdkhooks>

#pragma semicolon 1
#pragma newdecls required

#if !defined PLUGIN_VERSION
#define PLUGIN_VERSION "dev"
#endif

public Plugin myinfo =
{
	name = "usercmd drops",
	author = "catmint",
	description = "Logs player commands the server receives but doesn't simulate",
	version = PLUGIN_VERSION,
	url = ""
};

enum struct PlayerStats
{
	int firstTick;
	int lastTick;
	int received;
	int simulated;
	int standIns;
	int dropsBudgetOrSkip;
	int dropsFuture;
	int droppedJumpPresses;
	int dropLines;
}

ConVar gCV_FutureTicks;
ConVar gCV_MaxDropLines;
PlayerStats gStats[MAXPLAYERS + 1];
bool gPending[MAXPLAYERS + 1];
bool gJumpPress[MAXPLAYERS + 1];
bool gHaveLast[MAXPLAYERS + 1];
int gLastCmdnum[MAXPLAYERS + 1];
int gLastButtons[MAXPLAYERS + 1];
char gLogDir[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
	gCV_FutureTicks = FindConVar("sv_max_usercmd_future_ticks");
	if (gCV_FutureTicks == null)
	{
		SetFailState("sv_max_usercmd_future_ticks not found");
	}
	gCV_MaxDropLines = CreateConVar("sm_usercmd_drops_max_lines", "100",
		"Drop lines logged per player per map (summaries are always logged)", _, true, 0.0);

	BuildPath(Path_SM, gLogDir, sizeof(gLogDir), "logs/usercmd-drops");
	if (!DirExists(gLogDir) && !CreateDirectory(gLogDir, 0o755))
	{
		SetFailState("Can't create %s", gLogDir);
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}
}

public void OnClientPutInServer(int client)
{
	PlayerStats fresh;
	fresh.firstTick = GetGameTickCount();
	fresh.lastTick = fresh.firstTick;
	gStats[client] = fresh;
	gPending[client] = false;
	gHaveLast[client] = false;
	if (!IsFakeClient(client))
	{
		SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
	}
}

public void OnClientDisconnect(int client)
{
	if (IsFakeClient(client) || gStats[client].received == 0)
	{
		return;
	}
	char steamId[32];
	GetSteamId(client, steamId, sizeof(steamId));
	File file = OpenLog("summary",
		"time\tmap\tsteamid64\tticks\treceived\tsimulated\tstand_ins\tdrops_budget_or_skip\tdrops_future\tdropped_jump_presses");
	if (file == null)
	{
		return;
	}
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	file.WriteLine("%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d", GetTime(), map, steamId,
		gStats[client].lastTick - gStats[client].firstTick + 1, gStats[client].received,
		gStats[client].simulated, gStats[client].standIns, gStats[client].dropsBudgetOrSkip,
		gStats[client].dropsFuture, gStats[client].droppedJumpPresses);
	delete file;
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
	int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (IsFakeClient(client))
	{
		return Plugin_Continue;
	}
	gStats[client].received++;
	gStats[client].lastTick = GetGameTickCount();
	// The engine's stand-ins (a replay of the last command, packet-loss fill-ins) repeat its number.
	if (gHaveLast[client] && cmdnum == gLastCmdnum[client])
	{
		gStats[client].standIns++;
	}
	gJumpPress[client] = (buttons & IN_JUMP) != 0 && (gLastButtons[client] & IN_JUMP) == 0;
	gLastCmdnum[client] = cmdnum;
	gLastButtons[client] = buttons;
	gHaveLast[client] = true;
	gPending[client] = true;
	return Plugin_Continue;
}

public void OnPostThinkPost(int client)
{
	gPending[client] = false;
	gStats[client].simulated++;
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3],
	const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed,
	const int mouse[2])
{
	if (!gPending[client])
	{
		return;
	}
	gPending[client] = false;

	int ahead = tickcount - GetGameTickCount();
	bool future = ahead > gCV_FutureTicks.IntValue;
	if (future)
	{
		gStats[client].dropsFuture++;
	}
	else
	{
		gStats[client].dropsBudgetOrSkip++;
	}
	if (gJumpPress[client])
	{
		gStats[client].droppedJumpPresses++;
	}

	if (gStats[client].dropLines >= gCV_MaxDropLines.IntValue)
	{
		return;
	}
	gStats[client].dropLines++;
	char steamId[32];
	GetSteamId(client, steamId, sizeof(steamId));
	File file = OpenLog("drops",
		"time\tmap\tserver_tick\tsteamid64\tcmdnum\ttickcount\tticks_ahead\treason\tjump_press");
	if (file == null)
	{
		return;
	}
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	file.WriteLine("%d\t%s\t%d\t%s\t%d\t%d\t%d\t%s\t%d", GetTime(), map, GetGameTickCount(),
		steamId, cmdnum, tickcount, ahead, future ? "future" : "budget_or_skip",
		gJumpPress[client] ? 1 : 0);
	delete file;
}

void GetSteamId(int client, char[] buffer, int maxlength)
{
	if (!GetClientAuthId(client, AuthId_SteamID64, buffer, maxlength))
	{
		strcopy(buffer, maxlength, "unauthorized");
	}
}

// Opens today's log of one kind for appending, writing its header when the file is new.
File OpenLog(const char[] kind, const char[] header)
{
	char date[16];
	FormatTime(date, sizeof(date), "%Y%m%d", GetTime());
	char path[PLATFORM_MAX_PATH];
	Format(path, sizeof(path), "%s/%s-%s.tsv", gLogDir, date, kind);
	bool isNew = !FileExists(path);
	File file = OpenFile(path, "a");
	if (file == null)
	{
		LogError("Can't open %s", path);
		return null;
	}
	if (isNew)
	{
		file.WriteLine("%s", header);
	}
	return file;
}
