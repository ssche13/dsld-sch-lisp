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
  (princ))

;;; ------------------------------------------------------------------
;;; Integration tests (drawing with TK_ tags + window schedule table)
;;; ------------------------------------------------------------------

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
                           written rowE)
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
      (setq ss (ssget "_X" '((0 . "ACAD_TABLE"))))
      (if (null ss)
        (tst:out "  SKIP table tests: no ACAD_TABLE in this drawing")
        (progn
          (setq tbl (sch:vla (ssname ss 0))
                info (sch:table-info tbl))
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
          (tst:dump-table tbl info "AFTER")))))
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
  (tst:out "-- unit tests --")
  (tst:units)
  (tst:out "-- integration tests --")
  (tst:integration)
  (tst:out (strcat "RESULT: " (itoa *tst:pass*) " passed, "
                   (itoa *tst:fail*) " failed"))
  (princ (strcat "\n[SCHTEST] Log: " *tst:path*))
  (princ))

(princ "\n[SCHTEST] Loaded. Command: SCHTEST (run on a TEST COPY only).")
(princ)
