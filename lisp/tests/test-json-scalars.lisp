;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; JSON serialization tests for scalar values:
;;; null, booleans, integers, floats, rationals, strings, keywords,
;;; non-keyword symbols.
;;;
;;; String *escape* details live in test-json-strings.lisp;
;;; collection types in test-json-collections.lisp.

(in-package :kernel-events-tests)

(defun j (value)
  "Convenience: encode VALUE through envelope-to-json."
  (kernel-events:envelope-to-json value))

;; ----------------------------------------------------------------
;; null and booleans

(deftest json-nil-is-null
  (assert-equal "null" (j nil)))

(deftest json-explicit-null-keyword
  (assert-equal "null" (j :null)))

(deftest json-t-is-true
  (assert-equal "true" (j t)))

(deftest json-explicit-false-keyword
  (assert-equal "false" (j :false)))

;; ----------------------------------------------------------------
;; Integers

(deftest json-integer-zero
  (assert-equal "0" (j 0)))

(deftest json-integer-positive
  (assert-equal "42" (j 42)))

(deftest json-integer-negative
  (assert-equal "-7" (j -7)))

(deftest json-integer-large
  ;; Far beyond fixnum on any modern Lisp.
  (assert-equal "12345678901234567890" (j 12345678901234567890)))

(deftest json-integer-negative-large
  (assert-equal "-12345678901234567890" (j -12345678901234567890)))

;; ----------------------------------------------------------------
;; Floats

(deftest json-float-simple
  (let ((out (j 1.5d0)))
    (assert-true (search "1.5" out) "float should contain 1.5")
    (assert-false (search "d0" out)
                  "should not contain Lisp's d0 exponent marker")
    (assert-false (search "e0" out)
                  "should not contain redundant e0 marker")))

(deftest json-float-zero
  (let ((out (j 0.0d0)))
    (assert-true (or (string= out "0.0") (string= out "0"))
                 (format nil "0.0d0 should encode as 0.0 or 0; got ~s" out))))

(deftest json-float-negative
  (let ((out (j -2.5d0)))
    (assert-true (search "-2.5" out))))

(deftest json-float-fractional
  (let ((out (j 3.14159d0)))
    ;; Allow for slight imprecision but the integer + first few digits
    ;; should be present.
    (assert-true (search "3.14" out))))

(deftest json-float-rational
  ;; Rationals get coerced to double-float before encoding.
  (let ((out (j 1/4)))
    (assert-true (search "0.25" out))))

;; ----------------------------------------------------------------
;; Floats: non-finite values become null

(deftest json-nan-is-null
  #+sbcl
  (let ((nan (sb-kernel:make-single-float #x7FC00000)))
    (assert-equal "null" (j nan)))
  #-sbcl
  (assert-true t "skipped on non-SBCL — no portable NaN literal"))

(deftest json-positive-infinity-is-null
  #+sbcl
  (let ((inf sb-ext:double-float-positive-infinity))
    (assert-equal "null" (j inf)))
  #-sbcl
  (assert-true t "skipped on non-SBCL"))

(deftest json-negative-infinity-is-null
  #+sbcl
  (let ((-inf sb-ext:double-float-negative-infinity))
    (assert-equal "null" (j -inf)))
  #-sbcl
  (assert-true t "skipped on non-SBCL"))

;; ----------------------------------------------------------------
;; Strings (basic — no escapes; see test-json-strings.lisp for those)

(deftest json-string-empty
  (assert-equal "\"\"" (j "")))

(deftest json-string-simple-word
  (assert-equal "\"hello\"" (j "hello")))

(deftest json-string-with-spaces
  (assert-equal "\"hello world\"" (j "hello world")))

(deftest json-string-digits
  (assert-equal "\"42\"" (j "42")
                "digits-as-string should keep their quotes — they're a string, not a number"))

;; ----------------------------------------------------------------
;; Keywords

(deftest json-keyword-renders-as-string
  (assert-equal "\"stream_begin\"" (j :stream_begin)))

(deftest json-keyword-hyphen-becomes-underscore
  (assert-equal "\"view_id\"" (j :view-id)))

(deftest json-keyword-uppercase-lowercased
  ;; CL upcases keyword names by default; the encoder lowercases.
  (assert-equal "\"stream_begin\"" (j :STREAM_BEGIN)))

(deftest json-keyword-mixed-case-lowercased
  (assert-equal "\"mixedcase\"" (j :MixedCase)))

(deftest json-keyword-multiple-hyphens
  (assert-equal "\"a_b_c_d\"" (j :a-b-c-d)))

;; ----------------------------------------------------------------
;; Non-keyword symbols (rendered as lowercased strings)

(deftest json-symbol-renders-as-string
  (assert-equal "\"foo\"" (j 'foo)))

(deftest json-symbol-uppercase-lowercased
  (assert-equal "\"foo\"" (j 'FOO)))
