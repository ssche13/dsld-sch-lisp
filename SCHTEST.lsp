;;; ===================================================================
;;; SCHTEST.lsp - automated regression tests for SCH.lsp
;;; Load SCH.lsp first, then this file. Command: SCHTEST
;;; Works in BricsCAD and AutoCAD. Non-interactive (safe for scripts).
;;;
;;; Unit tests need no drawing content. Integration tests expect the
;;; current drawing to contain TK_* tag INSERTs and a WINDOW SCHEDULE
;;; ACAD_TABLE (e.g. a COPY of "Sch. Of Openings.dxf") - they MODIFY
;;; the table, so never run on a production drawing.
;;;
;;; Results: SCHTEST-log.txt next to the drawing (flushed per line).
;;; ===================================================================

(setq *tst:path* nil)
(setq *tst:pass* 0)
(setq *tst:fail* 0)

(defun tst:out (msg / fh)
  (princ (strcat "\n" msg))
  (if *tst:path*
    (progn
      (setq fh (open *tst:path* "a"))
      (if fh (progn (write-line msg fh) (close fh)))))
  (princ))

;; tolerant deep-equal: numbers compare with fuzz, lists recurse
(defun tst:eq (a b)
  (cond
    ((and (numberp a) (numberp b)) (equal a b 1e-4))
    ((and (listp a) (listp b) (not (null a)) (not (null b)))
     (and (tst:eq (car a) (car b)) (tst:eq (cdr a) (cdr b))))
    (t (equal a b))))

(defun tst:assert (label got want)
  (if (tst:eq got want)
    (progn
      (setq *tst:pass* (1+ *tst:pass*))
      (tst:out (strcat "  PASS  " label)))
    (progn
      (setq *tst:fail* (1+ *tst:fail*))
      (tst:out (strcat "  FAIL  " label
                       "  got=" (vl-princ-to-string got)
                       "  want=" (vl-princ-to-string want)))))
  (princ))

;;; ------------------------------------------------------------------
;;; Unit tests (no drawing content required)
;;; ------------------------------------------------------------------

