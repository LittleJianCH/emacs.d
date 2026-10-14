;;; init-evil.el --- Vim 键位（evil） -*- lexical-binding: t; -*-

;;; Commentary:

;; evil + evil-collection（为 magit、dired、help 等常用模式提供 Vim 键位）。
;; leader 键为 SPC（normal / motion 状态）：
;;   SPC f  找文件          SPC b  切换 buffer      SPC r  最近文件
;;   SPC s  搜索当前文件    SPC /  项目内搜索       SPC p  项目命令
;;   SPC g  magit           SPC a  agent 命令（同 C-c a）
;;   SPC w  窗口命令        SPC u  前缀参数（C-u 被用于向上翻页）
;; minibuffer 中不启用 evil，保持普通编辑。
;;
;; 是否加载由 init-base.el 中的 `my/use-evil' 决定（默认关闭）；
;; 运行中用 M-x my/toggle-evil 开关，加前缀参数 C-u 同时保存为默认。

;;; Code:

;; 默认不加载 evil，编译本文件时声明一下其函数（运行时随 evil 加载）。
(declare-function evil-set-leader "evil-core")
(declare-function evil-define-key* "evil-core")

(use-package evil
  :ensure t
  ;; NonGNU 上的 1.15.0 在 Emacs 31 下会报 void-variable evil-mode-buffers
  ;; （Emacs 31 的全局 minor mode 不再定义 MODE-buffers），MELPA 版已修复。
  :pin melpa
  :demand t
  :init
  ;; evil-collection 要求在 evil 加载前设置。
  (setq evil-want-integration t
        evil-want-keybinding nil)
  :custom
  (evil-want-C-u-scroll t)
  (evil-want-C-i-jump nil)
  (evil-undo-system 'undo-redo)
  (evil-respect-visual-line-mode t)
  (evil-split-window-below t)
  (evil-vsplit-window-right t)
  (evil-symbol-word-search t)
  :config
  (evil-mode 1)
  (evil-set-leader '(normal motion visual) (kbd "SPC"))
  (evil-define-key '(normal motion visual) 'global
    (kbd "<leader>f") #'find-file
    (kbd "<leader>b") #'consult-buffer
    (kbd "<leader>r") #'consult-recent-file
    (kbd "<leader>s") #'consult-line
    (kbd "<leader>/") #'consult-ripgrep
    (kbd "<leader>p") project-prefix-map
    (kbd "<leader>g") #'magit-status
    (kbd "<leader>w") evil-window-map
    (kbd "<leader>u") #'universal-argument
    (kbd "<leader>h") help-map
    (kbd "<leader>i") #'my/open-init-file))

(use-package evil-collection
  :ensure t
  :after evil
  :demand t
  :custom
  (evil-collection-want-unimpaired-p nil)
  :config
  (evil-collection-init))

(provide 'init-evil)
;;; init-evil.el ends here
