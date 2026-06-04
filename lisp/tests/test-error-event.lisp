;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for error-event.lisp — the structured error envelope.

(in-package :kernel-events-tests)

;; ----------------------------------------------------------------
;; Shape

(deftest error-event-minimal-shape
  (with-collector (envs)
    (kernel-events:emit-error :maxima_error "Division by 0")
    (assert-equal 1 (length envs))
    (let ((e (aref envs 0)))
      (assert-equal :error (getf e :type))
      (assert-equal :maxima_error (getf e :kind))
      (assert-equal "Division by 0" (getf e :message))
      (assert-equal :false (getf e :recoverable)))))

(deftest error-event-with-location-and-form
  (with-collector (envs)
    (kernel-events:emit-error :parser_error
                              "unexpected token"
                              :location (list :line 3 :column 12)
                              :form "1/")
    (let ((e (aref envs 0)))
      (assert-equal (list :line 3 :column 12) (getf e :location))
      (assert-equal "1/" (getf e :form)))))

(deftest error-event-with-backtrace
  (with-collector (envs)
    (kernel-events:emit-error :lisp_error
                              "boom"
                              :backtrace (vector "frame 0" "frame 1"))
    (let ((bt (getf (aref envs 0) :backtrace)))
      (assert-true (vectorp bt))
      (assert-equal 2 (length bt))
      (assert-equal "frame 0" (aref bt 0)))))

(deftest error-event-recoverable-flag
  (with-collector (envs)
    (kernel-events:emit-error :timeout "slow"
                              :recoverable t)
    (assert-equal t (getf (aref envs 0) :recoverable))))

(deftest error-event-eval-id-from-dynamic
  (with-collector (envs)
    (let ((kernel-events::*current-eval-id* "e_99"))
      (kernel-events:emit-error :maxima_error "boom"))
    (assert-equal "e_99" (getf (aref envs 0) :eval_id))))

(deftest error-event-eval-id-explicit-overrides-dynamic
  (with-collector (envs)
    (let ((kernel-events::*current-eval-id* "e_99"))
      (kernel-events:emit-error :maxima_error "boom"
                                :eval-id "e_explicit"))
    (assert-equal "e_explicit" (getf (aref envs 0) :eval_id))))

(deftest error-event-eval-id-nil-outside-eval
  (with-collector (envs)
    (kernel-events:emit-error :lisp_error "boom")
    (assert-equal nil (getf (aref envs 0) :eval_id))))
