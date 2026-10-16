;;; init-dev.el --- Projects, git, language servers -*- lexical-binding: t; -*-

(use-package project
  :custom
  (project-switch-commands '((project-find-file "Find file" ?f)
                             (consult-ripgrep "Ripgrep" ?r)
                             (project-dired "Dired" ?d)
                             (magit-project-status "Magit" ?m))))

;;; Git: the main tools for reviewing agent changes

(use-package magit
  :ensure t
  :bind (("C-x g" . magit-status))
  :custom
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1)
  (magit-diff-refine-hunk 'all))

;; Change markers next to line numbers show at a glance what an agent changed.
(use-package diff-hl
  :ensure t
  :demand t
  :hook (dired-mode . diff-hl-dired-mode)
  :config
  (global-diff-hl-mode 1)
  (diff-hl-flydiff-mode 1))

(use-package ediff
  :custom
  (ediff-window-setup-function #'ediff-setup-windows-plain)
  (ediff-split-window-function #'split-window-horizontally))

;;; Language servers and diagnostics

(use-package eglot
  :commands (eglot eglot-ensure)
  :bind (("C-c e" . eglot)
         :map eglot-mode-map
         ("C-c l a" . eglot-code-actions)
         ("C-c l r" . eglot-rename)
         ("C-c l f" . eglot-format-buffer))
  :custom
  (eglot-autoshutdown t)
  (eglot-events-buffer-config '(:size 0)))

;; Show eldoc (hover, signature) in a child frame next to point.  Its look, a
;; padded card in the status-line band color, comes from the theme
;; (init-theme.el) and init-ui.el.
(use-package eldoc-box
  :ensure t
  ;; Review buffers ask the language server of the reviewed file.
  :hook ((eglot-managed-mode agent-review-mode) . eldoc-box-hover-at-point-mode)
  :custom
  (eldoc-box-max-pixel-width 800)
  (eldoc-box-max-pixel-height 600))

(defun my/eglot-format-on-save ()
  "Format the current buffer with the language server before saving.
Only takes effect when eglot is connected.  Language modules add this
to their own mode hooks."
  (add-hook 'before-save-hook
            (lambda ()
              (when (and (fboundp 'eglot-managed-p) (eglot-managed-p))
                (eglot-format-buffer)))
            nil t))

(use-package flymake
  :bind (:map flymake-mode-map
         ("M-g n" . flymake-goto-next-error)
         ("M-g p" . flymake-goto-prev-error)))

(use-package compile
  :custom
  (compilation-scroll-output 'first-error)
  (compilation-ask-about-save nil)
  :hook (compilation-filter . ansi-color-compilation-filter))

;; Prefer tree-sitter modes (Emacs 31); when a grammar is missing, ask and then
;; install it into tree-sitter/.
(use-package treesit
  :custom
  (treesit-font-lock-level 4)
  (treesit-enabled-modes t)
  (treesit-auto-install-grammar 'ask))

;;; Documents

(use-package markdown-mode
  :ensure t
  :mode (("README\\.md\\'" . gfm-mode))
  :custom
  (markdown-fontify-code-blocks-natively t))

(use-package org
  :custom
  (org-startup-indented t)
  (org-startup-with-inline-images t)
  (org-image-actual-width '(600))
  (org-hide-emphasis-markers t))

(provide 'init-dev)
;;; init-dev.el ends here
