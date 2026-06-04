;;;; -*-  Mode: Lisp; Package: kernel-events-tests; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Tests for queue-input-stream.lisp.
;;;
;;; The stream is SBCL-only; tests skip on other Lisps.  We exercise
;;; the basic read/push semantics directly; integration with
;;; maxima::continue lives in the experiment driver, not the unit
;;; tests (it would require spawning a Maxima REPL thread inside an
;;; rtest, which is overkill and slow).

(in-package :kernel-events-tests)

;; ----------------------------------------------------------------
;; Basic read semantics

#+sbcl
(deftest queue-stream-empty-blocks-then-reads
  (let ((s (kernel-events:make-queue-input-stream)))
    ;; In a worker thread: push input after a short delay; the main
    ;; thread blocks on read-char until that happens.
    (sb-thread:make-thread
      (lambda ()
        (sleep 0.05)
        (kernel-events:push-queue-input s "h"))
      :name "qs-pusher")
    (assert-equal #\h (read-char s))))

#+sbcl
(deftest queue-stream-multi-char-push-reads-in-order
  (let ((s (kernel-events:make-queue-input-stream)))
    (kernel-events:push-queue-input s "abc")
    (assert-equal #\a (read-char s))
    (assert-equal #\b (read-char s))
    (assert-equal #\c (read-char s))))

#+sbcl
(deftest queue-stream-pushes-coalesce
  ;; Multiple pushes accumulate into a single readable stream.
  (let ((s (kernel-events:make-queue-input-stream)))
    (kernel-events:push-queue-input s "ab")
    (kernel-events:push-queue-input s "cd")
    (kernel-events:push-queue-input s "ef")
    (let ((buf (make-string 6)))
      (loop for i from 0 below 6
            do (setf (char buf i) (read-char s)))
      (assert-equal "abcdef" buf))))

#+sbcl
(deftest queue-stream-close-without-input-eofs
  (let ((s (kernel-events:make-queue-input-stream)))
    (kernel-events:close-queue-input s)
    ;; read-char with eof-error-p=nil returns eof-value
    (assert-equal :sentinel (read-char s nil :sentinel))))

#+sbcl
(deftest queue-stream-close-drains-existing-buffer-first
  ;; Closing AFTER pushing should still let existing chars be read
  ;; before EOF.
  (let ((s (kernel-events:make-queue-input-stream)))
    (kernel-events:push-queue-input s "xy")
    (kernel-events:close-queue-input s)
    (assert-equal #\x (read-char s))
    (assert-equal #\y (read-char s))
    (assert-equal :eof (read-char s nil :eof))))

;; ----------------------------------------------------------------
;; unread-char

#+sbcl
(deftest queue-stream-unread-then-read
  (let ((s (kernel-events:make-queue-input-stream)))
    (kernel-events:push-queue-input s "ab")
    (let ((c (read-char s)))
      (unread-char c s)
      (assert-equal #\a (read-char s))
      (assert-equal #\b (read-char s)))))

;; ----------------------------------------------------------------
;; stream-listen: T when buffer non-empty OR EOF signalled

#+sbcl
(deftest queue-stream-listen-empty-is-nil
  (let ((s (kernel-events:make-queue-input-stream)))
    (assert-false (listen s))))

#+sbcl
(deftest queue-stream-listen-buffered-is-t
  (let ((s (kernel-events:make-queue-input-stream)))
    (kernel-events:push-queue-input s "z")
    (assert-true (listen s))))

#+sbcl
(deftest queue-stream-listen-after-close-is-t
  (let ((s (kernel-events:make-queue-input-stream)))
    (kernel-events:close-queue-input s)
    (assert-true (listen s)
                 "listen should be T after close so read-char can return :EOF")))

;; ----------------------------------------------------------------
;; Concurrent producer + consumer

#+sbcl
(deftest queue-stream-concurrent-producer-consumer
  (let* ((s (kernel-events:make-queue-input-stream))
         (consumed (make-array 0 :adjustable t :fill-pointer 0))
         (consumer
           (sb-thread:make-thread
             (lambda ()
               (loop for c = (read-char s nil :eof)
                     until (eq c :eof)
                     do (vector-push-extend c consumed)))
             :name "qs-consumer")))
    (dotimes (i 100)
      (kernel-events:push-queue-input s
                                      (format nil "~A" (mod i 10))))
    (kernel-events:close-queue-input s)
    (sb-thread:join-thread consumer)
    (assert-equal 100 (length consumed))))

;; ----------------------------------------------------------------
;; Non-SBCL behaviour

#-sbcl
(deftest queue-stream-non-sbcl-make-errors
  (assert-signals 'error
                  (lambda () (kernel-events:make-queue-input-stream))))
