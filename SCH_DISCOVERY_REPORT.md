# SCH — Schedule of Openings LISP: Asset Discovery Report

**Date:** 2026-07-02 · **Scope:** all CAD assets used by the PDF extractor / DXF pipeline, analyzed to spec the `SCH` AutoLISP command for AutoCAD Architecture.

---

## TL;DR

| Question | Answer |
|---|---|
| What are the door/window callouts? | ACA **schedule tags** (multi-view blocks `TK_Door_Tag`, `TK_Door_Tag_Circle`, `TK_Window_Tag`, `TK_Window_Tag_Diamond`) whose text is driven by **property sets** `DoorObjects` / `WindowObjects` |
| Where's the MARK (bubble number/letter)? | Custom property **`DSLD_NUMBER`** (doors = numbers 1–11, windows = letters A–H) |
| Where's the size? | Automatic property **`StandardSizeDescription`** — codes like `2040`, `2668`, `8080` |
| What is the schedule chart? | A **native AutoCAD table** (`ACAD_TABLE`, style **"DSLD Table Style"**) — LISP can read/write it cell-by-cell. Columns: `MARK | WIDTH | HEIGHT | QTY | DESCRIPTION` |
| Is LH/RH stored anywhere? | **No.** Not in tags, not in the schedule, not in door styles. Must be derived from the door object/geometry in live ACA |
| How are cased openings marked? | Door-schedule rows with DESCRIPTION `CASED OPENING`; drawn via **TK_Arch** door styles or AEC Opening objects. No dedicated tag block exists |
| Can the wall (4" vs 6") be read? | Only from the **host wall's Width property** — most DSLD wall styles are variable-width ("Stud-X"), so style names alone can't tell |
| Can I test everything offline? | **No** — the ODA DXF conversion dropped every AEC object. Table + tag-INSERT logic is testable on the DXFs; door/wall reading needs live ACA |

---

## 1. The callout/tag system (Tags.dxf + tool palettes)

Your Palettes 3 catalog (`Tags_83FB7204...atc`, palette "Tags", parent document "DSLD") confirms the four production tag tools, all ACA Schedule Tag stock tools:

| Palette tool | Tag block | Layer key | Displays |
|---|---|---|---|
| Door Tag | `TK_Door_Tag` | DOORNO | `DOOROBJECTS:STANDARDSIZEDESCRIPTION` (size, e.g. `2668`) |
| Door Tag Circle | `TK_Door_Tag_Circle` | DOORNO | `DOOROBJECTS:DSLD_NUMBER` (mark number in a circle) |
| Window Tag | `TK_Window_Tag` | WINDNO | `WINDOWOBJECTS:STANDARDSIZEDESCRIPTION` (e.g. `2040`) |
| Window Tag Diamond | `TK_Window_Tag_Diamond` | WINDNO | `WINDOWOBJECTS:DSLD_NUMBER` (mark letter in a diamond) |

- A fifth block exists: `TK_Door_Tag_2` showing `DOOROBJECTS:WIDTH` only (width-only door tag — which plans use it is unconfirmed).
- Placed tags land on layers **`A-Door-Iden`** / **`A-Glaz-Iden`**.
- In live ACA these are `AecDbMvBlockRef` entities anchored to the door/window via `AecDbAnchorExtendedTagToEnt` — the tag *displays* property-set data that lives **on the door/window object**. So the LISP reads the objects (or their property sets) directly; the tags are just the visible face of the same data.
- The property-set *definitions* live in `W:\AutoCAD Architecture STUFF\AutoCAD Architecture\Library\Tags.dwg` — the W: drive is not mounted on this machine, so the full property list can only be confirmed in live ACA.

**Live sample found** (Sch. Of Openings.dxf): diamond tag `E` + size tag `2040` on `A-Glaz-Iden`, matching schedule row E = 2'-0" × 4'-0". Mirrored copies placed at negative X scale (LH/RH plan versions).

## 2. The schedule chart (the ref file)

Verified identical structure across Carlton 3 Family and the sample plan:

