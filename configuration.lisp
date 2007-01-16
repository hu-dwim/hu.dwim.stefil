;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :stefil)

(enable-sharp-boolean-syntax)

;;; These definitions need to be available by the time we are reading the other files, therefore
;;; they are in a standalone file.

(defmacro debug-only (&body body)
  #+debug`(progn ,@body)
  #-debug(declare (ignore body)))

(defun file-header ()
  `(progn
    (enable-sharp-boolean-syntax)
    (eval-when (:compile-toplevel)
      (assert (eq *defclass-macro-name-for-dynamic-context* 'defclass*) ()
              "Seems like defclass-star is not loaded because *defclass-macro-name-for-dynamic-context* points to ~S."
              *defclass-macro-name-for-dynamic-context*))))



