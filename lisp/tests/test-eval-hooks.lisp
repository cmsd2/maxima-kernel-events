;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for the evaluation lifecycle hooks.
;;;
;;; install-eval-hooks wraps dbm-read and toplevel-macsyma-eval.
;;; Tests call (maxima::toplevel-macsyma-eval ...) directly with
;;; constructed Maxima forms and inspect the collector sink for the
;;; expected eval_begin / eval_result / eval_end sequence.  To
;;; simulate the suppression-flag handoff from dbm-read (which the
;;; tests bypass), tests bind kernel-events::*next-eval-suppressed*
;;; around the call.

(in-package :kernel-events-tests)

(defmacro with-installed-eval-hooks ((collector-var) &body body)
  "Install eval hooks around BODY with a fresh collector sink.
   COLLECTOR-VAR is bound to a fill-pointer'd vector accumulating
   every emitted envelope.  Always uninstalls and resets state."
  (let ((token (gensym "TOKEN")))
    `(let ((,collector-var (make-array 0 :adjustable t :fill-pointer 0)))
       (declare (ignorable ,collector-var))
       (kernel-events:clear-sinks)
       (kernel-events:reset-eval-counter)
       (kernel-events:reset-cancel-flag)
       (let ((,token
               (kernel-events:register-sink
                 (lambda (e) (vector-push-extend e ,collector-var)))))
         (unwind-protect
             (progn
               (kernel-events:install-eval-hooks)
               ,@body)
           (kernel-events:uninstall-eval-hooks)
           (kernel-events:unregister-sink ,token)
           (kernel-events:clear-sinks)
           (kernel-events:reset-eval-counter))))))

(defun envs-of-type (envs type)
  "Return the subset of ENVS whose :type is TYPE."
  (loop for e across envs when (eq type (getf e :type)) collect e))

;; ----------------------------------------------------------------
;; Install / uninstall lifecycle

(deftest eval-hooks-install-returns-t
  (unwind-protect
      (progn
        (kernel-events:uninstall-eval-hooks)        ; just in case
        (assert-equal t (kernel-events:install-eval-hooks)))
    (kernel-events:uninstall-eval-hooks)))

(deftest eval-hooks-install-second-call-returns-nil
  (unwind-protect
      (progn
        (kernel-events:install-eval-hooks)
        (assert-equal nil (kernel-events:install-eval-hooks)
                      "double install should be a no-op"))
    (kernel-events:uninstall-eval-hooks)))

(deftest eval-hooks-uninstall-returns-t-when-installed
  (kernel-events:install-eval-hooks)
  (assert-equal t (kernel-events:uninstall-eval-hooks)))

(deftest eval-hooks-uninstall-returns-nil-when-not-installed
  (kernel-events:uninstall-eval-hooks)
  (assert-equal nil (kernel-events:uninstall-eval-hooks)))

(deftest eval-hooks-installed-p-toggles
  (kernel-events:uninstall-eval-hooks)
  (assert-false (kernel-events:eval-hooks-installed-p))
  (unwind-protect
      (progn
        (kernel-events:install-eval-hooks)
        (assert-true (kernel-events:eval-hooks-installed-p)))
    (kernel-events:uninstall-eval-hooks))
  (assert-false (kernel-events:eval-hooks-installed-p)))

;; ----------------------------------------------------------------
;; Eval-id allocation

(deftest eval-hooks-eval-id-starts-at-e1
  (kernel-events:reset-eval-counter)
  (assert-equal "e_1" (kernel-events:next-eval-id)))

(deftest eval-hooks-eval-id-increments
  (kernel-events:reset-eval-counter)
  (kernel-events:next-eval-id)
  (kernel-events:next-eval-id)
  (assert-equal "e_3" (kernel-events:next-eval-id)))

(deftest eval-hooks-current-eval-id-nil-outside-eval
  (kernel-events:reset-eval-counter)
  (assert-equal nil (kernel-events:current-eval-id)))

;; ----------------------------------------------------------------
;; Eval-result helper (no hooks installed; direct test)

(deftest eval-hooks-emit-eval-result-shape
  (let ((envs (make-array 0 :adjustable t :fill-pointer 0)))
    (kernel-events:clear-sinks)
    (kernel-events:register-sink (lambda (e) (vector-push-extend e envs)))
    (kernel-events:emit-eval-result "e_1" 42
                                    :label "%o7"
                                    :suppressed nil)
    (kernel-events:clear-sinks)
    (let ((e (aref envs 0)))
      (assert-equal :eval_result (getf e :type))
      (assert-equal "e_1" (getf e :eval_id))
      (assert-equal "%o7" (getf e :output_label))
      (assert-equal :false (getf e :suppressed))
      (let ((bundle (getf e :mime_bundle)))
        (assert-true (hash-table-p bundle))
        (assert-equal "42" (gethash "text/plain" bundle))))))

(deftest eval-hooks-emit-eval-result-suppressed-flag
  (let ((envs (make-array 0 :adjustable t :fill-pointer 0)))
    (kernel-events:clear-sinks)
    (kernel-events:register-sink (lambda (e) (vector-push-extend e envs)))
    (kernel-events:emit-eval-result "e_1" 42 :suppressed t)
    (kernel-events:clear-sinks)
    (assert-equal t (getf (aref envs 0) :suppressed))))

;; ----------------------------------------------------------------
;; current-output-label-string

(deftest eval-hooks-output-label-string-format
  ;; $outchar defaults to $%o; the helper strips the leading $ and
  ;; appends $linenum.  Save/restore $linenum around the test.
  (let ((saved-linenum (symbol-value 'maxima::$linenum)))
    (unwind-protect
        (progn
          (setf (symbol-value 'maxima::$linenum) 7)
          (let ((label (kernel-events::current-output-label-string)))
            (assert-true (stringp label))
            ;; Strips leading $ from $outchar, appends linenum.
            (assert-true (search "7" label)
                         "label should contain the linenum")))
      (setf (symbol-value 'maxima::$linenum) saved-linenum))))

(deftest eval-hooks-output-label-string-strips-dollar
  ;; Whatever $outchar is, the leading $ must be stripped.
  (let ((label (kernel-events::current-output-label-string)))
    (assert-true (stringp label))
    (assert-false (and (plusp (length label))
                       (char= #\$ (char label 0)))
                  "leading $ should be stripped")))

;; ----------------------------------------------------------------
;; End-to-end: toplevel-macsyma-eval wrap
;;
;; With the new design, eval_result is emitted from inside the
;; toplevel-eval wrap itself, carrying the suppression flag that was
;; stashed by the dbm-read wrap into *next-eval-suppressed*.  Tests
;; that bypass dbm-read can pre-bind *next-eval-suppressed* to
;; control which branch is exercised.

(deftest eval-hooks-non-suppressed-emits-begin-result-end
  (with-installed-eval-hooks (envs)
    (let ((kernel-events::*next-eval-suppressed* nil))
      (maxima::toplevel-macsyma-eval 42))
    ;; Expect: eval_begin, eval_result, eval_end (in that order)
    (assert-equal 3 (length envs))
    (assert-equal :eval_begin  (getf (aref envs 0) :type))
    (assert-equal :eval_result (getf (aref envs 1) :type))
    (assert-equal :eval_end    (getf (aref envs 2) :type))
    ;; Same eval_id throughout
    (let ((id (getf (aref envs 0) :eval_id)))
      (assert-equal id (getf (aref envs 1) :eval_id))
      (assert-equal id (getf (aref envs 2) :eval_id)))
    ;; eval_result carries the value bundle and the label
    (assert-equal :false (getf (aref envs 1) :suppressed))
    (let ((label (getf (aref envs 1) :output_label)))
      (assert-true (stringp label))
      (assert-true (and (>= (length label) 2)
                        (char= #\% (char label 0)))
                   "output_label should look like %oN"))
    (let ((bundle (getf (aref envs 1) :mime_bundle)))
      (assert-equal "42" (gethash "text/plain" bundle)))
    ;; eval_end status :ok
    (assert-equal :ok (getf (aref envs 2) :status))))

(deftest eval-hooks-suppressed-emits-suppressed-result
  (with-installed-eval-hooks (envs)
    ;; Simulate dbm-read having captured `$'-terminated input.
    (let ((kernel-events::*next-eval-suppressed* t))
      (maxima::toplevel-macsyma-eval 42))
    (assert-equal 3 (length envs))
    (assert-equal :eval_begin  (getf (aref envs 0) :type))
    (assert-equal :eval_result (getf (aref envs 1) :type))
    (assert-equal :eval_end    (getf (aref envs 2) :type))
    (assert-equal t (getf (aref envs 1) :suppressed))
    (let ((bundle (getf (aref envs 1) :mime_bundle)))
      (assert-equal "42" (gethash "text/plain" bundle)))))

