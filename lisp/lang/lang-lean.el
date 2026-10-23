;;; lang-lean.el --- Lean 4 proofs and goal view -*- lexical-binding: t; -*-

;;; Commentary:

;; Lean's maintained mode uses lsp-mode for its goal view and semantic tokens.
;; Keep that client local to Lean; other languages continue to use Eglot.
;; The upstream VC package includes the data/ directory for Unicode input.
;; Install Lean 4 and Lake with elan or a project environment.
;; C-c C-i toggles goals, C-c C-d refreshes imports, C-c C-p C-l builds.

;;; Code:

(require 'init-env)

(declare-function lsp "lsp-mode")
(declare-function lean4-get-executable "lean4-util")
(declare-function evil-define-key* "evil-core")
(declare-function my/lean-evil-keys "lang-lean")
(defvar lean4-rootdir)
(defvar lean4-mode-hook)
(defvar lean4-mode-map)
(defvar lean4-executable-name)
(defvar lsp-completion-provider)
(defvar lsp-diagnostics-provider)
(defvar lsp-enable-snippet)

(defun my/lean-start-lsp ()
  "Connect Lean after the project environment and executable are ready."
  (when (and (my/environment-ready-p) (not (bound-and-true-p lsp-mode)))
    (if (condition-case nil
            (file-executable-p (lean4-get-executable lean4-executable-name))
          (error nil))
        ;; Start now: a deferred command could outlive this environment.
        (lsp)
      (message "未找到 Lean 4；安装 elan 工具链后可启用目标窗口和诊断"))))

(defun my/lean-setup ()
  "Use existing completion and Flymake UI for this Lean buffer."
  (setq-local indent-tabs-mode nil
              lsp-completion-provider :capf
              lsp-diagnostics-provider :flymake
              lsp-enable-snippet nil))

(defun my/lean-uncached-rootdir (original &rest args)
  "Call ORIGINAL with ARGS without caching a project's toolchain globally."
  ;; Upstream returns its detected root but also saves it in lean4-rootdir.
  ;; Keep explicit user settings, and discard only automatic detection.
  (let ((lean4-rootdir nil))
    (apply original args)))

(use-package lean4-mode
  :vc (:url "https://github.com/leanprover-community/lean4-mode.git"
       :rev :last-release)
  :commands (lean4-mode lean4-select-mode)
  :mode ("\\.lean\\'" . lean4-select-mode)
  :hook (lean4-mode . my/lean-setup)
  :config
  ;; Upstream starts LSP unconditionally; wait for async direnv instead.
  (remove-hook 'lean4-mode-hook #'lsp)
  (advice-add 'lean4-setup-rootdir :around #'my/lean-uncached-rootdir))

(defun my/lean-environment-ready ()
  "Connect Lean when a buffer receives its project environment."
  (when (derived-mode-p 'lean4-mode)
    (my/lean-start-lsp)))

(add-hook 'my/environment-ready-hook #'my/lean-environment-ready)
(add-hook 'after-change-major-mode-hook #'my/lean-environment-ready 90)

(defvar-keymap my/lean-command-map
  :doc "Lean commands under the major-mode leader."
  "i" 'lean4-toggle-info
  "d" 'lean4-refresh-file-dependencies
  "b" 'lean4-lake-build
  "l" 'lean4-std-exe
  "r" 'lsp-workspace-restart)

(with-eval-after-load 'evil
  (defun my/lean-evil-keys ()
    "Install Lean's major-mode leader in Evil command states."
    (evil-define-key* '(normal motion visual) lean4-mode-map
      (kbd "<leader>m") my/lean-command-map))
  (with-eval-after-load 'lean4-mode
    (my/lean-evil-keys)))

(provide 'lang-lean)
;;; lang-lean.el ends here
