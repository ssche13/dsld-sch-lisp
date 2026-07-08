# SCH on AutoCAD — Findings & Fix Plan

*Written 2026-07-08, carrying over everything learned in the RPR (roof-pitch-rafters) cross-CAD round. Companion to `README.md`, `SCH_DISCOVERY_REPORT.md`, and `SCHPROBE.lsp`. SCH.lsp is v2.7.*

---

## 0. The one-paragraph answer

SCH's **code** is already cross-CAD-clean — I verified the whole load path. So "crashes AutoCAD on startup" is almost certainly a **load-mechanism** problem, not a bug in the text, and the single highest-value change is to **stop SCH from writing itself into `acaddoc.lsp` at load time**. That auto-install is what turns any one-time load failure into a crash on *every* drawing open that survives removing SCH from the Startup Suite. Make install an explicit command (`SCHINSTALL`) instead. The most likely trigger of the crash itself is AutoCAD's **`SECURELOAD` / Trusted Locations** gate (BricsCAD has no equivalent), followed by a **stale/duplicate autoload of an old or email-corrupted copy**.

---

## 1. What I verified about the load path (why the crash isn't the code text)

I read every top-level form that executes when SCH.lsp loads. There are only four kinds, and none of them can hard-crash on their own:

1. `(vl-load-com)` (line 39) — standard.
2. Config `(setq ...)` of literal data (lines 45–116) — inert.
3. `(princ "[SCH] v2.7 loaded...")` (line 2366) — inert.
4. `(vl-catch-all-apply 'sch:autoinstall)` (line 2370) — the only side-effecting form.

Additional checks, all clean:
- **Parens balance** (string/comment-aware), **no BOM**, paths written into `acaddoc.lsp` use **forward slashes** (`sch:slash`, line 2182) — so the classic `"C:\Users\..."` backslash-escape footgun is already avoided.
- **The AecX COM bridge** (`sch:sched-app`, line 300) and the **door-explode swing detection** are gated by `*sch:use-aecx*` / `*sch:use-explode*` and only run *inside the SCH/SCHDIAG commands*, never at load. Both cache their failure so they can't retry-crash.
- **Zero `(command …)` calls** in the entire file, and **no reactors** (`vlr-*`). So the two biggest RPR-round AutoCAD hazards — `(command)` inside a reactor, and AutoCAD refusing to invoke LISP commands via `(command "_.NAME")` — simply don't apply to SCH.
- **Table + layer creation is ActiveX** (`AddTable` 1252, `SetText`/`SetTextString` 1168, `vla-Add` 1239), **not `entmake`.** This is exactly the fix we had to *retrofit* into RPR this round (see §3). SCH already does it right.

**Conclusion:** loading the v2.7 text should produce, at worst, a command-line *error* — not a crash. A hard crash points at the environment or the load mechanism. This is the same conclusion the README reached independently, and it's why `SCHPROBE.lsp` exists.

---

## 2. Ranked diagnosis of the startup crash

| # | Cause | Why it fits "BricsCAD fine, AutoCAD crashes on startup" | Confidence |
|---|---|---|---|
| 1 | **`SECURELOAD` / untrusted path** | AutoCAD gates loading LISP from folders not in **Trusted Locations**. `SECURELOAD=2` silently refuses; `=1` pops a modal warning that can open **off-screen** (unplugged 2nd monitor) and look exactly like a freeze/crash. **BricsCAD has no such gate** — so it "just works" there. SCH lives on `E:\` / OneDrive / a network path → untrusted by default. | **High** |
| 2 | **Self-writing `acaddoc.lsp` reloading a stale/broken copy** | `sch:autoinstall` appends a `(load "…SCH.lsp")` into `acaddoc.lsp` (2214–2224), which AutoCAD runs on **every drawing open**. If an *older* SCH.lsp (or an email-mangled one) is what that line points at, the crash recurs on every startup — and removing SCH from the Startup Suite doesn't stop it. `SCHPROBE` specifically audits `acaddoc.lsp` for duplicate `SCH-AUTOLOAD` markers for this reason. | **High** |
| 3 | **Email/Word-corrupted file** | Megan receives copies by email (the RPR distribution pattern). Pasting LISP through email/Word turns `"` into smart quotes, wraps long lines, and can change encoding — producing a parse failure that AutoCAD handles worse than BricsCAD. README and SCHPROBE both warn: **download fresh from GitHub, never use an emailed copy.** For SCH this is easy because the repo is **public** (see §5). | **Medium-High** |
| 4 | **Antivirus quarantine** | Writing to `acaddoc.lsp` at load resembles ALisp-virus behavior; corporate AV can quarantine the file mid-load and take the session down. Add the folder to AV exclusions. | **Medium** |
| 5 | **ACA AEC object-enabler crash at drawing-open** | ACA loads its AEC enablers at the same moment `acaddoc.lsp` runs, so an enabler/version problem *looks* like the LISP crashed. Test: rename `acaddoc.lsp` — if ACA still dies, it's the install, not SCH. Crash dumps land in `%LOCALAPPDATA%\Autodesk` (`acad.err`, `.dmp`). | **Low-Medium** |