;; ----------------------------------------------------------------
;; dbm-read wrap: suppression-flag capture from form header

(deftest eval-hooks-dbm-read-wrap-displayinput-sets-non-suppressed
  ;; Simulate dbm-read returning a `;'-terminated form:
  ;; ((displayinput) c-tag expr).  The wrap should set
  ;; *next-eval-suppressed* to NIL.
  (let ((kernel-events::*next-eval-suppressed* :unset)
        (fake-read-result `((maxima::displayinput) nil 42)))
    (let* ((orig (lambda (&rest args) (declare (ignore args)) fake-read-result))
           (wrapped (kernel-events::make-dbm-read-wrap orig)))
      (funcall wrapped)
      (assert-equal nil kernel-events::*next-eval-suppressed*))))

(deftest eval-hooks-dbm-read-wrap-non-displayinput-sets-suppressed
  ;; A `$'-terminated form has a different header (e.g. (msetq)
  ;; ...).  The wrap should set *next-eval-suppressed* to T.
  (let ((kernel-events::*next-eval-suppressed* :unset)
        (fake-read-result `((maxima::msetq) nil 42)))
    (let* ((orig (lambda (&rest args) (declare (ignore args)) fake-read-result))
           (wrapped (kernel-events::make-dbm-read-wrap orig)))
      (funcall wrapped)
      (assert-equal t kernel-events::*next-eval-suppressed*))))

