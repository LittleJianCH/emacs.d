;;; agent-session.el --- Emacs 自己渲染的 agent 会话 -*- lexical-binding: t; -*-

;;; Commentary:

;; agent CLI 以后台进程运行（Claude: stream-json，Codex: app-server），
;; 对话由这里渲染成 Emacs buffer：上方是只读的对话记录，下方是输入区。
;;
;; 分层：
;;   - 本文件：会话管理、界面、输入；对后端暴露“界面 API”（agent-session-text、
;;     agent-session-tool、agent-session-ask ...），不关心具体协议。
;;   - 后端（agent-claude.el、agent-codex.el）：实现 agent-session-backend-* 泛型函数，
;;     把各自协议的消息翻译成界面 API 调用。
;;
;; 新增 agent：实现一个后端，再用 `agent-session-define-agent' 注册。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'server)
(require 'button)

(defgroup agent-session nil
  "Emacs 渲染的 agent 会话。"
  :group 'tools
  :prefix "agent-session-")

(defcustom agent-session-window-width 0.42
  "会话窗口的宽度，小数为占框架宽度的比例。"
  :type 'number)

(defcustom agent-session-bin-directory (expand-file-name "bin" user-emacs-directory)
  "前置到后台进程 PATH 的目录，其中放 emx。"
  :type 'directory)

(defcustom agent-session-output-lines 20
  "工具输出展开时最多显示的行数（显示末尾部分）。"
  :type 'integer)

;;; Faces

(defface agent-session-user '((t :inherit (bold font-lock-keyword-face)))
  "用户消息标题。")
(defface agent-session-assistant '((t :inherit (bold font-lock-function-name-face)))
  "agent 消息标题。")
(defface agent-session-thinking '((t :inherit (italic shadow)))
  "思考过程。")
(defface agent-session-tool '((t :inherit font-lock-type-face))
  "工具调用标题。")
(defface agent-session-dim '((t :inherit shadow))
  "次要信息。")
(defface agent-session-ok '((t :inherit success))
  "成功状态。")
(defface agent-session-error '((t :inherit error))
  "失败状态。")
(defface agent-session-ask '((t :inherit (bold warning)))
  "等待用户确认。")
(defface agent-session-button
  '((t :inherit (mode-line-inactive bold)
       :box (:line-width (6 . 2) :style released-button)))
  "按钮。")

;;; 会话对象

(cl-defstruct (agent-session (:constructor agent-session--make))
  agent          ; 注册名，如 claude
  backend        ; 后端符号，用于泛型分派
  root           ; 项目根目录
  buffer
  process
  (status 'starting)   ; starting / idle / running / exited
  info           ; 显示在 header-line 的信息 plist：:model :tokens :cost ...
  state          ; 后端私有状态 plist
  (blocks (make-hash-table :test #'equal))
  tail           ; 对话记录末尾（新 block 插入处）
  input          ; 输入区起点
  queue          ; 运行中输入的消息，回合结束后依次发送
  history
  settings)      ; 用户选择：:model :effort :mode（nil 表示用 agent 的默认值）

(defvar-local agent-session--current nil "本 buffer 的会话对象。")
(put 'agent-session--current 'permanent-local t)

(defvar agent-session-agents nil
  "已注册的 agent：((NAME . PLIST) ...)。PLIST 支持 :backend :title :key。")

(defun agent-session--get (agent prop)
  "读取已注册 AGENT 的属性 PROP。"
  (plist-get (alist-get agent agent-session-agents) prop))

(defun agent-session-resume-id (session)
  "SESSION 对应的 agent 原生会话 id（Claude session id / Codex thread id），可能为 nil。"
  (and session (plist-get (agent-session-state session) :resume)))

(defun agent-session-title (session)
  "SESSION 的显示名，如 Claude。"
  (or (agent-session--get (agent-session-agent session) :title)
      (symbol-name (agent-session-agent session))))

;;; 后端接口

(cl-defgeneric agent-session-backend-start (backend session)
  "启动 SESSION 的后台进程。BACKEND 为后端符号。")

(cl-defgeneric agent-session-backend-send (backend session text)
  "把用户消息 TEXT 发给 agent。")

(cl-defgeneric agent-session-backend-interrupt (backend session)
  "中断当前回合。")

(cl-defgeneric agent-session-backend-handle (backend session message)
  "处理后台进程输出的一条 JSON 消息 MESSAGE（plist）。")

(cl-defgeneric agent-session-backend-stop (backend session)
  "结束会话。默认直接结束进程。"
  (ignore backend)
  (when-let* ((process (agent-session-process session)))
    ;; 先解除关联，旧进程的 sentinel 据此忽略这次退出。
    (setf (agent-session-process session) nil)
    (when (process-live-p process) (delete-process process))))

(cl-defgeneric agent-session-backend-models (backend session)
  "可选模型：((:id ID :name 显示名 :description 说明 :efforts (强度...) :default-effort E) ...)。"
  (ignore backend session)
  nil)

(cl-defgeneric agent-session-backend-modes (backend session)
  "支持的权限模式（`agent-session-modes' 的键）。"
  (ignore backend session)
  '(ask edits full))

