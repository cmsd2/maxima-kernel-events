;;;; -*-  Mode: Lisp; Package: kernel-events; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Queue-backed character input stream.
;;;
;;; A thread-safe sb-gray stream whose read-char blocks until another
;;; thread pushes input or signals end-of-input.  Designed for
;;; embedding hosts that want to drive maxima::continue from an
;;; external source (HTTP requests, MCP tool calls, IDE input):
;;;
;;;   1. Make a stream.
;;;   2. Spawn a thread that runs (maxima::continue :stream s ...).
;;;   3. From any other thread, push-queue-input s "1+1;\n".
;;;   4. Observe envelopes through a registered sink.
;;;
;;; Pairs with with-collecting-sink (sink.lisp) for the
;;; submit-and-harvest pattern: register a collector, push input,
;;; wait for the matching eval_end envelope, return the slice
;;; matching that eval_id.
;;;
;;; SBCL-only — depends on sb-gray and sb-thread.  Non-SBCL Lisps
;;; get the symbols exported with stub error definitions so callers
;;; can feature-detect.

(in-package :kernel-events)

#+sbcl
(defclass queue-input-stream (sb-gray:fundamental-character-input-stream)
  ((buffer
     :initform (make-string 0)
     :documentation "Current contents queued for read-char.
     Compacted on each push to avoid unbounded growth.")
   (cursor
     :initform 0
     :documentation "Index of the next char read-char will return.")
   (eof-p
     :initform nil
     :documentation "Set by close-queue-input.  read-char returns
     :EOF once buffer is exhausted.")
   (mutex
     :initform (sb-thread:make-mutex :name "queue-input-stream"))
   (waitq
     :initform (sb-thread:make-waitqueue :name "queue-input-stream")))
  (:documentation
    "Character input stream backed by a thread-safe append-only
     character buffer.  read-char blocks when the buffer is empty
     until either push-queue-input or close-queue-input wakes it."))

(defun make-queue-input-stream ()
  "Return a fresh queue-input-stream ready for use.  Errors on
   non-SBCL."
  #+sbcl (make-instance 'queue-input-stream)
  #-sbcl (error "queue-input-stream requires SBCL (sb-gray + sb-thread)"))

(defun push-queue-input (stream text)
  "Append TEXT to STREAM's buffer; wake any thread blocked on
   read-char.  Drops already-consumed characters on each push to
   bound memory."
  #+sbcl
  (with-slots (buffer cursor mutex waitq) stream
    (sb-thread:with-mutex (mutex)
      (setf buffer (concatenate 'string (subseq buffer cursor) text)
            cursor 0)
      (sb-thread:condition-notify waitq)))
  #-sbcl (declare (ignore stream text))
  #-sbcl (error "queue-input-stream requires SBCL"))

(defun close-queue-input (stream)
  "Signal end-of-input.  read-char returns :EOF once the existing
   buffer is drained."
  #+sbcl
  (with-slots (eof-p mutex waitq) stream
    (sb-thread:with-mutex (mutex)
      (setf eof-p t)
      (sb-thread:condition-notify waitq)))
  #-sbcl (declare (ignore stream))
  #-sbcl (error "queue-input-stream requires SBCL"))

#+sbcl
(defmethod sb-gray:stream-read-char ((s queue-input-stream))
  (with-slots (buffer cursor eof-p mutex waitq) s
    (sb-thread:with-mutex (mutex)
      (loop while (and (>= cursor (length buffer)) (not eof-p))
            do (sb-thread:condition-wait waitq mutex))
      (cond
        ((>= cursor (length buffer)) :eof)
        (t (prog1 (char buffer cursor)
             (incf cursor)))))))

#+sbcl
(defmethod sb-gray:stream-unread-char ((s queue-input-stream) char)
  (declare (ignore char))
  (with-slots (cursor) s
    (when (plusp cursor) (decf cursor))
    nil))

#+sbcl
(defmethod sb-gray:stream-listen ((s queue-input-stream))
  ;; Returns T if input is available (or EOF reached).
  (with-slots (buffer cursor eof-p mutex) s
    (sb-thread:with-mutex (mutex)
      (or (< cursor (length buffer)) eof-p))))
