;;; init-base.el --- 基础行为 -*- lexical-binding: t; -*-

(setq inhibit-startup-screen t
      initial-scratch-message nil
      use-short-answers t
      ring-bell-function #'ignore
      make-backup-files t
      backup-by-copying t
      version-control t
      kept-new-versions 5
      kept-old-versions 2
      delete-old-versions t
      create-lockfiles nil
      scroll-conservatively 101
      scroll-margin 3
      read-process-output-max (* 1024 1024)
      sentence-end-double-space nil
      require-final-newline t)

(setq-default indent-tabs-mode nil
              tab-width 4
              fill-column 88)
(prefer-coding-system 'utf-8-unix)

;;; 状态文件集中在 var/，不进 git

(defconst my/var-dir (expand-file-name "var/" user-emacs-directory))
(dolist (dir '("" "backups/" "auto-save/"))
  (make-directory (expand-file-name dir my/var-dir) t))

(defun my/var (name)
  "返回 var/ 下 NAME 的完整路径。"
  (expand-file-name name my/var-dir))

(setq backup-directory-alist `(("." . ,(my/var "backups/")))
      auto-save-file-name-transforms `((".*" ,(my/var "auto-save/") t))
      auto-save-list-file-prefix (my/var "auto-save/.saves-")
      recentf-save-file (my/var "recentf")
      savehist-file (my/var "history")
      save-place-file (my/var "places")
      bookmark-default-file (my/var "bookmarks")
      project-list-file (my/var "projects")
      transient-history-file (my/var "transient/history.el")
      transient-levels-file (my/var "transient/levels.el")
      transient-values-file (my/var "transient/values.el")
      url-configuration-directory (my/var "url/")
      custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror 'nomessage)

;;; 常用内置模式

(delete-selection-mode 1)
(show-paren-mode 1)
(electric-pair-mode 1)
(column-number-mode 1)
(savehist-mode 1)
(save-place-mode 1)
(setq recentf-max-saved-items 200)
(recentf-mode 1)
(repeat-mode 1)

;; agent 在外部改文件，buffer 需要及时刷新；非文件 buffer（dired 等）也一起刷新。
(setq auto-revert-interval 1
      auto-revert-avoid-polling t
      auto-revert-check-vc-info t
      global-auto-revert-non-file-buffers t
      auto-revert-verbose nil)
(global-auto-revert-mode 1)

(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'prog-mode-hook #'hl-line-mode)
(add-hook 'text-mode-hook #'visual-line-mode)

;;; macOS

;; 图形界面从 Dock 启动时继承登录 shell 的 PATH，才能找到 claude / codex / rg。
(use-package exec-path-from-shell
  :ensure t
  :if (or (daemonp) (memq window-system '(mac ns x)))
  :custom
  (exec-path-from-shell-arguments '("-l"))
  (exec-path-from-shell-variables '("PATH" "MANPATH"))
  :config
  (exec-path-from-shell-initialize))

;;; 便捷命令

(defun my/open-init-file ()
  "打开配置目录。"
  (interactive)
  (find-file (expand-file-name "init.el" user-emacs-directory)))
(keymap-global-set "C-c i" #'my/open-init-file)

(provide 'init-base)
;;; init-base.el ends here
