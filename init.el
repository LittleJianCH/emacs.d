;;; init.el --- Emacs config for working with coding agents -*- lexical-binding: t; -*-

;;; Commentary:

;; Layout:
;;   lisp/core/   base layer: defaults, UI, completion, general dev tools
;;   lisp/lang/   language modules, one file per language: lang-NAME.el
;;   lisp/agent/  agent support: terminal sessions, the agent -> Emacs bridge
;;
;; To add a language: create lisp/lang/lang-NAME.el (ending with `provide'),
;; then add NAME to `my/languages'.

;;; Code:

(when (version< emacs-version "30.1")
  (error "这份配置需要 Emacs 30.1 或更新版本"))

(dolist (dir '("core" "lang" "agent"))
  (add-to-list 'load-path (expand-file-name (concat "lisp/" dir) user-emacs-directory)))

;;; Package archives: GNU / NonGNU ELPA first, MELPA only for a few extras

(require 'package)
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))
(package-initialize)
(require 'use-package)
(setq use-package-expand-minimally t)

;;; Modules

(defvar my/languages '(elisp rust)
  "Enabled language modules, each loaded from lisp/lang/lang-NAME.el.")

(require 'init-base)        ; defaults, paths, macOS environment
(require 'init-ui)          ; theme, fonts, windows
(when my/use-evil
  (require 'init-evil))     ; Vim keys (evil), off by default; M-x my/toggle-evil
(require 'init-completion)  ; vertico / consult / corfu
(require 'init-dev)         ; projects, git, eglot, tree-sitter
(require 'init-remote)      ; remote editing: tramp-rpc

(dolist (lang my/languages)
  (require (intern (format "lang-%s" lang))))

(require 'init-agent)       ; agent terminal sessions, agent -> Emacs bridge

;; Restore normal GC settings once startup finishes.
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 64 1024 1024)
                  gc-cons-percentage 0.1)))

;;; init.el ends here
