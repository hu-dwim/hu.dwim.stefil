;;; -*- mode: Lisp; Syntax: Common-Lisp; -*-
;;;
;;; Copyright (c) 2009 by the authors.
;;;
;;; See LICENCE for details.

(load-system :hu.dwim.asdf)

(in-package :hu.dwim.asdf)

(defsystem :hu.dwim.stefil+hu.dwim.def
  :class hu.dwim.system
  :depends-on (:hu.dwim.def
               :hu.dwim.stefil)
  :components ((:module "integration"
                :components ((:file "def")))))
