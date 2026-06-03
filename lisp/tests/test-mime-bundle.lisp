;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for the mime-bundle layer: builder, accessors, capability
;;; negotiation, and the Maxima-backed bundle generator
;;; (build-mime-bundle).  These tests run inside a Maxima session via
;;; mxpm test, so the maxima:: symbols mgrind / $tex1 are available.

(in-package :kernel-events-tests)

(defmacro with-default-render-mimes (&body body)
  "Save and restore *render-mimes* around BODY so tests don't bleed
   into each other."
  (let ((saved (gensym)))
    `(let ((,saved (kernel-events:render-mimes)))
       (unwind-protect (progn ,@body)
         (kernel-events:set-render-mimes ,saved)))))

;; ----------------------------------------------------------------
;; make-mime-bundle / mime-bundle-get / mime-bundle-mimes /
;; mime-bundle-empty-p

(deftest mime-bundle-empty-make-is-empty
  (let ((b (kernel-events:make-mime-bundle)))
    (assert-true (kernel-events:mime-bundle-empty-p b))
    (assert-equal 0 (length (kernel-events:mime-bundle-mimes b)))))

(deftest mime-bundle-make-with-pairs
  (let ((b (kernel-events:make-mime-bundle
             "text/plain" "1/2"
             "application/x-maxima-latex" "\\frac{1}{2}")))
    (assert-false (kernel-events:mime-bundle-empty-p b))
    (assert-equal "1/2"
                  (kernel-events:mime-bundle-get b "text/plain"))
    (assert-equal "\\frac{1}{2}"
                  (kernel-events:mime-bundle-get b
                    "application/x-maxima-latex"))))

(deftest mime-bundle-get-missing-returns-nil
  (let ((b (kernel-events:make-mime-bundle "text/plain" "x")))
    (assert-equal nil
                  (kernel-events:mime-bundle-get b "image/png"))))

(deftest mime-bundle-mimes-lists-all-keys
  (let* ((b (kernel-events:make-mime-bundle "a" 1 "b" 2 "c" 3))
         (mimes (kernel-events:mime-bundle-mimes b)))
    (assert-equal 3 (length mimes))
    (assert-true (member "a" mimes :test #'string=))
    (assert-true (member "b" mimes :test #'string=))
    (assert-true (member "c" mimes :test #'string=))))

(deftest mime-bundle-non-string-mime-errors
  (assert-signals 'error
                  (lambda () (kernel-events:make-mime-bundle
                              :keyword-not-string "x"))))

;; ----------------------------------------------------------------
;; mime-bundle-add

(deftest mime-bundle-add-inserts-new-mime
  (let ((b (kernel-events:make-mime-bundle "text/plain" "x")))
    (kernel-events:mime-bundle-add b "image/png" "<bytes>")
    (assert-equal "<bytes>"
                  (kernel-events:mime-bundle-get b "image/png"))
    (assert-equal "x"
                  (kernel-events:mime-bundle-get b "text/plain"))))

(deftest mime-bundle-add-overwrites-existing
  (let ((b (kernel-events:make-mime-bundle "text/plain" "old")))
    (kernel-events:mime-bundle-add b "text/plain" "new")
    (assert-equal "new"
                  (kernel-events:mime-bundle-get b "text/plain"))))

(deftest mime-bundle-add-returns-bundle-for-chaining
  (let* ((b (kernel-events:make-mime-bundle))
         (r (kernel-events:mime-bundle-add b "text/plain" "x")))
    (assert-true (eq r b) "mime-bundle-add should return the bundle itself")))

;; ----------------------------------------------------------------
;; *render-mimes* and capability negotiation

(deftest render-mimes-default-includes-text-plain
  (with-default-render-mimes
    (assert-true (member "text/plain"
                         (kernel-events:render-mimes)
                         :test #'string=))))

(deftest render-mimes-default-includes-latex
  (with-default-render-mimes
    (assert-true (member "application/x-maxima-latex"
                         (kernel-events:render-mimes)
                         :test #'string=))))

(deftest render-mimes-returns-fresh-copy
  (with-default-render-mimes
    (let ((listing (kernel-events:render-mimes)))
      (declare (ignorable listing))
      (setf listing (cons "spurious" listing))
      ;; External mutation must not affect the internal list.
      (assert-false (member "spurious" (kernel-events:render-mimes)
                            :test #'string=))
      ;; Touch listing so SBCL doesn't dead-code-eliminate it.
      (assert-equal "spurious" (first listing)))))

(deftest set-render-mimes-replaces
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain"))
    (assert-equal '("text/plain") (kernel-events:render-mimes))))

(deftest set-render-mimes-checks-types
  (with-default-render-mimes
    (assert-signals 'error
                    (lambda ()
                      (kernel-events:set-render-mimes '(:keyword))))))

(deftest add-render-mime-appends
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain"))
    (kernel-events:add-render-mime "image/png")
    (assert-true (member "image/png" (kernel-events:render-mimes)
                         :test #'string=))))

(deftest add-render-mime-is-idempotent
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain"))
    (kernel-events:add-render-mime "text/plain")
    (assert-equal 1
                  (count "text/plain" (kernel-events:render-mimes)
                         :test #'string=))))

(deftest should-render-mime-p-true-when-present
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain" "image/png"))
    (assert-true (kernel-events:should-render-mime-p "image/png"))))

(deftest should-render-mime-p-false-when-absent
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain"))
    (assert-false (kernel-events:should-render-mime-p
                    "application/x-maxima-latex"))))

;; ----------------------------------------------------------------
;; build-mime-bundle — integration with Maxima

(deftest build-bundle-integer-includes-text-plain
  (with-default-render-mimes
    (let* ((b (kernel-events:build-mime-bundle 42))
           (text (kernel-events:mime-bundle-get b "text/plain")))
      (assert-equal "42" text))))

(deftest build-bundle-integer-includes-latex-when-requested
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain" "application/x-maxima-latex"))
    (let* ((b (kernel-events:build-mime-bundle 42))
           (latex (kernel-events:mime-bundle-get b
                    "application/x-maxima-latex")))
      (assert-true (and (stringp latex) (search "42" latex))
                   "LaTeX representation of 42 should contain the digits"))))

(deftest build-bundle-skips-latex-when-not-in-render-mimes
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain"))
    (let ((b (kernel-events:build-mime-bundle 42)))
      (assert-equal nil
                    (kernel-events:mime-bundle-get b
                      "application/x-maxima-latex")))))

(deftest build-bundle-text-plain-is-always-present
  (with-default-render-mimes
    ;; Even if the host declares only LaTeX rendering, we still
    ;; populate text/plain — it's a fallback every consumer can use.
    (kernel-events:set-render-mimes '("application/x-maxima-latex"))
    (let ((b (kernel-events:build-mime-bundle 42)))
      (assert-true (stringp
                     (kernel-events:mime-bundle-get b "text/plain"))
                   "text/plain should always be populated"))))

(deftest build-bundle-rational-text
  (with-default-render-mimes
    (let* ((maxima-rat
             ;; A Maxima rational: 1/2 in Maxima internal form.
             ;; ((rat simp) 1 2) is the canonical shape.
             (list (list 'maxima::rat 'maxima::simp) 1 2))
           (b (kernel-events:build-mime-bundle maxima-rat))
           (text (kernel-events:mime-bundle-get b "text/plain")))
      (assert-equal "1/2" text))))

(deftest build-bundle-rational-latex-is-fraction-form
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain"
                                      "application/x-maxima-latex"))
    (let* ((maxima-rat (list (list 'maxima::rat 'maxima::simp) 1 2))
           (b (kernel-events:build-mime-bundle maxima-rat))
           (latex (kernel-events:mime-bundle-get b
                    "application/x-maxima-latex")))
      (assert-true (stringp latex)
                   "LaTeX representation should be a string")
      ;; Maxima's tex1 emits {{1}\over{2}} for 1/2 (TeX, not modern
      ;; LaTeX \frac convention).  Assert both numerator and
      ;; denominator and the fraction-bar control sequence.
      (assert-true (search "\\over" latex)
                   "LaTeX form of 1/2 should use \\over")
      (assert-true (search "1" latex)
                   "LaTeX form of 1/2 should contain the numerator")
      (assert-true (search "2" latex)
                   "LaTeX form of 1/2 should contain the denominator"))))

;; ----------------------------------------------------------------
;; Bundle serializes through envelope-to-json

(deftest build-bundle-json-shape
  (with-default-render-mimes
    (kernel-events:set-render-mimes '("text/plain"
                                      "application/x-maxima-latex"))
    (let* ((b (kernel-events:build-mime-bundle 42))
           (json (kernel-events:envelope-to-json b)))
      ;; Hash-table ordering varies; just assert key presence.
      (assert-true (search "\"text/plain\":\"42\"" json))
      (assert-true (search "\"application/x-maxima-latex\":" json)))))
