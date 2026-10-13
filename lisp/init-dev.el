;;; init-dev.el --- 项目、git、语言服务 -*- lexical-binding: t; -*-

(use-package project
  :custom
  (project-switch-commands '((project-find-file "Find file" ?f)
                             (consult-ripgrep "Ripgrep" ?r)
                             (project-dired "Dired" ?d)
                             (magit-project-status "Magit" ?m))))

;;; Git：审查 agent 的改动主要靠这两个

(use-package magit
  :ensure t
  :bind (("C-x g" . magit-status))
  :custom
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1)
  (magit-diff-refine-hunk 'all))

;; 行号旁的改动标记，agent 改了哪里一眼可见。
(use-package diff-hl
  :ensure t
  :demand t
  :hook ((magit-pre-refresh . diff-hl-magit-pre-refresh)
         (magit-post-refresh . diff-hl-magit-post-refresh)
         (dired-mode . diff-hl-dired-mode))
  :config
  (global-diff-hl-mode 1)
  (diff-hl-flydiff-mode 1))

(use-package ediff
  :custom
  (ediff-window-setup-function #'ediff-setup-windows-plain)
  (ediff-split-window-function #'split-window-horizontally))

;;; 语言服务与诊断

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

(use-package flymake
  :bind (:map flymake-mode-map
         ("M-g n" . flymake-goto-next-error)
         ("M-g p" . flymake-goto-prev-error)))

;; 优先使用 tree-sitter 模式（Emacs 31）；缺少语法时询问后自动安装到 tree-sitter/。
(use-package treesit
  :custom
  (treesit-font-lock-level 4)
  (treesit-enabled-modes t)
  (treesit-auto-install-grammar 'ask))

;;; 文档

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