- **Native `ACAD_TABLE`** (not an AEC schedule table), table style **"DSLD Table Style"**, on layer `0`.
- 5 columns, widths 27/30/33/21/177 (24'-0" total): **MARK | WIDTH | HEIGHT | QTY | DESCRIPTION**.
- Title row ("WINDOW SCHEDULE" / "DOOR SCHEDULE"), header row, then data rows (~12" tall, LBRITE font, 4.5" text).
- **Windows use letter marks (A–H)** — spare blank rows are pre-allocated with the mark filled in (F, G, H empty). **Doors use number marks (1–11).**
- Sample door rows: `5 | 2'-8" | 6'-8" | 5 | INTERIOR GRADE - HOLLOW CORE - SEE P.O.` · `9 | 4'-0" | 6'-8" | 1 | DBL. 2068 INT. GRADE...` · `10 | 2'-8" | 6'-8" | 1 | CASED OPENING` · `11 | 8'-0" | 8'-0" | 1 | CASED OPENING`
- Descriptions contain MTEXT stacked fractions (`4/4 EQ. SASH` is stored as `\S4#4;`) — the LISP normalizes these when comparing, and **preserves existing descriptions** (they're spec text that isn't derivable from CAD).
- One drawing can hold **multiple schedule sets** — Carlton 3 has three window+door pairs labeled "SCHEDULE FOR A, B, C, D" / "SCHEDULE FOR K & L" for elevation groups. So `SCH` asks you to pick the target tables.
- No QTY surprises: QTY already aggregates identical openings.
- **No LH/RH column, no remarks column, no wall-thickness notation exists today** — adding LH/RH means either inserting columns or appending to DESCRIPTION (SCH supports both; you pick in the preview dialog).

## 3. LH/RH swing — the gap

Exhaustive text/attribute/style search across every asset: **per-door handing is encoded nowhere.** The only "LH/RH" strings anywhere label whole-house mirrored plan versions (the `Mirror Line` block), not door swings. Door styles distinguish single/double leaf (`TK_S-*` / `TK_D-*`) but never hand — consistent with ACA, where swing/hand is per-door-instance (grip flips), not per-style.

**Consequence:** SCH derives hand per door in live ACA, two ways:
1. If the DoorObjects property set carries any `*SWING*`/`*HAND*` property → use it.
2. Otherwise **geometric**: copy the door, explode the copy to primitives, find the swing arc + leaf line, compare against the host wall direction, compute LH/RH, delete the temp entities.

Default convention implemented: *stand on the side the door opens away from; hinges on your left = LH* (configurable to the opposite). **You need to confirm which handing convention DSLD/your millwork P.O.s use.**

Note: mirrored plan versions flip every door's hand — SCH counts whatever region you select, so select the base version (or the version the schedule describes).

## 4. Cased openings + 4"/6" wall detection

- No dedicated cased-opening tag exists. In the drawings they are: **`TK_Arch` family door styles** (Arch / Arch-Trim / Arch-Structure / Arch-Trim-Structure, drawn on `A-Door-Arch`), possibly **AEC Opening objects** (`AecDbOpening` class is registered), and at least once a plain MTEXT `8080` on `A-Door-Iden`.
- SCH treats as cased: any `AecDbOpening`, plus any door whose style name contains "ARCH".
- **Wall size:** DSLD wall styles are mostly variable-width (`TK_Stud-X ...`) — only `TK_Stud-3.5 Brick` / `TK_Stud-5.5 Brick` encode width in the name. The opening endcap styles come in exactly two flavors (3.5 / 5.5), confirming the two wall families. So SCH finds the **nearest AEC wall** to each cased opening and reads its **Width property**: `< 5.0"` → 4" wall, `≥ 5.0"` → 6" wall (threshold configurable). Result goes into the description: `CASED OPENING - 6" WALL`.

## 5. Drawing organization gotchas (handled in the design)

- **12 plan copies per construct** (6 variants × LH/RH mirror pairs) — SCH scopes by a window selection of ONE plan copy, so counts aren't multiplied.
- **Xref web:** doors/windows often live in an xref (e.g., the Schedule construct xrefs Exterior). SCH walks xref block contents, transforms positions through the xref insert (including mirror scales), and keeps what falls inside your selection window. Limitation: geometric hand detection is skipped for xref-resident doors (can't safely explode inside an xref) — run SCH in the construct that owns the doors for full LH/RH counts.
- **Elevation callout bubbles** (`ViewNumber` A–G on `A-Detl-Iden`) look like window marks — SCH filters by block/object type, never by "circle with a letter."
- Size-code parsing handles `2668` (2'-6"×6'-8"), `8080`, 5-digit garage codes (`16070` = 16'-0"×7'-0"), and `DBL.`/`2-` doubles (width doubled, like your existing "DBL. 2068 → 4'-0"" row).

## 6. Existing LISP inventory

- `E:\Megans lisp routines` — **empty** (assumed to be the home for this new tool; SCH.lsp now lives there).
- No schedule-filling routine exists anywhere on the machine. Closest prior art: `AI drafting software\src\lisp\bricscad\openings.lsp` (parses WWWH text callouts + swing arcs, but BricsCAD/text-based — different data model).
- `Documents\acad.lsp` / `acaddoc.lsp` auto-load the Enhanced Takeoff plugin at startup (unrelated, but be aware they run in ACA too).
- Schedule sheet naming varies by family: `Schedule of Openings-Parent-A` (Carlton/Calmore/Oxford) vs `A-601 Schedules` (Shefford/Sanford) vs `K4 FINISHES AND SCHEDULE` (townhomes) — SCH is naming-agnostic since you pick the tables.

## 7. The big caveat → SCHDIAG

**Every DXF on this machine was ODA-converted with AEC objects dropped** — zero walls, doors, windows, or schedule tags survive as objects (only annotation, tables, and orphan block definitions). That's why the analysis leaned on dictionaries, palettes, and the one file with live tag INSERTs.

So the parts of SCH that touch live AEC objects (property sets, door explode/hand, wall width) are written defensively with fallbacks, but **must be validated in real AutoCAD Architecture on a production DWG**. That's what `SCHDIAG` is for:

1. Open a real plan in ACA, `APPLOAD` → `SCH.lsp`, run **`SCHDIAG`**.
2. It prints a census (AEC doors/windows/openings/walls/tags/tables) and lets you click a few doors, a window, a cased opening, and a wall.
3. It writes `SCHDIAG-report.txt` next to the DWG — send that back, and the extraction layer gets hardened against exactly what your objects expose.

## 8. Proposed SCH workflow (implemented in v1)

```
SCH
 1. Window-select one plan version          → harvests doors/windows/openings
    (AEC objects, xref contents, or TK_ tag inserts as fallback)
 2. Pick the WINDOW SCHEDULE table
 3. Pick the DOOR SCHEDULE table
 4. PREVIEW DIALOG — every proposed row flagged:
      +  new row      ~  changes an existing row
      =  unchanged    !  needs attention (e.g., in table but not found)
    + choose LH/RH placement: new columns after QTY, or appended to description
 5. Apply → writes cells (one undo step) or Cancel → nothing touched
```
Existing descriptions are never clobbered; QTY/WIDTH/HEIGHT update in place; new marks fill the pre-allocated blank rows or append.

## 9. Open questions for you

1. **LH/RH placement** — new LH/RH columns in the door schedule, or appended to DESCRIPTION? (Both are built; which should be the default?)
2. **Handing convention** — confirm DSLD's rule (current default: viewer on the side the door swings *away* from, hinge left = LH).
3. **Cased-opening practice** — are they drawn as TK_Arch doors, AEC Openings, or sometimes just MTEXT? (SCHDIAG on one will answer this.)
4. **Wall text format** — is `CASED OPENING - 6" WALL` the wording you want in the description?
5. **A production DWG** (not ODA DXF) of any plan — or just run SCHDIAG in ACA and send the report. This is the single most useful thing you can provide.
6. Should windows ever get LH/RH too (e.g., casements), or doors only? (Current library is 100% double-hung, so v1 does doors only.)
