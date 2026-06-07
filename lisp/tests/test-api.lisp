;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for the Maxima-callable API.
;;;
;;; Runs inside Maxima (mxpm test) so the $-prefixed functions are
;;; defined and Maxima expression shapes (mlist, mequal, rat) are
;;; available.

(in-package :kernel-events-tests)

(defmacro with-clean-api-state (&body body)
  `(unwind-protect
       (progn
         (kernel-events:clear-sinks)
         (kernel-events:reset-view-counters)
         ,@body)
     (kernel-events:clear-sinks)
     (kernel-events:reset-view-counters)))

(defun collect ()
  (let ((v (make-array 0 :adjustable t :fill-pointer 0)))
    (values v
            (kernel-events:register-sink
              (lambda (e) (vector-push-extend e v))))))

;; ----------------------------------------------------------------
;; Helper: maxima-symbol-to-keyword

(deftest api-symbol-to-keyword-strips-dollar
  (assert-equal :ode_trajectory
                (kernel-events::maxima-symbol-to-keyword
                  'maxima::$ode_trajectory)))

(deftest api-symbol-to-keyword-without-dollar
  (assert-equal :info
                (kernel-events::maxima-symbol-to-keyword
                  (intern "INFO" :maxima))))

;; ----------------------------------------------------------------
;; Helper: maxima-value-to-json-value

(defun mklist (&rest items)
  "Build a Maxima list ((mlist) items…)."
  (list* '(maxima::mlist) items))

(defun mkequal (k v)
  "Build a Maxima equation ((mequal) k v)."
  (list '(maxima::mequal) k v))

(defun mkrat (n d)
  "Build a Maxima rational ((rat simp) n d)."
  (list '(maxima::rat maxima::simp) n d))

(deftest api-convert-number-passthrough
  (assert-equal 42 (kernel-events::maxima-value-to-json-value 42))
  (assert-equal 0.5d0 (kernel-events::maxima-value-to-json-value 0.5d0)))

(deftest api-convert-string-passthrough
  (assert-equal "hello" (kernel-events::maxima-value-to-json-value "hello")))

(deftest api-convert-dollar-symbol-to-keyword
  (assert-equal :foo
                (kernel-events::maxima-value-to-json-value 'maxima::$foo)))

(deftest api-convert-nil-and-t
  (assert-equal nil (kernel-events::maxima-value-to-json-value nil))
  (assert-equal t   (kernel-events::maxima-value-to-json-value t)))

(deftest api-convert-rat-to-float
  (assert-equal 0.25d0
                (kernel-events::maxima-value-to-json-value (mkrat 1 4))))

(deftest api-convert-mlist-of-values-to-vector
  (let ((v (kernel-events::maxima-value-to-json-value
             (mklist 1 2 3))))
    (assert-true (vectorp v))
    (assert-equal 3 (length v))
    (assert-equal 1 (aref v 0))
    (assert-equal 2 (aref v 1))
    (assert-equal 3 (aref v 2))))

(deftest api-convert-mlist-of-equations-to-plist
  (let ((p (kernel-events::maxima-value-to-json-value
             (mklist (mkequal 'maxima::$t 0.05d0)
                     (mkequal 'maxima::$y (mklist 1.0d0 0.02d0))))))
    (assert-equal 0.05d0 (getf p :t))
    (let ((y (getf p :y)))
      (assert-true (vectorp y))
      (assert-equal 1.0d0 (aref y 0))
      (assert-equal 0.02d0 (aref y 1)))))

(deftest api-convert-nested-mlist-recurses
  (let ((v (kernel-events::maxima-value-to-json-value
             (mklist (mklist 1 2) (mklist 3 4)))))
    (assert-true (vectorp v))
    (assert-equal 2 (length v))
    (assert-true (vectorp (aref v 0)))
    (assert-equal 2 (aref (aref v 0) 1))))

(deftest api-convert-top-level-mequal-to-pair
  (let ((v (kernel-events::maxima-value-to-json-value
             (mkequal 'maxima::$t 0.05d0))))
    (assert-true (vectorp v))
    (assert-equal :t (aref v 0))
    (assert-equal 0.05d0 (aref v 1))))

;; ----------------------------------------------------------------
;; $kernel_events_available

(deftest api-kernel-events-available-returns-t
  (assert-equal t (maxima::$kernel_events_available)))

;; ----------------------------------------------------------------
;; $alloc_view

(deftest api-alloc-view-returns-string
  (with-clean-api-state
    (collect)
    (let ((v (maxima::$alloc_view 'maxima::$ode_trajectory)))
      (assert-true (stringp v))
      (assert-equal "v_1" v))))

(deftest api-alloc-view-emits-stream-begin
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$alloc_view 'maxima::$ode_trajectory)
      (assert-equal 1 (length envs))
      (assert-equal :stream_begin (getf (aref envs 0) :type))
      (assert-equal "v_1" (getf (aref envs 0) :view_id))
      (assert-equal :ode_trajectory (getf (aref envs 0) :kind)))))

(deftest api-alloc-view-counter-increments
  (with-clean-api-state
    (collect)
    (assert-equal "v_1" (maxima::$alloc_view 'maxima::$ode_trajectory))
    (assert-equal "v_2" (maxima::$alloc_view 'maxima::$ode_trajectory))))

;; ----------------------------------------------------------------
;; $show

(deftest api-show-emits-display-with-bundle
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$show 42)
      (assert-equal 1 (length envs))
      (let ((e (aref envs 0)))
        (assert-equal :display (getf e :type))
        (let ((bundle (getf e :mime_bundle)))
          (assert-true (hash-table-p bundle))
          (assert-equal "42" (gethash "text/plain" bundle)))))))

(deftest api-show-returns-done
  (with-clean-api-state
    (collect)
    (assert-equal 'maxima::$done (maxima::$show 42))))

;; ----------------------------------------------------------------
;; $emit_display

(deftest api-emit-display-with-explicit-bundle
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_display
        (mklist (mklist "text/plain" "1/2")
                (mklist "application/x-maxima-latex" "\\over")))
      (assert-equal 1 (length envs))
      (let* ((e (aref envs 0))
             (bundle (getf e :mime_bundle)))
        (assert-equal :display (getf e :type))
        (assert-true (hash-table-p bundle))
        (assert-equal "1/2" (gethash "text/plain" bundle))
        (assert-equal "\\over"
                      (gethash "application/x-maxima-latex" bundle))))))

(deftest api-emit-display-non-list-errors
  (with-clean-api-state
    (collect)
    (assert-signals 'error
                    (lambda () (maxima::$emit_display "not a list")))))

(deftest api-emit-display-pair-not-list-errors
  (with-clean-api-state
    (collect)
    (assert-signals 'error
                    (lambda ()
                      (maxima::$emit_display (mklist "wrong"))))))

;; ----------------------------------------------------------------
;; $emit_frame

(deftest api-emit-frame-with-positional-payload
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_frame "v_1" (mklist 0.05d0 1.0d0))
      (let* ((e (aref envs 0))
             (payload (getf e :payload)))
        (assert-equal :frame (getf e :type))
        (assert-equal 1 (getf e :seq))
        (assert-true (vectorp payload))
        (assert-equal 0.05d0 (aref payload 0))
        (assert-equal 1.0d0 (aref payload 1))))))

(deftest api-emit-frame-with-equation-payload-builds-plist
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_frame
        "v_1"
        (mklist (mkequal 'maxima::$t 0.05d0)
                (mkequal 'maxima::$y (mklist 1.0d0 0.02d0))))
      (let* ((e (aref envs 0))
             (payload (getf e :payload)))
        (assert-equal 0.05d0 (getf payload :t))
        (assert-true (vectorp (getf payload :y)))))))

(deftest api-emit-frame-returns-seq
  (with-clean-api-state
    (collect)
    (assert-equal 1 (maxima::$emit_frame "v_1" (mklist 0.0d0)))
    (assert-equal 2 (maxima::$emit_frame "v_1" (mklist 0.1d0)))))

(deftest api-emit-frame-non-string-view-errors
  (with-clean-api-state
    (collect)
    (assert-signals 'error
                    (lambda ()
                      (maxima::$emit_frame :keyword-not-string
                                           (mklist 1))))))

;; ----------------------------------------------------------------
;; $emit_progress

(deftest api-emit-progress-with-fraction
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_progress "v_1" 0.25d0 "halfway")
      (let ((e (aref envs 0)))
        (assert-equal :progress (getf e :type))
        (assert-equal 0.25d0 (getf e :fraction))
        (assert-equal "halfway" (getf e :message))))))

(deftest api-emit-progress-without-message
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_progress "v_1" 0.5d0)
      (assert-equal nil (getf (aref envs 0) :message)))))

;; ----------------------------------------------------------------
;; $emit_log

(deftest api-emit-log-converts-level-symbol-to-keyword
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_log "v_1" 'maxima::$info "hello")
      (assert-equal :info (getf (aref envs 0) :level))
      (assert-equal "hello" (getf (aref envs 0) :message)))))

(deftest api-emit-log-warn-and-error
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_log "v_1" 'maxima::$warn "be careful")
      (maxima::$emit_log "v_1" 'maxima::$error "bad")
      (assert-equal :warn  (getf (aref envs 0) :level))
      (assert-equal :error (getf (aref envs 1) :level)))))

;; ----------------------------------------------------------------
;; $emit_done

(deftest api-emit-done-default-status
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      ;; First emit a frame so the seq counter has something
      (maxima::$emit_frame "v_1" (mklist 1))
      (maxima::$emit_done "v_1")
      (let ((end (aref envs 1)))
        (assert-equal :stream_end (getf end :type))
        (assert-equal :complete (getf end :status))
        (assert-equal 1 (getf end :final_seq))))))

(deftest api-emit-done-with-explicit-status
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_done "v_1" 'maxima::$cancelled)
      (let ((end (aref envs 0)))
        (assert-equal :cancelled (getf end :status))))))

(deftest api-emit-done-returns-final-seq
  (with-clean-api-state
    (collect)
    (maxima::$emit_frame "v_1" (mklist 1))
    (maxima::$emit_frame "v_1" (mklist 2))
    (assert-equal 2 (maxima::$emit_done "v_1"))))

;; ----------------------------------------------------------------
;; Integration: full ODE-style flow

(deftest api-integration-full-stream-flow
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (let ((v (maxima::$alloc_view 'maxima::$ode_trajectory)))
        (maxima::$emit_frame v (mklist (mkequal 'maxima::$t 0.0d0)
                                       (mkequal 'maxima::$y
                                                (mklist 1.0d0))))
        (maxima::$emit_frame v (mklist (mkequal 'maxima::$t 0.1d0)
                                       (mkequal 'maxima::$y
                                                (mklist 0.995d0))))
        (maxima::$emit_done v))
      (assert-equal 4 (length envs))
      (assert-equal :stream_begin (getf (aref envs 0) :type))
      (assert-equal :frame        (getf (aref envs 1) :type))
      (assert-equal :frame        (getf (aref envs 2) :type))
      (assert-equal :stream_end   (getf (aref envs 3) :type))
      (assert-equal 2             (getf (aref envs 3) :final_seq)))))

;; ----------------------------------------------------------------
;; Envelopes from the API serialize cleanly through envelope-to-json

(deftest api-integration-frame-envelope-jsonable
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_frame
        "v_1"
        (mklist (mkequal 'maxima::$t 0.05d0)
                (mkequal 'maxima::$y (mklist 1.0d0 0.02d0))))
      (let ((json (kernel-events:envelope-to-json (aref envs 0))))
        (assert-true (search "\"type\":\"frame\"" json))
        (assert-true (search "\"t\":0.05" json))
        (assert-true (search "\"y\":[1.0,0.02]" json))))))

;; ----------------------------------------------------------------
;; Session handshake: $emit_capabilities, $emit_ready, $start_session

(deftest api-emit-capabilities-no-args
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_capabilities)
      (assert-equal 1 (length envs))
      (assert-equal :capabilities (getf (aref envs 0) :type))
      ;; :packages and :supports are vectors so the JSON encoder
      ;; emits them as arrays (lists collide with plists).
      ;; assert-equal uses #'equal, which isn't element-wise on
      ;; vectors; coerce to list for the structural check.
      (assert-equal '() (coerce (getf (aref envs 0) :packages) 'list)))))

(deftest api-emit-capabilities-with-packages
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_capabilities (mklist "ax-plots" "sundials"))
      (assert-equal '("ax-plots" "sundials")
                    (coerce (getf (aref envs 0) :packages) 'list)))))

(deftest api-emit-capabilities-non-string-package-errors
  (with-clean-api-state
    (collect)
    (assert-signals 'error
                    (lambda ()
                      (maxima::$emit_capabilities (mklist 42))))))

(deftest api-emit-ready-shape
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_ready)
      (assert-equal 1 (length envs))
      (assert-equal :ready (getf (aref envs 0) :type)))))

(deftest api-start-session-emits-capabilities-then-ready
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$start_session)
      (assert-equal 2 (length envs))
      (assert-equal :capabilities (getf (aref envs 0) :type))
      (assert-equal :ready        (getf (aref envs 1) :type)))))

;; ----------------------------------------------------------------
;; $emit_error

(deftest api-emit-error-shape
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (maxima::$emit_error 'maxima::$maxima_error "div by 0")
      (let ((e (aref envs 0)))
        (assert-equal :error (getf e :type))
        (assert-equal :maxima_error (getf e :kind))
        (assert-equal "div by 0" (getf e :message))))))

(deftest api-emit-error-non-string-message-errors
  (with-clean-api-state
    (collect)
    (assert-signals 'error
                    (lambda ()
                      (maxima::$emit_error 'maxima::$lisp_error 42)))))

;; ----------------------------------------------------------------
;; $emit_vars

(deftest api-emit-vars-snapshots-current-values
  (with-clean-api-state
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (let ((maxima::$values (list (list 'maxima::mlist))))
        (maxima::$emit_vars)
        (let ((e (aref envs 0)))
          (assert-equal :vars (getf e :type))
          (assert-equal 0 (length (getf e :vars))))))))

;; ----------------------------------------------------------------
;; $emit_stdin_request

(deftest api-emit-stdin-request-shape
  (with-clean-api-state
    (kernel-events:reset-stdin-counter)
    (multiple-value-bind (envs _token) (collect)
      (declare (ignore _token))
      (let ((id (maxima::$emit_stdin_request "Enter: " 'maxima::$string)))
        (assert-equal "r_1" id)
        (let ((e (aref envs 0)))
          (assert-equal :stdin_request (getf e :type))
          (assert-equal "Enter: " (getf e :prompt))
          (assert-equal :string (getf e :kind)))))))

(deftest api-emit-stdin-request-non-string-prompt-errors
  (with-clean-api-state
    (collect)
    (assert-signals 'error
                    (lambda ()
                      (maxima::$emit_stdin_request 42 'maxima::$string)))))
