;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for the debugger hooks.
;;;
;;; The wrappers are exercised directly: tests build a closure with
;;; a no-op ORIG, call it, and inspect the collector sink for
;;; debug_enter / debug_leave envelopes.  We do not actually enter
;;; SBCL's debugger (that would block on *debug-io*) — the closure
;;; logic and emission shapes are what we cover.

(in-package :kernel-events-tests)

(defmacro with-debugger-hooks-clean ((collector-var) &body body)
  "Set up a collector sink and reset *current-debug-depth*.  Always
   tears down — leaving hooks installed across tests would be a
   landmine."
  (let ((token (gensym "TOKEN")))
    `(let ((,collector-var (make-array 0 :adjustable t :fill-pointer 0)))
       (declare (ignorable ,collector-var))
       (kernel-events:clear-sinks)
       (kernel-events:reset-debug-depth)
       (let ((,token
               (kernel-events:register-sink
                 (lambda (e) (vector-push-extend e ,collector-var)))))
         (unwind-protect
             (progn ,@body)
           (kernel-events:uninstall-debugger-hooks)
           (kernel-events:unregister-sink ,token)
           (kernel-events:clear-sinks)
           (kernel-events:reset-debug-depth))))))

;; ----------------------------------------------------------------
;; Install / uninstall lifecycle

(deftest debugger-hooks-install-returns-t
  (unwind-protect
      (progn
        (kernel-events:uninstall-debugger-hooks)
        (assert-equal t (kernel-events:install-debugger-hooks)))
    (kernel-events:uninstall-debugger-hooks)))

(deftest debugger-hooks-install-second-call-returns-nil
  (unwind-protect
      (progn
        (kernel-events:install-debugger-hooks)
        (assert-equal nil (kernel-events:install-debugger-hooks)
                      "double install should be a no-op"))
    (kernel-events:uninstall-debugger-hooks)))

(deftest debugger-hooks-uninstall-returns-t-when-installed
  (kernel-events:install-debugger-hooks)
  (assert-equal t (kernel-events:uninstall-debugger-hooks)))

(deftest debugger-hooks-uninstall-returns-nil-when-not-installed
  (kernel-events:uninstall-debugger-hooks)
  (assert-equal nil (kernel-events:uninstall-debugger-hooks)))

(deftest debugger-hooks-installed-p-toggles
  (kernel-events:uninstall-debugger-hooks)
  (assert-false (kernel-events:debugger-hooks-installed-p))
  (unwind-protect
      (progn
        (kernel-events:install-debugger-hooks)
        (assert-true (kernel-events:debugger-hooks-installed-p)))
    (kernel-events:uninstall-debugger-hooks))
  (assert-false (kernel-events:debugger-hooks-installed-p)))

(deftest debugger-hooks-uninstall-restores-debugger-hook
  ;; Capture the pre-install value, install, uninstall, verify the
  ;; original is back.
  (let ((sentinel (lambda (c h) (declare (ignore c h)))))
    (let ((*debugger-hook* sentinel))
      (unwind-protect
          (progn
            (kernel-events:install-debugger-hooks)
            (assert-false (eq sentinel *debugger-hook*)
                          "install should have replaced *debugger-hook*")
            (kernel-events:uninstall-debugger-hooks)
            (assert-true (eq sentinel *debugger-hook*)
                         "uninstall should restore the captured hook"))
        (kernel-events:uninstall-debugger-hooks)))))

(deftest debugger-hooks-uninstall-restores-break-dbm-loop
  (let ((original (symbol-function 'maxima::break-dbm-loop)))
    (unwind-protect
        (progn
          (kernel-events:install-debugger-hooks)
          (assert-false (eq original
                            (symbol-function 'maxima::break-dbm-loop))
                        "install should have replaced break-dbm-loop")
          (kernel-events:uninstall-debugger-hooks)
          (assert-true (eq original
                           (symbol-function 'maxima::break-dbm-loop))
                       "uninstall should restore break-dbm-loop"))
      (kernel-events:uninstall-debugger-hooks))))

;; ----------------------------------------------------------------
;; emit-debug-enter / emit-debug-leave shapes

(deftest debugger-emit-enter-shape
  (with-debugger-hooks-clean (envs)
    (kernel-events:emit-debug-enter :lisp
                                    :condition-type 'simple-error
                                    :message "boom")
    (assert-equal 1 (length envs))
    (let ((e (aref envs 0)))
      (assert-equal :debug_enter (getf e :type))
      (assert-equal :lisp (getf e :level))
      (assert-equal 1 (getf e :depth))
      (assert-equal 'simple-error (getf e :condition_type))
      (assert-equal "boom" (getf e :message)))))

(deftest debugger-emit-leave-shape
  (with-debugger-hooks-clean (envs)
    (kernel-events:emit-debug-enter :maxima :message "div by zero")
    (kernel-events:emit-debug-leave :maxima)
    (assert-equal 2 (length envs))
    (let ((leave (aref envs 1)))
      (assert-equal :debug_leave (getf leave :type))
      (assert-equal :maxima (getf leave :level))
      ;; Depth at the time of emission is the pre-decrement value.
      (assert-equal 1 (getf leave :depth)))))

(deftest debugger-depth-increments-and-decrements
  (with-debugger-hooks-clean (envs)
    (assert-equal 0 kernel-events:*current-debug-depth*)
    (kernel-events:emit-debug-enter :lisp)
    (assert-equal 1 kernel-events:*current-debug-depth*)
    (kernel-events:emit-debug-enter :maxima)
    (assert-equal 2 kernel-events:*current-debug-depth*)
    (kernel-events:emit-debug-leave :maxima)
    (assert-equal 1 kernel-events:*current-debug-depth*)
    (kernel-events:emit-debug-leave :lisp)
    (assert-equal 0 kernel-events:*current-debug-depth*)))

(deftest debugger-emit-enter-tags-current-eval-id
  ;; When *current-eval-id* is bound (inside an eval), debug_enter
  ;; should carry it.
  (with-debugger-hooks-clean (envs)
    (let ((kernel-events::*current-eval-id* "e_99"))
      (kernel-events:emit-debug-enter :maxima))
    (assert-equal "e_99" (getf (aref envs 0) :eval_id))))

;; ----------------------------------------------------------------
;; break-dbm-loop wrap

(deftest debugger-break-dbm-loop-wrap-emits-enter-then-leave
  (with-debugger-hooks-clean (envs)
    (let* ((called nil)
           (orig (lambda (at) (declare (ignore at)) (setf called t) :resume))
           (wrap (kernel-events::make-break-dbm-loop-wrap orig)))
      (assert-equal :resume (funcall wrap nil))
      (assert-true called "wrap should call orig")
      (assert-equal 2 (length envs))
      (assert-equal :debug_enter (getf (aref envs 0) :type))
      (assert-equal :maxima (getf (aref envs 0) :level))
      (assert-equal :debug_leave (getf (aref envs 1) :type))
      (assert-equal :maxima (getf (aref envs 1) :level)))))

(deftest debugger-break-dbm-loop-wrap-leaves-on-non-local-exit
  ;; If orig does a throw, the unwind-protect cleanup must still
  ;; emit debug_leave.
  (with-debugger-hooks-clean (envs)
    (let* ((orig (lambda (at) (declare (ignore at)) (throw 'test-tag :gone)))
           (wrap (kernel-events::make-break-dbm-loop-wrap orig)))
      (catch 'test-tag (funcall wrap nil))
      (assert-equal 2 (length envs))
      (assert-equal :debug_enter (getf (aref envs 0) :type))
      (assert-equal :debug_leave (getf (aref envs 1) :type)))))

(deftest debugger-break-dbm-loop-wrap-captures-maxima-error-message
  (with-debugger-hooks-clean (envs)
    ;; Set $error so the wrap's enter-time snapshot picks up a
    ;; message.  Shape: ((mlist simp) "msg" . args)
    (let ((maxima::$error
            (list (list 'maxima::mlist 'maxima::simp)
                  "test failure"
                  'maxima::$x)))
      (let* ((orig (lambda (at) (declare (ignore at)) :resume))
             (wrap (kernel-events::make-break-dbm-loop-wrap orig)))
        (funcall wrap nil)
        (assert-equal "test failure" (getf (aref envs 0) :message))))))

(deftest debugger-break-dbm-loop-wrap-captures-frames-and-restarts
  ;; The dbm wrap calls capture-maxima-frames and
  ;; capture-maxima-restarts at enter time; both fields should be
  ;; present on the envelope.  Frames may be empty (no in-flight
  ;; dbm session in a unit test) but should be a vector; restarts
  ;; should include at least the built-in dbm commands.
  (with-debugger-hooks-clean (envs)
    (let* ((orig (lambda (at) (declare (ignore at)) :resume))
           (wrap (kernel-events::make-break-dbm-loop-wrap orig)))
      (funcall wrap nil)
      (let ((enter (aref envs 0)))
        (assert-true (or (null (getf enter :frames))
                         (vectorp (getf enter :frames))))
        (assert-true (vectorp (getf enter :restarts)))))))

;; ----------------------------------------------------------------
;; capture-maxima-restarts: shape + presence of built-in commands

(deftest debugger-capture-maxima-restarts-returns-vector
  (let ((rs (kernel-events:capture-maxima-restarts)))
    (assert-true (vectorp rs))
    (assert-true (plusp (length rs))
                 "Maxima ships with built-in dbm commands; expected at least one")))

(deftest debugger-capture-maxima-restarts-shape-is-name-description
  (let* ((rs (kernel-events:capture-maxima-restarts))
         (first (and (plusp (length rs)) (aref rs 0))))
    (when first
      (assert-true (stringp (getf first :name)))
      (assert-true (stringp (getf first :description))))))

(deftest debugger-capture-maxima-restarts-name-is-lowercased
  (let ((rs (kernel-events:capture-maxima-restarts)))
    (loop for r across rs
          for n = (getf r :name)
          do (assert-true (every (lambda (c) (not (upper-case-p c))) n)
                          "restart :name should be lowercased"))))

;; ----------------------------------------------------------------
;; capture-maxima-frames: defensive — returns vector or NIL

(deftest debugger-capture-maxima-frames-returns-vector-or-nil
  (let ((fs (kernel-events:capture-maxima-frames)))
    (assert-true (or (null fs) (vectorp fs)))))

;; ----------------------------------------------------------------
;; Lisp *debugger-hook* wrap
;;
;; We can't safely invoke-debugger in a test (it blocks on
;; *debug-io*).  Instead we install a no-op ORIG that captures the
;; condition and returns.

(deftest debugger-lisp-hook-wrap-emits-enter-then-leave
  (with-debugger-hooks-clean (envs)
    (let* ((captured nil)
           (orig (lambda (c h)
                   (declare (ignore h))
                   (setf captured c)
                   :handled))
           (wrap (kernel-events::make-lisp-debugger-hook orig))
           (condition (make-condition 'simple-error
                                       :format-control "test"
                                       :format-arguments nil)))
      (funcall wrap condition nil)
      (assert-true (typep captured 'simple-error)
                   "orig should have seen the condition")
      (assert-equal 2 (length envs))
      (assert-equal :debug_enter (getf (aref envs 0) :type))
      (assert-equal :lisp (getf (aref envs 0) :level))
      (assert-equal 'simple-error (getf (aref envs 0) :condition_type))
      (assert-equal :debug_leave (getf (aref envs 1) :type))
      (assert-equal :lisp (getf (aref envs 1) :level)))))

(deftest debugger-emit-enter-accepts-frames-and-restarts
  (with-debugger-hooks-clean (envs)
    (let ((frames   (vector "0: (foo 1 2)" "1: (bar)" ))
          (restarts (vector (list :name "abort" :description "Top level"))))
      (kernel-events:emit-debug-enter :lisp
                                      :frames   frames
                                      :restarts restarts))
    (let ((e (aref envs 0)))
      (assert-true (vectorp (getf e :frames)))
      (assert-equal 2 (length (getf e :frames)))
      (assert-true (vectorp (getf e :restarts)))
      (assert-equal 1 (length (getf e :restarts)))
      (assert-equal "abort"
                    (getf (aref (getf e :restarts) 0) :name)))))

#+sbcl
(deftest debugger-lisp-hook-wrap-captures-frames-and-restarts
  ;; The lisp-debugger-hook wrap should call capture-sbcl-backtrace
  ;; and capture-restarts at debug_enter time, so hosts can render
  ;; the stack and the available restarts.
  (with-debugger-hooks-clean (envs)
    (let* ((orig (lambda (c h) (declare (ignore c h)) :handled))
           (wrap (kernel-events::make-lisp-debugger-hook orig))
           (condition (make-condition 'simple-error
                                       :format-control "test"
                                       :format-arguments nil)))
      (funcall wrap condition nil)
      (let ((enter (aref envs 0)))
        ;; frames may legitimately be NIL if SBCL printing breaks,
        ;; but the field should be present in the envelope.
        (assert-true (or (null (getf enter :frames))
                         (vectorp (getf enter :frames))))
        (assert-true (or (null (getf enter :restarts))
                         (vectorp (getf enter :restarts))))))))

(deftest debugger-lisp-hook-wrap-passes-message
  (with-debugger-hooks-clean (envs)
    (let* ((orig (lambda (c h) (declare (ignore c h))))
           (wrap (kernel-events::make-lisp-debugger-hook orig))
           (condition (make-condition 'simple-error
                                       :format-control "bad value: ~a"
                                       :format-arguments '(42))))
      (funcall wrap condition nil)
      (let ((msg (getf (aref envs 0) :message)))
        (assert-true (stringp msg))
        (assert-true (search "42" msg)
                     "message should include the formatted arg")))))

(deftest debugger-lisp-hook-wrap-leaves-on-non-local-exit
  (with-debugger-hooks-clean (envs)
    (let* ((orig (lambda (c h)
                   (declare (ignore c h))
                   (throw 'test-tag :gone)))
           (wrap (kernel-events::make-lisp-debugger-hook orig))
           (condition (make-condition 'simple-error
                                       :format-control "test"
                                       :format-arguments nil)))
      (catch 'test-tag (funcall wrap condition nil))
      (assert-equal 2 (length envs))
      (assert-equal :debug_enter (getf (aref envs 0) :type))
      (assert-equal :debug_leave (getf (aref envs 1) :type)))))

(deftest debugger-lisp-hook-wrap-binds-debugger-hook-nil-inside
  ;; Inside the unwind-protect we shadow *debugger-hook* to NIL so
  ;; recursive errors don't re-enter our hook.  Verify the binding
  ;; is visible to ORIG.
  (with-debugger-hooks-clean (envs)
    (let* ((seen-hook :not-yet-seen)
           (orig (lambda (c h)
                   (declare (ignore c h))
                   (setf seen-hook *debugger-hook*)))
           (wrap (kernel-events::make-lisp-debugger-hook orig))
           (condition (make-condition 'simple-error
                                       :format-control "test"
                                       :format-arguments nil)))
      (let ((*debugger-hook* (lambda (c h) (declare (ignore c h)))))
        (funcall wrap condition nil))
      (assert-equal nil seen-hook
                    "*debugger-hook* should be NIL inside the wrap's body"))))

;; ----------------------------------------------------------------
;; maxima-error-message helper

(deftest debugger-maxima-error-message-with-string
  (let ((maxima::$error
          (list (list 'maxima::mlist 'maxima::simp)
                "the message"
                'maxima::$foo)))
    (assert-equal "the message" (kernel-events::maxima-error-message))))

(deftest debugger-maxima-error-message-with-empty-error
  (let ((maxima::$error (list (list 'maxima::mlist 'maxima::simp))))
    (assert-equal nil (kernel-events::maxima-error-message))))

;; ----------------------------------------------------------------
;; condition-message helper — defensive against broken print-object

(deftest debugger-condition-message-prints-condition
  (let ((c (make-condition 'simple-error
                           :format-control "oops"
                           :format-arguments nil)))
    (let ((msg (kernel-events::condition-message c)))
      (assert-true (stringp msg))
      (assert-true (search "oops" msg)))))
