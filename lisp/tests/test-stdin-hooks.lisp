;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for stdin-hooks.lisp ($readonly wrap) and the dbm-context
;;; stdin_request emission inside make-dbm-read-wrap.

(in-package :kernel-events-tests)

;; ----------------------------------------------------------------
;; Install / uninstall lifecycle

(deftest stdin-hooks-install-returns-t
  (unwind-protect
      (progn
        (kernel-events:uninstall-stdin-hooks)
        (assert-equal t (kernel-events:install-stdin-hooks)))
    (kernel-events:uninstall-stdin-hooks)))

(deftest stdin-hooks-install-second-call-returns-nil
  (unwind-protect
      (progn
        (kernel-events:install-stdin-hooks)
        (assert-equal nil (kernel-events:install-stdin-hooks)
                      "double install should be a no-op"))
    (kernel-events:uninstall-stdin-hooks)))

(deftest stdin-hooks-uninstall-returns-t-when-installed
  (kernel-events:install-stdin-hooks)
  (assert-equal t (kernel-events:uninstall-stdin-hooks)))

(deftest stdin-hooks-uninstall-returns-nil-when-not-installed
  (kernel-events:uninstall-stdin-hooks)
  (assert-equal nil (kernel-events:uninstall-stdin-hooks)))

(deftest stdin-hooks-installed-p-toggles
  (kernel-events:uninstall-stdin-hooks)
  (assert-false (kernel-events:stdin-hooks-installed-p))
  (unwind-protect
      (progn
        (kernel-events:install-stdin-hooks)
        (assert-true (kernel-events:stdin-hooks-installed-p)))
    (kernel-events:uninstall-stdin-hooks))
  (assert-false (kernel-events:stdin-hooks-installed-p)))

(deftest stdin-hooks-uninstall-restores-readonly
  (let ((original (symbol-function 'maxima::$readonly)))
    (unwind-protect
        (progn
          (kernel-events:install-stdin-hooks)
          (assert-false (eq original
                            (symbol-function 'maxima::$readonly)))
          (kernel-events:uninstall-stdin-hooks)
          (assert-true (eq original
                           (symbol-function 'maxima::$readonly))))
      (kernel-events:uninstall-stdin-hooks))))

;; ----------------------------------------------------------------
;; $readonly wrap closure: fires stdin_request before delegating

(deftest stdin-hooks-readonly-wrap-emits-before-orig
  (with-collector (envs)
    (let* ((orig-called nil)
           (orig (lambda (&rest args)
                   (declare (ignore args))
                   ;; By the time orig runs, the envelope should
                   ;; already be in the collector.
                   (setf orig-called (length envs))
                   'maxima::$done))
           (wrap (kernel-events::make-readonly-wrap orig)))
      (funcall wrap)
      (assert-equal 1 orig-called
                    "stdin_request envelope should precede the orig call"))
    (assert-equal :stdin_request (getf (aref envs 0) :type))
    (assert-equal :expression    (getf (aref envs 0) :kind))))

(deftest stdin-hooks-readonly-wrap-no-args-emits-empty-prompt
  (with-collector (envs)
    (let ((wrap (kernel-events::make-readonly-wrap
                  (lambda (&rest args) (declare (ignore args)) nil))))
      (funcall wrap))
    (assert-equal "" (getf (aref envs 0) :prompt))))

(deftest stdin-hooks-readonly-wrap-passes-args-through
  (with-collector (envs)
    (let* ((received nil)
           (wrap (kernel-events::make-readonly-wrap
                   (lambda (&rest args)
                     (setf received args)
                     :the-result))))
      (assert-equal :the-result (funcall wrap "a" "b" "c"))
      (assert-equal '("a" "b" "c") received))))

;; ----------------------------------------------------------------
;; dbm-context stdin_request: emitted by make-dbm-read-wrap when
;; *current-debug-depth* > 0; suppressed at depth 0

(deftest stdin-hooks-dbm-read-wrap-no-emit-at-depth-zero
  ;; Top-level REPL read: no stdin_request — `ready' covers it.
  (with-collector (envs)
    (let ((kernel-events:*current-debug-depth* 0)
          (orig (lambda (&rest args)
                  (declare (ignore args))
                  `((maxima::displayinput) nil 1))))
      (funcall (kernel-events::make-dbm-read-wrap orig)))
    (assert-equal 0
                  (count :stdin_request envs
                         :key (lambda (e) (getf e :type))))))

(deftest stdin-hooks-dbm-read-wrap-emits-debugger-command-at-depth
  ;; Inside a dbm session (depth > 0): emit stdin_request before the
  ;; read, with kind = :debugger_command.
  (with-collector (envs)
    (let ((kernel-events:*current-debug-depth* 1)
          (orig (lambda (&rest args)
                  (declare (ignore args))
                  `((maxima::displayinput) nil 1))))
      (funcall (kernel-events::make-dbm-read-wrap orig)))
    (let ((reqs (loop for e across envs
                      when (eq (getf e :type) :stdin_request)
                      collect e)))
      (assert-equal 1 (length reqs))
      (assert-equal :debugger_command (getf (first reqs) :kind))
      (assert-true (search "dbm:1" (getf (first reqs) :prompt))
                   "prompt should reflect the debug depth"))))

(deftest stdin-hooks-dbm-read-wrap-depth-reflected-in-prompt
  (with-collector (envs)
    (let ((kernel-events:*current-debug-depth* 3)
          (orig (lambda (&rest args)
                  (declare (ignore args))
                  `((maxima::displayinput) nil 1))))
      (funcall (kernel-events::make-dbm-read-wrap orig)))
    (let ((req (find :stdin_request envs
                     :key (lambda (e) (getf e :type)))))
      (assert-true (search "dbm:3" (getf req :prompt))))))
