;;; ===================================================================
;;; SCHPROBE.lsp - SCH.lsp crash locator for AutoCAD / ACA
;;;
;;; WHY: SCH.lsp works in BricsCAD but reportedly crashes AutoCAD when
;;; it is loaded. This probe loads SCH.lsp ONE top-level form at a
;;; time, writing a progress log (flushed line-by-line) BEFORE each
;;; form is evaluated. If AutoCAD dies mid-probe, the LAST line of the
;;; log names the exact form that killed it.
;;;
;;; HOW TO USE (on the AutoCAD machine):
;;;   1. Download a FRESH SCH.lsp from GitHub (do NOT use a copy that
;;;      was pasted through email - formatting can corrupt it):
;;;      https://github.com/ssche13/dsld-sch-lisp
;;;   2. Put SCHPROBE.lsp in the SAME folder as SCH.lsp.
;;;   3. APPLOAD SCHPROBE.lsp - it runs immediately (or type SCHPROBE).
;;;   4a. If AutoCAD survives: it prints DONE and SCH is fully loaded -
;;;       try the SCH command normally.
;;;   4b. If AutoCAD crashes: reopen the folder and email back
;;;       SCHPROBE-log.txt (it sits next to SCH.lsp).
;;;
;;; The probe uses only core AutoLISP until the vl-load-com step, so
;;; it can log even a vl-load-com crash.
;;; ===================================================================

(setq *probe:log* nil)

;; flushed logging: open-append / close on every line so the log
;; survives a hard crash
(defun probe:log (msg / f)
  (if *probe:log*
    (progn
      (setq f (open *probe:log* "a"))
      (if f (progn (write-line msg f) (close f)))))
  (princ (strcat "\n" msg))
  (princ))

;; core-only dirname (no vl-filename-directory before vl-load-com)
(defun probe:dirname (p / i c cut)
  (setq i (strlen p) cut 0)
  (while (and (> i 0) (= cut 0))
    (setq c (substr p i 1))
    (if (or (= c "\\") (= c "/")) (setq cut i))
    (setq i (1- i)))
  (if (> cut 0) (substr p 1 (1- cut)) "."))

