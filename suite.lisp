;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :stefil)

#.(file-header)

(defmacro defsuite (name-or-name-with-args &body body)
  (bind (((name &rest args) (ensure-list name-or-name-with-args)))
    (with-unique-names (test)
      `(progn
        (deftest (,name ,@args) ()
          (bind ((,test (find-test ',name)))
            (flet ((run-child-tests ()
                     (iter (for (nil subtest) :in-hashtable (children-of ,test))
                           (when (and (auto-call-p subtest)
                                      (or (zerop (length (lambda-list-of subtest)))
                                          (member (first (lambda-list-of subtest)) '(&key &optional))))
                             (funcall (name-of subtest))))))
              ,@(or body
                    `((if (test-was-run-p ,test)
                          (warn "Skipped executing already ran tests suite ~S" (name-of ,test))
                          (run-child-tests))))))
          (values))
        (values (find-test ',name))))))

(defmacro defsuite* (name &body body)
  `(setf *suite* (defsuite ,name ,@body)))

(setf *suite* (make-suite 'global-suite :documentation "Default Suite"))

(defmacro in-suite (suite-name)
  `(setf *suite* (find-test ',suite-name
                  :otherwise (lambda ()
                               (cerror "Create a new suite named ~A."
                                       "Unkown suite ~A." ',name)
                               (defsuite ,name)))))

(defmacro in-suite* (name &body body)
  "Just like in-suite, but silently creates the named suite if it does not exists."
  (with-unique-names (suite)
    `(let ((,suite (find-test ,name :otherwise (lambda ()
                                                (defsuite ,name ,@body)))))
      (in-suite ,suite))))



