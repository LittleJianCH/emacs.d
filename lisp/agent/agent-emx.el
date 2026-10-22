;;; agent-emx.el --- Render sessions owned by an emx daemon -*- lexical-binding: t; -*-

;;; Commentary:

;; All enabled agents use this daemon client.
;; Register agents with :backend emx and optionally :emx-agent "name".
;; The socket belongs to the connection; session objects hold only views.

;;; Code:

(require 'agent-session)
(require 'json)
(require 'agent-usage)
(require 'agent-ui)
(require 'agent-emx-config)

(declare-function agent-emx-remote-connection "agent-emx-remote")
(declare-function agent-emx-remote-push-config "agent-emx-remote")
(declare-function agent-emx-remote-usage "agent-emx-remote")
(declare-function agent-emx-remote-configure-usage "agent-emx-remote")
(declare-function agent-emx-remote-config-call "agent-emx-remote")
(declare-function agent-emx-remote-path "agent-emx-remote")
(declare-function agent-emx-remote-result "agent-emx-remote")

(defgroup agent-emx nil
  "Sessions owned by the emx daemon."
  :group 'agent-session)

(defvar agent-emx--adopting nil
  "Dynamic (CONNECTION . SUMMARY) while opening a daemon view.")
(declare-function agent-collab--link-tool "agent-collab")

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
    ("environment-fallback" . "项目环境读取失败，使用基础环境：%s")
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
    ("claude-task-done"
     . (lambda (args)
         (let* ((description (plist-get args :description))
                (summary (plist-get args :summary))
                (label (pcase (plist-get args :status)
                         ("completed" "后台任务完成")
                         ("failed" "后台任务失败")
                         ("stopped" "后台任务已停止")
                         (_ "后台任务结束")))
                (name (if (and (stringp description)
                               (not (string-empty-p description)))
                          description
                        (and (stringp summary)
                             (not (string-empty-p summary))
                             summary))))
           (if name (concat label "：" name) label))))
    ("claude-restart-deferred" . "后台任务运行中，Emacs 工具更新将在任务结束后生效")
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
  pending-stops pending-cancellations role capabilities remote starting)

(defvar agent-emx--connections (make-hash-table :test #'equal)
  "Connections keyed by (PLACE . VAR-DIRECTORY), for future remote use.")

(defvar agent-emx--tools-signatures (make-hash-table :test #'eq)
  "Connection -> last tools signature sent to its daemon.")

(defun agent-emx--get (session key)
  "Return backend state KEY of SESSION."
  (plist-get (agent-session-client session) key))

(defun agent-emx--set (session key value)
  "Set backend state KEY of SESSION to VALUE."
  (setf (agent-session-client session)
        (plist-put (agent-session-client session) key value))
  value)

(defun agent-emx--table (session key)
  "Return or create SESSION's hash table at state KEY."
  (or (agent-emx--get session key)
      (agent-emx--set session key (make-hash-table :test #'equal))))

(defvar agent-emx-reload--restarting (make-hash-table :test #'eq)
  "Connections awaiting automatic restart recovery, with target versions.")

(defvar agent-emx-reload--recovering (make-hash-table :test #'eq)
  "Connections with one active automatic restart recovery loop.")

(defvar agent-emx--wire-message nil
  "Current parsed config message, with null distinct from empty objects.")
(defvar agent-emx-config--wire nil
  "Effective local config with JSON types preserved for host daemons.")

(defun agent-emx--receive-config (config)
  "Cache local CONFIG and its verbatim wire object for remote hello/push."
  (setq agent-emx-config--wire
        (when agent-emx--wire-message
          (agent-emx--wire-object
           (plist-get (or (plist-get agent-emx--wire-message :result)
                          (plist-get agent-emx--wire-message :params)) :config))))
  (agent-emx-config-receive config))

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
  (agent-usage--disconnected connection)
  (when quiet
    (setq error (plist-put (copy-sequence error) :connection-lost t)))
  (remhash connection agent-emx--tools-signatures)
  (setf (agent-emx--connection-ready connection) nil
        (agent-emx--connection-starting connection) nil)
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

(defun agent-emx--cancelled-p (connection summary)
  "Return non-nil when SUMMARY has a pending cancellation on CONNECTION."
  (or (member (plist-get summary :id)
              (agent-emx--connection-pending-stops connection))
      (member (plist-get summary :creationId)
              (agent-emx--connection-pending-cancellations connection))))

(defun agent-emx--canonical-view (connection summary)
  "Return one view for SUMMARY on CONNECTION and discard duplicate views."
  (let* ((id (plist-get summary :id))
         (creation (plist-get summary :creationId))
         (info (plist-get summary :info))
         (mapped (gethash id (agent-emx--connection-sessions connection)))
         matches)
    (when (and mapped (buffer-live-p (agent-session-buffer mapped))
               (not (agent-emx--get mapped :emx-stopped)))
      (push mapped matches))
    (dolist (buffer (agent-session-buffers))
      (let ((view (buffer-local-value 'agent-session--current buffer)))
        (when (and (eq connection (agent-emx--get view :emx-connection))
                   (not (agent-emx--get view :emx-stopped))
                   (or (equal id (agent-emx--get view :emx-id))
                       (and creation (equal creation (agent-emx--get view :emx-creation-id)))))
          (cl-pushnew view matches))))
    ;; Native resume ids are only a fallback for unbound top-level views.
    ;; Children may share a fixture/native id and still be distinct sessions.
    (unless (or matches (plist-get info :parent) (not (plist-get info :sessionId)))
      (setq matches
            (seq-keep
             (lambda (buffer)
               (let ((view (buffer-local-value 'agent-session--current buffer)))
                 (and (eq connection (agent-emx--get view :emx-connection))
                      (not (agent-emx--get view :emx-stopped))
                      (not (agent-emx--get view :emx-id))
                      (not (agent-session-child-p view))
                      (equal (plist-get info :sessionId) (agent-session-resume-id view))
                      (equal (plist-get summary :agent)
                             (or (agent-session--get (agent-session-agent view) :emx-agent)
                                 (symbol-name (agent-session-agent view))))
                      (equal (agent-session-root view)
                             (agent-emx-remote-path connection (plist-get summary :root)))
                      view)))
             (agent-session-buffers))))
    (let ((canonical (if (memq mapped matches) mapped (car (last matches)))))
      (dolist (duplicate (delq canonical matches))
        ;; Preserve children when removing only their duplicate parent view.
        (dolist (child (agent-session-children duplicate))
          (setf (agent-session-info child)
                (plist-put (agent-session-info child) :parent
                           (agent-session-buffer canonical))))
        ;; The duplicate owns only a view, never the daemon session's lifetime.
        (agent-emx--set duplicate :emx-id nil)
        (agent-emx--set duplicate :emx-creation-id nil)
        (agent-emx--set duplicate :emx-connection nil)
        (agent-emx--set duplicate :emx-generation (make-symbol "duplicate"))
        (agent-emx--set duplicate :emx-stopped t)
        (agent-session-kill-quietly (agent-session-buffer duplicate)))
      canonical)))

(defun agent-emx--adopt (connection summary)
  "Create a view for daemon SUMMARY on CONNECTION, without a new CLI."
  (let* ((id (plist-get summary :id))
         (info (plist-get summary :info))
         (parent (gethash (plist-get info :parent)
                          (agent-emx--connection-sessions connection))))
    (unless (agent-emx--cancelled-p connection summary)
      (or (when-let* ((existing
                       (agent-emx--canonical-view connection summary)))
            (agent-emx--set existing :emx-id id)
            (agent-emx--set existing :emx-creation-id (plist-get summary :creationId))
            (puthash id existing (agent-emx--connection-sessions connection))
            (when (and (eq (agent-session-status existing) 'disconnected)
                       (not (agent-emx--get existing :emx-attaching)))
              (agent-emx--set existing :emx-attaching t)
              (agent-emx--attach existing connection))
            existing)
          (when (or parent (not (plist-get info :parent)))
            (let* ((agent (intern (plist-get summary :agent)))
                   (entry (copy-sequence (cdr (assq agent agent-session-agents))))
                   (agent-session-agents
                    (cons (cons agent (plist-put entry :backend 'emx))
                          (assq-delete-all agent (copy-sequence agent-session-agents))))
                   (agent-emx--adopting (cons connection summary))
                   (agent-session-opening-view t)
                   (buffer (agent-session-open
                            agent (agent-emx-remote-path connection (plist-get summary :root)) nil nil
                            (if parent
				(plist-put (copy-sequence info) :parent
                                           (agent-session-buffer parent))
                              (copy-sequence info))))
                   (child (buffer-local-value 'agent-session--current buffer)))
              (agent-session-set-handle child (plist-get info :handle))
              (when (and parent (fboundp 'agent-collab--link-tool))
		(agent-collab--link-tool parent child))
              child))))))

(defun agent-emx--recover (connection summaries)
  "Recover live root views on CONNECTION before their child SUMMARIES."
  (seq-doseq (summary summaries)
    (unless (or (plist-get (plist-get summary :info) :parent)
                (equal (plist-get summary :status) "exited")
                (member (plist-get summary :id)
                        (agent-emx--connection-pending-stops connection)))
      (agent-emx--adopt connection summary)))
  (seq-doseq (summary summaries)
    (when (plist-get (plist-get summary :info) :parent)
      (agent-emx--adopt connection summary))))

(defun agent-emx--close-view (connection id)
  "Close the view of daemon ID on CONNECTION after daemon-owned cleanup."
  (when-let* ((session (gethash id (agent-emx--connection-sessions connection))))
    (remhash id (agent-emx--connection-sessions connection))
    (agent-emx--set session :emx-id nil)
    (agent-emx--set session :emx-stopped t)
    (agent-session-kill-quietly (agent-session-buffer session))))

(defun agent-emx--route-id (connection)
  "Return a stable opaque route for CONNECTION across editor restarts."
  (secure-hash 'sha256
               (prin1-to-string (list (when-let* ((place (agent-emx--connection-place connection)))
                                        (file-remote-p place))
                                      (agent-emx--connection-var connection)))))

(defun agent-emx--hub-connections (&optional except)
  "Return attached editor connections, excluding EXCEPT and usage clients."
  (let (connections)
    (maphash
     (lambda (_ connection)
       (when (and (not (eq connection except))
                  (not (eq (agent-emx--connection-role connection) 'usage))
                  (agent-emx--connection-ready connection)
                  (process-live-p (agent-emx--connection-process connection)))
         (cl-pushnew connection connections)))
     agent-emx--connections)
    connections))

(defun agent-emx--hub-list (source success failure)
  "Collect sessions outside SOURCE, then call SUCCESS or FAILURE."
  (let* ((connections (agent-emx--hub-connections source))
         (remaining (length connections)) rows failed)
    (if (zerop remaining) (funcall success nil)
      (dolist (connection connections)
        (agent-emx--request
         connection "collab/list" nil
         (lambda (result)
           (seq-doseq (row (plist-get result :sessions))
             (let* ((route (agent-emx--route-id connection))
                    (handle (plist-get row :id))
                    (row (copy-sequence row)))
               (setq row (plist-put row :id (concat handle "#" route))
                     row (plist-put row :handle handle)
                     row (plist-put row :daemon route)
                     row (plist-put row :place
                                    (or (agent-emx--connection-place connection) "local")))
               (when-let* ((parent (plist-get row :parent)))
                 (setq row (plist-put row :parent (concat parent "#" route))))
               (setq row (plist-put row :children
                                    (vconcat (mapcar (lambda (child) (concat child "#" route))
                                                    (append (plist-get row :children) nil)))))
               (push (cons connection row) rows)))
           (when (and (zerop (cl-decf remaining)) (not failed))
             (funcall success rows)))
         (lambda (error)
           (unless failed (setq failed t) (funcall failure error))))))))

(defun agent-emx--hub-call (connection message)
  "Route a private collaboration MESSAGE through the attached editor."
  (let* ((process (agent-emx--connection-process connection))
         (id (plist-get message :id))
         (params (plist-get message :params))
         (method (plist-get params :method))
         (args (plist-get params :params))
         (caller (plist-get params :caller))
         (success (lambda (value)
                    (when (eq process (agent-emx--connection-process connection))
                      (agent-emx--write connection
                                      (list :jsonrpc "2.0" :id id
                                            :result (list :ok t :result value))))))
         (failure (lambda (error)
                    (when (eq process (agent-emx--connection-process connection))
                      (agent-emx--write
                     connection (list :jsonrpc "2.0" :id id
                                      :result (list :ok :false
                                                    :error (or (plist-get error :message)
                                                               "Cross-daemon call failed"))))))))
    (cond
     ((equal method "_collab_deliver")
      (let* ((route (plist-get args :route))
             (target (seq-find
                      (lambda (peer) (equal (agent-emx--route-id peer) (plist-get route :daemon)))
                      (agent-emx--hub-connections))))
        (if target
            (agent-emx--request target "collab/deliver" args success failure)
          (funcall failure '(:message "Source daemon is not attached to Emacs")))))
     ((member method '("_collab_sessions" "_collab_read" "_collab_ask"))
      (agent-emx--hub-list
       connection
       (lambda (rows)
         (if (equal method "_collab_sessions")
             (funcall success (vconcat (mapcar #'cdr rows)))
           (let* ((name (plist-get args :session))
                  (exact (seq-filter (lambda (entry) (equal name (plist-get (cdr entry) :id))) rows))
                  (matches (or exact
                               (seq-filter
                                (lambda (entry)
                                  (or (equal name (plist-get (cdr entry) :handle))
                                      (equal name (plist-get (cdr entry) :session)))) rows))))
             (cond
              ((null matches)
               (funcall failure '(:message "No such session on an attached daemon; list them with sessions")))
              ((cdr matches)
               (funcall failure '(:message "Ambiguous session handle; use the qualified id from sessions")))
              (t
               (let* ((entry (car matches))
                      (target (car entry))
                      (session (gethash (plist-get caller :session)
                                        (agent-emx--connection-sessions connection)))
                      (forward
                       (if (equal method "_collab_ask")
                           (list :id (plist-get (cdr entry) :session)
                                 :prompt (plist-get args :prompt)
                                 :route (list :daemon (agent-emx--route-id connection)
                                              :session (plist-get caller :session))
                                 :origin (plist-get args :origin))
                         (append (list :id (plist-get (cdr entry) :session))
                                 (cl-loop for key in '(:last :before :tools)
                                          when (plist-member args key)
                                          append (list key (plist-get args key)))))))
                 (if (not (and session (buffer-live-p (agent-session-buffer session))))
                     (funcall failure '(:message "Calling session is not attached to Emacs"))
                   (agent-emx--request target
                                       (if (equal method "_collab_ask") "collab/ask" "collab/read")
                                       forward success failure))))))))
       failure))
     (t (funcall failure '(:message "Unknown collaboration hub request"))))))

(defun agent-emx--editor-call (connection message)
  "Answer an editor request MESSAGE on CONNECTION without blocking."
  (let* ((id (plist-get message :id))
         (params (plist-get message :params))
         (method (plist-get params :method))
         (args (agent-emx--editor-params (plist-get params :params)))
         (caller (plist-get params :caller))
         (session-id (plist-get caller :session))
         (session (gethash session-id (agent-emx--connection-sessions connection))))
    (cond
     ((and (stringp method) (string-prefix-p "_collab_" method))
      (agent-emx--hub-call connection message))
     ((and (agent-emx--connection-place connection)
             (member method '("config_read" "config_edit" "config_write")))
        (agent-emx-remote-config-call connection message))
     (t (agent-emx--write
       connection
       (append
	(list :jsonrpc "2.0" :id id)
	(cond
	 ((not (equal (plist-get message :method) "editor/call"))
          (list :error '(:code -32601 :message "Unknown editor request")))
	 ((member method '("_config_modified" "_config_written"))
          (condition-case err
              (list :result
                    (list :ok t :result
                          (if (equal method "_config_modified")
                              (if (agent-ui-file-modified-p (plist-get args :path)) t :false)
                            (agent-ui-file-written (plist-get args :path)) :null)))
            (error (list :result (list :ok :false :error (error-message-string err))))))
	 ;; Private daemon requests are never MCP tool definitions.
	 ((equal method "_session_open")
          (condition-case err
              (progn (agent-emx--adopt connection (plist-get args :session))
                     (list :result '(:ok t :result t)))
            (error (list :result (list :ok :false :error (error-message-string err))))))
	 ((equal method "_session_visible")
          (list :result (list :ok t :result
                              (list :visible
                                    (if (and session
                                             (get-buffer-window
                                              (agent-session-buffer session) t))
					t :false)))))
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
            (list :result (agent-emx-remote-result connection result)))))))))))

(defun agent-emx--tools (&optional place)
  "Return this machine's MCP definitions and private read-only classification."
  (list :tools (agent-ui--describe place)
        :readOnly (vconcat (agent-ui-read-only-methods place))))

(defun agent-emx--tools-signature (tools)
  "Hash captured TOOLS definitions and private permission classification."
  (secure-hash 'sha1 (json-serialize tools)))

(defun agent-emx--publish-tools ()
  "Publish changed local tools on every ready daemon connection."
  (maphash
   (lambda (_ connection)
     (when (and (not (eq (agent-emx--connection-role connection) 'usage))
                (agent-emx--connection-ready connection)
                (process-live-p (agent-emx--connection-process connection)))
       (let* ((tools (agent-emx--tools (agent-emx--connection-place connection)))
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
       ((equal method "daemon/restarting")
        (puthash connection (plist-get params :version) agent-emx-reload--restarting)
        (message "emx 代码已更新，正在休眠会话并重启；下次发送时恢复"))
       ((equal method "daemon/restart-failed")
        (remhash connection agent-emx-reload--restarting)
        (remhash connection agent-emx-reload--recovering)
        (message "emx 更新失败：%s" (plist-get params :error)))
       ((equal method "collab/closed")
        (agent-emx--close-view connection (plist-get params :id)))
       ((equal method "sessions")
        (seq-doseq (summary (plist-get params :sessions))
          (when (plist-get (plist-get summary :info) :parent)
            (agent-emx--adopt connection summary))))
       ((equal method "config")
        (unless (agent-emx--connection-place connection)
          (agent-emx--receive-config (plist-get params :config))
          (agent-emx-remote-push-config)))
       ((equal method "usage/outbox")
        (agent-emx-remote-usage connection (plist-get params :entries)))
       ((and (not (agent-emx--connection-place connection))
             (equal method "usage/changed"))
        (run-hooks 'agent-usage-change-functions))
       ((and (not (agent-emx--connection-place connection))
             (equal method "usage/quotas"))
        (agent-usage--receive-quotas (plist-get params :quotas)))
       ((equal method "replaced")
        (agent-emx--lost connection '(:message "Connection replaced") t)
        (delete-process (agent-emx--connection-process connection)))
       ((and session (buffer-live-p (agent-session-buffer session)))
        (agent-emx--event session method params)))))))

(defun agent-emx--wire-object (value)
  "Preserve parsed config VALUE's empty objects and nulls for forwarding."
  (cond
   ((listp value)
    (let ((object (make-hash-table :test #'equal)))
      (while value
        (puthash (substring (symbol-name (pop value)) 1)
                 (agent-emx--wire-object (pop value)) object))
      object))
   ((vectorp value) (vconcat (mapcar #'agent-emx--wire-object value)))
   (t value)))

(defun agent-emx--ui-nulls (value)
  "Convert parsed null markers in VALUE to the UI's nil convention."
  (cond
   ((eq value :null) nil)
   ((consp value) (cons (agent-emx--ui-nulls (car value))
                        (agent-emx--ui-nulls (cdr value))))
   ((vectorp value) (vconcat (mapcar #'agent-emx--ui-nulls value)))
   (t value)))

(defun agent-emx--filter (connection bytes)
  "Buffer partial BYTES on CONNECTION and dispatch complete UTF-8 lines."
  (setf (agent-emx--connection-input connection)
        (concat (agent-emx--connection-input connection) bytes))
  (let (end)
    (while (setq end (string-search "\n" (agent-emx--connection-input connection)))
      (let* ((input (agent-emx--connection-input connection))
             (line (substring input 0 end)))
        ;; Dispatch can run a nested event loop, including this same filter.
        (setf (agent-emx--connection-input connection) (substring input (1+ end)))
        (unless (string-empty-p line)
          (condition-case err
              (let* ((wire (json-parse-string (decode-coding-string line 'utf-8)
                                               :object-type 'plist
                                               :null-object :null :false-object :false))
                     (container (or (plist-get wire :result) (plist-get wire :params)))
                     (agent-emx--wire-message
                      (and (consp container) (plist-member container :config) wire)))
                ;; Most stream deltas need no traversal after the native parser.
                (agent-emx--dispatch connection
                                     (if (string-search "null" line)
                                         (agent-emx--ui-nulls wire) wire)))
            (error (message "emx 事件处理失败：%s" (error-message-string err)))))))))

(defun agent-emx--connect (connection result)
  "Connect CONNECTION to the daemon described by ensure RESULT."
  (when (eq (plist-get result :stale) t)
    (message "emx daemon 代码已过期；运行 reload 会在会话空闲后自动更新"))
  (setf (agent-emx--connection-starter connection) nil
        (agent-emx--connection-starting connection) nil
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
                       (agent-emx--lost connection (list :message (string-trim event)) t)
                       (agent-emx-reload--disconnected connection)))))
  (let* ((usage (eq (agent-emx--connection-role connection) 'usage))
         (tools (unless usage (agent-emx--tools (agent-emx--connection-place connection))))
         (signature (unless usage (agent-emx--tools-signature tools))))
    (agent-emx--request
     connection (if usage "usage/hello" "hello")
     (if usage (make-hash-table)
       (append (list :client "emacs" :version (plist-get result :version) :tools tools
		     :agents (vconcat (mapcar (lambda (a) (symbol-name (car a)))
					      agent-session-agents)))
               (when (agent-emx--connection-place connection)
                 (list :config (or agent-emx-config--wire agent-emx-config--value)))))
     (lambda (hello)
       (let* ((cancelled (copy-sequence
                          (agent-emx--connection-pending-cancellations connection)))
              (stopped (append
                        (copy-sequence (agent-emx--connection-pending-stops connection))
                        (seq-keep (lambda (summary)
                                    (when (member (plist-get summary :creationId) cancelled)
                                      (plist-get summary :id)))
                                  (plist-get hello :sessions)))))
	 (setf (agent-emx--connection-capabilities connection) (plist-get hello :capabilities))
	 (if (and usage (not (agent-usage--capable-p connection)))
             (progn
               (agent-emx--lost connection '(:message "Daemon does not support acknowledged usage"))
               (delete-process (agent-emx--connection-process connection)))
           (unless (agent-emx--connection-place connection)
             (agent-emx--receive-config (plist-get hello :config)))
           (unless usage
             (puthash connection signature agent-emx--tools-signatures)
             (agent-emx--flush-stops connection))
           (setf (agent-emx--connection-ready connection) t)
           (unless (agent-emx--connection-place connection)
             (agent-emx-remote-push-config))
           (when (agent-emx--connection-place connection)
             (agent-emx-remote-configure-usage connection))
           (agent-emx--flush-cancellations
            connection
            (lambda ()
              (unless usage
                (agent-emx--recover
                 connection
                 (seq-remove (lambda (summary)
                               (or (member (plist-get summary :id) stopped)
                                   (member (plist-get (plist-get summary :info) :parent) stopped)
                                   (member (plist-get summary :creationId) cancelled)))
                             (plist-get hello :sessions)))
                (dolist (peer (agent-emx--hub-connections))
                  (agent-emx--request peer "collab/retry" nil)))
              (let ((waiters (agent-emx--connection-waiters connection)))
                (setf (agent-emx--connection-waiters connection) nil)
                (dolist (pair waiters) (funcall (car pair) connection))))))))
     (lambda (error)
       (agent-emx--lost connection error)
       (delete-process (agent-emx--connection-process connection))))))

(defun agent-emx--flush-cancellations (connection &optional done)
  "Cancel uncertain opens on CONNECTION before invoking DONE for recovery."
  (let* ((pending (copy-sequence
                   (agent-emx--connection-pending-cancellations connection)))
         (remaining (length pending))
         (finish (lambda ()
                   (cl-decf remaining)
                   (when (and (= remaining 0) done) (funcall done)))))
    (if (null pending) (when done (funcall done))
      (dolist (creation pending)
        (agent-emx--request
         connection "session/cancel" (list :creationId creation)
         (lambda (_)
           (setf (agent-emx--connection-pending-cancellations connection)
                 (delete creation (agent-emx--connection-pending-cancellations connection)))
           (funcall finish))
         (lambda (_) (funcall finish)))))))

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

(defun agent-emx--local-connection (callback error-callback &optional role)
  "Obtain the local daemon connection without waiting interactively.
Call CALLBACK after hello or ERROR-CALLBACK on failure.
ROLE usage obtains a separate non-exclusive connection."
  (agent-usage--migrate)
  (let* ((var (expand-file-name agent-emx-var-directory))
         (key (cons role var))
         (connection (or (gethash key agent-emx--connections)
                         (puthash key (agent-emx--make-connection :var var :role role)
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
  (let* ((generation (agent-emx--get session :emx-generation))
         (receive (lambda (connection)
                    (when (eq generation (agent-emx--get session :emx-generation))
                      (agent-emx--set session :emx-connection connection)
                      (funcall callback connection))))
         (failure (lambda (error)
                    (when (eq generation (agent-emx--get session :emx-generation))
                      (when error-callback (funcall error-callback error)))))
         (connection
          (if (agent-session-place (agent-session-root session))
              (agent-emx-remote-connection (agent-session-root session) receive failure)
            (agent-emx--local-connection receive failure))))
    (when (eq generation (agent-emx--get session :emx-generation))
      (agent-emx--set session :emx-connection connection))
    connection))

(defun agent-emx-history (agent root callback)
  "Fetch AGENT's past sessions in ROOT from its daemon into CALLBACK."
  (setq root (expand-file-name root))
  (let ((receive
         (lambda (connection)
           (agent-emx--request
            connection "sessions/history"
            (list :agent (symbol-name agent)
                  :root (agent-session-process-directory root))
            (lambda (result)
              (funcall callback
                       (mapcar (lambda (item)
                                 (if (plist-get item :root)
                                     (plist-put item :root
                                                (agent-emx-remote-path connection
                                                                       (plist-get item :root)))
                                   item))
                               (append (plist-get result :items) nil))))
            (lambda (error)
              (message "读取历史会话失败：%s" (plist-get error :message))
              (funcall callback nil)))))
        (fail (lambda (error)
                (message "读取历史会话失败：%s" (plist-get error :message))
                (funcall callback nil))))
    (if (file-remote-p root)
        (progn
          (agent-session-ensure-programs root)
          (agent-emx-remote-connection root receive fail))
      (agent-emx--local-connection receive fail))))

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
                   (_ 'agent-session-dim))))
         ;; A background task finishing while idle starts an autonomous turn
         ;; with this notice as its first block: fold that turn here, not on a
         ;; message.  Mid-turn completions stay inside the current turn.
         (props (when (and (equal kind "claude-task-done")
                           (eq (plist-get args :autonomous) t))
                  (list :turn-start t))))
    (if (agent-session--block session id)
        (apply #'agent-session--update session id :text text :face face props)
      (apply #'agent-session-notice session text face id props))))

(defun agent-emx--block (session block)
  "Render a complete wire BLOCK in SESSION."
  (let* ((id (plist-get block :id))
         (existing (agent-session--block session id)))
    (puthash id block (agent-emx--table session :emx-blocks))
    (pcase (plist-get block :type)
      ("user"
       (unless existing
         (agent-session--new-block session id
                                   (list :type 'user :origin (plist-get block :origin) :text
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
The daemon parent id is not an Emacs buffer."
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

(defun agent-emx--skills-context (session)
  "Return backend-neutral skill context for SESSION."
  (list :skillsDir (if (file-remote-p (agent-session-root session))
                       (agent-emx--get session :emx-skills)
                     (agent-session-skills-dir session))
        :supersededSkills (vconcat (agent-session-superseded-skills))))

(defun agent-emx--publish-skills ()
  "Refresh skill context on attached sessions after skill registration."
  (maphash
   (lambda (_ connection)
     (when (agent-emx--connection-ready connection)
       (maphash
        (lambda (id session)
          (when (buffer-live-p (agent-session-buffer session))
            (when (file-remote-p (agent-session-root session))
              (agent-emx--set session :emx-skills (agent-session-skills-dir session)))
            (agent-emx--request connection "session/context"
                                (list :id id :skills (agent-emx--skills-context session)))))
        (agent-emx--connection-sessions connection))))
   agent-emx--connections))

(add-hook 'agent-session-skills-change-functions #'agent-emx--publish-skills)

(defun agent-emx--attach (session connection)
  "Attach SESSION on ready CONNECTION, opening it first if necessary."
  (agent-emx--set session :emx-connection connection)
  (let ((id (agent-emx--get session :emx-id))
        (generation (or (agent-emx--get session :emx-generation)
                        (agent-emx--set session :emx-generation (make-symbol "start")))))
    (if id
        (progn
          (let ((canonical (agent-emx--canonical-view
                            connection (list :id id :creationId
                                             (agent-emx--get session :emx-creation-id)))))
            (when (and canonical (not (eq canonical session)))
              (setq session canonical
                    generation (agent-emx--get canonical :emx-generation))))
          (puthash id session (agent-emx--connection-sessions connection))
          (agent-emx--request
           connection "session/attach"
           (append (list :id id)
                   (when (agent-emx--get session :emx-cursor)
                     (list :after (agent-emx--get session :emx-cursor))))
           (lambda (result)
             (when (and (buffer-live-p (agent-session-buffer session))
                        (eq generation (agent-emx--get session :emx-generation))
                        (not (agent-emx--get session :emx-stopped)))
               (agent-emx--attached session result)))
           (lambda (error)
             (when (eq generation (agent-emx--get session :emx-generation))
               (agent-emx--error session error)))))
      (agent-emx--request
       connection "session/open"
       (append (list :creationId
                     (or (agent-emx--get session :emx-creation-id)
                         (agent-emx--set session :emx-creation-id
                                         (md5 (format "%s:%s:%s:%s" (emacs-pid) (current-time)
                                                      (random) (buffer-name (agent-session-buffer session))))))
                     :agent (or (agent-session--get (agent-session-agent session) :emx-agent)
                               (symbol-name (agent-session-agent session)))
                     :root (agent-session-process-directory (agent-session-root session))
                     :settings (agent-emx--choices session)
                     :skills (agent-emx--skills-context session))
               (when-let* ((handle (agent-session-handle session)))
                 (list :handle handle))
               (when (agent-session-child-p session)
                 (list :parent (or (and (agent-session-parent session)
                                        (agent-emx--get (agent-session-parent session) :emx-id))
                                   "emacs")))
               (when (agent-emx--get session :resume)
                 (list :resume (agent-emx--get session :resume))))
       (lambda (result)
         (let ((id (plist-get result :id)))
           (if (or (not (eq generation (agent-emx--get session :emx-generation)))
                   (agent-emx--get session :emx-stopped)
                   (not (buffer-live-p (agent-session-buffer session))))
               (unless (gethash id (agent-emx--connection-sessions connection))
                 (agent-emx--stop connection id))
             (agent-emx--set session :emx-id id)
             (agent-emx--attach session connection))))
       (lambda (error)
         (when (eq generation (agent-emx--get session :emx-generation))
           (agent-emx--error session error)))))))

(defun agent-emx--ready (session &optional callback)
  "Attach SESSION asynchronously, then run CALLBACK if supplied."
  (when (and (not agent-emx-remote--automatic)
             (not (agent-emx--get session :emx-id))
             (file-remote-p (agent-session-root session)))
    (let* ((root (agent-session-root session))
           (expanded (expand-file-name root))
           (known (gethash (agent-session-place root) agent-session--remote-programs)))
      (unless (string-prefix-p "/" (file-local-name expanded))
        (error "Cannot resolve remote project root: %s" root))
      (setf (agent-session-root session) expanded)
      (when known
        (puthash (agent-session-place expanded) known agent-session--remote-programs))
      ;; Prepare skills here, before hello or any other process callback.
      (unless (agent-emx--get session :emx-skills-prepared)
        (agent-emx--set session :emx-skills (agent-session-skills-dir session))
        (agent-emx--set session :emx-skills-prepared t))))
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
                   (when (and (eq generation (agent-emx--get session :emx-generation))
                              (not (agent-emx--get session :emx-stopped)))
                     (agent-emx--attach session connection)))
         (lambda (error)
           (when (eq generation (agent-emx--get session :emx-generation))
             (agent-emx--error session error))))))))

(defun agent-emx--rpc (session method &optional params callback)
  "Send SESSION's METHOD and PARAMS, then call CALLBACK with the result."
  (let ((generation (agent-emx--get session :emx-generation)))
    (agent-emx--ready
     session
     (lambda ()
       (when (eq generation (agent-emx--get session :emx-generation))
         (agent-emx--request
          (agent-emx--get session :emx-connection) method
          (append (list :id (agent-emx--get session :emx-id))
                  (when (and (member method '("session/send" "session/steer"))
                             (agent-session-handle session))
                    (list :handle (agent-session-handle session))) params)
          (lambda (result)
            (when (and callback (eq generation (agent-emx--get session :emx-generation)))
              (funcall callback result)))
          (lambda (error)
            (when (eq generation (agent-emx--get session :emx-generation))
              (agent-emx--error session error)))))))))

(defun agent-emx--choices (session)
  "Return SESSION's settings in wire form."
  (append
   (cl-loop for key in '(:model :effort :mode)
            for value = (agent-session-setting session key)
            append (list key (if (symbolp value) (and value (symbol-name value)) value)))
   (when-let* ((mode (plist-get (agent-session-settings session) :before-plan)))
     (list :beforePlan (symbol-name mode)))))

(defun agent-emx--message (session text)
  "Return wire fields for TEXT in SESSION, uploading remote images first.
A message with a hidden note also carries the text its block shows, which
the daemon keeps when the agent echoes the whole message."
  (append (list :text (agent-session-message-text text))
          (when agent-session-outgoing-block (list :block agent-session-outgoing-block))
          (when-let* ((id agent-session-outgoing-block)
                      (block (agent-session--block session id))
                      ((plist-get block :hidden)))
            (list :display (agent-session-message-text (plist-get block :text))))
          (when-let* ((images (agent-session-message-images text)))
            (list :images (vconcat
                           (if (file-remote-p (agent-session-root session))
                               (mapcar (lambda (file)
                                         (agent-remote-upload (agent-session-root session) file))
                                       images)
                             images))))))

(cl-defmethod agent-session-backend-start ((_ (eql emx)) session)
  (agent-emx--set session :emx-generation (make-symbol "start"))
  (agent-emx--set session :emx-creation-id nil)
  (agent-emx--set session :emx-stopped nil)
  (when agent-emx--adopting
    (agent-emx--info session (plist-get (cdr agent-emx--adopting) :info))
    (agent-emx--set session :emx-id (plist-get (cdr agent-emx--adopting) :id))
    (agent-emx--set session :emx-creation-id (plist-get (cdr agent-emx--adopting) :creationId))
    (agent-emx--set session :emx-connection (car agent-emx--adopting))
    (puthash (agent-emx--get session :emx-id) session
             (agent-emx--connection-sessions (car agent-emx--adopting))))
  (if agent-emx--adopting
      (agent-emx--attach session (car agent-emx--adopting))
    (agent-emx--ready session)))

(cl-defmethod agent-session-backend-send ((_ (eql emx)) session text)
  (agent-emx--rpc session "session/send" (agent-emx--message session text)))

(cl-defmethod agent-session-backend-steer ((_ (eql emx)) session text)
  (let ((params (agent-emx--message session text)))
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
                  (make-symbol "stopped"))
  (agent-emx--set session :emx-stopped t)
  (agent-emx--set session :emx-attaching nil)
  (agent-emx--set session :emx-replay nil)
  (agent-emx--set session :emx-waiters nil)
  (when-let* ((connection (agent-emx--get session :emx-connection)))
    (if-let* ((id (agent-emx--get session :emx-id)))
        (progn
          (agent-emx--cancel-deferred connection id)
          (remhash id (agent-emx--connection-sessions connection))
          (agent-emx--stop connection id))
      (when-let* ((creation (agent-emx--get session :emx-creation-id)))
        (cl-pushnew creation (agent-emx--connection-pending-cancellations connection)
                    :test #'equal)
        (when (and (agent-emx--connection-ready connection)
                   (process-live-p (agent-emx--connection-process connection)))
          (agent-emx--flush-cancellations connection)))))
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

(defun agent-emx--daemon-connection (callback error-callback &optional connection)
  "Obtain CONNECTION's daemon or the current view's, else the local daemon.
Call CALLBACK or ERROR-CALLBACK without waiting for a remote ensure."
  (let* ((session (and (boundp 'agent-session--current) agent-session--current))
         (root (if connection (agent-emx--connection-place connection)
                 (and session (eq (agent-session-backend session) 'emx)
                      (agent-session-place (agent-session-root session))))))
    (if root (agent-emx-remote-connection root callback error-callback)
      (agent-emx--local-connection callback error-callback))))

(defun agent-emx--restart-after-stop (connection attempts)
  "Wait asynchronously for CONNECTION to close, with ATTEMPTS left."
  (if (process-live-p (agent-emx--connection-process connection))
      (if (> attempts 0)
          (run-at-time 0.1 nil #'agent-emx--restart-after-stop connection (1- attempts))
        (message "emx daemon 尚未停止，请稍后重试"))
    (let ((noninteractive nil))
      (agent-emx--daemon-connection
       (lambda (_)
         (when (and (not (agent-emx--connection-place connection))
                    agent-usage--monitoring)
           (agent-usage--start))
         (message "emx daemon 已休眠会话并重启；下次发送时恢复"))
       (lambda (error) (message "emx daemon 重启失败：%s" (plist-get error :message)))
       connection))))

(defun agent-emx-restart-daemon ()
  "Hibernate resumable idle sessions and start the checkout's current daemon.
Running turns, asks and ephemeral children must finish before restart."
  (interactive)
  (agent-emx--daemon-connection
   (lambda (connection)
     (agent-emx--request
      connection "sessions/list" nil
      (lambda (result)
        (if (seq-some (lambda (session)
                        (or (member (plist-get session :status) '("running" "starting"))
                            (plist-get (plist-get session :info) :parent)))
                      (plist-get result :sessions))
            (message "请先结束运行中的回合、审批和子会话，再重启 emx daemon")
          (agent-emx--request
           connection "daemon/stop" '(:idleOnly t)
           (lambda (_) (agent-emx--restart-after-stop connection 50))
           (lambda (error) (message "emx daemon 休眠失败：%s" (plist-get error :message))))))
      (lambda (error) (message "emx daemon 读取会话失败：%s" (plist-get error :message)))))
   (lambda (error) (message "emx daemon 连接失败：%s" (plist-get error :message)))))

(require 'agent-emx-remote)
(require 'agent-emx-reload)

(provide 'agent-emx)
;;; agent-emx.el ends here
