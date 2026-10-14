;;; init.el --- 面向 agent 协作开发的 Emacs 配置 -*- lexical-binding: t; -*-

;;; Commentary:

;; 目录结构：
;;   lisp/core/   基础层：默认行为、界面、补全、通用开发工具
;;   lisp/lang/   语言模块，一个语言一个文件：lang-NAME.el
;;   lisp/agent/  agent 支持：终端会话、agent → Emacs 的桥
;;
;; 增加语言：新建 lisp/lang/lang-NAME.el（末尾 provide），再把 NAME 加入 `my/languages'。

;;; Code:

(when (version< emacs-version "30.1")
  (error "这份配置需要 Emacs 30.1 或更新版本"))

(dolist (dir '("core" "lang" "agent"))
  (add-to-list 'load-path (expand-file-name (concat "lisp/" dir) user-emacs-directory)))

;;; 插件源：GNU / NonGNU ELPA 优先，MELPA 只补充少数包

(require 'package)
(setq package-archives '(("gnu" . "https://elpa.gnu.org/packages/")
                         ("nongnu" . "https://elpa.nongnu.org/nongnu/")
                         ("melpa" . "https://melpa.org/packages/"))
      package-archive-priorities '(("gnu" . 3) ("nongnu" . 2) ("melpa" . 1)))
(package-initialize)
(require 'use-package)
(setq use-package-expand-minimally t)

;;; 模块

(defvar my/languages '(elisp rust)
  "启用的语言模块，对应 lisp/lang/lang-NAME.el。")

(require 'init-base)        ; 默认行为、路径、macOS 环境
(require 'init-ui)          ; 主题、字体、窗口
(when my/use-evil
  (require 'init-evil))     ; Vim 键位（evil），默认关闭；M-x my/toggle-evil 切换
(require 'init-completion)  ; vertico / consult / corfu
(require 'init-dev)         ; 项目、git、eglot、tree-sitter

(dolist (lang my/languages)
  (require (intern (format "lang-%s" lang))))

(require 'init-agent)       ; agent 终端会话、agent → Emacs 桥

;; 启动完成后恢复正常 GC。
(add-hook 'emacs-startup-hook
          (lambda ()
            (setq gc-cons-threshold (* 64 1024 1024)
                  gc-cons-percentage 0.1)))

;;; init.el ends here
