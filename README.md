# DSLD SCH — Schedule of Openings Auto-Fill

AutoLISP routine that fills the DSLD **Schedule of Openings** (WINDOW SCHEDULE + DOOR SCHEDULE tables) from the door/window objects on the floor plan, with a preview dialog before anything is written. Developed and fully regression-tested in **BricsCAD V26**; targets **AutoCAD Architecture** as well.

| File | Purpose |
|---|---|
| `SCH.lsp` | The routine — commands `SCH`, `SCHDIAG`, `SCHHELP`, `SCHUPDATE`, `SCHUNINSTALL` |
| `SCHPROBE.lsp` | Crash locator — loads SCH.lsp one form at a time with a flushed log (use if AutoCAD dies loading SCH) |
| `SCHTEST.lsp` | Regression harness (developer use) |
| `SCH_DISCOVERY_REPORT.md` | Asset analysis behind the design (tags, property sets, table format) |

## Installing (once per machine)

1. Download **fresh copies from this repo** (green *Code* button → *Download ZIP*). Do **not** use a copy that traveled through email/Word — pasting corrupts LISP files.
2. Put `SCH.lsp` (and `SCHPROBE.lsp`) in a folder, e.g. `C:\DSLD\lisp`.
3. AutoCAD only: add that folder under **Options → Files → Trusted Locations** (otherwise AutoCAD pops a security warning at every load — and that dialog can open off-screen and look like a freeze).
4. `APPLOAD` → select `SCH.lsp` → Load. On first load it installs itself into `acaddoc.lsp` so it auto-loads in every future session. `SCHUNINSTALL` removes that again.

## Commands

- **`SCH`** — box-select one plan (interior + exterior xrefs both picked up, or type `All` / run from paper space). Preview dialog shows every row before anything is written; counts can *Replace* or *Add to* existing values. Charts are created in DSLD format on the **SCH layer** if none exist; charts in other open drawings are updated too.
- **`SCHDIAG`** — read-only diagnostics. Writes `SCHDIAG-report.txt` next to the DWG; run this first on a new machine and send the report back.
- **`SCHHELP`** — quick-reference popup.
- **`SCHUPDATE`** — pulls the latest version from this repo and reloads.

## If AutoCAD crashes or freezes when loading SCH.lsp

BricsCAD loading fine but AutoCAD "crashing" is almost never the code text — a bad LISP file produces a command-line *error*, not a crash. Work down this list:

1. **Run the probe.** Put `SCHPROBE.lsp` next to `SCH.lsp` and `APPLOAD` it. It logs its progress to `SCHPROBE-log.txt` *before* each step, so if AutoCAD dies, the last line of the log names the exact culprit. It also reports `SECURELOAD` / trusted-path state and audits `acaddoc.lsp`. **Email that log back.**
2. **Look for a hidden security dialog.** With `SECURELOAD=1` and an untrusted folder, AutoCAD shows a modal warning that can appear off-screen (second monitor unplugged, etc.) — the session *looks* hung. Add the folder to Trusted Locations (step 3 above).
3. **Check for a stale autoload line.** If an old/broken copy of SCH.lsp was ever loaded, `acaddoc.lsp` may re-load it on *every drawing open*. Open `acaddoc.lsp` (the probe log prints its path) and delete the two lines following/including the `SCH-AUTOLOAD` marker, or run `SCHUNINSTALL` from a session that did load.
4. **Rule out the machine.** Antivirus can quarantine LISP mid-load (writing to `acaddoc.lsp` resembles ALisp-virus behavior — add the folder to AV exclusions). And ACA's AEC object enablers crash at drawing-open at the same moment `acaddoc.lsp` runs: rename `acaddoc.lsp` temporarily — if ACA still crashes, it is the ACA install, not the LISP. Crash details land in `%LOCALAPPDATA%\Autodesk` (`acad.err`, `.dmp` files).

## What it reads

1. **Property sets on each door/window** (`DoorObjects` / `WindowObjects`: `DSLD_NUMBER` mark, `StandardSizeDescription` size code) — the same data the TK_ tags display (ACA only).
2. Fallback: geometry measured inside the casing, snapped to the DSLD standard-size catalog (this is the path BricsCAD uses).
3. Fallback for flattened drawings: `TK_Door_Tag*` / `TK_Window_Tag*` block inserts (mark bubble paired with nearest size tag).

Computed (not stored on the assets):
- **LH/RH** — derived per door from the swing arc vs. the host wall. Convention: stand on the side the door swings **away** from; hinge on your left = LH. Doubles/sliders/garage doors count as "swing unknown".
- **Cased openings** — `AecDbOpening` objects or doors with `TK_Arch*` styles; host wall Width `< 5"` → `CASED OPENING - 4" WALL`, otherwise `- 6" WALL`.

## Config (top of SCH.lsp)

Descriptions, size catalogs, trim allowances, the LH/RH convention, the SCH layer name, and the GitHub update URL all live in the config block at the top of `SCH.lsp` — edit freely to match office wording.
