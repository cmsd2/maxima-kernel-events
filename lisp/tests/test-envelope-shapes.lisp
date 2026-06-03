;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; End-to-end envelope shape tests.
;;;
;;; For each envelope type defined in doc/design/kernel-events.md and
;;; doc/design/streaming.md we round-trip a representative example
;;; through make-envelope + envelope-to-json and check the resulting
;;; JSON.

(in-package :kernel-events-tests)

(defun emit-and-json (type &rest body)
  (kernel-events:envelope-to-json
    (apply #'kernel-events:make-envelope type body)))

;; ----------------------------------------------------------------
;; make-envelope basics

(deftest make-envelope-slots-type-first
  (let ((env (kernel-events:make-envelope
               :stream_begin :view_id "v_1" :kind :ode_trajectory)))
    (assert-equal :stream_begin (getf env :type))
    (assert-equal "v_1" (getf env :view_id))
    (assert-equal :ode_trajectory (getf env :kind))))

(deftest make-envelope-empty-body
  (let ((env (kernel-events:make-envelope :ready)))
    (assert-equal '(:type :ready) env)))

(deftest make-envelope-arbitrary-keys
  (let ((env (kernel-events:make-envelope :custom :foo 1 :bar "two")))
    (assert-equal 1 (getf env :foo))
    (assert-equal "two" (getf env :bar))))

;; ----------------------------------------------------------------
;; Session lifecycle: capabilities, ready

(deftest envelope-capabilities
  (let* ((env (kernel-events:make-envelope
                :capabilities
                :kernel_version "5.47.0"
                :lisp "SBCL 2.6.3"
                :supports #(:streaming :mime_bundles :debug_events)))
         (out (kernel-events:envelope-to-json env)))
    (assert-true (search "\"type\":\"capabilities\"" out))
    (assert-true (search "\"kernel_version\":\"5.47.0\"" out))
    (assert-true (search "\"lisp\":\"SBCL 2.6.3\"" out))
    (assert-true (search "\"supports\":[\"streaming\",\"mime_bundles\",\"debug_events\"]" out))))

(deftest envelope-ready
  (assert-equal "{\"type\":\"ready\"}"
                (emit-and-json :ready)))

;; ----------------------------------------------------------------
;; Evaluation lifecycle: eval_begin, eval_result, eval_end

(deftest envelope-eval-begin
  (let ((out (emit-and-json :eval_begin
                            :eval_id "e_42"
                            :started_at "2026-06-03T15:21:08.412Z")))
    (assert-true (search "\"type\":\"eval_begin\"" out))
    (assert-true (search "\"eval_id\":\"e_42\"" out))
    (assert-true (search "\"started_at\":\"2026-06-03T15:21:08.412Z\"" out))))

(deftest envelope-eval-result-with-bundle
  (let* ((bundle (make-hash-table :test 'equal)))
    (setf (gethash "text/plain" bundle) "1/2")
    (setf (gethash "application/x-maxima-latex" bundle) "\\frac{1}{2}")
    (let ((out (emit-and-json :eval_result
                              :eval_id "e_42"
                              :output_label "%o7"
                              :suppressed :false
                              :mime_bundle bundle)))
      (assert-true (search "\"type\":\"eval_result\"" out))
      (assert-true (search "\"output_label\":\"%o7\"" out))
      (assert-true (search "\"suppressed\":false" out))
      (assert-true (search "\"text/plain\":\"1/2\"" out))
      (assert-true (search "\"application/x-maxima-latex\":\"\\\\frac{1}{2}\"" out)))))

(deftest envelope-eval-end-ok
  (let ((out (emit-and-json :eval_end
                            :eval_id "e_42"
                            :status :ok
                            :duration_ms 12)))
    (assert-true (search "\"status\":\"ok\"" out))
    (assert-true (search "\"duration_ms\":12" out))))

(deftest envelope-eval-end-cancelled
  (let ((out (emit-and-json :eval_end
                            :eval_id "e_42"
                            :status :cancelled
                            :duration_ms 1500)))
    (assert-true (search "\"status\":\"cancelled\"" out))))

;; ----------------------------------------------------------------
;; Within-evaluation: output, display, error, debug, stdin, vars

(deftest envelope-output-stdout
  (let ((out (emit-and-json :output
                            :eval_id "e_42"
                            :seq 3
                            :stream "stdout"
                            :mime "text/plain"
                            :text "step 3: 9
")))
    (assert-true (search "\"type\":\"output\"" out))
    (assert-true (search "\"stream\":\"stdout\"" out))
    (assert-true (search "\"text\":\"step 3: 9\\n\"" out))))

(deftest envelope-display-with-mime-bundle
  (let ((bundle (make-hash-table :test 'equal)))
    (setf (gethash "application/x-maxima-plotly" bundle)
          "{\"data\":[]}")
    (setf (gethash "text/plain" bundle) "<plot>")
    (let ((out (emit-and-json :display
                              :eval_id "e_42"
                              :seq 5
                              :mime_bundle bundle)))
      (assert-true (search "\"type\":\"display\"" out))
      (assert-true (search "\"application/x-maxima-plotly\":" out))
      (assert-true (search "\"text/plain\":\"<plot>\"" out)))))

(deftest envelope-error-structured
  (let ((out (emit-and-json :error
                            :eval_id "e_42"
                            :kind :maxima_error
                            :message "Division by 0"
                            :location '(:line 3 :column 12)
                            :form "1/0"
                            :recoverable t)))
    (assert-true (search "\"kind\":\"maxima_error\"" out))
    (assert-true (search "\"message\":\"Division by 0\"" out))
    (assert-true (search "\"location\":{\"line\":3,\"column\":12}" out))
    (assert-true (search "\"recoverable\":true" out))))

(deftest envelope-debug-enter-maxima
  (let ((out (emit-and-json :debug_enter
                            :eval_id "e_42"
                            :level :maxima
                            :depth 1
                            :frames #((:function "myfun"
                                       :args #("x=3")
                                       :source_line 4)))))
    (assert-true (search "\"type\":\"debug_enter\"" out))
    (assert-true (search "\"level\":\"maxima\"" out))
    (assert-true (search "\"depth\":1" out))
    (assert-true (search "\"function\":\"myfun\"" out))
    (assert-true (search "\"args\":[\"x=3\"]" out))))

(deftest envelope-debug-leave
  (assert-equal "{\"type\":\"debug_leave\",\"eval_id\":\"e_42\",\"depth\":1}"
                (emit-and-json :debug_leave
                               :eval_id "e_42"
                               :depth 1)))

(deftest envelope-stdin-request
  (let ((out (emit-and-json :stdin_request
                            :eval_id "e_42"
                            :request_id "r_3"
                            :prompt "Enter x: "
                            :kind :string)))
    (assert-true (search "\"request_id\":\"r_3\"" out))
    (assert-true (search "\"prompt\":\"Enter x: \"" out))
    (assert-true (search "\"kind\":\"string\"" out))))

(deftest envelope-vars
  (let ((out (emit-and-json :vars
                            :eval_id "e_42"
                            :vars #("x" "y" "z")
                            :values_text #("3" "4" "5"))))
    (assert-true (search "\"vars\":[\"x\",\"y\",\"z\"]" out))
    (assert-true (search "\"values_text\":[\"3\",\"4\",\"5\"]" out))))

;; ----------------------------------------------------------------
;; Streaming envelopes: stream_begin, frame, progress, stream_end,
;; stream_error, log

(deftest envelope-stream-begin
  (let ((out (emit-and-json :stream_begin
                            :view_id "v_42"
                            :kind :ode_trajectory
                            :started_at "2026-06-03T15:21:08.412Z"
                            :expected_frames nil
                            :metadata '(:vars #("x" "v")
                                        :t0 0.0d0
                                        :tf 10.0d0))))
    (assert-true (search "\"type\":\"stream_begin\"" out))
    (assert-true (search "\"view_id\":\"v_42\"" out))
    (assert-true (search "\"kind\":\"ode_trajectory\"" out))
    (assert-true (search "\"expected_frames\":null" out))
    (assert-true (search "\"vars\":[\"x\",\"v\"]" out))
    (assert-true (search "\"t0\":0.0" out))
    (assert-true (search "\"tf\":10.0" out))))

(deftest envelope-frame-shape
  (let ((out (emit-and-json :frame
                            :view_id "v_42"
                            :seq 1
                            :payload '(:t 0.05d0
                                       :y #(1.0d0 0.02d0)))))
    (assert-true (search "\"type\":\"frame\"" out))
    (assert-true (search "\"view_id\":\"v_42\"" out))
    (assert-true (search "\"seq\":1" out))
    (assert-true (search "\"payload\":{" out))
    (assert-true (search "\"t\":0.05" out))
    (assert-true (search "\"y\":[1.0,0.02]" out))))

(deftest envelope-progress-numeric-fraction
  (let ((out (emit-and-json :progress
                            :view_id "v_42"
                            :fraction 0.25d0
                            :message "integrating t=2.5/10.0")))
    (assert-true (search "\"fraction\":0.25" out))
    (assert-true (search "\"message\":\"integrating t=2.5/10.0\"" out))))

(deftest envelope-progress-null-fraction
  (let ((out (emit-and-json :progress
                            :view_id "v_42"
                            :fraction nil
                            :message "indeterminate")))
    (assert-true (search "\"fraction\":null" out))))

(deftest envelope-stream-end-complete
  (let ((out (emit-and-json :stream_end
                            :view_id "v_42"
                            :final_seq 200
                            :duration_ms 340
                            :status :complete)))
    (assert-true (search "\"status\":\"complete\"" out))
    (assert-true (search "\"final_seq\":200" out))
    (assert-true (search "\"duration_ms\":340" out))))

(deftest envelope-stream-error
  (let ((out (emit-and-json :stream_error
                            :view_id "v_42"
                            :message "RHS evaluation failed at t=3.7: division by zero"
                            :recoverable :false)))
    (assert-true (search "\"type\":\"stream_error\"" out))
    (assert-true (search "\"recoverable\":false" out))
    (assert-true (search "RHS evaluation failed" out))))

(deftest envelope-log
  (let ((out (emit-and-json :log
                            :view_id "v_42"
                            :level :info
                            :message "detected event at t=2.3")))
    (assert-true (search "\"level\":\"info\"" out))
    (assert-true (search "\"message\":\"detected event at t=2.3\"" out))))