(defun tst:units ( / old)
  ;; --- size-code parser ---
  (tst:assert "parse 2668" (sch:parse-size "2668") (list 1 30.0 80.0))
  (tst:assert "parse 2040" (sch:parse-size "2040") (list 1 24.0 48.0))
  (tst:assert "parse 8080" (sch:parse-size "8080") (list 1 96.0 96.0))
  (tst:assert "parse 16070" (sch:parse-size "16070") (list 1 192.0 84.0))
  (tst:assert "parse DBL. 2068" (sch:parse-size "DBL. 2068")
              (list 2 24.0 80.0))
  (tst:assert "parse 2-2668" (sch:parse-size "2-2668") (list 2 30.0 80.0))
  (tst:assert "parse 100 -> nil" (sch:parse-size "100") nil)
  (tst:assert "parse 00 -> nil" (sch:parse-size "00") nil)
  (tst:assert "parse TWIN text -> nil" (sch:parse-size "TWIN 3'-0\"") nil)
  (tst:assert "parse empty -> nil" (sch:parse-size "") nil)
  (tst:assert "parse 8x7 garage" (sch:parse-size "8x7") (list 1 96.0 84.0))
  (tst:assert "parse 16x7 garage" (sch:parse-size "16x7")
              (list 1 192.0 84.0))
  (tst:assert "parse 3x4 window" (sch:parse-size "3x4") (list 1 36.0 48.0))
  ;; --- feet-inch formatter ---
  (tst:assert "ftin 30" (sch:ftin 30.0) "2'-6\"")
  (tst:assert "ftin 96" (sch:ftin 96.0) "8'-0\"")
  (tst:assert "ftin 24" (sch:ftin 24.0) "2'-0\"")
  (tst:assert "ftin 35.9999 carries" (sch:ftin 35.9999) "3'-0\"")
  (tst:assert "ftin 84" (sch:ftin 84.0) "7'-0\"")
  ;; --- mtext stripper ---
  (tst:assert "strip stacked fraction"
              (sch:strip-fmt "\\A1;{\\H0.7x;\\S4#4;} EQ. SASH")
              "4/4 EQ. SASH")
  (tst:assert "strip color override"
              (sch:strip-fmt "{\\C256;6 LITE FIXED}")
              "6 LITE FIXED")
  (tst:assert "strip line break keeps text"
              (sch:strip-fmt "SOLID CORE\\PWOOD")
              "SOLID CORE WOOD")
  (tst:assert "strip plain passthrough"
              (sch:strip-fmt "2'-8\"")
              "2'-8\"")
  (tst:assert "strip nil -> empty" (sch:strip-fmt nil) "")
  ;; --- hand-clause stripper ---
  (tst:assert "strip-hand suffix"
              (sch:strip-hand "INT. GRADE - 2 LH / 3 RH")
              "INT. GRADE")
  (tst:assert "strip-hand whole" (sch:strip-hand "2 LH / 3 RH") "")
  (tst:assert "strip-hand none" (sch:strip-hand "PLAIN DESC") "PLAIN DESC")
  ;; --- swing-hand math ---
  ;; wall along +X from (0,0)-(100,0); hinge (30,0); arc r=30.
  ;; arc 0..90deg: strike at (60,0), swings up (+Y). Viewer stands on
  ;; -Y (door opens away); viewer's left = -X; hinge at west end -> LH
  (tst:assert "hand-calc LH"
              (sch:hand-calc (list 30.0 0.0) 30.0 0.0 (/ pi 2.0)
                             (list 0.0 0.0) (list 100.0 0.0))
              "LH")
  ;; arc 90..180deg: strike at (0,0), swings up. hinge at east end -> RH
  (tst:assert "hand-calc RH"
              (sch:hand-calc (list 30.0 0.0) 30.0 (/ pi 2.0) pi
                             (list 0.0 0.0) (list 100.0 0.0))
              "RH")
  ;; TOWARD convention flips the answer
  (setq old *sch:hand-convention*)
  (setq *sch:hand-convention* "TOWARD")
  (tst:assert "hand-calc TOWARD flips"
              (sch:hand-calc (list 30.0 0.0) 30.0 0.0 (/ pi 2.0)
                             (list 0.0 0.0) (list 100.0 0.0))
              "RH")
  (setq *sch:hand-convention* old)
  ;; --- probe hand decision (wall +X, swing up/+Y) ---
  (tst:assert "probe-decide hinge west = LH"
              (sch:probe-decide 0.0 32.0 0.0
                                (list 0.0 1.0) (list 1.0 0.0))
              "LH")
  (tst:assert "probe-decide hinge east = RH"
              (sch:probe-decide 0.0 32.0 32.0
                                (list 0.0 1.0) (list 1.0 0.0))
              "RH")
  (setq *sch:hand-convention* "TOWARD")
  (tst:assert "probe-decide TOWARD flips"
              (sch:probe-decide 0.0 32.0 0.0
                                (list 0.0 1.0) (list 1.0 0.0))
              "RH")
  (setq *sch:hand-convention* old)
  ;; swing-down mirror case: hinge east, opens toward -Y = LH
  (tst:assert "probe-decide swing-down hinge east = LH"
              (sch:probe-decide 0.0 32.0 32.0
                                (list 0.0 -1.0) (list 1.0 0.0))
              "LH")
  ;; --- insert transform ---
  (tst:assert "xform translate"
              (sch:xform-pt (list 10.0 5.0) (list 100.0 200.0) 0.0 1.0 1.0)
              (list 110.0 205.0))
  (tst:assert "xform mirror-x"
              (sch:xform-pt (list 10.0 5.0) (list 100.0 200.0) 0.0 -1.0 1.0)
              (list 90.0 205.0))
  (tst:assert "xform rot90"
              (sch:xform-pt (list 10.0 5.0) (list 100.0 200.0)
                            (/ pi 2.0) 1.0 1.0)
              (list 95.0 210.0))
  ;; --- misc ---
  (tst:assert "wall-class 4" (sch:wall-class (list nil nil 4.5)) "4")
  (tst:assert "wall-class 6" (sch:wall-class (list nil nil 5.5)) "6")
  (tst:assert "cased desc"
              (sch:cased-desc "6") "CASED OPENING - 6\" WALL")
  ;; --- auto descriptions ---
  (tst:assert "auto-desc garage style"
              (sch:auto-desc "DOOR" "TK_Garage-Brick" 1 192.0 84.0)
              "OVERHEAD GARAGE DOOR")
  (tst:assert "auto-desc garage by size"
              (sch:auto-desc "DOOR" "" 1 96.0 84.0)
              "OVERHEAD GARAGE DOOR")
  (tst:assert "auto-desc exterior"
              (sch:auto-desc "DOOR" "TK_S-Hinged-Exterior-Brick-Trim"
                             1 36.0 80.0)
              "EXT. GRADE - FIBERGLASS")
  (tst:assert "auto-desc interior catalog"
              (sch:auto-desc "DOOR" "TK_S-Hinged-Trim" 1 32.0 80.0)
              "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")
  (tst:assert "auto-desc front door by size"
              (sch:auto-desc "DOOR" "" 1 36.0 80.0)
              "4 LITE EXT. GRADE W/ BOTTOM PANEL")
  (tst:assert "auto-desc double catalog"
              (sch:auto-desc "DOOR" "TK_D-Hinged-Trim" 2 48.0 80.0)
              "DBL. 4068 INT. GRADE - HOLLOW CORE - SEE P.O.")
  (tst:assert "auto-desc window catalog"
              (sch:auto-desc "WINDOW" "TK_Double-Hung" 1 36.0 72.0)
              "1/1 EQ. SASH - VINYL SINGLE HUNG")
  (tst:assert "auto-desc window fixed by size"
              (sch:auto-desc "WINDOW" "" 1 36.0 36.0)
              "FIXED - OBSCURE - TEMPERED")
  (tst:assert "auto-desc sliding"
              (sch:auto-desc "DOOR" "TK_DoorWall-Center-Brick-Trim"
                             1 72.0 80.0)
              "SLIDING GLASS DOOR")
  ;; --- measured-size snapping (casing math from the libraries) ---
  (tst:assert "snap door 40 incl casing -> 2'-8\""
              (sch:snap-std "DOOR" 40.0 80.0 T nil)
              (list 32.0 80.0
                    "INTERIOR GRADE - HOLLOW CORE - SEE P.O." T))
  (tst:assert "snap window 43 incl casing -> 3'-0\"x6'-0\""
              (sch:snap-std "WINDOW" 43.0 72.0 T nil)
              (list 36.0 72.0 "1/1 EQ. SASH - VINYL SINGLE HUNG" T))
  (tst:assert "snap garage 195 -> 16'x7'"
              (sch:snap-std "DOOR" 195.0 nil T nil)
              (list 192.0 84.0 "OVERHEAD GARAGE DOOR" T))
  (tst:assert "snap cased opening no allowance"
              (sch:snap-std "DOOR" 42.0 96.0 T T)
              (list 42.0 96.0 "CASED OPENING" T))
  (tst:assert "snap non-standard does not snap"
              (cadddr (sch:snap-std "DOOR" 55.0 80.0 nil nil))
              nil)
  (princ))

