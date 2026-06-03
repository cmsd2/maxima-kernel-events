;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Streaming envelopes.
;;;
;;; Per-view streaming: stream_begin, frame, progress, stream_end,
;;; stream_error, log.  See doc/design/streaming.md for the use
;;; cases (animated plots, ODE trajectories growing live, MCMC
;;; chains, optimization iterates).
;;;
;;; Streaming envelopes reference a view_id rather than an eval_id;
;;; a view's lifetime can span multiple evaluations.

(in-package :kernel-events)

(defvar *view-counter* 0
  "Monotonically increasing view-id source, session-scoped.")

(defvar *view-seq-table* (make-hash-table :test 'equal)
  "Per-view-id sequence numbers for frame ordering.  Allocated by
   next-view-seq; cleared by emit-stream-end.")

(defun next-view-id ()
  "Allocate a fresh view-id (e.g. \"v_1\", \"v_2\", ...)."
  (format nil "v_~D" (incf *view-counter*)))

(defun next-view-seq (view-id)
  "Allocate and return the next seq number for VIEW-ID, starting at 1."
  (incf (gethash view-id *view-seq-table* 0)))

(defun reset-view-counters ()
  "Reset the view-id and per-view seq state.  Used by tests."
  (setf *view-counter* 0)
  (clrhash *view-seq-table*))

;; ISO 8601 timestamp without milliseconds — every Lisp has the
;; pieces, so this stays portable.  Higher-resolution timestamps
;; could replace this when we want sub-second ordering precision.
(defun current-iso8601-utc ()
  "Return the current UTC time as an ISO 8601 string with second
   resolution: 2026-06-03T15:21:08Z."
  (multiple-value-bind (sec min hour day month year)
      (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
            year month day hour min sec)))

;;; --- Typed emitters ----------------------------------------------------

(defun emit-stream-begin (view-id kind &key expected-frames metadata)
  "Emit a stream_begin envelope.  Returns VIEW-ID for chaining.

   KIND is a renderer-side dispatch keyword (e.g. :ode_trajectory,
   :mcmc_chain).  EXPECTED-FRAMES may be NIL for unbounded streams.
   METADATA is an arbitrary plist carrying view-kind-specific
   configuration."
  (emit-envelope
    (make-envelope :stream_begin
                   :view_id view-id
                   :kind kind
                   :started_at (current-iso8601-utc)
                   :expected_frames expected-frames
                   :metadata metadata))
  view-id)

(defun emit-frame (view-id payload)
  "Emit a frame envelope.  Auto-allocates the seq number from the
   per-view-id counter.  Returns the seq.

   PAYLOAD shape is per-view-kind; the renderer's extend handler
   knows what to expect (e.g. {:t T :y Y} for ode_trajectory)."
  (let ((seq (next-view-seq view-id)))
    (emit-envelope
      (make-envelope :frame
                     :view_id view-id
                     :seq seq
                     :payload payload))
    seq))

(defun emit-progress (view-id fraction &optional message)
  "Emit a progress envelope.  FRACTION in [0,1] or NIL when total
   is unknown.  MESSAGE is an optional human-readable hint."
  (emit-envelope
    (make-envelope :progress
                   :view_id view-id
                   :fraction fraction
                   :message message)))

(defun emit-stream-end (view-id &key (status :complete) duration-ms)
  "Emit a stream_end envelope and release the per-view seq counter.
   Returns the final seq number for the view.

   STATUS is :complete | :cancelled | :error."
  (let ((final-seq (gethash view-id *view-seq-table* 0)))
    (emit-envelope
      (make-envelope :stream_end
                     :view_id view-id
                     :final_seq final-seq
                     :duration_ms duration-ms
                     :status status))
    (remhash view-id *view-seq-table*)
    final-seq))

(defun emit-stream-error (view-id message &key (recoverable :false))
  "Emit a stream_error envelope.  RECOVERABLE is t / :false; callers
   typically follow this with emit-stream-end :status :error."
  (emit-envelope
    (make-envelope :stream_error
                   :view_id view-id
                   :message message
                   :recoverable recoverable)))

(defun emit-log (view-id level message)
  "Emit a log envelope attached to a view.  LEVEL is :info, :warn,
   or :error."
  (emit-envelope
    (make-envelope :log
                   :view_id view-id
                   :level level
                   :message message)))
