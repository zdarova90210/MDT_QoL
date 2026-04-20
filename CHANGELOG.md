# Changelog

## 0.4.1 - 2026-04-20

- Extended top-panel spell search to also match enemy names.

## 0.4.0 - 2026-04-19

- Added a spell search bar in the MDT top panel (`Search spell name or ID`).
- Search results now instantly show which enemy casts a spell in the current dungeon.
- Clicking a search result opens `Enemy Info` for that enemy.
- Implemented lightweight per-dungeon spell indexing with caching to keep the addon responsive.

## 0.3.0 - 2026-04-13

- Refined the `Ctrl` pull percentage labels: increased horizontal padding, added rounded pill-style background corners, and nudged labels a few pixels lower from their anchor.

## 0.2.0 - 2026-04-13

- Added support for closing the `Enemy Info` window with `Ctrl + Right Click` anywhere inside the window.
- Added protection against immediate closing on the same click that opens `Enemy Info`.

## 0.1.0 - 2026-04-08

- First public release of `MDT_QoL`.
- Added a pull percentage overlay on the map when `Ctrl` is held.
- Added a high-contrast background for percentages (semi-transparent black, 4px padding).
- Added quick access to `Enemy Info`: `Ctrl + Right Click` on an enemy.
- Added fallback font logic, including an attempt to use `PTSansNarrow`.
