;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Evaluation lifecycle hooks.
;;;
;;; Emits eval_begin / eval_result / eval_end envelopes around each
;;; top-level Maxima evaluation.
;;;
;;; Load-only path: hook via *prompt-prefix* / *prompt-suffix*
;;; (already a frontend-protocol API used by wxMaxima) plus wrap
;;; displa for the result.  This is producer-side hooking, which we
;;; own -- distinct from the consumer-side prompt parsing we're
;;; trying to retire in aximar.

(in-package :kernel-events)

(defvar *current-eval-id* nil
  "Eval-id of the currently-evaluating top-level form, or NIL outside
   an evaluation.  Bound by emit-eval-begin / emit-eval-end.")

(defvar *eval-counter* 0
  "Monotonically increasing eval-id source, session-scoped.")

(defun next-eval-id ()
  "Allocate a new eval-id for the next evaluation."
  (format nil "e_~D" (incf *eval-counter*)))

(defun current-eval-id ()
  "Return the eval-id of the currently-evaluating form, or NIL."
  *current-eval-id*)

(defun emit-eval-begin (eval-id)
  "Emit an eval_begin envelope and bind *current-eval-id*."
  (declare (ignore eval-id))
  (error "TODO: implement emit-eval-begin"))

(defun emit-eval-result (eval-id value label suppressed)
  "Emit an eval_result envelope with the bundle for VALUE.
   LABEL is the Maxima output label (e.g. %o7).
   SUPPRESSED is T when the user terminated with `$' (no echo)."
  (declare (ignore eval-id value label suppressed))
  (error "TODO: implement emit-eval-result"))

(defun emit-eval-end (eval-id status duration-ms)
  "Emit an eval_end envelope.  STATUS is :ok | :error | :cancelled.
   Unbinds *current-eval-id*."
  (declare (ignore eval-id status duration-ms))
  (error "TODO: implement emit-eval-end"))

(defun install-eval-hooks ()
  "Install hooks on Maxima's top-level evaluation driver so that
   eval-lifecycle envelopes fire automatically around each user form.

   Mechanism: rebind *prompt-prefix* / *prompt-suffix*, wrap displa.
   Idempotent -- safe to call multiple times during a session."
  (error "TODO: implement install-eval-hooks"))
