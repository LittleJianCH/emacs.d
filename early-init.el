;;; early-init.el --- Settings applied before the first frame -*- lexical-binding: t; -*-

;; Relax GC during startup; init.el restores it once startup finishes.
(setq gc-cons-threshold most-positive-fixnum
      gc-cons-percentage 0.6)

;; Packages are initialized in init.el.
(setq package-enable-at-startup nil)

;; Keep third-party noise out of *Warnings*: native-comp warnings about
;; packages (still in *Async-native-compile-log*; our own files are checked
;; by byte-compiling), and packages that lack a lexical-binding cookie.
(setq native-comp-async-report-warnings-errors nil
      warning-suppress-log-types '((files missing-lexbind-cookie)))

;; Disable unneeded UI elements before the first frame is created, to avoid flicker.
(setq frame-inhibit-implied-resize t
      frame-resize-pixelwise t)
(push '(tool-bar-lines . 0) default-frame-alist)
(push '(vertical-scroll-bars . nil) default-frame-alist)
(push '(internal-border-width . 24) default-frame-alist) ; wide margins, as in nano
(push '(width . 200) default-frame-alist)
(push '(height . 55) default-frame-alist)
(when (eq system-type 'darwin)
  (push '(ns-transparent-titlebar . t) default-frame-alist))

;;; early-init.el ends here
