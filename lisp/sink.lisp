;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Sink abstraction.
;;;
;;; A SINK is a function that takes one envelope (a Lisp object that
;;; serializes to JSON; see envelope.lisp) and writes it somewhere.
;;; The package does not assume any particular transport.  Sinks
;;; observed in practice:
;;;
;;;   - fd-3 transport:  write the envelope as a JSON line to
;;;                      *maxima-events-out*
;;;   - HTTP+SSE host:   fan out to all connected SSE streams
;;;   - tests:           accumulate into a list
;;;   - file logger:     append to a file
;;;
;;; Multiple sinks can be registered simultaneously.  Emission iterates
;;; over all registered sinks; one failing sink does not prevent the
;;; others from receiving the envelope.

(in-package :kernel-events)

(defvar *sinks* '()
  "List of sink functions.  Each receives every emitted envelope.")

;; Mutex protecting *sinks*.  SBCL has native threads; other Lisps
;; either have their own primitive or are single-threaded.  For the
;; MVP we provide a mutex on SBCL and a no-op on everything else.
#+sbcl
(defvar *sinks-lock*
  (sb-thread:make-mutex :name "kernel-events-sinks-lock"))
#-sbcl
(defvar *sinks-lock* nil)

(defmacro with-sinks-lock (&body body)
  "Hold the sinks lock for BODY.  No-op on Lisps without threads."
  #+sbcl `(sb-thread:with-mutex (*sinks-lock*) ,@body)
  #-sbcl `(progn ,@body))

(defvar *debug-sinks* nil
  "When non-nil, sink errors are logged to *trace-output*.  Off by
   default so we never write to stdout during emission (we may be in
   an output-wrapper context and that would infinite-loop).")

(defun register-sink (sink-fn)
  "Register SINK-FN as a sink.  SINK-FN is called as
   (funcall sink-fn envelope) for every emitted envelope.  Returns
   SINK-FN itself as a token usable for unregister-sink."
  (check-type sink-fn function)
  (with-sinks-lock
    (pushnew sink-fn *sinks* :test #'eq))
  sink-fn)

(defun unregister-sink (token)
  "Remove the sink identified by TOKEN (returned by register-sink).
   Returns T if a sink was removed, NIL otherwise."
  (with-sinks-lock
    (let ((before (length *sinks*)))
      (setf *sinks* (remove token *sinks* :test #'eq))
      (< (length *sinks*) before))))

(defun list-sinks ()
  "Return a fresh copy of the current sink list (for inspection)."
  (with-sinks-lock
    (copy-list *sinks*)))

(defun clear-sinks ()
  "Remove every registered sink.  Used by tests for isolation."
  (with-sinks-lock
    (setf *sinks* nil)))

(defun call-sinks (envelope)
  "Internal: deliver ENVELOPE to all registered sinks.  Catches
   per-sink errors so one bad sink doesn't stop the others.  Errors
   are silently swallowed unless *debug-sinks* is non-nil."
  (dolist (sink (list-sinks))
    (handler-case
        (funcall sink envelope)
      (error (e)
        (when *debug-sinks*
          ;; *trace-output*, not *standard-output* — if a sink wrap
          ;; of stdout is in play we'd otherwise re-enter emission.
          (format *trace-output*
                  "~&[kernel-events] sink ~s error: ~a~%" sink e))
        nil))))

;;; --- Scoped collecting sink --------------------------------------------

(defmacro with-collecting-sink ((envelopes-var) &body body)
  "Register a sink for the dynamic extent of BODY that pushes every
   emitted envelope into a fresh fill-pointer'd vector bound to
   ENVELOPES-VAR.  Unregisters on exit.

   Thread-safe: pushes are guarded by a private mutex (on SBCL) so
   concurrent emitters can fan into the same collector.

   This is the building block for embedding hosts that want
   per-request envelope collection — register before submitting an
   eval, harvest after the eval_end."
  (let ((lock-sym  (gensym "LOCK"))
        (token-sym (gensym "TOKEN")))
    `(let ((,envelopes-var (make-array 0 :adjustable t :fill-pointer 0))
           (,lock-sym
             #+sbcl (sb-thread:make-mutex :name "collecting-sink")
             #-sbcl nil))
       (declare (ignorable ,envelopes-var ,lock-sym))
       (let ((,token-sym
               (register-sink
                 (lambda (e)
                   #+sbcl (sb-thread:with-mutex (,lock-sym)
                            (vector-push-extend e ,envelopes-var))
                   #-sbcl (vector-push-extend e ,envelopes-var)))))
         (unwind-protect (progn ,@body)
           (unregister-sink ,token-sym))))))

(defun collect-envelopes (thunk)
  "Call THUNK with no arguments under a collecting sink and return
   the vector of envelopes that emerged.  Functional equivalent of
   the with-collecting-sink macro for callers that prefer a
   higher-order form."
  (with-collecting-sink (envelopes)
    (funcall thunk)
    envelopes))
