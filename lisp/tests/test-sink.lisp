;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for sink registration, fanout, and error isolation.

(in-package :kernel-events-tests)

(defmacro with-clean-sinks (&body body)
  "Ensure the sinks list is empty around BODY."
  `(unwind-protect (progn
                     (kernel-events:clear-sinks)
                     ,@body)
     (kernel-events:clear-sinks)))

;; ----------------------------------------------------------------
;; Registration roundtrip

(deftest sink-register-returns-token
  (with-clean-sinks
    (let* ((sink (lambda (envelope) (declare (ignore envelope))))
           (token (kernel-events:register-sink sink)))
      (assert-true (eq token sink)
                   "register-sink should return the function itself"))))

(deftest sink-register-appears-in-list
  (with-clean-sinks
    (let ((sink (lambda (e) (declare (ignore e)))))
      (kernel-events:register-sink sink)
      (assert-equal 1 (length (kernel-events:list-sinks)))
      (assert-true (eq sink (first (kernel-events:list-sinks)))))))

(deftest sink-register-is-idempotent
  (with-clean-sinks
    (let ((sink (lambda (e) (declare (ignore e)))))
      (kernel-events:register-sink sink)
      (kernel-events:register-sink sink)
      (assert-equal 1 (length (kernel-events:list-sinks))
                    "registering twice should be a no-op"))))

(deftest sink-multiple-distinct-registers
  (with-clean-sinks
    (let ((a (lambda (e) (declare (ignore e))))
          (b (lambda (e) (declare (ignore e))))
          (c (lambda (e) (declare (ignore e)))))
      (kernel-events:register-sink a)
      (kernel-events:register-sink b)
      (kernel-events:register-sink c)
      (assert-equal 3 (length (kernel-events:list-sinks))))))

;; ----------------------------------------------------------------
;; Unregister

(deftest sink-unregister-removes
  (with-clean-sinks
    (let ((sink (lambda (e) (declare (ignore e)))))
      (kernel-events:register-sink sink)
      (assert-true (kernel-events:unregister-sink sink))
      (assert-equal 0 (length (kernel-events:list-sinks))))))

(deftest sink-unregister-unknown-returns-nil
  (with-clean-sinks
    (assert-false (kernel-events:unregister-sink
                    (lambda (e) (declare (ignore e))))
                  "unregistering an unknown sink should return NIL")))

(deftest sink-unregister-twice-is-nil-second-time
  (with-clean-sinks
    (let ((sink (lambda (e) (declare (ignore e)))))
      (kernel-events:register-sink sink)
      (assert-true (kernel-events:unregister-sink sink))
      (assert-false (kernel-events:unregister-sink sink)
                    "second unregister of the same sink should return NIL"))))

(deftest sink-unregister-one-leaves-others
  (with-clean-sinks
    (let ((a (lambda (e) (declare (ignore e))))
          (b (lambda (e) (declare (ignore e)))))
      (kernel-events:register-sink a)
      (kernel-events:register-sink b)
      (kernel-events:unregister-sink a)
      (let ((remaining (kernel-events:list-sinks)))
        (assert-equal 1 (length remaining))
        (assert-true (eq b (first remaining)))))))

;; ----------------------------------------------------------------
;; list-sinks and clear-sinks

(deftest sink-clear-empties-list
  (with-clean-sinks
    ;; Capture the loop variable inside the lambda so each registered
    ;; closure is a distinct function object — otherwise SBCL hoists
    ;; the empty closure to a constant and pushnew dedups all five.
    (dotimes (i 5)
      (kernel-events:register-sink
        (let ((id i)) (lambda (e) (declare (ignore e)) id))))
    (assert-equal 5 (length (kernel-events:list-sinks)))
    (kernel-events:clear-sinks)
    (assert-equal 0 (length (kernel-events:list-sinks)))))

(deftest sink-list-returns-fresh-copy
  ;; Caller mutating the returned list must NOT affect *sinks*.
  (with-clean-sinks
    (let ((sink (lambda (e) (declare (ignore e)))))
      (kernel-events:register-sink sink)
      (let ((listing (kernel-events:list-sinks)))
        (declare (ignorable listing))
        (setf listing (cons :spurious listing))
        (assert-equal 1 (length (kernel-events:list-sinks))
                      "external mutation should not affect *sinks*")
        ;; touch listing so it's not dead-code-eliminated
        (assert-true (eq :spurious (first listing)))))))

;; ----------------------------------------------------------------
;; Fanout

(deftest sink-fanout-delivers-to-all
  (with-clean-sinks
    (let ((collector-a (make-array 0 :adjustable t :fill-pointer 0))
          (collector-b (make-array 0 :adjustable t :fill-pointer 0)))
      (kernel-events:register-sink
        (lambda (e) (vector-push-extend e collector-a)))
      (kernel-events:register-sink
        (lambda (e) (vector-push-extend e collector-b)))
      (kernel-events:emit-envelope '(:type :hello))
      (kernel-events:emit-envelope '(:type :world))
      (assert-equal 2 (length collector-a))
      (assert-equal 2 (length collector-b))
      (assert-equal :hello (getf (aref collector-a 0) :type))
      (assert-equal :world (getf (aref collector-b 1) :type)))))

(deftest sink-emit-with-no-sinks-is-noop
  (with-clean-sinks
    ;; Should not signal even with zero sinks.
    (kernel-events:emit-envelope '(:type :probe))
    (assert-true t "emit-envelope with no sinks should not signal")))

(deftest sink-emit-returns-no-values
  (with-clean-sinks
    (kernel-events:register-sink (lambda (e) (declare (ignore e))))
    (assert-equal nil
                  (multiple-value-list (kernel-events:emit-envelope '(:type :probe)))
                  "emit-envelope should return (values) — zero values")))

(deftest sink-receives-the-same-envelope-object
  ;; Sinks receive the original Lisp plist, not a copy. Useful for
  ;; in-process transports that want to inspect by identity.
  (with-clean-sinks
    (let ((received nil)
          (envelope '(:type :probe :payload (1 2 3))))
      (kernel-events:register-sink
        (lambda (e) (setf received e)))
      (kernel-events:emit-envelope envelope)
      (assert-true (eq envelope received)
                   "sink should receive the same cons, not a copy"))))

;; ----------------------------------------------------------------
;; Per-sink error isolation

(deftest sink-error-does-not-stop-others
  (with-clean-sinks
    (let ((reached nil))
      (kernel-events:register-sink
        (lambda (e) (declare (ignore e)) (error "kaboom")))
      (kernel-events:register-sink
        (lambda (e) (declare (ignore e)) (setf reached t)))
      (kernel-events:emit-envelope '(:type :probe))
      (assert-true reached
                   "second sink should still receive after first errors"))))

(deftest sink-error-does-not-propagate-from-emit
  (with-clean-sinks
    (kernel-events:register-sink
      (lambda (e) (declare (ignore e)) (error "kaboom")))
    ;; emit-envelope itself must NEVER signal.
    (kernel-events:emit-envelope '(:type :probe))
    (assert-true t "emit-envelope should swallow sink errors")))

(deftest sink-multiple-errors-all-isolated
  (with-clean-sinks
    (let ((survivor-count 0))
      (kernel-events:register-sink
        (lambda (e) (declare (ignore e)) (error "first")))
      (kernel-events:register-sink
        (lambda (e) (declare (ignore e)) (incf survivor-count)))
      (kernel-events:register-sink
        (lambda (e) (declare (ignore e)) (error "third")))
      (kernel-events:register-sink
        (lambda (e) (declare (ignore e)) (incf survivor-count)))
      (kernel-events:emit-envelope '(:type :probe))
      (assert-equal 2 survivor-count
                    "every non-erroring sink should still be called"))))

;; ----------------------------------------------------------------
;; Type checking

(deftest sink-register-non-function-errors
  (with-clean-sinks
    (assert-signals 'error
                    (lambda () (kernel-events:register-sink "not a function")))))

(deftest sink-register-nil-errors
  (with-clean-sinks
    (assert-signals 'error
                    (lambda () (kernel-events:register-sink nil)))))
