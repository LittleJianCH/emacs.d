;;; lang-elisp.el --- Emacs Lisp development environment -*- lexical-binding: t; -*-

;;; Commentary:

;; Keys in emacs-lisp-mode:
;;   C-c C-b  eval-buffer
;;   C-c C-e  evaluate the previous sexp and pretty-print the result
;;   C-c C-m  expand the macro at point (macrostep, q to quit)
;;   C-c C-z  open IELM
;; Evil has them under SPC l: b, e, m, z and d (helpful at point).
;; C-h f / v / k / x use helpful instead, which shows source and references.

;;; Code:

(declare-function evil-define-key* "evil-core")

(defun my/elisp-setup ()
  "Common setup for Emacs Lisp buffers."
  ;; The byte-compile checker needs to find this config's modules.
  (setq-local elisp-flymake-byte-compile-load-path (cons "./" load-path))
  (when buffer-file-name
    (flymake-mode 1)))

(use-package elisp-mode
  :hook ((emacs-lisp-mode . my/elisp-setup))
  :bind (:map emacs-lisp-mode-map
         ("C-c C-b" . eval-buffer)
         ("C-c C-e" . pp-eval-last-sexp)
         ("C-c C-z" . ielm)
         :map lisp-interaction-mode-map
         ("C-c C-e" . pp-eval-last-sexp)))

(use-package macrostep
  :ensure t
  :bind (:map emacs-lisp-mode-map
         ("C-c C-m" . macrostep-expand)))

(use-package helpful
  :ensure t
  :bind (("C-h f" . helpful-callable)
         ("C-h v" . helpful-variable)
         ("C-h k" . helpful-key)
         ("C-h x" . helpful-command)
         :map emacs-lisp-mode-map
         ("C-c C-d" . helpful-at-point)))

(defvar-keymap my/elisp-command-map
  :doc "Emacs Lisp commands under the Evil language leader."
  "b" #'eval-buffer
  "e" #'pp-eval-last-sexp
  "m" 'macrostep-expand
  "z" #'ielm
  "d" 'helpful-at-point)

(defvar-keymap my/lisp-interaction-command-map
  :doc "*scratch* commands under the Evil language leader."
  "e" #'pp-eval-last-sexp)

(with-eval-after-load 'evil
  (evil-define-key* '(normal motion visual) emacs-lisp-mode-map
    (kbd "<leader>l") my/elisp-command-map)
  (evil-define-key* '(normal motion visual) lisp-interaction-mode-map
    (kbd "<leader>l") my/lisp-interaction-command-map))

(provide 'lang-elisp)
;;; lang-elisp.el ends here
