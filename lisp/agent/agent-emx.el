;;; agent-emx.el --- Render sessions owned by an emx daemon -*- lexical-binding: t; -*-

;;; Commentary:

;; Optional backend; agent-dsh loads it to define the migration switch.
;; Register agents with :backend emx and optionally :emx-agent "name".
;; The socket belongs to the connection, never to agent-session-process.

;;; Code:

(require 'agent-session)
(require 'json)
(require 'agent-usage)
(require 'agent-ui)

(defgroup agent-emx nil
  "Sessions owned by the emx daemon."
  :group 'agent-session)

(defvar agent-emx--offered nil
  "Agents the daemon can run, with their Lisp backends: ((AGENT . BACKEND) ...).")

(defvar agent-emx-agents)

(defun agent-emx--apply (agent)
  "Register AGENT's backend per `agent-emx-agents' for future sessions."
  (when-let* ((entry (assq agent agent-session-agents))
              (lisp (alist-get agent agent-emx--offered)))
    (let ((daemon (memq agent agent-emx-agents)))
      (setcdr entry (plist-put (cdr entry) :backend (if daemon 'emx lisp)))
      (setcdr entry (plist-put (cdr entry) :emx-agent
                               (and daemon (symbol-name agent)))))))

(defun agent-emx-offer (agent)
  "Let AGENT's sessions run through the daemon when `agent-emx-agents' says so.
Call it after registering AGENT with `agent-session-define-agent'."
  (unless (assq agent agent-emx--offered)
    (push (cons agent (agent-session--get agent :backend)) agent-emx--offered))
  (agent-emx--apply agent))

(defun agent-emx--select-agents (symbol value)
  "Set SYMBOL to VALUE and update registrations for future sessions."
  (set-default symbol value)
  (dolist (entry agent-emx--offered)
    (agent-emx--apply (car entry))))

(defcustom agent-emx-agents nil
  "Agents whose new sessions run through the emx daemon.
Only agents whose backend offers it (`agent-emx-offer') switch, and
only for local projects.  Nil keeps the Lisp backends.
Customize this option before opening a session; existing sessions keep
using the backend they started with."
  :type '(repeat symbol)
  :set #'agent-emx--select-agents)

(defcustom agent-emx-var-directory
  (if (boundp 'my/var) (symbol-value 'my/var)
    (expand-file-name "var/" user-emacs-directory))
  "Directory holding the local daemon's runtime state."
  :type 'directory)

(defconst agent-emx--checkout
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name)))
  "Checkout containing this backend and bin/emx.")

(defcustom agent-emx-notice-formats
  '(("effort-after-turn" . "推理强度将在当前回合结束后生效")
    ("restart-for-external" . "正在重新接入其他客户端更新的会话")
    ("interrupted" . "已中断")
    ("error" . "代理发生错误")
    ("backend-error" . "出错：%s")
    ("max-tokens" . "输出达到 token 上限")
    ("history-end" . "—— 以上为历史记录 ——")
    ("claude-child-effort" . "子会话不保存记录，不能重启来改推理强度")
    ("claude-external-source"
     . (lambda (args)
         (format "以下来自 %s"
                 (pcase (plist-get args :source)
                   ("claude-desktop" "Claude Desktop")
                   ("cli" "终端中的 Claude Code")
                   (source (or source "其他客户端"))))))
    ("codex-tools-changed" . "Emacs 的工具有更新，重启 Codex 后继续")
    ("codex-config-read-failed" . "读取 Codex 配置失败，未注入 Emacs 环境说明；保留原有指令：%s")
    ("dsh-warning" . "dsh：%s")
    ("dsh-version" . "dsh 版本为 %s，桥接插件按 %s 编写，若有异常可能需要适配")
    ("command-error" . "命令失败：%s")
    ("command-result" . (lambda (args) (or (plist-get args :message) "命令已执行"))))
  "Notice kinds and their Chinese wording.
A value is a format string, with args values in wire order, or a function
accepting the args plist.  Unknown kinds are displayed dimly as-is."
  :type '(alist :key-type string :value-type (choice string function)))

(cl-defstruct (agent-emx--connection (:constructor agent-emx--make-connection))
  place var process starter ready waiters
  (input (encode-coding-string "" 'utf-8 t))
  (next-id 0)
  (pending (make-hash-table :test #'eql))
  (sessions (make-hash-table :test #'equal))
  pending-stops)

(defvar agent-emx--connections (make-hash-table :test #'equal)
  "Connections keyed by (PLACE . VAR-DIRECTORY), for future remote use.")

(defvar agent-emx--tools-signatures (make-hash-table :test #'eq)
  "Connection -> last tools signature sent to its daemon.")

(defun agent-emx--get (session key)
  "Return backend state KEY of SESSION."
  (plist-get (agent-session-state session) key))

(defun agent-emx--set (session key value)
  "Set backend state KEY of SESSION to VALUE."
  (setf (agent-session-state session)
        (plist-put (agent-session-state session) key value))
  value)

(defun agent-emx--table (session key)
  "Return or create SESSION's hash table at state KEY."
  (or (agent-emx--get session key)
      (agent-emx--set session key (make-hash-table :test #'equal))))

(defun agent-emx--parse (line)
  "Decode a complete binary JSON LINE."
  (json-parse-string (decode-coding-string line 'utf-8)
                     :object-type 'plist :array-type 'array
                     :null-object nil :false-object :false))

(defun agent-emx--request (connection method params &optional callback error-callback)
  "Send METHOD with PARAMS on CONNECTION without waiting.
Call CALLBACK with the result or ERROR-CALLBACK with the error plist."
  (let ((id (cl-incf (agent-emx--connection-next-id connection))))
    (puthash id (cons callback error-callback) (agent-emx--connection-pending connection))
    (condition-case err
        (process-send-string
         (agent-emx--connection-process connection)
         (concat (json-serialize (list :jsonrpc "2.0" :id id :method method
                                      :params (or params (make-hash-table)))
                                 :null-object nil :false-object :false)
                 (encode-coding-string "\n" 'utf-8 t)))
      (error
       (remhash id (agent-emx--connection-pending connection))
       (when error-callback
         (funcall error-callback (list :message (error-message-string err))))))
    id))

(defun agent-emx--cancel-deferred (connection &optional session)
  "Cancel deferred calls owned by CONNECTION, optionally only SESSION."
  (let (ids)
    (maphash
     (lambda (id entry)
       (let ((owner (plist-get entry :emx-owner)))
         (when (and (eq (car owner) connection)
                    (or (null session) (equal (cdr owner) session)))
           (push id ids))))
     agent-ui--deferred)
    (dolist (id ids)
      (condition-case err
          (agent-ui--poll id t)
        (error (message "emx 取消等待失败：%s" (error-message-string err)))))))

(defun agent-emx--lost (connection error &optional quiet)
  "Fail CONNECTION's pending work with ERROR and disconnect its sessions.
QUIET marks transport loss, whose uncertain replies need no failure notice."
  (agent-emx--cancel-deferred connection)
  (when quiet
    (setq error (plist-put (copy-sequence error) :connection-lost t)))
  (remhash connection agent-emx--tools-signatures)
  (setf (agent-emx--connection-ready connection) nil)
  (let ((pending (hash-table-values (agent-emx--connection-pending connection)))
        (waiters (agent-emx--connection-waiters connection)))
    (clrhash (agent-emx--connection-pending connection))
    (setf (agent-emx--connection-waiters connection) nil)
    (maphash
     (lambda (_ session)
       (when (buffer-live-p (agent-session-buffer session))
         (agent-emx--set session :emx-attaching nil)
         (agent-emx--set session :emx-replay nil)
         (agent-emx--set session :emx-earlier-busy nil)
         (agent-emx--history-line session)
         (agent-emx--set session :emx-waiters nil)
         (agent-session-set-status session 'disconnected)))
     (agent-emx--connection-sessions connection))
    (dolist (pair (append pending waiters))
      (when (cdr pair) (funcall (cdr pair) error)))))

(defun agent-emx--write (connection message)
  "Write a JSON-RPC MESSAGE to CONNECTION."
  (let ((encoded
         (condition-case err
             (json-serialize message :null-object :null :false-object :false)
           (error
            (json-serialize
             (list :jsonrpc "2.0" :id (plist-get message :id)
                   :error (list :code -32603
                                :message (format "Result cannot be serialized: %s"
                                                 (error-message-string err)))))))))
    (process-send-string (agent-emx--connection-process connection)
                         (concat encoded (encode-coding-string "\n" 'utf-8 t)))))

(defun agent-emx--editor-params (value)
  "Copy editor argument VALUE with legacy false and null decoding.
Daemon events keep their distinct false value; only tool arguments use nil."
  (cond
   ((eq value :false) nil)
   ((consp value) (cons (agent-emx--editor-params (car value))
                        (agent-emx--editor-params (cdr value))))
   ((vectorp value) (apply #'vector (mapcar #'agent-emx--editor-params value)))
   (t value)))

(defun agent-emx--editor-call (connection message)
  "Answer an editor request MESSAGE on CONNECTION without blocking."
  (let* ((id (plist-get message :id))
         (params (plist-get message :params))
         (method (plist-get params :method))
         (args (agent-emx--editor-params (plist-get params :params)))
         (caller (plist-get params :caller))
         (session-id (plist-get caller :session))
         (session (gethash session-id (agent-emx--connection-sessions connection))))
    (agent-emx--write
     connection
     (append
      (list :jsonrpc "2.0" :id id)
      (cond
       ((not (equal (plist-get message :method) "editor/call"))
        (list :error '(:code -32601 :message "Unknown editor request")))
       ;; Cleanup may arrive after the session stopped and lost its mapping.
       ((and (equal method "_poll") (plist-get args :cancel))
        (let ((entry (gethash (plist-get args :id) agent-ui--deferred)))
          (list :result
                (cond
                 ((null entry) '(:ok t :result :null))
                 ((equal (plist-get entry :emx-owner) (cons connection session-id))
                  (agent-ui-call method args nil))
                 (t '(:ok :false :error "Pending result belongs to another caller"))))))
       ((not (and session (buffer-live-p (agent-session-buffer session))))
        (list :result '(:ok :false :error "Daemon session is not attached to Emacs")))
       (t
        (let* ((result
                (agent-ui-call
                 method args
                 (list :agent_buffer (buffer-name (agent-session-buffer session))
                       :session session-id
                       :root (agent-session-root session)
                       :place (agent-session-place (agent-session-root session)))))
               (pending (plist-get result :pending)))
          (when-let* ((entry (and pending (gethash pending agent-ui--deferred))))
            (puthash pending (plist-put entry :emx-owner (cons connection session-id))
                     agent-ui--deferred))
          (list :result result))))))))

(defun agent-emx--tools ()
  "Return this machine's MCP definitions and private read-only classification."
  (list :tools (agent-ui--describe nil)
        :readOnly (vconcat (agent-ui-read-only-methods nil))))

(defun agent-emx--tools-signature (tools)
  "Hash captured TOOLS definitions and private permission classification."
  (secure-hash 'sha1 (json-serialize tools)))

(defun agent-emx--publish-tools ()
  "Publish changed local tools on every ready daemon connection."
  (maphash
   (lambda (_ connection)
     (when (and (agent-emx--connection-ready connection)
                (process-live-p (agent-emx--connection-process connection)))
       (let* ((tools (agent-emx--tools))
              (signature (agent-emx--tools-signature tools)))
         (unless (equal signature (gethash connection agent-emx--tools-signatures))
           (agent-emx--write connection (list :jsonrpc "2.0" :method "editor/tools"
                                               :params tools))
           (puthash connection signature agent-emx--tools-signatures)))))
   agent-emx--connections))

(add-hook 'agent-ui-tools-change-functions #'agent-emx--publish-tools)

(defun agent-emx--dispatch (connection message)
  "Dispatch a parsed JSON-RPC MESSAGE from CONNECTION."
  (cond
   ((and (plist-member message :id) (plist-get message :method))
    (agent-emx--editor-call connection message))
   ((plist-member message :id)
    (let* ((id (plist-get message :id))
           (pair (gethash id (agent-emx--connection-pending connection))))
      (remhash id (agent-emx--connection-pending connection))
      (if (plist-member message :error)
          (when (cdr pair) (funcall (cdr pair) (plist-get message :error)))
        (when (car pair) (funcall (car pair) (plist-get message :result))))))
   (t
    (let* ((method (plist-get message :method))
           (params (plist-get message :params))
           (session (gethash (plist-get params :session)
                             (agent-emx--connection-sessions connection))))
      (cond
       ((equal method "usage/changed")
        (run-hooks 'agent-usage-change-functions))
       ((equal method "usage/quotas")
        (agent-usage--receive-quotas (plist-get params :quotas)))
       ((equal method "replaced")
        (agent-emx--lost connection '(:message "Connection replaced") t)
        (delete-process (agent-emx--connection-process connection)))
       ((and session (buffer-live-p (agent-session-buffer session)))
        (agent-emx--event session method params)))))))

(defun agent-emx--filter (connection bytes)
  "Buffer partial BYTES on CONNECTION and dispatch complete UTF-8 lines."
  (let ((input (concat (agent-emx--connection-input connection) bytes)) end)
    (while (setq end (string-search "\n" input))
      (let ((line (substring input 0 end)))
        (setq input (substring input (1+ end)))
        (unless (string-empty-p line)
          (condition-case err
              (agent-emx--dispatch connection (agent-emx--parse line))
            (error (message "emx 事件处理失败：%s" (error-message-string err)))))))
    (setf (agent-emx--connection-input connection) input)))

(defun agent-emx--connect (connection result)
  "Connect CONNECTION to the daemon described by ensure RESULT."
  (setf (agent-emx--connection-starter connection) nil
        (agent-emx--connection-input connection) (encode-coding-string "" 'utf-8 t)
        (agent-emx--connection-process connection)
        (make-network-process
         :name "emx-daemon" :family 'local :service (plist-get result :socket)
         :coding 'binary :noquery t
         :filter (lambda (process bytes)
                   (when (eq process (agent-emx--connection-process connection))
                     (agent-emx--filter connection bytes)))
         :sentinel (lambda (process event)
                     (when (and (eq process (agent-emx--connection-process connection))
                                (not (process-live-p process)))
                       (agent-emx--lost connection (list :message (string-trim event)) t)))))
  (let* ((tools (agent-emx--tools))
         (signature (agent-emx--tools-signature tools)))
    (agent-emx--request
     connection "hello" (list :client "emacs" :version (plist-get result :version)
                              :tools tools)
     (lambda (_)
       (puthash connection signature agent-emx--tools-signatures)
       (setf (agent-emx--connection-ready connection) t)
       (agent-usage--connected connection)
       (agent-emx--flush-stops connection)
       (let ((waiters (agent-emx--connection-waiters connection)))
         (setf (agent-emx--connection-waiters connection) nil)
         (dolist (pair waiters) (funcall (car pair) connection))))
     (lambda (error)
       (agent-emx--lost connection error)
       (delete-process (agent-emx--connection-process connection))))))

(defun agent-emx--flush-stops (connection)
  "Send CONNECTION's pending stops, retaining them until acknowledged."
  (dolist (id (copy-sequence (agent-emx--connection-pending-stops connection)))
    (let ((forget (lambda (&optional _)
                    (setf (agent-emx--connection-pending-stops connection)
                          (delete id (agent-emx--connection-pending-stops
                                      connection))))))
      (agent-emx--request
       connection "session/stop" (list :id id) forget
       (lambda (error)
         (when (eql (plist-get error :code) 1) (funcall forget)))))))

(defun agent-emx--stop (connection id)
  "Keep a stop for ID on CONNECTION even if its transport is down."
  (cl-pushnew id (agent-emx--connection-pending-stops connection) :test #'equal)
  (when (and (agent-emx--connection-ready connection)
             (process-live-p (agent-emx--connection-process connection)))
    (agent-emx--flush-stops connection)))

(defun agent-emx--ensure (connection)
  "Ensure CONNECTION's daemon exists, then connect and say hello.
Only batch Emacs uses call-process.  Interactive startup uses the same
command asynchronously so starting a daemon never waits in the editor."
  (let* ((default-directory agent-emx--checkout)
         (command (list "node" (expand-file-name "bin/emx" agent-emx--checkout)
                        "daemon" "--var" (agent-emx--connection-var connection) "--ensure"))
         (buffer (generate-new-buffer " *emx-ensure*")))
    (if noninteractive
        (unwind-protect
            (condition-case err
                (if (zerop (apply #'call-process (car command) nil buffer nil (cdr command)))
                    (agent-emx--connect connection
                                        (with-current-buffer buffer
                                          (agent-emx--parse (buffer-string))))
                  (agent-emx--lost connection '(:message "Daemon ensure failed")))
              (error (agent-emx--lost connection (list :message (error-message-string err)))))
          (kill-buffer buffer))
      (condition-case err
          (setf (agent-emx--connection-starter connection)
                (make-process
                 :name "emx-ensure" :buffer buffer :command command
                 :connection-type 'pipe :coding 'binary :noquery t
                 :sentinel
                 (lambda (process _)
                   (unless (process-live-p process)
                     (setf (agent-emx--connection-starter connection) nil)
                     (unwind-protect
                         (condition-case err
                             (if (zerop (process-exit-status process))
                                 (agent-emx--connect connection
                                                     (with-current-buffer buffer
                                                       (agent-emx--parse (buffer-string))))
                               (agent-emx--lost connection '(:message "Daemon ensure failed")))
                           (error (agent-emx--lost
                                   connection (list :message (error-message-string err)))))
                       (kill-buffer buffer))))))
        (error
         (kill-buffer buffer)
         (agent-emx--lost connection (list :message (error-message-string err))))))))

(defun agent-emx--local-connection (callback error-callback)
  "Obtain the local daemon connection without waiting interactively.
Call CALLBACK after hello or ERROR-CALLBACK on failure."
  (agent-usage--migrate)
  (let* ((var (expand-file-name agent-emx-var-directory))
         (key (cons nil var))
         (connection (or (gethash key agent-emx--connections)
                         (puthash key (agent-emx--make-connection :var var)
                                  agent-emx--connections))))
    (if (and (agent-emx--connection-ready connection)
             (process-live-p (agent-emx--connection-process connection)))
        (funcall callback connection)
      (setf (agent-emx--connection-waiters connection)
            (append (agent-emx--connection-waiters connection)
                    (list (cons callback error-callback))))
      (unless (or (process-live-p (agent-emx--connection-process connection))
                  (process-live-p (agent-emx--connection-starter connection)))
        (agent-emx--ensure connection)))
    connection))

(defun agent-emx--connection (session callback error-callback)
  "Obtain SESSION's connection; call CALLBACK after hello or ERROR-CALLBACK."
  (when (agent-session-place (agent-session-root session))
    (error "Remote emx daemons are not implemented"))
  (let ((connection (agent-emx--local-connection
                     (lambda (connection)
                       (agent-emx--set session :emx-connection connection)
                       (funcall callback connection))
                     error-callback)))
    (agent-emx--set session :emx-connection connection)
    connection))

;;; Transcript and asks

(defun agent-emx--notice (session id notice)
  "Render NOTICE in SESSION as stable block ID."
  (let* ((kind (plist-get notice :kind))
         (format (cdr (assoc kind agent-emx-notice-formats)))
         (args (plist-get notice :args))
         (text (cond ((functionp format) (funcall format args))
                     (format (apply #'format format
                                    (cl-loop for (_ value) on args by #'cddr collect value)))
                     (t kind)))
         (face (if (null format) 'agent-session-dim
                 (pcase (plist-get notice :level)
                   ("error" 'agent-session-error) ("warning" 'warning)
                   (_ 'agent-session-dim)))))
    (if (agent-session--block session id)
        (agent-session--update session id :text text :face face)
      (agent-session-notice session text face id))))

(defun agent-emx--block (session block)
  "Render a complete wire BLOCK in SESSION."
  (let* ((id (plist-get block :id))
         (existing (agent-session--block session id)))
    (puthash id block (agent-emx--table session :emx-blocks))
    (pcase (plist-get block :type)
      ("user"
       (unless existing
         (agent-session--new-block session id
                                   (list :type 'user :text
                                         (string-join
                                          (append (make-list
                                                   (or (plist-get block :imageCount)
                                                       (length (plist-get block :images)))
                                                   "[图片]")
                                                  (list (plist-get block :text))) " ")))))
      ("text"
       (if existing
           (agent-session--update session id :text (plist-get block :text)
                                  :kind (intern (plist-get block :kind))
                                  :done (eq (plist-get block :done) t))
         (agent-session-text session id (plist-get block :text)
                             (intern (plist-get block :kind))))
       (when (eq (plist-get block :done) t) (agent-session-text-done session id)))
      ("tool"
       (let ((view (plist-get block :view)))
         (agent-session-tool session id :kind (intern (plist-get view :kind))
                             :title (pcase (plist-get view :name)
                                      ((or "todo_write" "TodoWrite") "更新计划")
                                      ("exit_plan_mode" "提交计划")
                                      ("skill" (concat "技能 " (plist-get view :title)))
                                      (_ (plist-get view :title)))
                             :status (intern (plist-get block :status))
                             :diff (plist-get view :diff)
                             :output (if (and (plist-member view :items)
                                              (member (plist-get block :status)
                                                      '("running" "done")))
                                         (mapconcat
                                          (lambda (item)
                                            (concat (pcase (plist-get item :status)
                                                      ("done" "☑") ("active" "▶") (_ "☐"))
                                                    " " (plist-get item :text)))
                                          (plist-get view :items) "\n")
                                       (plist-get block :output)))))
      ("notice" (agent-emx--notice session id (plist-get block :notice))))))

(defun agent-emx--question (question)
  "Translate a wire QUESTION to the session UI's plist."
  (list :question (plist-get question :question) :header (plist-get question :header)
        :detail (plist-get question :detail)
        :options (mapcar (lambda (option)
                           (cons (plist-get option :label) (plist-get option :description)))
                         (append (plist-get question :options) nil))
        :multi (eq (plist-get question :multi) t)
        :other (eq (plist-get question :other) t)
        :secret (eq (plist-get question :secret) t)
        :range (append (plist-get question :range) nil)))

(defun agent-emx--plan-review (session ask question)
  "Render ASK's plan review QUESTION using the native approval footer."
  (let* ((options (append (plist-get question :options) nil))
         (approve (plist-get (plist-get question :intent) :approve)))
    (agent-session-ask
     session :title "批准这个计划并开始执行？" :tool (plist-get ask :tool)
     :choices (seq-map-indexed (lambda (option index)
                                 (list index (plist-get option :label))) options)
     :callback
     (lambda (index)
       (let* ((label (plist-get (nth index options) :label))
              (feedback (unless (equal label approve)
                          (string-trim (read-string "修改意见（可留空）：")))))
         (agent-emx--rpc
          session "session/answer"
          (list :ask (plist-get ask :id) :answers
                (vconcat
                 (mapcar
                  (lambda (q)
                    (if (eq q question)
                        (append (list :selected (vector label))
                                (when (and feedback (not (string-empty-p feedback)))
                                  (list :custom feedback)))
                      (list :selected [])))
                  (append (plist-get ask :questions) nil))))))))))

(defun agent-emx--ask (session ask)
  "Show wire ASK in SESSION, keeping its id separate from the UI id."
  (let* ((id (plist-get ask :id))
         (table (agent-emx--table session :emx-asks)))
    (unless (gethash id table)
      (puthash
       id
       (cond
        ((seq-find (lambda (q) (equal (plist-get (plist-get q :intent) :kind)
                                      "plan-review"))
                   (plist-get ask :questions))
         (agent-emx--plan-review
          session ask (seq-find (lambda (q) (equal (plist-get (plist-get q :intent) :kind)
                                                    "plan-review"))
                                (plist-get ask :questions))))
        ((equal (plist-get ask :type) "approval")
           (agent-session-ask
            session :title (or (plist-get (plist-get ask :view) :title)
                               (plist-get ask :description) "需要确认")
            :detail (string-join (delq nil (list (plist-get ask :description)
                                                 (plist-get (plist-get ask :view) :command)))
                                 "\n")
            :diff (plist-get (plist-get ask :view) :diff)
            :tool (plist-get ask :tool)
            :choices (mapcar (lambda (choice)
                               (list (intern choice)
                                     (cdr (assoc choice '(("allow" . "允许")
                                                          ("always" . "本会话允许")
                                                          ("deny" . "拒绝"))))))
                             (append (plist-get ask :choices) nil))
            :callback (lambda (choice)
                        (agent-emx--rpc session "session/answer"
                                        (list :ask id :choice (symbol-name choice))))))
        (t (agent-session-ask-questions
          session :questions (mapcar #'agent-emx--question
                                      (append (plist-get ask :questions) nil))
          :tool (plist-get ask :tool)
          :callback
          (lambda (answers)
            (agent-emx--rpc
             session "session/answer"
             (if (eq answers 'cancel)
                 (list :ask id)
               (list :ask id :answers
                     (vconcat
                      (mapcar (lambda (answer)
                                 (append (list :selected (vconcat (plist-get answer :selected)))
                                         (when (plist-get answer :custom)
                                           (list :custom (plist-get answer :custom)))))
                               answers)))))))))
       table))))

(defun agent-emx--close-asks (session label)
  "Close all daemon asks of SESSION with LABEL."
  (maphash (lambda (_ ui-id)
             (when-let* ((ask (agent-session--ask session ui-id))
                         ((not (plist-get ask :answer))))
               (agent-session--close-ask session ask label)))
           (agent-emx--table session :emx-asks))
  (clrhash (agent-emx--table session :emx-asks)))

(defun agent-emx--fresh (session)
  "Clear SESSION's transcript before fresh history arrives."
  (let ((queued (mapcar (lambda (entry)
                          (cons (car entry) (copy-sequence
                                             (agent-session--block session (car entry)))))
                        (agent-session-queue session))))
    (agent-emx--close-asks session "已失效")
    (agent-session--with-buffer session
      (remove-overlays (point-min) (agent-session-tail session)))
    (dolist (id (hash-table-keys (agent-session-blocks session)))
      (agent-session--remove-block session id))
    (clrhash (agent-emx--table session :emx-blocks))
    ;; These messages have not reached the daemon yet, including hidden notes.
    (dolist (entry queued)
      (when (cdr entry) (agent-session--new-block session (car entry) (cdr entry))))))

(defun agent-emx--first-block (session)
  "Return the first daemon block shown in SESSION, ignoring local blocks."
  (car (seq-find (lambda (entry)
                   (gethash (car entry) (agent-emx--table session :emx-blocks)))
                 (agent-session--blocks-in-order session))))

(defun agent-emx--history-line (session)
  "Redraw SESSION's earlier-history button above its transcript."
  (if (eq (agent-emx--get session :emx-earlier) t)
      (let ((draw
             (lambda ()
               (agent-session--update
                session "emx-history" :type 'notice :face 'agent-session-run-button
                :text (if (agent-emx--get session :emx-earlier-busy)
                          "正在载入历史记录…"
                        (make-text-button
                         "▲ 加载更早的记录" nil
                         'follow-link t 'help-echo "载入更早的 20 个回合（RET）"
                         'action (lambda (_) (agent-emx--show-history session))))))))
        ;; The insertion wrapper must not advance the button's own start marker.
        (if (agent-session--block session "emx-history")
            (funcall draw)
          (agent-session-call-before-block
           session (caar (agent-session--blocks-in-order session)) draw)))
    (agent-session--remove-block session "emx-history")))

(defun agent-emx--show-history (session)
  "Request earlier turns in SESSION, retrying an incomplete page first."
  (unless (or (agent-emx--get session :emx-earlier-busy)
              (agent-emx--get session :emx-attaching))
    (agent-emx--ready
     session
     (lambda ()
       (when-let* (((eq (agent-emx--get session :emx-earlier) t))
                   (before (or (agent-emx--get session :emx-earlier-before)
                               (agent-emx--first-block session))))
         ;; Keep the page anchor across transport loss until history/done.
         (agent-emx--set session :emx-earlier-before before)
         (agent-emx--set session :emx-earlier-busy t)
         (agent-emx--history-line session)
         (agent-emx--request
          (agent-emx--get session :emx-connection) "session/earlier"
          (list :id (agent-emx--get session :emx-id) :before before :turns 20)
          nil (lambda (error) (agent-emx--error session error))))))))

(defun agent-emx--info (session info)
  "Apply wire INFO to SESSION, preserving its Lisp parent buffer.
The daemon parent id is not a buffer; collaboration moves in phase 5."
  (let ((props (cl-loop for (key value) on info by #'cddr
                        unless (eq key :parent) append (list key value))))
    (apply #'agent-session-set-info session props))
  (when-let* ((resume (plist-get info :sessionId)))
    (agent-emx--set session :resume resume)))

(defun agent-emx--settings (session settings)
  "Apply daemon SETTINGS to SESSION without sending them back."
  (cl-loop for key in '(:model :effort :mode :beforePlan)
           when (plist-member settings key)
           do (let ((value (plist-get settings key)))
                (setf (agent-session-settings session)
                      (plist-put (agent-session-settings session)
                                 (if (eq key :beforePlan) :before-plan key)
                                 (if (and (memq key '(:mode :beforePlan)) value)
                                     (intern value) value)))))
  (agent-session--refresh session))

(defun agent-emx--event (session method params)
  "Render event METHOD and PARAMS in SESSION, deduplicating by seq."
  (let* ((seq (plist-get params :seq))
         (epoch (agent-emx--get session :emx-epoch))
         (cursor (agent-emx--get session :emx-cursor))
         (history (or (eq (plist-get params :history) t)
                      (equal method "history/done")))
         (fresh (equal (plist-get (agent-emx--get session :emx-replay)
                                  :replay) "fresh")))
    (when (or history
              (not (equal epoch (plist-get cursor :epoch)))
              (> seq (or (plist-get cursor :seq) 0)))
      ;; A partial fresh transfer never establishes a resumable cursor.
      ;; Advance before status can flush a queued message and reenter us.
      (unless (or history fresh)
        (agent-emx--set session :emx-cursor (list :epoch epoch :seq seq)))
      (pcase method
        ("history/done"
         (agent-emx--set session :emx-earlier (plist-get params :earlier))
         (agent-emx--set session :emx-earlier-busy nil)
         (agent-emx--set session :emx-earlier-before nil)
         (when fresh
           (let ((result (agent-emx--get session :emx-replay)))
             (agent-emx--set session :emx-cursor
                             (list :epoch (plist-get result :epoch)
                                   :seq (plist-get result :seq)))
             (agent-emx--finish-attach session result)))
         (agent-emx--history-line session))
        ("status"
         ;; The local queue may only flush once replay reaches the snapshot.
         (let ((queue (agent-session-queue session)))
           (when (agent-emx--get session :emx-replay)
             (setf (agent-session-queue session) nil))
           (unwind-protect
               (agent-session-set-status session (intern (plist-get params :status)))
             (when (agent-emx--get session :emx-replay)
               (setf (agent-session-queue session) queue)))))
        ("info" (agent-emx--info session (plist-get params :info)))
        ("settings" (agent-emx--settings session (plist-get params :settings)))
        ("capabilities"
         (agent-emx--set session :emx-capabilities (plist-get params :capabilities))
         (agent-session--refresh session))
        ("block/add"
         ;; A retried page repeats its received prefix; leave those blocks alone.
         (unless (and history
                      (gethash (plist-get (plist-get params :block) :id)
                               (agent-emx--table session :emx-blocks)))
           (agent-session-call-before-block
            session (or (plist-get params :before)
                        ;; Fresh history precedes messages queued during attach.
                        (and (eq (plist-get params :history) t)
                             (car (seq-find
                                   (lambda (entry)
                                     (and (not (equal (car entry) "emx-history"))
                                          (not (gethash
                                                (car entry)
                                                (agent-emx--table session :emx-blocks)))))
                                   (agent-session--blocks-in-order session)))))
            (lambda () (agent-emx--block session (plist-get params :block))))))
        ("block/append"
         (let* ((id (plist-get params :id))
                (block (gethash id (agent-emx--table session :emx-blocks)))
                (text (plist-get params :text))
                (tool (equal (plist-get block :type) "tool")))
           (when block
             (puthash id (plist-put block (if tool :output :text)
                                    (concat (plist-get block (if tool :output :text)) text))
                      (agent-emx--table session :emx-blocks))
             (if tool (agent-session-tool-output session id text)
               (agent-session-text session id text)))))
        ("block/update"
         (let* ((id (plist-get params :id))
                (block (gethash id (agent-emx--table session :emx-blocks))))
           (when block
             (cl-loop for (key value) on (plist-get params :fields) by #'cddr
                      do (setq block (plist-put block key value)))
             (if (equal (plist-get block :type) "user")
                 (agent-session--update session id :text (plist-get block :text))
               (agent-emx--block session block)))))
        ("block/remove"
         (seq-doseq (id (plist-get params :ids))
           (agent-session--remove-block session id)
           (remhash id (agent-emx--table session :emx-blocks))))
        ("ask/add" (agent-emx--ask session (plist-get params :ask)))
        ("ask/remove"
         (let* ((table (agent-emx--table session :emx-asks))
                (id (plist-get params :id))
                (ask (agent-session--ask session (gethash id table))))
           (when (and ask (not (plist-get ask :answer)))
             (agent-session--close-ask session ask
                                       (if (equal (plist-get params :resolution) "answered")
                                           "已回答" "已取消")))
           (remhash id table)
           (agent-session--refresh session)))
        ;; Keep daemon queue metadata separate from the UI's unsent local queue.
        ("queue" (agent-emx--set session :emx-queue (plist-get params :items))))
      (when-let* ((replay (agent-emx--get session :emx-replay))
                  ((equal (plist-get replay :replay) "events"))
                  ((>= (or (plist-get (agent-emx--get session :emx-cursor) :seq) 0)
                       (plist-get replay :seq))))
        (agent-emx--finish-attach session replay)))))

;;; Backend interface and reconnection

(defun agent-emx--error (session error)
  "Report RPC ERROR in SESSION and allow a later reconnect."
  (agent-emx--set session :emx-attaching nil)
  (agent-emx--set session :emx-replay nil)
  (agent-emx--set session :emx-waiters nil)
  (agent-emx--set session :emx-earlier-busy nil)
  (when (buffer-live-p (agent-session-buffer session))
    (agent-emx--history-line session)
    (agent-session-set-status session 'disconnected)
    ;; A lost send reply does not prove that the daemon rejected the message.
    ;; Reattach will recover its events; do not add a spurious failure block.
    (unless (plist-get error :connection-lost)
      (agent-session-notice session (format "emx 请求失败：%s" (plist-get error :message))
                            'agent-session-error))))

(defun agent-emx--attached (session result)
  "Apply attach RESULT before the following replay notifications."
  (agent-emx--set session :emx-attaching t)
  (agent-emx--set session :emx-epoch (plist-get result :epoch))
  ;; Only a fresh view says whether earlier turns remain: after a replay
  ;; of events the view, and so what lies before it, is unchanged.
  (when (equal (plist-get result :replay) "fresh")
    (agent-emx--set session :emx-earlier (plist-get result :earlier)))
  (if (equal (plist-get result :replay) "fresh")
      (progn
        (agent-emx--set session :emx-cursor nil)
        (agent-emx--set session :emx-replay result)
        (agent-emx--fresh session))
    ;; A seq from another epoch cannot suppress this epoch's events.
    (let* ((cursor (agent-emx--get session :emx-cursor))
           (seq (if (equal (plist-get cursor :epoch) (plist-get result :epoch))
                    (or (plist-get cursor :seq) 0)
                  0)))
      (agent-emx--set session :emx-cursor
                      (list :epoch (plist-get result :epoch) :seq seq))
      ;; Do not apply idle until replay finishes: tools may still be running.
      (if (< seq (plist-get result :seq))
          (agent-emx--set session :emx-replay result)
        (agent-emx--finish-attach session result))))
  (agent-emx--history-line session))

(defun agent-emx--finish-attach (session result)
  "Finish applying RESULT once its replay is complete."
  (agent-emx--set session :emx-replay nil)
  (agent-emx--info session (plist-get result :info))
  (agent-emx--settings session (plist-get result :settings))
  (agent-emx--set session :emx-capabilities (plist-get result :capabilities))
  (agent-emx--set session :emx-queue (plist-get result :queue))
  (agent-emx--set session :emx-attaching nil)
  (agent-session-set-status session (intern (plist-get result :status)))
  (let ((table (agent-emx--table session :emx-asks))
        (ids (mapcar (lambda (ask) (plist-get ask :id))
                     (append (plist-get result :asks) nil))))
    (dolist (id (hash-table-keys table))
      (unless (member id ids)
        (when-let* ((ask (agent-session--ask session (gethash id table)))
                    ((not (plist-get ask :answer))))
          (agent-session--close-ask session ask "已失效"))
        (remhash id table)))
    (seq-doseq (ask (plist-get result :asks))
      (when (plist-get (agent-session--ask session (gethash (plist-get ask :id) table)) :answer)
        (remhash (plist-get ask :id) table))
      (agent-emx--ask session ask)))
  (agent-session--refresh session)
  (let ((waiters (agent-emx--get session :emx-waiters)))
    (agent-emx--set session :emx-waiters nil)
    (dolist (callback waiters) (funcall callback))))

(defun agent-emx--attach (session connection)
  "Attach SESSION on ready CONNECTION, opening it first if necessary."
  (let ((id (agent-emx--get session :emx-id))
        (generation (agent-emx--get session :emx-generation)))
    (if id
        (progn
          (puthash id session (agent-emx--connection-sessions connection))
          (agent-emx--request
           connection "session/attach"
           (append (list :id id)
                   (when (agent-emx--get session :emx-cursor)
                     (list :after (agent-emx--get session :emx-cursor))))
           (lambda (result)
             (when (and (buffer-live-p (agent-session-buffer session))
                        (equal generation (agent-emx--get session :emx-generation))
                        (not (agent-emx--get session :emx-stopped)))
               (agent-emx--attached session result)))
           (lambda (error)
             (when (equal generation (agent-emx--get session :emx-generation))
               (agent-emx--error session error)))))
      (agent-emx--request
       connection "session/open"
       (append (list :agent (or (agent-session--get (agent-session-agent session) :emx-agent)
                               (symbol-name (agent-session-agent session)))
                     :root (agent-session-root session) :settings (agent-emx--choices session))
               (when-let* ((handle (agent-session-handle session)))
                 (list :handle handle))
               (when (eq (agent-session-agent session) 'claude)
                 (let ((skills (agent-session-skills-dir session)))
                   (list :claude (append (when skills (list :skillsDir skills))
                                         (list :supersededSkills
                                               (vconcat (agent-session-superseded-skills)))))))
               (when (eq (agent-session-agent session) 'codex)
                 (let ((skills (agent-session-skills-dir session)))
                   (list :codex (append (when skills (list :skillsRoot skills))
                                        (list :supersededSkills
                                              (vconcat (agent-session-superseded-skills)))))))
               (when (agent-session-child-p session)
                 (list :parent (or (and (agent-session-parent session)
                                        (agent-emx--get (agent-session-parent session) :emx-id))
                                   "emacs")))
               (when (agent-emx--get session :resume)
                 (list :resume (agent-emx--get session :resume))))
       (lambda (result)
         (let ((id (plist-get result :id)))
           (if (or (not (equal generation (agent-emx--get session :emx-generation)))
                   (agent-emx--get session :emx-stopped)
                   (not (buffer-live-p (agent-session-buffer session))))
               (agent-emx--stop connection id)
             (agent-emx--set session :emx-id id)
             (agent-emx--attach session connection))))
       (lambda (error)
         (when (equal generation (agent-emx--get session :emx-generation))
           (agent-emx--error session error)))))))

(defun agent-emx--ready (session &optional callback)
  "Attach SESSION asynchronously, then run CALLBACK if supplied."
  (if (and (not (agent-emx--get session :emx-attaching))
           (agent-emx--get session :emx-id)
           (not (eq (agent-session-status session) 'disconnected))
           (when-let* ((connection (agent-emx--get session :emx-connection)))
             (and (agent-emx--connection-ready connection)
                  (process-live-p (agent-emx--connection-process connection)))))
      (when callback (funcall callback))
    (when callback
      (agent-emx--set session :emx-waiters
                      (append (agent-emx--get session :emx-waiters) (list callback))))
    (unless (agent-emx--get session :emx-attaching)
      (agent-emx--set session :emx-attaching t)
      (agent-session-set-status session 'starting)
      (let ((generation (agent-emx--get session :emx-generation)))
        (agent-emx--connection
         session (lambda (connection)
                   (when (and (equal generation (agent-emx--get session :emx-generation))
                              (not (agent-emx--get session :emx-stopped)))
                     (agent-emx--attach session connection)))
         (lambda (error)
           (when (equal generation (agent-emx--get session :emx-generation))
             (agent-emx--error session error))))))))

(defun agent-emx--rpc (session method &optional params callback)
  "Send SESSION's METHOD and PARAMS, then call CALLBACK with the result."
  (agent-emx--ready
   session
   (lambda ()
     (agent-emx--request (agent-emx--get session :emx-connection) method
                         (append (list :id (agent-emx--get session :emx-id))
                                 (when (and (member method '("session/send" "session/steer"))
                                            (agent-session-handle session))
                                   (list :handle (agent-session-handle session))) params)
                         callback (lambda (error) (agent-emx--error session error))))))

(defun agent-emx--choices (session)
  "Return SESSION's settings in wire form."
  (append
   (cl-loop for key in '(:model :effort :mode)
            for value = (agent-session-setting session key)
            append (list key (if (symbolp value) (and value (symbol-name value)) value)))
   (when-let* ((mode (plist-get (agent-session-settings session) :before-plan)))
     (list :beforePlan (symbol-name mode)))))

(defun agent-emx--message (text)
  "Return wire fields for message TEXT and its already displayed block."
  (append (list :text (agent-session-message-text text))
          (when agent-session-outgoing-block (list :block agent-session-outgoing-block))
          (when-let* ((images (agent-session-message-images text)))
            (list :images (vconcat images)))))

(cl-defmethod agent-session-backend-start ((_ (eql emx)) session)
  (agent-emx--set session :emx-stopped nil)
  (agent-emx--ready session))

(cl-defmethod agent-session-backend-send ((_ (eql emx)) session text)
  (agent-emx--rpc session "session/send" (agent-emx--message text)))

(cl-defmethod agent-session-backend-steer ((_ (eql emx)) session text)
  (let ((params (agent-emx--message text)))
    (agent-emx--rpc
     session "session/steer" params
     (lambda (result)
       ;; The generic returns before the daemon can report accepted:false.
       ;; Keep the displayed block's id when falling back to a queued send.
       (unless (eq (plist-get result :accepted) t)
         (agent-session-notice session "该 agent 不支持引导，已中断当前回合，随后发送")
         (agent-emx--rpc session "session/interrupt")
         (agent-emx--rpc session "session/send" params)))))
  t)

(cl-defmethod agent-session-backend-interrupt ((_ (eql emx)) session)
  (agent-emx--rpc session "session/interrupt"))

(cl-defmethod agent-session-backend-apply-settings ((_ (eql emx)) session _changed)
  (agent-emx--rpc session "session/configure" (agent-emx--choices session)))

(cl-defmethod agent-session-backend-modes ((_ (eql emx)) session)
  (mapcar #'intern (append (plist-get (agent-emx--get session :emx-capabilities) :modes) nil)))

(cl-defmethod agent-session-backend-models ((_ (eql emx)) session)
  (mapcar (lambda (model)
            (list :id (plist-get model :id) :name (plist-get model :name)
                  :description (plist-get model :description)
                  :efforts (append (plist-get model :efforts) nil)
                  :default-effort (plist-get model :defaultEffort)))
          (append (plist-get (agent-emx--get session :emx-capabilities) :models) nil)))

(cl-defmethod agent-session-backend-commands ((_ (eql emx)) session)
  (append (plist-get (agent-emx--get session :emx-capabilities) :commands) nil))

(cl-defmethod agent-session-backend-stop ((_ (eql emx)) session)
  (agent-emx--set session :emx-generation
                  (1+ (or (agent-emx--get session :emx-generation) 0)))
  (agent-emx--set session :emx-stopped t)
  (agent-emx--set session :emx-attaching nil)
  (agent-emx--set session :emx-replay nil)
  (agent-emx--set session :emx-waiters nil)
  (when-let* ((connection (agent-emx--get session :emx-connection))
              (id (agent-emx--get session :emx-id)))
    (agent-emx--cancel-deferred connection id)
    (remhash id (agent-emx--connection-sessions connection))
    (agent-emx--stop connection id))
  (agent-emx--set session :emx-id nil))

(cl-defmethod agent-session-backend-reconnect ((_ (eql emx)) session)
  (agent-emx--ready session)
  t)

(defun agent-emx-reconnect (&optional session)
  "Reconnect the current daemon SESSION asynchronously."
  (interactive)
  (setq session (or session (agent-session--this)))
  (unless (eq (agent-session-backend session) 'emx)
    (user-error "当前会话不由 emx daemon 管理"))
  (agent-emx--ready session))

(provide 'agent-emx)
;;; agent-emx.el ends here
