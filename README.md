TestRepo
========

This repository contains two unrelated projects:

- [`index.html`](./index.html) - **Lego Tetris**, a browser game (described below).
- [`ad-backup/`](./ad-backup/) - **AD Backup & Restore on Azure**, a PowerShell
  + Bicep solution that snapshots Active Directory to immutable Azure Blob
  Storage, diffs snapshots, and supports authoritative restore after
  compromise. See [`ad-backup/README.md`](./ad-backup/README.md).

Lego Tetris
-----------

A browser Tetris game rendered with Lego-brick styled blocks (studs, bevels, highlights).

Open `index.html` in any modern browser to play.

## Controls

- `←` / `→` — move
- `↓` — soft drop
- `↑` / `X` — rotate clockwise
- `Z` — rotate counter-clockwise
- `Space` — hard drop
- `P` — pause

## Features

- Standard 10×20 playfield with the 7 classic tetrominoes
- 7-bag randomizer for fair piece distribution
- Ghost piece, hard/soft drop, wall kicks
- Next-piece preview
- Progressive speed (level increases every 10 lines)
- Score: 100/300/500/800 per 1/2/3/4 lines, multiplied by level
