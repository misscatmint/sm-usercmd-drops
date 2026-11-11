# sm-usercmd-drops

A SourceMod plugin for CS:GO servers that logs the player commands the
server receives but doesn't simulate, and the engine's stand-in commands,
per player and per map. It changes nothing in game: it only counts and
writes logs.

## Why

SourceMod's `OnPlayerRunCmd` and `OnPlayerRunCmdPost` run for every
command handed to the player's command function, including commands the
engine then throws away: over the player's command budget
(`sv_maxusrcmdprocessticks`), or with a tick count too far ahead
(`sv_max_usercmd_future_ticks`, the speedhack check). Another plugin can
also skip a command by returning `Plugin_Handled`. How often this happens
to players with stock clients is unknown, and this plugin measures it.

## Requirements

- SourceMod 1.12 with SDKHooks and SDKTools.
- Tested on CS:GO only. It reads `sv_max_usercmd_future_ticks` and refuses
  to load without it.

## How it works

- `OnPlayerRunCmd` marks the command pending.
- SDKHooks' `PostThinkPost`, which runs once for each command the server
  simulates, clears the mark.
- `OnPlayerRunCmdPost` counts a command still marked as not simulated.
  Its tick count decides the reason: more than
  `sv_max_usercmd_future_ticks` ahead of the server tick is `future`,
  anything else `budget_or_skip`.
- A command that repeats the previous command's number counts as a
  stand-in: the engine's replay of the last command after a silence, or
  its fill-ins for lost packets. Stand-ins are simulated like any command.

Bots are skipped.

## Output

Daily tab-separated files in `addons/sourcemod/logs/usercmd-drops/`:

- `YYYYMMDD-summary.tsv`, one row per player per map, written when the
  player leaves or the map ends: `ticks` (server ticks the player was in
  the game), `received`, `simulated`, `stand_ins`,
  `drops_budget_or_skip`, `drops_future`, and `dropped_jump_presses`
  (dropped commands that pressed jump after a command without it).
- `YYYYMMDD-drops.tsv`, one row per dropped command, up to
  `sm_usercmd_drops_max_lines` (default 100) per player per map:
  `server_tick`, the command's `cmdnum` and `tickcount`, `ticks_ahead`,
  `reason` and `jump_press`.

Times are Unix seconds. Players are identified by SteamID64.

## Limits

- `budget_or_skip` can't tell the budget from another plugin's
  `Plugin_Handled`.
- The `future` reason compares the command's tick count with the server
  tick as the plugin sees it, an approximation of the engine's check.
- Counting a drop relies on `OnPlayerRunCmdPost` running after a dropped
  command, as SourceHook runs post hooks whatever the hooked function did.
  If drops never show up while the engine's own warning
  (`sv_maxusrcmdprocessticks_warning`) reports them, that assumption is
  wrong.
- A stand-in is recognized only by its repeated command number.

## Build

`make` builds `addons/sourcemod/plugins/usercmd-drops.smx` with `spcomp64`
from `PATH` (or `SPCOMP`). `make dist` builds a release zip, with `SMDIR`
set to a SourceMod scripting folder that holds `spcomp64` and `include/`.

## License

AGPL-3.0, see `LICENSE.txt`.
