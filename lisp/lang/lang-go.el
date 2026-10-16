;;; lang-go.el --- Go development environment -*- lexical-binding: t; -*-

;;; Commentary:

;; go-ts-mode (built in) + eglot/gopls + go commands.  Saving a buffer
;; organizes imports and formats it through gopls.
;;
;; Keys in go-ts-mode:
;;   C-c C-c    pick and run a go subcommand (build / vet / test / run ...)
;;   C-c C-r    go run .
;;   C-c C-k    rerun the last go command
;;   C-c C-t t  run the test at point (built in; C-c C-t f file, C-c C-t p package)
;;   C-c C-d    insert a doc comment for the declaration at point (built in)

;;; Code:

(require 'treesit)

(declare-function eglot-code-actions "eglot")
(declare-function eglot-current-server "eglot")
(declare-function eglot-execute "eglot")
(declare-function eglot-managed-p "eglot")
(defvar go-ts-mode-indent-offset)

(defcustom my/gopls-command '("gopls")
  "Command used to start gopls."
  :type '(repeat string)
  :group 'tools)

(defcustom my/gopls-options
  '(:hints (:parameterNames t
            :rangeVariableTypes t
            :constantValues t))
  "The initializationOptions passed to gopls.
Per-project settings belong in `eglot-workspace-configuration'."
  :type 'sexp
  :group 'tools)

;;; go commands

(defvar my/go-history '("build ./..." "vet ./..." "test ./..." "run ." "mod tidy")
  "History of go subcommands.")

(defun my/go-module-root ()
  "Return the directory of the nearest go.mod, else `default-directory'."
  (or (locate-dominating-file default-directory "go.mod")
      default-directory))

(defun my/go (command)
  "Run go COMMAND in the module root."
  (interactive
   (list (completing-read "go " my/go-history nil nil nil
                          'my/go-history (car my/go-history))))
  (let ((default-directory (my/go-module-root)))
    (compile (concat "go " command))))

(defun my/go-run ()
  "Run the package in the current directory."
  (interactive)
  (compile "go run ."))

;;; Mode

(defun my/go-organize-imports ()
  "Apply gopls's organize-imports action, if it offers one."
  (when-let* (((and (fboundp 'eglot-managed-p) (eglot-managed-p)))
              (action (car (eglot-code-actions (point-min) (point-max)
                                               "source.organizeImports"))))
    (eglot-execute (eglot-current-server) action)))

(defun my/go-setup ()
  "Set up a Go buffer: indentation and import organizing on save."
  ;; gofmt indents with one tab per level; go-ts-mode's 8-column offset
  ;; would insert two tabs per level with a 4-column `tab-width'.
  (setq-local go-ts-mode-indent-offset tab-width)
  ;; Depth -10: organize imports before `my/eglot-format-on-save' formats.
  (add-hook 'before-save-hook #'my/go-organize-imports -10 t))

(use-package go-ts-mode
  :mode (("\\.go\\'" . go-ts-mode)
         ("/go\\.mod\\'" . go-mod-ts-mode)
         ("/go\\.work\\'" . go-work-ts-mode))
  :hook (((go-ts-mode go-mod-ts-mode go-work-ts-mode) . eglot-ensure)
         (go-ts-mode . my/eglot-format-on-save)
         (go-ts-mode . my/go-setup))
  :bind (:map go-ts-mode-map
         ("C-c C-c" . my/go)
         ("C-c C-r" . my/go-run)
         ("C-c C-k" . recompile)))

(defun my/gopls-contact (&rest _)
  "Return the latest gopls command and options.
Called by eglot each time it connects to gopls."
  `(,@my/gopls-command :initializationOptions ,my/gopls-options))

(defvar eglot-server-programs)
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((go-ts-mode go-mod-ts-mode go-work-ts-mode go-mode)
                 . my/gopls-contact)))

(provide 'lang-go)
;;; lang-go.el ends here
