;;; agent-codex.el --- Codex 后端（app-server JSON-RPC） -*- lexical-binding: t; -*-

;;; Commentary:

;; 以 `codex app-server' 运行，stdio 上逐行 JSON-RPC：
;;   initialize → initialized → thread/start → turn/start / turn/interrupt
;;   通知：turn/*、item/started、item/completed、item/*/delta、thread/tokenUsage/updated
;;   服务端请求：item/commandExecution/requestApproval、item/fileChange/requestApproval
;; emacs MCP server 通过 -c mcp_servers.emacs.* 只注入本进程，不改 ~/.codex/config.toml。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)

(defgroup agent-codex nil
  "Codex 后端。"
  :group 'agent-session
  :prefix "agent-codex-")

(defcustom agent-codex-executable "codex"
  "codex 命令。"
  :type 'string)

(defconst agent-codex--modes
  ;; 与 T3 Code 相同的映射：(审批策略 沙箱 thread/start 用的沙箱名 审批者)
  '((ask "untrusted" "readOnly" "read-only" "user")
    (edits "on-request" "workspaceWrite" "workspace-write" "user")
    (auto "on-request" "workspaceWrite" "workspace-write" "auto_review")
    (full "never" "dangerFullAccess" "danger-full-access" "user"))
  "统一权限模式到 Codex 审批策略与沙箱的映射。")

(defun agent-codex--mode (session)
  "SESSION 当前权限模式的 Codex 设置：(审批策略 沙箱策略类型 沙箱名 审批者)。"
  (or (alist-get (agent-session-setting session :mode) agent-codex--modes)
      (alist-get 'edits agent-codex--modes)))

(defcustom agent-codex-extra-args nil
  "额外的命令行参数（放在 app-server 之后），例如 (\"-c\" \"model_reasoning_effort=\\\"high\\\"\")。"
  :type '(repeat string))

(defun agent-codex--toml-string (string)
  "STRING 的 TOML 字符串字面量。"
  (concat "\"" (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" string) "\""))

(defun agent-codex--command (session)
  "启动 SESSION 的命令行。"
  (let* ((emx (agent-session-emx-command))
         ;; codex 启动 MCP server 时不会传递全部环境变量，emx 需要的显式给出。
         ;; 环境列表中同名变量可能出现多次，前面的生效，TOML 表里只能写一次。
         (env (mapcar (lambda (name)
                        (let ((entry (seq-find (lambda (e) (string-prefix-p (concat name "=") e))
                                               (agent-session-environment session))))
                          (format "%s=%s" name (agent-codex--toml-string
                                                (substring entry (1+ (length name)))))))
                      '("PATH" "EMACS_SOCKET_NAME" "EMX_AGENT_BUFFER"))))
    (append
     (list agent-codex-executable "app-server"
           "-c" (concat "mcp_servers.emacs.command=" (agent-codex--toml-string (car emx)))
           "-c" (format "mcp_servers.emacs.args=[%s]"
                        (mapconcat #'agent-codex--toml-string (cdr emx) ","))
           "-c" (format "mcp_servers.emacs.env={%s}" (string-join env ",")))
     agent-codex-extra-args)))

;;; JSON-RPC

(defun agent-codex--state (session key)
  "读取 SESSION 的后端状态 KEY。"
  (plist-get (agent-session-state session) key))

(defun agent-codex--set (session key value)
  "设置 SESSION 的后端状态 KEY。"
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-codex--request (session method params &optional callback)
  "发送 JSON-RPC 请求；收到结果后以 result 调用 CALLBACK。"
  (let ((id (1+ (or (agent-codex--state session :next-id) 0))))
    (agent-codex--set session :next-id id)
    (when callback
      (unless (agent-codex--state session :callbacks)
        (agent-codex--set session :callbacks (make-hash-table)))
      (puthash id callback (agent-codex--state session :callbacks)))
    (agent-session-write session (list :jsonrpc "2.0" :id id :method method
                                       :params (or params (make-hash-table))))))

(defun agent-codex--notify (session method &optional params)
  "发送 JSON-RPC 通知。"
  (agent-session-write session (append (list :jsonrpc "2.0" :method method)
                                       (when params (list :params params)))))

(defun agent-codex--respond (session id result)
  "回复服务端请求 ID。"
  (agent-session-write session (list :jsonrpc "2.0" :id id :result result)))

;;; 后端接口

(cl-defmethod agent-session-backend-start ((_ (eql codex)) session)
  (agent-session-start-process session (agent-codex--command session))
  (agent-codex--request
   session "initialize"
   (list :clientInfo (list :name "emacs" :title "Emacs" :version emacs-version))
   (lambda (_result)
     (agent-codex--notify session "initialized")
     (agent-codex--request
      session "model/list" (list :limit 50)
      (lambda (result) (agent-codex--set session :models (plist-get result :data))))
     (pcase-let* ((`(,approval ,_ ,sandbox ,_) (agent-codex--mode session))
                  (resume (agent-codex--state session :resume)))
       (agent-codex--request
        session (if resume "thread/resume" "thread/start")
        (append (list :cwd (expand-file-name (agent-session-root session))
                      :approvalPolicy approval
                      :sandbox sandbox)
                (when resume (list :threadId resume :excludeTurns t))
                (when-let* ((model (agent-session-setting session :model)))
                  (list :model model)))
        (lambda (result)
          (let ((thread (plist-get (plist-get result :thread) :id)))
            (agent-codex--set session :thread thread)
            (agent-codex--set session :resume thread))
          (agent-session-set-info session :model (plist-get result :model))
          (if (and resume (zerop (hash-table-count (agent-session-blocks session))))
              (agent-codex--replay session)
            (agent-session-set-status session 'idle))))))))

(defun agent-codex--replay (session)
  "取回恢复的会话的历史回合并渲染，完成后进入空闲。"
  (agent-codex--request
   session "thread/turns/list"
   (list :threadId (agent-codex--state session :thread)
         :itemsView "full" :sortDirection "asc" :limit 200)
   (lambda (result)
     (seq-doseq (turn (plist-get result :data))
       (seq-doseq (item (plist-get turn :items))
         (if (equal (plist-get item :type) "userMessage")
             (agent-session--new-block
              session (plist-get item :id)
              (list :type 'user
                    :text (mapconcat (lambda (part) (or (plist-get part :text) ""))
                                     (plist-get item :content) "")))
           (agent-codex--item-completed session item))))
     (agent-session-notice session "—— 以上为历史记录 ——")
     (agent-session-set-status session 'idle))))

;;; 历史会话列表：临时启动一个 app-server 调用 thread/list

(cl-defmethod agent-session-backend-history ((_ (eql codex)) root callback)
  (let* ((pending "")
         (done nil)
         (process
          (make-process
           :name "agent-codex-list"
           :command (list agent-codex-executable "app-server")
           :connection-type 'pipe :coding 'utf-8-unix :noquery t
           :stderr (get-buffer-create " *agent-codex-list stderr*")
           :filter
           (lambda (process output)
             (setq pending (concat pending output))
             (let ((lines (split-string pending "\n")))
               (setq pending (car (last lines)))
               (dolist (line (butlast lines))
                 (when-let* ((message (ignore-errors
                                        (json-parse-string line :object-type 'plist
                                                           :null-object nil :false-object nil))))
                   (pcase (plist-get message :id)
                     (1 (process-send-string
                         process
                         (concat (json-serialize '(:jsonrpc "2.0" :method "initialized")) "\n"
                                 (json-serialize
                                  (list :jsonrpc "2.0" :id 2 :method "thread/list"
                                        :params (list :cwd (directory-file-name (expand-file-name root))
                                                      :limit 50 :sortKey "updated_at"
                                                      :sortDirection "desc")))
                                 "\n")))
                     (2 (setq done t)
                        (delete-process process)
                        (funcall callback
                                 (mapcar (lambda (thread)
                                           (list :id (plist-get thread :id)
                                                 :title (or (plist-get thread :name)
                                                            (car (split-string
                                                                  (string-trim (or (plist-get thread :preview) ""))
                                                                  "\n"))
                                                            "（无标题）")
                                                 :time (plist-get thread :updatedAt)))
                                         (plist-get (plist-get message :result) :data)))))))))
           :sentinel (lambda (_process _event)
                       (unless done (setq done t) (funcall callback nil))))))
    (process-send-string
     process (concat (json-serialize (list :jsonrpc "2.0" :id 1 :method "initialize"
                                           :params (list :clientInfo (list :name "emacs" :version emacs-version))))
                     "\n"))))

(cl-defmethod agent-session-backend-models ((_ (eql codex)) session)
  (seq-keep (lambda (model)
              (unless (plist-get model :hidden)
                (list :id (plist-get model :model)
                      :name (plist-get model :displayName)
                      :description (plist-get model :description)
                      :efforts (mapcar (lambda (e) (plist-get e :reasoningEffort))
                                       (plist-get model :supportedReasoningEfforts))
                      :default-effort (plist-get model :defaultReasoningEffort))))
            (agent-codex--state session :models)))

(cl-defmethod agent-session-backend-modes ((_ (eql codex)) _session)
  (mapcar #'car agent-codex--modes))

(cl-defmethod agent-session-backend-apply-settings ((_ (eql codex)) session changed)
  ;; 设置随每次 turn/start 发送，下一条消息起生效。
  (when (memq :model changed)
    (agent-session-set-info session :model (agent-session-setting session :model))))

(cl-defmethod agent-session-backend-send ((_ (eql codex)) session text)
  (agent-codex--request
   session "turn/start"
   (pcase-let ((`(,approval ,sandbox ,_ ,reviewer) (agent-codex--mode session)))
     (append
      (list :threadId (agent-codex--state session :thread)
            :input (vector (list :type "text" :text text))
            ;; 要求推理摘要，才会有 item/reasoning/summaryTextDelta。
            :summary "detailed"
            ;; 审批相关设置每回合都显式发送，避免恢复会话后沿用旧值。
            :approvalPolicy approval
            :approvalsReviewer reviewer
            :sandboxPolicy (list :type sandbox))
      (when-let* ((model (agent-session-setting session :model))) (list :model model))
      (when-let* ((effort (agent-session-setting session :effort))) (list :effort effort))))
   (lambda (result)
     (agent-codex--set session :turn (plist-get (plist-get result :turn) :id)))))

(defun agent-codex--interrupt (session)
  "中断当前回合；还不知道回合 id 时，等 turn/started 到达再中断。"
  (if-let* ((turn (agent-codex--state session :turn)))
      (agent-codex--request session "turn/interrupt"
                            (list :threadId (agent-codex--state session :thread) :turnId turn))
    (agent-codex--set session :interrupt-pending t)))

(cl-defmethod agent-session-backend-interrupt ((_ (eql codex)) session)
  (agent-codex--interrupt session))

;;; item 的展示

(defun agent-codex--relative (session path)
  "PATH 相对于项目根目录的形式。"
  (if (and (stringp path) (file-name-absolute-p path))
      (file-relative-name path (agent-session-root session))
    path))

(defun agent-codex--changes-diff (session changes)
  "文件改动 CHANGES 合成的 diff。"
  (mapconcat
   (lambda (change)
     (let ((path (agent-codex--relative session (plist-get change :path)))
           (diff (string-remove-suffix "\n" (or (plist-get change :diff) ""))))
       (pcase (plist-get (plist-get change :kind) :type)
         ("add" (concat "--- /dev/null\n+++ " path "\n"
                        (mapconcat (lambda (line) (concat "+" line)) (split-string diff "\n") "\n")))
         ("delete" (concat "--- " path "\n+++ /dev/null"))
         (_ (if (string-prefix-p "---" diff) diff (concat "--- " path "\n+++ " path "\n" diff))))))
   changes "\n"))

(defun agent-codex--command-title (command)
  "命令 COMMAND 的简短标题：去掉 bash -lc 包装，多行时只取第一行。"
  (let* ((command (or command ""))
         (inner (if (string-match "\\`\\(?:/bin/\\)?\\(?:ba\\|z\\)?sh -l?c '\\(\\(?:.\\|\n\\)*\\)'\\'" command)
                    (match-string 1 command)
                  command))
         (lines (split-string (string-trim inner) "\n")))
    (concat (car lines) (if (cdr lines) " …" ""))))

(defun agent-codex--item-view (session item)
  "item 的工具展示属性；不是工具调用时返回 nil。"
  (pcase (plist-get item :type)
    ("commandExecution"
     (list :kind 'command :title (agent-codex--command-title (plist-get item :command))))
    ("fileChange"
     (let ((changes (plist-get item :changes)))
       (list :kind 'edit
             :title (mapconcat (lambda (c) (agent-codex--relative session (plist-get c :path)))
                               changes ", ")
             :diff (agent-codex--changes-diff session changes))))
    ("mcpToolCall" (list :kind 'mcp :title (format "%s · %s" (plist-get item :server)
                                                  (plist-get item :tool))))
    ("dynamicToolCall" (list :kind 'other :title (plist-get item :tool)))
    ("webSearch" (list :kind 'web :title (plist-get item :query)))
    ("plan" (list :kind 'plan :title "计划" :output (plist-get item :text)))
    ("imageView" (list :kind 'read :title (agent-codex--relative session (plist-get item :path))))
    ("collabAgentToolCall" (list :kind 'task :title (or (plist-get item :prompt) "子任务")))))

(defun agent-codex--item-status (item)
  "item 的完成状态。"
  (pcase (plist-get item :status)
    ((or "failed" "error") 'error)
    ("declined" 'declined)
    ((or "inProgress" "in_progress") 'running)
    (_ (if (and (plist-get item :exitCode) (/= (plist-get item :exitCode) 0)) 'error 'ok))))

(defun agent-codex--item-output (item)
  "item 的输出文本。"
  (pcase (plist-get item :type)
    ("commandExecution" (plist-get item :aggregatedOutput))
    ("mcpToolCall" (let ((result (plist-get item :result)) (err (plist-get item :error)))
                     (cond (err (format "%s" (or (plist-get err :message) err)))
                           (result (mapconcat (lambda (part) (or (plist-get part :text) ""))
                                              (plist-get result :content) "\n")))))
    ("plan" (plist-get item :text))))

(defun agent-codex--item-started (session item)
  "item 开始。"
  (when-let* ((view (agent-codex--item-view session item)))
    (apply #'agent-session-tool session (plist-get item :id) :status 'running view)))

(defun agent-codex--item-completed (session item)
  "item 完成。"
  (let ((id (plist-get item :id)))
    (pcase (plist-get item :type)
      ("agentMessage" (agent-session-text-done session id (plist-get item :text)))
      ("reasoning" (agent-session-text-done session (concat id "-thinking")))
      ((pred (lambda (_) (agent-codex--item-view session item)))
       (apply #'agent-session-tool session id
              :status (agent-codex--item-status item)
              (append (when-let* ((output (agent-codex--item-output item))) (list :output output))
                      (agent-codex--item-view session item)))))))

;;; 审批

(defun agent-codex--approval (session id method params)
  "处理服务端的审批请求。"
  (let* ((item-id (plist-get params :itemId))
         (command (equal method "item/commandExecution/requestApproval"))
         (tool (agent-session--block session item-id)))
    (agent-session-ask
     session
     :title (if command
                (format "运行命令%s" (if-let* ((reason (plist-get params :reason)))
                                         (format "（%s）" reason) ""))
              (format "修改文件：%s%s" (or (plist-get tool :title) "")
                      (if-let* ((reason (plist-get params :reason))) (format "（%s）" reason) "")))
     :detail (and command (or (plist-get params :command) (plist-get tool :title)))
     :diff (and (not command) (plist-get tool :diff))
     :choices '((accept "允许") (acceptForSession "本会话允许") (decline "拒绝"))
     :tool item-id
     :callback (lambda (choice)
                 (agent-codex--respond session id (list :decision (symbol-name choice)))))))

;;; 消息处理

(cl-defmethod agent-session-backend-handle ((_ (eql codex)) session message)
  (let ((id (plist-get message :id))
        (method (plist-get message :method))
        (params (plist-get message :params)))
    (cond
     ;; 我们发出的请求的响应
     ((and id (not method))
      (if-let* ((err (plist-get message :error)))
          (agent-session-notice session (format "请求失败：%s" (plist-get err :message))
                                'agent-session-error)
        (when-let* ((callbacks (agent-codex--state session :callbacks))
                    (callback (gethash id callbacks)))
          (remhash id callbacks)
          (funcall callback (plist-get message :result)))))
     ;; 服务端请求
     (id
      (if (member method '("item/commandExecution/requestApproval"
                           "item/fileChange/requestApproval"))
          (agent-codex--approval session id method params)
        (agent-session-write session (list :jsonrpc "2.0" :id id
                                           :error (list :code -32601
                                                        :message (format "Emacs 不支持 %s" method))))))
     ;; 通知
     (t
      (pcase method
        ("turn/started"
         (agent-codex--set session :turn (plist-get (plist-get params :turn) :id))
         (agent-session-set-status session 'running)
         (when (agent-codex--state session :interrupt-pending)
           (agent-codex--set session :interrupt-pending nil)
           (agent-codex--interrupt session)))
        ("turn/completed"
         (let ((turn (plist-get params :turn)))
           (when-let* ((err (plist-get turn :error)))
             (agent-session-notice session (format "出错：%s" (plist-get err :message))
                                   'agent-session-error))
           (agent-codex--set session :turn nil)
           (agent-session-set-status session 'idle)))
        ("item/started" (agent-codex--item-started session (plist-get params :item)))
        ("item/completed" (agent-codex--item-completed session (plist-get params :item)))
        ("item/agentMessage/delta"
         (agent-session-text session (plist-get params :itemId) (plist-get params :delta)))
        ((or "item/reasoning/summaryTextDelta" "item/reasoning/textDelta")
         (agent-session-text session (concat (plist-get params :itemId) "-thinking")
                             (plist-get params :delta) 'thinking))
        ("item/commandExecution/outputDelta"
         (agent-session-tool-output session (plist-get params :itemId) (plist-get params :delta)))
        ("thread/tokenUsage/updated"
         (agent-session-set-info session :tokens
                                 (plist-get (plist-get (plist-get params :tokenUsage) :last)
                                            :totalTokens)))
        ("error"
         (unless (plist-get params :willRetry)
           (agent-session-notice session (format "出错：%s"
                                                 (plist-get (plist-get params :error) :message))
                                 'agent-session-error))))))))

(provide 'agent-codex)
;;; agent-codex.el ends here
