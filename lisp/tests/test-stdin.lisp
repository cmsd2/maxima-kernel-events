;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for stdin.lisp — stdin_request envelope + id allocator.

(in-package :kernel-events-tests)

;; ----------------------------------------------------------------
;; Request-id allocator

(deftest stdin-request-id-starts-at-r1
  (kernel-events:reset-stdin-counter)
  (assert-equal "r_1" (kernel-events:next-stdin-request-id)))

(deftest stdin-request-id-increments
  (kernel-events:reset-stdin-counter)
  (kernel-events:next-stdin-request-id)
  (kernel-events:next-stdin-request-id)
  (assert-equal "r_3" (kernel-events:next-stdin-request-id)))

(deftest stdin-reset-clears-counter
  (kernel-events:next-stdin-request-id)
  (kernel-events:next-stdin-request-id)
  (kernel-events:reset-stdin-counter)
  (assert-equal "r_1" (kernel-events:next-stdin-request-id)))

;; ----------------------------------------------------------------
;; Envelope shape

(deftest stdin-request-shape
  (with-collector (envs)
    (kernel-events:reset-stdin-counter)
    (let ((id (kernel-events:emit-stdin-request "Enter x: " :string)))
      (assert-equal "r_1" id)
      (assert-equal 1 (length envs))
      (let ((e (aref envs 0)))
        (assert-equal :stdin_request (getf e :type))
        (assert-equal "r_1" (getf e :request_id))
        (assert-equal "Enter x: " (getf e :prompt))
        (assert-equal :string (getf e :kind))))))

(deftest stdin-request-explicit-id
  (with-collector (envs)
    (let ((id (kernel-events:emit-stdin-request "?" :debugger_command
                                                :request-id "r_custom")))
      (assert-equal "r_custom" id)
      (assert-equal "r_custom" (getf (aref envs 0) :request_id)))))

(deftest stdin-request-tags-current-eval-id
  (with-collector (envs)
    (let ((kernel-events::*current-eval-id* "e_42"))
      (kernel-events:emit-stdin-request "go: " :string))
    (assert-equal "e_42" (getf (aref envs 0) :eval_id))))

(deftest stdin-request-eval-id-nil-outside-eval
  (with-collector (envs)
    (kernel-events:emit-stdin-request "go: " :string)
    (assert-equal nil (getf (aref envs 0) :eval_id))))
