;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Structured error envelope.
;;;
;;; The kernel's existing eval_end with :status :error tells a host
;;; *that* something failed.  The error envelope tells a host *what*
;;; failed: kind, message, and optional location/form/backtrace.
;;;
;;; Hosts can emit this themselves (from a handler-bind in their own
;;; eval driver) or instrument it later.  Not auto-wired by
;;; eval-hooks today — merror uses throw, not a Lisp condition, so a
;;; non-trivial bind-and-catch would be needed.

(in-package :kernel-events)

(defun emit-error (kind message
                   &key location form backtrace
                        (recoverable :false)
                        eval-id)
  "Emit a structured error envelope.

   KIND is one of :maxima_error :lisp_error :parser_error :timeout
   :cancelled.
   MESSAGE is the human-readable error string.
   LOCATION is an optional plist with :line and :column.
   FORM is the offending source as a string.
   BACKTRACE is a vector of strings.
   RECOVERABLE is T / :false; defaults to :false.
   EVAL-ID defaults to *current-eval-id*."
  (emit-envelope
    (make-envelope :error
                   :eval_id     (or eval-id *current-eval-id*)
                   :kind        kind
                   :message     message
                   :location    location
                   :form        form
                   :backtrace   backtrace
                   :recoverable recoverable)))
