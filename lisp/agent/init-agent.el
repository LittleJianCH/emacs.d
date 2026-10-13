;;; init-agent.el --- agent 支持的装配 -*- lexical-binding: t; -*-

;;; Commentary:

;; agent CLI 在后台以结构化协议运行，对话由 Emacs 渲染（agent-session）。
;; 全局命令在 C-c a 前缀下：
;;   C-c a a  显示 / 隐藏 agent 列        C-c a n  新建会话（C-u 先选 agent）
;;   C-c a s  会话列表（进行中 + 历史）   C-c a k  结束会话
;;   C-c a f  把当前文件引用插入输入区    C-c a r  把选区代码块插入输入区
;;   C-c a v  回到 agent 最近展示的页面
;; 会话中：C-c C-c 发送，C-c C-o 设置菜单（agent / 模型 / 推理强度 / 权限模式），
;; C-c C-k 中断，C-c C-y / C-c C-n 允许 / 拒绝；输入 / 补全命令，@ 补全文件。
;;
;; 新增 agent：实现一个后端（参考 agent-claude.el），再加一行 `agent-session-define-agent'。

;;; Code:

(use-package agent-session
  :demand t
  :config
  (keymap-global-set "C-c a" agent-session-command-map)
  (with-eval-after-load 'project
    (add-to-list 'project-switch-commands '(agent-session-create "Agent" ?a) t)))

(use-package agent-claude
  :after agent-session
  :demand t
  :config
  (agent-session-define-agent claude :title "Claude"))

(use-package agent-codex
  :after agent-session
  :demand t
  :config
  (agent-session-define-agent codex :title "Codex"))

(use-package agent-session-list
  :after agent-session
  :demand t)

;; agent → Emacs：emx 命令和 MCP server 调用的方法都定义在 agent-ui 中。
(use-package agent-ui
  :demand t
  :after agent-session
  :config
  (keymap-set agent-session-command-map "v" #'agent-ui-last-view))

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
