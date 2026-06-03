;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Cooperative cancellation infrastructure.
;;;
;;; A polling thread reads a host-provided fd (or in-process queue);
;;; when it sees a cancel signal, it sets *cancel-flag* to T.  Library
;;; code (e.g. the SUNDIALS RHS callback) checks the flag at well-
;;; defined opt-in points and unwinds via merror or a custom signal.
;;;
;;; The load-only path cannot patch Maxima's mdo to check the flag
;;; automatically (that's upstream Patch 2).  Library authors opt in by
;;; calling (check-cancel) in their inner loop.

(in-package :kernel-events)

(defvar *cancel-flag* nil
  "Set to T when a cancellation has been requested.  Library code
   checks this flag in its inner loops and unwinds cleanly when set.
   Reset by emit-eval-end so each evaluation starts fresh.")

(defvar *cancel-watcher-thread* nil
  "Background thread that reads the host-provided cancel channel and
   sets *cancel-flag*.  NIL when no watcher is active.")

(defun request-cancel ()
  "Request cancellation of the current evaluation.  Sets
   *cancel-flag*; library code is responsible for noticing.
   May be called from any thread, including from a sink callback."
  (setf *cancel-flag* t))

(defun cancel-requested-p ()
  "Return T if cancellation has been requested.  Library code calls
   this in its inner loops."
  *cancel-flag*)

(defun check-cancel ()
  "If cancellation has been requested, signal an error to unwind
   the current evaluation.  Library code calls this directly in
   inner loops where unwinding is safe."
  (when *cancel-flag*
    (error "TODO: implement check-cancel unwind")))

(defun start-cancel-watcher (read-fd)
  "Start a background thread that polls READ-FD for cancel signals.
   Sets *cancel-watcher-thread* on success."
  (declare (ignore read-fd))
  (error "TODO: implement start-cancel-watcher"))

(defun stop-cancel-watcher ()
  "Stop the cancel watcher thread, if running."
  (error "TODO: implement stop-cancel-watcher"))

(defun reset-cancel-flag ()
  "Called by emit-eval-end to clear the flag for the next evaluation."
  (setf *cancel-flag* nil))
