#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define GAMEDATA_FILE "stv_camfix"
#define MAX_FIXED_CAMERAS 64
#define IFACE_OK 0
#define POINTER_SIZE 4

public Plugin myinfo =
{
	name = "SourceTV Camera List Fix",
	author = "mge.tf",
	description = "Keep CHLTVDirector camera pointers valid when an observer camera is deleted",
	version = "1.2",
	url = "https://mge.tf"
};

static Handle g_hBuildCameraList;
static Handle g_hRemoveEventsFromHistory;
static Address g_pDirector;
static DynamicDetour g_hAnalyzeCameras;
static ConVar g_cvClearEvents;
static ConVar g_cvTrace;
static bool g_bRebuilding;
static bool g_bMapActive;
static bool g_bArmed;
static int g_iCamerasOffset = -1;
static int g_iCameraCountOffset = -1;
static int g_iIfaceOffset = -1;

public void OnPluginStart()
{
	GameData gd = new GameData(GAMEDATA_FILE);
	if (gd == null)
	{
		SetFailState("Missing gamedata %s.txt", GAMEDATA_FILE);
	}

	g_iIfaceOffset = gd.GetOffset("CHLTVDirector::IHLTVDirector");
	g_iCamerasOffset = gd.GetOffset("CHLTVDirector::m_pFixedCameras");
	g_iCameraCountOffset = gd.GetOffset("CHLTVDirector::m_nNumFixedCameras");

	LoadDirectorOrFail(gd);
	PrepDirectorCalls(gd);

	g_hAnalyzeCameras = DynamicDetour.FromConf(gd, "CHLTVDirector::AnalyzeCameras");
	delete gd;

	bool canSplice = (g_iCamerasOffset != -1 && g_iCameraCountOffset != -1);
	bool canDetour = (g_hAnalyzeCameras != null && g_hBuildCameraList != null);
	if (!canSplice && !canDetour)
	{
		SetFailState("Need camera list offsets or an AnalyzeCameras detour");
	}

	g_cvClearEvents = CreateConVar("stv_camfix_clear_events", "0", "Call RemoveEventsFromHistory(-1) after BuildCameraList", _, true, 0.0, true, 1.0);
	g_cvTrace = CreateConVar("stv_camfix_trace", "0", "Print AnalyzeCameras detour hits", _, true, 0.0, true, 1.0);
	RegServerCmd("stv_camfix_rebuild", CmdRebuild);
	RegServerCmd("stv_camfix_arm", CmdArm);

	g_bMapActive = true;
	CreateTimer(2.0, Timer_Arm, _, TIMER_FLAG_NO_MAPCHANGE);

	char map[128];
	GetCurrentMap(map, sizeof(map));
	LogError("[stvcamfix] ready v=1.2 map=%s director=%08x splice=%d detour=%d tv_enable=%d",
		map, g_pDirector, canSplice ? 1 : 0, canDetour ? 1 : 0, TvEnable());
}

