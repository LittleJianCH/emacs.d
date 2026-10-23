;;; lang-coq.el --- Coq proof development -*- lexical-binding: t; -*-

;;; Commentary:

;; Proof General owns syntax, _CoqProject handling and the proof process.
;; Load only its site bootstrap here; proof processing remains user-driven.
;; Native Proof General keys remain available:
;;   C-c C-n      process the next command
;;   C-c C-u      undo the last command
;;   C-c C-RET    process or retract to point
;;   C-c C-b      process the buffer
;;   C-c C-r      retract the buffer
;; Evil users also have these operations under SPC m.

;;; Code:

(require 'init-env)

(declare-function envrc-propagate-environment "envrc")
(declare-function coq-mode "coq")
(declare-function evil-define-key* "evil-core")
(defvar coq-mode-map)

(defun my/coq-start-with-environment (original &rest args)
  "Call ORIGINAL with ARGS using Coq's ready project environment.
Proof General creates its process in another buffer, so propagate the
calling buffer's environment rather than the global shell environment."
  (if (derived-mode-p 'coq-mode)
      (progn
        (unless (my/environment-ready-p)
          (user-error "Coq 项目环境尚未就绪；请等待加载完成或运行 M-x envrc-allow"))
        (apply #'envrc-propagate-environment original args))
    (apply original args)))

(use-package proof-site
  :ensure proof-general
  :demand t)

(defun my/coq-mode ()
  "Load Proof General's entry point, then enable its Coq mode."
  (interactive)
  (require 'proof-site)
  (coq-mode))

;; PG installs an ordinary coq-mode function at package startup.  Use our
;; own entry point so the lazy loader can still load this module first.
(add-to-list 'auto-mode-alist '("\\.v\\'" . my/coq-mode))

(with-eval-after-load 'proof-shell
  (advice-add 'proof-shell-start :around #'my/coq-start-with-environment))

(defvar-keymap my/coq-command-map
  :doc "Coq commands under the Evil major-mode leader."
  "n" 'proof-assert-next-command-interactive
  "u" 'proof-undo-last-successful-command
  "p" 'proof-goto-point
  "b" 'proof-process-buffer
  "r" 'proof-retract-buffer
  "R" 'proof-shell-restart
  "q" 'proof-shell-exit)

(with-eval-after-load 'evil
  (with-eval-after-load 'coq
    (evil-define-key* '(normal motion visual) coq-mode-map
      (kbd "<leader>m") my/coq-command-map)))

(provide 'lang-coq)
;;; lang-coq.el ends here
