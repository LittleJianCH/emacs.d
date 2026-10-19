;;; agent-dsh.el --- DeepSeek Harness backend (custom bridge plugin) -*- lexical-binding: t; -*-

;;; Commentary:

;; dsh has no headless protocol rich enough for an interactive UI (its SDK
;; protocol cannot cancel, approve or switch models), so we load our own
;; plugin, dsh/emacs-bridge.mjs, into the shipped `sdk' profile:
;;   dsh --profile sdk --patch dsh/emacs.yml
;; The plugin drives one dsh agent through its internal API and speaks
;; line-delimited JSON-RPC on stdio; the wire format is documented at the top
;; of emacs-bridge.mjs.
;;
;; The API key is dsh's own business (~/.dsh/.credentials.yaml); nothing here
;; passes credentials to the process.
;;
;; For a remote project dsh runs on the project's host, like the other
;; backends: the plugin files are copied to the host first, and emx is reached
;; through agent-remote.el's relay.  The host needs dsh, python3 and its own
;; dsh credentials.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)
(require 'agent-remote)

(defgroup agent-dsh nil
  "DeepSeek Harness backend."
  :group 'agent-session
  :prefix "agent-dsh-")

(defcustom agent-dsh-executable "dsh"
  "The dsh command."
  :type 'string)

(defconst agent-dsh--patch
  (expand-file-name "dsh/emacs.yml" (file-name-directory (or load-file-name buffer-file-name)))
  "Profile patch that mounts the Emacs bridge plugin.")

(defconst agent-dsh--presets
  '((ask . "read-only")
    (edits . "workspace-write")
    (auto . "auto")
    (full . "danger-full-access"))
  "Unified permission modes mapped to dsh permission presets.
`auto' comes from dsh's experimental auto-review plugin, which emacs.yml loads.")

(defun agent-dsh--preset (session)
  "The dsh permission preset for the current mode of SESSION.
Plan mode is separate in dsh; it keeps the preset of the mode before it."
  (let ((mode (agent-session-setting session :mode)))
    (alist-get (if (eq mode 'plan)
                   (or (plist-get (agent-session-settings session) :before-plan)
                       agent-session-default-mode)
                 mode)
               agent-dsh--presets "workspace-write")))

(defconst agent-dsh-tested-version "0.2.0-rc.2"
  "The dsh version the bridge plugin was written against.
The plugin uses dsh internals, so other versions may need changes.")

(defun agent-dsh--plugin-files ()
  "The local plugin files, the patch last."
  (list (expand-file-name "emacs-bridge.mjs" (file-name-directory agent-dsh--patch))
        agent-dsh--patch))

(defun agent-dsh--remote-plugin-dir (root files)
  "Directory on the host of remote ROOT that holds FILES.
Named after their contents, so a changed plugin gets a fresh copy and
an unchanged one is reused."
  (concat (file-remote-p root) "~/.cache/emacs-agent/dsh/"
          (substring (secure-hash 'sha256 (mapconcat (lambda (file)
                                                       (with-temp-buffer
                                                         (insert-file-contents-literally file)
                                                         (buffer-string)))
                                                     files ""))
                     0 16)
          "/"))

(defun agent-dsh--patch-file (root)
  "The patch file as the bridge process of project ROOT sees it.
A remote host gets a copy of the plugin files next to each other (the
patch names the plugin relative to itself).  The patch is copied last,
so its presence marks a complete upload."
  (if (not (file-remote-p root))
      agent-dsh--patch
    (let* ((files (agent-dsh--plugin-files))
           (dir (agent-dsh--remote-plugin-dir root files))
           (patch (expand-file-name (file-name-nondirectory agent-dsh--patch) dir)))
      (unless (file-exists-p patch)
        (make-directory dir t)
        (dolist (file files)
          (copy-file file (expand-file-name (file-name-nondirectory file) dir) t)))
      (file-local-name patch))))

(defun agent-dsh--command (root)
  "Command line that starts the bridge for project ROOT."
  (list agent-dsh-executable "--profile" "sdk" "--patch" (agent-dsh--patch-file root)))

