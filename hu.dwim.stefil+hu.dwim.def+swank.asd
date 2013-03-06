;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2006 by the authors.
;;;
;;; See LICENCE for details.

;; TODO rename to something like :hu.dwim.dependency-for-tests or something that is closer to the intent than to the implementation
(defsystem :hu.dwim.stefil+hu.dwim.def+swank
  :defsystem-depends-on (:hu.dwim.asdf)
  :class "hu.dwim.asdf:hu.dwim.system"
  :depends-on (:hu.dwim.def+swank
               :hu.dwim.stefil+hu.dwim.def
               :hu.dwim.stefil+swank))
