;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for the cancellation primitives.
;;;
;;; Covers the in-process flag mechanics (request-cancel,
;;; cancel-requested-p, check-cancel, reset-cancel-flag) plus the
;;; threaded watcher (start-cancel-watcher / stop-cancel-watcher).

(in-package :kernel-events-tests)

(defmacro with-clean-cancel-state (&body body)
  "Ensure no watcher is running and the flag is clear around BODY."
  `(unwind-protect
       (progn
         (kernel-events:stop-cancel-watcher)
         (kernel-events:reset-cancel-flag)
         ,@body)
     (kernel-events:stop-cancel-watcher)
     (kernel-events:reset-cancel-flag)))

;; ----------------------------------------------------------------
;; Flag mechanics: request-cancel, cancel-requested-p, reset

(deftest cancel-flag-starts-clear
  (with-clean-cancel-state
    (assert-false (kernel-events:cancel-requested-p))))

(deftest cancel-request-sets-flag
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (assert-true (kernel-events:cancel-requested-p))))

(deftest cancel-request-is-idempotent
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (kernel-events:request-cancel)
    (kernel-events:request-cancel)
    (assert-true (kernel-events:cancel-requested-p))))

(deftest cancel-request-returns-t
  (with-clean-cancel-state
    (assert-equal t (kernel-events:request-cancel))))

(deftest reset-cancel-flag-clears
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (kernel-events:reset-cancel-flag)
    (assert-false (kernel-events:cancel-requested-p))))

(deftest reset-cancel-flag-returns-previous-value
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (assert-equal t (kernel-events:reset-cancel-flag))
    ;; Once cleared, reset returns nil.
    (assert-equal nil (kernel-events:reset-cancel-flag))))

;; ----------------------------------------------------------------
;; check-cancel: signal-or-pass

(deftest check-cancel-clear-returns-nil
  (with-clean-cancel-state
    (assert-equal nil (kernel-events:check-cancel))))

(deftest check-cancel-pending-signals
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (assert-signals 'kernel-events:cancellation-requested
                    (lambda () (kernel-events:check-cancel)))))

(deftest check-cancel-does-not-auto-reset
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (handler-case (kernel-events:check-cancel)
      (kernel-events:cancellation-requested () nil))
    ;; Flag is still set so the next checker also unwinds — explicit
    ;; reset-cancel-flag is required to clear it.
    (assert-true (kernel-events:cancel-requested-p))))

(deftest check-cancel-condition-carries-view-id
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (handler-case
        (progn (kernel-events:check-cancel :view-id "v_42")
               (error "should have unwound"))
      (kernel-events:cancellation-requested (c)
        (assert-equal "v_42" (kernel-events:cancellation-view-id c))))))

(deftest check-cancel-condition-nil-view-id-by-default
  (with-clean-cancel-state
    (kernel-events:request-cancel)
    (handler-case
        (progn (kernel-events:check-cancel)
               (error "should have unwound"))
      (kernel-events:cancellation-requested (c)
        (assert-equal nil (kernel-events:cancellation-view-id c))))))

(deftest cancellation-condition-report-includes-view-id
  (let ((c (make-condition 'kernel-events:cancellation-requested
                           :view-id "v_7")))
    (let ((rendered (princ-to-string c)))
      (assert-true (search "v_7" rendered)
                   "report should include the view-id when present"))))

(deftest cancellation-condition-report-without-view-id
  (let ((c (make-condition 'kernel-events:cancellation-requested)))
    (let ((rendered (princ-to-string c)))
      (assert-true (search "Cancellation requested" rendered)))))

;; ----------------------------------------------------------------
;; Watcher: start / stop / running-p

(deftest watcher-not-running-by-default
  (with-clean-cancel-state
    (assert-false (kernel-events:cancel-watcher-running-p))))

(deftest watcher-start-then-running
  (with-clean-cancel-state
    ;; A read-fn that blocks forever (we'll stop the watcher explicitly).
    (kernel-events:start-cancel-watcher
      (lambda () (sleep 60) nil))
    (assert-true (kernel-events:cancel-watcher-running-p))
    (kernel-events:stop-cancel-watcher)))

(deftest watcher-double-start-errors
  (with-clean-cancel-state
    (kernel-events:start-cancel-watcher
      (lambda () (sleep 60) nil))
    (unwind-protect
        (assert-signals 'error
                        (lambda ()
                          (kernel-events:start-cancel-watcher
                            (lambda () nil))))
      (kernel-events:stop-cancel-watcher))))

(deftest watcher-stop-returns-t-when-running
  (with-clean-cancel-state
    (kernel-events:start-cancel-watcher
      (lambda () :stop))
    ;; Watcher exited on first iteration via :stop.
    ;; Give it a moment to register.
    (sleep 0.05)
    (assert-equal t (kernel-events:stop-cancel-watcher))))

(deftest watcher-stop-nil-when-not-running
  (with-clean-cancel-state
    (assert-false (kernel-events:stop-cancel-watcher))))

(deftest watcher-readfn-truthy-sets-flag
  (with-clean-cancel-state
    ;; A read-fn that returns T once, then :stop forever.  Wait
    ;; briefly for the flag to flip, then assert.
    (let ((count 0))
      (kernel-events:start-cancel-watcher
        (lambda ()
          (incf count)
          (cond
            ((= count 1) t)
            (t (sleep 0.01) :stop)))))
    (sleep 0.1)
    (assert-true (kernel-events:cancel-requested-p))
    (kernel-events:stop-cancel-watcher)))
