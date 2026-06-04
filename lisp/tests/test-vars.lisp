;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for vars.lisp — the variable-snapshot envelope.

(in-package :kernel-events-tests)

;; ----------------------------------------------------------------
;; maxima-symbol-display-name

(deftest vars-display-name-strips-dollar
  (assert-equal "X"
                (kernel-events::maxima-symbol-display-name 'maxima::$x)))

(deftest vars-display-name-passes-through-non-dollar
  ;; A symbol without the $ prefix is returned bare.
  (assert-equal "X"
                (kernel-events::maxima-symbol-display-name
                  (intern "X" :maxima))))

;; ----------------------------------------------------------------
;; Explicit vars + values-text

(deftest vars-emit-with-explicit-arrays
  (with-collector (envs)
    (kernel-events:emit-vars :vars (vector "x" "y")
                             :values-text (vector "1" "2"))
    (assert-equal 1 (length envs))
    (let ((e (aref envs 0)))
      (assert-equal :vars (getf e :type))
      (let ((names (getf e :vars))
            (texts (getf e :values_text)))
        (assert-equal 2 (length names))
        (assert-equal "x" (aref names 0))
        (assert-equal "y" (aref names 1))
        (assert-equal 2 (length texts))
        (assert-equal "1" (aref texts 0))
        (assert-equal "2" (aref texts 1))))))

(deftest vars-emit-tags-current-eval-id
  (with-collector (envs)
    (let ((kernel-events::*current-eval-id* "e_42"))
      (kernel-events:emit-vars :vars #("z") :values-text #("3")))
    (assert-equal "e_42" (getf (aref envs 0) :eval_id))))

;; ----------------------------------------------------------------
;; Snapshot from maxima::$values

(deftest vars-snapshot-empty-when-no-values
  ;; $values shape: ((mlist) ...) — empty rest means no user vars.
  (let ((maxima::$values (list (list 'maxima::mlist))))
    (multiple-value-bind (names texts)
        (kernel-events:current-vars-snapshot)
      (assert-equal 0 (length names))
      (assert-equal 0 (length texts)))))

(deftest vars-snapshot-strips-dollar-from-names
  ;; Set $x to 42 the Maxima way, then snapshot.
  (let ((saved-x (and (boundp 'maxima::$x) (symbol-value 'maxima::$x)))
        (saved-values (and (boundp 'maxima::$values)
                           (symbol-value 'maxima::$values))))
    (unwind-protect
        (progn
          (setf (symbol-value 'maxima::$x) 42)
          (setf (symbol-value 'maxima::$values)
                (list (list 'maxima::mlist) 'maxima::$x))
          (multiple-value-bind (names texts)
              (kernel-events:current-vars-snapshot)
            (assert-equal 1 (length names))
            (assert-equal "X" (aref names 0))
            (assert-equal "42" (aref texts 0))))
      (when saved-values
        (setf (symbol-value 'maxima::$values) saved-values))
      (when saved-x
        (setf (symbol-value 'maxima::$x) saved-x)))))

(deftest vars-emit-no-args-uses-snapshot
  ;; emit-vars with neither :vars nor :values-text falls back to
  ;; current-vars-snapshot.
  (with-collector (envs)
    (let ((maxima::$values (list (list 'maxima::mlist))))
      (kernel-events:emit-vars)
      (let ((e (aref envs 0)))
        (assert-equal :vars (getf e :type))
        (assert-equal 0 (length (getf e :vars)))
        (assert-equal 0 (length (getf e :values_text)))))))
