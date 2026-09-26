# mge-stv-camfix

SourceMod plugin for Team Fortress 2 dedicated servers. It stops SourceTV from hanging srcds when an `info_observer_point` is deleted while the HLTV director still holds a raw pointer to it.

Without this, `CHLTVDirector::AnalyzeCameras` can call `GetAbsOrigin` on a freed camera. The engine then spins forever inside `CThreadFastMutex::Lock`. The watchdog kills the process about a minute later with:

```
WatchDog! Server took too long to process (probably infinite loop).
FATAL ERROR: Host_Error: WatchdogHandler called - server exiting.
```

`tv_enable 0` avoids the path. This plugin lets SourceTV stay on.

## How it works

TF2 stores fixed cameras as raw `CBaseEntity*` in `CHLTVDirector::m_pFixedCameras`. A `Kill` / `RemoveEntity` / delayed `UTIL_Remove` does not rebuild that array. The next director think (every 0.5s while an HLTV server exists) walks the stale list.

This plugin detours `AnalyzeCameras` (DHooks, bundled in SourceMod 1.12) and calls `BuildCameraList` first, using the Linux singleton accessor `HLTVDirector()`. TF2 Linux puts `IHLTVDirector` at this-adjust 12, not the L4D gamedata offset 16.

It does **not** fix the separate SourceTV crash in `CHLTVServer::UpdateTick` / `free()`.

## Requirements

- Team Fortress 2 Linux dedicated server
- SourceMod 1.12 with DHooks
- `tv_enable 1` (otherwise the director never thinks)

Windows signatures are not in the gamedata. Linux only.

## Installation

1. Copy `plugins/mge_stv_camfix.smx` to `addons/sourcemod/plugins/`.
2. Copy `gamedata/mge_stv_camfix.txt` to `addons/sourcemod/gamedata/`.
3. `sm plugins load mge_stv_camfix` or restart the map.

On load you should see `[stvcamfix] director at ...` and `[stvcamfix] armed`.

## Cvars and commands

| Name | Default | Role |
|---|---|---|
| `mge_stv_camfix_clear_events` | `0` | If `1`, also call `RemoveEventsFromHistory(-1)` after rebuilding the camera list |
| `mge_stv_camfix_rebuild` | server cmd | Rebuild the list now, without waiting for the next director think |
| `mge_stv_camfix_arm` | server cmd | Enable the detour immediately (it also auto-arms 2s after map start) |

## Build

```
spcomp scripting/mge_stv_camfix.sp -o plugins/mge_stv_camfix.smx
```

CI compiles on `v*` tags (SourcePawn 1.12.x) and publishes a zip with `plugins/`, `gamedata/`, and `scripting/`.
