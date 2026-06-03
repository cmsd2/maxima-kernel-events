;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Sink abstraction.
;;;
;;; A SINK is a function that takes one envelope (a Lisp object that
;;; serializes to JSON; see envelope.lisp) and writes it somewhere.
;;; The package does not assume any particular transport.  Sinks
;;; observed in practice:
;;;
;;;   - aximar:        write to *maxima-events-out* (fd 3) as JSON-lines
;;;   - maxima_mcp:    fan out to all connected SSE streams
;;;   - tests:         accumulate into a list
;;;   - file logger:   append to a file
;;;
;;; Multiple sinks can be registered simultaneously.  Emission iterates
;;; over all registered sinks; one failing sink does not prevent the
;;; others from receiving the envelope.

(in-package :kernel-events)

(defvar *sinks* '()
  "List of sink functions.  Each receives every emitted envelope.")

(defvar *sinks-lock* nil
  "Mutex protecting *sinks*.  Set by the bootstrap when threading is
   available (SBCL: sb-thread:make-mutex).  NIL on Lisps without
   threading -- emission is then unprotected.")

(defun register-sink (sink-fn)
  "Register SINK-FN as a sink.  SINK-FN is called as
   (funcall sink-fn envelope) for every emitted envelope.
   Returns a token usable for unregister-sink."
  (declare (ignore sink-fn))
  (error "TODO: implement register-sink"))

(defun unregister-sink (token)
  "Remove the sink identified by TOKEN (returned by register-sink)."
  (declare (ignore token))
  (error "TODO: implement unregister-sink"))

(defun list-sinks ()
  "Return the current list of registered sinks (for inspection)."
  (copy-list *sinks*))

(defun call-sinks (envelope)
  "Internal: deliver ENVELOPE to all registered sinks.
   Catches per-sink errors so one bad sink doesn't stop the others."
  (declare (ignore envelope))
  (error "TODO: implement call-sinks"))
