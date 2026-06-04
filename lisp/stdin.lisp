;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; stdin_request envelope.
;;;
;;; Announces that the kernel is blocking on user input.  Hosts
;;; respond via a dedicated stdin-response channel (out of scope for
;;; this package — the kernel-events channel is one-way).
;;;
;;; Today this is an emitter only.  Wiring it into Maxima's
;;; readonly/read_string / dbm input read paths is a follow-up.

(in-package :kernel-events)

(defvar *stdin-request-counter* 0
  "Monotonic allocator for stdin request ids, session-scoped.")

(defun next-stdin-request-id ()
  "Allocate the next stdin request id string (\"r_<n>\")."
  (format nil "r_~D" (incf *stdin-request-counter*)))

(defun reset-stdin-counter ()
  "Reset the stdin request counter.  Used by tests for isolation."
  (setf *stdin-request-counter* 0))

(defun emit-stdin-request (prompt kind &key request-id eval-id)
  "Emit a stdin_request envelope.

   PROMPT is the prompt text to surface in the host UI.
   KIND is one of :string :expression :debugger_command.
   REQUEST-ID defaults to a fresh id from next-stdin-request-id.
   EVAL-ID defaults to *current-eval-id*.

   Returns the request-id so the caller can correlate the eventual
   stdin-response."
  (let ((id (or request-id (next-stdin-request-id))))
    (emit-envelope
      (make-envelope :stdin_request
                     :eval_id    (or eval-id *current-eval-id*)
                     :request_id id
                     :prompt     prompt
                     :kind       kind))
    id))
