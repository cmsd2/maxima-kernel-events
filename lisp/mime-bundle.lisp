;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Mime-bundle builder.
;;;
;;; A mime bundle is a hash table (or alist) mapping mime-type strings
;;; to their representations of the same value.  Used in `display' and
;;; `eval_result' envelopes.
;;;
;;; Always includes "text/plain" as a fallback for headless / CLI
;;; consumers.  Other entries (application/x-maxima-latex, image/png,
;;; application/x-maxima-plotly, text/html) are added when supported
;;; by the kernel build and requested by the renderer's capability
;;; negotiation (see render-mimes in api.lisp).

(in-package :kernel-events)

(defun build-mime-bundle (value)
  "Build a mime bundle for VALUE (a Maxima expression).
   Always includes text/plain.  Includes application/x-maxima-latex
   when *render-mimes* contains it (default: yes)."
  (declare (ignore value))
  (error "TODO: implement build-mime-bundle"))

(defun mime-bundle-add (bundle mime payload)
  "Add (MIME PAYLOAD) to BUNDLE.  Used by libraries that emit their
   own structured output (e.g. ax-plots' Plotly JSON)."
  (declare (ignore bundle mime payload))
  (error "TODO: implement mime-bundle-add"))

(defvar *render-mimes*
  '("text/plain" "application/x-maxima-latex")
  "Mime types the host has declared it can render.  Set by the host
   via SET-RENDER-MIMES at session start (capability negotiation).
   The bundle builder skips computing mimes not in this list -- e.g.
   a CLI host that only sets {'text/plain'} pays no LaTeX cost.")

(defun set-render-mimes (mimes)
  "Set the list of mime types the host can render.  Called by the
   host during capability negotiation."
  (declare (ignore mimes))
  (error "TODO: implement set-render-mimes"))

(defun render-mimes ()
  "Return the current list of host-renderable mimes."
  (copy-list *render-mimes*))
