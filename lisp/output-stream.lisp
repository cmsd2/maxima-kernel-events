;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Output stream wrapping.
;;;
;;; Replaces *standard-output* (and *error-output*) with gray streams
;;; that buffer bytes line-by-line and emit an `output' envelope on
;;; each newline (or on explicit finish-output / uninstall).  The
;;; wrappers ALSO pass writes through to the original underlying
;;; stream — a user without a registered kernel-events sink still
;;; sees normal output, and the development REPL is unaffected.
;;;
;;; Three design choices, each grounded in mailing-list lore:
;;;
;;; 1. Pass-through is the default.  Mirrors $appendfile
;;;    (src/macsys.lisp:585-592): one logical output channel fanning
;;;    to multiple physical destinations.  Without a sink the wrapper
;;;    is invisible to the user.
;;;
;;; 2. We flush with finish-output, NOT force-output.  CLISP loses
;;;    characters with force-output (Königsmann 2019, sf_id 36632166;
;;;    confirmed Villate/Königsmann 2022, sf_id 37626709).
;;;
;;; 3. Gray streams are SBCL-only in practice.  On other Lisps,
;;;    install-output-wrapping warns once and returns NIL — loading
;;;    the package never errors regardless of host Lisp.
;;;
;;; Each output envelope carries:
;;;   - eval_id  (NIL until eval-hooks.lisp wires up the eval driver)
;;;   - stream   ("stdout" or "stderr")
;;;   - mime     "text/plain"
;;;   - text     one logical line

(in-package :kernel-events)

(defvar *original-standard-output* nil
  "Pre-install *standard-output*.  NIL when the wrapper is not
   installed.  Set by install-output-wrapping; cleared by uninstall.")

(defvar *original-error-output* nil
  "Pre-install *error-output*.  Same lifecycle as
   *original-standard-output*.")

;;; --- Gray stream implementation ----------------------------------------
;;;
;;; Loaded only on SBCL.  On other Lisps the install/uninstall
;;; functions are stubs that warn-once and return NIL — so the package
;;; still loads cleanly elsewhere.

#+sbcl
(defclass events-output-stream (sb-gray:fundamental-character-output-stream)
  ((buffer
     :initform (make-array 256
                 :element-type 'character
                 :adjustable t
                 :fill-pointer 0)
     :reader stream-buffer
     :documentation "Per-line buffer.  Bytes accumulate here until a
                     newline triggers envelope emission.")
   (name
     :initarg :name
     :reader stream-name
     :documentation "\"stdout\" or \"stderr\" — appears verbatim in
                     output envelopes' :stream field.")
   (underlying
     :initarg :underlying
     :reader stream-underlying
     :documentation "The original stream we wrap.  Every write is
                     mirrored here so dev sessions still see
                     output normally."))
  (:documentation
    "Gray stream that line-buffers writes, emits one `output'
     envelope per line, and mirrors every character to its
     underlying stream."))

#+sbcl
(defun flush-output-buffer (stream)
  "Emit any buffered text in STREAM as a single output envelope and
   clear the buffer.  Safe to call repeatedly with no content."
  (let ((buf (stream-buffer stream)))
    (when (plusp (length buf))
      (emit-output-line (stream-name stream) (copy-seq buf))
      (setf (fill-pointer buf) 0))))

#+sbcl
(defmethod sb-gray:stream-write-char ((s events-output-stream) ch)
  ;; Mirror first so dev sessions see characters even if we crash
  ;; while building the envelope (defensive against our own bugs).
  (write-char ch (stream-underlying s))
  (vector-push-extend ch (stream-buffer s))
  (when (char= ch #\Newline)
    (flush-output-buffer s))
  ch)

#+sbcl
(defmethod sb-gray:stream-write-string
    ((s events-output-stream) string &optional (start 0) end)
  (let ((end (or end (length string))))
    (write-string string (stream-underlying s) :start start :end end)
    (loop for i from start below end
          for ch = (char string i)
          do (vector-push-extend ch (stream-buffer s))
             (when (char= ch #\Newline)
               (flush-output-buffer s)))
    string))

#+sbcl
(defmethod sb-gray:stream-line-column ((s events-output-stream))
  ;; We don't track columns.  Returning NIL is the documented "no
  ;; idea" answer in the gray-streams protocol.
  nil)

#+sbcl
(defmethod sb-gray:stream-finish-output ((s events-output-stream))
  ;; finish-output (not force-output): CLISP loses chars with the
  ;; latter (Königsmann 2019).  SBCL is fine with either, but we use
  ;; finish-output for symmetry.
  (finish-output (stream-underlying s))
  (flush-output-buffer s))

#+sbcl
(defmethod sb-gray:stream-force-output ((s events-output-stream))
  ;; Provide for API completeness, but mirror to underlying's
  ;; finish-output deliberately — see comment above.
  (finish-output (stream-underlying s))
  (flush-output-buffer s))

#+sbcl
(defmethod sb-gray:stream-clear-output ((s events-output-stream))
  (setf (fill-pointer (stream-buffer s)) 0)
  (clear-output (stream-underlying s))
  nil)

#+sbcl
(defmethod close ((s events-output-stream) &key abort)
  (declare (ignore abort))
  (flush-output-buffer s)
  t)

;;; --- Public API ---------------------------------------------------------

(defun emit-output-line (stream-name text)
  "Build and emit an output envelope.  Called from the gray stream's
   buffer-flush path; also callable directly by code that wants to
   route a line through the same envelope shape (mostly tests)."
  (emit-envelope
    (make-envelope :output
                   :eval_id (current-eval-id)
                   :stream stream-name
                   :mime "text/plain"
                   :text text)))

(defvar *non-sbcl-warning-issued* nil
  "T after we've warned once on a non-SBCL host that output wrapping
   is a no-op.  Avoid spamming the user.")

(defun install-output-wrapping ()
  "Wrap *standard-output* and *error-output* with envelope-emitting
   streams that also pass through to their originals.  Idempotent —
   a second call while installed returns NIL and changes nothing.
   On non-SBCL Lisps, warns once and returns NIL.  On success
   returns T."
  #+sbcl
  (cond
    (*original-standard-output*
     nil)
    (t
     (setf *original-standard-output* *standard-output*
           *original-error-output*    *error-output*)
     (setq *standard-output*
           (make-instance 'events-output-stream
                          :name "stdout"
                          :underlying *original-standard-output*))
     (setq *error-output*
           (make-instance 'events-output-stream
                          :name "stderr"
                          :underlying *original-error-output*))
     t))
  #-sbcl
  (progn
    (unless *non-sbcl-warning-issued*
      (warn "kernel-events: output-stream wrapping requires SBCL gray streams; no-op on this host")
      (setf *non-sbcl-warning-issued* t))
    nil))

(defun uninstall-output-wrapping ()
  "Restore the original *standard-output* and *error-output*.  Flush
   any partial buffered lines so they aren't lost.  Returns T if a
   wrapper was uninstalled, NIL if none was installed."
  #+sbcl
  (when *original-standard-output*
    (let ((wrapped-out *standard-output*)
          (wrapped-err *error-output*))
      (setq *standard-output* *original-standard-output*)
      (setq *error-output*    *original-error-output*)
      (setf *original-standard-output* nil
            *original-error-output*    nil)
      (when (typep wrapped-out 'events-output-stream)
        (flush-output-buffer wrapped-out))
      (when (typep wrapped-err 'events-output-stream)
        (flush-output-buffer wrapped-err)))
    t)
  #-sbcl
  nil)

(defun output-wrapping-installed-p ()
  "T when the wrapper is currently active."
  (not (null *original-standard-output*)))