;;; ------------------------------------------------------------------
;;; Integration tests (drawing with TK_ tags + window schedule table)
;;; ------------------------------------------------------------------

;; find the first ACAD_TABLE whose title matches pat -> (tbl info) or nil
(defun tst:find-table (pat / ss i tbl info out)
  (setq ss (ssget "_X" '((0 . "ACAD_TABLE"))))
  (if ss
    (progn
      (setq i 0)
      (while (and (< i (sslength ss)) (null out))
        (setq tbl (sch:vla (ssname ss i))
              info (sch:table-info tbl))
        (if (wcmatch (strcase (car info)) pat)
          (setq out (list tbl info)))
        (setq i (1+ i)))))
  out)

;; build a synthetic harvest record (same shape as sch:harvest-aec)
(defun tst:make-rec (kind mark code mult win hin hand cased wall)
  (list (cons "KIND" kind) (cons "MARK" mark) (cons "CODE" code)
        (cons "MULT" mult) (cons "WIN" win) (cons "HIN" hin)
        (cons "HAND" hand) (cons "CASED" cased) (cons "WALL" wall)
        (cons "STYLE" "") (cons "SRC" "test")))

(defun tst:dump-table (tbl info label / r c row rows cols)
  (setq rows (nth 3 info) cols (nth 4 info) r 0)
  (tst:out (strcat "  -- table dump " label " ("
                   (itoa rows) "x" (itoa cols) ") --"))
  (while (< r rows)
    (setq c 0 row "")
    (while (< c cols)
      (setq row (strcat row (sch:strip-fmt (sch:tbl-get tbl r c)) " | "))
      (setq c (1+ c)))
    (tst:out (strcat "    [" (itoa r) "] " row))
    (setq r (1+ r)))
  (princ))

(defun tst:integration ( / ss i v ins recs aggs a tbl info plan pE
                           written rowE pair recs2 aggs2 plan2 p2
                           info2w rF)
  ;; harvest all TK_ tag inserts in model space
  (setq ss (ssget "_X" '((0 . "INSERT") (2 . "TK_*") (410 . "Model"))))
  (if (null ss)
    (tst:out "  SKIP integration: no TK_* tag INSERTs in this drawing")
    (progn
      (tst:out (strcat "  found " (itoa (sslength ss)) " TK_ tag inserts"))
      (setq i 0 ins nil)
      (while (< i (sslength ss))
        (setq v (sch:vla (ssname ss i)))
        (setq ins (cons (cons v (sch:catch 'vlax-safearray->list
                                  (list (vlax-variant-value
                                          (vla-get-InsertionPoint v)))))
                        ins))
        (setq i (1+ i)))
      (setq ins (vl-remove-if '(lambda (x) (null (cdr x))) ins))
      (setq recs (sch:harvest-tag-inserts ins))
      (tst:assert "tag records (one per mark bubble)" (length recs) 2)
      (foreach r recs
        (tst:assert "tag KIND" (sch:rget r "KIND") "WINDOW")
        (tst:assert "tag MARK" (sch:rget r "MARK") "E")
        (tst:assert "tag CODE paired" (sch:rget r "CODE") "2040")
        (tst:assert "tag WIN" (sch:rget r "WIN") 24.0)
        (tst:assert "tag HIN" (sch:rget r "HIN") 48.0))
      ;; aggregate
      (setq aggs (sch:aggregate recs "WINDOW"))
      (tst:assert "agg rows" (length aggs) 1)
      (setq a (car aggs))
      (tst:assert "agg mark" (car a) "E")
      (tst:assert "agg qty" (nth 3 a) 2)
      (tst:assert "agg width in" (cadr a) 24.0)
      (tst:assert "agg height in" (caddr a) 48.0)
      ;; table
      (setq pair (tst:find-table "*WINDOW*"))
      (if (null pair)
        (tst:out "  SKIP table tests: no WINDOW SCHEDULE table in this drawing")
        (progn
          (setq tbl (car pair)
                info (cadr pair))
          (tst:out (strcat "  table title: \"" (car info) "\""))
          (tst:assert "title contains WINDOW"
                      (if (wcmatch (strcase (car info)) "*WINDOW*") T nil) T)
          (tst:assert "header row found" (if (cadr info) T nil) T)
          (tst:assert "col MARK mapped" (if (sch:col info "MARK") T nil) T)
          (tst:assert "col WIDTH mapped" (if (sch:col info "WIDTH") T nil) T)
          (tst:assert "col HEIGHT mapped" (if (sch:col info "HEIGHT") T nil) T)
          (tst:assert "col QTY mapped" (if (sch:col info "QTY") T nil) T)
          (tst:assert "col DESCRIPTION mapped"
                      (if (sch:col info "DESCRIPTION") T nil) T)
          (tst:dump-table tbl info "BEFORE")
          ;; merge
          (setq plan (sch:merge tbl info aggs "WINDOW"))
          (tst:out (strcat "  plan: " (vl-princ-to-string plan)))
          (setq pE nil)
          (foreach p plan (if (= (cadr p) "E") (setq pE p)))
          (tst:assert "plan has row E" (if pE T nil) T)
          (if pE
            (progn
              (tst:assert "row E planned qty" (nth 4 pE) "2")
              (tst:assert "row E matched existing (not +)"
                          (if (car pE) T nil) T)
              (tst:assert "row E keeps existing desc"
                          (nth 7 pE) nil)))
          ;; apply
          (setq *sch:handmode* "cols")
          (setq written (sch:apply-plan tbl info plan "WINDOW"))
          (tst:out (strcat "  rows written: " (itoa written)))
          (tst:assert "at least one row written" (>= written 1) T)
          ;; verify cells after
          (setq info (sch:table-info tbl))
          (setq rowE (cdr (assoc "E" (nth 5 info))))
          (tst:assert "row E present after apply" (if rowE T nil) T)
          (if rowE
            (progn
              (tst:assert "E QTY cell = 2"
                          (sch:strip-fmt
                            (sch:tbl-get tbl rowE (sch:col info "QTY")))
                          "2")
              (tst:assert "E WIDTH cell"
                          (sch:strip-fmt
                            (sch:tbl-get tbl rowE (sch:col info "WIDTH")))
                          "2'-0\"")
              (tst:assert "E HEIGHT cell"
                          (sch:strip-fmt
                            (sch:tbl-get tbl rowE (sch:col info "HEIGHT")))
                          "4'-0\"")
              (tst:assert "E DESCRIPTION preserved"
                          (sch:strip-fmt
                            (sch:tbl-get tbl rowE
                                         (sch:col info "DESCRIPTION")))
                          "6 LITE FIXED")))
          (tst:dump-table tbl info "AFTER")
          ;; second pass: a brand-new window size must adopt the first
          ;; pre-filled spare mark (F) instead of inventing a new one
          (setq info (sch:table-info tbl))
          (setq recs2 (list (tst:make-rec "WINDOW" "" "3050" 1
                                          36.0 60.0 nil nil nil)))
          (setq aggs2 (sch:aggregate recs2 "WINDOW"))
          (setq plan2 (sch:merge tbl info aggs2 "WINDOW"))
          (tst:out (strcat "  spare plan: " (vl-princ-to-string plan2)))
          (setq p2 (car plan2))
          (tst:assert "new window adopts spare mark F" (cadr p2) "F")
          (sch:apply-plan tbl info plan2 "WINDOW")
          (setq info2w (sch:table-info tbl))
          (tst:assert "window table did not grow"
                      (nth 3 info2w) (nth 3 info))
          (setq rF (cdr (assoc "F" (nth 5 info2w))))
          (tst:assert "row F present" (if rF T nil) T)
          (if rF
            (progn
              (tst:assert "row F WIDTH"
                          (sch:strip-fmt
                            (sch:tbl-get tbl rF (sch:col info2w "WIDTH")))
                          "3'-0\"")
              (tst:assert "row F HEIGHT"
                          (sch:strip-fmt
                            (sch:tbl-get tbl rF (sch:col info2w "HEIGHT")))
                          "5'-0\"")
              (tst:assert "row F QTY"
                          (sch:strip-fmt
                            (sch:tbl-get tbl rF (sch:col info2w "QTY")))
                          "1")))
          (tst:dump-table tbl info2w "AFTER SPARE ADOPTION")))))
  (princ))

;; Door-table integration: uses SYNTHETIC records (no doors needed in
;; the drawing) against a real DOOR SCHEDULE table. Exercises LH/RH
;; column insertion, hand-count cells, cased-opening desc updates,
;; and appending a brand-new row.
(defun tst:integration-door ( / pair tbl info recs aggs plan written
                                info2 r5 r10 rNew rowsBefore had3080
                                hadblank m r wtxt htxt)
  (setq pair (tst:find-table "*DOOR*"))
  (if (null pair)
    (tst:out "  SKIP door tests: no DOOR SCHEDULE table in this drawing")
    (progn
      (setq tbl (car pair) info (cadr pair)
            rowsBefore (nth 3 info))
      (tst:dump-table tbl info "DOOR BEFORE")
      ;; note pre-existing 3'-0"x8'-0" rows and blank spare rows
      ;; (both affect the new-row expectations below)
      (setq had3080 nil hadblank nil)
      (foreach m (nth 5 info)
        (setq wtxt (sch:strip-fmt (sch:tbl-get tbl (cdr m)
                                               (sch:col info "WIDTH")))
              htxt (sch:strip-fmt (sch:tbl-get tbl (cdr m)
                                               (sch:col info "HEIGHT"))))
        (if (and (= wtxt "3'-0\"") (= htxt "8'-0\"")) (setq had3080 T))
        (if (and (= (car m) "") (= wtxt "")) (setq hadblank T)))
      (if had3080 (tst:out "  note: table already has a 3'-0\"x8'-0\" row"))
      (if hadblank (tst:out "  note: table has blank spare rows"))
      ;; synthetic harvest:
      ;;  5x mark 5 hinged 2'-8"x6'-8" (3 LH / 2 RH)
      ;;  1x cased opening 2'-8"x6'-8" in a 6" wall (no mark)
      ;;  1x new door 3'-0"x8'-0" LH (no mark, size not in table)
      (setq recs nil)
      (repeat 3 (setq recs (cons (tst:make-rec "DOOR" "5" "2868" 1
                                               32.0 80.0 "LH" nil nil)
                                 recs)))
      (repeat 2 (setq recs (cons (tst:make-rec "DOOR" "5" "2868" 1
                                               32.0 80.0 "RH" nil nil)
                                 recs)))
      (setq recs (cons (tst:make-rec "DOOR" "" "" 1 32.0 80.0
                                     nil T "6")
                       recs))
      (setq recs (cons (tst:make-rec "DOOR" "" "3080" 1 36.0 96.0
                                     "LH" nil nil)
                       recs))
      (setq aggs (sch:aggregate recs "DOOR"))
      (tst:assert "door agg rows" (length aggs) 3)
      (setq plan (sch:merge tbl info aggs "DOOR"))
      (tst:out (strcat "  door plan: " (vl-princ-to-string plan)))
      (setq *sch:handmode* "cols")
      (setq written (sch:apply-plan tbl info plan "DOOR"))
      (tst:out (strcat "  door rows written: " (itoa written)))
      (tst:assert "three rows written" written 3)
      (setq info2 (sch:table-info tbl))
      ;; LH/RH columns inserted after QTY
      (tst:assert "LH column inserted" (if (sch:col info2 "LH") T nil) T)
      (tst:assert "RH column inserted" (if (sch:col info2 "RH") T nil) T)
      (if (and (sch:col info2 "QTY") (sch:col info2 "LH"))
        (tst:assert "LH sits right after QTY"
                    (sch:col info2 "LH") (1+ (sch:col info2 "QTY"))))
      ;; mark 5: qty 5, 3 LH / 2 RH, description preserved
      (setq r5 (cdr (assoc "5" (nth 5 info2))))
      (tst:assert "door row 5 present" (if r5 T nil) T)
      (if r5
        (progn
          (tst:assert "door 5 QTY"
                      (sch:strip-fmt (sch:tbl-get tbl r5
                                                  (sch:col info2 "QTY")))
                      "5")
          (tst:assert "door 5 LH"
                      (sch:strip-fmt (sch:tbl-get tbl r5
                                                  (sch:col info2 "LH")))
                      "3")
          (tst:assert "door 5 RH"
                      (sch:strip-fmt (sch:tbl-get tbl r5
                                                  (sch:col info2 "RH")))
                      "2")))
      ;; cased opening matched an existing CASED row by size and got
      ;; the wall size appended to the description
      (setq r10 nil)
      (foreach m (nth 5 info2)
        (setq r (cdr m))
        (if (and (null r10)
                 (wcmatch (strcase (sch:strip-fmt
                             (sch:tbl-get tbl r
                                          (sch:col info2 "DESCRIPTION"))))
                          "*CASED*6\"*"))
          (setq r10 r)))
      (tst:assert "cased row updated with wall size" (if r10 T nil) T)
      (if r10
        (tst:assert "cased desc text"
                    (sch:strip-fmt (sch:tbl-get tbl r10
                                                (sch:col info2 "DESCRIPTION")))
                    "CASED OPENING - 6\" WALL"))
      ;; new 3'-0"x8'-0" door: appended as a new row (unless the table
      ;; already had that size, in which case it merged there)
      (setq rNew nil)
      (foreach m (nth 5 info2)
        (setq r (cdr m)
              wtxt (sch:strip-fmt (sch:tbl-get tbl r
                                               (sch:col info2 "WIDTH")))
              htxt (sch:strip-fmt (sch:tbl-get tbl r
                                               (sch:col info2 "HEIGHT"))))
        (if (and (null rNew) (= wtxt "3'-0\"") (= htxt "8'-0\""))
          (setq rNew r)))
      (tst:assert "new 3080 row present" (if rNew T nil) T)
      (if rNew
        (tst:assert "new 3080 qty"
                    (sch:strip-fmt (sch:tbl-get tbl rNew
                                                (sch:col info2 "QTY")))
                    "1"))
      (cond
        (hadblank
         (tst:assert "blank spare row consumed (no growth)"
                     (nth 3 info2) rowsBefore))
        ((not had3080)
         (tst:assert "table grew by one row"
                     (nth 3 info2) (1+ rowsBefore))))
      ;; ADD mode: scanning another area accumulates counts
      (setq *sch:addmode* T)
      (setq aggs (sch:aggregate
                   (list (tst:make-rec "DOOR" "5" "2868" 1 32.0 80.0
                                       "LH" nil nil)
                         (tst:make-rec "DOOR" "5" "2868" 1 32.0 80.0
                                       "RH" nil nil))
                   "DOOR"))
      (setq plan (sch:merge tbl info2 aggs "DOOR"))
      (setq *sch:addmode* nil)
      (setq *sch:handmode* "cols")
      (setq written (sch:apply-plan tbl info2 plan "DOOR"))
      (setq info2 (sch:table-info tbl))
      (setq r5 (cdr (assoc "5" (nth 5 info2))))
      (if r5
        (progn
          (tst:assert "ADD mode QTY 5+2"
                      (sch:strip-fmt
                        (sch:tbl-get tbl r5 (sch:col info2 "QTY")))
                      "7")
          (tst:assert "ADD mode LH 3+1"
                      (sch:strip-fmt
                        (sch:tbl-get tbl r5 (sch:col info2 "LH")))
                      "4")
          (tst:assert "ADD mode RH 2+1"
                      (sch:strip-fmt
                        (sch:tbl-get tbl r5 (sch:col info2 "RH")))
                      "3")))
      (tst:dump-table tbl info2 "DOOR AFTER")))
  (princ))

;; census of the current drawing (what would SCH have to work with?)
(defun tst:count (label filt / ss)
  (setq ss (ssget "_X" filt))
  (tst:out (strcat "  " label ": " (if ss (itoa (sslength ss)) "0"))))

(defun tst:census ()
  (tst:count "AEC doors" '((0 . "AEC_DOOR")))
  (tst:count "AEC windows" '((0 . "AEC_WINDOW")))
  (tst:count "AEC window assemblies" '((0 . "AEC_WINDOW_ASSEMBLY")))
  (tst:count "AEC openings" '((0 . "AEC_OPENING")))
  (tst:count "AEC walls" '((0 . "AEC_WALL")))
  (tst:count "AEC mvblock refs (tags)" '((0 . "AEC_MVBLOCK_REF")))
  (tst:count "proxy entities" '((0 . "ACAD_PROXY_ENTITY")))
  (tst:count "TK_ tag INSERTs" '((0 . "INSERT") (2 . "TK_*")))
  (tst:count "ACAD tables" '((0 . "ACAD_TABLE")))
  (tst:count "xref INSERTs" '((0 . "INSERT") (66 . 1)))
  (princ))

;; auto-create: build both charts from scratch at a far-away point,
;; fill them from synthetic records, verify, then delete them.
(defun tst:integration-create ( / res tbl info aggs plan written m r
                                  wtxt found3050 found2040 dres dtbl
                                  dinfo daggs dplan r1)
  ;; ----- window chart -----
  (setq res (sch:make-table "WINDOW SCHEDULE" (list 1.0e6 1.0e6) 2))
  (tst:assert "make-table returns window table" (if res T nil) T)
  (if res
    (progn
      (setq tbl (car res) info (cadr res))
      (tst:assert "created objname" (sch:objname tbl) "AcDbTable")
      (tst:assert "created title" (car info) "WINDOW SCHEDULE")
      (tst:assert "created header row found" (if (cadr info) T nil) T)
      (tst:assert "created rows (2+2 data+3 spare)" (nth 3 info) 7)
      (tst:assert "created cols" (nth 4 info) 5)
      (setq aggs (sch:aggregate
                   (list (tst:make-rec "WINDOW" "" "3050" 1 36.0 60.0
                                       nil nil nil)
                         (tst:make-rec "WINDOW" "" "3050" 1 36.0 60.0
                                       nil nil nil)
                         (tst:make-rec "WINDOW" "" "2040" 1 24.0 48.0
                                       nil nil nil))
                   "WINDOW"))
      (tst:assert "create-fill agg rows" (length aggs) 2)
      (setq plan (sch:merge tbl info aggs "WINDOW"))
      (setq *sch:handmode* "cols")
      (setq written (sch:apply-plan tbl info plan "WINDOW"))
      (tst:assert "create-fill rows written" written 2)
      (setq info (sch:table-info tbl))
      (tst:assert "marks A and B assigned"
                  (and (assoc "A" (nth 5 info))
                       (assoc "B" (nth 5 info))
                       T) T)
      (setq found3050 nil found2040 nil)
      (foreach m (nth 5 info)
        (setq r (cdr m)
              wtxt (sch:strip-fmt (sch:tbl-get tbl r
                                               (sch:col info "WIDTH"))))
        (if (= wtxt "3'-0\"")
          (setq found3050
            (= (sch:strip-fmt (sch:tbl-get tbl r (sch:col info "QTY")))
               "2")))
        (if (= wtxt "2'-0\"")
          (setq found2040
            (= (sch:strip-fmt (sch:tbl-get tbl r (sch:col info "QTY")))
               "1"))))
      (tst:assert "3'-0\" row qty 2" found3050 T)
      (tst:assert "2'-0\" row qty 1" found2040 T)
      (setq r (cdr (assoc "A" (nth 5 info))))
      (if r
        (tst:assert "window A auto-description"
                    (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "DESCRIPTION")))
                    "1/1 EQ. SASH - VINYL SINGLE HUNG"))
      (tst:dump-table tbl info "CREATED WINDOW")
      (sch:catch 'vla-Delete (list tbl))))
  ;; ----- door chart (incl. LH/RH columns on a fresh table) -----
  (setq dres (sch:make-table "DOOR SCHEDULE" (list 1.0e6 999000.0) 1))
  (tst:assert "make-table returns door table" (if dres T nil) T)
  (if dres
    (progn
      (setq dtbl (car dres) dinfo (cadr dres))
      (setq daggs (sch:aggregate
                    (list (tst:make-rec "DOOR" "" "2668" 1 30.0 80.0
                                        "LH" nil nil))
                    "DOOR"))
      (setq dplan (sch:merge dtbl dinfo daggs "DOOR"))
      (setq *sch:handmode* "cols")
      (setq written (sch:apply-plan dtbl dinfo dplan "DOOR"))
      (tst:assert "door create-fill written" written 1)
      (setq dinfo (sch:table-info dtbl))
      (tst:assert "created door LH col" (if (sch:col dinfo "LH") T nil) T)
      (setq r1 (cdr (assoc "1" (nth 5 dinfo))))
      (tst:assert "door mark 1 assigned" (if r1 T nil) T)
      (if r1
        (progn
          (tst:assert "door 1 width"
                      (sch:strip-fmt
                        (sch:tbl-get dtbl r1 (sch:col dinfo "WIDTH")))
                      "2'-6\"")
          (tst:assert "door 1 LH"
                      (sch:strip-fmt
                        (sch:tbl-get dtbl r1 (sch:col dinfo "LH")))
                      "1")
          (tst:assert "door 1 auto-description"
                      (sch:strip-fmt
                        (sch:tbl-get dtbl r1
                                     (sch:col dinfo "DESCRIPTION")))
                      "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")))
      (tst:dump-table dtbl dinfo "CREATED DOOR")
      (sch:catch 'vla-Delete (list dtbl))))
  (princ))

;; ------------------------------------------------------------------
;; Real-AEC diagnostics (produce output only when AEC content exists)
;; ------------------------------------------------------------------

;; can xref block definitions be walked in this host? Both channels.
(defun tst:xref-walk ( / ss i v bname bd bdef e typ cnt d w tag ccnt
                         firstw recs)
  (setq ss (ssget "_X" '((0 . "INSERT"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq v (sch:vla (ssname ss i))
              bname (sch:val->str (sch:prop v 'Name)))
        (setq bd (sch:catch 'vla-Item
                   (list (vla-get-Blocks
                           (vla-get-ActiveDocument
                             (vlax-get-acad-object)))
                         bname)))
        (if (and bd (= (sch:prop bd 'IsXRef) :vlax-true))
          (progn
            (setq bdef (tblsearch "BLOCK" bname))
            (setq e (if bdef (cdr (assoc -2 bdef))))
            (tst:out (strcat "  XREF \"" bname "\": tblsearch="
                             (if bdef "ok" "NIL") "  first-ent="
                             (if e "ok" "NIL")))
            (setq cnt 0 d 0 w 0 tag 0)
            (if e (tst:out (strcat "    test start-handle: "
                                   (cdr (assoc 5 (entget e))))))
            (while e
              (setq typ (cdr (assoc 0 (entget e)))
                    cnt (1+ cnt))
              (cond ((= typ "AEC_DOOR") (setq d (1+ d)))
                    ((= typ "AEC_WINDOW") (setq w (1+ w)))
                    ((= typ "AEC_MVBLOCK_REF") (setq tag (1+ tag))))
              (setq e (entnext e)))
            (tst:out (strcat "    entnext walk: " (itoa cnt)
                             " ents (" (itoa d) " doors, " (itoa w)
                             " windows, " (itoa tag) " tags)"))
            (setq ccnt 0)
            (sch:catch '(lambda ()
                          (vlax-for x bd (setq ccnt (1+ ccnt))))
                       nil)
            (tst:out (strcat "    COM iteration: " (itoa ccnt)
                             " ents"))
            ;; bbox on the first xref-resident window
            (setq e (if bdef (cdr (assoc -2 bdef))) firstw nil)
            (while (and e (null firstw))
              (if (= (cdr (assoc 0 (entget e))) "AEC_WINDOW")
                (setq firstw e))
              (setq e (entnext e)))
            (if firstw
              (tst:out (strcat "    first window bbox: "
                               (vl-princ-to-string
                                 (sch:bbox (sch:vla firstw))))))
            ;; direct harvest with an unbounded region
            (setq recs (sch:harvest-xref v (list -1.0e9 -1.0e9)
                                         (list 1.0e9 1.0e9) nil))
            (tst:out (strcat "    harvest-xref whole-extent records: "
                             (itoa (length recs))))
            (tst:out (strcat "    xref-last: "
                             (vl-princ-to-string *sch:xref-last*)))
            (if recs
              (tst:out (strcat "    sample record: "
                               (vl-princ-to-string (car recs)))))))
        (setq i (1+ i)))))
  (princ))

;; per-door probe internals on real AEC doors (first 12)
(defun tst:probe-doors ( / ss i n v walls hand bb pl)
  (setq ss (ssget "_X" '((0 . "AEC_DOOR"))))
  (if ss
    (progn
      (setq walls (sch:collect-walls))
      (tst:out (strcat "  wall records: " (itoa (length walls))))
      (setq i 0 n (min 12 (sslength ss)))
      (while (< i n)
        (setq v (sch:vla (ssname ss i))
              bb (sch:bbox v)
              hand (sch:door-hand-probe v walls)
              pl *sch:probe-last*)
        (tst:out (strcat "  door " (itoa (1+ i))
                         "  bbox=" (if bb
                                     (strcat (rtos (- (car (cadr bb))
                                                      (car (car bb))) 2 1)
                                             " x "
                                             (rtos (- (cadr (cadr bb))
                                                      (cadr (car bb))) 2 1))
                                     "NIL")
                         "  hand=" (if hand hand "UNKNOWN")
                         "  probe=" (vl-princ-to-string pl)))
        (setq i (1+ i)))))
  (princ))

;; end-to-end sheet-style harvest: entire model space incl. all
;; xrefs (the paper-space / [All] path), then aggregation
(defun tst:harvest-all ( / recs waggs daggs a)
  (if (null (ssget "_X" '((0 . "AEC_DOOR,AEC_WINDOW,INSERT"))))
    (tst:out "  SKIP harvest-all: nothing to scan")
    (progn
      (setq recs (sch:harvest-core (list -1.0e12 -1.0e12)
                                   (list 1.0e12 1.0e12) T))
      (tst:out (strcat "  harvest-all records: "
                       (itoa (length recs))))
      (setq waggs (sch:aggregate recs "WINDOW")
            daggs (sch:aggregate recs "DOOR"))
      (tst:out (strcat "  door agg rows: " (itoa (length daggs))))
      (foreach a daggs
        (tst:out (strcat "    D " (vl-princ-to-string a))))
      (tst:out (strcat "  window agg rows: " (itoa (length waggs))))
      (foreach a waggs
        (tst:out (strcat "    W " (vl-princ-to-string a))))))
  (princ))

;;; ------------------------------------------------------------------

(defun c:SCHTEST ( / fh)
  (setq *tst:path* (strcat (getvar "DWGPREFIX") "SCHTEST-log.txt")
        *tst:pass* 0
        *tst:fail* 0)
  (setq fh (open *tst:path* "a"))
  (if fh
    (close fh)
    (setq *tst:path* (strcat (getvar "TEMPPREFIX") "SCHTEST-log.txt")))
  (tst:out "==========================================================")
  (tst:out (strcat "SCHTEST  product: " (getvar "ACADVER")
                   "  dwg: " (getvar "DWGNAME")))
  (tst:out "-- census --")
  (tst:census)
  (tst:out "-- xref walkability --")
  (tst:xref-walk)
  (tst:out "-- probe internals on real doors --")
  (tst:probe-doors)
  (tst:out "-- harvest-all (paper-space / All path) --")
  (tst:harvest-all)
  (tst:out "-- unit tests --")
  (tst:units)
  (tst:out "-- integration tests (window/tags) --")
  (tst:integration)
  (tst:out "-- integration tests (door table, synthetic records) --")
  (tst:integration-door)
  (tst:out "-- integration tests (auto-create charts) --")
  (tst:integration-create)
  (tst:out (strcat "RESULT: " (itoa *tst:pass*) " passed, "
                   (itoa *tst:fail*) " failed"))
  (princ (strcat "\n[SCHTEST] Log: " *tst:path*))
  (princ))

(princ "\n[SCHTEST] Loaded. Command: SCHTEST (run on a TEST COPY only).")
(princ)
