;;; agent-codex.el --- Codex backend (app-server JSON-RPC) -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs `codex app-server', speaking line-delimited JSON-RPC over stdio:
;;   initialize → initialized → thread/start → turn/start / turn/interrupt
;;   Notifications: turn/*, item/started, item/completed, item/*/delta,
;;     thread/tokenUsage/updated
;;   Server requests: item/commandExecution/requestApproval,
;;     item/fileChange/requestApproval
;; The emacs MCP server is injected into this process only via
;; -c mcp_servers.emacs.*; ~/.codex/config.toml is left untouched.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)
(require 'agent-remote)

(defgroup agent-codex nil
  "Codex backend."
  :group 'agent-session
  :prefix "agent-codex-")

(defcustom agent-codex-executable "codex"
  "The codex command."
  :type 'string)

(defconst agent-codex--modes
  ;; Same mapping as T3 Code:
  ;; (approval policy, sandbox, sandbox name for thread/start, reviewer)
  '((ask "untrusted" "readOnly" "read-only" "user")
    (edits "on-request" "workspaceWrite" "workspace-write" "user")
    (auto "on-request" "workspaceWrite" "workspace-write" "auto_review")
    (full "never" "dangerFullAccess" "danger-full-access" "user")
    ;; Read-only, and never asks: what can't run in the sandbox fails.
    (plan "never" "readOnly" "read-only" "user"))
  "Mapping from unified permission modes to Codex approval policy and sandbox.")

(defun agent-codex--mode (session)
  "Return the Codex settings for SESSION's current permission mode.
The value is (APPROVAL-POLICY SANDBOX-POLICY-TYPE SANDBOX-NAME REVIEWER)."
  (or (alist-get (agent-session-setting session :mode) agent-codex--modes)
      (alist-get 'edits agent-codex--modes)))

(defcustom agent-codex-extra-args nil
  "Extra command-line arguments (placed after app-server).
For example (\"-c\" \"model_reasoning_effort=\\\"high\\\"\")."
  :type '(repeat string))

(defcustom agent-codex-native-subagents nil
  "Non-nil lets Codex start its own subagents (its multi-agent tools).
Off by default: subagents go through Emacs (agent-collab.el).  The model
catalog switches multi-agent on for most models, which agents.enabled
overrides and the multi_agent feature flag does not."
  :type 'boolean)

(defun agent-codex--toml-string (string)
  "Return STRING as a TOML string literal."
  (concat "\""
          (replace-regexp-in-string
           "\n" "\\\\n"
           (replace-regexp-in-string
            "\t" "\\\\t"
            (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" string)))
          "\""))

(defun agent-codex--command (session)
  "Return the command line that starts SESSION."
  (append
   (list agent-codex-executable "app-server"
         ;; session_ask waits for another agent; the default is 60 seconds.
         "-c" "mcp_servers.emacs.tool_timeout_sec=1800")
   (if (file-remote-p (agent-session-root session))
       ;; On the host the MCP server is the relay to this Emacs's emx, which
       ;; needs no environment.
       (let ((relay (agent-remote-mcp-command session)))
         (list "-c" (concat "mcp_servers.emacs.command=" (agent-codex--toml-string (car relay)))
               "-c" (format "mcp_servers.emacs.args=[%s]"
                            (mapconcat #'agent-codex--toml-string (cdr relay) ","))))
     (let* ((emx (agent-session-emx-command))
            ;; codex doesn't pass the whole environment to MCP servers, so
            ;; give the variables emx needs explicitly.  A variable may
            ;; appear several times in the environment list (the first one
            ;; wins), but a TOML table may contain it only once.
            (env (mapcar (lambda (name)
                           (let ((entry (seq-find (lambda (e) (string-prefix-p (concat name "=") e))
                                                  (agent-session-environment session))))
                             (format "%s=%s" name (agent-codex--toml-string
                                                   (substring entry (1+ (length name)))))))
                         agent-session-emx-variables)))
       (list "-c" (concat "mcp_servers.emacs.command=" (agent-codex--toml-string (car emx)))
             "-c" (format "mcp_servers.emacs.args=[%s]"
                          (mapconcat #'agent-codex--toml-string (cdr emx) ","))
             "-c" (format "mcp_servers.emacs.env={%s}" (string-join env ",")))))
   ;; This replaces any [[skills.config]] of config.toml.
   (when-let* ((superseded (agent-session-superseded-skills)))
     (list "-c" (format "skills.config=[%s]"
                        (mapconcat (lambda (name)
                                     (format "{name=%s,enabled=false}"
                                             (agent-codex--toml-string name)))
                                   superseded ","))))
   (unless agent-codex-native-subagents
     (list "-c" "agents.enabled=false"))
   agent-codex-extra-args))

;;; JSON-RPC

(defun agent-codex--state (session key)
  "Return backend state KEY of SESSION."
  (plist-get (agent-session-state session) key))

(defun agent-codex--set (session key value)
  "Set backend state KEY of SESSION to VALUE."
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-codex--request (session method params &optional callback error-callback)
  "Send a JSON-RPC request for METHOD with PARAMS.
Call CALLBACK with the result, or ERROR-CALLBACK with the RPC error.
Without ERROR-CALLBACK, display the error as a session notice."
  (let ((id (1+ (or (agent-codex--state session :next-id) 0))))
    (agent-codex--set session :next-id id)
    (when callback
      (unless (agent-codex--state session :callbacks)
        (agent-codex--set session :callbacks (make-hash-table)))
      (puthash id callback (agent-codex--state session :callbacks)))
    (when error-callback
      (unless (agent-codex--state session :error-callbacks)
        (agent-codex--set session :error-callbacks (make-hash-table)))
      (puthash id error-callback (agent-codex--state session :error-callbacks)))
    (agent-session-write session (list :jsonrpc "2.0" :id id :method method
                                       :params (or params (make-hash-table))))))

(defun agent-codex--notify (session method &optional params)
  "Send a JSON-RPC notification for METHOD with PARAMS."
  (agent-session-write session (append (list :jsonrpc "2.0" :method method)
                                       (when params (list :params params)))))

(defun agent-codex--respond (session id result)
  "Reply to server request ID with RESULT."
  (agent-session-write session (list :jsonrpc "2.0" :id id :result result)))

;;; Backend interface

(declare-function agent-ui-tools-signature "agent-ui" ())

(defun agent-codex--tools-signature ()
  "Signature of the methods Emacs gives agents, or nil without agent-ui."
  (and (fboundp 'agent-ui-tools-signature) (agent-ui-tools-signature)))

(defun agent-codex--tools-stale-p (session)
  "Non-nil if Emacs's tools changed since the codex of SESSION started.
Codex lists MCP tools once per thread and ignores tools/list_changed, so a
saved thread is resumed in a new process to see them.  An unknown
signature, from a process started before this code was loaded, counts as
changed.  A child's thread isn't saved: it keeps the tools it started with."
  (and (agent-codex--state session :resume)
       (not (agent-session-child-p session))
       (not (equal (agent-codex--state session :tools) (agent-codex--tools-signature)))))

(cl-defmethod agent-session-backend-start ((_ (eql codex)) session)
  (agent-codex--set session :tools (agent-codex--tools-signature))
  (let ((skills (agent-session-skills-dir session)))
    (agent-session-start-process session (agent-codex--command session))
    (agent-codex--request
     session "initialize"
     (list :clientInfo (list :name "emacs" :title "Emacs" :version emacs-version))
     (lambda (_result)
       (agent-codex--notify session "initialized")
       (agent-codex--request
        session "model/list" (list :limit 50)
        (lambda (result) (agent-codex--set session :models (plist-get result :data))))
       ;; Codex loads the skills in the directories under an extra root;
       ;; the thread starts once they are known.
       (if skills
           (agent-codex--request
            session "skills/extraRoots/set"
            (list :extraRoots (vector (concat skills ".claude/skills")))
            (lambda (_result) (agent-codex--start-thread session)))
         (agent-codex--start-thread session))))))

(defun agent-codex--developer-instructions (root result)
  "Append Emacs context to the effective config in RESULT for ROOT.
Reject malformed config/read results instead of replacing unknown user
instructions.  Preserve the existing instruction string verbatim."
  (let* ((config (plist-get result :config))
         (existing (and (listp config)
                        (plist-get config :developer_instructions))))
    (unless (and (plist-member result :config) config (listp config)
                 (or (null existing) (stringp existing)))
      (error "Invalid config/read result"))
    (concat
     (when existing (concat existing "\n\n"))
     "This session is hosted by the user's Emacs; the conversation UI is an Emacs buffer.\n"
     "Unless the user explicitly refers to another application, references to the current page, window, editor, or input box mean Emacs; first discover and call the emacs MCP context tool.\n"
     "Use the emacs MCP tools to inspect and operate that UI."
     (when (file-remote-p root)
       (concat "\nThe agent shell runs on the project host; Emacs and its configuration are on the user's machine. "
               "Edit that configuration with config_read/config_edit/config_write, then reload.")))))

(defun agent-codex--fork-source (session)
  "The thread SESSION is to fork, or nil; once started it resumes its own."
  (and (not (agent-codex--state session :resume))
       (plist-get (agent-session-info session) :fork-from)))

(defun agent-codex--start-thread (session)
  "Read effective config, then start or resume SESSION.
A failed read leaves developerInstructions unset so Codex retains the
user's configured instructions; report that Emacs context was omitted.
A fork needs no config: it copies the instructions with the history."
  (if (agent-codex--fork-source session)
      (agent-codex--start-thread-with-instructions
       session (agent-session-process-directory (agent-session-root session)) nil)
    (agent-codex--read-config-and-start session)))

(defun agent-codex--read-config-and-start (session)
  "Read effective config, then start or resume SESSION."
  (let* ((cwd (agent-session-process-directory (agent-session-root session)))
         (read-failed
          (lambda (reason)
            (agent-session-notice
             session (format "读取 Codex 配置失败，未注入 Emacs 环境说明；保留原有指令：%s"
                             reason)
             'agent-session-error))))
    (agent-codex--request
     session "config/read" (list :cwd cwd)
     (lambda (result)
       (let ((instructions
              (condition-case err
                  (agent-codex--developer-instructions (agent-session-root session) result)
                (error (funcall read-failed (error-message-string err)) nil))))
         (agent-codex--start-thread-with-instructions session cwd instructions)))
     (lambda (err)
       (funcall read-failed (plist-get err :message))
       (agent-codex--start-thread-with-instructions session cwd nil)))))

(defun agent-codex--start-thread-with-instructions (session cwd instructions)
  "Start or resume SESSION at CWD with optional developer INSTRUCTIONS.
Codex ignores instruction overrides when resuming an already running
thread; sending this field does not guarantee updating such a thread."
  (pcase-let* ((`(,approval ,_ ,sandbox ,_) (agent-codex--mode session))
               (resume (agent-codex--state session :resume))
               (fork (agent-codex--fork-source session)))
    (agent-codex--request
     session (cond (resume "thread/resume") (fork "thread/fork") (t "thread/start"))
     (append (list :approvalPolicy approval :sandbox sandbox)
             ;; A fork takes its directory and instructions from the history
             ;; it copies; giving them again would change its prompt.
             (unless fork (list :cwd cwd))
             (when (and instructions (not fork)) (list :developerInstructions instructions))
             (when resume (list :threadId resume :excludeTurns t))
             ;; Only an ephemeral fork keeps the source's prompt cache.
             (when fork (list :threadId fork :excludeTurns t))
             ;; A session another agent started lives with its buffer.
             (when (agent-session-child-p session) (list :ephemeral t))
             (when-let* ((model (agent-session-setting session :model)))
               (list :model model)))
     (lambda (result)
       (let ((thread (plist-get (plist-get result :thread) :id)))
         (agent-codex--set session :thread thread)
         (agent-codex--set session :resume thread))
       (agent-session-set-info session :model (plist-get result :model))
       (if (and resume (zerop (hash-table-count (agent-session-blocks session))))
           (agent-codex--replay session)
         (agent-codex--thread-ready session)))
     (lambda (err)
       (agent-session-notice session (format "请求失败：%s" (plist-get err :message))
                             'agent-session-error)
       ;; Restarted for a message: don't leave it waiting, and try again
       ;; with the next one.
       (when (agent-codex--state session :pending-send)
         (agent-codex--set session :pending-send nil)
         (agent-codex--set session :tools nil)
         (agent-session-notice session "恢复 Codex 会话失败，这条消息没有发出；再发一次会重试"
                               'agent-session-error)
         (agent-session-set-status session 'idle))))))

(defun agent-codex--thread-ready (session)
  "Send the message SESSION was restarted for, if any, else go idle."
  (if-let* ((text (agent-codex--state session :pending-send)))
      (progn
        (agent-codex--set session :pending-send nil)
        (agent-codex--send-turn session text))
    (agent-session-set-status session 'idle)))

(defun agent-codex--replay (session)
  "Fetch and render the past turns of a resumed session, then go idle."
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

;;; Past session list: start a temporary app-server and call thread/list

(defun agent-codex--history-items (threads dirs)
  "Return history items for THREADS (from thread/list) run in DIRS.
DIRS is from `agent-session-worktree-dirs', its project root first.
Threads of another worktree carry :root and :worktree."
  (mapcar (lambda (thread)
            (append
             (list :id (plist-get thread :id)
                   :title (or (plist-get thread :name)
                              (car (split-string (string-trim (or (plist-get thread :preview) ""))
                                                 "\n"))
                              "（无标题）")
                   :time (plist-get thread :updatedAt))
             (when-let* ((dir (seq-find (lambda (dir)
                                          (equal (agent-codex--cwd (car dir))
                                                 (plist-get thread :cwd)))
                                        (cdr dirs))))
               (list :root (car dir) :worktree (cdr dir)))))
          threads))

(defun agent-codex--cwd (dir)
  "Return DIR the way Codex records a thread's cwd."
  (directory-file-name (agent-session-process-directory dir)))

(cl-defmethod agent-session-backend-history ((_ (eql codex)) root callback)
  (agent-session-worktrees
   root (lambda (dirs) (agent-codex--list-threads root dirs callback))))

(defun agent-codex--list-threads (root dirs callback)
  "Call CALLBACK with the threads of project ROOT run in DIRS.
The app-server runs where ROOT's threads are stored: on a remote
project's host."
  (let* ((pending "")
         (done nil)
         (default-directory root)
         (process
          (make-process
           :name "agent-codex-list"
           :command (list agent-codex-executable "app-server")
           :connection-type 'pipe :coding 'utf-8-unix :noquery t
           :file-handler (and (file-remote-p root) t)
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
                                  ;; The cwd filter takes several paths: one
                                  ;; request sorts and limits them together.
                                  (list :jsonrpc "2.0" :id 2 :method "thread/list"
                                        :params (list :cwd (vconcat (mapcar (lambda (dir)
                                                                              (agent-codex--cwd (car dir)))
                                                                            dirs))
                                                      :limit 50 :sortKey "updated_at"
                                                      :sortDirection "desc")))
                                 "\n")))
                     (2 (setq done t)
                        (delete-process process)
                        (funcall callback
                                 (agent-codex--history-items
                                  (plist-get (plist-get message :result) :data) dirs))))))))
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
  ;; Settings are sent with every turn/start and apply from the next message.
  (when (memq :model changed)
    (agent-session-set-info session :model (agent-session-setting session :model))))

(defun agent-codex--input (text &optional root)
  "Return the input items of user message TEXT: text and images (local files).
For a remote project ROOT codex runs on the host, so images are copied
there first."
  (let ((plain (agent-session-message-text text)))
    (vconcat (unless (string-empty-p plain) (list (list :type "text" :text plain)))
             (mapcar (lambda (file)
                       (list :type "localImage"
                             :path (if (and root (file-remote-p root))
                                       (agent-remote-upload root file)
                                     file)))
                     (agent-session-message-images text)))))

(cl-defmethod agent-session-backend-send ((_ (eql codex)) session text)
  (if (not (agent-codex--tools-stale-p session))
      (agent-codex--send-turn session text)
    ;; The thread resumes in a new process; the message goes once it has.
    (agent-session-notice session "Emacs 的工具有更新，重启 Codex 后继续")
    (agent-codex--set session :pending-send text)
    (agent-session-restart-process session)
    (agent-session-set-status session 'running)))

(defun agent-codex--send-turn (session text)
  "Start a turn of SESSION with user message TEXT."
  (agent-codex--request
   session "turn/start"
   (pcase-let ((`(,approval ,sandbox ,_ ,reviewer) (agent-codex--mode session)))
     (append
      (list :threadId (agent-codex--state session :thread)
            :input (agent-codex--input text (agent-session-root session))
            ;; Request reasoning summaries to get item/reasoning/summaryTextDelta.
            :summary "detailed"
            ;; Send approval settings explicitly every turn so a resumed
            ;; session doesn't keep stale values.
            :approvalPolicy approval
            :approvalsReviewer reviewer
            :sandboxPolicy (list :type sandbox))
      (when-let* ((model (agent-session-setting session :model))) (list :model model))
      (when-let* ((effort (agent-session-setting session :effort))) (list :effort effort))))
   (lambda (result)
     (agent-codex--set session :turn (plist-get (plist-get result :turn) :id)))))

(defun agent-codex--interrupt (session)
  "Interrupt the current turn of SESSION.
If the turn id isn't known yet, interrupt once turn/started arrives."
  (if-let* ((turn (agent-codex--state session :turn)))
      (agent-codex--request session "turn/interrupt"
                            (list :threadId (agent-codex--state session :thread) :turnId turn))
    (agent-codex--set session :interrupt-pending t)))

(cl-defmethod agent-session-backend-steer ((_ (eql codex)) session text)
  ;; turn/steer needs the current turn id; if it is unknown, return nil so
  ;; the caller falls back to interrupting and then sending.
  (when-let* ((turn (agent-codex--state session :turn)))
    (agent-codex--request session "turn/steer"
                          (list :threadId (agent-codex--state session :thread)
                                :expectedTurnId turn
                                :input (agent-codex--input text (agent-session-root session))))
    t))

(cl-defmethod agent-session-backend-interrupt ((_ (eql codex)) session)
  (agent-codex--interrupt session))

;;; Displaying items

(defun agent-codex--relative (session path)
  "Return PATH relative to the project root of SESSION."
  (if (and (stringp path) (file-name-absolute-p path))
      (file-relative-name path (agent-session-process-directory (agent-session-root session)))
    path))

(defun agent-codex--changes-diff (session changes)
  "Return a diff combining file CHANGES."
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
  "Return a short title for COMMAND.
Strip the bash -lc wrapper and keep only the first line."
  (let* ((command (or command ""))
         (inner (if (string-match "\\`\\(?:/bin/\\)?\\(?:ba\\|z\\)?sh -l?c '\\(\\(?:.\\|\n\\)*\\)'\\'" command)
                    (match-string 1 command)
                  command))
         (lines (split-string (string-trim inner) "\n")))
    (concat (car lines) (if (cdr lines) " …" ""))))

(defun agent-codex--item-view (session item)
  "Return the tool display properties of ITEM, or nil if it isn't a tool call."
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
  "Return the completion status of ITEM."
  (pcase (plist-get item :status)
    ((or "failed" "error") 'error)
    ("declined" 'declined)
    ((or "inProgress" "in_progress") 'running)
    (_ (if (and (plist-get item :exitCode) (/= (plist-get item :exitCode) 0)) 'error 'ok))))

(defun agent-codex--item-output (item)
  "Return the output text of ITEM."
  (pcase (plist-get item :type)
    ("commandExecution" (plist-get item :aggregatedOutput))
    ("mcpToolCall" (let ((result (plist-get item :result)) (err (plist-get item :error)))
                     (cond (err (format "%s" (or (plist-get err :message) err)))
                           (result (mapconcat (lambda (part) (or (plist-get part :text) ""))
                                              (plist-get result :content) "\n")))))
    ("plan" (plist-get item :text))))

(defun agent-codex--item-started (session item)
  "Handle the start of ITEM."
  (when-let* ((view (agent-codex--item-view session item)))
    (apply #'agent-session-tool session (plist-get item :id) :status 'running view)))

(defun agent-codex--item-completed (session item)
  "Handle the completion of ITEM."
  (let ((id (plist-get item :id)))
    (pcase (plist-get item :type)
      ("agentMessage" (agent-session-text-done session id (plist-get item :text)))
      ("reasoning" (agent-session-text-done session (concat id "-thinking")))
      ((pred (lambda (_) (agent-codex--item-view session item)))
       (apply #'agent-session-tool session id
              :status (agent-codex--item-status item)
              (append (when-let* ((output (agent-codex--item-output item))) (list :output output))
                      (agent-codex--item-view session item)))))))

;;; Approvals

(defun agent-codex--approval (session id method params)
  "Handle the server's approval request ID for METHOD with PARAMS."
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

;;; Questions (request_user_input)

(defun agent-codex--user-input (session id params)
  "Ask the user the questions of request_user_input request ID with PARAMS.
Answers go back keyed by question id; skipped questions, and all of them
when the user declines, are left out."
  (let ((questions
         (mapcar (lambda (question)
                   (list :id (plist-get question :id)
                         :question (plist-get question :question)
                         :header (plist-get question :header)
                         :options (mapcar (lambda (option)
                                            (cons (plist-get option :label)
                                                  (plist-get option :description)))
                                          (plist-get question :options))
                         :other (plist-get question :isOther)
                         :secret (plist-get question :isSecret)))
                 (plist-get params :questions))))
    (agent-session-ask-questions
     session
     :questions questions
     :tool (plist-get params :itemId)
     :callback
     (lambda (answers)
       (let ((table (make-hash-table :test #'equal)))
         (unless (eq answers 'cancel)
           (cl-mapc (lambda (question answer)
                      (when answer
                        (puthash (plist-get question :id)
                                 (list :answers
                                       (vconcat (plist-get answer :selected)
                                                (when-let* ((custom (plist-get answer :custom)))
                                                  (list custom))))
                                 table)))
                    questions answers))
         (agent-codex--respond session id (list :answers table)))))))

;;; Message handling

(defun agent-codex--foreign-thread-p (session params)
  "Non-nil if PARAMS of a notification name a thread other than SESSION's."
  (let ((thread (plist-get params :threadId))
        (own (agent-codex--state session :thread)))
    (and thread own (not (equal thread own)))))

(cl-defmethod agent-session-backend-handle ((_ (eql codex)) session message)
  (let ((id (plist-get message :id))
        (method (plist-get message :method))
        (params (plist-get message :params)))
    (cond
     ;; Responses to our requests
     ((and id (not method))
      (let* ((callbacks (agent-codex--state session :callbacks))
             (errors (agent-codex--state session :error-callbacks))
             (callback (and callbacks (gethash id callbacks)))
             (error-callback (and errors (gethash id errors))))
        (when callbacks (remhash id callbacks))
        (when errors (remhash id errors))
        (if-let* ((err (plist-get message :error)))
            (if error-callback
                (funcall error-callback err)
              (agent-session-notice session (format "请求失败：%s" (plist-get err :message))
                                    'agent-session-error))
          (when callback (funcall callback (plist-get message :result))))))
     ;; Server requests
     (id
      (cond
       ((member method '("item/commandExecution/requestApproval"
                         "item/fileChange/requestApproval"))
        (agent-codex--approval session id method params))
       ((equal method "item/tool/requestUserInput")
        (agent-codex--user-input session id params))
       (t
        (agent-session-write session (list :jsonrpc "2.0" :id id
                                           :error (list :code -32601
                                                        :message (format "Emacs 不支持 %s" method)))))))
     ;; Notifications of other threads on this connection, such as Codex's
     ;; own subagents, would end this session's turn and mix into its
     ;; transcript.
     ((agent-codex--foreign-thread-p session params))
     ;; Notifications
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

(cl-defmethod agent-session-backend-fork-p ((_ (eql codex)))
  t)

(agent-session-define-agent codex :title "Codex")

(provide 'agent-codex)
;;; agent-codex.el ends here