(deftest eval-hooks-dbm-read-wrap-passes-through-result
  (let ((fake-read-result `((maxima::displayinput) nil 42)))
    (let* ((orig (lambda (&rest args) (declare (ignore args)) fake-read-result))
           (wrapped (kernel-events::make-dbm-read-wrap orig)))
      (assert-equal fake-read-result (funcall wrapped)))))

;; ----------------------------------------------------------------
;; Error path
;;
;; The toplevel wrap observes four failure shapes and surfaces each
;; as an `error' envelope before the closing `eval_end':
;;   - throw 'macsyma-quit       -> kind :maxima_error (re-thrown)
;;   - maxima-$error signal      -> kind :maxima_error (declined)
;;   - cancellation-requested    -> kind :cancelled    (consumed)
;;   - any other cl:error        -> kind :lisp_error   (declined)

(deftest eval-hooks-maxima-error-signal-emits-error-envelope
  ;; When merror signals (e.g. *merror-signals-$error-p* T, or
  ;; errcatch frame), our handler-bind observes maxima-$error,
  ;; emits :maxima_error, and declines so the condition keeps
  ;; propagating.  Simulate by signalling directly — calling real
  ;; merror inside a test interacts badly with rtest's errcatch.
  (with-installed-eval-hooks (envs)
    (kernel-events:uninstall-eval-hooks)
    (let ((maxima::$error (list (list 'maxima::mlist) "test failure"))
          (wrap (kernel-events::make-toplevel-eval-wrap
                  (lambda (x)
                    (declare (ignore x))
                    (error 'maxima::maxima-$error)))))
      (handler-case (funcall wrap 1)
        (maxima::maxima-$error () nil)
        (error () nil)))
    (let ((errs    (envs-of-type envs :error))
          (begins  (envs-of-type envs :eval_begin))
          (ends    (envs-of-type envs :eval_end))
          (results (envs-of-type envs :eval_result)))
      (assert-equal 1 (length begins))
      (assert-equal 1 (length ends))
      (assert-equal 0 (length results))
      (assert-equal :error (getf (first ends) :status))
      (assert-equal 1 (length errs))
      (assert-equal :maxima_error (getf (first errs) :kind)))))

(deftest eval-hooks-maxima-throw-emits-error-envelope
  ;; Default merror path: throw 'macsyma-quit (NOT a CL condition).
  ;; The wrap catches the throw, emits :maxima_error, and re-throws
  ;; so continue's outer catch still sees the abort.  Simulate the
  ;; throw directly so the test doesn't depend on triggering merror.
  (with-installed-eval-hooks (envs)
    (kernel-events:uninstall-eval-hooks)
    (let ((maxima::$error (list (list 'maxima::mlist) "thrown"))
          (wrap (kernel-events::make-toplevel-eval-wrap
                  (lambda (x)
                    (declare (ignore x))
                    (throw 'maxima::macsyma-quit 'maxima::maxima-error)))))
      (catch 'maxima::macsyma-quit (funcall wrap 1)))
    (let ((errs (envs-of-type envs :error))
          (ends (envs-of-type envs :eval_end)))
      (assert-equal 1 (length errs))
      (assert-equal :maxima_error (getf (first errs) :kind))
      (assert-equal "thrown" (getf (first errs) :message))
      (assert-equal 1 (length ends))
      (assert-equal :error (getf (first ends) :status)))))

(deftest eval-hooks-cancellation-consumed-and-marked
  ;; cancellation-requested raised during eval is consumed by the
  ;; handler-case clause; the wrap emits :cancelled and sets
  ;; eval_end :status to :cancelled.  We bypass install/uninstall
  ;; and call the closure directly with an orig that signals.
  (with-installed-eval-hooks (envs)
    (kernel-events:uninstall-eval-hooks)
    (let ((wrap (kernel-events::make-toplevel-eval-wrap
                  (lambda (x)
                    (declare (ignore x))
                    (error 'kernel-events:cancellation-requested
                           :view-id "v_test")))))
      (funcall wrap 1))
    (let ((errs (envs-of-type envs :error))
          (ends (envs-of-type envs :eval_end)))
      (assert-equal 1 (length errs))
      (assert-equal :cancelled (getf (first errs) :kind))
      (assert-equal 1 (length ends))
      (assert-equal :cancelled (getf (first ends) :status)))))

(deftest eval-hooks-lisp-error-emits-lisp-error-envelope
  ;; A non-Maxima Lisp error escapes through the eval; the wrap
  ;; observes it via handler-bind and emits :lisp_error.  The
  ;; condition continues to propagate; the test's handler-case
  ;; catches it.
  (with-installed-eval-hooks (envs)
    (kernel-events:uninstall-eval-hooks)
    (let ((wrap (kernel-events::make-toplevel-eval-wrap
                  (lambda (x)
                    (declare (ignore x))
                    (error "synthesized lisp error")))))
      (handler-case (funcall wrap 1) (error () nil)))
    (let ((errs (envs-of-type envs :error))
          (ends (envs-of-type envs :eval_end)))
      (assert-equal 1 (length errs))
      (assert-equal :lisp_error (getf (first errs) :kind))
      (assert-true (stringp (getf (first errs) :condition_type)))
      (assert-equal 1 (length ends))
      (assert-equal :error (getf (first ends) :status)))))

;; ----------------------------------------------------------------
;; current-eval-id is bound during eval

(deftest eval-hooks-current-eval-id-bound-during-eval
  (with-installed-eval-hooks (envs)
    (let ((captured-id nil))
      ;; Use a sink that reads current-eval-id at envelope time.
      (kernel-events:register-sink
        (lambda (e)
          (when (and (null captured-id)
                     (eq (getf e :type) :eval_begin))
            (setf captured-id (kernel-events:current-eval-id)))))
      (maxima::toplevel-macsyma-eval 42)
      (assert-true (stringp captured-id)
                   "current-eval-id should be bound to a string during eval"))))

(deftest eval-hooks-current-eval-id-nil-after-eval
  (with-installed-eval-hooks (envs)
    (maxima::toplevel-macsyma-eval 42)
    (assert-equal nil (kernel-events:current-eval-id)
                  "current-eval-id should unwind to nil after eval")))

;; ----------------------------------------------------------------
;; Reentry: nested toplevel-macsyma-eval calls (batch-style)

(deftest eval-hooks-true-nested-eval-shadows-then-restores
  (with-installed-eval-hooks (envs)
    (let ((outer-id-during-outer nil)
          (outer-id-after-inner nil)
          (inner-id-during-inner nil)
          (triggered nil))
      (kernel-events:register-sink
        (lambda (e)
          (when (eq (getf e :type) :eval_begin)
            (cond
              ((not triggered)
               (setf triggered t)
               (setf outer-id-during-outer
                     (kernel-events:current-eval-id))
               ;; Nest: recursively invoke toplevel-macsyma-eval
               (maxima::toplevel-macsyma-eval 11)
               (setf outer-id-after-inner
                     (kernel-events:current-eval-id)))
              ((null inner-id-during-inner)
               (setf inner-id-during-inner
                     (kernel-events:current-eval-id)))))))
      (maxima::toplevel-macsyma-eval 22)
      (assert-true (stringp outer-id-during-outer))
      (assert-true (stringp inner-id-during-inner))
      (assert-false (string= outer-id-during-outer inner-id-during-inner)
                    "inner eval should get a distinct id")
      ;; After the nested eval unwinds, *current-eval-id* is restored
      ;; to the outer's binding.
      (assert-equal outer-id-during-outer outer-id-after-inner))))

;; ----------------------------------------------------------------
;; Integration with output-stream wrapper: install cleanly together

#+sbcl
(deftest eval-hooks-coexists-with-output-wrapping
  (with-installed-eval-hooks (envs)
    (unwind-protect
        (progn
          (kernel-events:install-output-wrapping)
          (maxima::toplevel-macsyma-eval 42))
      (kernel-events:uninstall-output-wrapping))
    ;; Verify the wrap installed cleanly and eval lifecycle fired.
    (assert-true (some (lambda (e) (eq (getf e :type) :eval_begin))
                       envs))
    (assert-true (some (lambda (e) (eq (getf e :type) :eval_end))
                       envs))))
