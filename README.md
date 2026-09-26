# stv-camfix

SourceMod plugin that stops TF2 SourceTV from hanging srcds when an `info_observer_point` is deleted while the director still has a pointer to it.

Linux dedicated servers get the AnalyzeCameras detour plus camera-list splice. Windows gets splice via `CreateInterface` (no detour signatures yet). SourceMod 1.12 with DHooks.

## Installation

1. Copy `stv_camfix.smx` to `addons/sourcemod/plugins/`
2. Copy `stv_camfix.txt` to `addons/sourcemod/gamedata/`

## Logs

Lines go to SourceMod `errors_*.log`. Grep `[stvcamfix]`.

| Token | Meaning |
|---|---|
| `ready` | Plugin loaded |
| `SAVED` | Removed a dying camera from the director list |
| `REBUILT` | AnalyzeCameras rebuild changed the camera count |
| `FAIL` | Detour did not arm |