public void OnMapStart()
{
	g_bMapActive = true;
	CreateTimer(2.0, Timer_Arm, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
	g_bMapActive = false;
	DisarmDetour();
}

public void OnEntityDestroyed(int entity)
{
	SpliceDestroyedCamera(entity);
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

	int before = ReadCameraCount();
	RebuildCameraList();
	PrintToServer("[stvcamfix] rebuild ok count %d -> %d", before, ReadCameraCount());
	return Plugin_Handled;
}

public MRESReturn Detour_AnalyzeCameras(Address pThis)
{
	if (g_cvTrace != null && g_cvTrace.BoolValue)
	{
		PrintToServer("[stvcamfix] AnalyzeCameras this=%08x director=%08x count=%d", pThis, g_pDirector, ReadCameraCount());
	}

	int before = ReadCameraCount();
	RebuildCameraList();
	int after = ReadCameraCount();
	if (before != after)
	{
		char map[128];
		GetCurrentMap(map, sizeof(map));
		LogError("[stvcamfix] REBUILT map=%s count %d -> %d", map, before, after);
	}

	return MRES_Ignored;
}

static void ArmDetour()
{
	if (g_bArmed || g_hAnalyzeCameras == null || g_hBuildCameraList == null)
	{
		return;
	}

	if (!g_hAnalyzeCameras.Enable(Hook_Pre, Detour_AnalyzeCameras))
	{
		LogError("[stvcamfix] FAIL AnalyzeCameras pre-detour enable");
		return;
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
}

static void RebuildCameraList()
{
	if (g_bRebuilding || !g_bMapActive || g_pDirector == Address_Null || g_hBuildCameraList == null)
	{
		return;
	}

	g_bRebuilding = true;
	SDKCall(g_hBuildCameraList, g_pDirector);
	if (g_cvClearEvents != null && g_cvClearEvents.BoolValue && g_hRemoveEventsFromHistory != null)
	{
		SDKCall(g_hRemoveEventsFromHistory, g_pDirector, -1);
	}
	g_bRebuilding = false;
}

static void SpliceDestroyedCamera(int entity)
{
	if (g_bRebuilding || !g_bMapActive || g_pDirector == Address_Null)
	{
		return;
	}
	if (g_iCamerasOffset == -1 || g_iCameraCountOffset == -1)
	{
		return;
	}
	if (entity < 0)
	{
		return;
	}

	char classname[64];
	if (!GetEntityClassname(entity, classname, sizeof(classname)))
	{
		return;
	}
	if (!StrEqual(classname, "info_observer_point"))
	{
		return;
	}

	Address adEntity = GetEntityAddress(entity);
	if (adEntity == Address_Null)
	{
		return;
	}

	int count = ReadCameraCount();
	if (count <= 0 || count > MAX_FIXED_CAMERAS)
	{
		return;
	}

	int ptrSize = POINTER_SIZE;
	int found = -1;
	for (int i = 0; i < count; i++)
	{
		Address slot = g_pDirector + view_as<Address>(g_iCamerasOffset + i * ptrSize);
		Address cam = LoadFromAddress(slot, NumberType_Int32);
		if (cam == adEntity)
		{
			found = i;
			break;
		}
	}
	if (found == -1)
	{
		return;
	}

	char name[64];
	GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));
	if (name[0] == '\0')
	{
		strcopy(name, sizeof(name), "-");
	}

	float origin[3];
	GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);

	for (int i = found; i < count - 1; i++)
	{
		Address dest = g_pDirector + view_as<Address>(g_iCamerasOffset + i * ptrSize);
		Address src = g_pDirector + view_as<Address>(g_iCamerasOffset + (i + 1) * ptrSize);
		StoreToAddress(dest, LoadFromAddress(src, NumberType_Int32), NumberType_Int32);
	}

	Address last = g_pDirector + view_as<Address>(g_iCamerasOffset + (count - 1) * ptrSize);
	StoreToAddress(last, 0, NumberType_Int32);
	StoreToAddress(g_pDirector + view_as<Address>(g_iCameraCountOffset), count - 1, NumberType_Int32);

	char map[128];
	GetCurrentMap(map, sizeof(map));
	LogError("[stvcamfix] SAVED map=%s ent=%d slot=%d origin=%.1f %.1f %.1f name=%s remaining=%d tv_enable=%d",
		map, entity, found, origin[0], origin[1], origin[2], name, count - 1, TvEnable());
}

static int ReadCameraCount()
{
	if (g_pDirector == Address_Null || g_iCameraCountOffset == -1)
	{
		return -1;
	}

	int count = LoadFromAddress(g_pDirector + view_as<Address>(g_iCameraCountOffset), NumberType_Int32);
	if (count < 0 || count > MAX_FIXED_CAMERAS)
	{
		return -1;
	}

	return count;
}

static int TvEnable()
{
	ConVar cv = FindConVar("tv_enable");
	return (cv != null && cv.BoolValue) ? 1 : 0;
}

static void LoadDirectorOrFail(GameData gd)
{
	g_pDirector = TryHltvDirectorAccessor(gd);
	if (g_pDirector == Address_Null)
	{
		g_pDirector = TryCreateInterfaceDirector(gd);
	}
	if (g_pDirector == Address_Null)
	{
		SetFailState("Could not resolve CHLTVDirector");
	}

	PrintToServer("[stvcamfix] director at %08x", g_pDirector);
}

static Address TryHltvDirectorAccessor(GameData gd)
{
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "HLTVDirector"))
	{
		return Address_Null;
	}
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle hAccessor = EndPrepSDKCall();
	if (hAccessor == null)
	{
		return Address_Null;
	}

	Address director = SDKCall(hAccessor);
	delete hAccessor;
	return director;
}

static Address TryCreateInterfaceDirector(GameData gd)
{
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CreateInterface"))
	{
		return Address_Null;
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_ByRef);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	Handle hCreate = EndPrepSDKCall();
	if (hCreate == null)
	{
		return Address_Null;
	}

	char ifaceName[64] = "HLTVDirector001";
	gd.GetKeyValue("INTERFACEVERSION_HLTVDIRECTOR", ifaceName, sizeof(ifaceName));
	if (g_iIfaceOffset == -1)
	{
		delete hCreate;
		return Address_Null;
	}

	int retval = IFACE_OK;
	Address iface = SDKCall(hCreate, ifaceName, retval);
	delete hCreate;
	if (retval != IFACE_OK || iface == Address_Null)
	{
		return Address_Null;
	}

	return iface - view_as<Address>(g_iIfaceOffset);
}

static void PrepDirectorCalls(GameData gd)
{
	StartPrepSDKCall(SDKCall_Raw);
	if (PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CHLTVDirector::BuildCameraList"))
	{
		g_hBuildCameraList = EndPrepSDKCall();
	}

	StartPrepSDKCall(SDKCall_Raw);
	if (PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CHLTVDirector::RemoveEventsFromHistory"))
	{
		PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
		g_hRemoveEventsFromHistory = EndPrepSDKCall();
	}
}
