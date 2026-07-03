;;; ===================================================================
;;; SCH.lsp - DSLD Schedule of Openings auto-fill
;;; Target platform: AutoCAD Architecture (ACA)
;;;
;;; Commands:
;;;   SCH      - harvest door/window/opening data from a selected plan
;;;              region, preview the proposed WINDOW SCHEDULE and DOOR
;;;              SCHEDULE contents in a dialog, then write the accepted
;;;              values into the two ACAD_TABLE schedule tables.
;;;   SCHDIAG  - diagnostic: census of AEC objects / tags / tables in
;;;              the drawing, plus deep-dump of picked entities
;;;              (properties, property sets, explode test). Writes
;;;              SCHDIAG-report.txt next to the drawing. Run this in
;;;              ACA on a real plan and send the report back so the
;;;              data-extraction layer can be hardened.
;;;
;;; Data sources (tried in order, per object):
;;;   1. ACA property sets via AecX.AecScheduleApplication
;;;      (DoorObjects / WindowObjects: DSLD_NUMBER,
;;;       StandardSizeDescription, plus any Swing/Hand property)
;;;   2. Direct ActiveX properties on AecDbDoor/AecDbWindow
;;;      (Width, Height, style name)
;;;   3. Fallback for flattened DWGs/DXFs (and BricsCAD testing):
;;;      plain INSERTs of TK_Door_Tag*_P / TK_Window_Tag*_P attributed
;;;      blocks (mark bubbles paired with size tags by proximity).
;;;
;;; LH/RH swing: derived geometrically - the door is copied, the copy
;;; exploded to primitives, the swing ARC + leaf line analyzed against
;;; the host wall direction, then all temp entities deleted.
;;; Convention (configurable below): viewer stands on the side the door
;;; opens AWAY from; hinge on viewer's left = LH.
;;;
;;; Cased openings: AecDbOpening objects, or doors whose style name
;;; contains "ARCH" (TK_Arch family). Host wall Width < threshold
;;; classifies as 4" wall, otherwise 6" wall; result is written into
;;; the DESCRIPTION as e.g.  CASED OPENING - 6" WALL
;;; ===================================================================

(vl-load-com)

;;; ------------------------------------------------------------------
;;; Configuration
;;; ------------------------------------------------------------------

(setq *sch:wall6-threshold* 5.0)  ; host wall Width >= 5.0" => 6" wall
(setq *sch:hand-convention* "AWAY") ; "AWAY": viewer on the side the door
                                    ; opens away from (US standard).
                                    ; "TOWARD" flips LH/RH.
(setq *sch:tagpair-dist* 40.0)    ; max distance (in) between a mark
                                  ; bubble and its size tag (INSERT
                                  ; fallback provider), scaled by the
                                  ; bubble's insert scale.
(setq *sch:use-aecx* T)           ; nil = never touch the AecX COM
                                  ; interface (set nil if it crashes)
(setq *sch:use-explode* T)        ; nil = skip geometric swing-hand
                                  ; detection (set nil if it crashes)
(setq *sch:diag-path* nil)        ; report path, set by SCHDIAG
(setq *sch:explode-broken* nil)   ; set T automatically after repeated
(setq *sch:explode-fails* 0)      ; explode failures (session cache)

;; Standard DSLD descriptions written into NEW schedule rows (existing
;; text is never overwritten). First style-name pattern that matches
;; wins - edit these freely to match office wording.
(setq *sch:desc-map*
  '(("*GARAGE*"   . "OVERHEAD GARAGE DOOR")
    ("*POCKET*"   . "POCKET - INT. GRADE - SEE P.O.")
    ("*BIFOLD*"   . "BIFOLD - INT. GRADE - SEE P.O.")
    ("*DOORWALL*" . "SLIDING GLASS DOOR")
    ("*EXTERIOR*" . "EXT. GRADE - FIBERGLASS")))
(setq *sch:desc-door-default* "INTERIOR GRADE - HOLLOW CORE - SEE P.O.")
(setq *sch:desc-window-default* "1/1 EQ. SASH - VINYL SINGLE HUNG")

;;; ------------------------------------------------------------------
;;; Generic guarded-call utilities
;;; ------------------------------------------------------------------

(defun sch:catch (f args / r)
  (setq r (vl-catch-all-apply f args))
  (if (vl-catch-all-error-p r) nil r))

