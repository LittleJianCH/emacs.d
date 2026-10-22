;;; lang-haskell.el --- Haskell editing and GHCi -*- lexical-binding: t; -*-

;;; Commentary:

;; haskell-mode supplies indentation, Cabal editing and an on-demand GHCi.
;; HLS supplies completion, diagnostics and formatting through Eglot.
;; Install GHC and haskell-language-server with GHCup or a project environment.
;; C-c C-l loads the file, C-c C-z opens GHCi, C-c C-t queries a type.

;;; Code:

(require 'init-env)

(declare-function eglot-ensure "eglot")
(declare-function my/eglot-format-on-save "init-dev")
(declare-function haskell-indentation-mode "haskell-indentation")
(declare-function interactive-haskell-mode "haskell")
(declare-function evil-define-key* "evil-core")
(declare-function my/haskell-evil-keys "lang-haskell")
(defvar eglot-server-programs)
(defvar haskell-mode-map)
(defvar-local my/haskell-format-configured nil)

(defcustom my/haskell-server-command '("haskell-language-server-wrapper" "--lsp")
  "Command used to start the Haskell language server."
  :type '(repeat string)
  :group 'tools)

(defun my/haskell-contact (&rest _)
  "Return the current Haskell language server command for Eglot."
  ;; Eglot connects on the next command, when direnv may have refreshed.
  (unless (my/environment-ready-p)
    (user-error "Haskell 项目环境尚未就绪；请等待加载完成或允许项目环境"))
  my/haskell-server-command)

(defun my/haskell-start-eglot ()
  "Start HLS only after this buffer's project environment is ready."
  (when (my/environment-ready-p)
    (if (and (car my/haskell-server-command)
             (executable-find (car my/haskell-server-command)))
        (eglot-ensure)
      (message "未找到 Haskell 语言服务器；安装 haskell-language-server 后可启用补全和诊断"))))

(defun my/haskell-setup ()
  "Enable Haskell indentation, GHCi commands and optional HLS support."
  (setq-local indent-tabs-mode nil)
  (haskell-indentation-mode 1)
  ;; This enables commands without starting a GHCi subprocess.
  (interactive-haskell-mode 1)
  (unless my/haskell-format-configured
    (my/eglot-format-on-save)
    (setq-local my/haskell-format-configured t)))

(use-package haskell-mode
  :ensure t
  :mode (("\\.hs\\'" . haskell-mode)
         ("\\.lhs\\'" . haskell-literate-mode)
         ("\\.cabal\\'" . haskell-cabal-mode))
  :hook (haskell-mode . my/haskell-setup))

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((haskell-mode haskell-literate-mode) . my/haskell-contact)))

(defun my/haskell-environment-ready ()
  "Connect HLS when a Haskell buffer receives its project environment."
  (when (derived-mode-p 'haskell-mode)
    (my/haskell-start-eglot)))

(add-hook 'my/environment-ready-hook #'my/haskell-environment-ready)
;; Globalized envrc starts after the language mode hook.  Run after it,
;; including for buffers where envrc decides not to enable itself.
(add-hook 'after-change-major-mode-hook #'my/haskell-environment-ready 90)

(defvar-keymap my/haskell-command-map
  :doc "Haskell commands under the major-mode leader."
  "l" 'haskell-process-load-file
  "r" 'haskell-process-reload
  "z" 'haskell-interactive-switch
  "t" 'haskell-process-do-type
  "i" 'haskell-process-do-info
  "b" 'haskell-process-cabal-build)

(with-eval-after-load 'evil
  (defun my/haskell-evil-keys ()
    "Install Haskell's major-mode leader in Evil command states."
    (evil-define-key* '(normal motion visual) haskell-mode-map
      (kbd "<leader>m") my/haskell-command-map))
  (with-eval-after-load 'haskell-mode
    (my/haskell-evil-keys)))

(provide 'lang-haskell)
;;; lang-haskell.el ends here