(defun agent-dsh--mcp-servers (session)
  "MCP servers mounted for the agent of SESSION: the emx bridge back to Emacs.
A remote agent reaches emx through the relay of agent-remote.el."
  (let ((emx (if (file-remote-p (agent-session-root session))
                 (agent-remote-mcp-command session)
               (agent-session-emx-command))))
    (vector
     (append
      (list :name "emacs" :command (car emx) :args (vconcat (cdr emx))
            ;; session_ask waits for another agent; the default is 60 seconds.
            :timeoutMs 1800000)
      ;; dsh scrubs secrets from the environment it passes MCP servers; give
      ;; emx its variables explicitly.  The relay needs none.
      (unless (file-remote-p (agent-session-root session))
        (list :env (let ((env (make-hash-table :test #'equal)))
                     (dolist (name '("PATH" "EMACS_SOCKET_NAME" "EMX_AGENT_BUFFER") env)
                       (when-let* ((entry (seq-find (lambda (e) (string-prefix-p (concat name "=") e))
                                                    (agent-session-environment session))))
                         (puthash name (substring entry (1+ (length name))) env))))))))))

;;; JSON-RPC

(defun agent-dsh--state (session key)
  "Read backend state KEY of SESSION."
  (plist-get (agent-session-state session) key))

(defun agent-dsh--set (session key value)
  "Set backend state KEY of SESSION to VALUE."
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-dsh--request (session method params &optional callback)
  "Send a JSON-RPC request; call CALLBACK with the result when it arrives."
  (let ((id (1+ (or (agent-dsh--state session :next-id) 0))))
    (agent-dsh--set session :next-id id)
    (when callback
      (unless (agent-dsh--state session :callbacks)
        (agent-dsh--set session :callbacks (make-hash-table)))
      (puthash id callback (agent-dsh--state session :callbacks)))
    (agent-session-write session (list :jsonrpc "2.0" :id id :method method
                                       :params (or params (make-hash-table))))))

(defun agent-dsh--respond (session id result)
  "Answer the bridge's request ID with RESULT."
  (agent-session-write session (list :jsonrpc "2.0" :id id :result result)))

;;; Backend interface

(cl-defmethod agent-session-backend-start ((_ (eql dsh)) session)
  (agent-dsh--set session :ready nil)
  (agent-session-start-process session (agent-dsh--command (agent-session-root session)))
  (agent-dsh--request
   session "initialize"
   (append (list :cwd (directory-file-name (agent-session-process-directory
                                            (agent-session-root session)))
                 :preset (agent-dsh--preset session)
                 :plan (if (eq (agent-session-setting session :mode) 'plan) t :false)
                 :mcpServers (agent-dsh--mcp-servers session))
           (when-let* ((resume (agent-dsh--state session :resume))) (list :resume resume))
           (when-let* ((model (agent-session-setting session :model))) (list :model model))
           (when-let* ((effort (agent-session-setting session :effort))) (list :effort effort)))
   (lambda (result)
     (agent-dsh--set session :ready t)
     (agent-dsh--set session :resume (plist-get result :sessionId))
     (agent-dsh--set session :models (plist-get result :models))
     (agent-dsh--set session :presets (append (plist-get result :presets) nil))
     (agent-dsh--set session :plan (plist-get result :plan))
     (agent-dsh--set session :commands (plist-get result :commands))
     (agent-dsh--apply-config session (plist-get result :config))
     (when-let* ((title (plist-get result :title)))
       (unless (plist-get (agent-session-info session) :title)
         (agent-session-set-info session :title (agent-session--title-seed title))))
     ;; A restarted process resumes a session that is already on screen.
     (when (and (length> (plist-get result :history) 0)
                (zerop (hash-table-count (agent-session-blocks session))))
       (seq-doseq (item (plist-get result :history))
         (agent-dsh--notification session (plist-get item :method) (plist-get item :params)))
       (agent-session-notice session "—— 以上为历史记录 ——"))
     (seq-doseq (warning (plist-get result :warnings))
       (agent-session-notice session (format "dsh：%s" warning) 'agent-session-error))
     (let ((version (plist-get result :version)))
       (unless (member version (list nil agent-dsh-tested-version))
         (agent-session-notice
          session (format "dsh 版本为 %s，桥接插件按 %s 编写，若有异常可能需要适配"
                          version agent-dsh-tested-version))))
     (agent-session-set-status session 'idle))))

;;; Past sessions: a short-lived bridge answers sessions/list

(defun agent-dsh--host-dir (dir)
  "Directory DIR as the bridge sees it, without a trailing slash."
  (directory-file-name (agent-session-process-directory dir)))

(defun agent-dsh--history-items (sessions dirs)
  "History items for SESSIONS (from sessions/list) run in DIRS.
DIRS is from `agent-session-worktree-dirs', its project root first.
Sessions of another worktree carry :root and :worktree."
  (mapcar (lambda (item)
            (append
             (list :id (plist-get item :id)
                   :title (car (split-string (string-trim (plist-get item :title)) "\n"))
                   :time (plist-get item :time))
             (when-let* ((dir (seq-find (lambda (dir)
                                          (equal (agent-dsh--host-dir (car dir))
                                                 (plist-get item :cwd)))
                                        (cdr dirs))))
               (list :root (car dir) :worktree (cdr dir)))))
          sessions))

(defun agent-dsh--list-sessions (root dirs callback)
  "Call CALLBACK with the history items of the sessions run in DIRS of ROOT."
  (let* ((pending "")
         (done nil)
         (default-directory root)
         (process
          (make-process
           :name "agent-dsh-list"
           :command (agent-dsh--command root)
           :connection-type 'pipe :coding 'utf-8-unix :noquery t
           ;; A remote project's sessions are stored on its host.
           :file-handler (and (file-remote-p root) t)
           :stderr (get-buffer-create " *agent-dsh-list stderr*")
           :filter
           (lambda (process output)
             (setq pending (concat pending output))
             (let ((lines (split-string pending "\n")))
               (setq pending (car (last lines)))
               (dolist (line (butlast lines))
                 (when-let* ((message (ignore-errors
                                        (json-parse-string line :object-type 'plist
                                                           :null-object nil :false-object nil)))
                             ((equal (plist-get message :id) 1)))
                   (setq done t)
                   (delete-process process)
                   (funcall callback
                            (agent-dsh--history-items
                             (plist-get (plist-get message :result) :sessions) dirs))))))
           :sentinel (lambda (_process _event)
                       (unless done (setq done t) (funcall callback nil))))))
    (process-send-string
     process (concat (json-serialize
                      (list :jsonrpc "2.0" :id 1 :method "sessions/list"
                            :params (list :cwds (vconcat (mapcar (lambda (dir)
                                                                   (agent-dsh--host-dir (car dir)))
                                                                 dirs)))))
                     "\n"))))

(cl-defmethod agent-session-backend-history ((_ (eql dsh)) root callback)
  (agent-session-worktrees
   root (lambda (dirs) (agent-dsh--list-sessions root dirs callback))))

(defun agent-dsh--apply-config (session config)
  "Follow CONFIG, the settings the bridge reports, in SESSION."
  (agent-session-set-info session :model (plist-get config :model))
  ;; An approved plan review leaves plan mode on the dsh side.
  (when (and (not (plist-get config :plan))
             (eq (agent-session-setting session :mode) 'plan)
             (not (agent-dsh--state session :configuring)))
    (agent-session-configure session :mode (or (plist-get (agent-session-settings session)
                                                          :before-plan)
                                               agent-session-default-mode))))

(cl-defmethod agent-session-backend-models ((_ (eql dsh)) session)
  (mapcar (lambda (model)
            (list :id (plist-get model :id)
                  :name (plist-get model :name)
                  :description (plist-get model :description)
                  :efforts (mapcar (lambda (e) (plist-get e :id)) (plist-get model :efforts))
                  :default-effort (plist-get model :defaultEffort)))
          (agent-dsh--state session :models)))

(cl-defmethod agent-session-backend-modes ((_ (eql dsh)) session)
  ;; Before the bridge reports its presets, offer every mode.
  (let ((presets (agent-dsh--state session :presets)))
    (append (seq-keep (pcase-lambda (`(,mode . ,preset))
                        (and (or (null presets) (member preset presets)) mode))
                      agent-dsh--presets)
            (when (agent-dsh--state session :plan) '(plan)))))

(cl-defmethod agent-session-backend-apply-settings ((_ (eql dsh)) session changed)
  ;; Before initialize the settings travel with it instead.
  (when (and (agent-dsh--state session :ready)
             (seq-intersection changed '(:model :effort :mode)))
    ;; Until the reply arrives, a reported plan state may predate this change.
    (agent-dsh--set session :configuring (1+ (or (agent-dsh--state session :configuring) 0)))
    (agent-dsh--request
     session "configure"
     (append (when (or (memq :model changed) (memq :effort changed))
               ;; Both together: nil selects the agent's default.
               (list :model (or (agent-session-setting session :model) :null)
                     :effort (or (agent-session-setting session :effort) :null)))
             (when (memq :mode changed)
               (list :preset (agent-dsh--preset session)
                     :plan (if (eq (agent-session-setting session :mode) 'plan) t :false))))
     (lambda (result)
       (let ((pending (1- (agent-dsh--state session :configuring))))
         (agent-dsh--set session :configuring (and (> pending 0) pending)))
       (agent-dsh--apply-config session (plist-get result :config))))))

(cl-defmethod agent-session-backend-commands ((_ (eql dsh)) session)
  (mapcar (lambda (command)
            (list :name (plist-get command :name)
                  :description (plist-get command :description)
                  :hint (plist-get command :hint)))
          (agent-dsh--state session :commands)))

(defun agent-dsh--message (text root)
  "Prompt parameters for user message TEXT: its text and image files.
For a remote project ROOT the bridge runs on the host, so images are
copied there first."
  (list :text (agent-session-message-text text)
        :images (vconcat (mapcar (lambda (file)
                                   (if (file-remote-p root) (agent-remote-upload root file) file))
                                 (agent-session-message-images text)))))

(cl-defmethod agent-session-backend-send ((_ (eql dsh)) session text)
  (agent-dsh--request
   session "prompt" (agent-dsh--message text (agent-session-root session))
   (lambda (result)
     ;; A dsh slash command runs without a turn; show its result.
     (when-let* ((command (plist-get result :command)))
       (let ((output (plist-get command :text)))
         (if (equal (plist-get command :kind) "error")
             (agent-session-notice session (format "命令失败：%s" output) 'agent-session-error)
           (agent-session-notice session (or output "命令已执行"))))
       (when (equal (plist-get result :status) "idle")
         (agent-session-set-status session 'idle))))))

(cl-defmethod agent-session-backend-steer ((_ (eql dsh)) session text)
  ;; dsh takes steering at the next step boundary of the running turn.
  (agent-dsh--request session "steer" (agent-dsh--message text (agent-session-root session)))
  t)

(cl-defmethod agent-session-backend-interrupt ((_ (eql dsh)) session)
  (agent-dsh--request session "cancel" nil))

;;; Tool display

(defun agent-dsh--arguments (arguments)
  "Parse the tool call ARGUMENTS JSON string into a plist."
  (and (stringp arguments)
       (ignore-errors (json-parse-string arguments :object-type 'plist
                                         :null-object nil :false-object nil))))

(defun agent-dsh--relative (session path)
  "PATH, as the agent reports it, relative to the project root of SESSION."
  (if (and (stringp path) (file-name-absolute-p path))
      (file-relative-name path (agent-session-process-directory (agent-session-root session)))
    path))

(defun agent-dsh--diff (path old new)
  "A simple diff for PATH from the text before (OLD) and after (NEW)."
  (cl-flet ((lines (prefix text)
              (when (and text (not (string-empty-p text)))
                (mapconcat (lambda (line) (concat prefix line))
                           (split-string (string-remove-suffix "\n" text) "\n")
                           "\n"))))
    (string-join (delq nil (list (concat "--- " path "\n+++ " path)
                                 (lines "-" old)
                                 (lines "+" new)))
                 "\n")))

(defun agent-dsh--tool-view (session name arguments)
  "Display properties of tool NAME called with ARGUMENTS (a plist)."
  (let ((path (agent-dsh--relative session (or (plist-get arguments :file_path)
                                               (plist-get arguments :path)))))
    (pcase name
      ("bash" (list :kind 'command
                    :title (car (split-string (string-trim (or (plist-get arguments :command) ""))
                                              "\n"))))
      ((or "read" "read_image") (list :kind 'read :title path))
      ("write" (list :kind 'edit :title path
                     :diff (agent-dsh--diff path nil (plist-get arguments :content))))
      ("edit" (list :kind 'edit :title path
                    :diff (agent-dsh--diff path (plist-get arguments :old_string)
                                           (plist-get arguments :new_string))))
      ((or "grep" "glob")
       (list :kind 'search :title (format "%s %s" name (or (plist-get arguments :pattern) ""))))
      ("web_fetch" (list :kind 'web :title (plist-get arguments :url)))
      ("web_search" (list :kind 'web
                          :title (mapconcat #'identity (plist-get arguments :queries) " · ")))
      ((or "subagent" "subagent_fork")
       (list :kind 'task :title (or (plist-get arguments :description) name)))
      ("todo_write"
       (list :kind 'plan :title "更新计划"
             :output (mapconcat (lambda (todo)
                                  (format "%s %s"
                                          (pcase (plist-get todo :status)
                                            ("completed" "☑") ("in_progress" "▶") (_ "☐"))
                                          (plist-get todo :content)))
                                (plist-get arguments :todos) "\n")))
      ("exit_plan_mode" (list :kind 'plan :title "提交计划" :output (plist-get arguments :plan)))
      ("skill" (list :kind 'other :title (format "技能 %s" (plist-get arguments :name))))
      ((pred (string-prefix-p "mcp__"))
       (list :kind 'mcp :title (string-join (cdr (split-string name "__")) " · ")))
      (_ (list :kind 'other :title (or path name))))))

;; Results that would only repeat what the call already shows (the plan, the
;; diff); failures are still shown.
(defconst agent-dsh--quiet-results '("todo_write" "exit_plan_mode" "write" "edit")
  "Tools whose successful result text is not shown.")

;;; Approvals

(defun agent-dsh--approval (session id params)
  "Ask the user about the bridge's approval request ID with PARAMS."
  (let* ((tool-id (plist-get params :callId))
         (tool (and tool-id (agent-session--block session tool-id))))
    (agent-session-ask
     session
     :title (format "%s%s" (or (plist-get tool :title) (plist-get params :toolName))
                    (if-let* ((reason (plist-get params :reason))) (format "（%s）" reason) ""))
     :choices '((allow "允许") (reject "拒绝"))
     :tool tool-id
     :callback (lambda (choice)
                 (agent-dsh--respond session id (list :decision (symbol-name choice)))))))

;;; Questions, and the plan review when the agent leaves plan mode

(defun agent-dsh--plan-review-p (question)
  "Whether QUESTION is dsh's review of a plan."
  (equal (plist-get (plist-get question :intent) :kind) "plan-review"))

(defun agent-dsh--plan-review (session id question tool)
  "Ask the user to approve the plan of QUESTION in request ID.
TOOL is the id of the related tool block.
Declining it can carry feedback for the next revision; the last option is
what `agent-session-deny' picks."
  (let* ((options (append (plist-get question :options) nil))
         (approve (plist-get (plist-get question :intent) :approve)))
    (agent-session-ask
     session
     :title "批准这个计划并开始执行？"
     :tool tool
     :choices (seq-map-indexed (lambda (option index) (list index (plist-get option :label)))
                               options)
     :callback
     (lambda (index)
       (let ((label (plist-get (nth index options) :label)))
         (agent-dsh--respond
          session id
          (list :answers
                (vector
                 (append
                  (list :id (plist-get question :id) :selected (vector label))
                  (unless (equal label approve)
                    (let ((feedback (string-trim (read-string "修改意见（可留空）："))))
                      (unless (string-empty-p feedback) (list :custom feedback)))))))))))))

(defun agent-dsh--question (session id params)
  "Ask the user the bridge's questions in request ID with PARAMS."
  (let ((questions (append (plist-get params :questions) nil)))
    (if-let* ((review (seq-find #'agent-dsh--plan-review-p questions)))
        (agent-dsh--plan-review session id review (plist-get params :callId))
      (agent-session-ask-questions
       session
       :questions (mapcar (lambda (question)
                            (list :question (plist-get question :question)
                                  :header (plist-get question :header)
                                  :detail (plist-get question :detail)
                                  :options (mapcar (lambda (option)
                                                     (cons (plist-get option :label)
                                                           (plist-get option :description)))
                                                   (plist-get question :options))
                                  :multi (plist-get question :multiSelect)
                                  :other t))
                          questions)
       :tool (plist-get params :callId)
       :callback
       (lambda (answers)
         (agent-dsh--respond
          session id
          (list :answers
                (vconcat
                 (cl-mapcar (lambda (question answer)
                              (append (list :id (plist-get question :id)
                                            :selected (vconcat (plist-get answer :selected)))
                                      (when-let* ((custom (plist-get answer :custom)))
                                        (list :custom custom))))
                            questions
                            (if (eq answers 'cancel) (make-list (length questions) nil) answers))))))))))

;;; Message handling

(defun agent-dsh--notification (session method params)
  "Handle notification METHOD with PARAMS (also used to replay history)."
  (pcase method
    ("status"
     (agent-session-set-status session (if (equal (plist-get params :status) "running")
                                           'running 'idle)))
    ("user"
     (agent-session--new-block
      session (plist-get params :id)
      (list :type 'user
            :text (string-join (append (make-list (or (plist-get params :images) 0) "[图片]")
                                       (list (plist-get params :text)))
                               " "))))
    ("text"
     (agent-session-text session (plist-get params :id) (plist-get params :delta)
                         (if (equal (plist-get params :kind) "thinking") 'thinking 'assistant)))
    ("text/done"
     (let ((id (plist-get params :id)))
       ;; Replayed thinking has no streamed block yet to carry its kind.
       (when (and (equal (plist-get params :kind) "thinking")
                  (not (agent-session--block session id)))
         (agent-session-text session id (plist-get params :text) 'thinking))
       (agent-session-text-done session id (plist-get params :text))))
    ("discard"
     (seq-doseq (block (plist-get params :ids))
       (agent-session--remove-block session block)))
    ("tool"
     (apply #'agent-session-tool session (plist-get params :id) :status 'running
            ;; The tool name is kept on the block to interpret its result.
            :dsh-tool (plist-get params :name)
            (agent-dsh--tool-view session (plist-get params :name)
                                  (agent-dsh--arguments (plist-get params :arguments)))))
    ("tool/done"
     (let* ((id (plist-get params :id))
            (quiet (member (plist-get (agent-session--block session id) :dsh-tool)
                           agent-dsh--quiet-results)))
       (when (agent-session--block session id)
         (apply #'agent-session-tool session id
                :status (if (plist-get params :isError) 'error 'ok)
                (unless (and quiet (not (plist-get params :isError)))
                  (list :output (plist-get params :output)))))))
    ;; Failed turns are already reported through "error".
    ("turn/end"
     (when (equal (plist-get params :reason) "max-tokens")
       (agent-session-notice session "输出达到 token 上限" 'agent-session-error)))
    ("config" (agent-dsh--apply-config session (plist-get params :config)))
    ("usage"
     (agent-session-set-info session :tokens
                             (plist-get (plist-get params :usage) :totalTokens)))
    ("error"
     (agent-session-notice session (format "出错：%s" (plist-get params :message))
                           'agent-session-error))))

(cl-defmethod agent-session-backend-handle ((_ (eql dsh)) session message)
  (let ((id (plist-get message :id))
        (method (plist-get message :method))
        (params (plist-get message :params)))
    (cond
     ;; Response to one of our requests
     ((and id (not method))
      (if-let* ((err (plist-get message :error)))
          (agent-session-notice session (format "请求失败：%s" (plist-get err :message))
                                'agent-session-error)
        (when-let* ((callbacks (agent-dsh--state session :callbacks))
                    (callback (gethash id callbacks)))
          (remhash id callbacks)
          (funcall callback (plist-get message :result)))))
     ;; Request from the bridge
     (id
      (pcase method
        ("approval" (agent-dsh--approval session id params))
        ("question" (agent-dsh--question session id params))
        (_ (agent-session-write session (list :jsonrpc "2.0" :id id
                                           :error (list :code -32601
                                                        :message (format "unsupported: %s" method)))))))
     ;; Notification
     (t (agent-dsh--notification session method params)))))

(agent-session-define-agent dsh :title "DeepSeek")

(provide 'agent-dsh)
;;; agent-dsh.el ends here
