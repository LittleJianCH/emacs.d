;;; lang-nix.el --- Nix development environment -*- lexical-binding: t; -*-

;;; Commentary:

;; nix-mode + Eglot/nil.  Install nil for completion and diagnostics, and
;; nixfmt for formatting on save.  Syntax editing works without either tool.
;; Project-specific nil settings belong in eglot-workspace-configuration.

;;; Code:

(require 'subr-x)
(require 'init-env)

(defvar-local my/nix-format-configured nil)

(declare-function eglot-ensure "eglot")
(declare-function my/eglot-format-on-save "init-dev")
(defvar eglot-server-programs)
(defvar eglot-workspace-configuration)

(defcustom my/nil-command '("nil")
  "Command used to start the nil Nix language server."
  :type '(repeat string)
  :group 'tools)

(defun my/nil-contact (&rest _)
  "Return the latest nil command for Eglot."
  my/nil-command)

(defun my/nix-setup ()
  "Set up indentation, nil and optional nixfmt formatting."
  (require 'eglot)
  (setq-local indent-tabs-mode nil)
  (when (and (not my/nix-format-configured) (executable-find "nixfmt"))
    ;; Preserve project configuration, including function-valued settings.
    (when (and (listp eglot-workspace-configuration)
               (not (plist-member eglot-workspace-configuration :nil)))
      (setq-local eglot-workspace-configuration
                  (plist-put (copy-tree eglot-workspace-configuration)
                             :nil '(:formatting (:command ["nixfmt"])))))
    (my/eglot-format-on-save)
    (setq-local my/nix-format-configured t))
  (if (and (car my/nil-command)
           (executable-find (car my/nil-command)))
      (eglot-ensure)
    (message "未找到 Nix 语言服务器；安装 nil 后可启用补全和诊断")))

(use-package nix-mode
  :ensure t
  :mode "\\.nix\\'"
  :hook (nix-mode . my/nix-setup))

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs '(nix-mode . my/nil-contact)))


(defun my/nix-environment-ready ()
  "Reconnect Nix tooling after the project environment becomes available."
  (when (derived-mode-p 'nix-mode)
    (my/nix-setup)))

(add-hook 'my/environment-ready-hook #'my/nix-environment-ready)

(provide 'lang-nix)
;;; lang-nix.el ends here