The definitive locator already exists: **`SCHPROBE.lsp`** loads SCH one form at a time with a flushed log and reports `SECURELOAD`/`TRUSTEDPATHS`/`LISPSYS` + the `acaddoc.lsp` audit. Run it on Megan's seat and read the last log line — it names the exact culprit.

---

## 3. What the RPR round proved, applied to SCH

The roof routine and the schedule routine share the same two-CAD constraint, so the lessons transfer directly:

- **`entmake` is stricter on AutoCAD 2025 than BricsCAD.** RPR's minimal SOLID-hatch `entmake` list is *accepted by BricsCAD and rejected by AutoCAD 2025* (proven by field `RPRDIAG`: 14 refusals, live-test FAILED). The fix was to fall back to an **ActiveX** creation path (`vla-AddHatch`). **SCH already builds its tables via ActiveX `AddTable`, so it sidesteps this entirely** — keep it that way. *If you ever add `entmake` of any object to SCH, ladder it to an ActiveX fallback the way RPR now does.*
- **COM `:vlax-false` coercion needs `vlax-invoke-method`, not plain `vlax-invoke`.** SCH already uses `vlax-invoke-method` in `sch:http-get` (line 2258) — correct.
- **`accoreconsole` cannot run ACA LISP** (no ActiveX, no interactive input) — established this round. So, exactly like RPR, **SCH's AutoCAD side cannot be auto-regression-tested**; it's validated manually via `SCHDIAG` on a real ACA seat. The BricsCAD `SCHTEST.lsp` suite is the automated safety net; AutoCAD is confirmed by field report.
- **Put the version in a per-command banner.** RPR now prints `[RPR v1.9.x]` at the *start of the command* because auto-update/version lag repeatedly caused us to debug the wrong build. SCH prints its version only at *load* (line 2366). **Add `(princ "\n[SCH v2.7]")` as the first line of `c:SCH` and `c:SCHDIAG`** so every field report names the build that actually ran.
- **Version-stamped filename for at-a-glance identity.** RPR now keeps a `roof-pitch-rafters-v<ver>.lsp` copy beside the plain file so you can see which version is current without opening it. Worth doing for SCH too — but the loaded file must stay `SCH.lsp` (auto-load + `SCHUPDATE` find it by name).

---

## 4. Census: real AEC data for SCH (new this round — closes the discovery report's big caveat)

`SCH_DISCOVERY_REPORT.md` §7 flagged that *every DXF on the machine had its AEC objects stripped by the ODA conversion*, so the door/window/wall reading "must be validated in real ACA." This round I censused the **actual production DWGs** (not DXFs) — the same Timsbury family SCH targets — by true `vla-get-ObjectName`. The AEC objects are intact and measurable:

| Drawing | Live AEC objects present |
|---|---|
| Exterior-Parent-A | **676 `AecDbWall`, 491 `AecDbWindow`, 162 `AecDbDoor`, 1260 `AecDbMvBlockRef`** (the TK_ tags) |
| Interior-Parent-A | 640 `AecDbWall`, 336 `AecDbDoor`, 672 `AecDbMvBlockRef` |
| Foundation-Parent-A | 1376 `AecDbWall` |
| Roof-Parent-A | none (pure `AcDbLine`/`AcDbPolyline`) — this is why RPR never sees AEC objects |

**Measured LISP behavior on AEC objects (BricsCAD V26 — confirm on native ACA via SCHDIAG):**
- `entget` on an AEC door/window/wall returns **~1 usable group** — i.e. `entget` is useless for reading them. **You must read via ActiveX properties / property sets, which SCH already does.** Good.
- AEC objects are **NOT** caught by an `ssget` DXF-type filter like `(0 . "LINE,LWPOLYLINE,ARC,…")`. So SCH must select them by **`vla-get-ObjectName`** (`AecDbDoor` etc.) or by the `AEC_*` DXF class names that native ACA exposes — never by a plain-entity type filter. (This also means SCH's selection can't accidentally scoop AEC objects into a plain-entity pass, and vice-versa — filter deliberately.)
- `vla-GetBoundingBox` works; `vlax-curve-getEndParam` works in BricsCAD (may differ on native ACA — the explode fallback exists precisely because ACA can be touchier).
- **The TK_ door/window tags are `AecDbMvBlockRef` (multi-view blocks), not plain `INSERT`s, on live drawings.** SCH's "plain INSERT of `TK_*_Tag`" path (discovery report §1, config `*sch:tagpair-dist*`) therefore only fires on **flattened/exported** drawings. On a live ACA plan (and even BricsCAD reading a live DWG), the **primary path — AEC objects + property sets — is what runs**, so that path is the one to harden first via SCHDIAG.

