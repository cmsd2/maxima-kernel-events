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
      ;; :packages and :supports are vectors so the JSON encoder
      ;; emits them as arrays (cons lists collide with plist).
      ;; assert-equal uses #'equal which doesn't compare vectors
      ;; element-wise; coerce to list for the structural check.
      (assert-equal '() (coerce (getf e :packages) 'list))
      (assert-true (vectorp (getf e :supports))))))

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
    (assert-equal '("foo" "bar")
                  (coerce (getf (aref envs 0) :packages) 'list))))

(deftest session-capabilities-supports-overridable
  (with-collector (envs)
    (kernel-events:emit-capabilities :supports '("custom"))
    (assert-equal '("custom")
                  (coerce (getf (aref envs 0) :supports) 'list))))

(deftest session-capabilities-carries-protocol-version
  (with-collector (envs)
    (kernel-events:emit-capabilities)
    (let ((e (aref envs 0)))
      (assert-equal "1" (getf e :protocol_version)
                    "envelope grammar version should be the v1 string")
      (assert-equal kernel-events:*protocol-version*
                    (getf e :protocol_version)))))

(deftest session-default-supports-includes-known-features
  ;; *default-capabilities-supports* is a vector, so use find rather
  ;; than member (which is list-only).
  (assert-true (find "streaming"
                     kernel-events:*default-capabilities-supports*
                     :test #'string=))
  (assert-true (find "debug_events"
                     kernel-events:*default-capabilities-supports*
                     :test #'string=))
  (assert-true (find "cancellation"
                     kernel-events:*default-capabilities-supports*
                     :test #'string=)))

;; ----------------------------------------------------------------
;; ready

(deftest session-ready-shape
  (with-collector (envs)
    (kernel-events:emit-ready)
    (assert-equal 1 (length envs))
    (assert-equal :ready (getf (aref envs 0) :type))))
