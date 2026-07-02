# DSLD SCH — Schedule of Openings Auto-Fill (AutoCAD Architecture)

AutoLISP routine that fills the DSLD **Schedule of Openings** (WINDOW SCHEDULE + DOOR SCHEDULE tables) from the door/window objects placed on the floor plan, with a preview dialog before anything is written.

| File | Purpose |
|---|---|
| `SCH.lsp` | The routine — commands `SCH` and `SCHDIAG` |
| `SCH_DISCOVERY_REPORT.md` | Asset analysis behind the design (tags, property sets, table format) |

## Loading

In AutoCAD Architecture: `APPLOAD` → select `SCH.lsp` → Load.
(Or drag the file into the drawing window.)

## Testing — step 1: run SCHDIAG first

On a real production plan (one with typical doors, a window, a cased opening, a 4" and a 6" wall):

1. Command: **`SCHDIAG`**
2. It prints a census of the drawing (AEC doors/windows/openings/walls, tags, tables).
3. When prompted, click: a couple of hinged doors, a window, a cased opening, and a wall. Press Enter to finish.
4. It writes **`SCHDIAG-report.txt`** next to the DWG. Send that file back — it confirms exactly what data the objects expose (property sets, swing/hand, wall widths, explode behavior) so the extraction layer can be hardened.

## Testing — step 2: run SCH

1. Command: **`SCH`**
2. Window-select **one plan version** (one house copy — not the whole model space, since constructs hold multiple mirrored/variant copies).
3. Pick the **WINDOW SCHEDULE** table, then the **DOOR SCHEDULE** table (Enter skips either).
4. Review the preview dialog:
   - `+` new row · `~` changes an existing row · `=` unchanged · `!` needs attention
   - LH/RH placement: **columns after QTY** (default) or appended to DESCRIPTION
5. **Apply to Tables** writes the cells (single undo step). **Cancel** touches nothing.

## What it reads

1. **Property sets on each door/window** (`DoorObjects` / `WindowObjects`: `DSLD_NUMBER` mark, `StandardSizeDescription` size code) — the same data the TK_ tags display.
2. Fallback: the object's own Width/Height properties.
3. Fallback for flattened drawings: `TK_Door_Tag*` / `TK_Window_Tag*` block inserts (mark bubble paired with nearest size tag).

Computed (not stored on the assets):
- **LH/RH** — derived per door from the swing arc vs. the host wall. Convention: stand on the side the door swings **away** from; hinge on your left = LH.
- **Cased openings** — `AecDbOpening` objects or doors with `TK_Arch*` styles; host wall Width `< 5"` → `CASED OPENING - 4" WALL`, otherwise `- 6" WALL`.

## Config (top of SCH.lsp)

```lisp
(setq *sch:wall6-threshold* 5.0)     ; wall Width >= 5.0" counts as 6" wall
(setq *sch:hand-convention* "AWAY")  ; "TOWARD" flips LH/RH
```

## Known limitations (v1)

- LH/RH geometric detection is skipped for doors living inside an xref (run SCH in the construct that owns the doors for full swing counts).
- Existing DESCRIPTION text is never overwritten (except cased-opening wall-size updates); new rows get an empty description for you to fill.
- Must run inside AutoCAD Architecture for AEC-object reading; in plain AutoCAD/BricsCAD only the tag-INSERT fallback and table writing work.
