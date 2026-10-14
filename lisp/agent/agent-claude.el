;;; agent-claude.el --- Claude Code 后端（stream-json） -*- lexical-binding: t; -*-

;;; Commentary:

;; 以 `claude -p --input-format stream-json --output-format stream-json' 运行一个长驻进程：
;;   - 用户消息：{"type":"user","message":{"role":"user","content":...}}
;;   - 输出：stream_event（流式增量）、assistant / user（完整消息、工具结果）、result（回合结束）
;;   - 权限：--permission-prompt-tool stdio，CLI 发来 control_request(can_use_tool)，
;;     我们回复 control_response；启动后需先发 initialize 控制请求。
;; emacs MCP server 通过 --mcp-config 只注入给本进程，不改全局配置。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)

(defgroup agent-claude nil
  "Claude Code 后端。"
  :group 'agent-session
  :prefix "agent-claude-")

(defcustom agent-claude-executable "claude"
  "claude 命令。"
  :type 'string)

(defcustom agent-claude-extra-args nil
  "额外的命令行参数。"
  :type '(repeat string))

(defconst agent-claude--modes
  '((ask . "default") (edits . "acceptEdits") (auto . "auto")
    (full . "bypassPermissions") (plan . "plan"))
  "统一权限模式到 Claude permission mode 的映射。")

(defun agent-claude--mode (session)
  "SESSION 当前权限模式对应的 Claude 取值。"
  (alist-get (agent-session-setting session :mode) agent-claude--modes "default"))

(defun agent-claude--command (session)
  "启动 SESSION 的命令行。模型、推理强度、权限模式取自会话设置。"
  (append
   (list agent-claude-executable "-p"
         "--input-format" "stream-json" "--output-format" "stream-json"
         "--verbose" "--include-partial-messages"
         "--permission-prompt-tool" "stdio"
         "--mcp-config" (json-serialize
                         (list :mcpServers
                               (list :emacs (list :command (car (agent-session-emx-command))
                                                  :args (vconcat (cdr (agent-session-emx-command))))))))
   ;; 允许之后在会话中切换到“完全访问”；是否启用由 --permission-mode 决定。
   (list "--allow-dangerously-skip-permissions"
         "--permission-mode" (agent-claude--mode session))
   (when-let* ((model (agent-session-setting session :model)))
     (unless (equal model "default") (list "--model" model)))
   (when-let* ((effort (agent-session-setting session :effort)))
     (list "--effort" effort))
   (when-let* ((resume (plist-get (agent-session-state session) :resume)))
     (list "--resume" resume))
   agent-claude-extra-args))

(defun agent-claude--state (session key)
  "读取 SESSION 的后端状态 KEY。"
  (plist-get (agent-session-state session) key))

(defun agent-claude--set (session key value)
  "设置 SESSION 的后端状态 KEY。"
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-claude--control (session request &optional callback)
  "向 CLI 发送控制请求 REQUEST；收到成功响应后以响应内容调用 CALLBACK。"
  (let ((id (symbol-name (gensym "emacs-"))))
    (when callback
      (agent-claude--set session :callbacks
                         (cons (cons id callback) (agent-claude--state session :callbacks))))
    (agent-session-write session (list :type "control_request" :request_id id :request request))))

;;; 历史会话（~/.claude/projects/<编码后的项目路径>/<session-id>.jsonl）

(defun agent-claude--project-dir (root)
  "项目 ROOT 的会话目录：路径中非字母数字的字符都替换为 -。"
  (expand-file-name (replace-regexp-in-string "[^[:alnum:]]" "-" (directory-file-name
                                                                   (expand-file-name root)))
                    "~/.claude/projects/"))

(defun agent-claude--json-lines (file &optional beg end)
  "FILE 中 BEG 到 END 字节范围内能完整解析的 JSON 行。"
  (with-temp-buffer
    (insert-file-contents file nil beg end)
    (let (result)
      (dolist (line (split-string (buffer-string) "\n" t) (nreverse result))
        (when-let* ((object (ignore-errors
                              (json-parse-string line :object-type 'plist
                                                 :null-object nil :false-object nil))))
          (push object result))))))

(defun agent-claude--user-text (entry)
  "ENTRY 若是用户亲自输入的消息则返回其文本（排除元信息、命令标签、子 agent）。"
  (let ((content (plist-get (plist-get entry :message) :content)))
    (when (and (equal (plist-get entry :type) "user")
               (stringp content)
               (not (plist-get entry :isMeta))
               (not (plist-get entry :isSidechain))
               (not (string-prefix-p "<" (string-trim-left content))))
      content)))

(defun agent-claude--session-title (file)
  "会话文件 FILE 的标题：Claude 生成的标题，否则取第一条用户消息。"
  (let* ((size (file-attribute-size (file-attributes file)))
         (tail (agent-claude--json-lines file (max 0 (- size 65536)) size))
         (custom (seq-find (lambda (e) (equal (plist-get e :type) "custom-title")) (reverse tail))))
    (or (plist-get custom :customTitle)
        (seq-some #'agent-claude--user-text (agent-claude--json-lines file 0 (min size 65536)))
        "（无标题）")))

(cl-defmethod agent-session-backend-history ((_ (eql claude)) root callback)
  (let* ((dir (agent-claude--project-dir root))
         (files (and (file-directory-p dir) (directory-files dir t "\\.jsonl\\'")))
         (mtime (lambda (file)
                  (float-time (file-attribute-modification-time (file-attributes file)))))
         (files (seq-take (sort files :key mtime :reverse t :in-place t) 50)))
    (funcall callback
             (mapcar (lambda (file)
                       (list :id (file-name-base file)
                             :title (car (split-string (string-trim (agent-claude--session-title file))
                                                       "\n"))
                             :time (funcall mtime file)))
                     files))))

(defun agent-claude--replay (session)
  "把恢复的会话的历史记录渲染到 SESSION 中。"
  (let ((file (expand-file-name (concat (agent-claude--state session :resume) ".jsonl")
                                (agent-claude--project-dir (agent-session-root session)))))
    (when (file-exists-p file)
      (dolist (entry (agent-claude--json-lines file))
        (unless (plist-get entry :isSidechain)
          (let ((message (plist-get entry :message)))
            (pcase (plist-get entry :type)
              ;; 回合进行中用户追加的消息，记录为 queued_command 附件。
              ("attachment"
               (let ((attachment (plist-get entry :attachment)))
                 ;; 以 < 开头的是内部消息（例如子 agent 交回的报告），不显示为用户消息。
                 (when (and (equal (plist-get attachment :type) "queued_command")
                            (stringp (plist-get attachment :prompt))
                            (not (string-prefix-p "<" (string-trim-left (plist-get attachment :prompt)))))
                   (agent-session--new-block session (plist-get entry :uuid)
                                             (list :type 'user :text (plist-get attachment :prompt))))))
              ("user"
               (if-let* ((text (agent-claude--user-text entry)))
                   (agent-session--new-block session (plist-get entry :uuid)
                                             (list :type 'user :text text))
                 (agent-claude--tool-results session message)))
              ("assistant"
               (seq-do-indexed
                (lambda (part index)
                  (pcase (plist-get part :type)
                    ("text" (agent-session-text-done
                             session (format "%s-%s" (plist-get message :id) index)
                             (plist-get part :text)))
                    ("tool_use"
                     (apply #'agent-session-tool session (plist-get part :id) :status 'ok
                            (agent-claude--tool-view session (plist-get part :name)
                                                     (plist-get part :input))))))
                (plist-get message :content))))))))
    (agent-session-notice session "—— 以上为历史记录 ——")))

(cl-defmethod agent-session-backend-start ((_ (eql claude)) session)
  (when (and (agent-claude--state session :resume)
             (zerop (hash-table-count (agent-session-blocks session))))
    (agent-claude--replay session))
  (agent-session-start-process session (agent-claude--command session))
  (agent-claude--control
   session (list :subtype "initialize")
   (lambda (response)
     ;; 初始化结果里有模型列表（含各模型支持的推理强度）和斜杠命令。
     (agent-claude--set session :models (plist-get response :models))
     (agent-claude--set session :commands (plist-get response :commands))
     (agent-session-set-status session 'idle))))

(cl-defmethod agent-session-backend-models ((_ (eql claude)) session)
  (mapcar (lambda (model)
            (list :id (plist-get model :value)
                  :name (plist-get model :displayName)
                  :description (plist-get model :description)
                  :efforts (append (plist-get model :supportedEffortLevels) nil)))
          (agent-claude--state session :models)))

(cl-defmethod agent-session-backend-modes ((_ (eql claude)) _session)
  (mapcar #'car agent-claude--modes))

(cl-defmethod agent-session-backend-commands ((_ (eql claude)) session)
  (mapcar (lambda (command)
            (list :name (plist-get command :name)
                  :description (plist-get command :description)
                  :hint (plist-get command :argumentHint)))
          (agent-claude--state session :commands)))

(cl-defmethod agent-session-backend-apply-settings ((_ (eql claude)) session changed)
  (when (memq :model changed)
    (agent-claude--control session (list :subtype "set_model"
                                         :model (agent-session-setting session :model))))
  (when (memq :mode changed)
    (agent-claude--control session (list :subtype "set_permission_mode"
                                         :mode (agent-claude--mode session))))
  ;; 推理强度只能在启动时指定：空闲时立即以 --resume 重启，运行中等回合结束。
  (when (memq :effort changed)
    (if (eq (agent-session-status session) 'running)
        (progn (agent-claude--set session :restart-pending t)
               (agent-session-notice session "推理强度将在本回合结束后生效"))
      (agent-session-restart-process session))))

(cl-defmethod agent-session-backend-send ((_ (eql claude)) session text)
  (agent-session-write session (list :type "user"
                                     :message (list :role "user" :content text))))

(cl-defmethod agent-session-backend-steer ((_ (eql claude)) session text)
  ;; 回合进行中写入的用户消息，CLI 会在下一个间隙（如工具调用之间）插入当前回合。
  (agent-session-write session (list :type "user" :message (list :role "user" :content text)))
  t)

(cl-defmethod agent-session-backend-interrupt ((_ (eql claude)) session)
  (agent-claude--control session (list :subtype "interrupt")))

;;; 工具调用的展示

(defun agent-claude--relative (session path)
  "PATH 相对于项目根目录的形式。"
  (if (and (stringp path) (file-name-absolute-p path))
      (file-relative-name path (agent-session-root session))
    path))

(defun agent-claude--diff (path old new)
  "由替换前后的文本 OLD / NEW 生成简单的 diff。"
  (cl-flet ((lines (prefix text)
              (when (and text (not (string-empty-p text)))
                (mapconcat (lambda (line) (concat prefix line))
                           (split-string (string-remove-suffix "\n" text) "\n")
                           "\n"))))
    (string-join (delq nil (list (concat "--- " path "\n+++ " path)
                                 (lines "-" old)
                                 (lines "+" new)))
                 "\n")))

(defun agent-claude--tool-view (session name input)
  "工具 NAME 及参数 INPUT 的展示：(:kind :title [:diff])。"
  (let ((path (agent-claude--relative session (plist-get input :file_path))))
    (pcase name
      ("Bash" (list :kind 'command
                    :title (car (split-string (or (plist-get input :command) "") "\n"))))
      ("Read" (list :kind 'read :title path))
      ("Write" (list :kind 'edit :title path
                     :diff (agent-claude--diff path nil (plist-get input :content))))
      ("Edit" (list :kind 'edit :title path
                    :diff (agent-claude--diff path (plist-get input :old_string)
                                              (plist-get input :new_string))))
      ("MultiEdit" (list :kind 'edit :title path
                         :diff (mapconcat (lambda (edit)
                                            (agent-claude--diff path (plist-get edit :old_string)
                                                                (plist-get edit :new_string)))
                                          (plist-get input :edits) "\n")))
      ((or "Grep" "Glob") (list :kind 'search
                                :title (format "%s %s" name (or (plist-get input :pattern) ""))))
      ((or "WebFetch" "WebSearch") (list :kind 'web
                                         :title (or (plist-get input :url) (plist-get input :query))))
      ((or "Task" "Agent") (list :kind 'task :title (or (plist-get input :description) name)))
      ("TodoWrite" (list :kind 'plan :title "更新计划"
                         :output (mapconcat (lambda (todo)
                                              (format "%s %s"
                                                      (pcase (plist-get todo :status)
                                                        ("completed" "☑") ("in_progress" "▶") (_ "☐"))
                                                      (plist-get todo :content)))
                                            (plist-get input :todos) "\n")))
      ((pred (string-prefix-p "mcp__"))
       (list :kind 'mcp :title (string-join (cdr (split-string name "__")) " · ")))
      (_ (list :kind 'other :title name)))))

(defun agent-claude--result-text (content)
  "工具结果 CONTENT（字符串或内容块数组）转成文本。"
  (if (stringp content)
      content
    (mapconcat (lambda (part) (or (plist-get part :text) "")) content "\n")))

;;; 消息处理

(defun agent-claude--block-id (session index)
  "当前消息中第 INDEX 个内容块对应的 block id。"
  (format "%s-%s" (agent-claude--state session :message) index))

(defun agent-claude--stream-event (session event)
  "处理流式事件 EVENT。"
  (pcase (plist-get event :type)
    ("message_start"
     (let ((message (plist-get event :message)))
       (agent-claude--set session :message (plist-get message :id))
       (agent-claude--usage session (plist-get message :usage))))
    ("content_block_start"
     (let ((block (plist-get event :content_block)))
       (when (equal (plist-get block :type) "tool_use")
         (agent-session-tool session (plist-get block :id) :kind 'other
                             :title (plist-get block :name) :status 'running))))
    ("content_block_delta"
     (let ((delta (plist-get event :delta))
           (id (agent-claude--block-id session (plist-get event :index))))
       (pcase (plist-get delta :type)
         ("text_delta" (agent-session-text session id (plist-get delta :text)))
         ("thinking_delta"
          (let ((text (plist-get delta :thinking)))
            (unless (string-empty-p (or text ""))
              (agent-session-text session (concat id "-thinking") text 'thinking)))))))
    ("content_block_stop"
     (let ((id (agent-claude--block-id session (plist-get event :index))))
       (agent-session-text-done session id)
       (agent-session-text-done session (concat id "-thinking"))))
    ("message_delta" (agent-claude--usage session (plist-get event :usage)))))

(defun agent-claude--usage (session usage)
  "根据 USAGE 更新上下文 token 数。"
  (when usage
    (let ((tokens (+ (or (plist-get usage :input_tokens) 0)
                     (or (plist-get usage :cache_creation_input_tokens) 0)
                     (or (plist-get usage :cache_read_input_tokens) 0)
                     (or (plist-get usage :output_tokens) 0))))
      (when (> tokens 0) (agent-session-set-info session :tokens tokens)))))

(defun agent-claude--assistant (session message)
  "完整的 assistant 消息：补全工具调用的参数展示。"
  (seq-doseq (part (plist-get message :content))
    (when (equal (plist-get part :type) "tool_use")
      (apply #'agent-session-tool session (plist-get part :id) :status 'running
             (agent-claude--tool-view session (plist-get part :name) (plist-get part :input))))))

(defun agent-claude--tool-results (session message)
  "user 消息中的工具结果：更新对应工具的状态与输出。"
  (let ((content (plist-get message :content)))
    (unless (stringp content)
      (seq-doseq (part content)
        (when (equal (plist-get part :type) "tool_result")
          (let* ((id (plist-get part :tool_use_id))
                 (declined (member id (agent-claude--state session :declined))))
            (agent-session-tool session id
                                :status (cond (declined 'declined)
                                              ((plist-get part :is_error) 'error)
                                              (t 'ok))
                                :output (agent-claude--result-text (plist-get part :content)))))))))

(defun agent-claude--permission (session request-id request)
  "处理权限请求：在会话中询问用户，再回复 CLI。"
  (let* ((input (plist-get request :input))
         (tool-id (plist-get request :tool_use_id))
         (view (agent-claude--tool-view session (plist-get request :tool_name) input))
         (suggestions (plist-get request :permission_suggestions))
         ;; 回传给 CLI 的参数必须与原始 JSON 完全一致。
         (raw-input (agent-session-raw-json "request" "input"))
         (raw-suggestions (agent-session-raw-json "request" "permission_suggestions")))
    (agent-session-ask
     session
     :title (format "%s：%s" (or (plist-get request :display_name) (plist-get request :tool_name))
                    (or (plist-get request :description) (plist-get view :title)))
     :detail (and (eq (plist-get view :kind) 'command) (plist-get input :command))
     :diff (plist-get view :diff)
     :tool tool-id
     :choices (append '((allow "允许"))
                      (when suggestions '((always "本会话允许")))
                      '((deny "拒绝")))
     :callback
     (lambda (choice)
       (when (eq choice 'deny)
         (agent-claude--set session :declined
                            (cons tool-id (agent-claude--state session :declined))))
       (agent-session-write
        session
        (list :type "control_response"
              :response (list :subtype "success" :request_id request-id
                              :response
                              (pcase choice
                                ('deny (list :behavior "deny" :message "用户拒绝了这个操作"))
                                (_ (append (list :behavior "allow"
                                                 :updatedInput (if (hash-table-p raw-input)
                                                                   raw-input
                                                                 (make-hash-table)))
                                           (when (eq choice 'always)
                                             (list :updatedPermissions raw-suggestions))))))))))))

(cl-defmethod agent-session-backend-handle ((_ (eql claude)) session message)
  ;; 子 agent（parent_tool_use_id 非空）的过程不展开显示，只看它的最终结果。
  (unless (plist-get message :parent_tool_use_id)
    (pcase (plist-get message :type)
      ("system"
       (when (equal (plist-get message :subtype) "init")
         (agent-claude--set session :resume (plist-get message :session_id))
         (agent-session-set-info session :model (plist-get message :model))
         (when (eq (agent-session-status session) 'starting)
           (agent-session-set-status session 'idle))))
      ("stream_event" (agent-claude--stream-event session (plist-get message :event)))
      ("assistant" (agent-claude--assistant session (plist-get message :message)))
      ("user" (agent-claude--tool-results session (plist-get message :message)))
      ("result"
       (agent-session-set-info session :cost (plist-get message :total_cost_usd))
       (when (plist-get message :is_error)
         (agent-session-notice session (format "出错：%s" (or (plist-get message :result)
                                                             (plist-get message :subtype)))
                               'agent-session-error))
       (agent-session-set-status session 'idle)
       (when (agent-claude--state session :restart-pending)
         (agent-claude--set session :restart-pending nil)
         (agent-session-restart-process session)))
      ("control_request"
       (let ((request (plist-get message :request))
             (request-id (plist-get message :request_id)))
         (if (equal (plist-get request :subtype) "can_use_tool")
             (agent-claude--permission session request-id request)
           (agent-session-write session
                                (list :type "control_response"
                                      :response (list :subtype "error" :request_id request-id
                                                      :error "Emacs 不支持该请求"))))))
      ("control_response"
       (let* ((response (plist-get message :response))
              (id (plist-get response :request_id))
              (callback (alist-get id (agent-claude--state session :callbacks) nil nil #'equal)))
         (agent-claude--set session :callbacks
                            (assoc-delete-all id (agent-claude--state session :callbacks)))
         (if (equal (plist-get response :subtype) "error")
             (agent-session-notice session (format "控制请求失败：%s" (plist-get response :error))
                                   'agent-session-error)
           (when callback (funcall callback (plist-get response :response)))))))))

(provide 'agent-claude)
;;; agent-claude.el ends here
