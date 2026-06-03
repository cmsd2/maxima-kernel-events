;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Output stream wrapping.
;;;
;;; Replaces *standard-output* (and *error-output*) with Gray streams
;;; that buffer bytes line-by-line and emit an `output' envelope on
;;; each newline (or explicit force-output).
;;;
;;; Why wrap the stream, not $print:
;;;   1. Lisp libraries using (format t ...) write to *standard-output*
;;;      directly; instrumenting $print would miss them.
;;;   2. displa() (src/displa.lisp:47) writes value echoes to
;;;      *standard-output*; with wrapping, value echoes flow through
;;;      output envelopes for free.
;;;   3. printf(stream, ...) to an explicit user-opened file stream
;;;      *shouldn't* emit events.  Wrapping *standard-output* cleanly
;;;      excludes this.
;;;
;;; Each output envelope carries:
;;;   - eval_id (current evaluation, or NIL outside one)
;;;   - stream  ("stdout" or "stderr")
;;;   - mime    ("text/plain" always; structured output goes through
;;;              `display' envelopes, not `output')
;;;   - text    one logical line

(in-package :kernel-events)

(defvar *original-standard-output* nil
  "The pre-wrap *standard-output*, kept so install-output-wrapping
   can be reversed for tests.")
(defvar *original-error-output* nil)

;; Per-Lisp Gray stream implementation lives below.
;; The portable interface is the events-output-stream class.

(defclass events-output-stream ()
  ((buffer :initform (make-array 256
                       :element-type 'character
                       :adjustable t :fill-pointer 0)
           :reader stream-buffer)
   (stream-name :initarg :name :reader stream-name))
  (:documentation
   "Stream that buffers bytes line-by-line and emits an output
    envelope on each newline.  Subclasses implement the per-Lisp
    Gray-stream protocol."))

(defun install-output-wrapping ()
  "Replace *standard-output* and *error-output* with events streams.
   Saves the originals so uninstall-output-wrapping can restore them.
   Idempotent."
  (error "TODO: implement install-output-wrapping"))

(defun uninstall-output-wrapping ()
  "Restore the original *standard-output* and *error-output*.
   Mostly for tests."
  (error "TODO: implement uninstall-output-wrapping"))

(defun emit-output-line (stream-name text)
  "Emit an output envelope for one logical line.
   STREAM-NAME is 'stdout' or 'stderr'."
  (declare (ignore stream-name text))
  (error "TODO: implement emit-output-line"))
