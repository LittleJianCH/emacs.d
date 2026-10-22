;;; init.el --- Emacs config for working with coding agents -*- lexical-binding: t; -*-

;;; Commentary:

;; Layout:
;;   lisp/core/   base layer: defaults, UI, completion, general dev tools
;;   lisp/lang/   language modules, one file per language: lang-NAME.el
;;   lisp/agent/  shared agent UI and bridge; backend/ holds individual agents
;;   lisp/app/    standalone applications, such as the Telegram client
;;
;; To add a language: create lisp/lang/lang-NAME.el (ending with `provide'),
;; then add NAME to `my/languages'; an app goes in lisp/app/init-NAME.el and
;; `my/apps'.  A module listed in `my/lazy-modules' (lisp/core/init-lazy.el)
;; with its triggers loads, and installs its packages, only on first use.
;; Agent registrations live in lisp/agent/backend/; all execute via emx.
;; `my/agents' selects enabled agents.

;;; Code:

(when (version< emacs-version "30.1")
  (error "这份配置需要 Emacs 30.1 或更新版本"))

(dolist (dir '("core" "lang" "agent" "agent/backend" "app"))
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

(defvar my/languages '(elisp rust go nix agda haskell coq lean)
  "Enabled language modules, each loaded from lisp/lang/lang-NAME.el.
Most load on first visiting one of their files; see `my/lazy-modules'.")

(defvar my/apps '(telega)
  "Enabled applications, each loaded from lisp/app/init-NAME.el on first use.")

(defvar my/agents '(claude codex dsh pi)
  "Enabled daemon agent registrations, loaded from lisp/agent/backend/agent-NAME.el.")

(require 'init-base)        ; defaults, paths, macOS environment
(require 'init-reload)      ; M-x my/reload-config: apply edited files, no restart
(require 'init-ui)          ; theme, fonts, windows
(when my/use-evil
  (require 'init-evil))     ; Vim keys (evil), off by default; M-x my/toggle-evil
(require 'init-completion)  ; vertico / consult / corfu
(require 'init-dev)         ; projects, git, eglot, tree-sitter
(require 'init-remote)      ; remote editing: tramp-rpc
(require 'init-term)        ; terminals: ghostel, C-c t

(require 'init-lazy)        ; optional modules, loaded on first use
(dolist (lang my/languages)
  (my/lazy-require (intern (format "lang-%s" lang))))

(require 'init-agent)       ; agent sessions, agent -> Emacs bridge
(dolist (app my/apps)       ; telega: Telegram client, C-c T
  (my/lazy-require (intern (format "init-%s" app))))

;; Restore normal GC settings once startup finishes.
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 64 1024 1024)
                  gc-cons-percentage 0.1)))

;;; init.el ends here