(cl-defgeneric agent-session-backend-commands (backend session)
  "agent 提供的斜杠命令：((:name N :description D :hint H) ...)。"
  (ignore backend session)
  nil)

(cl-defgeneric agent-session-backend-apply-settings (backend session changed)
  "设置变化后生效。CHANGED 为变化的键列表（:model :effort :mode）。"
  (ignore backend session changed))

(cl-defgeneric agent-session-backend-history (backend root callback)
  "列出项目 ROOT 中的历史会话，以列表调用 CALLBACK（可异步）。
每项为 (:id ID :title 标题 :time 秒数)，按时间倒序。"
  (ignore backend root)
  (funcall callback nil))

;;; 设置：模型、推理强度、权限模式

(defconst agent-session-modes
  '((ask "需确认" "命令和文件改动都需要确认")
    (edits "自动接受编辑" "文件改动自动通过，其他操作仍需确认")
    (auto "自动审查" "由 agent 的自动审查放行常规操作，其余询问")
    (full "完全访问" "命令和改动都不再询问")
    (plan "计划" "只读规划，不做改动"))
  "统一的权限模式（参考 T3 Code），由各后端映射到自己的设置。")

(defcustom agent-session-default-mode 'edits
  "新会话默认的权限模式。"
  :type '(choice (const ask) (const edits) (const auto) (const full)))

(defvar agent-session-last-settings nil
  "每个 agent 最近一次使用的设置：((AGENT . PLIST) ...)，新会话沿用。")
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'agent-session-last-settings))

(defun agent-session-setting (session key)
  "SESSION 的设置 KEY；未设置模式时用默认模式。"
  (or (plist-get (agent-session-settings session) key)
      (and (eq key :mode) agent-session-default-mode)))

(defun agent-session-configure (session &rest props)
  "修改 SESSION 的设置（:model :effort :mode）并让后端生效。"
  (let (changed)
    (cl-loop for (key value) on props by #'cddr
             unless (equal value (agent-session-setting session key))
             do (push key changed)
                (setf (agent-session-settings session)
                      (plist-put (agent-session-settings session) key value)))
    (when changed
      (setf (alist-get (agent-session-agent session) agent-session-last-settings)
            (agent-session-settings session))
      (agent-session-backend-apply-settings (agent-session-backend session) session changed)
      (agent-session--refresh-header session))
    changed))

(defun agent-session-model-info (session &optional model)
  "SESSION 中模型 MODEL（默认当前模型）的信息 plist。"
  (let ((models (agent-session-backend-models (agent-session-backend session) session))
        (model (or model (agent-session-setting session :model))))
    (or (seq-find (lambda (m) (equal (plist-get m :id) model)) models)
        (car models))))

(defun agent-session-restart-process (session)
  "重启 SESSION 的后台进程（例如切换只能在启动时指定的设置）。"
  (agent-session-backend-stop (agent-session-backend session) session)
  (setf (agent-session-status session) 'starting)
  (agent-session-backend-start (agent-session-backend session) session))

;;; 后台进程

(defun agent-session-environment (session)
  "后台进程的环境：能找到 emx，并能连回本 Emacs。"
  (append
   (list (concat "PATH=" agent-session-bin-directory path-separator (getenv "PATH"))
         (concat "EMACS_SOCKET_NAME=" (expand-file-name server-name server-socket-dir))
         (concat "EMX_AGENT_BUFFER=" (buffer-name (agent-session-buffer session))))
   process-environment))

(defun agent-session-emx-command ()
  "启动 emx MCP server 的命令行。"
  (list (expand-file-name "emx" agent-session-bin-directory) "mcp"))

(defun agent-session-start-process (session command)
  "以 COMMAND 启动 SESSION 的后台进程；每行 JSON 交给后端处理。"
  (let* ((buffer (agent-session-buffer session))
         (default-directory (agent-session-root session))
         (process-environment (agent-session-environment session))
         (pending "")
         (process
          (make-process
           :name (format "agent-%s" (agent-session-agent session))
           :command command
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :stderr (get-buffer-create (format " *%s stderr*" (buffer-name buffer)))
           :filter
           (lambda (_process output)
             (setq pending (concat pending output))
             (let ((lines (split-string pending "\n")))
               (setq pending (car (last lines)))
               (dolist (line (butlast lines))
                 (unless (string-blank-p line)
                   (agent-session--dispatch session line)))))
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               ;; 已被替换或主动结束的进程，不算意外退出。
               (when (and (buffer-live-p buffer) (eq process (agent-session-process session)))
                 (agent-session-set-status session 'exited)
                 (agent-session-notice
                  session (format "进程已退出（%s，退出码 %s）"
                                  (process-status process) (process-exit-status process))
                  'agent-session-error)))))))
    (setf (agent-session-process session) process)))

(defvar agent-session-raw-message nil
  "正在处理的消息的原始 JSON 行。
plist 解析会丢失 false / null / {} 的区别；需要把数据原样回传给 agent 时，
用 `agent-session-raw-json' 从这里重新解析。")

(defun agent-session-raw-json (&rest path)
  "按键 PATH 从当前原始消息中取值，保留 JSON 的 false / null / 空对象。"
  (let ((value (json-parse-string agent-session-raw-message :object-type 'hash-table
                                  :null-object :null :false-object :false)))
    (dolist (key path value)
      (setq value (and (hash-table-p value) (gethash key value))))))

(defun agent-session--dispatch (session line)
  "解析一行 JSON 并交给后端；出错时记录到会话中而不中断进程。"
  (when (buffer-live-p (agent-session-buffer session))
    (condition-case err
        (let ((agent-session-raw-message line))
          (agent-session-backend-handle
         (agent-session-backend session) session
           (json-parse-string line :object-type 'plist :null-object nil :false-object nil)))
      (error
       (agent-session-notice session (truncate-string-to-width
                                      (format "处理消息出错：%s" (error-message-string err)) 200 nil nil "…")
                             'agent-session-error)))))

(defun agent-session-write (session object)
  "把 OBJECT 序列化为一行 JSON 写给后台进程。"
  (let ((process (agent-session-process session)))
    (unless (process-live-p process) (user-error "agent 进程未运行"))
    (process-send-string process (concat (json-serialize object :null-object :null :false-object :false)
                                         "\n"))))

;;; 对话记录：block 的插入与重绘

(defun agent-session--ro (string)
  "把 STRING 标为对话记录（只读）。"
  (propertize string 'read-only t 'front-sticky '(read-only) 'rear-nonsticky '(read-only)))

(defmacro agent-session--with-buffer (session &rest body)
  "在 SESSION 的 buffer 中执行 BODY，允许修改只读的对话记录，并保持各窗口的光标。"
  (declare (indent 1))
  (let ((buffer (make-symbol "buffer")))
    `(let ((,buffer (agent-session-buffer ,session)))
       (when (buffer-live-p ,buffer)
         (with-current-buffer ,buffer
           (let ((inhibit-read-only t)
                 (inhibit-modification-hooks t))
             (save-excursion ,@body)))))))

(defun agent-session--block (session id)
  "SESSION 中 ID 对应的 block 数据（plist），没有时返回 nil。"
  (gethash id (agent-session-blocks session)))

(defun agent-session--new-block (session id data)
  "在对话末尾新建 block ID，内容由 DATA 渲染。"
  (agent-session--with-buffer session
    (let ((tail (agent-session-tail session)))
      (goto-char tail)
      (let ((start (copy-marker (point)))
            (end (copy-marker (point))))
        (insert (agent-session--ro "\n"))
        ;; start / end 都不随插入移动；内容渲染在两者之间，末尾的换行把相邻 block 隔开。
        (puthash id (plist-put (plist-put data :start start) :end end)
                 (agent-session-blocks session))
        (agent-session--render session id)))))

(defun agent-session--render (session id)
  "按 block ID 的数据重绘它。"
  (let* ((block (agent-session--block session id))
         (start (plist-get block :start))
         (end (plist-get block :end)))
    (agent-session--with-buffer session
      (delete-region start end)
      (goto-char start)
      (insert (agent-session--ro (agent-session--format session id block)))
      (set-marker end (point)))))

(defun agent-session--remove-block (session id)
  "从对话记录中删除 block ID（连同其后的分隔换行）。"
  (when-let* ((block (agent-session--block session id)))
    (agent-session--with-buffer session
      (delete-region (plist-get block :start) (1+ (plist-get block :end))))
    (remhash id (agent-session-blocks session))))

(defun agent-session--update (session id &rest props)
  "合并 PROPS 到 block ID 并重绘；block 不存在时新建。"
  (let ((block (agent-session--block session id)))
    (if (null block)
        (agent-session--new-block session id props)
      (cl-loop for (key value) on props by #'cddr
               do (setq block (plist-put block key value)))
      (puthash id block (agent-session-blocks session))
      (agent-session--render session id))))

(defun agent-session--format (session id block)
  "把 BLOCK 渲染成字符串。"
  (pcase (plist-get block :type)
    ('user (agent-session--format-user block))
    ('text (agent-session--format-text session block))
    ('tool (agent-session--format-tool id block))
    ('ask (agent-session--format-ask session id block))
    ('notice (concat (propertize (plist-get block :text)
                                 'face (or (plist-get block :face) 'agent-session-dim))
                     "\n"))))

;;; markdown 与代码高亮

(defun agent-session-fontify (text mode)
  "用 major MODE 高亮 TEXT，返回带 face 的字符串。"
  (if (not (fboundp mode))
      text
    (with-temp-buffer
      (insert text)
      (let ((treesit-auto-install-grammar nil))
        (ignore-errors
          (delay-mode-hooks (funcall mode))
          (font-lock-ensure)))
      ;; 有些模式用 font-lock-face，统一转成 face，展示时不依赖 font-lock。
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((next (next-single-property-change pos 'font-lock-face nil (point-max)))
                (face (get-text-property pos 'font-lock-face)))
            (when face (put-text-property pos next 'face face))
            (setq pos next))))
      (remove-list-of-text-properties (point-min) (point-max)
                                      '(invisible display keymap local-map mouse-face help-echo))
      (buffer-string))))

(defvar markdown-fontify-code-blocks-natively)

(defun agent-session--markdown (text)
  "把 markdown TEXT 高亮（代码块按语言高亮）。"
  (if (require 'markdown-mode nil t)
      (let ((markdown-fontify-code-blocks-natively t))
        (agent-session-fontify text 'gfm-mode))
    text))

;;; 各类 block 的格式

(define-button-type 'agent-session-toggle
  'face nil 'follow-link t 'action #'agent-session--toggle-block
  'help-echo "折叠 / 展开")

(define-button-type 'agent-session-choice
  'face 'agent-session-button 'follow-link t)

(defun agent-session--indent (text)
  "把 TEXT 每行缩进两格（用 line-prefix，不改变文本）。"
  (propertize text 'line-prefix "  " 'wrap-prefix "  "))

(defun agent-session--format-user (block)
  "用户消息。"
  (concat (propertize "▍ 你" 'face 'agent-session-user)
          (if (plist-get block :queued) (propertize "  排队中" 'face 'agent-session-dim) "")
          "\n"
          (agent-session--indent (plist-get block :text))
          "\n"))

(defun agent-session--format-text (session block)
  "agent 的回复或思考。流式输出时显示原文，结束后渲染 markdown。"
  (let ((text (string-trim-right (or (plist-get block :text) "")))
        (thinking (eq (plist-get block :kind) 'thinking)))
    (concat
     (propertize (if thinking "  思考" (concat "● " (agent-session-title session)))
                 'face (if thinking 'agent-session-dim 'agent-session-assistant))
     "\n"
     (agent-session--indent
      (cond (thinking (propertize text 'face 'agent-session-thinking))
            ((plist-get block :done) (agent-session--markdown text))
            (t text)))
     "\n")))

(defconst agent-session--tool-icons
  '((command . "$") (edit . "✎") (read . "≡") (search . "⌕") (web . "◎")
    (mcp . "⚙") (task . "◆") (plan . "☰") (other . "•"))
  "工具类型的图标。")

(defun agent-session--diff-stat (diff)
  "统计 DIFF 的增删行数。"
  (let ((added 0) (removed 0))
    (dolist (line (split-string (or diff "") "\n"))
      (cond ((string-match-p "\\`\\+\\(?:[^+]\\|\\'\\)" line) (cl-incf added))
            ((string-match-p "\\`-\\(?:[^-]\\|\\'\\)" line) (cl-incf removed))))
    (concat (propertize (format "+%d" added) 'face 'diff-added)
            " "
            (propertize (format "-%d" removed) 'face 'diff-removed))))

(defun agent-session--tail-lines (text n)
  "TEXT 的最后 N 行。"
  (let ((lines (split-string (string-trim-right text) "\n")))
    (if (> (length lines) n)
        (concat (propertize (format "…（省略 %d 行）\n" (- (length lines) n))
                            'face 'agent-session-dim)
                (string-join (last lines n) "\n"))
      (string-join lines "\n"))))

(defun agent-session--format-tool (id block)
  "工具调用：标题行可点击折叠，展开后显示 diff 或输出。"
  (let* ((status (plist-get block :status))
         (diff (plist-get block :diff))
         (output (plist-get block :output))
         (has-body (or diff (and output (not (string-blank-p output)))))
         (collapsed (if (plist-member block :collapsed)
                        (plist-get block :collapsed)
                      (not (or diff (eq status 'error)))))
         (header (concat
                  (if has-body (if collapsed "▸ " "▾ ") "  ")
                  (propertize (format "%s %s"
                                      (alist-get (plist-get block :kind) agent-session--tool-icons "•")
                                      (plist-get block :title))
                              'face 'agent-session-tool)
                  "  "
                  (pcase status
                    ('running (propertize "…" 'face 'agent-session-dim))
                    ('error (propertize "✗" 'face 'agent-session-error))
                    ('declined (propertize "已拒绝" 'face 'agent-session-error))
                    (_ (propertize "✓" 'face 'agent-session-ok)))
                  (if diff (concat "  " (agent-session--diff-stat diff)) "")
                  (if-let* ((note (plist-get block :note)))
                      (concat "  " (propertize note 'face 'agent-session-dim))
                    ""))))
    (concat
     (if has-body
         (make-text-button header nil 'type 'agent-session-toggle 'agent-session-block id)
       header)
     "\n"
     (when (and has-body (not collapsed))
       (concat
        (agent-session--indent
         (if diff
             (agent-session-fontify (string-trim-right diff) 'diff-mode)
           (propertize (agent-session--tail-lines output agent-session-output-lines)
                       'face 'agent-session-dim)))
        "\n")))))

(defun agent-session--toggle-block (button)
  "折叠或展开 BUTTON 所在的工具 block。"
  (let* ((session agent-session--current)
         (id (button-get button 'agent-session-block))
         (block (agent-session--block session id))
         (collapsed (if (plist-member block :collapsed)
                        (plist-get block :collapsed)
                      (not (or (plist-get block :diff) (eq (plist-get block :status) 'error))))))
    (agent-session--update session id :collapsed (not collapsed))))

(defun agent-session--format-ask (session id block)
  "等待用户确认的请求：说明、详情和选项按钮。"
  (let ((answer (plist-get block :answer)))
    (concat
     (propertize (concat (if answer "  " "⚠ ") (plist-get block :title))
                 'face (if answer 'agent-session-dim 'agent-session-ask))
     "\n"
     (when-let* ((detail (plist-get block :detail)))
       (concat (agent-session--indent (propertize detail 'face 'font-lock-string-face)) "\n"))
     (when-let* ((diff (and (not answer) (plist-get block :diff))))
       (concat (agent-session--indent (agent-session-fontify (string-trim-right diff) 'diff-mode))
               "\n"))
     (if answer
         (agent-session--indent (propertize (concat "→ " answer) 'face 'agent-session-dim))
       (agent-session--indent
        (mapconcat (pcase-lambda (`(,key ,label))
                     (make-text-button (format " %s " label) nil
                                       'type 'agent-session-choice
                                       'action (lambda (_) (agent-session--answer session id key))))
                   (plist-get block :choices) "  ")))
     "\n")))

;;; 界面 API（供后端调用）

(defun agent-session-text (session id text &optional kind)
  "把 TEXT 追加到消息 block ID；KIND 为 assistant（默认）或 thinking。"
  (let ((block (agent-session--block session id)))
    (if (null block)
        (agent-session--new-block session id (list :type 'text :kind (or kind 'assistant)
                                                   :text text))
      ;; 流式输出：直接在 block 末尾追加，不整段重绘。
      (puthash id (plist-put block :text (concat (plist-get block :text) text))
               (agent-session-blocks session))
      (agent-session--with-buffer session
        (let ((end (plist-get block :end)))
          (goto-char (1- end))                    ; 末尾换行之前
          (insert (agent-session--ro (agent-session--indent
                                      (if (eq (plist-get block :kind) 'thinking)
                                          (propertize text 'face 'agent-session-thinking)
                                        text)))))))))

(defun agent-session-text-done (session id &optional text)
  "消息 block ID 输出完毕；TEXT 非空时以它为最终全文。重绘为 markdown。"
  (if (agent-session--block session id)
      (apply #'agent-session--update session id :done t (and text (list :text text)))
    (when (and text (not (string-blank-p text)))
      (agent-session--new-block session id (list :type 'text :kind 'assistant :text text :done t)))))

(defun agent-session-tool (session id &rest props)
  "创建或更新工具 block ID。PROPS：:kind :title :status :output :diff :note。"
  (apply #'agent-session--update session id
         (if (agent-session--block session id) props (append (list :type 'tool) props))))

(defun agent-session-tool-output (session id delta)
  "把输出增量 DELTA 追加到工具 block ID。"
  (when-let* ((block (agent-session--block session id)))
    (agent-session--update session id :output (concat (plist-get block :output) delta))))

(cl-defun agent-session-ask (session &key title detail diff choices callback)
  "请用户确认。CHOICES 为 ((KEY 标签) ...)，用户选择后以 KEY 调用 CALLBACK。"
  (let ((id (symbol-name (gensym "ask-"))))
    (agent-session--new-block session id (list :type 'ask :title title :detail detail :diff diff
                                               :choices choices :callback callback))
    (agent-session--refresh-header session)
    (message "%s 需要确认：%s（C-c C-y 允许，C-c C-n 拒绝）"
             (agent-session-title session) title)
    id))

(defun agent-session--answer (session id key)
  "以 KEY 回答确认请求 ID。"
  (let ((block (agent-session--block session id)))
    (unless (plist-get block :answer)
      (agent-session--update session id
                             :answer (cadr (assq key (plist-get block :choices))))
      (funcall (plist-get block :callback) key)
      (agent-session--refresh-header session))))

(defun agent-session-notice (session text &optional face)
  "在对话中插入一行提示。"
  (agent-session--new-block session (format "notice-%s" (random)) (list :type 'notice :text text
                                                                       :face face)))

(defun agent-session-set-info (session &rest props)
  "更新 header-line 上的信息：:model :tokens :cost 等。"
  (cl-loop for (key value) on props by #'cddr
           do (setf (agent-session-info session)
                    (plist-put (agent-session-info session) key value)))
  (agent-session--refresh-header session))

(defun agent-session--settle (session)
  "回合结束或进程退出时收尾：仍在运行的工具标为中断，未回答的确认作废。"
  (maphash (lambda (id block)
             (pcase (plist-get block :type)
               ('tool (when (eq (plist-get block :status) 'running)
                        (agent-session--update session id :status 'error :note "已中断")))
               ('ask (unless (plist-get block :answer)
                       (agent-session--update session id :answer "已失效")))
               ('text (unless (plist-get block :done)
                        (agent-session--update session id :done t)))))
           (agent-session-blocks session)))

(defun agent-session-set-status (session status)
  "设置会话状态：idle / running / exited。空闲时发送排队的消息。"
  (setf (agent-session-status session) status)
  (when (memq status '(idle exited))
    (agent-session--settle session))
  (agent-session--refresh-header session)
  (when (and (eq status 'idle) (agent-session-queue session))
    (let ((next (pop (agent-session-queue session))))
      ;; 排队时显示在当时的末尾；真正发出时移到对话末尾，保持记录顺序与实际一致。
      (agent-session--remove-block session (car next))
      (agent-session--new-block session (car next) (list :type 'user :text (cdr next)))
      (agent-session--deliver session (cdr next)))))

;;; header-line

(defun agent-session--pending-asks (session)
  "SESSION 中尚未回答的确认请求 id，按出现先后排列。"
  (let (ids)
    (maphash (lambda (id block)
               (when (and (eq (plist-get block :type) 'ask) (not (plist-get block :answer)))
                 (push (cons (marker-position (plist-get block :start)) id) ids)))
             (agent-session-blocks session))
    (mapcar #'cdr (sort ids :key #'car))))

(defun agent-session--header (session)
  "header-line 内容。"
  (let ((info (agent-session-info session)))
    (concat
     " "
     (propertize (agent-session-title session) 'face 'agent-session-assistant)
     (propertize (format "  %s" (file-name-nondirectory
                                 (directory-file-name (agent-session-root session))))
                 'face 'agent-session-dim)
     (if-let* ((model (plist-get info :model)))
         (propertize (format "  %s" model) 'face 'agent-session-dim)
       "")
     "  "
     (cond ((agent-session--pending-asks session)
            (propertize "● 等待确认" 'face 'agent-session-ask))
           (t (pcase (agent-session-status session)
                ('starting (propertize "○ 启动中" 'face 'agent-session-dim))
                ('running (propertize "● 运行中" 'face 'warning))
                ('idle (propertize "● 空闲" 'face 'agent-session-ok))
                ('exited (propertize "○ 已退出" 'face 'agent-session-error)))))
     (if-let* ((tokens (plist-get info :tokens)))
         (propertize (format "  %.1fk tokens" (/ tokens 1000.0)) 'face 'agent-session-dim)
       "")
     (if-let* ((cost (plist-get info :cost)))
         (propertize (format "  $%.3f" cost) 'face 'agent-session-dim)
       ""))))

(defun agent-session--refresh-header (session)
  "刷新 SESSION 的 header-line。"
  (when (buffer-live-p (agent-session-buffer session))
    (with-current-buffer (agent-session-buffer session)
      (force-mode-line-update))))

;;; 输入

(defvar-local agent-session--history-index nil "当前浏览到的输入历史位置。")

(defun agent-session--input-text (session)
  "输入区的文本。"
  (with-current-buffer (agent-session-buffer session)
    (buffer-substring-no-properties (agent-session-input session) (point-max))))

(defun agent-session--deliver (session text)
  "把 TEXT 交给后端发送。"
  (agent-session-set-status session 'running)
  (agent-session-backend-send (agent-session-backend session) session text))

(defun agent-session-submit (session text)
  "以用户身份发送 TEXT：显示在对话中；agent 正忙时排队。"
  (let ((id (format "user-%s" (random)))
        (busy (memq (agent-session-status session) '(running starting))))
    (agent-session--new-block session id (list :type 'user :text text :queued busy))
    (if busy
        (setf (agent-session-queue session)
              (append (agent-session-queue session) (list (cons id text))))
      (agent-session--deliver session text))))

(defun agent-session-send-input ()
  "发送输入区的内容。"
  (interactive)
  (let* ((session (agent-session--this))
         (text (string-trim (agent-session--input-text session))))
    (when (string-empty-p text) (user-error "输入为空"))
    (when (eq (agent-session-status session) 'exited) (user-error "agent 进程已退出"))
    (push text (agent-session-history session))
    (setq agent-session--history-index nil)
    (delete-region (agent-session-input session) (point-max))
    (agent-session-submit session text)))

(defun agent-session--history-step (step)
  "在输入历史中移动 STEP。"
  (let* ((session (agent-session--this))
         (history (agent-session-history session))
         (index (+ (or agent-session--history-index -1) step)))
    (cond ((< index 0)
           (setq agent-session--history-index nil)
           (delete-region (agent-session-input session) (point-max)))
          ((< index (length history))
           (setq agent-session--history-index index)
           (delete-region (agent-session-input session) (point-max))
           (goto-char (point-max))
           (insert (nth index history)))
          (t (user-error "没有更早的输入")))))

(defun agent-session-previous-input ()
  "上一条输入。"
  (interactive)
  (agent-session--history-step 1))

(defun agent-session-next-input ()
  "下一条输入。"
  (interactive)
  (agent-session--history-step -1))

(defun agent-session-interrupt ()
  "中断 agent 当前的回合，并清空排队的消息。"
  (interactive)
  (let ((session (agent-session--this)))
    (setf (agent-session-queue session) nil)
    (agent-session-backend-interrupt (agent-session-backend session) session)
    (agent-session-notice session "已中断")))

(defun agent-session--answer-latest (key-fn)
  "用 KEY-FN 从最早的待确认请求的选项中挑一个作答。"
  (let* ((session (agent-session--this))
         (id (or (car (agent-session--pending-asks session)) (user-error "没有待确认的请求")))
         (choices (plist-get (agent-session--block session id) :choices)))
    (agent-session--answer session id (funcall key-fn choices))))

(defun agent-session-approve ()
  "允许最早的待确认请求（第一个选项）。"
  (interactive)
  (agent-session--answer-latest #'caar))

(defun agent-session-deny ()
  "拒绝最早的待确认请求（最后一个选项）。"
  (interactive)
  (agent-session--answer-latest (lambda (choices) (car (car (last choices))))))

(defun agent-session-goto-input ()
  "跳到输入区末尾。"
  (interactive)
  (goto-char (point-max)))

;;; 模式

(defvar-keymap agent-session-mode-map
  :doc "agent 会话的按键。"
  "C-c C-c" #'agent-session-send-input
  "C-c C-k" #'agent-session-interrupt
  "C-c C-y" #'agent-session-approve
  "C-c C-n" #'agent-session-deny
  "M-p" #'agent-session-previous-input
  "M-n" #'agent-session-next-input
  "C-c C-i" #'agent-session-goto-input
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode agent-session-mode fundamental-mode "Agent"
  "Emacs 渲染的 agent 会话。上方为对话记录，最下方为输入区。"
  (setq-local truncate-lines nil
              word-wrap t
              word-wrap-by-category t
              header-line-format '(:eval (agent-session--header agent-session--current)))
  ;; 对话记录不断插入到输入区之前，undo 记录的位置会错乱，所以关闭 undo。
  (buffer-disable-undo))

(defun agent-session--this ()
  "当前 buffer 的会话，没有时报错。"
  (or agent-session--current (user-error "不在 agent 会话中")))

(defun agent-session--setup-buffer (session)
  "初始化会话 buffer 的布局：对话记录、分隔线、输入区。"
  (with-current-buffer (agent-session-buffer session)
    (agent-session-mode)
    (setq agent-session--current session)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert (agent-session--ro
               (propertize (concat "\n──── C-c C-c 发送 · C-c C-k 中断 · "
                                   "C-c C-y / C-c C-n 允许 / 拒绝 · M-p 历史 ────\n")
                           'face 'agent-session-dim)))
      (setf (agent-session-input session) (point-marker))
      ;; 对话记录插在分隔线之前。标记要在插入分隔线之后再建：
      ;; 它随插入后移，若先建，插入分隔线时会被推到分隔线后面。
      (setf (agent-session-tail session) (copy-marker (point-min) t)))))

;;; 会话管理

(defun agent-session-buffer-p (buffer)
  "BUFFER 是否为 agent 会话。"
  (and (buffer-live-p buffer)
       (buffer-local-value 'agent-session--current buffer)
       t))

(defun agent-session--root ()
  "当前上下文的项目根目录，没有项目时用 `default-directory'。"
  (expand-file-name
   (if-let* ((project (project-current)))
       (project-root project)
     default-directory)))

(defun agent-session-buffers (&optional root agent)
  "按最近使用排序的会话 buffer；可按 ROOT 和 AGENT 过滤。"
  (seq-filter (lambda (buffer)
                (when-let* ((session (and (buffer-live-p buffer)
                                          (buffer-local-value 'agent-session--current buffer))))
                  (and (or (null root) (equal root (agent-session-root session)))
                       (or (null agent) (eq agent (agent-session-agent session))))))
              (buffer-list)))

(defun agent-session--visible-window ()
  "当前框架中显示会话的窗口。"
  (seq-find (lambda (window) (agent-session-buffer-p (window-buffer window)))
            (window-list nil 'no-minibuf)))

(defun agent-session-target ()
  "当前操作的目标会话 buffer：可见的 > 本项目最近的 > 任意最近的。"
  (or (when-let* ((window (agent-session--visible-window)))
        (window-buffer window))
      (car (agent-session-buffers (agent-session--root)))
      (car (agent-session-buffers))))

(defun agent-session-display (buffer)
  "在右侧的 agent 列显示 BUFFER，返回窗口。"
  (or (get-buffer-window buffer)
      (when-let* ((window (agent-session--visible-window)))
        (set-window-buffer window buffer)
        window)
      (display-buffer buffer
                      `((display-buffer-in-direction)
                        (direction . right)
                        (window . main)
                        (window-width . ,agent-session-window-width)))))

(defun agent-session--read-agent ()
  "选择一个已注册的 agent。"
  (intern (completing-read "Agent: " (reverse (mapcar #'car agent-session-agents)) nil t)))

;;;###autoload
(defun agent-session-start (agent &optional new resume root)
  "打开当前项目的 AGENT 会话；NEW 非空（前缀参数）时总是新建。
RESUME 为要恢复的历史会话 id；ROOT 默认为当前项目根目录。"
  (interactive (list (agent-session--read-agent) current-prefix-arg))
  (unless (server-running-p) (server-start))
  (let ((root (or root (agent-session--root))))
    (if-let* ((existing (if resume
                            (seq-find (lambda (b) (equal resume (agent-session-resume-id
                                                                 (buffer-local-value
                                                                  'agent-session--current b))))
                                      (agent-session-buffers))
                          (and (not new) (car (agent-session-buffers root agent))))))
        (select-window (agent-session-display existing))
      (let* ((buffer (generate-new-buffer
                      (format "*%s@%s*" agent (file-name-nondirectory (directory-file-name root)))))
             (session (agent-session--make
                       :agent agent
                       :backend (or (agent-session--get agent :backend)
                                    (user-error "未注册 agent：%s" agent))
                       :root root :buffer buffer
                       :state (and resume (list :resume resume))
                       :settings (copy-sequence
                                  (alist-get agent agent-session-last-settings)))))
        (agent-session--setup-buffer session)
        (with-current-buffer buffer
          (setq default-directory root)
          (add-hook 'kill-buffer-hook
                    (lambda () (agent-session-backend-stop (agent-session-backend session) session))
                    nil t))
        (select-window (agent-session-display buffer))
        (goto-char (point-max))
        (agent-session-backend-start (agent-session-backend session) session)
        buffer))))

;;;###autoload
(defun agent-session-toggle ()
  "显示或隐藏 agent 列；没有会话时先选择 agent 启动。"
  (interactive)
  (if-let* ((window (agent-session--visible-window)))
      (if (one-window-p) (switch-to-buffer (other-buffer)) (delete-window window))
    (if-let* ((buffer (agent-session-target)))
        (select-window (agent-session-display buffer))
      (call-interactively #'agent-session-start))))

;;;###autoload
(defun agent-session-switch ()
  "在所有会话之间切换。"
  (interactive)
  (let ((buffers (mapcar #'buffer-name (agent-session-buffers))))
    (unless buffers (user-error "还没有 agent 会话"))
    (select-window (agent-session-display
                    (get-buffer (completing-read "会话: " buffers nil t))))))

(defun agent-session-kill ()
  "结束当前（或目标）会话。"
  (interactive)
  (let ((buffer (if (agent-session-buffer-p (current-buffer))
                    (current-buffer)
                  (agent-session-target))))
    (unless buffer (user-error "没有 agent 会话"))
    (when (yes-or-no-p (format "结束 %s？" (buffer-name buffer)))
      (kill-buffer buffer))))

;;; 从代码 buffer 引用到输入区

(defun agent-session-insert-input (buffer text)
  "把 TEXT 插入会话 BUFFER 的输入区末尾，并跳过去继续输入。"
  (select-window (agent-session-display buffer))
  (goto-char (point-max))
  (unless (or (= (point) (agent-session-input agent-session--current))
              (memq (char-before) '(?\s ?\n)))
    (insert " "))
  (insert text))

;;;###autoload
(defun agent-session-insert-reference ()
  "把当前文件（有选区时带行号范围）的引用插入会话输入区。"
  (interactive)
  (let* ((buffer (or (agent-session-target) (user-error "没有 agent 会话")))
         (root (agent-session-root (buffer-local-value 'agent-session--current buffer)))
         (file (or buffer-file-name (user-error "当前 buffer 没有对应文件")))
         (lines (and (use-region-p)
                     (format ":%d-%d" (line-number-at-pos (region-beginning))
                             (line-number-at-pos (max (region-beginning) (1- (region-end))))))))
    (deactivate-mark)
    (agent-session-insert-input buffer (concat (file-relative-name file root) lines " "))))

;;;###autoload
(defun agent-session-insert-region (start end)
  "把选区代码连同出处，作为代码块插入会话输入区。"
  (interactive "r")
  (let* ((buffer (or (agent-session-target) (user-error "没有 agent 会话")))
         (root (agent-session-root (buffer-local-value 'agent-session--current buffer)))
         (where (if buffer-file-name
                    (format "%s:%d-%d" (file-relative-name buffer-file-name root)
                            (line-number-at-pos start)
                            (line-number-at-pos (max start (1- end))))
                  (buffer-name)))
         (lang (string-remove-suffix "-ts" (string-remove-suffix "-mode" (symbol-name major-mode))))
         (code (buffer-substring-no-properties start end)))
    (deactivate-mark)
    (agent-session-insert-input buffer (format "\n%s\n```%s\n%s\n```\n" where lang code))))

;;; 注册 agent

(defvar-keymap agent-session-command-map
  :doc "agent 命令前缀表；各 agent 的启动键由 `agent-session-define-agent' 加入。"
  "a" #'agent-session-toggle
  "n" #'agent-session-start
  "s" #'agent-session-switch
  "k" #'agent-session-kill
  "f" #'agent-session-insert-reference
  "r" #'agent-session-insert-region)

(defmacro agent-session-define-agent (name &rest plist)
  "注册 agent NAME，并定义命令 agent-session-NAME。
PLIST：:backend 后端符号（默认同 NAME），:title 显示名，:key 在
`agent-session-command-map' 中的启动键。"
  (declare (indent 1))
  (let ((command (intern (format "agent-session-%s" name)))
        (key (plist-get plist :key)))
    `(progn
       (setf (alist-get ',name agent-session-agents)
             (list :backend ',(or (plist-get plist :backend) name)
                   :title ,(or (plist-get plist :title) (capitalize (symbol-name name)))
                   :key ,key))
       (defun ,command (&optional new)
         ,(format "打开当前项目的 %s 会话；前缀参数时新建。" name)
         (interactive "P")
         (agent-session-start ',name new))
       ,(when key `(keymap-set agent-session-command-map ,key #',command))
       ',command)))

(provide 'agent-session)
;;; agent-session.el ends here
