;;;; -*-  Mode: Lisp; Package: maxima; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Maxima-callable API.
;;;
;;; Thin wrappers around the kernel-events:emit-* functions, exposed
;;; as Maxima functions ($-prefixed).  These are what user .mac code
;;; and library packages call.

(in-package :maxima)

(defmfun $show (expr)
  "show(expr) — emit a display event with a mime bundle for EXPR.
   The renderer picks the richest mime it can render."
  (declare (ignore expr))
  (merror "TODO: implement $show"))

(defmfun $emit_display (pairs)
  "emit_display([[mime, payload], ...]) — emit a display event with
   an explicit mime bundle.  Used by libraries like ax-plots that
   know exactly what mime types they're producing."
  (declare (ignore pairs))
  (merror "TODO: implement $emit_display"))

(defmfun $emit_frame (view-id payload)
  "emit_frame(view_id, payload) — emit one frame to a streaming view."
  (declare (ignore view-id payload))
  (merror "TODO: implement $emit_frame"))

(defmfun $emit_progress (view-id fraction)
  "emit_progress(view_id, fraction) — emit a progress signal (0..1)."
  (declare (ignore view-id fraction))
  (merror "TODO: implement $emit_progress"))

;; Parameter is named lvl, not level, because maxima::level is a
;; special variable in Maxima core and declaring a special IGNORE
;; is a style warning we'd rather not chase to the Maxima side.
(defmfun $emit_log (view-id lvl message)
  "emit_log(view_id, level, message) — emit a log line attached to
   a view.  LEVEL is one of 'info, 'warn, 'error."
  (declare (ignore view-id lvl message))
  (merror "TODO: implement $emit_log"))

(defmfun $emit_done (view-id &optional (status '$complete))
  "emit_done(view_id [, status]) — close a streaming view."
  (declare (ignore view-id status))
  (merror "TODO: implement $emit_done"))

(defmfun $alloc_view (kind)
  "alloc_view(kind) — allocate a new view-id and emit stream_begin.
   Returns the view-id as a Maxima string."
  (declare (ignore kind))
  (merror "TODO: implement $alloc_view"))

(defmfun $kernel_events_available ()
  "kernel_events_available() — feature-detect, returns true if the
   package is loaded.  Mirrors Python's `from __future__ import ...'
   idiom for libraries that want to conditionally opt in."
  t)
