;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

(in-package :sinfol)

#.(file-header)

(defmacro defsuite (name &rest args &key in &allow-other-keys)
  (declare (ignore in))
  `(progn
    (deftest (,name ,@args) ()
      (bind ((test (get-test ',name)))
        (iter (for (nil subtest) :in-hashtable (children-of test))
              (if (or (zerop (length (lambda-list-of subtest)))
                      (member (first (lambda-list-of subtest)) '(&key &optional)))
                  (funcall (name-of subtest))
                  (warn "Skipped test ~S because it has mandatory arguments" subtest))))
      (in-global-context context
        ;; we are not really a test
        (decf (test-count-of context)))
      (values))
    (get-test ',name)))

(setf *suite* (make-suite 'global-suite :documentation "Global Suite"))

(defmacro in-suite (suite-name)
  `(%in-suite ,suite-name))

(defmacro in-suite* (suite-name &rest args &key &allow-other-keys)
  "Just like in-suite, but silently creates missing suites."
  `(%in-suite ,suite-name :fail-on-error #f ,@args))

(defmacro %in-suite (suite-name &rest args &key (fail-on-error #t) &allow-other-keys)
  (remf-keywords args :fail-on-error)
  (with-unique-names (suite)
    `(progn
      (if-bind ,suite (get-test ',suite-name :otherwise nil)
        (setf *suite* ,suite)
        (progn
          (when ,fail-on-error
            (cerror "Create a new suite named ~A."
                    "Unkown suite ~A." ',suite-name))
          (setf *suite* (eval `(defsuite ,',suite-name ,@',args)))))
      ',suite-name)))