**Net for SCH:** the primary extraction path (AEC objects → ActiveX properties / property sets) is the correct one and is what production drawings actually require; the INSERT-tag fallback is for flattened files only. Validate the property-set names (`DSLD_NUMBER`, `StandardSizeDescription`, any `*SWING*`/`*HAND*`) against Megan's seat with SCHDIAG — that's the last unknown, same as it was for the discovery report.

---

## 5. Distribution — SCH is better off than RPR here

The **`ssche13/dsld-sch-lisp` repo is PUBLIC** (verified). This matters:
- **`SCHUPDATE` actually works** (it fetches raw GitHub). RPR's repo is *private*, so RPR's auto-updater silently 404s on every machine and updates are hand-carried — SCH does not have that problem.
- So the fix for the "email-corrupted copy" crash vector is simply: **Megan downloads `SCH.lsp` + `SCHPROBE.lsp` fresh from the repo** (Code → Download ZIP), never an emailed copy. Then `SCHUPDATE` keeps her current.

*(If you later make the RPR repo public too, RPR's dormant auto-updater comes alive the same way — see the RPR notes.)*

---

## 6. Hardening checklist for SCH.lsp (ranked by value ÷ risk)

1. **Make auto-install opt-in.** Move the `acaddoc.lsp` write out of the load-time `(vl-catch-all-apply 'sch:autoinstall)` (line 2370) into a new `c:SCHINSTALL` command. On load, if not installed, just `princ` a one-line hint ("Run SCHINSTALL to load SCH automatically"). *This is the single most important change* — it removes the mechanism that makes a crash permanent and inescapable, and eliminates load-time file I/O entirely.
2. **Per-command version banner.** First line of `c:SCH` / `c:SCHDIAG`: `(princ "\n[SCH v2.7]")`. Ends version-lag guesswork in field reports.
3. **Self-heal duplicate autoloads.** When `SCHINSTALL` runs (or on load, read-only), detect and collapse multiple `SCH-AUTOLOAD` markers in `acaddoc.lsp` to one — SCHPROBE already knows how to find them.
4. **Load-time SECURELOAD hint.** In the load banner, if `(getvar "SECURELOAD")` > 0 and the folder isn't trusted, print a one-line note pointing at Options → Files → Trusted Locations. Cheap, and it pre-empts the #1 crash.
5. **Keep the AecX / explode gates and `sch:catch` wrapping** exactly as they are — they're the right defensive posture for the parts that touch live ACA COM.
6. **Do NOT add any `entmake` of AEC-ish objects or hatches** without an ActiveX fallback (the RPR lesson). SCH's all-ActiveX table path is already correct.

None of these change behavior on BricsCAD (where it all works today); they harden the AutoCAD load path and the diagnostics.

---

## 7. Runbook for Megan (get it loading, then validate the data)

**A. Break any existing crash loop first**
1. If ACA crashes the instant a drawing opens: find `acaddoc.lsp` (search the support paths, or read `SCHPROBE-log.txt` if you got one) and **delete the two lines including the `;; SCH-AUTOLOAD` marker.** That stops the auto-reload. (Or run `SCHUNINSTALL` from any session that manages to load.)
2. Temporarily rename `acaddoc.lsp` → if ACA *still* crashes on drawing-open, the problem is the ACA install / AEC enablers, not SCH.

**B. Load it cleanly**
3. Download **fresh** `SCH.lsp` + `SCHPROBE.lsp` from `github.com/ssche13/dsld-sch-lisp` (Code → Download ZIP). Do **not** use an emailed copy.
4. Put both in one folder and add that folder to **Options → Files → Trusted Locations** (this is what prevents the SECURELOAD off-screen-dialog "freeze").
5. `APPLOAD` → `SCHPROBE.lsp`. If it prints **DONE**, SCH loaded fine — run `SCH`. If ACA dies, reopen the folder and **email back `SCHPROBE-log.txt`** — its last line names the exact form that killed it.

**C. Validate the AEC extraction (the last real unknown)**
6. Open a real plan (the Exterior or Interior construct — that's where the doors/windows/walls live), run **`SCHDIAG`**, and send back `SCHDIAG-report.txt`. That confirms the property-set names and object properties on Megan's actual ACA seat, which is the one thing no amount of BricsCAD testing or web research can settle.

---

*Bottom line: SCH is architecturally in good shape for AutoCAD — ActiveX-based, command-free, COM-guarded. Ship the opt-in-install change and the version banner, get Megan on a Trusted-Location fresh download, and use SCHPROBE + SCHDIAG to close the last environment-specific unknowns. Nothing here requires forking the file for the two CADs — one SCH.lsp runs on both, same as RPR.*