(defun sch:prop (obj name)
  (if (and obj (eq (type obj) 'VLA-OBJECT)
           (vlax-property-available-p obj name))
    (sch:catch 'vlax-get-property (list obj name))))

(defun sch:invoke (obj meth args)
  (if (and obj (eq (type obj) 'VLA-OBJECT))
    (sch:catch 'vlax-invoke (append (list obj meth) args))))

(defun sch:vla (e)
  (cond ((eq (type e) 'ENAME) (sch:catch 'vlax-ename->vla-object (list e)))
        ((eq (type e) 'VLA-OBJECT) e)))

(defun sch:objname (o / v)
  (setq v (sch:vla o))
  (if v (sch:prop v 'ObjectName) ""))

(defun sch:val->str (v)
  (cond ((null v) "")
        ((eq (type v) 'STR) v)
        ((eq (type v) 'INT) (itoa v))
        ((eq (type v) 'REAL) (rtos v 2 4))
        ((eq (type v) 'VARIANT)
         (sch:val->str (sch:catch 'vlax-variant-value (list v))))
        (t "")))

;;; ------------------------------------------------------------------
;;; String / formatting utilities
;;; ------------------------------------------------------------------

(defun sch:trim (s)
  (if s (vl-string-trim " \t" s) ""))

;; Strip common MTEXT formatting codes; \Sa#b; becomes a/b.
;; Handles semicolon-less codes (\P \~ \\ \{ \} \L \l \O \o \K \k)
;; separately from ;-terminated ones (\A1; \H0.7x; \S4#4; \C \f \p ...).
(defun sch:strip-fmt (s / i n c out code nxt)
  (if (null s) (setq s ""))
  (setq i 1 n (strlen s) out "")
  (while (<= i n)
    (setq c (substr s i 1))
    (cond
      ((or (= c "{") (= c "}")) (setq i (1+ i)))
      ((= c "\\")
       (setq nxt (if (< i n) (substr s (1+ i) 1) ""))
       (cond
         ((member nxt '("\\" "{" "}")) ; escaped literals
          (setq out (strcat out nxt) i (+ i 2)))
         ((member nxt '("P" "~")) ; hard line break / nbsp -> space
          (setq out (strcat out " ") i (+ i 2)))
         ((member nxt '("L" "l" "O" "o" "K" "k")) ; format toggles
          (setq i (+ i 2)))
         (t ; ;-terminated codes
          (setq code "" i (1+ i))
          (while (and (<= i n) (/= (substr s i 1) ";")
                      (< (strlen code) 40))
            (setq code (strcat code (substr s i 1)) i (1+ i)))
          (if (and (<= i n) (= (substr s i 1) ";"))
            (setq i (1+ i))) ; skip ";" only if actually there
          (if (and (> (strlen code) 1)
                   (= (strcase (substr code 1 1)) "S"))
            ;; stacked fraction \S4#4; -> 4/4
            (setq out (strcat out
                              (vl-string-translate "#" "/"
                                                   (substr code 2))))))))
      (t (setq out (strcat out c)) (setq i (1+ i)))))
  (sch:trim out))

;; inches -> 2'-8"  (whole inches expected; shows one decimal otherwise)
(defun sch:ftin (in / ft rem)
  (setq ft (fix (/ in 12.0))
        rem (- in (* ft 12)))
  (if (equal rem (float (fix (+ rem 0.5e-3))) 1e-2)
    (setq rem (float (fix (+ rem 0.5e-3)))))
  (if (>= rem 11.95) ; carry rounded-up inches into feet: 2'-12" -> 3'-0"
    (setq ft (1+ ft) rem 0.0))
  (strcat (itoa ft) "'-"
          (if (equal rem (float (fix rem)) 1e-6)
            (itoa (fix rem))
            (rtos rem 2 1))
          "\""))

(defun sch:alldigits-p (s / i ok)
  (setq ok (> (strlen s) 0) i 1)
  (while (and ok (<= i (strlen s)))
    (if (not (<= 48 (ascii (substr s i 1)) 57)) (setq ok nil))
    (setq i (1+ i)))
  ok)

;; Parse a DSLD size code -> (mult widthIn heightIn) or nil.
;; "2668" -> (1 30.0 80.0)   "8080" -> (1 96.0 96.0)
;; "16070" -> (1 192.0 84.0) "2-2668"/"DBL. 2668" -> (2 30.0 80.0)
;; "8X7"/"16X7" garage and "3X4"/"4X5" window shorthand (feet x feet)
(defun sch:parse-size (raw / s mult d1 d2 d3 d4 d5 n p)
  (setq s (strcase (sch:trim raw)) mult 1)
  (cond ((wcmatch s "DBL*")
         (setq mult 2 s (sch:trim (vl-string-trim ". " (substr s 4))))))
  (if (wcmatch s "#-####") ; e.g. 2-2668
    (progn (setq mult (atoi (substr s 1 1)))
           (setq s (substr s 3))))
  (setq n (strlen s))
  (cond
    ((wcmatch s "#X#,##X#,#X##,##X##") ; feet x feet: 8X7, 16X7, 3X4
     (setq p (vl-string-search "X" s))
     (list mult (* 12.0 (atoi (substr s 1 p)))
           (* 12.0 (atoi (substr s (+ p 2))))))
    ((not (sch:alldigits-p s)) nil)
    ((= n 4)
     (setq d1 (atoi (substr s 1 1)) d2 (atoi (substr s 2 1))
           d3 (atoi (substr s 3 1)) d4 (atoi (substr s 4 1)))
     (list mult (+ (* d1 12.0) d2) (+ (* d3 12.0) d4)))
    ((= n 5) ; 2-digit feet width, e.g. 16070 = 16'-0" x 7'-0"
     (setq d1 (atoi (substr s 1 2)) d2 (atoi (substr s 3 1))
           d3 (atoi (substr s 4 1)) d4 (atoi (substr s 5 1)))
     (list mult (+ (* d1 12.0) d2) (+ (* d3 12.0) d4)))
    (t nil)))

;;; ------------------------------------------------------------------
;;; Geometry utilities
;;; ------------------------------------------------------------------

(defun sch:bbox (vlaObj / mn mx)
  ;; GetBoundingBox is a void method - success is signaled by the
  ;; out-params mn/mx being filled, never by the return value.
  (sch:catch 'vla-GetBoundingBox (list vlaObj 'mn 'mx))
  (if (and mn mx)
    (list (vlax-safearray->list mn) (vlax-safearray->list mx))))

(defun sch:bbox-center (vlaObj / bb)
  (if (setq bb (sch:bbox vlaObj))
    (mapcar '(lambda (a b) (/ (+ a b) 2.0)) (car bb) (cadr bb))))

(defun sch:pt2 (p) (list (car p) (cadr p)))

(defun sch:v- (a b) (mapcar '- (sch:pt2 a) (sch:pt2 b)))
(defun sch:v+ (a b) (mapcar '+ (sch:pt2 a) (sch:pt2 b)))
(defun sch:vscale (v s) (mapcar '(lambda (x) (* x s)) v))
(defun sch:vdot (a b) (apply '+ (mapcar '* a b)))
(defun sch:vlen (v) (sqrt (sch:vdot v v)))
(defun sch:vunit (v / l) (setq l (sch:vlen v))
  (if (> l 1e-9) (sch:vscale v (/ 1.0 l)) '(0.0 0.0)))
(defun sch:vperp (v) (list (- (cadr v)) (car v)))
(defun sch:vcross (a b) (- (* (car a) (cadr b)) (* (cadr a) (car b))))

;; distance from point p to segment a-b (2D)
(defun sch:dist-pt-seg (p a b / ab ap tparam proj)
  (setq ab (sch:v- b a) ap (sch:v- p a))
  (if (< (sch:vlen ab) 1e-9)
    (sch:vlen ap)
    (progn
      (setq tparam (/ (sch:vdot ap ab) (sch:vdot ab ab)))
      (if (< tparam 0.0) (setq tparam 0.0))
      (if (> tparam 1.0) (setq tparam 1.0))
      (setq proj (sch:v+ a (sch:vscale ab tparam)))
      (sch:vlen (sch:v- p proj)))))

;; transform a local point by an insert's placement (2D; handles
;; mirror via negative scales; ignores OCS - plans are WCS)
(defun sch:xform-pt (pt ip rot sx sy / x y c s)
  (setq x (* (car pt) sx) y (* (cadr pt) sy)
        c (cos rot) s (sin rot))
  (list (+ (car ip) (- (* x c) (* y s)))
        (+ (cadr ip) (+ (* x s) (* y c)))))

(defun sch:pt-in-box (p p1 p2)
  (and (>= (car p) (min (car p1) (car p2)))
       (<= (car p) (max (car p1) (car p2)))
       (>= (cadr p) (min (cadr p1) (cadr p2)))
       (<= (cadr p) (max (cadr p1) (cadr p2)))))

;;; ------------------------------------------------------------------
;;; AecX bridge - property sets
;;; ------------------------------------------------------------------

(defun sch:sched-app ( / vlist app)
  (cond
    ((not *sch:use-aecx*) nil)
    (*sch:schedapp* *sch:schedapp*)
    ((eq *sch:schedapp-failed* T) nil)
    (t
     (setq vlist '("" ".9.7" ".9.5" ".9.0" ".8.9" ".8.8" ".8.7" ".8.5"
                   ".8.0" ".7.9" ".7.7" ".7.5" ".7.0" ".6.7" ".6.5"
                   ".6.0" ".5.5" ".5.0" ".4.7" ".4.5"))
     (foreach v vlist
       (if (and (null *sch:schedapp*)
                (setq app (sch:catch 'vla-GetInterfaceObject
                            (list (vlax-get-acad-object)
                                  (strcat "AecX.AecScheduleApplication" v)))))
         (progn (setq *sch:schedapp* app *sch:schedapp-ver* v))))
     (if (null *sch:schedapp*) (setq *sch:schedapp-failed* T))
     *sch:schedapp*)))

;; Return property sets of an object as
;; (("DOOROBJECTS" ("DSLD_NUMBER" . "5") ("STANDARDSIZEDESCRIPTION" . "2668") ...) ...)
(defun sch:psets (vlaObj / app sets out props pl nm)
  (setq app (sch:sched-app))
  (if app
    (progn
      (setq sets (sch:invoke app 'PropertySets (list vlaObj)))
      (if (null sets)
        (setq sets (sch:catch 'vlax-get-property
                     (list app 'PropertySets vlaObj))))
      (if (and sets (eq (type sets) 'VLA-OBJECT))
        (sch:catch
          '(lambda ()
             (vlax-for ps sets
               (setq pl nil
                     nm (strcase (sch:val->str (sch:prop ps 'Name))))
               (setq props (sch:prop ps 'Properties))
               (if props
                 (sch:catch
                   '(lambda ()
                      (vlax-for p props
                        (setq pl (cons (cons (strcase (sch:val->str
                                                        (sch:prop p 'Name)))
                                             (sch:val->str (sch:prop p 'Value)))
                                       pl))))
                   nil))
               (setq out (cons (cons nm (reverse pl)) out))))
          nil))))
  out)

;; find a property value by property-set-name pattern + property-name pattern
(defun sch:pset-val (psets setpat proppat / out)
  (foreach ps psets
    (if (and (null out) (wcmatch (car ps) setpat))
      (foreach pr (cdr ps)
        (if (and (null out) (wcmatch (car pr) proppat))
          (setq out (cdr pr))))))
  out)

;;; ------------------------------------------------------------------
;;; Walls - census and nearest-wall width
;;; ------------------------------------------------------------------

;; each wall record: (p1 p2 widthOrNil)
(defun sch:wall-record (vlaW / sp ep bb p1 p2 w mn mx dx dy)
  (setq w (sch:prop vlaW 'Width))
  (if (eq (type w) 'VARIANT) (setq w (sch:catch 'vlax-variant-value (list w))))
  (if (not (numberp w)) (setq w nil))
  (setq sp (sch:prop vlaW 'StartPoint)
        ep (sch:prop vlaW 'EndPoint))
  (if (eq (type sp) 'VARIANT)
    (setq sp (sch:catch 'vlax-safearray->list
               (list (vlax-variant-value sp)))))
  (if (eq (type ep) 'VARIANT)
    (setq ep (sch:catch 'vlax-safearray->list
               (list (vlax-variant-value ep)))))
  (cond
    ((and sp ep (listp sp) (listp ep))
     (list (sch:pt2 sp) (sch:pt2 ep) w))
    ((setq bb (sch:bbox vlaW))
     (setq mn (car bb) mx (cadr bb)
           dx (- (car mx) (car mn)) dy (- (cadr mx) (cadr mn)))
     ;; baseline = midline along the long axis; short axis approximates width
     (if (>= dx dy)
       (list (list (car mn) (/ (+ (cadr mn) (cadr mx)) 2.0))
             (list (car mx) (/ (+ (cadr mn) (cadr mx)) 2.0))
             (if w w (if (< dy 24.0) dy nil)))
       (list (list (/ (+ (car mn) (car mx)) 2.0) (cadr mn))
             (list (/ (+ (car mn) (car mx)) 2.0) (cadr mx))
             (if w w (if (< dx 24.0) dx nil)))))))

(defun sch:collect-walls ( / ss i rec out)
  (setq out nil)
  (setq ss (ssget "_X" '((0 . "AEC_WALL") (410 . "Model"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq rec (sch:wall-record (sch:vla (ssname ss i))))
        (if rec (setq out (cons rec out)))
        (setq i (1+ i)))))
  out)

;; nearest wall to pt within maxd -> wall record or nil
(defun sch:nearest-wall (pt walls maxd / best bestd d)
  (setq bestd maxd)
  (foreach w walls
    (setq d (sch:dist-pt-seg pt (car w) (cadr w)))
    (if (< d bestd) (setq bestd d best w)))
  best)

(defun sch:wall-class (wrec / w)
  (if (and wrec (setq w (caddr wrec)))
    (if (>= w *sch:wall6-threshold*) "6" "4")))

;;; ------------------------------------------------------------------
;;; Swing-hand detection (explode a copy, analyze arc + leaf)
;;; ------------------------------------------------------------------

;; explode a copy of vlaObj (2 levels), return list of vla primitives.
;; caller must delete them with sch:del-ents.
;; ActiveX ONLY - never the command line: feeding _EXPLODE into the
;; command stream mid-session collided with pending commands (BricsCAD
;; BIM section prompts) and is banned. After 3 consecutive failures,
;; swing detection is switched off for the rest of the session.
(defun sch:explode-copy (vlaObj / cp res out sub subres)
  (if (null *sch:explode-fails*) (setq *sch:explode-fails* 0))
  (if (not *sch:explode-broken*)
    (progn
      (setq cp (sch:catch 'vla-Copy (list vlaObj)))
      (setq res (if cp (sch:invoke cp 'Explode nil)))
      (if cp (sch:catch 'vla-Delete (list cp)))
      (if res
        (progn
          (setq *sch:explode-fails* 0)
          ;; explode nested inserts one more level
          (setq sub nil)
          (foreach o res
            (if (and o (= (sch:objname o) "AcDbBlockReference"))
              (progn
                (setq subres (sch:invoke o 'Explode nil))
                (if subres
                  (progn (setq sub (append sub subres))
                         (sch:catch 'vla-Delete (list o)))
                  (setq sub (cons o sub))))
              (if o (setq sub (cons o sub)))))
          (setq out (vl-remove nil sub)))
        (progn
          (setq *sch:explode-fails* (1+ *sch:explode-fails*))
          (if (>= *sch:explode-fails* 3)
            (progn
              (setq *sch:explode-broken* T)
              (princ "\n[SCH] These objects cannot be exploded - swing detection off for this session.")))))))
  out)

(defun sch:del-ents (lst)
  (foreach o lst (if o (sch:catch 'vla-Delete (list o)))))

(defun sch:arc-data (vlaArc / c r a1 a2)
  (setq c (sch:prop vlaArc 'Center))
  (if (eq (type c) 'VARIANT)
    (setq c (sch:catch 'vlax-safearray->list (list (vlax-variant-value c)))))
  (setq r (sch:prop vlaArc 'Radius)
        a1 (sch:prop vlaArc 'StartAngle)
        a2 (sch:prop vlaArc 'EndAngle))
  (if (and c r a1 a2) (list (sch:pt2 c) r a1 a2)))

(defun sch:line-ends (vlaLine / a b)
  (setq a (sch:prop vlaLine 'StartPoint) b (sch:prop vlaLine 'EndPoint))
  (if (eq (type a) 'VARIANT)
    (setq a (sch:catch 'vlax-safearray->list (list (vlax-variant-value a)))))
  (if (eq (type b) 'VARIANT)
    (setq b (sch:catch 'vlax-safearray->list (list (vlax-variant-value b)))))
  (if (and a b) (list (sch:pt2 a) (sch:pt2 b))))

;; core hand computation.
;; c=hinge, r=radius, a1/a2=arc angles, wallP1/wallP2 = wall baseline
;; (or leaf-derived pseudo-baseline). Returns "LH" / "RH" / nil.
(defun sch:hand-calc (c r a1 a2 wallP1 wallP2 / delta mid midpt e1 e2
                      strike wdir wnorm side swingn viewdir leftdir dvec)
  (setq delta (- a2 a1))
  (if (< delta 0.0) (setq delta (+ delta (* 2.0 pi))))
  (setq mid (+ a1 (/ delta 2.0))
        midpt (sch:v+ c (list (* r (cos mid)) (* r (sin mid))))
        e1 (sch:v+ c (list (* r (cos a1)) (* r (sin a1))))
        e2 (sch:v+ c (list (* r (cos a2)) (* r (sin a2))))
        wdir (sch:vunit (sch:v- wallP2 wallP1))
        wnorm (sch:vperp wdir))
  (if (< (sch:vlen wdir) 1e-9)
    nil
    (progn
      ;; strike endpoint = arc endpoint closest to the wall line
      (setq strike
        (if (< (sch:dist-pt-seg e1 wallP1 wallP2)
               (sch:dist-pt-seg e2 wallP1 wallP2))
          e1 e2))
      ;; which side of the wall the arc bulges to
      (setq side (sch:vdot (sch:v- midpt c) wnorm))
      (if (equal side 0.0 1e-9)
        nil
        (progn
          (setq swingn (sch:vscale wnorm (if (> side 0.0) 1.0 -1.0)))
          ;; viewer stands opposite the swing, looking through the door
          (setq viewdir swingn)
          (if (= (strcase *sch:hand-convention*) "TOWARD")
            (setq viewdir (sch:vscale viewdir -1.0)))
          (setq leftdir (sch:vperp viewdir)) ; viewer's left
          (setq dvec (sch:v- strike c))     ; hinge -> strike
          ;; hinge relative to door center = -dvec/2
          (if (> (sch:vdot (sch:vscale dvec -0.5) leftdir) 0.0)
            "LH" "RH"))))))

;; Determine hand of a door vla-object. walls = wall records.
;; Returns "LH" / "RH" / nil.
(defun sch:door-hand (vlaDoor walls / prims arcs lines best bestr ad
                      hinge r a1 a2 wrec wallP1 wallP2 leaf le hand)
  (setq prims (if *sch:use-explode* (sch:explode-copy vlaDoor)))
  (if prims
    (progn
      (foreach o prims
        (cond ((= (sch:objname o) "AcDbArc") (setq arcs (cons o arcs)))
              ((= (sch:objname o) "AcDbLine") (setq lines (cons o lines)))))
      ;; largest arc = swing arc
      (setq bestr 0.0)
      (foreach a arcs
        (setq ad (sch:arc-data a))
        (if (and ad (> (cadr ad) bestr))
          (setq bestr (cadr ad) best ad)))
      (if best
        (progn
          (setq hinge (car best) r (cadr best)
                a1 (caddr best) a2 (cadddr best))
          ;; wall baseline: nearest wall within 12" of hinge
          (setq wrec (sch:nearest-wall hinge walls 12.0))
          (if wrec
            (setq wallP1 (car wrec) wallP2 (cadr wrec))
            ;; fallback: leaf line = line with an endpoint at the hinge,
            ;; length ~ radius; pseudo-baseline is perpendicular to leaf
            (progn
              (foreach l lines
                (setq le (sch:line-ends l))
                (if (and le (null leaf))
                  (cond
                    ((and (< (distance (car le) hinge) (* 0.1 r))
                          (> (distance (cadr le) hinge) (* 0.7 r)))
                     (setq leaf (cadr le)))
                    ((and (< (distance (cadr le) hinge) (* 0.1 r))
                          (> (distance (car le) hinge) (* 0.7 r)))
                     (setq leaf (car le))))))
              (if leaf
                (progn
                  ;; wall direction ~ perpendicular to closed-leaf line is
                  ;; unreliable; use the arc endpoint farthest from leaf tip
                  ;; as the strike, wall dir = hinge->strike
                  (setq wallP1 hinge
                        wallP2 (if (> (distance
                                        (sch:v+ hinge
                                                (list (* r (cos a1))
                                                      (* r (sin a1))))
                                        leaf)
                                      (distance
                                        (sch:v+ hinge
                                                (list (* r (cos a2))
                                                      (* r (sin a2))))
                                        leaf))
                                 (sch:v+ hinge (list (* r (cos a1))
                                                     (* r (sin a1))))
                                 (sch:v+ hinge (list (* r (cos a2))
                                                     (* r (sin a2))))))))))
          (if (and wallP1 wallP2)
            (setq hand (sch:hand-calc hinge r a1 a2 wallP1 wallP2)))))
      (sch:del-ents prims)))
  hand)

;;; ------------------------------------------------------------------
;;; Harvest - build item records from the selection
;;; item record: assoc list with string keys:
;;;  "KIND" "DOOR"|"WINDOW"  "MARK" "5"/"A"/""  "CODE" "2668"/""
;;;  "MULT" int  "WIN"/"HIN" real|nil  "HAND" "LH"|"RH"|nil
;;;  "CASED" T|nil  "WALL" "4"|"6"|nil  "STYLE" name  "SRC" tag
;;; ------------------------------------------------------------------

(defun sch:rget (rec k) (cdr (assoc k rec)))

(defun sch:style-name (vlaObj / s)
  (setq s (sch:prop vlaObj 'StyleName))
  (if (null s) (setq s (sch:prop vlaObj 'Style)))
  (if (eq (type s) 'VLA-OBJECT) (setq s (sch:prop s 'Name)))
  (if (eq (type s) 'STR) s ""))

(defun sch:num-prop (vlaObj name / v)
  (setq v (sch:prop vlaObj name))
  (if (eq (type v) 'VARIANT)
    (setq v (sch:catch 'vlax-variant-value (list v))))
  (if (numberp v) v nil))

;; getpropertyvalue-based reader (AutoCAD 2012+/BricsCAD) - reaches
;; data on entities whose COM wrapper exposes nothing (BricsCAD shows
;; only Layer/ObjectName on ACA doors).
(defun sch:gprop (ename name)
  (if (and ename (member "GETPROPERTYVALUE" (atoms-family 1)))
    (sch:catch 'getpropertyvalue (list ename name))))

(defun sch:gprop-num (ename name / v)
  (setq v (sch:gprop ename name))
  (cond ((numberp v) v)
        ((and (eq (type v) 'STR) (distof v)) (distof v))))

;; harvest one AEC object (door/window/opening) -> record
(defun sch:harvest-aec (vlaObj kind cased walls needhand
                        / psets mark code sz mult win hin hand style
                          center wrec wallcls swingval en bb dx dy dz
                          meas)
  (setq psets (sch:psets vlaObj)
        style (sch:style-name vlaObj)
        center (sch:bbox-center vlaObj))
  (if (and (not cased) (wcmatch (strcase style) "*ARCH*"))
    (setq cased T))
  (setq mark (sch:trim (sch:val->str
               (sch:pset-val psets "*OBJECTS" "DSLD_NUMBER")))
        code (sch:trim (sch:val->str
               (sch:pset-val psets "*OBJECTS" "STANDARDSIZEDESCRIPTION"))))
  (if (and (/= code "") (setq sz (sch:parse-size code)))
    (setq mult (car sz) win (cadr sz) hin (caddr sz))
    (setq mult 1))
  (if (null win) (setq win (sch:num-prop vlaObj "Width")))
  (if (null hin) (setq hin (sch:num-prop vlaObj "Height")))
  ;; non-COM property channel (BricsCAD's COM wrapper hides AEC data)
  (setq en (sch:catch 'vlax-vla-object->ename (list vlaObj)))
  (if (null win) (setq win (sch:gprop-num en "Width")))
  (if (null hin) (setq hin (sch:gprop-num en "Height")))
  (if (= style "") (setq style (sch:val->str (sch:gprop en "Style"))))
  ;; last resort: measure the bounding box (plan extent = width,
  ;; 3D extent = height), snapped to the nearest inch
  (if (and (null win) (setq bb (sch:bbox vlaObj)))
    (progn
      (setq dx (- (car (cadr bb)) (car (car bb)))
            dy (- (cadr (cadr bb)) (cadr (car bb)))
            dz (- (caddr (cadr bb)) (caddr (car bb))))
      (setq win (float (fix (+ (max dx dy) 0.5))))
      (if (and (null hin) (> dz 12.0))
        (setq hin (float (fix (+ dz 0.5)))))
      (if (> win 0.0) (setq meas T) (setq win nil))))
  ;; hand: property set first (any *SWING*/*HAND* property), else geometry
  (if (and needhand (not cased))
    (progn
      (setq swingval (strcase (sch:val->str
                       (sch:pset-val psets "*OBJECTS" "*SWING*,*HAND*"))))
      (cond ((wcmatch swingval "*LEFT*,LH*") (setq hand "LH"))
            ((wcmatch swingval "*RIGHT*,RH*") (setq hand "RH"))
            (t (setq hand (sch:door-hand vlaObj walls))))))
  (if cased
    (progn
      (setq wrec (if center (sch:nearest-wall center walls 24.0)))
      (setq wallcls (sch:wall-class wrec))))
  (list (cons "KIND" kind) (cons "MARK" mark) (cons "CODE" code)
        (cons "MULT" mult) (cons "WIN" win) (cons "HIN" hin)
        (cons "HAND" hand) (cons "CASED" cased) (cons "WALL" wallcls)
        (cons "STYLE" style) (cons "MEAS" meas) (cons "SRC" "aec")))

;; INSERT-tag fallback: collect tag inserts from a list of
;; (vlaIns . worldPt) pairs. Returns list of records.
(defun sch:harvest-tag-inserts (inserts / bubbles sizes name atts tag val
                                 rec out pt best bestd d sc kind)
  ;; classify
  (foreach ip inserts
    (setq name (strcase (sch:val->str (sch:prop (car ip) 'EffectiveName))))
    (if (= name "") (setq name (strcase (sch:val->str
                                  (sch:prop (car ip) 'Name)))))
    (setq atts (sch:invoke (car ip) 'GetAttributes nil))
    (if atts
      (foreach a atts
        (setq tag (strcase (sch:val->str (sch:prop a 'TagString)))
              val (sch:trim (sch:val->str (sch:prop a 'TextString))))
        (cond
          ((wcmatch tag "*`:DSLD_NUMBER")
           (setq kind (if (wcmatch tag "DOOROBJECTS*") "DOOR" "WINDOW"))
           (setq sc (sch:num-prop (car ip) "XScaleFactor"))
           (setq bubbles (cons (list (cdr ip) val kind
                                     (if sc (abs sc) 1.0))
                               bubbles)))
          ((wcmatch tag "*`:STANDARDSIZEDESCRIPTION,*`:WIDTH")
           (setq kind (if (wcmatch tag "DOOROBJECTS*") "DOOR" "WINDOW"))
           (setq sizes (cons (list (cdr ip) val kind) sizes)))))))
  ;; pair each bubble with nearest same-kind size tag
  (foreach b bubbles
    (setq pt (car b) best nil bestd (* *sch:tagpair-dist* (cadddr b)))
    (foreach s sizes
      (if (= (caddr s) (caddr b))
        (progn
          (setq d (distance pt (car s)))
          (if (< d bestd) (setq bestd d best s)))))
    (setq d (if best (sch:parse-size (cadr best))))
    (setq rec (list (cons "KIND" (caddr b))
                    (cons "MARK" (cadr b))
                    (cons "CODE" (if best (cadr best) ""))
                    (cons "MULT" (if d (car d) 1))
                    (cons "WIN" (if d (cadr d)))
                    (cons "HIN" (if d (caddr d)))
                    (cons "HAND" nil)
                    (cons "CASED" nil) (cons "WALL" nil)
                    (cons "STYLE" "") (cons "SRC" "tag")))
    (setq out (cons rec out)))
  out)

;; xref harvesting: walk an xref insert's block definition with a fast
;; entget/entnext scan (no per-entity COM roundtrips - the old vlax-for
;; walk made huge xrefs unusably slow), transform candidate points to
;; world, keep those inside box p1-p2.
(defun sch:harvest-xref (vlaIns p1 p2 walls / bname bdef e ed dxf nm ip
                          rot sx sy out c wpt kind cased inserts v
                          cnt nd nw)
  (setq bname (sch:val->str (sch:prop vlaIns 'Name)))
  (setq ip (sch:catch 'vlax-safearray->list
             (list (vlax-variant-value (vla-get-InsertionPoint vlaIns))))
        rot (sch:num-prop vlaIns "Rotation")
        sx (sch:num-prop vlaIns "XScaleFactor")
        sy (sch:num-prop vlaIns "YScaleFactor"))
  (if (null rot) (setq rot 0.0))
  (if (null sx) (setq sx 1.0))
  (if (null sy) (setq sy 1.0))
  (setq bdef (tblsearch "BLOCK" bname))
  (setq e (if bdef (cdr (assoc -2 bdef))))
  (setq cnt 0 nd 0 nw 0)
  (while e
    (setq cnt (1+ cnt)
          ed (entget e)
          dxf (cdr (assoc 0 ed))
          kind nil cased nil)
    (cond
      ((= dxf "AEC_DOOR") (setq kind "DOOR"))
      ((= dxf "AEC_WINDOW") (setq kind "WINDOW"))
      ((= dxf "AEC_WINDOW_ASSEMBLY") (setq kind "WINDOW"))
      ((= dxf "AEC_OPENING") (setq kind "DOOR" cased T)))
    (cond
      (kind
       (setq v (sch:vla e)
             c (if v (sch:bbox-center v)))
       (if c
         (progn
           (setq wpt (sch:xform-pt c ip rot sx sy))
           (if (sch:pt-in-box wpt p1 p2)
             ;; note: hand detection skipped for xref-resident
             ;; doors (cannot safely explode inside an xref)
             (progn
               (if (= kind "DOOR") (setq nd (1+ nd)) (setq nw (1+ nw)))
               (setq out (cons (sch:harvest-aec v kind cased walls nil)
                               out)))))))
      ((and (= dxf "INSERT")
            (setq nm (cdr (assoc 2 ed)))
            (wcmatch (strcase nm) "TK_DOOR_TAG*,TK_WINDOW_TAG*"))
       (setq c (cdr (assoc 10 ed)))
       (if c
         (progn
           (setq wpt (sch:xform-pt c ip rot sx sy))
           (if (sch:pt-in-box wpt p1 p2)
             (setq inserts (cons (cons (sch:vla e) wpt) inserts)))))))
    (setq e (entnext e)))
  ;; per-xref readout: shows whether the xref could be scanned at all
  (princ (strcat "\n[SCH]   xref \"" bname "\": " (itoa cnt)
                 " entities scanned, " (itoa nd) " doors / " (itoa nw)
                 " windows inside the region."))
  (if (= cnt 0)
    (princ (strcat "\n[SCH]   (xref \"" bname
                   "\" not walkable - probably demand-loaded. Open that construct and run SCH inside it, or set XLOADCTL to 0 and reload.)")))
  ;; same rule as the top-level harvest: tag records only for kinds
  ;; with no AEC objects found (avoids double-counting tagged doors)
  (if inserts
    (setq out
      (append out
        (vl-remove-if
          '(lambda (r)
             (vl-some '(lambda (q) (and (= (sch:rget q "KIND")
                                           (sch:rget r "KIND"))
                                        (= (sch:rget q "SRC") "aec")))
                      out))
          (sch:harvest-tag-inserts inserts)))))
  out)

;; main harvest: user picks two corners; returns list of records
(defun sch:harvest ( / p1 p2 ss i n e v on walls recs inserts kind cased
                       isxref bd nAd nAw nAo nPx nTag nXr)
  (setq p1 (getpoint "\nSchedule area - first corner of plan region: "))
  (if p1 (setq p2 (getcorner p1 "\nOpposite corner: ")))
  (if (and p1 p2)
    (progn
      (princ "\n[SCH] Scanning selection")
      (setq walls (sch:collect-walls))
      (setq nAd 0 nAw 0 nAo 0 nPx 0 nTag 0 nXr 0)
      (setq ss (ssget "_C" p1 p2
                 '((0 . "AEC_DOOR,AEC_WINDOW,AEC_WINDOW_ASSEMBLY,AEC_OPENING,INSERT,ACAD_PROXY_ENTITY"))))
      (if ss
        (progn
          (setq i 0 n (sslength ss))
          (while (< i n)
            (if (= (rem i 25) 0) (princ "."))
            (setq e (ssname ss i)
                  on (cdr (assoc 0 (entget e)))
                  kind nil cased nil v nil)
            (cond
              ((= on "AEC_DOOR") (setq kind "DOOR" nAd (1+ nAd)))
              ((= on "AEC_WINDOW") (setq kind "WINDOW" nAw (1+ nAw)))
              ((= on "AEC_WINDOW_ASSEMBLY")
               (setq kind "WINDOW" nAw (1+ nAw)))
              ((= on "AEC_OPENING") (setq kind "DOOR" cased T
                                          nAo (1+ nAo)))
              ((= on "ACAD_PROXY_ENTITY") (setq nPx (1+ nPx))))
            (cond
              (kind
               (setq v (sch:vla e))
               ;; swing-hand detection is doors-only
               (if v
                 (setq recs (cons (sch:harvest-aec v kind cased walls
                                                   (= kind "DOOR"))
                                  recs))))
              ((= on "INSERT")
               (setq v (sch:vla e))
               (setq isxref nil)
               (setq bd (sch:catch 'vla-Item
                          (list (vla-get-Blocks
                                  (vla-get-ActiveDocument
                                    (vlax-get-acad-object)))
                                (sch:val->str (sch:prop v 'Name)))))
               (if (and bd (= (sch:prop bd 'IsXRef) :vlax-true))
                 (setq isxref T))
               (cond
                 (isxref
                  (setq nXr (1+ nXr))
                  (setq recs (append recs
                               (sch:harvest-xref v p1 p2 walls))))
                 ((wcmatch (strcase (sch:val->str (sch:prop v 'Name)))
                           "TK_DOOR_TAG*,TK_WINDOW_TAG*")
                  (setq nTag (1+ nTag))
                  (setq inserts
                    (cons (cons v
                                (sch:catch 'vlax-safearray->list
                                  (list (vlax-variant-value
                                          (vla-get-InsertionPoint v)))))
                          inserts))))))
            (setq i (1+ i)))))
      ;; readable breakdown so an empty/partial result explains itself
      (princ (strcat "\n[SCH] Region contents: " (itoa nAd)
                     " AEC doors, " (itoa nAw) " AEC windows, "
                     (itoa nAo) " AEC openings, " (itoa nTag)
                     " tag inserts, " (itoa nXr) " xrefs, "
                     (itoa nPx) " proxy entities."))
      (if (> nPx 0)
        (princ "\n[SCH] NOTE: proxy entities are unreadable here - that data needs AutoCAD Architecture (or AEC object enablers)."))
      ;; use tag-INSERT provider only for kinds with no AEC objects found
      (if inserts
        (progn
          (setq inserts (vl-remove-if '(lambda (x) (null (cdr x))) inserts))
          (setq recs
            (append recs
              (vl-remove-if
                '(lambda (r)
                   (vl-some '(lambda (q) (and (= (sch:rget q "KIND")
                                                 (sch:rget r "KIND"))
                                              (= (sch:rget q "SRC") "aec")))
                            recs))
                (sch:harvest-tag-inserts inserts))))))
      recs)))

;;; ------------------------------------------------------------------
;;; Aggregation
;;; agg row: (mark widthIn heightIn qty lh rh cased wallcls codes notes)
;;; ------------------------------------------------------------------

;; grouping key: mark when readable; otherwise size code, else the
;; measured WxH plus style name - so unmarked doors of different sizes
;; and styles land on separate schedule rows instead of one big group.
(defun sch:agg-key (r / sz)
  (strcat (sch:rget r "KIND") "|"
          (if (/= (sch:rget r "MARK") "") (sch:rget r "MARK")
            (progn
              (setq sz
                (if (/= (sch:rget r "CODE") "") (sch:rget r "CODE")
                  (strcat
                    (if (sch:rget r "WIN")
                      (rtos (sch:rget r "WIN") 2 1) "?")
                    "x"
                    (if (sch:rget r "HIN")
                      (rtos (sch:rget r "HIN") 2 1) "?"))))
              (strcat "?" sz "|"
                      (if (sch:rget r "STYLE") (sch:rget r "STYLE") "")
                      "|"
                      (if (sch:rget r "CASED") "C" "")
                      (if (sch:rget r "WALL") (sch:rget r "WALL") ""))))))

(defun sch:aggregate (recs kind / groups key g out mark win hin qty lh rh
                        cased wall code notes sty mlt meas)
  (setq groups nil)
  (foreach r recs
    (if (= (sch:rget r "KIND") kind)
      (progn
        (setq key (sch:agg-key r)
              g (assoc key groups))
        (if g
          (setq groups (subst (cons key (cons r (cdr g))) g groups))
          (setq groups (cons (cons key (list r)) groups))))))
  (foreach g groups
    (setq mark "" win nil hin nil qty 0 lh 0 rh 0
          cased nil wall nil code "" notes "" sty "" mlt 1 meas nil)
    (foreach r (cdr g)
      (setq qty (+ qty 1))
      (if (sch:rget r "MEAS") (setq meas T))
      (if (and (= sty "") (sch:rget r "STYLE")
               (/= (sch:rget r "STYLE") ""))
        (setq sty (sch:rget r "STYLE")))
      (if (and (sch:rget r "MULT") (> (sch:rget r "MULT") 1))
        (setq mlt (sch:rget r "MULT")))
      (if (and (= mark "") (/= (sch:rget r "MARK") ""))
        (setq mark (sch:rget r "MARK")))
      (if (and (null win) (sch:rget r "WIN"))
        (setq win (* (sch:rget r "WIN")
                     (if (sch:rget r "MULT") (sch:rget r "MULT") 1))))
      (if (and (null hin) (sch:rget r "HIN")) (setq hin (sch:rget r "HIN")))
      (if (= code "") (setq code (sch:rget r "CODE")))
      (if (sch:rget r "CASED") (setq cased T))
      (if (and (null wall) (sch:rget r "WALL")) (setq wall (sch:rget r "WALL")))
      (cond ((= (sch:rget r "HAND") "LH") (setq lh (1+ lh)))
            ((= (sch:rget r "HAND") "RH") (setq rh (1+ rh)))))
    (if (and (= kind "DOOR") (not cased) (< (+ lh rh) qty))
      (setq notes (strcat (itoa (- qty lh rh)) " swing unknown")))
    (if meas
      (setq notes (strcat notes (if (= notes "") "" "; ")
                          "sizes measured from geometry - verify")))
    (setq out (cons (list mark win hin qty lh rh cased wall code notes
                          sty mlt)
                    out)))
  out)

;;; ------------------------------------------------------------------
;;; Table access
;;; ------------------------------------------------------------------

(defun sch:tbl-get (tbl r c / v)
  (setq v (sch:invoke tbl 'GetText (list r c)))
  (if (null v) (setq v (sch:invoke tbl 'GetTextString (list r c))))
  (if (eq (type v) 'STR) v ""))

(defun sch:tbl-set (tbl r c txt / v)
  (setq v (sch:invoke tbl 'SetText (list r c txt)))
  (if (null v) (setq v (sch:invoke tbl 'SetTextString (list r c txt))))
  v)

(defun sch:pick-table (prompt / es v done out)
  (while (not done)
    (setvar "ERRNO" 0)
    (setq es (entsel prompt))
    (cond
      ((and (null es) (= (getvar "ERRNO") 7)) ; missed pick - re-prompt
       (princ "\n[SCH] Nothing there - pick the table or press Enter to skip."))
      ((null es) (setq done T out nil)) ; genuine Enter = skip
      (t
       (setq v (sch:vla (car es)))
       (if (= (sch:objname v) "AcDbTable")
         (setq done T out v)
         (princ "\n[SCH] That is not a table - pick the schedule table or press Enter to cancel.")))))
  out)

;; returns (title headerRowIdx colmap rows cols marks)
;; colmap = assoc of header name -> col index
;; marks = list of (markText . rowIdx) for data rows
(defun sch:table-info (tbl / rows cols r c txt title hdr colmap marks)
  (setq rows (sch:prop tbl 'Rows) cols (sch:prop tbl 'Columns))
  (if (null rows) (setq rows 0))
  (if (null cols) (setq cols 0))
  (setq title (sch:strip-fmt (sch:tbl-get tbl 0 0)))
  ;; find header row
  (setq r 0)
  (while (and (< r rows) (null hdr))
    (if (= (strcase (sch:strip-fmt (sch:tbl-get tbl r 0))) "MARK")
      (setq hdr r))
    (setq r (1+ r)))
  (if hdr
    (progn
      (setq c 0)
      (while (< c cols)
        (setq txt (strcase (sch:strip-fmt (sch:tbl-get tbl hdr c))))
        (if (/= txt "")
          (setq colmap (cons (cons txt c) colmap)))
        (setq c (1+ c)))
      (setq r (1+ hdr))
      (while (< r rows)
        (setq txt (sch:strip-fmt (sch:tbl-get tbl r 0)))
        (setq marks (cons (cons txt r) marks))
        (setq r (1+ r)))))
  (list title hdr colmap rows cols (reverse marks)))

;; all tables whose title matches pat AND that have a MARK header row
;; -> list of (tbl info)
(defun sch:find-tables (pat / ss i tbl info out)
  (setq ss (ssget "_X" '((0 . "ACAD_TABLE"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq tbl (sch:vla (ssname ss i))
              info (sch:table-info tbl))
        (if (and (wcmatch (strcase (car info)) pat) (cadr info))
          (setq out (cons (list tbl info) out)))
        (setq i (1+ i)))))
  (reverse out))

;; create a DSLD-format schedule table at pt (top-left corner).
;; ndata = expected data rows (3 blank spare rows are added).
;; Matches the DSLD sheets: cols MARK|WIDTH|HEIGHT|QTY|DESCRIPTION,
;; widths 27/30/33/21/177, row heights 14/13.33/12, text 6/5.5/4.5,
;; "DSLD Table Style" when the drawing has it. Returns (tbl info).
(defun sch:make-table (title pt ndata / doc msp tbl rows r c widths hdrs)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object))
        msp (vla-get-ModelSpace doc)
        rows (+ 2 ndata 3))
  (setq tbl (sch:catch 'vlax-invoke
              (list msp 'AddTable
                    (list (car pt) (cadr pt) 0.0) rows 5 12.0 57.6)))
  (if tbl
    (progn
      ;; use the DSLD table style if this drawing has it
      (sch:catch 'vlax-put-property (list tbl 'StyleName "DSLD Table Style"))
      (sch:invoke tbl 'SetRowHeight (list 0 14.0))
      (sch:invoke tbl 'SetRowHeight (list 1 13.3333))
      (setq widths '(27.0 30.0 33.0 21.0 177.0) c 0)
      (foreach w widths
        (sch:invoke tbl 'SetColumnWidth (list c w))
        (setq c (1+ c)))
      ;; row types: acDataRow=1 acTitleRow=2 acHeaderRow=4
      (sch:invoke tbl 'SetTextHeight (list 2 6.0))
      (sch:invoke tbl 'SetTextHeight (list 4 5.5))
      (sch:invoke tbl 'SetTextHeight (list 1 4.5))
      ;; data rows middle-center, DESCRIPTION column middle-left
      (sch:invoke tbl 'SetAlignment (list 1 5))
      (setq r 2)
      (while (< r rows)
        (sch:invoke tbl 'SetCellAlignment (list r 4 4))
        (setq r (1+ r)))
      (sch:tbl-set tbl 0 0 title)
      (setq hdrs '("MARK" "WIDTH" "HEIGHT" "QTY" "DESCRIPTION") c 0)
      (foreach h hdrs
        (sch:tbl-set tbl 1 c h)
        (setq c (1+ c)))
      (list tbl (sch:table-info tbl)))))

;; locate the schedule table for one kind, or create it where the
;; user points. Exactly one match -> used automatically; several ->
;; user picks; none -> user picks an insertion point for a new one.
;; Returns (tbl info) or nil.
(defun sch:resolve-table (title pat ndata / cands tbl info pt)
  (setq cands (sch:find-tables pat))
  (cond
    ((= (length cands) 1)
     (princ (strcat "\n[SCH] Found existing " title " - using it."))
     (car cands))
    ((> (length cands) 1)
     (princ (strcat "\n[SCH] " (itoa (length cands))
                    " tables match " title " (multiple schedule sets)."))
     (setq tbl (sch:pick-table
                 (strcat "\nSelect the " title
                         " to fill (Enter to skip): ")))
     (if tbl
       (progn
         (setq info (sch:table-info tbl))
         (if (cadr info)
           (list tbl info)
           (progn
             (princ "\n[SCH] That table has no MARK header row - skipped.")
             nil)))))
    (t
     (princ (strcat "\n[SCH] No " title " found in this drawing."))
     (setq pt (getpoint (strcat "\nPick top-left corner for a new "
                                title " (Enter to skip): ")))
     (if pt (sch:make-table title pt ndata)))))

;;; ------------------------------------------------------------------
;;; Merge: aggregated data + existing table -> planned rows
;;; plan entry:
;;;  (rowIdx|nil mark wtxt htxt qtyTxt lhTxt rhTxt descTxt|nil flag)
;;;  descTxt nil = leave existing description untouched
;;;  flag: "=" unchanged / "~" changed / "+" new / "!" attention
;;; ------------------------------------------------------------------

(defun sch:col (info name / e)
  (setq e (assoc name (caddr info)))
  (if e (cdr e)))

(defun sch:mark<num (a b) (< (atoi (car a)) (atoi (car b))))
(defun sch:mark<alpha (a b) (< (car a) (car b)))

(defun sch:next-num-mark (used / m)
  (setq m 1)
  (while (member (itoa m) used) (setq m (1+ m)))
  (itoa m))

(defun sch:next-alpha-mark (used / i m)
  (setq i 0 m nil)
  (while (and (< i 26) (null m))
    (if (not (member (chr (+ 65 i)) used))
      (setq m (chr (+ 65 i))))
    (setq i (1+ i)))
  (if m m "?"))

(defun sch:cased-desc (wall)
  (if wall
    (strcat "CASED OPENING - " wall "\" WALL")
    "CASED OPENING"))

;; standard DSLD description for a NEW schedule row, from the style
;; name (pattern map in the config block), kind, leaf count and width.
(defun sch:auto-desc (kind style mult win / s out)
  (setq s (strcase (if style style "")))
  (foreach pair *sch:desc-map*
    (if (and (null out) (/= s "") (wcmatch s (car pair)))
      (setq out (cdr pair))))
  (if (and (null out) (= kind "DOOR") (numberp win) (>= win 90.0))
    (setq out "OVERHEAD GARAGE DOOR")) ; very wide non-cased door
  (if (null out)
    (setq out (if (= kind "WINDOW")
                *sch:desc-window-default*
                *sch:desc-door-default*)))
  (if (and (= kind "DOOR") mult (> mult 1)
           (not (wcmatch (strcase out) "DBL*")))
    (setq out (strcat "DBL. " out)))
  out)

;; first "spare" data row mark: mark pre-filled (like the window
;; table's F/G/H rows) but QTY and WIDTH cells empty; skips marks
;; already taken this run. Returns the mark string or nil.
(defun sch:spare-mark (tbl info taken / out m r)
  (foreach m (nth 5 info)
    (if (and (null out) (/= (car m) "")
             (not (member (car m) taken)))
      (progn
        (setq r (cdr m))
        (if (and (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "QTY"))) "")
                 (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "WIDTH"))) ""))
          (setq out (car m))))))
  out)

;; first completely blank data row (no mark, no qty, no width),
;; excluding row indices in skip. Returns row index or nil.
(defun sch:blank-row (tbl info skip / out m r)
  (foreach m (nth 5 info)
    (if (and (null out) (= (car m) "")
             (not (member (cdr m) skip)))
      (progn
        (setq r (cdr m))
        (if (and (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "QTY"))) "")
                 (= (sch:strip-fmt
                      (sch:tbl-get tbl r (sch:col info "WIDTH"))) ""))
          (setq out r)))))
  out)

;; find an existing row for an agg row.
;; priority: same mark; else (cased rows) row whose desc contains CASED
;; with same W/H; else same W/H unique.
(defun sch:find-row (agg tbl info / mark marks hit wtxt htxt cw ch cd r
                       cand n)
  (setq mark (car agg) marks (nth 5 info))
  (if (/= mark "")
    (setq hit (assoc mark marks)))
  (if (and (null hit) (cadr agg) (caddr agg))
    (progn
      (setq wtxt (sch:ftin (cadr agg)) htxt (sch:ftin (caddr agg))
            n 0)
      (foreach m marks
        (setq r (cdr m)
              cw (sch:strip-fmt (sch:tbl-get tbl r (sch:col info "WIDTH")))
              ch (sch:strip-fmt (sch:tbl-get tbl r (sch:col info "HEIGHT")))
              cd (strcase (sch:strip-fmt
                    (sch:tbl-get tbl r (sch:col info "DESCRIPTION")))))
        (if (and (= cw wtxt) (= ch htxt)
                 (or (and (nth 6 agg) (wcmatch cd "*CASED*"))
                     (and (not (nth 6 agg)) (not (wcmatch cd "*CASED*")))))
          (progn (setq cand m n (1+ n)))))
      (if (= n 1) (setq hit cand))))
  hit)

;; Build plan for one table.
;; kind "WINDOW"|"DOOR"; aggs = sch:aggregate output.
(defun sch:merge (tbl info aggs kind / plan used marks hit rowidx mark wtxt
                    htxt qty lh rh desc flag curw curh curq curd r
                    sorted sparetaken)
  (setq marks (nth 5 info))
  (foreach m marks
    (if (/= (car m) "") (setq used (cons (car m) used))))
  ;; marks already carried by harvested aggs are taken too - a freshly
  ;; assigned mark must not collide with a tagged opening in this run
  (foreach a aggs
    (if (/= (car a) "") (setq used (cons (car a) used))))
  ;; assign marks to unmarked aggs
  (setq aggs
    (mapcar
      '(lambda (a / hit2 mk sp)
         (if (= (car a) "")
           (progn
             (setq hit2 (sch:find-row a tbl info))
             (setq mk (cond
                        (hit2 (car hit2))
                        ;; pre-filled spare rows (F/G/H style) first
                        ((setq sp (sch:spare-mark tbl info sparetaken))
                         (setq sparetaken (cons sp sparetaken))
                         sp)
                        ((= kind "DOOR") (sch:next-num-mark used))
                        (t (sch:next-alpha-mark used))))
             (setq used (cons mk used))
             (cons mk (cdr a)))
           a))
      aggs))
  ;; sort
  (setq sorted
    (if (= kind "DOOR")
      (vl-sort aggs '(lambda (a b) (< (atoi (car a)) (atoi (car b)))))
      (vl-sort aggs '(lambda (a b) (< (car a) (car b))))))
  (foreach a sorted
    (setq mark (car a)
          wtxt (if (cadr a) (sch:ftin (cadr a)) "")
          htxt (if (caddr a) (sch:ftin (caddr a)) "")
          qty (itoa (nth 3 a))
          lh (if (nth 6 a) "" (itoa (nth 4 a)))
          rh (if (nth 6 a) "" (itoa (nth 5 a)))
          desc (if (nth 6 a) (sch:cased-desc (nth 7 a)) nil)
          hit (sch:find-row a tbl info)
          flag "+")
    (if hit
      (progn
        (setq rowidx (cdr hit)
              curw (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "WIDTH")))
              curh (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "HEIGHT")))
              curq (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "QTY")))
              curd (sch:strip-fmt (sch:tbl-get tbl rowidx
                                               (sch:col info "DESCRIPTION"))))
        ;; keep an existing non-empty description unless cased text changes
        (if (and desc (/= curd "")
                 (= (strcase curd) (strcase desc)))
          (setq desc nil))
        (if (and desc (/= curd "") (not (wcmatch (strcase curd) "*CASED*")))
          (setq desc nil)) ; don't clobber a real description
        ;; fill an EMPTY existing description with the standard text
        (if (and (null desc) (= curd "") (not (nth 6 a)))
          (setq desc (sch:auto-desc kind (nth 10 a) (nth 11 a)
                                    (cadr a))))
        (setq flag
          (if (and (or (= wtxt "") (= curw wtxt))
                   (or (= htxt "") (= curh htxt))
                   (= curq qty)
                   (null desc))
            "=" "~")))
      (setq rowidx nil))
    (if (and (= flag "+") (null desc) (not (nth 6 a)))
      (setq desc (sch:auto-desc kind (nth 10 a) (nth 11 a) (cadr a))))
    (setq plan (cons (list rowidx mark wtxt htxt qty lh rh desc flag
                           (nth 9 a))
                     plan)))
  ;; existing data rows with content that were not matched
  (foreach m marks
    (if (and (/= (car m) "")
             (not (vl-some '(lambda (p) (equal (cdr m) (car p))) plan)))
      (progn
        (setq curq (sch:strip-fmt (sch:tbl-get tbl (cdr m)
                                               (sch:col info "QTY"))))
        (if (/= curq "")
          (setq plan (cons (list (cdr m) (car m) "" "" "" "" "" nil "!"
                                 "in table, not found in selection")
                           plan))))))
  (reverse plan))

;;; ------------------------------------------------------------------
;;; Preview dialog (DCL written to temp file)
;;; ------------------------------------------------------------------

;; returns the DCL path, or nil if the temp file cannot be created
(defun sch:dcl-file ( / path f)
  (setq path (vl-filename-mktemp "sch_prev.dcl"))
  (setq f (open path "w"))
  (if (null f)
    nil
    (progn
  (write-line "sch_preview : dialog {" f)
  (write-line "  label = \"SCH - Schedule Fill Preview\";" f)
  (write-line "  : text { key = \"summary\"; width = 110; }" f)
  (write-line "  : boxed_column { label = \"WINDOW SCHEDULE\";" f)
  (write-line "    : list_box { key = \"wlist\"; width = 110; height = 8;" f)
  (write-line "      tabs = \"4 12 22 32 40 46 52\"; }" f)
  (write-line "  }" f)
  (write-line "  : boxed_column { label = \"DOOR SCHEDULE\";" f)
  (write-line "    : list_box { key = \"dlist\"; width = 110; height = 12;" f)
  (write-line "      tabs = \"4 12 22 32 40 46 52\"; }" f)
  (write-line "  }" f)
  (write-line "  : boxed_column { label = \"Notes\";" f)
  (write-line "    : list_box { key = \"nlist\"; width = 110; height = 4; }" f)
  (write-line "  }" f)
  (write-line "  : boxed_radio_row { label = \"LH/RH placement (doors)\"; key = \"handmode\";" f)
  (write-line "    : radio_button { key = \"hm_cols\"; label = \"Insert LH / RH columns after QTY\"; }" f)
  (write-line "    : radio_button { key = \"hm_desc\"; label = \"Append counts to DESCRIPTION\"; }" f)
  (write-line "  }" f)
  (write-line "  : row {" f)
  (write-line "    : button { key = \"accept\"; label = \"Apply to Tables\"; is_default = true; }" f)
  (write-line "    : button { key = \"cancel\"; label = \"Cancel\"; is_cancel = true; }" f)
  (write-line "  }" f)
  (write-line "}" f)
  (close f)
  path)))

(defun sch:plan-line (p / flag)
  (setq flag (nth 8 p))
  (strcat flag "\t" (cadr p) "\t" (caddr p) "\t" (cadddr p) "\t"
          (nth 4 p) "\t" (nth 5 p) "\t" (nth 6 p) "\t"
          (cond ((nth 7 p) (nth 7 p))
                (t "(keep existing)"))))

(defun sch:preview (wplan dplan notes / dclpath dclid ok line)
  (setq dclpath (sch:dcl-file)
        dclid (if dclpath (load_dialog dclpath) 0)
        ok nil)
  (if (and dclid (> dclid 0) (new_dialog "sch_preview" dclid))
    (progn
      (set_tile "summary"
        (strcat "  " (itoa (length wplan)) " window rows, "
                (itoa (length dplan)) " door rows.   "
                "Flags:  + new row   ~ changed   = unchanged   ! attention"
                "   |   MARK  WIDTH  HEIGHT  QTY  LH  RH  DESCRIPTION"))
      (start_list "wlist")
      (foreach p wplan (add_list (sch:plan-line p)))
      (end_list)
      (start_list "dlist")
      (foreach p dplan (add_list (sch:plan-line p)))
      (end_list)
      (start_list "nlist")
      (if notes
        (foreach x notes (add_list x))
        (add_list "(none)"))
      (end_list)
      (set_tile (if (= *sch:handmode* "desc") "hm_desc" "hm_cols") "1")
      (action_tile "hm_cols" "(setq *sch:handmode* \"cols\")")
      (action_tile "hm_desc" "(setq *sch:handmode* \"desc\")")
      (action_tile "accept" "(done_dialog 1)")
      (action_tile "cancel" "(done_dialog 0)")
      (setq ok (= (start_dialog) 1)))
    (progn
      ;; DCL failed - fall back to command-line preview + confirm
      (princ "\n--- SCH preview (dialog unavailable) ---")
      (princ "\nWINDOW SCHEDULE:")
      (foreach p wplan
        (setq line (sch:plan-line p))
        (princ (strcat "\n  " (vl-string-translate "\t" " " line))))
      (princ "\nDOOR SCHEDULE:")
      (foreach p dplan
        (setq line (sch:plan-line p))
        (princ (strcat "\n  " (vl-string-translate "\t" " " line))))
      (foreach x notes (princ (strcat "\n  NOTE: " x)))
      (initget "Yes No")
      (setq ok (= (getkword "\nApply to tables? [Yes/No] <No>: ") "Yes"))))
  ;; unload whenever a dialog was actually loaded (even if new_dialog
  ;; failed and we fell back to the command line)
  (if (and dclid (> dclid 0)) (unload_dialog dclid))
  (if dclpath (vl-file-delete dclpath))
  ok)

;;; ------------------------------------------------------------------
;;; Apply
;;; ------------------------------------------------------------------

;; ensure LH/RH columns exist on the door table (cols mode).
;; returns updated info.
(defun sch:ensure-hand-cols (tbl info / qtycol hdr r)
  (setq qtycol (sch:col info "QTY") hdr (cadr info))
  (if (and qtycol hdr (null (sch:col info "LH")))
    (progn
      (sch:invoke tbl 'InsertColumns (list (1+ qtycol) 21.0 2))
      (sch:tbl-set tbl hdr (1+ qtycol) "LH")
      (sch:tbl-set tbl hdr (+ 2 qtycol) "RH")
      (sch:catch 'vlax-invoke
        (list tbl 'SetColumnWidth (1+ qtycol) 21.0))
      (sch:catch 'vlax-invoke
        (list tbl 'SetColumnWidth (+ 2 qtycol) 21.0))
      (setq info (sch:table-info tbl))))
  info)

;; append a new data row at the bottom; returns new row index or nil.
;; InsertRows is a void method - success is verified by the row count
;; actually growing, never by the (always-nil) return value.
(defun sch:append-row (tbl info / rows h newrows)
  (setq rows (nth 3 info))
  (setq h (sch:invoke tbl 'GetRowHeight (list (1- rows))))
  (if (null h) (setq h 12.0))
  (sch:invoke tbl 'InsertRows (list rows h 1))
  (setq newrows (sch:prop tbl 'Rows))
  (if (and newrows (> newrows rows)) rows))

;; remove a previously appended "N LH / N RH" clause from a description
;; so re-runs refresh the counts instead of keeping stale ones
(defun sch:strip-hand (s / i j)
  (if (setq i (vl-string-search " LH / " s)) ; 0-based match position
    (progn
      (setq j i) ; 1-based index of the char just before the match
      (while (and (> j 0) (wcmatch (substr s j 1) "#"))
        (setq j (1- j))) ; walk back over the LH count digits
      (vl-string-right-trim " -" (substr s 1 j)))
    s))

(defun sch:apply-plan (tbl info plan kind / r p rowidx desc lhc rhc
                         written handcols newrows)
  (setq written 0)
  (setq handcols (and (= kind "DOOR") (= *sch:handmode* "cols")))
  (if handcols (setq info (sch:ensure-hand-cols tbl info)))
  (foreach p plan
    (if (/= (nth 8 p) "!")
      (progn
        (setq rowidx (car p))
        (if (null rowidx)
          (progn
            ;; consume a blank spare row first, only then grow the table
            (setq rowidx (sch:blank-row tbl info newrows))
            (if (null rowidx)
              (setq rowidx (sch:append-row tbl info)
                    info (if rowidx (sch:table-info tbl) info)))
            (if rowidx (setq newrows (cons rowidx newrows)))))
        (if rowidx
          (progn
            (sch:tbl-set tbl rowidx (sch:col info "MARK") (cadr p))
            (if (/= (caddr p) "")
              (sch:tbl-set tbl rowidx (sch:col info "WIDTH") (caddr p)))
            (if (/= (cadddr p) "")
              (sch:tbl-set tbl rowidx (sch:col info "HEIGHT") (cadddr p)))
            (sch:tbl-set tbl rowidx (sch:col info "QTY") (nth 4 p))
            (if (and handcols (sch:col info "LH"))
              (progn
                (sch:tbl-set tbl rowidx (sch:col info "LH") (nth 5 p))
                (sch:tbl-set tbl rowidx (sch:col info "RH") (nth 6 p))))
            (setq desc (nth 7 p))
            (if (and (= kind "DOOR") (= *sch:handmode* "desc")
                     (or (/= (nth 5 p) "") (/= (nth 6 p) ""))
                     (or (/= (nth 5 p) "0") (/= (nth 6 p) "0")))
              (progn
                (if (null desc)
                  (setq desc (sch:strip-fmt
                               (sch:tbl-get tbl rowidx
                                            (sch:col info "DESCRIPTION")))))
                (setq desc (sch:strip-hand desc))
                (setq desc (strcat desc
                             (if (= desc "") "" " - ")
                             (nth 5 p) " LH / " (nth 6 p) " RH"))))
            (if desc
              (sch:tbl-set tbl rowidx (sch:col info "DESCRIPTION") desc))
            (setq written (1+ written)))))))
  written)

;;; ------------------------------------------------------------------
;;; c:SCH - main command
;;; ------------------------------------------------------------------

(defun c:SCH ( / doc recs waggs daggs wres dres wtbl dtbl winfo dinfo
                 wplan dplan notes ok n oldecho *error*)
  (defun *error* (msg)
    (if doc (sch:catch 'vla-EndUndoMark (list doc)))
    (if oldecho (setvar "CMDECHO" oldecho))
    (if (and msg (not (wcmatch (strcase msg) "*BREAK*,*CANCEL*,*EXIT*")))
      (princ (strcat "\n[SCH] Error: " msg)))
    (princ))
  (setq oldecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  (setq doc (vla-get-ActiveDocument (vlax-get-acad-object)))
  (sch:catch 'vla-StartUndoMark (list doc))
  (setq recs (sch:harvest))
  (cond
    ((null recs)
     (princ "\n[SCH] Nothing found. Select a region containing doors/windows (AEC objects or TK_ tag blocks)."))
    (t
     (princ (strcat "\n[SCH] Found " (itoa (length recs)) " openings ("
                    (itoa (length (vl-remove-if-not
                                    '(lambda (r) (= (sch:rget r "KIND")
                                                    "DOOR"))
                                    recs)))
                    " door / "
                    (itoa (length (vl-remove-if-not
                                    '(lambda (r) (= (sch:rget r "KIND")
                                                    "WINDOW"))
                                    recs)))
                    " window)."))
     (setq waggs (sch:aggregate recs "WINDOW")
           daggs (sch:aggregate recs "DOOR"))
     ;; locate / create the schedule tables (auto-find when unique,
     ;; pick when several sets, create at a user point when missing)
     (if waggs
       (setq wres (sch:resolve-table "WINDOW SCHEDULE" "*WINDOW*"
                                     (length waggs)))
       (princ "\n[SCH] No windows in the selection - window schedule skipped."))
     (if daggs
       (setq dres (sch:resolve-table "DOOR SCHEDULE" "*DOOR*"
                                     (length daggs)))
       (princ "\n[SCH] No doors in the selection - door schedule skipped."))
     (setq wtbl (car wres) winfo (cadr wres)
           dtbl (car dres) dinfo (cadr dres))
     (if (and (null wtbl) (null dtbl))
       (princ "\n[SCH] No schedule tables available - cancelled.")
       (progn
         (if winfo (setq wplan (sch:merge wtbl winfo waggs "WINDOW")))
         (if dinfo (setq dplan (sch:merge dtbl dinfo daggs "DOOR")))
         (foreach p (append wplan dplan)
           (if (and (nth 9 p) (/= (nth 9 p) ""))
             (setq notes (cons (strcat "Mark " (cadr p) ": " (nth 9 p))
                               notes))))
         (if (vl-some '(lambda (r) (= (sch:rget r "MARK") "")) recs)
           (setq notes
             (cons "Some openings have no readable mark - rows grouped by size/style, marks auto-assigned."
                   notes)))
         (foreach r recs
           (if (and (= (sch:rget r "SRC") "tag")
                    (= (sch:rget r "CODE") ""))
             (setq notes (cons (strcat "Tag mark " (sch:rget r "MARK")
                                       ": no size tag paired")
                               notes))))
         (setq notes (reverse notes))
         (if (null *sch:handmode*) (setq *sch:handmode* "cols"))
         (setq ok (sch:preview (if wplan wplan '()) (if dplan dplan '())
                               notes))
         (if ok
           (progn
             (setq n 0)
             (if (and wtbl wplan)
               (setq n (+ n (sch:apply-plan wtbl winfo wplan "WINDOW"))))
             (if (and dtbl dplan)
               (setq n (+ n (sch:apply-plan dtbl dinfo dplan "DOOR"))))
             (princ (strcat "\n[SCH] Done - " (itoa n) " rows written.")))
           (princ "\n[SCH] Cancelled - tables unchanged."))))))
  (sch:catch 'vla-EndUndoMark (list doc))
  (setvar "CMDECHO" oldecho)
  (princ))

;;; ------------------------------------------------------------------
;;; c:SCHDIAG - diagnostics
;;; ------------------------------------------------------------------

;; f kept for signature compatibility but IGNORED: every line is
;; opened/appended/closed individually so the report file survives an
;; AutoCAD crash - the last line on disk shows the step that killed it.
(defun sch:diag-out (f msg / fh)
  (princ (strcat "\n" msg))
  (if *sch:diag-path*
    (progn
      (setq fh (open *sch:diag-path* "a"))
      (if fh (progn (write-line msg fh) (close fh)))))
  (princ))

(defun sch:diag-count (f label filt / ss)
  (setq ss (ssget "_X" filt))
  (sch:diag-out f (strcat "  " label ": "
                          (if ss (itoa (sslength ss)) "0"))))

(defun sch:diag-props (f obj / names v)
  (if (not (and obj (eq (type obj) 'VLA-OBJECT)))
    (sch:diag-out f "    (no VLA object - properties unavailable)")
    (progn
  (setq names '("Width" "Height" "Rise" "Leaf" "StyleName" "Style"
                "Location" "InsertionPoint" "Position" "Normal" "Rotation"
                "OpeningPercent" "Swing" "SwingDirection" "Hand" "Handing"
                "Measure" "MeasureTo" "Length" "StartPoint" "EndPoint"
                "Justification" "BaseHeight" "Name" "EffectiveName"
                "Description" "Layer" "ObjectName"))
  (foreach n names
    (if (vlax-property-available-p obj n)
      (progn
        (setq v (sch:catch 'vlax-get-property (list obj n)))
        (if (eq (type v) 'VARIANT)
          (setq v (sch:catch 'vlax-variant-value (list v))))
        (sch:diag-out f
          (strcat "    ." n " = "
                  (cond ((eq (type v) 'STR) v)
                        ((numberp v) (rtos v 2 4))
                        ((eq (type v) 'VLA-OBJECT)
                         (strcat "<object "
                                 (sch:val->str (sch:prop v 'Name)) ">"))
                        ((and v (eq (type v) 'SAFEARRAY))
                         (vl-princ-to-string
                           (sch:catch 'vlax-safearray->list (list v))))
                        (v (vl-princ-to-string v))
                        (t "nil"))))))))))

;; probe getpropertyvalue with likely AEC property names
(defun sch:diag-gprops (f ename / v hits)
  (if (member "GETPROPERTYVALUE" (atoms-family 1))
    (progn
      (setq hits 0)
      (foreach n '("Width" "Height" "Rise" "Style" "StyleName"
                   "Description" "DoorWidth" "DoorHeight" "LeafWidth"
                   "FrameWidth" "OpenPercent" "SwingAngle" "Measure"
                   "WallWidth" "BaseHeight" "Length" "Elevation")
        (setq v (sch:catch 'getpropertyvalue (list ename n)))
        (if v
          (progn
            (setq hits (1+ hits))
            (sch:diag-out f (strcat "    gpv ." n " = "
                                    (vl-princ-to-string v))))))
      (if (= hits 0)
        (sch:diag-out f "    (getpropertyvalue returned nothing)")))
    (sch:diag-out f "    (getpropertyvalue not available)"))
  (princ))

(defun sch:diag-psets (f obj / psets)
  (setq psets (sch:psets obj))
  (if psets
    (foreach ps psets
      (sch:diag-out f (strcat "    property set [" (car ps) "]"))
      (foreach pr (cdr ps)
        (sch:diag-out f (strcat "      " (car pr) " = " (cdr pr)))))
    (sch:diag-out f
      (if (sch:sched-app)
        "    (no property sets returned for this object)"
        "    (AecX.AecScheduleApplication NOT available - property sets unreadable)"))))

;; dump one entity's entget (capped) - used for property-set objects
(defun sch:diag-dumpent (f ename indent / ed i)
  (setq ed (sch:catch 'entget (list ename)) i 0)
  (foreach g ed
    (if (< i 60)
      (sch:diag-out f (strcat indent (vl-princ-to-string g))))
    (setq i (1+ i)))
  (if (>= i 60) (sch:diag-out f (strcat indent "...(truncated)")))
  (princ))

;; walk the extension dictionary two levels deep - this is where ACA
;; property sets live (AEC_PROPERTY_SETS dictionary), and the raw
;; entget of those objects shows how to read DSLD_NUMBER etc. without
;; the AecX COM interface.
(defun sch:diag-xdict (f ename / ed xd name name2 sub subed g g2)
  (setq ed (entget ename)
        xd (cdr (assoc 360 ed)))
  (if (null xd)
    (sch:diag-out f "    (no extension dictionary)")
    (progn
      (sch:diag-out f "    extension dictionary entries:")
      (foreach g (entget xd)
        (cond
          ((= (car g) 3) (setq name (cdr g)))
          ((member (car g) '(350 360 340))
           (setq sub (cdr g)
                 subed (sch:catch 'entget (list sub)))
           (sch:diag-out f (strcat "      [" (if name name "?")
                                   "] type="
                                   (if subed (cdr (assoc 0 subed)) "?")))
           (if (and subed (= (cdr (assoc 0 subed)) "DICTIONARY"))
             (progn
               (setq name2 nil)
               (foreach g2 subed
                 (cond
                   ((= (car g2) 3) (setq name2 (cdr g2)))
                   ((member (car g2) '(350 360 340))
                    (sch:diag-out f (strcat "        {"
                                            (if name2 name2 "?") "}"))
                    (sch:diag-dumpent f (cdr g2) "          ")))))
             (if (and subed
                      (wcmatch (strcase (if name name "")) "*PROP*,*AEC*"))
               (sch:diag-dumpent f sub "        "))))))))
  (princ))

(defun c:SCHDIAG ( / fh es v on ename walls hand prims done ss i tbl
                     info oldecho kw bb *error*)
  (defun *error* (msg)
    (if oldecho (setvar "CMDECHO" oldecho))
    (if (and msg (not (wcmatch (strcase msg) "*BREAK*,*CANCEL*,*EXIT*")))
      (princ (strcat "\n[SCHDIAG] Error: " msg)))
    (princ))
  (setq oldecho (getvar "CMDECHO"))
  (setvar "CMDECHO" 0)
  ;; report path: next to the DWG, else temp folder
  (setq *sch:diag-path* (strcat (getvar "DWGPREFIX") "SCHDIAG-report.txt"))
  (setq fh (open *sch:diag-path* "a"))
  (if fh
    (close fh)
    (setq *sch:diag-path*
      (strcat (getvar "TEMPPREFIX") "SCHDIAG-report.txt")))
  ;; opt-in gates for the two crash-prone subsystems
  (initget "Yes No")
  (setq kw (getkword
    "\nTest AecX property-set interface (COM)? [Yes/No] <Yes>: "))
  (setq *sch:use-aecx* (/= kw "No"))
  (initget "Yes No")
  (setq kw (getkword
    "\nTest door explode / swing detection? [Yes/No] <Yes>: "))
  (setq *sch:use-explode* (/= kw "No"))
  (sch:diag-out nil "==========================================================")
  (sch:diag-out nil (strcat "SCHDIAG v1.8  dwg: " (getvar "DWGNAME")
                            "  date: " (rtos (getvar "CDATE") 2 6)))
  (sch:diag-out nil (strcat "  product: " (getvar "ACADVER")
                            "  aecx-gate: " (if *sch:use-aecx* "ON" "OFF")
                            "  explode-gate: "
                            (if *sch:use-explode* "ON" "OFF")))
  (sch:diag-out nil "STEP: census of AEC objects (ssget)...")
  (sch:diag-count nil "AEC doors" '((0 . "AEC_DOOR")))
  (sch:diag-count nil "AEC windows" '((0 . "AEC_WINDOW")))
  (sch:diag-count nil "AEC window assemblies" '((0 . "AEC_WINDOW_ASSEMBLY")))
  (sch:diag-count nil "AEC openings" '((0 . "AEC_OPENING")))
  (sch:diag-count nil "AEC walls" '((0 . "AEC_WALL")))
  (sch:diag-count nil "AEC mvblock refs (tags)" '((0 . "AEC_MVBLOCK_REF")))
  (sch:diag-count nil "TK_ tag INSERTs" '((0 . "INSERT") (2 . "TK_*")))
  (sch:diag-count nil "ACAD tables" '((0 . "ACAD_TABLE")))
  (if *sch:use-aecx*
    (progn
      (sch:diag-out nil
        "STEP: probing AecX.AecScheduleApplication (if AutoCAD dies HERE, rerun and answer No to the AecX question)...")
      (sch:diag-out nil
        (strcat "  AecX schedule app: "
                (if (sch:sched-app)
                  (strcat "OK (AecX.AecScheduleApplication"
                          (if *sch:schedapp-ver* *sch:schedapp-ver* "")
                          ")")
                  "NOT AVAILABLE")))))
  (sch:diag-out nil "STEP: reading ACAD table titles...")
  (setq ss (ssget "_X" '((0 . "ACAD_TABLE"))))
  (if ss
    (progn
      (setq i 0)
      (while (< i (sslength ss))
        (setq tbl (sch:vla (ssname ss i))
              info (sch:table-info tbl))
        (sch:diag-out nil
          (strcat "  table " (itoa (1+ i)) ": \"" (car info) "\"  rows="
                  (itoa (nth 3 info)) " cols=" (itoa (nth 4 info))
                  (if (cadr info)
                    (strcat "  header row=" (itoa (cadr info)))
                    "  (no MARK header)")))
        (setq i (1+ i)))))
  ;; per-entity inspection loop
  (sch:diag-out nil "-- entity inspection (pick doors, windows, openings, walls, tags; Enter to finish) --")
  (setq done nil)
  (while (not done)
    (setq es (entsel "\nSCHDIAG - select an entity to inspect (Enter to finish): "))
    (if (null es)
      (setq done T)
      (progn
        (setq ename (car es) v (sch:vla ename) on (sch:objname v))
        (sch:diag-out nil (strcat "  ENTITY " on
                                  "  layer=" (sch:val->str (sch:prop v 'Layer))
                                  "  handle=" (sch:val->str (sch:prop v 'Handle))))
        (sch:diag-out nil (strcat "    dxf type: "
                                  (cdr (assoc 0 (entget ename)))))
        (sch:diag-out nil "STEP: raw entget dump...")
        (sch:diag-dumpent nil ename "      ")
        (sch:diag-out nil "STEP: ActiveX property probe...")
        (sch:diag-props nil v)
        (sch:diag-out nil "STEP: getpropertyvalue probe...")
        (sch:diag-gprops nil ename)
        (setq bb (sch:bbox v))
        (if bb
          (sch:diag-out nil
            (strcat "    bbox dx/dy/dz = "
                    (rtos (- (car (cadr bb)) (car (car bb))) 2 2) " / "
                    (rtos (- (cadr (cadr bb)) (cadr (car bb))) 2 2) " / "
                    (rtos (- (caddr (cadr bb)) (caddr (car bb))) 2 2)))
          (sch:diag-out nil "    (no bounding box)"))
        (if *sch:use-aecx*
          (progn
            (sch:diag-out nil
              "STEP: property sets via AecX (if AutoCAD dies HERE, rerun with AecX = No)...")
            (sch:diag-psets nil v)))
        (sch:diag-out nil "STEP: extension dictionary...")
        (sch:diag-xdict nil ename)
        ;; door-specific: explode test + hand
        (if (and *sch:use-explode* (wcmatch on "AecDbDoor,AecDbOpening"))
          (progn
            (sch:diag-out nil
              "STEP: explode/swing test (if AutoCAD dies HERE, rerun with explode = No)...")
            (setq prims (sch:explode-copy v))
            (if prims
              (progn
                (foreach o prims
                  (sch:diag-out nil (strcat "      -> " (sch:objname o))))
                (sch:del-ents prims))
              (sch:diag-out nil "      (explode produced nothing / failed)"))
            (if (null walls) (setq walls (sch:collect-walls)))
            (setq hand (sch:door-hand v walls))
            (sch:diag-out nil (strcat "    computed hand: "
                                      (if hand hand "UNKNOWN")))))
        (if (= on "AecDbWall")
          (progn
            (sch:diag-out nil "STEP: wall record...")
            (sch:diag-out nil
              (strcat "    wall record: "
                      (vl-princ-to-string (sch:wall-record v)))))))))
  (sch:diag-out nil "-- end of SCHDIAG run (completed normally) --")
  (setvar "CMDECHO" oldecho)
  (princ (strcat "\n[SCHDIAG] Report at: " *sch:diag-path*))
  (princ))

;;; ------------------------------------------------------------------

(princ "\n[SCH] Loaded. Commands: SCH (fill schedule), SCHDIAG (diagnostics).")
(princ)
