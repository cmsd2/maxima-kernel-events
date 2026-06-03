;;;; -*-  Mode: Lisp; Package: maxima; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Maxima-callable API.
;;;
;;; Thin wrappers around the kernel-events:emit-* functions, exposed
;;; as Maxima functions ($-prefixed).  These are what user .mac code
;;; and library packages call.

(in-package :maxima)

;;; --- Maxima → JSON-value conversion -----------------------------------
;;;
;;; The kernel-events JSON serializer (envelope-to-json) understands:
;;;   strings, numbers, vectors, plists (keyword keys), hash-tables,
;;;   keywords, t/nil, :null/:false.
;;;
;;; Maxima expressions arriving here look like:
;;;   numbers           → numbers
;;;   strings           → strings
;;;   nil / t           → nil / t
;;;   $foo              → :foo  (keyword)
;;;   ((mlist) ...)     → vector of converted items, OR a plist when
;;;                       every item is an ((mequal) k v) form
;;;   ((rat simp) a b)  → float a/b
;;;   ((mequal) k v)    → 2-element vector [k, v]
;;;
;;; Anything else triggers an error; library code that wants a non-
;;; standard structure should construct it in Lisp and call
;;; kernel-events:emit-envelope directly.

(defun kernel-events::maxima-symbol-to-keyword (sym)
  "$ode_trajectory → :ode_trajectory.  Symbols without a $-prefix
   are kept as-is in their string form (we still lowercase + intern
   into the KEYWORD package for canonical use as a sum-type tag)."
  (if (symbolp sym)
      (let ((name (symbol-name sym)))
        (cond
          ((and (plusp (length name)) (char= (char name 0) #\$))
           (intern (subseq name 1) :keyword))
          (t (intern name :keyword))))
      sym))

(defun kernel-events::mequalp (x)
  "T if X is an mequal form ((mequal …) k v)."
  (and (consp x) (consp (car x))
       (eq (caar x) 'mequal)))

(defun kernel-events::mlistp (x)
  "T if X is an mlist form ((mlist …) items…)."
  (and (consp x) (consp (car x))
       (eq (caar x) 'mlist)))

(defun kernel-events::mratp (x)
  "T if X is a Maxima rational ((rat simp) a b)."
  (and (consp x) (consp (car x))
       (eq (caar x) 'rat)))

(defun kernel-events::maxima-value-to-json-value (x)
  "Convert a Maxima value X to a Lisp structure suitable for the
   kernel-events JSON serializer.  Errors on unsupported shapes."
  (cond
    ((null x) nil)
    ((eq x t) t)
    ((numberp x) x)
    ((stringp x) x)
    ((symbolp x) (kernel-events::maxima-symbol-to-keyword x))
    ((kernel-events::mratp x)
     (float (/ (second x) (third x)) 1.0d0))
    ((kernel-events::mlistp x)
     (let ((items (cdr x)))
       (cond
         ((and items (every #'kernel-events::mequalp items))
          ;; Every item is an equation — build a plist.
          (loop for eq in items
                append (list (kernel-events::maxima-symbol-to-keyword
                               (second eq))
                             (kernel-events::maxima-value-to-json-value
                               (third eq)))))
         (t
          ;; Plain values — build a vector.
          (map 'vector #'kernel-events::maxima-value-to-json-value items)))))
    ((kernel-events::mequalp x)
     ;; Single equation at top level: 2-element array [k, v].
     (vector (kernel-events::maxima-value-to-json-value (second x))
             (kernel-events::maxima-value-to-json-value (third x))))
    (t
     (merror "kernel-events: cannot convert Maxima value to JSON: ~M" x))))

(defun kernel-events::pairs-to-mime-bundle (pairs)
  "PAIRS is a Maxima list-of-2-element-lists: [[mime, payload], ...]
   Returns a hash-table mime bundle."
  (unless (kernel-events::mlistp pairs)
    (merror "kernel-events: emit_display expects a list of [mime, payload] pairs; got: ~M" pairs))
  (let ((bundle (make-hash-table :test 'equal)))
    (dolist (pair (cdr pairs))
      (unless (and (kernel-events::mlistp pair)
                   (= (length pair) 3))
        (merror "kernel-events: emit_display pair must be [mime, payload]; got: ~M" pair))
      (let ((mime    (second pair))
            (payload (third pair)))
        (unless (stringp mime)
          (merror "kernel-events: emit_display mime must be a string; got: ~M" mime))
        (setf (gethash mime bundle) payload)))
    bundle))

;;; --- Public Maxima-callable functions ---------------------------------

(defmfun $show (expr)
  "show(expr) -- emit a display event with a mime bundle for EXPR.
   The renderer picks the richest mime it can render.  Returns 'done."
  (kernel-events:emit-envelope
    (kernel-events:make-envelope
      :display
      :eval_id (kernel-events:current-eval-id)
      :mime_bundle (kernel-events:build-mime-bundle expr)))
  '$done)

(defmfun $emit_display (pairs)
  "emit_display([[mime, payload], ...]) -- emit a display event with
   an explicit mime bundle.  Used by library packages that know
   exactly what mime types they're producing.  Returns 'done."
  (kernel-events:emit-envelope
    (kernel-events:make-envelope
      :display
      :eval_id (kernel-events:current-eval-id)
      :mime_bundle (kernel-events::pairs-to-mime-bundle pairs)))
  '$done)

(defmfun $emit_frame (view-id payload)
  "emit_frame(view_id, payload) -- emit one frame to a streaming view.
   PAYLOAD shapes the renderer expects:
     [t = 0.05, y = [1.0, 0.02]]   (list of equations → object)
     [0.05, [1.0, 0.02]]           (positional list → array)
   Returns the allocated seq number."
  (unless (stringp view-id)
    (merror "kernel-events: emit_frame view_id must be a string; got: ~M" view-id))
  (kernel-events:emit-frame
    view-id
    (kernel-events::maxima-value-to-json-value payload)))

(defmfun $emit_progress (view-id fraction &optional (message nil))
  "emit_progress(view_id, fraction [, message]) -- emit a progress
   signal.  FRACTION is in [0,1] or false for indeterminate."
  (unless (stringp view-id)
    (merror "kernel-events: emit_progress view_id must be a string; got: ~M" view-id))
  (kernel-events:emit-progress
    view-id
    (if (eq fraction nil) nil fraction)
    message)
  '$done)

(defmfun $emit_log (view-id lvl message)
  "emit_log(view_id, level, message) -- emit a log line attached to a
   view.  LEVEL is one of 'info, 'warn, 'error."
  (unless (stringp view-id)
    (merror "kernel-events: emit_log view_id must be a string; got: ~M" view-id))
  (kernel-events:emit-log
    view-id
    (kernel-events::maxima-symbol-to-keyword lvl)
    message)
  '$done)

(defmfun $emit_done (view-id &optional (status '$complete))
  "emit_done(view_id [, status]) -- close a streaming view.
   STATUS is one of 'complete (default), 'cancelled, 'error.
   Returns the final seq number for the view."
  (unless (stringp view-id)
    (merror "kernel-events: emit_done view_id must be a string; got: ~M" view-id))
  (kernel-events:emit-stream-end
    view-id
    :status (kernel-events::maxima-symbol-to-keyword status)))

(defmfun $alloc_view (kind)
  "alloc_view(kind) -- allocate a new view_id and emit stream_begin.
   KIND is a renderer-side dispatch symbol, e.g. 'ode_trajectory.
   Returns the view_id as a Maxima string."
  (let ((view-id (kernel-events:next-view-id))
        (kw      (kernel-events::maxima-symbol-to-keyword kind)))
    (kernel-events:emit-stream-begin view-id kw)
    view-id))

(defmfun $kernel_events_available ()
  "kernel_events_available() -- feature-detect.  Returns true if the
   package is loaded.  Mirrors Python's `from __future__ import ...'
   idiom for libraries that want to conditionally opt in."
  t)
