;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for emit-envelope routing — the integration point between
;;; envelopes and sinks.

(in-package :kernel-events-tests)

;; with-clean-sinks is defined in test-sink.lisp, which loads first.

;; ----------------------------------------------------------------
;; Basic routing

(deftest emit-routes-single-envelope-to-single-sink
  (with-clean-sinks
    (let ((captured nil))
      (kernel-events:register-sink (lambda (e) (push e captured)))
      (kernel-events:emit-envelope (kernel-events:make-envelope :ready))
      (assert-equal 1 (length captured))
      (assert-equal :ready (getf (first captured) :type)))))

(deftest emit-routes-multiple-envelopes-in-order-per-sink
  (with-clean-sinks
    (let ((captured (make-array 0 :adjustable t :fill-pointer 0)))
      (kernel-events:register-sink
        (lambda (e) (vector-push-extend e captured)))
      (kernel-events:emit-envelope (kernel-events:make-envelope :first))
      (kernel-events:emit-envelope (kernel-events:make-envelope :second))
      (kernel-events:emit-envelope (kernel-events:make-envelope :third))
      (assert-equal 3 (length captured))
      (assert-equal :first  (getf (aref captured 0) :type))
      (assert-equal :second (getf (aref captured 1) :type))
      (assert-equal :third  (getf (aref captured 2) :type)))))

;; ----------------------------------------------------------------
;; Composition with JSON output: a sink that encodes for transport

(deftest emit-with-json-encoding-sink
  (with-clean-sinks
    (let ((written (make-array 0 :adjustable t :fill-pointer 0)))
      (kernel-events:register-sink
        (lambda (e)
          (vector-push-extend (kernel-events:envelope-to-json e)
                              written)))
      (kernel-events:emit-envelope
        (kernel-events:make-envelope :frame
                                     :view_id "v_1" :seq 0
                                     :payload '(:t 0.0d0 :y #(1.0d0))))
      (assert-equal 1 (length written))
      (let ((json (aref written 0)))
        (assert-true (search "\"type\":\"frame\"" json))
        (assert-true (search "\"view_id\":\"v_1\"" json))
        (assert-true (search "\"y\":[1.0]" json))))))

;; ----------------------------------------------------------------
;; Sink can be transient (registered, used, then unregistered)

(deftest emit-respects-mid-stream-unregister
  (with-clean-sinks
    (let* ((count-a 0)
           (count-b 0)
           (sink-a (kernel-events:register-sink
                     (lambda (e) (declare (ignore e)) (incf count-a))))
           (sink-b (kernel-events:register-sink
                     (lambda (e) (declare (ignore e)) (incf count-b)))))
      (declare (ignore sink-b))
      ;; Both fire
      (kernel-events:emit-envelope (kernel-events:make-envelope :probe))
      ;; Remove A
      (kernel-events:unregister-sink sink-a)
      ;; Only B fires
      (kernel-events:emit-envelope (kernel-events:make-envelope :probe))
      (assert-equal 1 count-a)
      (assert-equal 2 count-b))))

;; ----------------------------------------------------------------
;; A sink registered during emission does NOT receive the current
;; envelope (call-sinks snapshots the list at the start)

(deftest emit-snapshot-isolates-mid-emission-registration
  (with-clean-sinks
    (let* ((got-by-new 0)
           (new-sink (lambda (e) (declare (ignore e)) (incf got-by-new))))
      (kernel-events:register-sink
        (lambda (e)
          (declare (ignore e))
          (kernel-events:register-sink new-sink)))
      (kernel-events:emit-envelope (kernel-events:make-envelope :probe))
      (assert-equal 0 got-by-new
                    "newly-registered sink should not see the current envelope")
      ;; Next emit should reach it
      (kernel-events:emit-envelope (kernel-events:make-envelope :probe))
      (assert-equal 1 got-by-new))))

;; ----------------------------------------------------------------
;; emit-envelope returns no values

(deftest emit-returns-zero-values
  (with-clean-sinks
    (let ((vs (multiple-value-list
                (kernel-events:emit-envelope
                  (kernel-events:make-envelope :probe)))))
      (assert-equal nil vs
                    "emit-envelope should return (values), i.e. zero values"))))
