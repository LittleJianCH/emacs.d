;;; agent-term.el --- 在 vterm 中运行原生 agent CLI -*- lexical-binding: t; -*-

;;; Commentary:

;; 每个 agent 会话是一个 vterm buffer，里面直接运行 claude / codex 等原生 CLI。
;; 会话按项目根目录归属，固定显示在框架右侧的“agent 列”。
;;
;; 会话内的环境变量：
;;   PATH               前置本配置的 bin/，agent 可直接调用 emx
;;   EMACS_SOCKET_NAME  指向当前 Emacs server，emacsclient / emx 连回本实例
;;   EMX_AGENT_BUFFER   会话 buffer 名，供 agent 回调时标识自己

;;; Code:

(require 'project)
(require 'seq)
(require 'server)
(require 'vterm)

(defgroup agent-term nil
  "在 Emacs 中运行 agent CLI。"
  :group 'tools
  :prefix "agent-term-")

(defvar agent-term-agents nil
  "已注册的 agent：((NAME . PLIST) ...)，用 `agent-term-define-agent' 添加。
PLIST 支持：
  :command    启动命令（shell 命令行）
  :reference  生成文件引用的函数，参数为 (PATH START END)，行号可为 nil")

(defcustom agent-term-window-width 0.42
  "agent 列的宽度，小数为占框架宽度的比例。"
  :type 'number)

(defcustom agent-term-bin-directory
  (expand-file-name "bin" user-emacs-directory)
  "前置到会话 PATH 的目录，其中放 emx 等桥接命令。"
  :type 'directory)

(defvar-local agent-term--agent nil "本 buffer 运行的 agent 名称。")
(defvar-local agent-term--root nil "本会话所属的项目根目录。")
(put 'agent-term--agent 'permanent-local t)
(put 'agent-term--root 'permanent-local t)

(defun agent-term--get (agent prop)
  "读取已注册 AGENT 的属性 PROP。"
  (plist-get (alist-get agent agent-term-agents) prop))

;;; 会话查找

(defun agent-term--root ()
  "当前上下文对应的项目根目录，没有项目时用 `default-directory'。"
  (expand-file-name
   (if-let* ((project (project-current)))
       (project-root project)
     default-directory)))

(defun agent-term-buffer-p (buffer)
  "BUFFER 是否为 agent 会话。"
  (and (buffer-live-p buffer)
       (buffer-local-value 'agent-term--agent buffer)))

(defun agent-term-buffers (&optional root agent)
  "按最近使用排序的 agent 会话；可按 ROOT 和 AGENT 过滤。"
  (seq-filter (lambda (buffer)
                (and (agent-term-buffer-p buffer)
                     (or (null root)
                         (equal root (buffer-local-value 'agent-term--root buffer)))
                     (or (null agent)
                         (eq agent (buffer-local-value 'agent-term--agent buffer)))))
              (buffer-list)))

(defun agent-term--visible-window ()
  "当前框架中显示 agent 会话的窗口。"
  (seq-find (lambda (window) (agent-term-buffer-p (window-buffer window)))
            (window-list nil 'no-minibuf)))

(defun agent-term--target ()
  "发送内容的目标会话：可见的 > 本项目最近的 > 任意最近的。"
  (or (when-let* ((window (agent-term--visible-window)))
        (window-buffer window))
      (car (agent-term-buffers (agent-term--root)))
      (car (agent-term-buffers))))

;;; 显示

(defun agent-term--display (buffer)
  "在 agent 列显示 BUFFER，返回所在窗口。
已有 agent 窗口时复用，否则在框架右侧新开一列。"
  (or (get-buffer-window buffer)
      (when-let* ((window (agent-term--visible-window)))
        (set-window-buffer window buffer)
        window)
      (display-buffer buffer
                      `((display-buffer-in-direction)
                        (direction . right)
                        (window . main)
                        (window-width . ,agent-term-window-width)))))

(defun agent-term--environment (buffer-name)
  "agent 会话的环境变量，形如 vterm-environment。"
  (list (concat "PATH=" agent-term-bin-directory path-separator (getenv "PATH"))
        (concat "EMACS_SOCKET_NAME="
                (expand-file-name server-name server-socket-dir))
        (concat "EMX_AGENT_BUFFER=" buffer-name)))

;;; 命令

(defun agent-term--read-agent ()
  "在 minibuffer 中选择一个 agent。"
  (intern (completing-read "Agent: " (reverse (mapcar #'car agent-term-agents))
                           nil t)))

;;;###autoload
(defun agent-term-start (agent &optional new)
  "打开当前项目的 AGENT 会话；NEW 非空（前缀参数）时总是新建。"
  (interactive (list (agent-term--read-agent) current-prefix-arg))
  (unless (server-running-p) (server-start))
  (let ((root (agent-term--root)))
    (if-let* ((existing (and (not new) (car (agent-term-buffers root agent)))))
        (select-window (agent-term--display existing))
      (let* ((name (generate-new-buffer-name
                    (format "*agent:%s@%s*" agent
                            (file-name-nondirectory (directory-file-name root)))))
             (buffer (get-buffer-create name))
             (window (agent-term--display buffer)))
        (select-window window)
        (with-current-buffer buffer
          (let ((default-directory root)
                (vterm-shell (or (agent-term--get agent :command)
                                 (user-error "未注册 agent：%s" agent)))
                (vterm-environment (append (agent-term--environment name)
                                           vterm-environment)))
            (vterm-mode))
          (setq agent-term--agent agent
                agent-term--root root))
        buffer))))

;;;###autoload
(defun agent-term-toggle ()
  "显示或隐藏 agent 列；没有会话时先选择 agent 启动。"
  (interactive)
  (if-let* ((window (agent-term--visible-window)))
      (if (one-window-p) (switch-to-buffer (other-buffer)) (delete-window window))
    (if-let* ((buffer (agent-term--target)))
        (select-window (agent-term--display buffer))
      (call-interactively #'agent-term-start))))

;;;###autoload
(defun agent-term-switch ()
  "在所有 agent 会话之间切换。"
  (interactive)
  (let ((buffers (mapcar #'buffer-name (agent-term-buffers))))
    (unless buffers (user-error "还没有 agent 会话"))
    (select-window (agent-term--display
                    (get-buffer (completing-read "Agent 会话: " buffers nil t))))))

(defun agent-term-kill ()
  "结束当前（或目标）agent 会话。"
  (interactive)
  (let ((buffer (if (agent-term-buffer-p (current-buffer))
                    (current-buffer)
                  (agent-term--target))))
    (unless buffer (user-error "没有 agent 会话"))
    (when (yes-or-no-p (format "结束 %s？" (buffer-name buffer)))
      (kill-buffer buffer))))

;;; 向 agent 发送内容

(defun agent-term-send-string (string &optional buffer)
  "以粘贴方式把 STRING 发送到 BUFFER（默认目标会话），不自动回车。"
  (let ((buffer (or buffer (agent-term--target)
                    (user-error "没有 agent 会话，先用 C-c a n 启动"))))
    (with-current-buffer buffer
      (vterm-send-string string t))
    (select-window (agent-term--display buffer))))

(defun agent-term-reference-colon (path start end)
  "通用引用格式：path 或 path:START-END。"
  (concat path (when start (format ":%d-%d" start end)) " "))

(defun agent-term-reference-at (path start end)
  "Claude Code 的 @ 引用格式：@path 或 @path#LSTART-END。"
  (concat "@" path (when start (format "#L%d-%d" start end)) " "))

(defun agent-term--reference (agent root)
  "当前 buffer 位置的文件引用字符串，路径相对于 ROOT。"
  (let ((file (or buffer-file-name (user-error "当前 buffer 没有对应文件")))
        (start (and (use-region-p) (line-number-at-pos (region-beginning))))
        (end (and (use-region-p)
                  (line-number-at-pos (max (region-beginning) (1- (region-end)))))))
    (funcall (or (agent-term--get agent :reference) #'agent-term-reference-colon)
             (file-relative-name file root) start end)))

;;;###autoload
(defun agent-term-send-reference ()
  "把当前文件（有选区时带行号范围）的引用发送给 agent。"
  (interactive)
  (let ((target (or (agent-term--target) (user-error "没有 agent 会话"))))
    (agent-term-send-string
     (agent-term--reference (buffer-local-value 'agent-term--agent target)
                            (buffer-local-value 'agent-term--root target))
     target)
    (deactivate-mark)))

;;;###autoload
(defun agent-term-send-region (start end)
  "把选区内容连同出处，作为代码块发送给 agent。"
  (interactive "r")
  (let* ((target (or (agent-term--target) (user-error "没有 agent 会话")))
         (root (buffer-local-value 'agent-term--root target))
         (where (if buffer-file-name
                    (format "%s:%d-%d" (file-relative-name buffer-file-name root)
                            (line-number-at-pos start)
                            (line-number-at-pos (max start (1- end))))
                  (buffer-name)))
         (lang (string-remove-suffix "-mode" (symbol-name major-mode))))
    (agent-term-send-string
     (format "%s\n```%s\n%s\n```\n" where
             (string-remove-suffix "-ts" lang)
             (buffer-substring-no-properties start end))
     target)
    (deactivate-mark)))

;;; 按键

(defvar-keymap agent-term-command-map
  :doc "agent 命令前缀表；各 agent 的启动键由 `agent-term-define-agent' 加入。"
  "a" #'agent-term-toggle
  "n" #'agent-term-start
  "s" #'agent-term-switch
  "k" #'agent-term-kill
  "f" #'agent-term-send-reference
  "r" #'agent-term-send-region)

;;; 注册 agent

(defmacro agent-term-define-agent (name &rest plist)
  "注册名为 NAME 的 agent，并定义命令 agent-term-NAME。
PLIST 见 `agent-term-agents'，另支持 :key，在 `agent-term-command-map'
中绑定启动命令。例如：

  (agent-term-define-agent gemini :command \"gemini\" :key \"g\")"
  (declare (indent 1))
  (let ((command (intern (format "agent-term-%s" name)))
        (key (plist-get plist :key)))
    `(progn
       (setf (alist-get ',name agent-term-agents) (list ,@plist))
       (defun ,command (&optional new)
         ,(format "打开当前项目的 %s 会话；前缀参数时新建。" name)
         (interactive "P")
         (agent-term-start ',name new))
       ,(when key `(keymap-set agent-term-command-map ,key #',command))
       ',command)))

(provide 'agent-term)
;;; agent-term.el ends here
