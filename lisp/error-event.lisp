;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Structured error envelope.
;;;
;;; The eval_end envelope's :status field tells a host *that*
;;; something failed (ok / error / cancelled).  The error envelope
;;; tells a host *what* failed: kind, message, optional
;;; location / form / backtrace.
;;;
;;; eval-hooks fires error envelopes automatically — one per failure
;;; mode:
;;;
;;;   - cancellation-requested  ->  kind = :cancelled
;;;   - maxima merror throw     ->  kind = :maxima_error
;;;   - maxima-$error signal    ->  kind = :maxima_error
;;;   - any other Lisp error    ->  kind = :lisp_error
;;;
;;; Hosts can also fire emit-error directly for cases the kernel
;;; doesn't auto-detect (parser errors, timeouts).
;;;
;;; This file also hosts the maxima-error-message helper — useful
;;; from both eval-hooks (catch the throw, read $error) and
;;; debugger-hooks (the dbm wrap reports the same message).

(in-package :kernel-events)

;; *current-eval-id* is defined in eval-hooks.lisp, which loads
;; after this file (so emit-error can be called from inside the
;; eval-hooks wrap).  Declaim special here so the compiler doesn't
;; warn about the forward reference.
(declaim (special *current-eval-id*))

(defun maxima-error-message ()
  "Read maxima::$error and render its message component to a string.
   Returns NIL if $error is unbound or empty.  Safe to call from any
   condition handler: catches any error that might fall out of
   coercing the message."
  (handler-case
      (let ((err (and (boundp 'maxima::$error)
                      (symbol-value 'maxima::$error))))
        (when (and (consp err) (consp (cdr err)))
          ;; $error is `((mlist simp) <message> . <args>)'.  The
          ;; <message> is typically a string already; if not, render
          ;; with princ.
          (let ((msg (second err)))
            (cond ((stringp msg) msg)
                  ((null msg) nil)
                  (t (princ-to-string msg))))))
    (error () nil)))

(defun condition-message (condition)
  "Render CONDITION to a human-readable string.  Defensive: a
   broken print-object method shouldn't recursively trigger error
   handlers."
  (handler-case (princ-to-string condition)
    (error () (format nil "<unprintable ~s>" (type-of condition)))))

(defun split-lines (s)
  "Return a list of S split on Newline.  Trailing empty line dropped."
  (loop with start = 0
        for i from 0 below (length s)
        when (char= (char s i) #\Newline)
        collect (subseq s start i) into acc
        and do (setf start (1+ i))
        finally (return (if (< start (length s))
                            (append acc (list (subseq s start)))
                            acc))))

(defun capture-sbcl-backtrace (&key (max-frames 32))
  "Capture an SBCL backtrace as a vector of frame description
   strings — one element per frame.  Returns NIL on non-SBCL or if
   backtrace inspection itself errors.  Uses SB-DEBUG:PRINT-BACKTRACE
   (the only external entry point) and splits its output on
   newlines; SBCL formats one frame per line."
  #+sbcl
  (handler-case
      (let* ((raw (with-output-to-string (s)
                    (sb-debug:print-backtrace :stream s
                                              :count max-frames)))
             (lines (split-lines raw))
             (vec (make-array (length lines) :fill-pointer 0)))
        (dolist (l lines vec)
          (vector-push l vec)))
    (error () nil))
  #-sbcl nil)

(defun capture-restarts (condition)
  "Capture available restarts for CONDITION as a vector of plists
   (:name string :description string).  Returns NIL if the runtime
   has no restart machinery exposed."
  (handler-case
      (let ((out (make-array 0 :adjustable t :fill-pointer 0)))
        (dolist (r (compute-restarts condition))
          (vector-push-extend
            (list :name
                  (let ((n (restart-name r)))
                    (if n (string-downcase (string n)) ""))
                  :description
                  (handler-case (princ-to-string r)
                    (error () "")))
            out))
        out)
    (error () nil)))

(defun emit-error (kind message
                   &key location form backtrace
                        (recoverable :false)
                        condition-type
                        eval-id)
  "Emit a structured error envelope.

   KIND is one of :maxima_error :lisp_error :parser_error :timeout
   :cancelled.
   MESSAGE is the human-readable error string.
   LOCATION is an optional plist with :line and :column.
   FORM is the offending source as a string.
   BACKTRACE is a vector of strings.
   CONDITION-TYPE is the Lisp class name (string) for :lisp_error;
   NIL otherwise.
   RECOVERABLE is T / :false; defaults to :false.
   EVAL-ID defaults to *current-eval-id*."
  (emit-envelope
    (make-envelope :error
                   :eval_id        (or eval-id *current-eval-id*)
                   :kind           kind
                   :message        message
                   :condition_type condition-type
                   :location       location
                   :form           form
                   :backtrace      backtrace
                   :recoverable    recoverable)))
