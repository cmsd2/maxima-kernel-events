;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for the typed streaming emitters: next-view-id, emit-frame,
;;; emit-stream-begin, emit-progress, emit-stream-end, emit-stream-error,
;;; emit-log.
;;;
;;; Each test uses a collecting sink so we can inspect the envelopes
;;; that were emitted without needing a live transport.

(in-package :kernel-events-tests)

(defmacro with-clean-stream-state (&body body)
  "Reset sinks and view counters around BODY."
  `(unwind-protect
       (progn
         (kernel-events:clear-sinks)
         (kernel-events:reset-view-counters)
         ,@body)
     (kernel-events:clear-sinks)
     (kernel-events:reset-view-counters)))

(defun collect-envelopes ()
  "Register a collecting sink.  Returns (values collector-vector
   token-for-unregister)."
  (let ((v (make-array 0 :adjustable t :fill-pointer 0)))
    (values v
            (kernel-events:register-sink
              (lambda (e) (vector-push-extend e v))))))

;; ----------------------------------------------------------------
;; next-view-id

(deftest stream-next-view-id-starts-at-1
  (with-clean-stream-state
    (assert-equal "v_1" (kernel-events:next-view-id))))

(deftest stream-next-view-id-monotonically-increases
  (with-clean-stream-state
    (assert-equal "v_1" (kernel-events:next-view-id))
    (assert-equal "v_2" (kernel-events:next-view-id))
    (assert-equal "v_3" (kernel-events:next-view-id))))

(deftest stream-reset-view-counters-resets-id
  (with-clean-stream-state
    (kernel-events:next-view-id)
    (kernel-events:next-view-id)
    (kernel-events:reset-view-counters)
    (assert-equal "v_1" (kernel-events:next-view-id))))

;; ----------------------------------------------------------------
;; next-view-seq

(deftest stream-next-view-seq-starts-at-1
  (with-clean-stream-state
    (assert-equal 1 (kernel-events:next-view-seq "v_1"))))

(deftest stream-next-view-seq-monotonically-per-view
  (with-clean-stream-state
    (assert-equal 1 (kernel-events:next-view-seq "v_1"))
    (assert-equal 2 (kernel-events:next-view-seq "v_1"))
    (assert-equal 3 (kernel-events:next-view-seq "v_1"))))

(deftest stream-next-view-seq-independent-across-views
  (with-clean-stream-state
    (assert-equal 1 (kernel-events:next-view-seq "v_1"))
    (assert-equal 1 (kernel-events:next-view-seq "v_2"))
    (assert-equal 2 (kernel-events:next-view-seq "v_1"))
    (assert-equal 2 (kernel-events:next-view-seq "v_2"))))

;; ----------------------------------------------------------------
;; emit-stream-begin

(deftest stream-begin-emits-envelope
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-begin "v_1" :ode_trajectory)
      (assert-equal 1 (length envs))
      (let ((e (aref envs 0)))
        (assert-equal :stream_begin (getf e :type))
        (assert-equal "v_1" (getf e :view_id))
        (assert-equal :ode_trajectory (getf e :kind))
        (assert-true (stringp (getf e :started_at))
                     "started_at should be a string (ISO 8601)")))))

(deftest stream-begin-returns-view-id
  (with-clean-stream-state
    (collect-envelopes)
    (assert-equal "v_42"
                  (kernel-events:emit-stream-begin "v_42" :ode_trajectory))))

(deftest stream-begin-with-metadata
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-begin "v_1" :ode_trajectory
                                       :expected-frames 200
                                       :metadata '(:vars #("x" "v")
                                                   :t0 0.0d0
                                                   :tf 10.0d0))
      (let* ((e  (aref envs 0))
             (md (getf e :metadata)))
        (assert-equal 200 (getf e :expected_frames))
        (assert-equal 0.0d0 (getf md :t0))
        (assert-equal 10.0d0 (getf md :tf))
        (assert-true (equalp #("x" "v") (getf md :vars))
                     "metadata.vars vector should round-trip")))))

(deftest stream-begin-default-expected-frames-is-nil
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-begin "v_1" :ode_trajectory)
      (let ((e (aref envs 0)))
        (assert-equal nil (getf e :expected_frames))))))

;; ----------------------------------------------------------------
;; emit-frame

(deftest stream-frame-emits-envelope-with-seq
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-frame "v_1" '(:t 0.05d0 :y #(1.0d0)))
      (assert-equal 1 (length envs))
      (let* ((e (aref envs 0))
             (payload (getf e :payload)))
        (assert-equal :frame (getf e :type))
        (assert-equal "v_1" (getf e :view_id))
        (assert-equal 1 (getf e :seq))
        (assert-equal 0.05d0 (getf payload :t))
        (assert-true (equalp #(1.0d0) (getf payload :y)))))))

(deftest stream-frame-returns-seq
  (with-clean-stream-state
    (collect-envelopes)
    (assert-equal 1 (kernel-events:emit-frame "v_1" '(:t 0.0d0)))
    (assert-equal 2 (kernel-events:emit-frame "v_1" '(:t 0.1d0)))
    (assert-equal 3 (kernel-events:emit-frame "v_1" '(:t 0.2d0)))))

(deftest stream-frame-seqs-independent-across-views
  (with-clean-stream-state
    (collect-envelopes)
    (assert-equal 1 (kernel-events:emit-frame "v_1" '(:n 1)))
    (assert-equal 1 (kernel-events:emit-frame "v_2" '(:n 1)))
    (assert-equal 2 (kernel-events:emit-frame "v_1" '(:n 2)))
    (assert-equal 2 (kernel-events:emit-frame "v_2" '(:n 2)))))

;; ----------------------------------------------------------------
;; emit-progress

(deftest stream-progress-emits-with-numeric-fraction
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-progress "v_1" 0.25d0 "integrating")
      (let ((e (aref envs 0)))
        (assert-equal :progress (getf e :type))
        (assert-equal 0.25d0 (getf e :fraction))
        (assert-equal "integrating" (getf e :message))))))

(deftest stream-progress-with-nil-fraction
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-progress "v_1" nil)
      (let ((e (aref envs 0)))
        (assert-equal nil (getf e :fraction))
        (assert-equal nil (getf e :message))))))

;; ----------------------------------------------------------------
;; emit-stream-end

(deftest stream-end-emits-with-status
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-end "v_1" :status :complete
                                          :duration-ms 340)
      (let ((e (aref envs 0)))
        (assert-equal :stream_end (getf e :type))
        (assert-equal :complete (getf e :status))
        (assert-equal 340 (getf e :duration_ms))))))

(deftest stream-end-default-status-is-complete
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-end "v_1")
      (let ((e (aref envs 0)))
        (assert-equal :complete (getf e :status))))))

(deftest stream-end-records-final-seq
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-frame "v_1" '(:n 1))
      (kernel-events:emit-frame "v_1" '(:n 2))
      (kernel-events:emit-frame "v_1" '(:n 3))
      (kernel-events:emit-stream-end "v_1")
      (let ((end-envelope (aref envs 3)))
        (assert-equal 3 (getf end-envelope :final_seq))))))

(deftest stream-end-returns-final-seq
  (with-clean-stream-state
    (collect-envelopes)
    (kernel-events:emit-frame "v_1" '(:n 1))
    (kernel-events:emit-frame "v_1" '(:n 2))
    (assert-equal 2 (kernel-events:emit-stream-end "v_1"))))

(deftest stream-end-releases-seq-counter
  (with-clean-stream-state
    (collect-envelopes)
    (kernel-events:emit-frame "v_1" '(:n 1))
    (kernel-events:emit-frame "v_1" '(:n 2))
    (kernel-events:emit-stream-end "v_1")
    ;; A new view with the same id starts fresh
    (assert-equal 1 (kernel-events:next-view-seq "v_1"))))

(deftest stream-end-cancelled-status
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-end "v_1" :status :cancelled)
      (let ((e (aref envs 0)))
        (assert-equal :cancelled (getf e :status))))))

;; ----------------------------------------------------------------
;; emit-stream-error

(deftest stream-error-emits-envelope
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-error "v_1" "RHS failed at t=3.7")
      (let ((e (aref envs 0)))
        (assert-equal :stream_error (getf e :type))
        (assert-equal "v_1" (getf e :view_id))
        (assert-equal "RHS failed at t=3.7" (getf e :message))
        (assert-equal :false (getf e :recoverable))))))

(deftest stream-error-recoverable-flag
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-stream-error "v_1" "transient" :recoverable t)
      (let ((e (aref envs 0)))
        (assert-equal t (getf e :recoverable))))))

;; ----------------------------------------------------------------
;; emit-log

(deftest stream-log-info
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-log "v_1" :info "detected event at t=2.3")
      (let ((e (aref envs 0)))
        (assert-equal :log (getf e :type))
        (assert-equal :info (getf e :level))
        (assert-equal "detected event at t=2.3" (getf e :message))))))

(deftest stream-log-warn-and-error-levels
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-log "v_1" :warn "step rejected")
      (kernel-events:emit-log "v_1" :error "solver failed")
      (assert-equal :warn (getf (aref envs 0) :level))
      (assert-equal :error (getf (aref envs 1) :level)))))

;; ----------------------------------------------------------------
;; Integration: a full stream lifecycle (the ODE-trajectory shape)

(deftest stream-full-lifecycle
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (let ((view (kernel-events:next-view-id)))
        (kernel-events:emit-stream-begin view :ode_trajectory
                                         :metadata '(:vars #("x" "v")))
        (kernel-events:emit-frame view '(:t 0.0d0 :y #(1.0d0 0.0d0)))
        (kernel-events:emit-frame view '(:t 0.1d0 :y #(0.995d0 -0.1d0)))
        (kernel-events:emit-frame view '(:t 0.2d0 :y #(0.980d0 -0.199d0)))
        (kernel-events:emit-stream-end view :duration-ms 12))
      ;; 1 begin + 3 frames + 1 end = 5 envelopes
      (assert-equal 5 (length envs))
      (assert-equal :stream_begin (getf (aref envs 0) :type))
      (assert-equal :frame        (getf (aref envs 1) :type))
      (assert-equal 1             (getf (aref envs 1) :seq))
      (assert-equal :frame        (getf (aref envs 2) :type))
      (assert-equal 2             (getf (aref envs 2) :seq))
      (assert-equal :frame        (getf (aref envs 3) :type))
      (assert-equal 3             (getf (aref envs 3) :seq))
      (assert-equal :stream_end   (getf (aref envs 4) :type))
      (assert-equal 3             (getf (aref envs 4) :final_seq))
      (assert-equal :complete     (getf (aref envs 4) :status)))))

;; ----------------------------------------------------------------
;; JSON round-trip: the emitted envelopes serialize cleanly

(deftest stream-frame-envelope-jsonable
  (with-clean-stream-state
    (multiple-value-bind (envs _token) (collect-envelopes)
      (declare (ignore _token))
      (kernel-events:emit-frame "v_1" '(:t 0.05d0 :y #(1.0d0 0.02d0)))
      (let ((json (kernel-events:envelope-to-json (aref envs 0))))
        (assert-true (search "\"type\":\"frame\"" json))
        (assert-true (search "\"view_id\":\"v_1\"" json))
        (assert-true (search "\"seq\":1" json))
        (assert-true (search "\"y\":[1.0,0.02]" json))))))
