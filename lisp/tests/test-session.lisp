;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for session.lisp — capabilities + ready envelopes.

(in-package :kernel-events-tests)

(defmacro with-collector ((collector-var) &body body)
  "Bind COLLECTOR-VAR to a fresh vector that captures every emitted
   envelope; tear down sinks afterwards."
  (let ((token (gensym "TOKEN")))
    `(let ((,collector-var (make-array 0 :adjustable t :fill-pointer 0)))
       (declare (ignorable ,collector-var))
       (kernel-events:clear-sinks)
       (let ((,token (kernel-events:register-sink
                       (lambda (e) (vector-push-extend e ,collector-var)))))
         (unwind-protect (progn ,@body)
           (kernel-events:unregister-sink ,token)
           (kernel-events:clear-sinks))))))

;; ----------------------------------------------------------------
;; capabilities

(deftest session-capabilities-default-shape
  (with-collector (envs)
    (kernel-events:emit-capabilities)
    (assert-equal 1 (length envs))
    (let ((e (aref envs 0)))
      (assert-equal :capabilities (getf e :type))
      (assert-true (or (null (getf e :kernel_version))
                       (stringp (getf e :kernel_version))))
      (assert-true (stringp (getf e :lisp))
                   "lisp implementation string should be set")
      (assert-equal '() (getf e :packages))
      (assert-true (listp (getf e :supports))))))

(deftest session-capabilities-explicit-kernel-version
  (with-collector (envs)
    (kernel-events:emit-capabilities :kernel-version "5.47.0"
                                     :lisp "SBCL 2.4.10")
    (let ((e (aref envs 0)))
      (assert-equal "5.47.0" (getf e :kernel_version))
      (assert-equal "SBCL 2.4.10" (getf e :lisp)))))

(deftest session-capabilities-packages-list
  (with-collector (envs)
    (kernel-events:emit-capabilities :packages '("foo" "bar"))
    (assert-equal '("foo" "bar") (getf (aref envs 0) :packages))))

(deftest session-capabilities-supports-overridable
  (with-collector (envs)
    (kernel-events:emit-capabilities :supports '("custom"))
    (assert-equal '("custom") (getf (aref envs 0) :supports))))

(deftest session-default-supports-includes-known-features
  (assert-true (member "streaming"
                       kernel-events:*default-capabilities-supports*
                       :test #'string=))
  (assert-true (member "debug_events"
                       kernel-events:*default-capabilities-supports*
                       :test #'string=))
  (assert-true (member "cancellation"
                       kernel-events:*default-capabilities-supports*
                       :test #'string=)))

;; ----------------------------------------------------------------
;; ready

(deftest session-ready-shape
  (with-collector (envs)
    (kernel-events:emit-ready)
    (assert-equal 1 (length envs))
    (assert-equal :ready (getf (aref envs 0) :type))))
