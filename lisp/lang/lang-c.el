;;; lang-c.el --- C and C++ development environment -*- lexical-binding: t; -*-

;;; Commentary:

;; Built-in tree-sitter modes when their grammars are ready, otherwise CC
;; Mode.  The wrappers never install grammars.  Clangd is optional and
;; starts only after globalized environment modes and project setup finish.

;;; Code:

(require 'treesit)
(require 'init-env)

(declare-function eglot-ensure "eglot")
(declare-function eglot-managed-p "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function evil-define-key* "evil-core")
(declare-function my/c-evil-keys "lang-c")
(defvar eglot-server-programs)

(defcustom my/clangd-command '("clangd" "--background-index")
  "Command used to start clangd in the current project environment.
This can be buffer-local, for example in .dir-locals.el."
  :type '(repeat string)
  :group 'tools)

(defvar-local my/c--mode-ready nil
  "Whether globalized minor modes have finished starting in this buffer.")

(defvar-local my/c--keys-configured nil
  "Whether this buffer has its own C/C++ command map.")

(defun my/c--buffer-p ()
  "Return non-nil only for the supported C and C++ major modes."
  (memq major-mode '(c-mode c++-mode c-ts-mode c++-ts-mode)))

(defun my/c--activate (cpp)
  "Activate C++ when CPP is non-nil, otherwise C, without installing grammars."
  ;; In Emacs 30.1 and 31 the shared base creates no parser: each final
  ;; language mode creates its own.  Only the generic header remap checks
  ;; both grammars, which our standard content heuristic does not need.
  (let ((languages (if cpp '(cpp) '(c)))
        (treesit-auto-install-grammar nil))
    (if (treesit-ready-p languages t)
        (if cpp (c++-ts-mode) (c-ts-mode))
      (if cpp (c++-mode) (c-mode)))))

(defun my/c-mode ()
  "Edit C with an available built-in syntax mode."
  (interactive)
  ;; On case-insensitive filesystems Emacs matches .C against the .c rule.
  (my/c--activate (and buffer-file-name
                      (equal (file-name-extension
                              (file-name-sans-versions buffer-file-name))
                             "C"))))

(defun my/c++-mode ()
  "Edit C++ with an available built-in syntax mode."
  (interactive)
  ;; Likewise the C++ .H alternative can match a lowercase .h on macOS.
  (if (and buffer-file-name
           (equal (file-name-extension
                   (file-name-sans-versions buffer-file-name)) "h"))
      (my/c-or-c++-mode)
    (my/c--activate t)))

(defun my/c-or-c++-mode ()
  "Use Emacs's header content heuristics to select the final C or C++ mode."
  (interactive)
  ;; Let the standard heuristic call the final mode once.  Do not initialize
  ;; CC Mode, run its tooling hooks, and then switch to a tree-sitter mode.
  (let ((major-mode-remap-alist
         (cons (cons 'c++-mode (lambda () (my/c--activate t)))
               (cons '(c-mode . my/c-mode) major-mode-remap-alist))))
    ;; Use a direct C++ activation in the heuristic to avoid redispatching .h.
    (if (and buffer-file-name
             (equal (file-name-extension
                     (file-name-sans-versions buffer-file-name)) "H"))
        (my/c--activate t)
      (c-or-c++-mode))))

(defun my/clangd-contact (&rest _)
  "Return the current clangd command after checking the actual environment.
Eglot calls this at connection time, after its deferred startup hook."
  (unless (my/environment-ready-p)
    (user-error "项目环境尚未就绪；环境加载完成后会重试 C/C++ 工具"))
  (unless (and (car my/clangd-command)
               (executable-find (car my/clangd-command) t))
    (user-error "未找到 C/C++ 语言服务器；请安装 clangd 或设置 my/clangd-command"))
  my/clangd-command)

(defun my/c-format-on-save ()
  "Format this buffer only while Eglot manages it."
  (when (and (fboundp 'eglot-managed-p) (eglot-managed-p))
    (eglot-format-buffer)))

(defun my/c--finish-startup ()
  "Allow retries after Eglot has run its deferred connection attempt."
  (remove-hook 'post-command-hook #'my/c--finish-startup t))

(defun my/c--ensure-tools ()
  "Schedule Eglot only in a ready C/C++ file buffer with an available server."
  (when (and (my/c--buffer-p) my/c--mode-ready buffer-file-name
             (not (memq #'my/c--finish-startup post-command-hook))
             (my/environment-ready-p)
             (car my/clangd-command)
             (executable-find (car my/clangd-command) t))
    (require 'eglot)
    (unless (eglot-managed-p)
      (eglot-ensure)
      ;; Mode completion, local variables and envrc may all notify us before
      ;; the first command.  Eglot's closures alone do not deduplicate these.
      (add-hook 'post-command-hook #'my/c--finish-startup 99 t))))

(defun my/c-after-major-mode ()
  "Start C/C++ tools after globalized environment modes have started."
  (when (my/c--buffer-p)
    (setq-local my/c--mode-ready t)
    (my/c--ensure-tools)))

(defun my/c-setup ()
  "Install buffer-local C/C++ commands and an idempotent save hook."
  (when (my/c--buffer-p)
    ;; Some C-like modes inherit C maps.  Keep these commands in the exact
    ;; modes we support, and preserve keys already installed by other hooks.
    (unless my/c--keys-configured
      (use-local-map (copy-keymap (current-local-map)))
      (keymap-local-set "C-c b" #'project-compile)
      (keymap-local-set "C-c k" #'recompile)
      (keymap-local-set "C-c o" #'ff-find-other-file)
      (setq-local my/c--keys-configured t))
    (when (fboundp 'my/c-evil-keys) (my/c-evil-keys))
    (add-hook 'before-save-hook #'my/c-format-on-save nil t)
    ;; A project can select a server that was absent from the initial PATH,
    ;; or override the command after mode initialization has already run.
    (add-hook 'hack-local-variables-hook #'my/c--ensure-tools nil t)
    (add-hook 'my/environment-ready-hook #'my/c--ensure-tools nil t)))

(use-package cc-mode
  :ensure nil
  :demand t
  :mode (("\\.c\\'" . my/c-mode)
         ("\\.\\(?:cc\\|cpp\\|cxx\\|c\\+\\+\\|C\\|hh\\|hpp\\|hxx\\|h\\+\\+\\|H\\|ipp\\|inl\\|tpp\\|ixx\\|cppm\\)\\'"
          . my/c++-mode)
         ("\\.h\\'" . my/c-or-c++-mode))
  :hook ((c-mode . my/c-setup)
         (c++-mode . my/c-setup)))

(use-package c-ts-mode
  :ensure nil
  :defer t
  :hook ((c-ts-mode . my/c-setup)
         (c++-ts-mode . my/c-setup)))

;; Mode hooks precede globalized minor mode activation (notably envrc).
;; The callback may fire during that activation; `my/c--mode-ready' gates it.
(add-hook 'after-change-major-mode-hook #'my/c-after-major-mode 90)

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((c-mode c++-mode c-ts-mode c++-ts-mode) . my/clangd-contact)))

(defvar-keymap my/c-command-map
  :doc "C/C++ commands under the language leader, next to Eglot's."
  "c" #'project-compile
  "k" #'recompile
  "o" #'ff-find-other-file)

(with-eval-after-load 'evil
  (defun my/c-evil-keys ()
    "Bind the C/C++ leader in this buffer without affecting native keys."
    (evil-define-key* '(normal motion visual) (current-local-map)
      (kbd "<leader>l") my/c-command-map))
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (my/c--buffer-p) my/c--keys-configured)
        (my/c-evil-keys)))))

(provide 'lang-c)
;;; lang-c.el ends here
