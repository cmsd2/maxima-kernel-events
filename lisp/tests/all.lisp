;;;; -*-  Mode: Lisp; Syntax: Common-Lisp; Base: 10 -*- ;;;;
;;;
;;; Load every test file in this directory in alphabetical order.
;;; Call this AFTER loading the package + lisp/sink.lisp +
;;; lisp/envelope.lisp + lisp/tests/runner.lisp.
;;;
;;; A typical SBCL one-liner is in run-tests.sh.

(load (merge-pathnames "test-emit.lisp"
                       (or *load-pathname* *compile-file-pathname*)))
(load (merge-pathnames "test-envelope-shapes.lisp"
                       (or *load-pathname* *compile-file-pathname*)))
(load (merge-pathnames "test-json-collections.lisp"
                       (or *load-pathname* *compile-file-pathname*)))
(load (merge-pathnames "test-json-scalars.lisp"
                       (or *load-pathname* *compile-file-pathname*)))
(load (merge-pathnames "test-json-strings.lisp"
                       (or *load-pathname* *compile-file-pathname*)))
(load (merge-pathnames "test-sink.lisp"
                       (or *load-pathname* *compile-file-pathname*)))
(load (merge-pathnames "test-stream-events.lisp"
                       (or *load-pathname* *compile-file-pathname*)))
