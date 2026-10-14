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
(require 'dnd)

;; 在 let 中动态绑定，渲染代码块时不弹出安装 tree-sitter 语法的询问。
(defvar treesit-auto-install-grammar)
(declare-function evil-insert-state "evil-states")
(require 'transient)

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
  input          ; 输入区起点（页脚之后）
  asks           ; 确认请求（按出现先后），显示在页脚而不是对话中
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

(defun agent-session-display-title (session)
  "SESSION 的标题：恢复时带来的标题，否则取第一条用户消息。"
  (or (plist-get (agent-session-info session) :title) "新会话"))

(defun agent-session--title-seed (text)
  "由用户消息 TEXT 生成标题：合并空白，截取前 50 个字符（图片显示为 [图片] 文字）。"
  (let ((text (string-trim (replace-regexp-in-string "[ \t\n]+" " "
                                                     (substring-no-properties text)))))
    (if (> (length text) 50) (concat (substring text 0 50) "…") text)))

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

(cl-defgeneric agent-session-backend-steer (backend session text)
  "把用户消息 TEXT 送进正在进行的回合（引导）。支持时返回非 nil；
默认不支持，由调用方退回到“中断后再发送”。"
  (ignore backend session text)
  nil)

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

(defcustom agent-session-default-mode 'auto
  "新会话默认的权限模式。默认“自动审查”：由 agent 的自动审查放行常规操作，
只在风险较高时询问（与 Claude Code 桌面端的 auto mode 相同）。"
  :type '(choice (const ask) (const edits) (const auto) (const full)))

(defvar agent-session-default-agent nil
  "新建会话时默认使用的 agent：最近一次使用的那个。")

(defvar agent-session-last-settings nil
  "每个 agent 最近一次使用的设置：((AGENT . PLIST) ...)，新会话沿用。")
(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'agent-session-last-settings)
  (add-to-list 'savehist-additional-variables 'agent-session-default-agent))

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
      (agent-session--refresh session))
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

(defvar-keymap agent-session-transcript-map
  :doc "对话记录与页脚上的按键：在其中打字会跳到输入区。"
  :parent button-map
  "RET" #'agent-session-ret
  "<remap> <self-insert-command>" #'agent-session-self-insert-to-input)

(defun agent-session--ro (string)
  "把 STRING 标为对话记录：只读，打字时跳到输入区。"
  (propertize string 'read-only t 'front-sticky '(read-only) 'rear-nonsticky t
              'keymap agent-session-transcript-map))

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
    ('user (agent-session--format-user id block))
    ('text (agent-session--format-text session id block))
    ('tool (agent-session--format-tool id block))
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

(define-button-type 'agent-session-fold
  'face nil 'follow-link t 'action #'agent-session--toggle-fold
  'help-echo "展开 / 收起这一回合的过程")

(defun agent-session--format-user (id block)
  "用户消息；回合已折叠时，下方附一行过程摘要（可点击展开）。"
  (let ((fold (plist-get block :fold)))
    (concat (propertize "▍ 你" 'face 'agent-session-user)
            (cond ((plist-get block :queued) (propertize "  排队中" 'face 'agent-session-dim))
                  ((plist-get block :steer) (propertize "  ↪ 引导" 'face 'agent-session-dim))
                  (t ""))
            "\n"
            (agent-session--indent (plist-get block :text))
            "\n"
            (when (consp fold)
              (concat "  "
                      (make-text-button
                       (concat (if (plist-get fold :collapsed) "▸ " "▾ ")
                               (propertize (plist-get fold :summary) 'face 'agent-session-dim))
                       nil 'type 'agent-session-fold 'agent-session-block id)
                      "\n")))))

(defun agent-session--format-text (session id block)
  "agent 的回复或思考。回复流式输出时显示原文，结束后渲染 markdown；
思考默认折叠成一行，可点击展开。"
  (let ((text (string-trim-right (or (plist-get block :text) ""))))
    (if (eq (plist-get block :kind) 'thinking)
        (let ((collapsed (agent-session--collapsed-p block)))
          (concat
           (make-text-button
            (concat (if collapsed "▸ " "▾ ")
                    (propertize (if (plist-get block :done) "思考" "思考中…")
                                'face 'agent-session-dim))
            nil 'type 'agent-session-toggle 'agent-session-block id)
           "\n"
           (unless collapsed
             (concat (agent-session--indent (propertize text 'face 'agent-session-thinking)) "\n"))))
      (concat
       (propertize (concat "● " (agent-session-title session)) 'face 'agent-session-assistant)
       "\n"
       (agent-session--indent (if (plist-get block :done) (agent-session--markdown text) text))
       "\n"))))

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

(defun agent-session--collapsed-p (block)
  "BLOCK 是否折叠：用户切换过则按其选择；思考默认折叠；
工具调用默认折叠，有 diff 或出错时展开。"
  (cond ((plist-member block :collapsed) (plist-get block :collapsed))
        ((eq (plist-get block :kind) 'thinking) t)
        (t (not (or (plist-get block :diff) (eq (plist-get block :status) 'error))))))

(defun agent-session--format-tool (id block)
  "工具调用：标题行可点击折叠，展开后显示 diff 或输出。"
  (let* ((status (plist-get block :status))
         (diff (plist-get block :diff))
         (output (plist-get block :output))
         (has-body (or diff (and output (not (string-blank-p output)))))
         (collapsed (agent-session--collapsed-p block))
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
  "折叠或展开 BUTTON 所在的 block（工具调用、思考）。"
  (let* ((session agent-session--current)
         (id (button-get button 'agent-session-block)))
    (agent-session--update session id
                           :collapsed (not (agent-session--collapsed-p
                                            (agent-session--block session id))))))

;;; 回合折叠（参考 T3 Code）
;;
;; 回合结束后，用户消息与最终回复之间的过程（工具调用、思考、中间说明）用一个
;; 不可见的 overlay 收起，用户消息下方显示一行摘要，点击可展开。进行中的回合不折叠。

(defconst agent-session--fold-kinds
  '((command . "条命令") (edit . "次编辑") (read . "次读取") (search . "次搜索")
    (web . "次网页访问") (mcp . "次工具调用") (task . "个子任务") (plan . "次计划更新")
    (other . "次其他操作"))
  "摘要中各类工具调用的量词。")

(defun agent-session--blocks-in-order (session)
  "SESSION 的 block，按在 buffer 中的位置排序：((ID . BLOCK) ...)。"
  (let (entries)
    (maphash (lambda (id block) (push (cons id block) entries)) (agent-session-blocks session))
    (sort entries :key (lambda (entry) (marker-position (plist-get (cdr entry) :start))))))

(defun agent-session--fold-summary (tools duration)
  "由工具调用 TOOLS 与用时 DURATION 生成摘要。"
  (let ((counts nil) (failed 0))
    (dolist (tool tools)
      (cl-incf (alist-get (plist-get tool :kind) counts 0))
      (when (memq (plist-get tool :status) '(error declined)) (cl-incf failed)))
    (string-join
     (delq nil
           (append
            (list (format "执行了 %d 个操作" (length tools)))
            (mapcar (pcase-lambda (`(,kind . ,unit))
                      (when-let* ((n (alist-get kind counts))) (format "%d %s" n unit)))
                    agent-session--fold-kinds)
            (list (and (> failed 0) (format "%d 个失败" failed))
                  (and duration (concat "用时 " duration)))))
     " · ")))

(defun agent-session--fold-overlay (session start end)
  "在 START 到 END 之间建一个折叠用的不可见 overlay。"
  (let ((overlay (make-overlay start end (agent-session-buffer session))))
    (overlay-put overlay 'invisible t)
    (overlay-put overlay 'agent-session-fold t)
    (overlay-put overlay 'isearch-open-invisible (lambda (o) (overlay-put o 'invisible nil)))
    overlay))

(defun agent-session--fold-turn (session user-id activity limit &optional duration)
  "折叠以用户消息 USER-ID 开始的回合；ACTIVITY 为其后的 block（按顺序）。
LIMIT 为回合的终点（下一条用户消息的起点，最后一个回合则是对话末尾）。
回合中最后一段 agent 说明保持可见（被打断的回合，其后可能还有工具调用），
它之前与之后的过程分别折叠；过程中没有工具调用时不折叠。"
  (let* ((final (seq-find (lambda (entry) (and (eq (plist-get (cdr entry) :type) 'text)
                                               (eq (plist-get (cdr entry) :kind) 'assistant)))
                          (reverse activity)))
         (before (if final (seq-take-while (lambda (entry) (not (eq entry final))) activity)
                   activity))
         (after (and final (cdr (memq final activity))))
         (tools (seq-keep (lambda (entry) (and (eq (plist-get (cdr entry) :type) 'tool) (cdr entry)))
                          (append before after)))
         (start-of (lambda (entry) (marker-position (plist-get (cdr entry) :start)))))
    (if (null tools)
        (agent-session--update session user-id :fold 'none)
      (agent-session--update
       session user-id
       :fold (list :collapsed t
                   :summary (agent-session--fold-summary tools duration)
                   :overlays
                   (delq nil
                         (list (and before
                                    (agent-session--fold-overlay
                                     session (funcall start-of (car before))
                                     (if final (funcall start-of final) limit)))
                               (and after
                                    (agent-session--fold-overlay
                                     session (funcall start-of (car after)) limit)))))))))

(defun agent-session--fold-turns (session &optional duration)
  "折叠所有已结束、尚未折叠的回合。DURATION 为最近一个回合的用时。"
  (let ((turns nil) (current nil))
    ;; 按用户消息切分回合：((USER-ID . ACTIVITY) ...)
    (dolist (entry (agent-session--blocks-in-order session))
      (cond
       ;; 排队中的消息暂时夹在上一回合中间，发出时会移到末尾，不作为回合分界。
       ((plist-get (cdr entry) :queued))
       ((eq (plist-get (cdr entry) :type) 'user)
        (when current (push current turns))
        (setq current (list (car entry))))
       (current (setcdr (last current) (list entry)))))
    (when current (push current turns))
    (let ((latest (car turns))
          (turns (nreverse turns)))
      (cl-loop for (turn . rest) on turns
               do (let ((user (agent-session--block session (car turn)))
                        (limit (if rest
                                   (marker-position
                                    (plist-get (agent-session--block session (caar rest)) :start))
                                 (marker-position (agent-session-tail session)))))
                    (unless (plist-get user :fold)
                      (agent-session--fold-turn session (car turn) (cdr turn) limit
                                                (and (eq turn latest) duration))))))))

(defun agent-session--toggle-fold (button)
  "展开或收起 BUTTON 所在回合的过程。"
  (let* ((session agent-session--current)
         (id (button-get button 'agent-session-block))
         (fold (plist-get (agent-session--block session id) :fold))
         (collapsed (not (plist-get fold :collapsed))))
    (dolist (overlay (plist-get fold :overlays))
      (overlay-put overlay 'invisible collapsed))
    (agent-session--update session id :fold (plist-put (copy-sequence fold) :collapsed collapsed))))

;;; 界面 API（供后端调用）

(defun agent-session-text (session id text &optional kind)
  "把 TEXT 追加到消息 block ID；KIND 为 assistant（默认）或 thinking。"
  (let ((block (agent-session--block session id)))
    (if (null block)
        (agent-session--new-block session id (list :type 'text :kind (or kind 'assistant)
                                                   :text text))
      (puthash id (plist-put block :text (concat (plist-get block :text) text))
               (agent-session-blocks session))
      (if (eq (plist-get block :kind) 'thinking)
          ;; 思考通常折叠，只需重绘（折叠时只有一行）。
          (when (not (agent-session--collapsed-p block))
            (agent-session--render session id))
        ;; 回复流式输出：直接在 block 末尾追加，不整段重绘。
        (agent-session--with-buffer session
          (let ((end (plist-get block :end)))
            (goto-char (1- end))                    ; 末尾换行之前
            (insert (agent-session--ro (agent-session--indent text)))))))))

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

(cl-defun agent-session-ask (session &key title detail diff choices callback tool)
  "请用户确认。CHOICES 为 ((KEY 标签) ...)，用户选择后以 KEY 调用 CALLBACK。
请求显示在页脚的辅助行；TOOL 为关联的工具 block id，等待与回答的结果标注在它上面，
对话中不再单独插入记录。DIFF 已由工具 block 展示，这里不再重复。"
  (ignore diff)
  (let ((id (symbol-name (gensym "ask-"))))
    (setf (agent-session-asks session)
          (append (agent-session-asks session)
                  ;; :answer 预先占位，回答时原地修改，列表中的这一项随之更新。
                  (list (list :id id :title title :detail detail :choices choices
                              :callback callback :tool tool :answer nil))))
    (when (and tool (agent-session--block session tool))
      (agent-session--update session tool :note "等待确认"))
    (agent-session--refresh session)
    (message "%s 需要确认：%s（C-c C-y 允许，C-c C-n 拒绝）"
             (agent-session-title session) title)
    id))

(defun agent-session--ask (session id)
  "SESSION 中的确认请求 ID。"
  (seq-find (lambda (ask) (equal (plist-get ask :id) id)) (agent-session-asks session)))

(defun agent-session--close-ask (session ask label)
  "把确认请求 ASK 标为已处理，结果 LABEL 标注在关联的工具上。"
  (plist-put ask :answer label)
  (when-let* ((tool (plist-get ask :tool))
              ((agent-session--block session tool)))
    (agent-session--update session tool :note label)))

(defun agent-session--answer (session id key)
  "以 KEY 回答确认请求 ID。"
  (let ((ask (agent-session--ask session id)))
    (unless (or (null ask) (plist-get ask :answer))
      (agent-session--close-ask session ask (cadr (assq key (plist-get ask :choices))))
      (funcall (plist-get ask :callback) key)
      (agent-session--refresh session))))

(defun agent-session-notice (session text &optional face)
  "在对话中插入一行提示。"
  (agent-session--new-block session (format "notice-%s" (random)) (list :type 'notice :text text
                                                                       :face face)))

(defun agent-session-set-info (session &rest props)
  "更新 header-line 上的信息：:model :tokens :cost 等。"
  (cl-loop for (key value) on props by #'cddr
           do (setf (agent-session-info session)
                    (plist-put (agent-session-info session) key value)))
  (agent-session--refresh session))

(defun agent-session--settle (session)
  "回合结束或进程退出时收尾：仍在运行的工具标为中断，未回答的确认作废。"
  (maphash (lambda (id block)
             (pcase (plist-get block :type)
               ('tool (when (eq (plist-get block :status) 'running)
                        (agent-session--update session id :status 'error :note "已中断")))
               ('text (unless (plist-get block :done)
                        (agent-session--update session id :done t)))))
           (agent-session-blocks session))
  (dolist (ask (agent-session-asks session))
    (unless (plist-get ask :answer)
      (agent-session--close-ask session ask "已失效"))))

(defun agent-session-set-status (session status)
  "设置会话状态：idle / running / exited。空闲时发送排队的消息。"
  (let ((previous (agent-session-status session))
        (info (agent-session-info session)))
    (when (and (eq status 'running) (not (eq previous 'running)))
      (setq info (plist-put info :started (current-time))))
    ;; 回合在后台完成时标记为未读，打开会话时清除。
    (when (and (eq previous 'running) (eq status 'idle)
               (not (get-buffer-window (agent-session-buffer session) t)))
      (setq info (plist-put info :unread t)))
    (setf (agent-session-info session) info))
  (let ((finished (and (eq (agent-session-status session) 'running) (eq status 'idle)
                       (plist-get (agent-session-info session) :started))))
    (setf (agent-session-status session) status)
    (when (memq status '(idle exited))
      (agent-session--settle session)
      ;; 回合结束：把已结束的回合折叠成摘要（恢复会话回放后也会走到这里）。
      (agent-session--fold-turns session (and finished (agent-session--elapsed finished)))))
  (agent-session--refresh session)
  (when (and (eq status 'idle) (agent-session-queue session))
    (let ((next (pop (agent-session-queue session))))
      ;; 排队时显示在当时的末尾；真正发出时移到对话末尾，保持记录顺序与实际一致。
      (agent-session--remove-block session (car next))
      (agent-session--new-block session (car next) (list :type 'user :text (cdr next)))
      (agent-session--deliver session (cdr next)))))

;;; 状态栏：agent / 模型 / 推理强度 / 权限模式 / 用量 / 状态

(defun agent-session--pending-asks (session)
  "SESSION 中尚未回答的确认请求 id，按出现先后排列。"
  (mapcar (lambda (ask) (plist-get ask :id))
          (seq-remove (lambda (ask) (plist-get ask :answer)) (agent-session-asks session))))

(defun agent-session--elapsed (since)
  "从 SINCE 到现在的简短时长，如 5s、3m、1h2m。"
  (let ((seconds (round (float-time (time-since since)))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          (t (format "%dh%dm" (/ seconds 3600) (/ (% seconds 3600) 60))))))

(defun agent-session-status-label (session)
  "SESSION 的状态标签（带 face），状态栏与会话列表共用。"
  (cond ((agent-session--pending-asks session)
         (propertize "● 等待确认" 'face 'agent-session-ask))
        (t (pcase (agent-session-status session)
             ('starting (propertize "○ 启动中" 'face 'agent-session-dim))
             ('running (propertize (format "● 工作中 %s"
                                           (agent-session--elapsed
                                            (or (plist-get (agent-session-info session) :started)
                                                (current-time))))
                                   'face 'warning))
             ('idle (if (plist-get (agent-session-info session) :unread)
                        (propertize "● 完成" 'face 'agent-session-ok)
                      (propertize "○ 空闲" 'face 'agent-session-dim)))
             ('exited (propertize "○ 已退出" 'face 'agent-session-error))))))

(defun agent-session--model-label (session)
  "当前模型的显示名。"
  (let ((info (agent-session-model-info session)))
    (or (plist-get info :name)
        (plist-get (agent-session-info session) :model)
        "默认模型")))

(defun agent-session--mode-line-control (label command help)
  "状态栏中可点击的一段：鼠标点击执行 COMMAND。"
  (propertize label
              'mouse-face 'mode-line-highlight
              'help-echo (concat help "（鼠标点击）")
              'local-map (make-mode-line-mouse-map
                          'mouse-1 (lambda (event)
                                     (interactive "e")
                                     (with-selected-window (posn-window (event-start event))
                                       (call-interactively command))))))

(defun agent-session--mode-line (session)
  "会话 buffer 的状态栏内容。"
  (let* ((info (agent-session-info session))
         (mode (agent-session-setting session :mode))
         (sep (propertize " · " 'face 'agent-session-dim)))
    (concat
     " " (agent-session-status-label session) "  "
     (agent-session--mode-line-control
      (propertize (agent-session-title session) 'face 'agent-session-assistant)
      #'agent-session-select-agent "切换 agent")
     sep
     (agent-session--mode-line-control (agent-session--model-label session)
                                       #'agent-session-select-model "切换模型（m）")
     (when (plist-get (agent-session-model-info session) :efforts)
       (concat sep (agent-session--mode-line-control
                    (concat "推理 " (or (agent-session-setting session :effort) "默认"))
                    #'agent-session-select-effort "切换推理强度（e）")))
     sep
     (if (eq mode 'plan)
         (agent-session--mode-line-control (propertize "计划模式" 'face 'warning)
                                           #'agent-session-toggle-plan "退出计划模式（P）")
       (agent-session--mode-line-control (agent-session--mode-label mode)
                                         #'agent-session-select-mode "切换权限模式（M）"))
     (when-let* ((tokens (plist-get info :tokens)))
       (propertize (format "  %.1fk" (/ tokens 1000.0)) 'face 'agent-session-dim))
     (when-let* ((cost (plist-get info :cost)))
       (propertize (format " · $%.2f" cost) 'face 'agent-session-dim))
     (when-let* ((queued (length (agent-session-queue session)))
                 ((> queued 0)))
       (propertize (format "  排队 %d" queued) 'face 'agent-session-dim))
     (propertize (format "  %s" (file-name-nondirectory
                                 (directory-file-name (agent-session-root session))))
                 'face 'agent-session-dim))))

(defvar agent-session--list-refresh-function nil
  "会话列表的刷新函数（由会话列表设置），会话状态变化时调用。")

(defvar agent-session--clock nil "运行中的会话存在时，定时刷新计时。")

(defun agent-session--tick ()
  "刷新运行中会话的状态栏与分隔线上的计时；没有运行中的会话时停止计时器。"
  (let ((running (seq-filter (lambda (b) (eq (agent-session-status
                                              (buffer-local-value 'agent-session--current b))
                                             'running))
                             (agent-session-buffers))))
    (if running
        (dolist (buffer running)
          (agent-session--render-footer (buffer-local-value 'agent-session--current buffer))
          (with-current-buffer buffer (force-mode-line-update)))
      (cancel-timer agent-session--clock)
      (setq agent-session--clock nil))))

(defun agent-session--refresh (session)
  "刷新 SESSION 的页脚与状态栏，并通知会话列表。"
  (when (buffer-live-p (agent-session-buffer session))
    (agent-session--render-footer session)
    (with-current-buffer (agent-session-buffer session)
      (force-mode-line-update))
    (when (and (eq (agent-session-status session) 'running) (not agent-session--clock))
      (setq agent-session--clock (run-with-timer 5 5 #'agent-session--tick)))
    (when agent-session--list-refresh-function
      (funcall agent-session--list-refresh-function))))

;;; 页脚：分隔线、辅助行、提示符（参考 telega 的 chatbuf）
;;
;; buffer 结构：对话记录 | tail | 分隔线 · 辅助行 · 提示符 | input | 输入
;; 对话记录与页脚只读；提示符不可进入（cursor-intangible），其后到 buffer 末尾是输入区。

(defface agent-session-separator '((t :inherit shadow :underline t))
  "对话与输入之间的分隔线。")

(defface agent-session-prompt '((t :inherit (bold font-lock-function-name-face)))
  "输入提示符。")

(defun agent-session--footer (session)
  "页脚文本：分隔线（左侧为进行中的状态）、辅助行、提示符。"
  (let* ((status (agent-session-status session))
         (asks (agent-session--pending-asks session))
         (state (cond (asks (agent-session-status-label session))
                      ((memq status '(running starting exited))
                       (agent-session-status-label session)))))
    (concat
     "\n"
     ;; 分隔线：贯穿窗口宽度的下划线，左侧显示进行中的状态。
     (propertize (concat (if state (concat " " state " ") "")
                         (propertize " " 'display '(space :align-to right)))
                 'face 'agent-session-separator)
     "\n"
     ;; 辅助行：待确认的请求（带选项按钮）与排队中的消息。
     (when-let* ((id (car asks)))
       (let ((ask (agent-session--ask session id)))
         (concat
          (propertize (concat " ⚠ " (plist-get ask :title) "  ") 'face 'agent-session-ask)
          (mapconcat (pcase-lambda (`(,key ,label))
                       (make-text-button (format " %s " label) nil
                                         'type 'agent-session-choice
                                         'action (lambda (_) (agent-session--answer session id key))))
                     (plist-get ask :choices) " ")
          "\n"
          ;; 没有关联工具 block 时，详情（例如命令）只能在这里看到。
          (when-let* ((detail (and (not (agent-session--block session (plist-get ask :tool)))
                                   (plist-get ask :detail))))
            (propertize (concat "   " (truncate-string-to-width
                                       (replace-regexp-in-string "\n" " ⏎ " detail) 200 nil nil "…")
                                "\n")
                        'face 'font-lock-string-face)))))
     (mapconcat (lambda (queued)
                  (concat
                   (propertize (concat " ⏳ 排队：" (agent-session--title-seed (cdr queued)) "  ")
                               'face 'agent-session-dim)
                   (make-text-button " 引导 " nil 'type 'agent-session-choice
                                     'help-echo "立刻送进当前回合"
                                     'action (lambda (_) (agent-session-steer-queued (car queued))))
                   " "
                   (make-text-button " 取消 " nil 'type 'agent-session-choice
                                     'help-echo "撤回这条排队消息"
                                     'action (lambda (_) (agent-session-cancel-queued (car queued))))
                   "\n"))
                (agent-session-queue session) "")
     ;; 提示符：只读、不可进入；其后的文本可编辑。
     (propertize (concat (agent-session-title session) " ❯ ")
                 'face 'agent-session-prompt
                 'cursor-intangible t 'field 'agent-session-prompt))))

(defun agent-session--render-footer (session)
  "重绘 SESSION 的页脚，保持各窗口中输入区内的光标位置与输入内容。"
  (let ((buffer (agent-session-buffer session)))
    (when (and (buffer-live-p buffer) (agent-session-input session))
      (with-current-buffer buffer
        (let* ((input (agent-session-input session))
               (tail (agent-session-tail session))
               (windows (get-buffer-window-list buffer nil t))
               ;; 输入区中的光标记为相对输入起点的偏移，重绘后恢复。
               (offsets (mapcar (lambda (w) (let ((p (window-point w)))
                                              (and (>= p input) (- p input))))
                                windows))
               (offset (and (>= (point) input) (- (point) input)))
               (inhibit-read-only t)
               (inhibit-modification-hooks t)
               (start (marker-position tail)))
          (save-excursion
            (delete-region start input)
            (goto-char start)
            (insert (agent-session--ro (agent-session--footer session)))
            (set-marker tail start)
            (set-marker input (point)))
          (when offset (goto-char (+ input offset)))
          (cl-mapc (lambda (w o) (when o (set-window-point w (+ input o)))) windows offsets))))))

;;; 输入：页脚之后的输入区

(defvar-local agent-session--history-index nil "当前浏览到的输入历史位置。")

(defun agent-session--input-text (session)
  "输入区的文本；图片附件保留为带 `agent-session-image' 属性的占位文字。"
  (with-current-buffer (agent-session-buffer session)
    (let* ((start (agent-session-input session))
           (text (buffer-substring-no-properties start (point-max)))
           (pos start))
      (while (setq pos (text-property-not-all pos (point-max) 'agent-session-image nil))
        (let ((end (next-single-property-change pos 'agent-session-image nil (point-max))))
          (add-text-properties (- pos start) (- end start)
                               (text-properties-at
                                0 (agent-session--image-string
                                   (get-text-property pos 'agent-session-image)))
                               text)
          (setq pos end)))
      text)))

;;; 图片附件
;;
;; 输入区中的图片是一段占位文字“[图片]”，带 `agent-session-image' 属性（文件路径），
;; GUI 中显示为缩略图。消息文本在排队、引导、历史中都保留这个属性，
;; 后端用 `agent-session-message-images' / `agent-session-message-text' 取出图片和文字。

(defcustom agent-session-image-directory (locate-user-emacs-file "var/agent-images/")
  "粘贴的图片保存在这里。"
  :type 'directory :group 'agent-session)

(defconst agent-session--clipboard-image-types
  '((image/png . "png") (image/jpeg . "jpg") (image/gif . "gif") (image/webp . "webp")
    (image/tiff . "tiff"))
  "剪贴板中可作为图片粘贴的类型及扩展名，按优先顺序。")

(defun agent-session--image-string (file)
  "图片附件 FILE 的占位文字；GUI 中显示为缩略图。"
  (apply #'propertize "[图片]"
         'agent-session-image file
         'help-echo (abbreviate-file-name file)
         'rear-nonsticky t
         (when (display-images-p)
           (list 'display (create-image file nil nil
                                        :max-height (* 6 (default-line-height))
                                        :ascent 'center)))))

(defun agent-session-message-images (text)
  "消息 TEXT 中的图片文件，按出现顺序。"
  (let ((pos 0) files)
    (while (setq pos (text-property-not-all pos (length text) 'agent-session-image nil text))
      (push (get-text-property pos 'agent-session-image text) files)
      (setq pos (next-single-property-change pos 'agent-session-image text (length text))))
    (nreverse files)))

(defun agent-session-message-text (text)
  "消息 TEXT 去掉图片占位后的纯文字。"
  (let ((pos 0) parts)
    (while (< pos (length text))
      (let ((next (next-single-property-change pos 'agent-session-image text (length text))))
        (unless (get-text-property pos 'agent-session-image text)
          (push (substring-no-properties text pos next) parts))
        (setq pos next)))
    (string-trim (apply #'concat (nreverse parts)))))

(defun agent-session-image-media-type (file)
  "图片 FILE 的 MIME 类型。"
  (pcase (downcase (or (file-name-extension file) ""))
    ((or "jpg" "jpeg") "image/jpeg")
    ("gif" "image/gif")
    ("webp" "image/webp")
    (_ "image/png")))

(defun agent-session--clipboard-image ()
  "剪贴板中有图片（且没有文字）时保存为文件并返回路径，否则返回 nil。
有文字时按文字粘贴：例如从 Finder 复制的文件，剪贴板里同时有文件名和图标。"
  (when-let* ((targets (ignore-errors (gui-get-selection 'CLIPBOARD 'TARGETS)))
              ((not (seq-some (lambda (type) (seq-contains-p targets type))
                              '(STRING UTF8_STRING text/plain))))
              (type (seq-find (lambda (type) (seq-contains-p targets (car type)))
                              agent-session--clipboard-image-types))
              (data (ignore-errors (gui-get-selection 'CLIPBOARD (car type))))
              ((> (length data) 0)))
    (make-directory agent-session-image-directory t)
    (let* ((base (expand-file-name (format-time-string "%Y%m%d-%H%M%S-%3N")
                                   agent-session-image-directory))
           (file (concat base "." (cdr type))))
      (let ((coding-system-for-write 'no-conversion))
        (write-region data nil file nil 'silent))
      ;; macOS 截图有时只有 TIFF，agent 不支持，转成 PNG。
      (when (equal (cdr type) "tiff")
        (let ((png (concat base ".png")))
          (when (eq 0 (call-process "sips" nil nil nil "-s" "format" "png" file "--out" png))
            (delete-file file)
            (setq file png))))
      file)))

(defun agent-session-insert-image (file)
  "在输入区插入图片附件 FILE（光标不在输入区时插到末尾）。"
  (interactive (list (read-file-name "图片：" nil nil t nil
                                     (lambda (f) (or (file-directory-p f)
                                                     (string-match-p (image-file-name-regexp) f))))))
  (unless (agent-session--in-input-p) (goto-char (point-max)))
  (insert (agent-session--image-string (expand-file-name file))))

(defun agent-session-yank (&optional arg)
  "粘贴：剪贴板中是图片时作为图片附件插入输入区，否则同 `yank'。"
  (interactive "*P")
  (if-let* ((file (agent-session--clipboard-image)))
      (agent-session-insert-image file)
    (unless (agent-session--in-input-p) (goto-char (point-max)))
    (setq this-command 'yank)
    (yank arg)))

(defun agent-session--dnd-file (uri action)
  "拖进会话 buffer 的图片作为附件；其他文件照常打开。"
  (let ((file (dnd-get-local-file-name uri t)))
    (if (and file (string-match-p (image-file-name-regexp) file))
        (progn (agent-session-insert-image file) 'private)
      (dnd-open-file uri action))))

(defun agent-session--in-input-p ()
  "光标是否在输入区。"
  (and agent-session--current (>= (point) (agent-session-input agent-session--current))))

(defun agent-session--deliver (session text)
  "把 TEXT 交给后端发送。"
  (agent-session-set-status session 'running)
  (agent-session-backend-send (agent-session-backend session) session text))

(defun agent-session-submit (session text)
  "以用户身份发送 TEXT：显示在对话中；agent 正忙时排队。"
  (unless (plist-get (agent-session-info session) :title)
    (setf (agent-session-info session)
          (plist-put (agent-session-info session) :title (agent-session--title-seed text))))
  (let ((id (format "user-%s" (random)))
        (busy (memq (agent-session-status session) '(running starting))))
    (agent-session--new-block session id (list :type 'user :text text :queued busy))
    (if busy
        (progn
          (setf (agent-session-queue session)
                (append (agent-session-queue session) (list (cons id text))))
          (agent-session--refresh session))
      (agent-session--deliver session text))))

(defun agent-session-send (session text)
  "处理用户输入的 TEXT：本地 /命令在 Emacs 中执行，其余发给 agent。"
  (let ((text (string-trim text)))
    (unless (string-empty-p text)
      (when (eq (agent-session-status session) 'exited) (user-error "agent 进程已退出"))
      (unless (agent-session--run-local-command session text)
        (agent-session-submit session text)))))

(defun agent-session-send-input ()
  "发送输入区的内容。"
  (interactive)
  (let* ((session (agent-session--this))
         (text (string-trim (agent-session--input-text session))))
    (when (string-empty-p text) (user-error "输入为空"))
    (push text (agent-session-history session))
    (setq agent-session--history-index nil)
    (let ((inhibit-read-only t))
      (delete-region (agent-session-input session) (point-max)))
    (agent-session-send session text)))

(defun agent-session-steer (session text)
  "把 TEXT 送进 SESSION 正在进行的回合（引导）。
agent 不在运行时等同普通发送；后端不支持引导时，中断当前回合后优先发送。"
  (cond
   ((not (eq (agent-session-status session) 'running))
    (agent-session-send session text))
   ;; /model 等本地命令照常在 Emacs 中执行。
   ((agent-session--run-local-command session text))
   (t
    (if (agent-session-backend-steer (agent-session-backend session) session text)
        (agent-session--new-block session (format "user-%s" (random))
                                  (list :type 'user :text text :steer t))
      (let ((id (format "user-%s" (random))))
        (agent-session--new-block session id (list :type 'user :text text :queued t))
        (setf (agent-session-queue session) (cons (cons id text) (agent-session-queue session)))
        (agent-session-backend-interrupt (agent-session-backend session) session)
        (agent-session-notice session "该 agent 不支持引导，已中断当前回合，随后发送")))
    (agent-session--refresh session))))

(defun agent-session-steer-input ()
  "以引导方式发送输入区内容：agent 运行中时立刻送进当前回合，而不是排队。"
  (interactive)
  (let* ((session (agent-session--this))
         (text (string-trim (agent-session--input-text session))))
    (when (string-empty-p text) (user-error "输入为空"))
    (push text (agent-session-history session))
    (setq agent-session--history-index nil)
    (let ((inhibit-read-only t))
      (delete-region (agent-session-input session) (point-max)))
    (agent-session-steer session text)))

(defun agent-session--take-queued (session id)
  "从排队中取出 ID（默认最早一条）并删除其显示，返回 (ID . TEXT)。"
  (let ((entry (if id (assoc id (agent-session-queue session)) (car (agent-session-queue session)))))
    (unless entry (user-error "没有排队的消息"))
    (setf (agent-session-queue session) (delq entry (agent-session-queue session)))
    (agent-session--remove-block session (car entry))
    entry))

(defun agent-session-steer-queued (&optional id)
  "把排队的消息 ID（默认最早一条）转为引导，立刻送进当前回合。"
  (interactive)
  (let ((session (agent-session--this)))
    (agent-session-steer session (cdr (agent-session--take-queued session id)))))

(defun agent-session-cancel-queued (&optional id)
  "撤回排队的消息 ID（默认最早一条），放回输入区以便修改。"
  (interactive)
  (let* ((session (agent-session--this))
         (entry (agent-session--take-queued session id)))
    (agent-session--refresh session)
    (agent-session-insert-input (agent-session-buffer session) (cdr entry))))

(defun agent-session-goto-input ()
  "跳到输入区末尾。"
  (interactive)
  (goto-char (point-max)))

(defun agent-session-ret ()
  "输入区中发送；按钮上执行按钮；对话中其他位置跳到输入区。"
  (interactive)
  (cond ((agent-session--in-input-p) (agent-session-send-input))
        ((button-at (point)) (push-button))
        (t (agent-session-goto-input))))

(defun agent-session-self-insert-to-input ()
  "在对话记录中打字时，跳到输入区末尾并输入。"
  (interactive)
  (goto-char (point-max))
  (call-interactively #'self-insert-command))

(defun agent-session-cancel-dwim ()
  "有输入时清空输入区；没有输入时中断 agent。"
  (interactive)
  (let ((session (agent-session--this)))
    (if (string-blank-p (agent-session--input-text session))
        (agent-session-interrupt)
      (let ((inhibit-read-only t))
        (delete-region (agent-session-input session) (point-max))))))

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

(defun agent-session-focus-input (&optional session)
  "聚焦 SESSION（默认当前或目标会话）的输入区。"
  (interactive)
  (let* ((session (or session agent-session--current
                      (when-let* ((buffer (agent-session-target)))
                        (buffer-local-value 'agent-session--current buffer))
                      (user-error "没有 agent 会话，先用 C-c a n 新建")))
         (window (agent-session-display (agent-session-buffer session))))
    (select-window window)
    (goto-char (point-max))
    (when (bound-and-true-p evil-local-mode)
      (evil-insert-state))))

(defun agent-session-tab ()
  "输入区中补全，对话记录中跳到下一个按钮。"
  (interactive)
  (if (agent-session--in-input-p)
      (completion-at-point)
    (forward-button 1 t)))

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
         (choices (plist-get (agent-session--ask session id) :choices)))
    (agent-session--answer session id (funcall key-fn choices))))

(defun agent-session-approve ()
  "允许最早的待确认请求（第一个选项）。"
  (interactive)
  (agent-session--answer-latest #'caar))

(defun agent-session-deny ()
  "拒绝最早的待确认请求（最后一个选项）。"
  (interactive)
  (agent-session--answer-latest (lambda (choices) (car (car (last choices))))))

(defun agent-session--message-positions ()
  "对话中各条消息（用户与 agent）的起点。"
  (let (positions)
    (maphash (lambda (_id block)
               (let ((pos (marker-position (plist-get block :start))))
                 ;; 跳过被折叠（不可见）的中间说明。
                 (when (and (memq (plist-get block :type) '(user text))
                            (not (invisible-p pos)))
                   (push pos positions))))
             (agent-session-blocks (agent-session--this)))
    (sort positions #'<)))

(defun agent-session-next-message ()
  "跳到下一条消息；没有时跳到输入区。"
  (interactive)
  (if-let* ((pos (seq-find (lambda (p) (> p (point))) (agent-session--message-positions))))
      (goto-char pos)
    (agent-session-goto-input)))

(defun agent-session-previous-message ()
  "跳到上一条消息。"
  (interactive)
  (when-let* ((pos (seq-find (lambda (p) (< p (point))) (reverse (agent-session--message-positions)))))
    (goto-char pos)))

;;; 切换 agent / 模型 / 推理强度 / 权限模式

(defun agent-session--has-conversation (session)
  "SESSION 是否已经有对话（用户消息或 agent 回复）。"
  (catch 'found
    (maphash (lambda (_id block)
               (when (memq (plist-get block :type) '(user text tool))
                 (throw 'found t)))
             (agent-session-blocks session))
    nil))

(defun agent-session--mode-label (mode)
  "权限模式 MODE 的显示名。"
  (or (cadr (assq mode agent-session-modes)) (symbol-name mode)))

(defun agent-session--completing-read (prompt candidates &optional default)
  "带说明的 completing-read。CANDIDATES 为 ((值 . 说明) ...)。"
  (let ((completion-extra-properties
         (list :annotation-function
               (lambda (candidate)
                 (when-let* ((note (cdr (assoc candidate candidates))))
                   (concat "  " (propertize note 'face 'completions-annotations)))))))
    (completing-read prompt (mapcar #'car candidates) nil t nil nil default)))

(defun agent-session-select-model (&optional model)
  "切换当前会话的模型。"
  (interactive)
  (let* ((session (agent-session--this))
         (models (or (agent-session-backend-models (agent-session-backend session) session)
                     (user-error "%s 还没有返回模型列表" (agent-session-title session))))
         (model (or model
                    (agent-session--completing-read
                     "模型: "
                     (mapcar (lambda (m) (cons (plist-get m :id)
                                               (string-join (delq nil (list (plist-get m :name)
                                                                            (plist-get m :description)))
                                                            " · ")))
                             models)
                     (agent-session-setting session :model)))))
    (unless (seq-find (lambda (m) (equal (plist-get m :id) model)) models)
      (user-error "没有模型 %s" model))
    (agent-session-configure session :model model)
    ;; 新模型不支持当前强度时恢复默认。
    (let ((efforts (plist-get (agent-session-model-info session) :efforts))
          (effort (agent-session-setting session :effort)))
      (when (and effort efforts (not (member effort efforts)))
        (agent-session-configure session :effort nil)))))

(defun agent-session-select-effort (&optional effort)
  "切换当前会话的推理强度。"
  (interactive)
  (let* ((session (agent-session--this))
         (info (agent-session-model-info session))
         (efforts (or (plist-get info :efforts)
                      (user-error "当前模型不支持调整推理强度")))
         (effort (or effort
                     (agent-session--completing-read
                      "推理强度: "
                      (mapcar (lambda (e) (cons e (and (equal e (plist-get info :default-effort))
                                                      "默认")))
                              efforts)
                      (agent-session-setting session :effort)))))
    (unless (member effort efforts) (user-error "当前模型不支持强度 %s" effort))
    (agent-session-configure session :effort effort)))

(defun agent-session-select-mode (&optional mode)
  "切换当前会话的权限模式。"
  (interactive)
  (let* ((session (agent-session--this))
         (modes (agent-session-backend-modes (agent-session-backend session) session))
         (mode (or mode
                   ;; 候选同时带中文名与英文名，输入任一种都能匹配，例如“完全访问 full”。
                   (let* ((candidates (mapcar (lambda (m) (cons (format "%s %s"
                                                                       (agent-session--mode-label m) m)
                                                                 (nth 2 (assq m agent-session-modes))))
                                              modes))
                          (label (agent-session--completing-read
                                  "权限模式: " candidates
                                  (car (seq-find (lambda (c) (string-suffix-p
                                                              (format " %s" (agent-session-setting
                                                                             session :mode))
                                                              (car c)))
                                                 candidates)))))
                     (intern (car (last (split-string label " "))))))))
    (unless (memq mode modes) (user-error "%s 不支持该权限模式" (agent-session-title session)))
    (agent-session-configure session :mode mode)))

(defun agent-session-plan-on ()
  "进入计划模式（/plan）：只规划，不改动。"
  (interactive)
  (let* ((session (agent-session--this))
         (mode (agent-session-setting session :mode)))
    (unless (memq 'plan (agent-session-backend-modes (agent-session-backend session) session))
      (user-error "%s 不支持计划模式" (agent-session-title session)))
    (unless (eq mode 'plan)
      (agent-session-configure session :before-plan mode :mode 'plan))))

(defun agent-session-plan-off ()
  "退出计划模式（/default），回到进入前的权限模式。"
  (interactive)
  (let ((session (agent-session--this)))
    (when (eq (agent-session-setting session :mode) 'plan)
      (agent-session-configure session :mode (or (plist-get (agent-session-settings session)
                                                            :before-plan)
                                                 agent-session-default-mode)))))

(defun agent-session-toggle-plan ()
  "切换计划模式。"
  (interactive)
  (if (eq (agent-session-setting (agent-session--this) :mode) 'plan)
      (agent-session-plan-off)
    (agent-session-plan-on)))

(defun agent-session-select-agent (&optional agent)
  "切换 agent。还没有对话时原地替换；否则新开会话并带上输入区草稿。"
  (interactive)
  (let* ((session (agent-session--this))
         (agent (or agent
                    (intern (agent-session--completing-read
                             "Agent: "
                             (mapcar (lambda (a) (cons (symbol-name (car a))
                                                       (plist-get (cdr a) :title)))
                                     (reverse agent-session-agents))
                             (symbol-name (agent-session-agent session)))))))
    (unless (assq agent agent-session-agents) (user-error "未注册 agent：%s" agent))
    (unless (eq agent (agent-session-agent session))
      (if (agent-session--has-conversation session)
          (let ((draft (agent-session--input-text session)))
            (agent-session-insert-input
             (agent-session-start agent t nil (agent-session-root session)) draft))
        (agent-session-backend-stop (agent-session-backend session) session)
        (setf (agent-session-agent session) agent
              (agent-session-backend session) (agent-session--get agent :backend)
              (agent-session-state session) nil
              (agent-session-info session) nil
              (agent-session-settings session)
              (copy-sequence (alist-get agent agent-session-last-settings))
              (agent-session-status session) 'starting)
        (with-current-buffer (agent-session-buffer session)
          (rename-buffer (format "*%s@%s*" agent (file-name-nondirectory
                                                   (directory-file-name (agent-session-root session))))
                         t))
        (agent-session-backend-start (agent-session-backend session) session)))))

(defun agent-session-new ()
  "在同一项目中用同一个 agent 新开会话。"
  (interactive)
  (let ((session (agent-session--this)))
    (agent-session-start (agent-session-agent session) t nil (agent-session-root session))))

(defun agent-session-resume (&optional agent)
  "从 AGENT（默认当前 agent）在本项目的历史会话中选择一个恢复。"
  (interactive)
  (let* ((session agent-session--current)
         (agent (or agent (and session (agent-session-agent session)) (agent-session--read-agent)))
         (root (if session (agent-session-root session) (agent-session--root)))
         (items 'pending))
    (agent-session-backend-history (agent-session--get agent :backend) root
                                   (lambda (result) (setq items result)))
    (with-timeout (20 (user-error "获取历史会话超时"))
      (while (eq items 'pending) (accept-process-output nil 0.05)))
    (unless items (user-error "本项目没有 %s 的历史会话" agent))
    (let* ((candidates (mapcar (lambda (item)
                                 (cons (format "%s  %s" (format-time-string "%m-%d %H:%M"
                                                                            (plist-get item :time))
                                               (plist-get item :title))
                                       (plist-get item :id)))
                               items))
           (choice (completing-read "恢复会话: " candidates nil t)))
      (agent-session-start agent nil (cdr (assoc choice candidates)) root))))

;;; 斜杠命令与补全

(defvar agent-session-local-commands
  '(("model" agent-session-select-model "切换模型" agent-session--model-ids)
    ("effort" agent-session-select-effort "切换推理强度" agent-session--effort-names)
    ("mode" agent-session-select-mode "切换权限模式" agent-session--mode-names)
    ("agent" agent-session-select-agent "切换 agent" agent-session--agent-names)
    ("plan" agent-session-plan-on "进入计划模式：只规划，不改动")
    ("default" agent-session-plan-off "退出计划模式")
    ("new" agent-session-new "新开会话")
    ("resume" agent-session-resume "恢复历史会话")
    ("interrupt" agent-session-interrupt "中断当前回合"))
  "在 Emacs 中执行、不发给 agent 的命令：(名称 函数 说明 [参数候选函数])。
带参数时以参数字符串（模式、agent 转为符号）调用函数。")

(defun agent-session--model-ids (session)
  "SESSION 可选的模型 id。"
  (mapcar (lambda (m) (plist-get m :id))
          (agent-session-backend-models (agent-session-backend session) session)))

(defun agent-session--effort-names (session)
  "SESSION 当前模型支持的推理强度。"
  (plist-get (agent-session-model-info session) :efforts))

(defun agent-session--mode-names (session)
  "SESSION 支持的权限模式名。"
  (mapcar #'symbol-name (agent-session-backend-modes (agent-session-backend session) session)))

(defun agent-session--agent-names (_session)
  "已注册的 agent 名。"
  (mapcar (lambda (a) (symbol-name (car a))) (reverse agent-session-agents)))

(defun agent-session--run-local-command (session text)
  "TEXT 若是本地命令则执行并返回非 nil。"
  (when (string-match "\\`/\\([[:alnum:]-]+\\)\\(?:[ \t]+\\(.*\\)\\)?\\'" text)
    (when-let* ((entry (assoc (match-string 1 text) agent-session-local-commands)))
      (let ((arg (match-string 2 text)))
        (with-current-buffer (agent-session-buffer session)
          (if (and arg (nth 3 entry))
              (funcall (nth 1 entry)
                       (if (memq (nth 1 entry) '(agent-session-select-mode agent-session-select-agent))
                           (intern arg)
                         arg))
            (call-interactively (nth 1 entry)))))
      t)))

(defun agent-session--command-candidates (session)
  "斜杠命令候选：((\"/name\" 说明 参数提示 来源) ...)。"
  (append
   (mapcar (lambda (c) (list (concat "/" (car c)) (nth 2 c) nil 'local)) agent-session-local-commands)
   (mapcar (lambda (c) (list (concat "/" (plist-get c :name)) (plist-get c :description)
                             (plist-get c :hint) 'agent))
           (agent-session-backend-commands (agent-session-backend session) session))))

(defun agent-session--project-files (session)
  "SESSION 项目中的文件（相对路径），用于 @ 补全。"
  (let ((default-directory (agent-session-root session)))
    (when-let* ((project (project-current nil default-directory)))
      (mapcar (lambda (f) (file-relative-name f default-directory))
              (seq-take (project-files project) 20000)))))

(defun agent-session--annotation-width (names)
  "补全弹窗中注释列的宽度：窗口宽度减去最长的命令名，限制在 10 到 70 列。
同时把 corfu 弹窗的最大宽度限制在会话窗口内（agent 列通常较窄）。"
  (let ((window (window-body-width)))
    (setq-local corfu-max-width (max 20 (1- window)))
    (max 10 (min 70 (- window (apply #'max 0 (mapcar #'string-width names)) 6)))))

(defun agent-session--command-annotation (command width)
  "命令 COMMAND 的注释：参数提示与说明，补齐或截断到恰好 WIDTH 列。
corfu 把注释右对齐到弹窗边缘，注释等宽时各行才能对齐成一列。"
  (pcase-let ((`(,_name ,description ,hint ,source) command))
    (concat "  "
            (truncate-string-to-width
             (concat (if (and hint (not (string-empty-p hint)))
                         (propertize (concat hint " ") 'face 'completions-common-part)
                       "")
                     (propertize (concat (if (eq source 'local) "· " "") (or description ""))
                                 'face 'completions-annotations))
             width nil ?\s "…"))))

(defun agent-session-completion-at-point ()
  "输入区的补全：行首的 /命令、命令参数、@文件。
“行首”指提示符之后或换行之后，提示符与输入在同一行。"
  (when-let* ((session agent-session--current)
              ((agent-session--in-input-p)))
    (let* ((start (max (line-beginning-position) (agent-session-input session)))
           (text (buffer-substring-no-properties start (point)))
           (exit (lambda (_name status) (when (eq status 'finished) (insert " ")))))
      (cond
       ;; 命令参数：/model xxx
       ((and (string-match "\\`/\\([[:alnum:]-]+\\)[ \t]+\\([^ \t\n]*\\)\\'" text)
             (nth 3 (assoc (match-string 1 text) agent-session-local-commands)))
        (list (+ start (match-beginning 2)) (point)
              (funcall (nth 3 (assoc (match-string 1 text) agent-session-local-commands)) session)
              :exclusive 'no))
       ;; 行首的 /命令
       ((string-match "\\`/[^ \t\n]*\\'" text)
        (let* ((candidates (agent-session--command-candidates session))
               (width (agent-session--annotation-width (mapcar #'car candidates))))
          (list start (point) (mapcar #'car candidates)
                :exclusive 'no
                :annotation-function
                (lambda (name)
                  (when-let* ((c (assoc name candidates)))
                    (agent-session--command-annotation c width)))
                :exit-function exit)))
       ;; @文件
       ((string-match "\\(?:\\`\\|[ \t]\\)@\\([^ \t\n]*\\)\\'" text)
        (list (+ start (match-beginning 1)) (point)
              (completion-table-with-cache
               (lambda (_) (agent-session--project-files session)))
              :exclusive 'no
              :category 'file
              :exit-function exit))))))

;;; 设置菜单（C-c C-o）

(defun agent-session--menu-value (key)
  "菜单中显示的当前设置值。"
  (when-let* ((session agent-session--current))
    (propertize
     (pcase key
       (:agent (agent-session-title session))
       (:model (agent-session--model-label session))
       (:effort (or (agent-session-setting session :effort) "默认"))
       (:mode (agent-session--mode-label (agent-session-setting session :mode))))
     'face 'transient-value)))

(transient-define-prefix agent-session-menu ()
  "会话设置：agent、模型、推理强度、权限模式，以及会话操作。"
  [["设置"
    ("a" agent-session-select-agent
     :description (lambda () (concat "Agent     " (agent-session--menu-value :agent))))
    ("m" agent-session-select-model
     :description (lambda () (concat "模型      " (agent-session--menu-value :model))))
    ("e" agent-session-select-effort
     :description (lambda () (concat "推理强度  " (agent-session--menu-value :effort))))
    ("p" agent-session-select-mode
     :description (lambda () (concat "权限模式  " (agent-session--menu-value :mode))))
    ("P" "计划模式开 / 关" agent-session-toggle-plan)]
   ["会话"
    ("n" "新会话" agent-session-new)
    ("r" "恢复历史会话" agent-session-resume)
    ("s" "会话列表" agent-session-list)]
   ["回合"
    ("k" "中断" agent-session-interrupt)
    ("g" "引导：最早的排队消息送进当前回合" agent-session-steer-queued)
    ("y" "允许" agent-session-approve)
    ("d" "拒绝" agent-session-deny)]])

;;; 模式

(defvar-keymap agent-session-mode-map
  :doc "agent 会话的按键：输入区中 RET 发送，C-j 换行。"
  "RET" #'agent-session-ret
  "C-j" #'newline
  "M-p" #'agent-session-previous-input
  "M-n" #'agent-session-next-input
  "TAB" #'agent-session-tab
  "<backtab>" #'backward-button
  "C-c C-c" #'agent-session-send-input
  "M-RET" #'agent-session-steer-input
  "C-c C-g" #'agent-session-steer-queued
  "C-c C-k" #'agent-session-cancel-dwim
  "C-c C-o" #'agent-session-menu
  "C-c C-y" #'agent-session-approve
  "C-c C-n" #'agent-session-deny
  "C-c C-i" #'agent-session-goto-input
  "C-c C-b" #'agent-session-previous-message
  "C-c C-f" #'agent-session-next-message
  "C-c C-s" #'agent-session-list
  "C-c C-a" #'agent-session-insert-image
  "<remap> <yank>" #'agent-session-yank)

(define-derived-mode agent-session-mode fundamental-mode "Agent"
  "Emacs 渲染的 agent 会话（参考 telega）：上方是对话，页脚之后是输入区。
\\{agent-session-mode-map}"
  (setq-local truncate-lines nil
              word-wrap t
              word-wrap-by-category t
              scroll-conservatively 101
              header-line-format nil
              mode-line-format '((:eval (agent-session--mode-line agent-session--current))))
  (cursor-intangible-mode 1)
  (setq-local dnd-protocol-alist (cons '("^file:" . agent-session--dnd-file) dnd-protocol-alist))
  (add-hook 'post-command-hook #'agent-session--keep-point-out-of-prompt nil t)
  (add-hook 'completion-at-point-functions #'agent-session-completion-at-point nil t)
  ;; 输入 / 后立即弹出补全。
  (setq-local corfu-auto-prefix 1
              corfu-auto-delay 0.1)
  ;; 对话记录不断插入到输入区之前，undo 记录的位置会错乱，所以关闭 undo。
  (buffer-disable-undo))

(defun agent-session--keep-point-out-of-prompt ()
  "光标落在提示符内时移到输入区起点（与 telega 相同，不依赖 cursor-intangible 的重绘时机）。"
  (when (and agent-session--current
             (eq (get-text-property (point) 'field) 'agent-session-prompt))
    (goto-char (agent-session-input agent-session--current))))

(defun agent-session--this ()
  "当前 buffer 的会话，没有时报错。"
  (or agent-session--current (user-error "不在 agent 会话中")))

(defun agent-session--setup-buffer (session)
  "初始化会话 buffer：对话记录、页脚（分隔线、辅助行、提示符）、输入区。"
  (with-current-buffer (agent-session-buffer session)
    (agent-session-mode)
    (setq agent-session--current session)
    (let ((inhibit-read-only t))
      (erase-buffer))
    ;; 对话记录插在 tail 处（随插入后移）；页脚位于 tail 与 input 之间，
    ;; 由 `agent-session--render-footer' 维护两个标记。
    (setf (agent-session-tail session) (copy-marker (point-min) t)
          (agent-session-input session) (copy-marker (point-min)))
    (agent-session--render-footer session)
    (goto-char (point-max))))

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
  (when-let* ((session (buffer-local-value 'agent-session--current buffer)))
    (when (plist-get (agent-session-info session) :unread)
      (setf (agent-session-info session) (plist-put (agent-session-info session) :unread nil))
      (agent-session--refresh session)))
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
  ;; 批处理（测试）中不启动 server：否则会占用用户 Emacs 的 socket，退出时把它删掉。
  (unless (or noninteractive (server-running-p)) (server-start))
  (setq agent-session-default-agent agent)
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
                    (lambda ()
                      (agent-session-backend-stop (agent-session-backend session) session)
                      ;; buffer 此时尚未删除，稍后再刷新会话列表。
                      (when agent-session--list-refresh-function
                        (run-at-time 0 nil agent-session--list-refresh-function)))
                    nil t))
        (select-window (agent-session-display buffer))
        (goto-char (point-max))
        (agent-session-backend-start (agent-session-backend session) session)
        buffer))))

;;;###autoload
(defun agent-session-create (&optional choose)
  "在当前项目新建会话，使用最近用过的 agent；CHOOSE（前缀参数）时先选择 agent。
会话中随时可以用 /agent 或工具栏切换 agent、模型与推理强度。"
  (interactive "P")
  (let ((buffer (agent-session-start
                 (if (or choose (not (assq agent-session-default-agent agent-session-agents)))
                     (agent-session--read-agent)
                   agent-session-default-agent)
                 t)))
    ;; 交互调用时直接开始输入第一条消息。
    (when (called-interactively-p 'interactive)
      (agent-session-focus-input (buffer-local-value 'agent-session--current buffer)))
    buffer))

;;;###autoload
(defun agent-session-toggle ()
  "显示或隐藏 agent 列；没有会话时先选择 agent 启动。"
  (interactive)
  (if-let* ((window (agent-session--visible-window)))
      (if (one-window-p) (switch-to-buffer (other-buffer)) (delete-window window))
    (if-let* ((buffer (agent-session-target)))
        (select-window (agent-session-display buffer))
      (agent-session-create))))

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
  "把 TEXT 插入会话 BUFFER 的输入区末尾，并聚焦输入区。"
  (with-current-buffer buffer
    (goto-char (point-max))
    (unless (or (= (point) (agent-session-input agent-session--current))
                (memq (char-before) '(?\s ?\n)))
      (insert " "))
    (insert text))
  (agent-session-focus-input (buffer-local-value 'agent-session--current buffer))
  buffer)

;;;###autoload
(defun agent-session-insert-reference ()
  "把当前文件（有选区时带行号范围）的引用带入会话输入。"
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
  "把选区代码连同出处，作为代码块带入会话输入。"
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
  :doc "agent 命令前缀表（C-c a）。"
  "a" #'agent-session-toggle
  "i" #'agent-session-focus-input
  "n" #'agent-session-create
  "s" #'agent-session-list
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
