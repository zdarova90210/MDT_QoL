# MDT_QoL

Quality-of-life addon for WoW Retail that extends a popular dungeon route planner addon without modifying its files.

## Features

- Hold `Ctrl` to show pull percentages directly on the map, without hunting for pulls in the sidebar.
- Quickly see how much % each pack gives while planning or running the dungeon.
- Use the `top-panel spell search` box to find a spell by name or ID and immediately see which enemy casts it.
- Press `Ctrl + Right Click` on an enemy to open `Enemy Info` instantly (without the context menu).
- Press `Ctrl + Right Click` anywhere inside `Enemy Info` to close it quickly.

## Repository layout

- `MDT_QoL/` - addon files for WoW.
- `tools/build-release.ps1` - release zip builder for CurseForge.
- `CHANGELOG.md` - release history.

## Local install

1. Copy `MDT_QoL/` to `World of Warcraft/_retail_/Interface/AddOns/`.
2. Ensure `.../AddOns/MDT_QoL/MDT_QoL.toc` exists.
3. Run `/reload` in game.

## Build release zip

```powershell
.\tools\build-release.ps1
```

Output:

- `release/MDT_QoL-<version>.zip`

The archive is ready for CurseForge upload (root folder inside zip is `MDT_QoL`).
