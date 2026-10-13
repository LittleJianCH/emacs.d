;;; init.el --- 面向 agent 协作开发的 Emacs 配置 -*- lexical-binding: t; -*-

(when (version< emacs-version "30.1")
  (error "这份配置需要 Emacs 30.1 或更新版本"))

(add-to-list 'load-path (expand-file-name "lisp" user-emacs-directory))

;;; 插件源：GNU / NonGNU ELPA 优先，MELPA 只用于 vterm 等少数包

(require 'package)
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))
(package-initialize)
(require 'use-package)
(setq use-package-always-ensure nil
      use-package-expand-minimally t)

;;; 模块

(require 'init-base)        ; 默认行为、路径、macOS 环境
(require 'init-ui)          ; 主题、字体、窗口
(require 'init-completion)  ; vertico / consult / corfu
(require 'init-dev)         ; 项目、git、eglot、tree-sitter

;; 启动完成后恢复正常 GC。
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 64 1024 1024)
                  gc-cons-percentage 0.1)))

;;; init.el ends here
