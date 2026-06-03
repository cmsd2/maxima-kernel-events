;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; JSON serialization of compound types:
;;;
;;;   vector     → JSON array
;;;   plist      → JSON object (keys must be keywords)
;;;   hash-table → JSON object (used for mime bundles)
;;;
;;; Plus error cases for malformed input.

(in-package :kernel-events-tests)

(defun j (v)
  (kernel-events:envelope-to-json v))

;; ----------------------------------------------------------------
;; Vectors → JSON arrays

(deftest json-vector-empty
  (assert-equal "[]" (j #())))

(deftest json-vector-single
  (assert-equal "[42]" (j #(42))))

(deftest json-vector-integers
  (assert-equal "[1,2,3]" (j #(1 2 3))))

(deftest json-vector-strings
  (assert-equal "[\"a\",\"b\",\"c\"]" (j #("a" "b" "c"))))

(deftest json-vector-mixed-types
  (assert-equal "[1,\"two\",\"three\"]" (j #(1 "two" :three))))

(deftest json-vector-with-booleans
  (assert-equal "[true,false,null]" (j #(t :false nil))))

(deftest json-vector-nested
  (assert-equal "[[1,2],[3,4]]" (j #(#(1 2) #(3 4)))))

(deftest json-vector-of-objects
  (assert-equal "[{\"k\":1},{\"k\":2}]"
                (j #((:k 1) (:k 2)))
                "vector of plists serialises as array of objects"))

;; ----------------------------------------------------------------
;; Plists → JSON objects

(deftest json-plist-simple
  (assert-equal "{\"a\":1,\"b\":2}" (j '(:a 1 :b 2))))

(deftest json-plist-single-pair
  (assert-equal "{\"only\":42}" (j '(:only 42))))

(deftest json-plist-key-with-hyphen
  (assert-equal "{\"view_id\":\"v_1\"}" (j '(:view-id "v_1"))))

(deftest json-plist-nested-object
  (assert-equal "{\"outer\":{\"inner\":42}}"
                (j '(:outer (:inner 42)))))

(deftest json-plist-deeply-nested
  (assert-equal "{\"a\":{\"b\":{\"c\":{\"d\":1}}}}"
                (j '(:a (:b (:c (:d 1)))))))

(deftest json-plist-with-vector-value
  (assert-equal "{\"xs\":[1,2,3]}" (j '(:xs #(1 2 3)))))

(deftest json-plist-with-array-of-objects
  (assert-equal "{\"items\":[{\"k\":1},{\"k\":2}]}"
                (j '(:items #((:k 1) (:k 2))))))

(deftest json-plist-with-mixed-values
  (assert-equal "{\"a\":1,\"b\":true,\"c\":null,\"d\":\"x\"}"
                (j '(:a 1 :b t :c nil :d "x"))))

;; ----------------------------------------------------------------
;; Plist errors

(deftest json-plist-odd-length-errors
  (assert-signals 'error (lambda () (j '(:a 1 :b)))))

(deftest json-plist-non-keyword-key-errors
  (assert-signals 'error
                  (lambda () (j '("not-a-keyword" 1))))
  (assert-signals 'error
                  (lambda () (j '(foo 1))))
  (assert-signals 'error
                  (lambda () (j '(1 2))))
  "every key in a plist must be a keyword")

;; ----------------------------------------------------------------
;; Hash-tables → JSON objects

(defun bundle-with (&rest pairs)
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on pairs by #'cddr
          do (setf (gethash k h) v))
    h))

(deftest json-hashtable-empty
  (assert-equal "{}" (j (make-hash-table :test 'equal))))

(deftest json-hashtable-string-keys
  (let* ((h (bundle-with "a" 1 "b" 2))
         (out (j h)))
    ;; Hash-table iteration order isn't guaranteed; check membership.
    (assert-true (or (string= out "{\"a\":1,\"b\":2}")
                     (string= out "{\"b\":2,\"a\":1}")))))

(deftest json-hashtable-mime-bundle-shape
  (let* ((h (bundle-with "text/plain" "1/2"
                         "application/x-maxima-latex" "\\frac{1}{2}"))
         (out (j h)))
    (assert-true (search "\"text/plain\":\"1/2\"" out))
    (assert-true (search "\"application/x-maxima-latex\":\"\\\\frac{1}{2}\"" out))))

(deftest json-hashtable-keyword-keys
  (let ((h (make-hash-table)))
    (setf (gethash :alpha h) 1)
    (let ((out (j h)))
      (assert-equal "{\"alpha\":1}" out))))

(deftest json-hashtable-mixed-keys
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "string-key" h) 1)
    (setf (gethash :keyword-key h) 2)
    (let ((out (j h)))
      ;; Both keys must appear; order varies.
      (assert-true (search "\"string-key\":1" out)
                   (format nil "string-key missing in ~s" out))
      (assert-true (search "\"keyword_key\":2" out)
                   (format nil "keyword key (with hyphen→underscore) missing in ~s" out)))))

(deftest json-hashtable-values-can-be-anything
  (let ((h (make-hash-table :test 'equal)))
    (setf (gethash "n" h) 42)
    (setf (gethash "xs" h) #(1 2 3))
    (setf (gethash "nested" h) '(:k "v"))
    (let ((out (j h)))
      (assert-true (search "\"n\":42" out))
      (assert-true (search "\"xs\":[1,2,3]" out))
      (assert-true (search "\"nested\":{\"k\":\"v\"}" out)))))

;; ----------------------------------------------------------------
;; Unknown types

(deftest json-function-value-errors
  (assert-signals 'error (lambda () (j #'identity))))

(deftest json-package-value-errors
  (assert-signals 'error (lambda () (j (find-package :cl)))))
