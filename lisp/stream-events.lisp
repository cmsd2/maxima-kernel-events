;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Streaming envelopes.
;;;
;;; Per-view streaming: stream_begin, frame, progress, stream_end,
;;; stream_error, log.  See streaming.md for the use cases (animated
;;; plots, ODE trajectories growing live, MCMC chains, optimization
;;; iterates).
;;;
;;; Streaming envelopes reference a view_id rather than an eval_id;
;;; a view's lifetime can span multiple evaluations.

(in-package :kernel-events)

(defvar *view-counter* 0
  "Monotonically increasing view-id source, session-scoped.")

(defvar *view-seq-table* (make-hash-table :test 'equal)
  "Per-view-id sequence numbers for frame ordering.")

(defun next-view-id ()
  "Allocate a new view-id."
  (format nil "v_~D" (incf *view-counter*)))

(defun next-view-seq (view-id)
  "Allocate the next seq number for VIEW-ID."
  (incf (gethash view-id *view-seq-table* 0)))

(defun emit-stream-begin (view-id kind &key expected-frames metadata)
  "Emit a stream_begin envelope."
  (declare (ignore view-id kind expected-frames metadata))
  (error "TODO: implement emit-stream-begin"))

(defun emit-frame (view-id payload)
  "Emit a frame envelope for VIEW-ID.  PAYLOAD shape is per-kind."
  (declare (ignore view-id payload))
  (error "TODO: implement emit-frame"))

(defun emit-progress (view-id fraction &optional message)
  "Emit a progress envelope (fraction in 0..1)."
  (declare (ignore view-id fraction message))
  (error "TODO: implement emit-progress"))

(defun emit-stream-end (view-id &key status duration-ms)
  "Emit a stream_end envelope.  STATUS is :complete | :cancelled | :error."
  (declare (ignore view-id status duration-ms))
  (error "TODO: implement emit-stream-end"))

(defun emit-stream-error (view-id message &key recoverable)
  "Emit a stream_error envelope, then stream_end with status :error."
  (declare (ignore view-id message recoverable))
  (error "TODO: implement emit-stream-error"))

(defun emit-log (view-id level message)
  "Emit a log envelope attached to a view.  LEVEL is :info | :warn | :error."
  (declare (ignore view-id level message))
  (error "TODO: implement emit-log"))
