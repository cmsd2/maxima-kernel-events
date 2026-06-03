;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Minimal test harness for kernel-events.
;;;
;;; Tests execute at *load* time.  A test that signals an error
;;; propagates up through the LOAD, which Maxima's batch(test) sees
;;; as a failed assertion — mxpm reports the failure with the test
;;; name and the underlying error.
;;;
;;; No registry, no run-all, no pass/fail printer.  Maxima/mxpm
;;; already provide those at the rtest level; duplicating them here
;;; was waste.
;;;
;;; Usage in a test file:
;;;
;;;   (in-package :kernel-events-tests)
;;;
;;;   (deftest sink-register-returns-token
;;;     (let* ((sink (lambda (e) (declare (ignore e))))
;;;            (token (kernel-events:register-sink sink)))
;;;       (assert-equal token sink)))

(defpackage :kernel-events-tests
  (:use :cl :kernel-events)
  (:export #:deftest
           #:assert-equal
           #:assert-true
           #:assert-false
           #:assert-signals))

(in-package :kernel-events-tests)

(defmacro deftest (name &body body)
  "Execute BODY immediately.  If anything inside signals an error,
   re-raise it with the test NAME prepended so the failing test is
   identifiable from the LOAD failure."
  `(handler-case (progn ,@body)
     (error (e)
       (error "test ~s failed: ~a" ',name e))))

(defun assert-equal (expected actual &optional message)
  (unless (equal expected actual)
    (error "assertion failed~@[ (~a)~]: expected ~s, got ~s"
           message expected actual)))

(defun assert-true (x &optional message)
  (unless x
    (error "assertion failed~@[ (~a)~]: expected truthy, got NIL"
           message)))

(defun assert-false (x &optional message)
  (when x
    (error "assertion failed~@[ (~a)~]: expected NIL, got ~s"
           message x)))

(defun assert-signals (condition-type thunk &optional message)
  (handler-case
      (progn
        (funcall thunk)
        (error "assertion failed~@[ (~a)~]: expected ~s, no error signalled"
               message condition-type))
    (condition (c)
      (unless (typep c condition-type)
        (error "assertion failed~@[ (~a)~]: expected ~s, got ~s"
               message condition-type (type-of c))))))
