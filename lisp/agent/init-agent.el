;;; init-agent.el --- agent 支持的装配 -*- lexical-binding: t; -*-

;;; Commentary:

;; agent CLI 在后台以结构化协议运行，对话由 Emacs 渲染（agent-session）。
;; 会话 buffer（参考 telega）：上方是对话，分隔线与提示符之后是输入区；模型等信息在状态栏。
;; 全局命令在 C-c a 前缀下：
;;   C-c a a  显示 / 隐藏 agent 列        C-c a n  新建会话（C-u 先选 agent）
;;   C-c a i  给当前项目的会话发消息      C-c a s  会话列表（进行中 + 历史）
;;   C-c a f  带上当前文件引用输入        C-c a r  带上选区代码块输入
;;   C-c a k  结束会话                    C-c a v  回到 agent 最近展示的页面
;; 会话 buffer 中：输入区 RET 发送，C-j 换行，M-p / M-n 历史，TAB 补全（/ 命令、@ 文件）；
;; C-c C-k 清空输入或中断，C-c C-o 设置菜单，C-c C-y / C-c C-n 允许 / 拒绝；
;; agent 运行中：RET 排队，M-RET 引导（立刻送进当前回合），C-c C-g 把最早的排队消息转为引导；
;; 在对话记录中打字会跳到输入区。
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

(defmacro agent-session--evil-enter (name command)
  "定义 NAME：输入区中执行 evil 的 COMMAND，否则跳到输入区末尾进入 insert 状态。
宏定义在顶层，编译时可用；生成的命令只在加载 evil 后使用。"
  `(defun ,name ()
     ,(format "输入区中同 `%s'；在对话记录中跳到输入区末尾并进入 insert 状态。" command)
     (interactive)
     (if (agent-session--in-input-p)
         (call-interactively #',command)
       (goto-char (point-max))
       (evil-insert-state))))

;; evil 默认不加载（见 `my/use-evil'），这里声明用到的函数，编译时不报警告。
(declare-function evil-insert "evil-commands")
(declare-function evil-append "evil-commands")
(declare-function evil-insert-line "evil-commands")
(declare-function evil-append-line "evil-commands")
(declare-function evil-open-below "evil-commands")
(declare-function evil-open-above "evil-commands")
(declare-function evil-insert-state "evil-states")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-define-key* "evil-core")

;; 这些命令只在调用时才用到 evil，提前定义没有副作用。
(agent-session--evil-enter agent-session-evil-insert evil-insert)
(agent-session--evil-enter agent-session-evil-append evil-append)
(agent-session--evil-enter agent-session-evil-insert-line evil-insert-line)
(agent-session--evil-enter agent-session-evil-append-line evil-append-line)
(agent-session--evil-enter agent-session-evil-open-below evil-open-below)
(agent-session--evil-enter agent-session-evil-open-above evil-open-above)

;; Vim 键位（加载了 evil 时）。会话 buffer 起始为 normal 状态：i / a / o 等在输入区中
;; 保持原意，在对话记录中则跳到输入区末尾进入 insert 状态；insert 状态下 RET 发送，
;; ESC 回到 normal 浏览对话。设置与审批放在本地 leader “,” 下（只在 agent 的 buffer 中生效）。
(with-eval-after-load 'evil
  (evil-define-key* '(normal motion visual) 'global
    (kbd "<leader>a") agent-session-command-map)

  (defvar-keymap agent-session-local-leader-map
    :doc "会话 buffer 中 , 之后的按键。"
    "o" #'agent-session-menu
    "m" #'agent-session-select-model
    "e" #'agent-session-select-effort
    "M" #'agent-session-select-mode
    "p" #'agent-session-toggle-plan
    "A" #'agent-session-select-agent
    "y" #'agent-session-approve
    "n" #'agent-session-deny
    "k" #'agent-session-interrupt
    "g" #'agent-session-steer-queued
    "x" #'agent-session-cancel-queued
    "s" #'agent-session-list
    "N" #'agent-session-new
    "r" #'agent-session-resume)

  (evil-set-initial-state 'agent-session-mode 'normal)
  (evil-define-key* '(normal motion) agent-session-mode-map
    (kbd "RET") #'agent-session-ret
    "i" #'agent-session-evil-insert
    "a" #'agent-session-evil-append
    "I" #'agent-session-evil-insert-line
    "A" #'agent-session-evil-append-line
    "o" #'agent-session-evil-open-below
    "O" #'agent-session-evil-open-above
    "]]" #'agent-session-next-message
    "[[" #'agent-session-previous-message
    (kbd "TAB") #'forward-button
    (kbd "<backtab>") #'backward-button
    "q" #'quit-window
    "," agent-session-local-leader-map)

  (evil-set-initial-state 'agent-session-list-mode 'normal)
  (evil-define-key* '(normal motion) agent-session-list-mode-map
    (kbd "RET") #'agent-session-list-open
    "o" #'agent-session-list-open
    "c" #'agent-session-list-create
    "x" #'agent-session-list-kill
    "gr" #'agent-session-list-refresh
    "]]" #'agent-session-list-next
    "[[" #'agent-session-list-previous
    "q" #'quit-window)

  (evil-set-initial-state 'agent-canvas-mode 'normal)
  (evil-define-key* '(normal motion) agent-canvas-mode-map
    (kbd "RET") #'push-button
    (kbd "TAB") #'agent-canvas-tab
    (kbd "<backtab>") #'backward-button
    "c" #'agent-canvas-comment
    "gr" #'revert-buffer
    "q" #'quit-window))

;; agent 通过 emacsclient / emx 回调本实例。
(use-package server
  :demand t
  :config
  (unless (or noninteractive (daemonp) (server-running-p))
    (server-start)))

(provide 'init-agent)
;;; init-agent.el ends here
