;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for the output stream wrapper.
;;;
;;; Important: the test runner writes test names to stdout between
;;; tests.  Every test here installs the wrapper in an unwind-protect
;;; that uninstalls before exiting, so the runner's reporting is
;;; always against the restored, un-wrapped streams.

(in-package :kernel-events-tests)

(defmacro with-wrapped-output ((collector-var) &body body)
  "Install the output wrapper around BODY, with a fresh collector
   sink registered.  COLLECTOR-VAR is bound to a fill-pointer'd
   vector that accumulates every envelope.  Always uninstalls."
  (let ((token-sym (gensym "TOKEN")))
    `(let ((,collector-var (make-array 0 :adjustable t :fill-pointer 0)))
       (kernel-events:clear-sinks)
       (let ((,token-sym
               (kernel-events:register-sink
                 (lambda (e) (vector-push-extend e ,collector-var)))))
         (unwind-protect
             (progn
               (kernel-events:install-output-wrapping)
               ,@body)
           (kernel-events:uninstall-output-wrapping)
           (kernel-events:unregister-sink ,token-sym))))))

;; ----------------------------------------------------------------
;; install / uninstall lifecycle

(deftest output-install-returns-t-on-sbcl
  #+sbcl
  (unwind-protect
      (assert-equal t (kernel-events:install-output-wrapping))
    (kernel-events:uninstall-output-wrapping))
  #-sbcl
  (assert-true t "skipped — non-SBCL"))

(deftest output-install-second-call-returns-nil
  #+sbcl
  (unwind-protect
      (progn
        (kernel-events:install-output-wrapping)
        (assert-equal nil (kernel-events:install-output-wrapping)
                      "double-install should be a no-op"))
    (kernel-events:uninstall-output-wrapping))
  #-sbcl
  (assert-true t "skipped — non-SBCL"))

(deftest output-uninstall-returns-t-when-installed
  #+sbcl
  (progn
    (kernel-events:install-output-wrapping)
    (assert-equal t (kernel-events:uninstall-output-wrapping)))
  #-sbcl
  (assert-true t "skipped — non-SBCL"))

(deftest output-uninstall-returns-nil-when-not-installed
  (assert-equal nil (kernel-events:uninstall-output-wrapping)))

(deftest output-installed-p-toggles
  #+sbcl
  (progn
    (assert-false (kernel-events:output-wrapping-installed-p))
    (unwind-protect
        (progn
          (kernel-events:install-output-wrapping)
          (assert-true (kernel-events:output-wrapping-installed-p)))
      (kernel-events:uninstall-output-wrapping))
    (assert-false (kernel-events:output-wrapping-installed-p)))
  #-sbcl
  (assert-true t "skipped — non-SBCL"))

;; ----------------------------------------------------------------
;; Capture: writes through *standard-output* produce envelopes

#+sbcl
(deftest output-write-newline-terminated-line-emits-envelope
  (with-wrapped-output (envs)
    (format *standard-output* "hello~%")
    (kernel-events:uninstall-output-wrapping)        ; flush
    (assert-equal 1 (length envs))
    (let ((e (aref envs 0)))
      (assert-equal :output (getf e :type))
      (assert-equal "stdout" (getf e :stream))
      (assert-equal "text/plain" (getf e :mime))
      (assert-equal "hello
" (getf e :text)))))

#+sbcl
(deftest output-eval-id-nil-without-eval-hooks
  ;; eval-hooks.lisp isn't wired up yet, so current-eval-id returns
  ;; NIL.  The output envelope should faithfully carry that.
  (with-wrapped-output (envs)
    (format *standard-output* "line~%")
    (kernel-events:uninstall-output-wrapping)
    (assert-equal nil (getf (aref envs 0) :eval_id))))

#+sbcl
(deftest output-multiple-lines-produce-multiple-envelopes
  (with-wrapped-output (envs)
    (format *standard-output* "one~%")
    (format *standard-output* "two~%")
    (format *standard-output* "three~%")
    (kernel-events:uninstall-output-wrapping)
    (assert-equal 3 (length envs))
    (assert-equal "one
"   (getf (aref envs 0) :text))
    (assert-equal "two
"   (getf (aref envs 1) :text))
    (assert-equal "three
" (getf (aref envs 2) :text))))

#+sbcl
(deftest output-partial-line-buffers-until-flush
  (with-wrapped-output (envs)
    ;; No newline — nothing should be emitted yet
    (format *standard-output* "no newline yet")
    (assert-equal 0 (length envs))
    ;; finish-output should flush the partial line
    (finish-output *standard-output*)
    (assert-equal 1 (length envs))
    (assert-equal "no newline yet" (getf (aref envs 0) :text))
    (kernel-events:uninstall-output-wrapping)))

#+sbcl
(deftest output-uninstall-flushes-partial-line
  (with-wrapped-output (envs)
    (format *standard-output* "trailing fragment")
    ;; uninstall happens in the with-wrapped-output unwind-protect
    )
  ;; Now check: the partial line should have been flushed.
  ;; Note: collector lifetime — we can't access envs after the
  ;; with-wrapped-output exits.  Test inline instead.
  (assert-true t "covered by output-uninstall-flushes-partial-line-inline"))

#+sbcl
(deftest output-uninstall-flushes-partial-line-inline
  ;; Same as above but we capture pre-uninstall.
  (let ((envs (make-array 0 :adjustable t :fill-pointer 0)))
    (kernel-events:clear-sinks)
    (kernel-events:register-sink
      (lambda (e) (vector-push-extend e envs)))
    (unwind-protect
        (progn
          (kernel-events:install-output-wrapping)
          (format *standard-output* "trailing fragment"))
      (kernel-events:uninstall-output-wrapping))
    (kernel-events:clear-sinks)
    (assert-equal 1 (length envs))
    (assert-equal "trailing fragment" (getf (aref envs 0) :text))))

;; ----------------------------------------------------------------
;; Pass-through: the underlying stream still receives output

#+sbcl
(deftest output-passes-through-to-original-stream
  ;; Wrap a string stream so we can inspect what got passed through.
  (let* ((captured (make-string-output-stream))
         (envs (make-array 0 :adjustable t :fill-pointer 0)))
    (kernel-events:clear-sinks)
    (kernel-events:register-sink
      (lambda (e) (vector-push-extend e envs)))
    ;; Manually wrap the string stream with our gray stream class.
    (let ((wrapper (make-instance 'kernel-events::events-output-stream
                                  :name "stdout"
                                  :underlying captured)))
      (write-string "passed through" wrapper)
      (terpri wrapper)
      ;; Underlying received it
      (assert-equal "passed through
" (get-output-stream-string captured))
      ;; Sink received an envelope
      (assert-equal 1 (length envs))
      (assert-equal "passed through
" (getf (aref envs 0) :text)))
    (kernel-events:clear-sinks)))

;; ----------------------------------------------------------------
;; *error-output* tagged "stderr"

#+sbcl
(deftest output-error-stream-tagged-stderr
  (with-wrapped-output (envs)
    (format *error-output* "warning!~%")
    (finish-output *error-output*)
    (let ((stderr-envelopes
            (loop for e across envs
                  when (string= (getf e :stream) "stderr")
                  collect e)))
      (assert-equal 1 (length stderr-envelopes))
      (assert-equal "warning!
" (getf (first stderr-envelopes) :text)))))

;; ----------------------------------------------------------------
;; Restoration: after uninstall, *standard-output* is the original

#+sbcl
(deftest output-uninstall-restores-original
  (let ((original *standard-output*))
    (kernel-events:install-output-wrapping)
    (assert-false (eq original *standard-output*)
                  "install should have replaced *standard-output*")
    (kernel-events:uninstall-output-wrapping)
    (assert-true (eq original *standard-output*)
                 "uninstall should restore the exact original object")))

#+sbcl
(deftest output-after-uninstall-no-envelopes
  (let ((envs (make-array 0 :adjustable t :fill-pointer 0)))
    (kernel-events:clear-sinks)
    (kernel-events:register-sink
      (lambda (e) (vector-push-extend e envs)))
    (unwind-protect
        (progn
          (kernel-events:install-output-wrapping)
          (kernel-events:uninstall-output-wrapping)
          (with-output-to-string (out)
            ;; Write to a discardable string stream so we don't
            ;; pollute the test runner's actual stdout.
            (let ((*standard-output* out))
              (format *standard-output* "should not be captured~%"))))
      (kernel-events:uninstall-output-wrapping)
      (kernel-events:clear-sinks))
    (assert-equal 0 (length envs)
                  "writes after uninstall should not emit envelopes")))

;; ----------------------------------------------------------------
;; multi-arg writes coalesce per line

#+sbcl
(deftest output-multi-arg-format-coalesces-into-one-line
  (with-wrapped-output (envs)
    (format *standard-output* "step ~D: ~D~%" 3 9)
    (kernel-events:uninstall-output-wrapping)
    (assert-equal 1 (length envs)
                  "multi-arg format with one ~% should produce one envelope")
    (assert-equal "step 3: 9
" (getf (aref envs 0) :text))))

#+sbcl
(deftest output-write-string-multiline-emits-per-line
  (with-wrapped-output (envs)
    ;; write-string with embedded newlines should split.
    (write-string "alpha
beta
gamma" *standard-output*)
    (finish-output *standard-output*)
    (kernel-events:uninstall-output-wrapping)
    (assert-equal 3 (length envs))
    (assert-equal "alpha
" (getf (aref envs 0) :text))
    (assert-equal "beta
"  (getf (aref envs 1) :text))
    (assert-equal "gamma"  (getf (aref envs 2) :text))))
