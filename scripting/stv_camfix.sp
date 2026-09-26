#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define GAMEDATA_FILE "stv_camfix"

public Plugin myinfo =
{
	name = "SourceTV Camera List Fix",
	author = "mge.tf",
	description = "Rebuild CHLTVDirector camera pointers before AnalyzeCameras so a freed info_observer_point cannot hang srcds",
	version = "1.1",
	url = "https://mge.tf"
};

static Handle g_hBuildCameraList;
static Handle g_hRemoveEventsFromHistory;
static Address g_pDirector;
static DynamicDetour g_hAnalyzeCameras;
static ConVar g_cvClearEvents;
static bool g_bRebuilding;
static bool g_bMapActive;
static bool g_bArmed;
static int g_iDetourHits;

public void OnPluginStart()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (gd == null)
	{
		SetFailState("Missing gamedata %s.txt", GAMEDATA_FILE);
	}

	LoadDirectorOrFail(gd);

	g_hAnalyzeCameras = DynamicDetour.FromConf(gd, "CHLTVDirector::AnalyzeCameras");
	delete gd;
	if (g_hAnalyzeCameras == null)
	{
		SetFailState("DynamicDetour.FromConf failed for CHLTVDirector::AnalyzeCameras");
	}

	g_cvClearEvents = CreateConVar("stv_camfix_clear_events", "0", "Call RemoveEventsFromHistory(-1) after BuildCameraList", _, true, 0.0, true, 1.0);
	RegServerCmd("stv_camfix_rebuild", CmdRebuild);
	RegServerCmd("stv_camfix_arm", CmdArm);

	g_bMapActive = true;
	CreateTimer(2.0, Timer_Arm, _, TIMER_FLAG_NO_MAPCHANGE);
	PrintToServer("[stvcamfix] loaded. Detour arms in 2s.");
}

public void OnMapStart()
{
	g_bMapActive = true;
	g_iDetourHits = 0;
	CreateTimer(2.0, Timer_Arm, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
	g_bMapActive = false;
	DisarmDetour();
}

public Action Timer_Arm(Handle timer)
{
	ArmDetour();
	return Plugin_Stop;
}

public Action CmdArm(int args)
{
	ArmDetour();
	return Plugin_Handled;
}

public Action CmdRebuild(int args)
{
	if (g_pDirector == Address_Null)
	{
		PrintToServer("[stvcamfix] rebuild skipped: no director");
		return Plugin_Handled;
	}

	RebuildCameraList();
	PrintToServer("[stvcamfix] rebuild ok (clear_events=%d)", g_cvClearEvents.IntValue);
	return Plugin_Handled;
}

public MRESReturn Detour_AnalyzeCameras(Address pThis)
{
	if (g_iDetourHits < 3)
	{
		g_iDetourHits++;
		PrintToServer("[stvcamfix] AnalyzeCameras pre #%d this=%08x director=%08x", g_iDetourHits, pThis, g_pDirector);
	}

	RebuildCameraList();
	return MRES_Ignored;
}

static void ArmDetour()
{
	if (g_bArmed || g_hAnalyzeCameras == null)
	{
		return;
	}

	if (!g_hAnalyzeCameras.Enable(Hook_Pre, Detour_AnalyzeCameras))
	{
		SetFailState("Failed to enable AnalyzeCameras pre-detour");
	}

	g_bArmed = true;
	PrintToServer("[stvcamfix] armed. AnalyzeCameras rebuilds m_pFixedCameras first.");
}

static void DisarmDetour()
{
	if (!g_bArmed || g_hAnalyzeCameras == null)
	{
		return;
	}

	g_hAnalyzeCameras.Disable(Hook_Pre, Detour_AnalyzeCameras);
	g_bArmed = false;
	PrintToServer("[stvcamfix] disarmed for map end.");
}

static void RebuildCameraList()
{
	if (g_bRebuilding || !g_bMapActive || g_pDirector == Address_Null)
	{
		return;
	}

	g_bRebuilding = true;
	SDKCall(g_hBuildCameraList, g_pDirector);
	if (g_cvClearEvents != null && g_cvClearEvents.BoolValue)
	{
		SDKCall(g_hRemoveEventsFromHistory, g_pDirector, -1);
	}
	g_bRebuilding = false;
}

static void LoadDirectorOrFail(GameData gd)
{
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "HLTVDirector"))
	{
		SetFailState("HLTVDirector() signature missing");
	}
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle hAccessor = EndPrepSDKCall();
	if (hAccessor == null)
	{
		SetFailState("HLTVDirector() SDKCall prep failed");
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CHLTVDirector::BuildCameraList"))
	{
		delete hAccessor;
		SetFailState("BuildCameraList signature missing");
	}
	g_hBuildCameraList = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Raw);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CHLTVDirector::RemoveEventsFromHistory"))
	{
		delete hAccessor;
		SetFailState("RemoveEventsFromHistory signature missing");
	}
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hRemoveEventsFromHistory = EndPrepSDKCall();

	if (g_hBuildCameraList == null || g_hRemoveEventsFromHistory == null)
	{
		delete hAccessor;
		SetFailState("Director SDKCall prep failed");
	}

	g_pDirector = SDKCall(hAccessor);
	delete hAccessor;
	if (g_pDirector == Address_Null)
	{
		SetFailState("HLTVDirector() returned null");
	}

	PrintToServer("[stvcamfix] director at %08x", g_pDirector);
}
