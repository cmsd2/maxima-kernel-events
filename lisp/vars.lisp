;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; vars envelope — Maxima variable inspection snapshot.
;;;
;;; Emitted on demand (typically in response to a host request),
;;; carrying parallel arrays of variable names and their value text.

(in-package :kernel-events)

(defun maxima-symbol-display-name (sym)
  "Strip the leading $ from a Maxima user-variable symbol.  Falls
   back to the bare symbol name when no $ prefix is present."
  (let ((name (symbol-name sym)))
    (if (and (plusp (length name)) (char= (char name 0) #\$))
        (subseq name 1)
        name)))

(defun current-vars-snapshot ()
  "Snapshot maxima::$values: return two parallel vectors,
   (values NAMES VALUES-TEXT), where NAMES are the user-visible
   variable names (no leading $) and VALUES-TEXT are the
   mgrind-rendered current values.  Returns (#() #()) when $values
   is unbound or empty."
  (let* ((vals (and (boundp 'maxima::$values)
                    (symbol-value 'maxima::$values)))
         ;; $values shape: ((mlist) $a $b $c ...)
         (syms (when (and (consp vals) (consp (car vals)))
                 (rest vals))))
    (let ((names    (make-array (length syms) :fill-pointer 0))
          (texts    (make-array (length syms) :fill-pointer 0)))
      (dolist (s syms)
        (vector-push (maxima-symbol-display-name s) names)
        (vector-push
          (handler-case
              (maxima-grind-to-string
                (maxima::meval s))
            (error () ""))
          texts))
      (values names texts))))

(defun emit-vars (&key vars values-text eval-id)
  "Emit a vars envelope.

   VARS is a vector of variable name strings.
   VALUES-TEXT is a parallel vector of value text strings.
   When both are NIL, snapshot via CURRENT-VARS-SNAPSHOT.
   EVAL-ID defaults to *current-eval-id*."
  (multiple-value-bind (names texts)
      (if (and (null vars) (null values-text))
          (current-vars-snapshot)
          (values (or vars #()) (or values-text #())))
    (emit-envelope
      (make-envelope :vars
                     :eval_id     (or eval-id *current-eval-id*)
                     :vars        names
                     :values_text texts))))
