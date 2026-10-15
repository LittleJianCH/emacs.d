;;; lang-rust.el --- Rust development environment -*- lexical-binding: t; -*-

;;; Commentary:

;; rust-ts-mode (built in) + eglot/rust-analyzer + cargo commands.
;;
;; Keys in rust-ts-mode:
;;   C-c C-c  pick and run a cargo subcommand (check / clippy / test / run ...)
;;   C-c C-t  run the test function at point
;;   C-c C-r  cargo run
;;   C-c C-k  rerun the last cargo command

;;; Code:

(require 'project)
(require 'treesit)

(defcustom my/rust-analyzer-command '("rust-analyzer")
  "Command used to start rust-analyzer.
If the default toolchain is unavailable, change it to
\(\"rustup\" \"run\" \"stable\" \"rust-analyzer\")."
  :type '(repeat string)
  :group 'tools)

(defcustom my/rust-analyzer-options
  '(:check (:command "clippy")
    :cargo (:buildScripts (:enable t))
    :procMacro (:enable t)
    :inlayHints (:closureReturnTypeHints (:enable "with_block")
                 :lifetimeElisionHints (:enable "skip_trivial")))
  "The initializationOptions passed to rust-analyzer."
  :type 'sexp
  :group 'tools)

;;; cargo

(defvar my/cargo-history '("check" "clippy --all-targets" "test" "build" "run" "fmt")
  "History of cargo subcommands.")

(defun my/cargo-root ()
  "Return the outermost Cargo workspace root.
Prefer the project root; fall back to the nearest Cargo.toml."
  (or (when-let* ((project (project-current))
                  (root (project-root project)))
        (and (file-exists-p (expand-file-name "Cargo.toml" root)) root))
      (locate-dominating-file default-directory "Cargo.toml")
      (user-error "不在 Cargo 项目中")))

(defun my/cargo (command)
  "Run cargo COMMAND in the workspace root."
  (interactive
   (list (completing-read "cargo " my/cargo-history nil nil nil
                          'my/cargo-history (car my/cargo-history))))
  (let ((default-directory (my/cargo-root)))
    (compile (concat "cargo " command))))

(defun my/cargo-run ()
  "Run cargo run."
  (interactive)
  (my/cargo "run"))

(defun my/cargo-test-at-point ()
  "Run the test for the function at point."
  (interactive)
  (let* ((node (treesit-defun-at-point))
         (name (and node (treesit-defun-name node))))
    (unless name (user-error "光标不在函数内"))
    (my/cargo (format "test %s -- --nocapture" name))))

;;; Mode

(defun my/rust-ts-drop-error-face ()
  "Don't paint tree-sitter parse errors with `font-lock-warning-face'.
The rule overrides every other face inside an ERROR node, and syntax the
grammar doesn't know yet (nightly `impl [const] Trait' in core, for one)
wraps the whole file in one, leaving it a single color.  rust-analyzer
reports real syntax errors through eglot anyway."
  (treesit-font-lock-recompute-features nil '(error)))

(use-package rust-ts-mode
  :mode "\\.rs\\'"
  :hook ((rust-ts-mode . eglot-ensure)
         (rust-ts-mode . my/eglot-format-on-save)
         (rust-ts-mode . my/rust-ts-drop-error-face))
  :bind (:map rust-ts-mode-map
         ("C-c C-c" . my/cargo)
         ("C-c C-t" . my/cargo-test-at-point)
         ("C-c C-r" . my/cargo-run)
         ("C-c C-k" . recompile)))

(defun my/rust-analyzer-contact (&rest _)
  "Return the latest rust-analyzer command and options.
Called by eglot each time it connects to rust-analyzer."
  `(,@my/rust-analyzer-command :initializationOptions ,my/rust-analyzer-options))

(defvar eglot-server-programs)
(defvar eglot-server-programs)
(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((rust-ts-mode rust-mode) . my/rust-analyzer-contact)))

;; Cargo.toml / Cargo.lock
(use-package toml-ts-mode
  :mode ("Cargo\\.lock\\'" . toml-ts-mode))

(provide 'lang-rust)
;;; lang-rust.el ends here
