;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2009 by the authors.
;;;
;;; See LICENCE for details.

(defsystem :hu.dwim.stefil.test
  :defsystem-depends-on (:hu.dwim.asdf)
  :class "hu.dwim.asdf:hu.dwim.test-system"
  :licence "BSD / Public domain"
  :depends-on (:hu.dwim.stefil
               ;; you pretty much want this, too... :hu.dwim.stefil+swank
               )
  :components ((:module "test"
                :components ((:file "package")
                             (:file "basic" :depends-on ("package"))
                             (:file "fixtures" :depends-on ("package" "basic"))))))
