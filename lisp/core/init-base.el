;;; init-base.el --- Basic behavior -*- lexical-binding: t; -*-

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

;;; Keep state files together under var/, out of git

(defconst my/var-dir (expand-file-name "var/" user-emacs-directory))
(dolist (dir '("" "backups/" "auto-save/"))
  (make-directory (expand-file-name dir my/var-dir) t))

(defun my/var (name)
  "Return the full path of NAME under var/."
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
      tramp-persistency-file-name (my/var "tramp")
      custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror 'nomessage)

;;; Common built-in modes

(delete-selection-mode 1)
(show-paren-mode 1)
(electric-pair-mode 1)
(column-number-mode 1)
(savehist-mode 1)
(save-place-mode 1)
(setq recentf-max-saved-items 200)
(recentf-mode 1)
(repeat-mode 1)

;; Agents modify files externally, so buffers must refresh promptly;
;; non-file buffers (dired etc.) are refreshed too.
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

;; When the GUI is launched from the Dock, inherit PATH from a login shell
;; so claude / codex / rg can be found.
(use-package exec-path-from-shell
  :ensure t
  :if (or (daemonp) (memq window-system '(mac ns x)))
  :custom
  (exec-path-from-shell-arguments '("-l"))
  (exec-path-from-shell-variables '("PATH" "MANPATH"))
  :config
  (exec-path-from-shell-initialize))

;;; Vim keybinding toggle

(defcustom my/use-evil nil
  "Non-nil means load evil (Vim keys, see init-evil.el) at startup.
nil means use the native Emacs keybindings.  Toggle it in a running
session with `my/toggle-evil'."
  :type 'boolean
  :group 'convenience)

(defun my/toggle-evil (&optional save)
  "Turn evil on or off in the current Emacs.
With SAVE (prefix argument), also save the new state as the default
for future sessions."
  (interactive "P")
  (let ((on (not (bound-and-true-p evil-mode))))
    (if on
        (if (featurep 'init-evil) (evil-mode 1) (require 'init-evil))
      (evil-mode -1))
    (setq my/use-evil on)
    (when save (customize-save-variable 'my/use-evil on))
    (message "evil 已%s%s" (if on "开启" "关闭") (if save "，并保存为默认" ""))))

;;; Convenience commands

(defun my/open-init-file ()
  "Open init.el in the config directory."
  (interactive)
  (find-file (expand-file-name "init.el" user-emacs-directory)))
(keymap-global-set "C-c i" #'my/open-init-file)

(provide 'init-base)
;;; init-base.el ends here
