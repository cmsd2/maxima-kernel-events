;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Mime-bundle builder.
;;;
;;; A mime bundle is a hash table mapping mime-type strings to their
;;; representation of the same value.  Used in `display' and
;;; `eval_result' envelopes; the renderer picks the richest mime it
;;; can render and shows that.
;;;
;;; Always includes "text/plain" as a fallback for headless / CLI
;;; consumers.  Other entries (application/x-maxima-latex, image/png,
;;; application/x-maxima-plotly, text/html) are added when supported
;;; by the kernel build AND requested by the renderer's capability
;;; negotiation — see *render-mimes* and set-render-mimes.

(in-package :kernel-events)

(defvar *render-mimes*
  '("text/plain" "application/x-maxima-latex")
  "Mime types the host has declared it can render.  Set by the host
   via SET-RENDER-MIMES at session start (capability negotiation).
   build-mime-bundle skips computing mimes not in this list — e.g.
   a CLI host that only sets `(\"text/plain\")` never pays the
   LaTeX cost.")

(defun render-mimes ()
  "Return a fresh copy of the current list of host-renderable mimes."
  (copy-list *render-mimes*))

(defun set-render-mimes (mimes)
  "Set the list of mime types the host can render.  Called by the
   host during capability negotiation."
  (check-type mimes list)
  (dolist (m mimes)
    (check-type m string))
  (setf *render-mimes* (copy-list mimes))
  (render-mimes))

(defun add-render-mime (mime)
  "Append MIME to *render-mimes* if not already present.  Useful for
   library packages that want to advertise a mime type their host
   may not have asked for explicitly (e.g. ax-plots adding
   \"application/x-maxima-plotly\")."
  (check-type mime string)
  (pushnew mime *render-mimes* :test #'string=)
  (render-mimes))

(defun should-render-mime-p (mime)
  "Return non-nil if MIME is in the host's declared render-mimes list."
  (find mime *render-mimes* :test #'string=))

;;; --- Bundle as a hash table ---------------------------------------------

(defun make-mime-bundle (&rest pairs)
  "Construct a mime bundle from explicit (MIME PAYLOAD) pairs.
   Example:
     (make-mime-bundle \"text/plain\" \"1/2\"
                       \"application/x-maxima-latex\" \"\\\\frac{1}{2}\")"
  (let ((b (make-hash-table :test 'equal)))
    (loop for (m p) on pairs by #'cddr
          do (check-type m string)
             (setf (gethash m b) p))
    b))

(defun mime-bundle-add (bundle mime payload)
  "Add (MIME PAYLOAD) to BUNDLE.  Idempotent overwrite.  Returns
   BUNDLE for chaining."
  (check-type bundle hash-table)
  (check-type mime string)
  (setf (gethash mime bundle) payload)
  bundle)

(defun mime-bundle-get (bundle mime)
  "Return the payload for MIME in BUNDLE, or NIL if absent."
  (gethash mime bundle))

(defun mime-bundle-mimes (bundle)
  "Return a fresh list of mime-type strings present in BUNDLE."
  (loop for k being the hash-keys of bundle collect k))

(defun mime-bundle-empty-p (bundle)
  (zerop (hash-table-count bundle)))

;;; --- Maxima output helpers ----------------------------------------------
;;;
;;; mgrind takes (form stream) and writes a one-line readable form.
;;; $tex1 (Maxima-callable, returns a string) is the standard LaTeX
;;; emitter.  Both live in the :maxima package, loaded by the time
;;; this file is loaded under Maxima (kernel-events.mac:21+).

(defun maxima-grind-to-string (expr)
  "Produce a one-line readable text form of EXPR via Maxima's
   mgrind.  Returns the string."
  (with-output-to-string (out)
    (let ((maxima::$display2d nil))
      (maxima::mgrind expr out))))

(defun maxima-tex1-to-string (expr)
  "Produce a LaTeX form of EXPR via Maxima's $tex1.  Returns the
   string, or NIL if $tex1 errors on EXPR."
  (handler-case
      (let ((maxima::$display2d nil))
        (maxima::$tex1 expr))
    (error () nil)))

;;; --- The public bundle builder ------------------------------------------

(defun build-mime-bundle (expr)
  "Build a mime bundle for EXPR (a Maxima expression).  Always
   includes \"text/plain\" via mgrind.  Includes
   \"application/x-maxima-latex\" when *render-mimes* contains it
   AND tex1 succeeds.  Library packages can extend the result via
   mime-bundle-add (e.g. ax-plots adding the Plotly JSON for plot
   values)."
  (let ((b (make-hash-table :test 'equal)))
    (setf (gethash "text/plain" b) (maxima-grind-to-string expr))
    (when (should-render-mime-p "application/x-maxima-latex")
      (let ((latex (maxima-tex1-to-string expr)))
        (when latex
          (setf (gethash "application/x-maxima-latex" b) latex))))
    b))
