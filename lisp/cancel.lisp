;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Cooperative cancellation infrastructure.
;;;
;;; A polling thread reads a host-provided fd (or any blocking
;;; read-fn).  When it sees a cancel signal it sets *cancel-flag*
;;; to T.  Library code (e.g. the SUNDIALS RHS callback) calls
;;; check-cancel at well-defined opt-in points; if the flag is set,
;;; check-cancel signals a CANCELLATION-REQUESTED condition that
;;; unwinds through the caller.
;;;
;;; The load-only path cannot patch Maxima's mdo to check the flag
;;; automatically (that's upstream Patch 2 from streaming.md).
;;; Library authors opt in by calling check-cancel in their inner
;;; loops at points where unwinding is safe.

(in-package :kernel-events)

(define-condition cancellation-requested (error)
  ((view-id :initarg :view-id
            :initform nil
            :reader cancellation-view-id))
  (:report
    (lambda (c stream)
      (let ((v (cancellation-view-id c)))
        (if v
            (format stream "Cancellation requested for view ~s" v)
            (format stream "Cancellation requested"))))))

(defvar *cancel-flag* nil
  "Set to T when a cancellation has been requested.  Library code
   checks this flag in its inner loops (via check-cancel) and
   unwinds via CANCELLATION-REQUESTED when set.  Reset is explicit
   via reset-cancel-flag — typically by the eval driver between
   evaluations.")

(defvar *cancel-watcher-thread* nil
  "Background thread polling for cancel signals.  NIL when no
   watcher is active.")

(defun request-cancel (&optional view-id)
  "Request cancellation of the current evaluation/stream.
   Idempotent — multiple calls are fine.  May be called from any
   thread (e.g. the watcher reading from fd 4, or directly from a
   host's MCP handler).

   VIEW-ID is currently informational only; we don't track per-view
   cancellation state, but the next CANCELLATION-REQUESTED condition
   raised by check-cancel will carry it through."
  (declare (ignore view-id))
  (setf *cancel-flag* t)
  t)

(defun cancel-requested-p ()
  "Return T if cancellation has been requested since the last reset."
  *cancel-flag*)

(defun check-cancel (&key view-id)
  "If a cancellation has been requested, signal CANCELLATION-REQUESTED
   with the optional VIEW-ID attached.  Otherwise return NIL.

   Library code calls this in its inner loops at points where
   unwinding through a condition is safe (after committing observable
   state, before allocating new resources).  Does NOT auto-reset the
   flag — reset is the responsibility of the eval driver."
  (when *cancel-flag*
    (error 'cancellation-requested :view-id view-id)))

(defun reset-cancel-flag ()
  "Clear the cancellation flag.  Returns its previous value (so
   callers can detect that a cancel was pending before they cleared
   it).  Typically called by the eval driver between evaluations."
  (let ((prev *cancel-flag*))
    (setf *cancel-flag* nil)
    prev))

;;; --- Watcher thread -----------------------------------------------------
;;;
;;; A simple wrapper around sb-thread:make-thread that runs READ-FN in a
;;; loop; whenever READ-FN returns non-nil, set the cancel flag.
;;; READ-FN is expected to BLOCK until input arrives (e.g. reading one
;;; byte from fd 4); a non-blocking READ-FN that returns nil
;;; immediately would hot-spin and pin a CPU.
;;;
;;; The watcher is opt-in: aximar / maxima_mcp / a custom host calls
;;; start-cancel-watcher with a function suitable for its transport.
;;; Without a watcher, request-cancel can still be called directly
;;; from in-process code (e.g. an interrupt handler).

(defvar *watcher-stop-requested* nil
  "Cooperative-stop flag for the watcher thread.  Set by
   stop-cancel-watcher; the watcher's read-fn is expected to check
   this between blocking reads to allow graceful shutdown.")

(defun start-cancel-watcher (read-fn)
  "Start a background thread that calls (FUNCALL READ-FN).  When
   READ-FN returns non-nil, set the cancel flag.  When it returns
   :stop, the watcher exits.

   READ-FN must BLOCK until input arrives — a fd-reading thunk
   reading exactly one byte is the canonical shape.  See
   stop-cancel-watcher for graceful shutdown.

   On non-threaded Lisps this signals an error; aximar's fd-4 path
   requires SBCL threading."
  (check-type read-fn function)
  (when *cancel-watcher-thread*
    (error "kernel-events: a cancel watcher is already running"))
  #+sbcl
  (progn
    (setf *watcher-stop-requested* nil)
    (setf *cancel-watcher-thread*
          (sb-thread:make-thread
            (lambda ()
              (loop until *watcher-stop-requested*
                    do (let ((result (funcall read-fn)))
                         (cond
                           ((eq result :stop) (return))
                           (result (setf *cancel-flag* t))))))
            :name "kernel-events-cancel-watcher")))
  #-sbcl
  (error "kernel-events: cancel watcher requires SBCL threading")
  *cancel-watcher-thread*)

(defun stop-cancel-watcher ()
  "Stop the cancel watcher thread, if running.  Sets the cooperative
   stop flag; the watcher's read-fn is expected to notice on its
   next iteration (or be unblocked externally).  Joins the thread
   and clears *cancel-watcher-thread*.  Returns T if a watcher was
   stopped, NIL otherwise."
  (when *cancel-watcher-thread*
    (setf *watcher-stop-requested* t)
    #+sbcl
    (handler-case
        (sb-thread:join-thread *cancel-watcher-thread*
                               :default :forced-exit)
      (error () nil))
    (setf *cancel-watcher-thread* nil)
    t))

(defun cancel-watcher-running-p ()
  "Return T if the cancel watcher thread is currently active."
  (and *cancel-watcher-thread*
       #+sbcl (sb-thread:thread-alive-p *cancel-watcher-thread*)
       #-sbcl nil))
