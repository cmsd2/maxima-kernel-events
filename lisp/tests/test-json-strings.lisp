;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; JSON string-escape tests.  Validates RFC 8259 string content
;;; escaping for write-json-string-body, json-escape-string, and the
;;; quoted-string path through envelope-to-json.

(in-package :kernel-events-tests)

;; ----------------------------------------------------------------
;; envelope-to-json: quoted string with each special character

(deftest json-string-escapes-quote
  (assert-equal "\"a\\\"b\"" (kernel-events:envelope-to-json "a\"b")))

(deftest json-string-escapes-backslash
  (assert-equal "\"a\\\\b\"" (kernel-events:envelope-to-json "a\\b")))

(deftest json-string-escapes-newline
  (assert-equal "\"a\\nb\""
                (kernel-events:envelope-to-json (concatenate 'string "a" (string #\Newline) "b"))))

(deftest json-string-escapes-tab
  (assert-equal "\"\\t\"" (kernel-events:envelope-to-json (string #\Tab))))

(deftest json-string-escapes-backspace
  (assert-equal "\"\\b\"" (kernel-events:envelope-to-json (string (code-char 8)))))

(deftest json-string-escapes-form-feed
  (assert-equal "\"\\f\"" (kernel-events:envelope-to-json (string (code-char 12)))))

(deftest json-string-escapes-carriage-return
  (assert-equal "\"\\r\"" (kernel-events:envelope-to-json (string (code-char 13)))))

(deftest json-string-escapes-low-control-as-uxxxx
  ;; U+0001 → 
  (assert-equal "\"\\u0001\""
                (kernel-events:envelope-to-json (string (code-char 1)))))

(deftest json-string-escapes-uxxxx-pads-with-zeros
  ;; U+0010 → , not \u10
  (assert-equal "\"\\u0010\""
                (kernel-events:envelope-to-json (string (code-char #x10)))))

(deftest json-string-escapes-del-as-uxxxx
  (assert-equal "\"\\u007f\""
                (kernel-events:envelope-to-json (string (code-char 127)))))

(deftest json-string-printable-ascii-unchanged
  ;; Everything from 0x20 to 0x7E except " and \ passes through verbatim.
  (let ((sample "abcXYZ 0123!@#$%^&*()-=+[]{}|;:,.<>?/`~"))
    (assert-equal (format nil "\"~a\"" sample)
                  (kernel-events:envelope-to-json sample))))

;; ----------------------------------------------------------------
;; Unicode passes through unchanged (UTF-8 is the on-wire encoding,
;; we emit the raw code points >= 32 except DEL).

(deftest json-string-unicode-bmp
  (let* ((s (string (code-char #x03C0))) ; π
         (out (kernel-events:envelope-to-json s)))
    (assert-equal (format nil "\"~a\"" s) out
                  "π (BMP) should pass through as a raw character")))

(deftest json-string-unicode-cjk
  (let* ((s (string (code-char #x4E2D))) ; 中
         (out (kernel-events:envelope-to-json s)))
    (assert-equal (format nil "\"~a\"" s) out)))

(deftest json-string-unicode-emoji
  ;; SBCL supports the supplementary plane; the encoder doesn't
  ;; surrogate-split anything (UTF-8 transport handles it).
  #+sbcl
  (let* ((s (string (code-char #x1F600))) ; 😀
         (out (kernel-events:envelope-to-json s)))
    (assert-equal (format nil "\"~a\"" s) out))
  #-sbcl
  (assert-true t "skipped on non-SBCL — supplementary plane support varies"))

;; ----------------------------------------------------------------
;; Compound: several escapes in one string

(deftest json-string-all-escapes-mixed
  (let* ((parts (list "before"
                      (string #\")
                      (string #\\)
                      (string #\Newline)
                      (string #\Tab)
                      (string (code-char 1))
                      "after"))
         (input (apply #'concatenate 'string parts))
         (out (kernel-events:envelope-to-json input)))
    (assert-true (search "before" out))
    (assert-true (search "\\\"" out))
    (assert-true (search "\\\\" out))
    (assert-true (search "\\n" out))
    (assert-true (search "\\t" out))
    (assert-true (search "\\u0001" out))
    (assert-true (search "after" out))))

;; ----------------------------------------------------------------
;; json-escape-string is the body-only path (no surrounding quotes)

(deftest json-escape-string-no-surrounding-quotes
  (assert-equal "hello" (kernel-events:json-escape-string "hello")))

(deftest json-escape-string-escapes-quote
  (assert-equal "a\\\"b" (kernel-events:json-escape-string "a\"b")))

(deftest json-escape-string-empty
  (assert-equal "" (kernel-events:json-escape-string "")))

(deftest json-escape-string-low-control
  (assert-equal "\\u0001" (kernel-events:json-escape-string (string (code-char 1)))))
