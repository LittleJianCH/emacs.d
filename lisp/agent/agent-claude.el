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

(defcustom agent-claude-model nil
  "使用的模型，例如 \"opus\"；nil 时用 CLI 的默认设置。"
  :type '(choice (const nil) string))

(defcustom agent-claude-extra-args nil
  "额外的命令行参数。"
  :type '(repeat string))

(defun agent-claude--command (session)
  "启动 SESSION 的命令行。"
  (append
   (list agent-claude-executable "-p"
         "--input-format" "stream-json" "--output-format" "stream-json"
         "--verbose" "--include-partial-messages"
         "--permission-prompt-tool" "stdio"
         "--mcp-config" (json-serialize
                         (list :mcpServers
                               (list :emacs (list :command (car (agent-session-emx-command))
                                                  :args (vconcat (cdr (agent-session-emx-command))))))))
   (when agent-claude-model (list "--model" agent-claude-model))
   (when-let* ((resume (plist-get (agent-session-state session) :resume)))
     (list "--resume" resume))
   agent-claude-extra-args))

(defun agent-claude--state (session key)
  "读取 SESSION 的后端状态 KEY。"
  (plist-get (agent-session-state session) key))

(defun agent-claude--set (session key value)
  "设置 SESSION 的后端状态 KEY。"
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-claude--control (session request)
  "向 CLI 发送控制请求 REQUEST。"
  (agent-session-write session (list :type "control_request"
                                     :request_id (symbol-name (gensym "emacs-"))
                                     :request request)))

(cl-defmethod agent-session-backend-start ((_ (eql claude)) session)
  (agent-session-start-process session (agent-claude--command session))
  (agent-claude--control session (list :subtype "initialize")))

(cl-defmethod agent-session-backend-send ((_ (eql claude)) session text)
  (agent-session-write session (list :type "user"
                                     :message (list :role "user" :content text))))

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
     (agent-session-text-done session (agent-claude--block-id session (plist-get event :index))))
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
       (agent-session-set-status session 'idle))
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
       (let ((response (plist-get message :response)))
         (if (equal (plist-get response :subtype) "error")
             (agent-session-notice session (format "控制请求失败：%s" (plist-get response :error))
                                   'agent-session-error)
           ;; initialize 完成后即可输入；system/init 要等第一条消息才会出现。
           (when (eq (agent-session-status session) 'starting)
             (agent-session-set-status session 'idle))))))))

(provide 'agent-claude)
;;; agent-claude.el ends here
