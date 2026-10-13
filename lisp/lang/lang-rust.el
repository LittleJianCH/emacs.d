;;; lang-rust.el --- Rust 开发环境 -*- lexical-binding: t; -*-

;;; Commentary:

;; rust-ts-mode（内置）+ eglot/rust-analyzer + cargo 命令。
;;
;; rust-ts-mode 中的按键：
;;   C-c C-c  选择并运行 cargo 子命令（check / clippy / test / run ...）
;;   C-c C-t  运行光标所在的测试函数
;;   C-c C-r  cargo run
;;   C-c C-k  重新运行上一次 cargo 命令

;;; Code:

(require 'project)
(require 'treesit)

(defcustom my/rust-analyzer-command '("rust-analyzer")
  "启动 rust-analyzer 的命令。
默认工具链不可用时，可改为 (\"rustup\" \"run\" \"stable\" \"rust-analyzer\")。"
  :type '(repeat string)
  :group 'tools)

(defcustom my/rust-analyzer-options
  '(:check (:command "clippy")
    :cargo (:buildScripts (:enable t))
    :procMacro (:enable t)
    :inlayHints (:closureReturnTypeHints (:enable "with_block")
                 :lifetimeElisionHints (:enable "skip_trivial")))
  "传给 rust-analyzer 的 initializationOptions。"
  :type 'sexp
  :group 'tools)

;;; cargo

(defvar my/cargo-history '("check" "clippy --all-targets" "test" "build" "run" "fmt")
  "cargo 子命令历史。")

(defun my/cargo-root ()
  "最外层 Cargo 工作区根目录：优先项目根，退而求其次最近的 Cargo.toml。"
  (or (when-let* ((project (project-current))
                  (root (project-root project)))
        (and (file-exists-p (expand-file-name "Cargo.toml" root)) root))
      (locate-dominating-file default-directory "Cargo.toml")
      (user-error "不在 Cargo 项目中")))

(defun my/cargo (command)
  "在工作区根目录运行 cargo COMMAND。"
  (interactive
   (list (completing-read "cargo " my/cargo-history nil nil nil
                          'my/cargo-history (car my/cargo-history))))
  (let ((default-directory (my/cargo-root)))
    (compile (concat "cargo " command))))

(defun my/cargo-run ()
  "cargo run。"
  (interactive)
  (my/cargo "run"))

(defun my/cargo-test-at-point ()
  "运行光标所在函数对应的测试。"
  (interactive)
  (let* ((node (treesit-defun-at-point))
         (name (and node (treesit-defun-name node))))
    (unless name (user-error "光标不在函数内"))
    (my/cargo (format "test %s -- --nocapture" name))))

;;; 模式

(use-package rust-ts-mode
  :mode "\\.rs\\'"
  :hook ((rust-ts-mode . eglot-ensure)
         (rust-ts-mode . my/eglot-format-on-save))
  :bind (:map rust-ts-mode-map
         ("C-c C-c" . my/cargo)
         ("C-c C-t" . my/cargo-test-at-point)
         ("C-c C-r" . my/cargo-run)
         ("C-c C-k" . recompile)))

(defun my/rust-analyzer-contact (&rest _)
  "eglot 连接 rust-analyzer 时读取最新的命令与选项。"
  `(,@my/rust-analyzer-command :initializationOptions ,my/rust-analyzer-options))

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((rust-ts-mode rust-mode) . my/rust-analyzer-contact)))

;; Cargo.toml / Cargo.lock
(use-package toml-ts-mode
  :mode ("Cargo\\.lock\\'" . toml-ts-mode))

(provide 'lang-rust)
;;; lang-rust.el ends here