(defun probe:getvar-str (v / r)
  (setq r (getvar v))
  (cond ((= (type r) 'STR) r)
        ((= (type r) 'INT) (itoa r))
        ((null r) "(nil)")
        (t "(non-string)")))

(defun c:SCHPROBE ( / src dir f line chunks cur n tmp res label nerr
                     total)
  ;; ---- locate SCH.lsp ---------------------------------------------
  (setq src (findfile "SCH.lsp"))
  (if (null src)
    (setq src (getfiled "Select SCH.lsp to probe" "" "lsp" 0)))
  (cond
    ((null src)
     (princ "\n[PROBE] No SCH.lsp found or selected - aborted."))
    (t
     ;; ---- open the log (next to SCH.lsp, else TEMP) ---------------
     (setq dir (probe:dirname src))
     (setq *probe:log* (strcat dir "\\SCHPROBE-log.txt"))
     (setq f (open *probe:log* "w"))
     (if f
       (progn (write-line "SCHPROBE log" f) (close f))
       (progn
         (setq *probe:log* (strcat (probe:getvar-str "TEMPPREFIX")
                                   "SCHPROBE-log.txt"))
         (setq f (open *probe:log* "w"))
         (if f
           (progn (write-line "SCHPROBE log (folder of SCH.lsp was not writable)" f)
                  (close f))
           (setq *probe:log* nil))))
     (probe:log (strcat "log file: "
                        (if *probe:log* *probe:log* "(NONE - printing only)")))
     (probe:log (strcat "source:   " src))
     (probe:log (strcat "ACADVER:  " (probe:getvar-str "ACADVER")
                        "   PRODUCT: " (probe:getvar-str "PRODUCT")))
     ;; ---- environment report (all diagnostic, all read-only) -------
     ;; SECURELOAD=2 silently blocks untrusted lisps; =1 pops a warning
     ;; dialog that can hide off-screen and LOOK like a hang.
     (probe:log (strcat "SECURELOAD:   " (probe:getvar-str "SECURELOAD")
                        "   LISPSYS: " (probe:getvar-str "LISPSYS")))
     (probe:log (strcat "TRUSTEDPATHS: " (probe:getvar-str "TRUSTEDPATHS")))
     ;; audit acaddoc.lsp - a stale SCH-AUTOLOAD line pointing at a
     ;; broken old copy re-loads it on EVERY drawing open
     (setq f (findfile "acaddoc.lsp"))
     (if f
       (progn
         (probe:log (strcat "acaddoc.lsp:  " f))
         (setq f (open f "r") n 0 nerr 0)
         (while (setq line (read-line f))
           (setq n (1+ n))
           (if (and (< (strlen line) 400)
                    (wcmatch line "*SCH-AUTOLOAD*"))
             (setq nerr (1+ nerr))))
         (close f)
         (probe:log (strcat "  " (itoa n) " lines, " (itoa nerr)
                            " SCH-AUTOLOAD marker(s)"
                            (if (> nerr 1)
                              "  <-- DUPLICATES, clean these out" ""))))
       (probe:log "acaddoc.lsp:  (none on the search path)"))
     (setq n 0 nerr 0 f nil line nil)
     ;; ---- step 1: vl-load-com (logged BEFORE, so a crash here shows)
     (probe:log "step: (vl-load-com) ... if the log ends here, vl-load-com killed AutoCAD")
     (vl-load-com)
     (probe:log "  ok")
     ;; ---- step 2: split SCH.lsp into top-level chunks -------------
     ;; a line whose FIRST character is "(" starts a new top-level form
     (probe:log "step: reading + splitting SCH.lsp into top-level forms")
     (setq f (open src "r") chunks nil cur "")
     (while (setq line (read-line f))
       (if (and (> (strlen line) 0) (= (substr line 1 1) "("))
         (progn
           (if (/= cur "") (setq chunks (cons cur chunks)))
           (setq cur (strcat line "\n")))
         (setq cur (strcat cur line "\n"))))
     (close f)
     (if (/= cur "") (setq chunks (cons cur chunks)))
     (setq chunks (reverse chunks)
           total  (length chunks))
     (probe:log (strcat "  ok - " (itoa total) " top-level forms"))
     ;; ---- step 3: load each form via a one-form temp file ---------
     (setq tmp (strcat dir "\\SCHPROBE-form.lsp") n 0 nerr 0)
     (setq f (open tmp "w"))
     (if (null f) (setq tmp (strcat (probe:getvar-str "TEMPPREFIX")
                                    "SCHPROBE-form.lsp"))
                  (close f))
     (foreach chunk chunks
       (setq n (1+ n))
       ;; label = first line of the form, trimmed
       (setq label chunk)
       (if (vl-string-search "\n" label)
         (setq label (substr label 1 (vl-string-search "\n" label))))
       (if (> (strlen label) 70) (setq label (substr label 1 70)))
       (probe:log (strcat "loading #" (itoa n) "/" (itoa total)
                          ": " label))
       (setq f (open tmp "w"))
       (if f
         (progn
           (princ chunk f)
           (close f)
           (setq res (load tmp "SCHPROBE-LOAD-FAILED"))
           (if (and (= (type res) 'STR) (= res "SCHPROBE-LOAD-FAILED"))
             (progn
               (setq nerr (1+ nerr))
               (probe:log "  LISP ERROR in this form (NOT a crash - probe continues)"))
             (probe:log "  ok")))
         (probe:log "  SKIPPED - could not write temp form file")))
     (vl-file-delete tmp)
     ;; ---- done -----------------------------------------------------
     (probe:log (strcat "DONE - all " (itoa total)
                        " forms evaluated without killing AutoCAD ("
                        (itoa nerr) " lisp errors)."))
     (if (= nerr 0)
       (probe:log "SCH is now fully loaded - try the SCH command. If loading SCH.lsp whole still crashes, the problem is the load mechanism (file copy, APPLOAD, startup suite), not the code - report that."))
     (princ)))
  (princ))

(c:SCHPROBE)
(princ)
