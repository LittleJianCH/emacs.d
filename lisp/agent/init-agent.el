;;; init-agent.el --- agent 支持的装配 -*- lexical-binding: t; -*-

;;; Commentary:

;; 所有 agent 命令在 C-c a 前缀下：
;;   C-c a a  显示 / 隐藏 agent 列
;;   C-c a c  Claude Code     C-c a x  Codex      （前缀参数 C-u 新建会话）
;;   C-c a n  选择 agent 启动  C-c a s  切换会话   C-c a k  结束会话
;;   C-c a f  发送当前文件引用（有选区时带行号）
;;   C-c a r  发送选区代码块
;;   C-c a v  回到 agent 最近展示的内容
;;
;; 新增 agent：在下方加一行 `agent-term-define-agent'。

;;; Code:

(use-package vterm
  :ensure t
  :defer t
  :custom
  (vterm-always-compile-module t)
  (vterm-max-scrollback 20000)
  ;; agent TUI 刷新频繁，缩短合并输出的延迟让流式输出更跟手。
  (vterm-timer-delay 0.02))

(use-package agent-term
  :demand t
  :config
  ;; vterm 默认不拦截 C-c 前缀，所以在 agent 终端里 C-c a 同样可用；
  ;; 要给 agent 发 Ctrl-C 用 C-c C-c。
  (keymap-global-set "C-c a" agent-term-command-map)
  (agent-term-define-agent claude
    :command "claude" :key "c" :reference #'agent-term-reference-at)
  (agent-term-define-agent codex
    :command "codex" :key "x")

  (with-eval-after-load 'project
    (dolist (entry '((agent-term-claude "Claude" ?c)
                     (agent-term-codex "Codex" ?x)))
      (add-to-list 'project-switch-commands entry t))))

;; agent → Emacs：emx 命令和 MCP server 调用的方法都定义在 agent-ui 中。
(use-package agent-ui
  :demand t
  :after agent-term
  :config
  (keymap-set agent-term-command-map "v" #'agent-ui-last-view))

;; agent 生成的原生页面：render / patch 方法。
(use-package agent-canvas
  :demand t
  :after agent-ui)

;; agent 通过 emacsclient / emx 回调本实例。
(use-package server
  :demand t
  :config
  (unless (or (daemonp) (server-running-p))
    (server-start)))

(provide 'init-agent)
;;; init-agent.el ends here
