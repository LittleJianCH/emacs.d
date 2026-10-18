;;; agent-opencode.el --- opencode backend (its own server API) -*- lexical-binding: t; -*-

;;; Commentary:

;; opencode's real interface is the API of `opencode serve': JSON over HTTP
;; plus an SSE event stream, the one its TUI, desktop app and web client use.
;; Each Emacs session gets a private server (ephemeral port, own password,
;; never the user's background service) started by opencode/emacs-bridge.mjs,
;; a Node program with no dependencies that speaks line-delimited JSON-RPC on
;; stdio; the wire format is documented at the top of that file.
;;
;; The server is configured for this session only, through
;; OPENCODE_CONFIG_CONTENT (an extra configuration source, merged over the
;; user's own files; nothing is written to disk): the emx MCP server and the
;; skills Emacs provides.  Credentials stay opencode's own business
;; (~/.config/opencode).
;;
;; Permission modes map to session rule sets: opencode matches the last
;; matching rule, so a mode appends its own rules and then denies the skills
;; Emacs replaces.  Plan mode is opencode's own `plan' agent, which cannot
;; edit files; its rules are the ones of the mode before it.
;; A model travels as "providerID/modelID" and its variant (the reasoning
;; effort) as the effort setting.
;;
;; For a remote project the bridge runs on the host, like the other backends:
;; the host needs node and opencode, and emx is reached through the relay of
;; agent-remote.el.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)
(require 'agent-remote)

(defgroup agent-opencode nil
  "opencode backend."
  :group 'agent-session
  :prefix "agent-opencode-")

(defcustom agent-opencode-executable "opencode"
  "The opencode command (on the project's host)."
  :type 'string)

(defcustom agent-opencode-node "node"
  "Node command used to run the bridge (on the project's host)."
  :type 'string)

(defconst agent-opencode-tested-version "2.0.32"
  "The opencode version the bridge was written against.
The bridge speaks opencode's own API, which changes between releases.")

(defconst agent-opencode--bridge
  (expand-file-name "opencode/emacs-bridge.mjs"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "The bridge program, loaded into opencode's own API.")

;;; The bridge process

(defun agent-opencode--bridge-file (root)
  "The bridge file as the process of project ROOT sees it.
A remote host gets a copy next to nothing else; it is named after its
contents, so a changed bridge gets a fresh copy and an unchanged one is
reused."
  (if (not (file-remote-p root))
      agent-opencode--bridge
    (let* ((hash (substring (secure-hash 'sha256 (with-temp-buffer
                                                  (insert-file-contents-literally
                                                   agent-opencode--bridge)
                                                  (buffer-string)))
                            0 16))
           (dir (concat (file-remote-p root) "~/.cache/emacs-agent/opencode/" hash "/"))
           (file (expand-file-name "emacs-bridge.mjs" dir)))
      (unless (file-exists-p file)
        (make-directory dir t)
        (copy-file agent-opencode--bridge file t))
      (file-local-name file))))

(defun agent-opencode--command (root)
  "Command line that starts the bridge for project ROOT."
  (list agent-opencode-node (agent-opencode--bridge-file root)
        "--opencode" agent-opencode-executable))

;;; Configuration of the private server

(defun agent-opencode--environment (session)
  "Environment for emx: PATH, EMACS_SOCKET_NAME, EMX_AGENT_BUFFER."
  (let ((env (make-hash-table :test #'equal)))
    (dolist (name '("PATH" "EMACS_SOCKET_NAME" "EMX_AGENT_BUFFER") env)
      (when-let* ((entry (seq-find (lambda (e) (string-prefix-p (concat name "=") e))
                                   (agent-session-environment session))))
        (puthash name (substring entry (1+ (length name))) env)))))

(defun agent-opencode--emx (session)
  "The emx MCP server as opencode's configuration wants it.
A remote agent reaches emx through the relay of agent-remote.el."
  (let ((remote (file-remote-p (agent-session-root session))))
    (append
     (list :type "local"
           :command (vconcat (if remote
                                 (agent-remote-mcp-command session)
                               (agent-session-emx-command)))
           ;; The worktree tools and the review workflow are called directly,
           ;; like in the other backends, instead of through Code Mode's
           ;; JavaScript sandbox.
           :codemode :false
           ;; session_ask waits for another agent; opencode's default is short.
           :timeout (list :execution 1800000))
     ;; The relay needs no variables, and the local ones (the Emacs socket)
     ;; mean nothing on the host.
     (unless remote
       (list :environment (agent-opencode--environment session))))))

(defun agent-opencode--config (session)
  "Extra configuration document for the private server of SESSION.
An extra source merged over the user's own configuration files, so
opencode run from a terminal is unaffected."
  (let ((skills (agent-session-skills-dir session)))
    (append
     ;; opencode discovers <dir>/<skill>/SKILL.md, and merges these with the
     ;; skills it finds by itself.
     (when skills (list :skills (vector (concat skills ".claude/skills"))))
     (list :mcp (list :servers (list :emacs (agent-opencode--emx session)))))))

;;; Permission modes and opencode agents

(defconst agent-opencode--policies
  '((ask
     (:action "*" :resource "*" :effect "allow")
     (:action "shell" :resource "*" :effect "ask")
     (:action "edit" :resource "*" :effect "ask")
     (:action "external_directory" :resource "*" :effect "ask"))
    (edits
     (:action "*" :resource "*" :effect "allow")
     (:action "shell" :resource "*" :effect "ask")
     (:action "external_directory" :resource "*" :effect "ask"))
    (auto
     (:action "*" :resource "*" :effect "allow")
     (:action "external_directory" :resource "*" :effect "ask"))
    (full
     (:action "*" :resource "*" :effect "allow")))
  "Session rules per mode; opencode matches the last matching rule.
opencode has no reviewer of its own: `auto' is its own permissive policy
plus a confirmation before reaching outside the project, and `full' adds
nothing.  opencode itself still asks before reading .env files.")

(defun agent-opencode--permissions (session)
  "Permission ruleset for the current mode of SESSION.
Rules are ordered, the last match wins: the mode's rules first, then the
skills Emacs replaces, which the agent must not use."
  (let ((mode (agent-session-setting session :mode)))
    (when (eq mode 'plan)
      (setq mode (or (plist-get (agent-session-settings session) :before-plan)
                     agent-session-default-mode)))
    (append (alist-get mode agent-opencode--policies)
            (mapcar (lambda (name) (list :action "skill" :resource name :effect "deny"))
                    (agent-session-superseded-skills)))))

(defun agent-opencode--agent (session)
  "The opencode agent of the current mode of SESSION.
Plan mode uses opencode's own planning agent, which cannot edit files."
  (if (eq (agent-session-setting session :mode) 'plan) "plan" "build"))

(defun agent-opencode--model-string (session)
  "Current model of SESSION as \"providerID/modelID\"."
  (or (agent-session-setting session :model)
      (agent-opencode--state session :model)))

;;; JSON-RPC

(defun agent-opencode--state (session key)
  "Read backend state KEY of SESSION."
  (plist-get (agent-session-state session) key))

(defun agent-opencode--set (session key value)
  "Set backend state KEY of SESSION to VALUE."
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-opencode--request (session method params &optional callback)
  "Send a JSON-RPC request; call CALLBACK with the result when it arrives."
  (let ((id (1+ (or (agent-opencode--state session :next-id) 0))))
    (agent-opencode--set session :next-id id)
    (when callback
      (unless (agent-opencode--state session :callbacks)
        (agent-opencode--set session :callbacks (make-hash-table)))
      (puthash id callback (agent-opencode--state session :callbacks)))
    (agent-session-write session (list :jsonrpc "2.0" :id id :method method
                                       :params (or params (make-hash-table))))))

(defun agent-opencode--respond (session id result)
  "Answer the bridge's request ID with RESULT."
  (agent-session-write session (list :jsonrpc "2.0" :id id :result result)))

;;; Backend interface

(defun agent-opencode--apply-config (session params)
  "Follow the settings PARAMS the bridge reports in SESSION.
The model and its variant can change elsewhere: the TUI, the desktop app,
or the server's own choice at the start of a turn.  Plan mode is ours,
but opencode can leave it on its own side as well."
  (when-let* ((model (plist-get params :model)))
    (unless (equal model (agent-session-setting session :model))
      (agent-session-configure session :model model :effort (plist-get params :variant))))
  (when-let* ((agent (plist-get params :agent)))
    (let ((plan (equal agent "plan"))
          (mode (agent-session-setting session :mode)))
      (cond ((and plan (not (eq mode 'plan)))
             (agent-session-configure session :before-plan mode :mode 'plan))
            ((and (not plan) (eq mode 'plan))
             (agent-session-configure
              session :mode (or (plist-get (agent-session-settings session) :before-plan)
                                agent-session-default-mode)))))))

(cl-defmethod agent-session-backend-start ((_ (eql opencode)) session)
  (agent-opencode--set session :ready nil)
  (agent-session-start-process session (agent-opencode--command (agent-session-root session)))
  (agent-opencode--request
   session "initialize"
   (append
    (list :cwd (directory-file-name (agent-session-process-directory
                                     (agent-session-root session)))
          :config (agent-opencode--config session)
          :agent (agent-opencode--agent session)
          :permissions (vconcat (agent-opencode--permissions session)))
    (when-let* ((resume (agent-opencode--state session :resume))) (list :resume resume))
    (when-let* ((model (agent-session-setting session :model)))
      (list :model model :variant (or (agent-session-setting session :effort) :null))))
   (lambda (result)
     (agent-opencode--set session :ready t)
     (agent-opencode--set session :resume (plist-get result :sessionId))
     (agent-opencode--set session :model (plist-get result :model))
     (agent-opencode--set session :models (append (plist-get result :models) nil))
     (agent-opencode--set session :commands (append (plist-get result :commands) nil))
     ;; A first session runs the model opencode picks; adopt it, so the mode
     ;; line and the menu say what is really running.
     (when-let* ((model (plist-get result :model))
                 ((null (agent-session-setting session :model))))
       (agent-session-configure session :model model :effort (plist-get result :variant)))
     (when-let* ((title (plist-get result :title)))
       (unless (plist-get (agent-session-info session) :title)
         (agent-session-set-info session :title (agent-session--title-seed title))))
     ;; A restarted process resumes a session that is already on screen.
     (when (and (length> (plist-get result :history) 0)
                (zerop (hash-table-count (agent-session-blocks session))))
       (seq-doseq (item (plist-get result :history))
         (agent-opencode--notification session (plist-get item :method)
                                       (plist-get item :params)))
       (agent-session-notice session "—— 以上为历史记录 ——"))
     (seq-doseq (warning (plist-get result :warnings))
       (agent-session-notice session (format "opencode：%s" warning) 'agent-session-error))
     (let ((version (plist-get result :version)))
       (unless (member version (list nil agent-opencode-tested-version))
         (agent-session-notice
          session
          (format "opencode 版本为 %s，桥接按 %s 编写，若有异常可能需要适配"
                  version agent-opencode-tested-version))))
     (agent-session-set-status session 'idle))))

(cl-defmethod agent-session-backend-models ((_ (eql opencode)) session)
  (mapcar (lambda (model)
            (list :id (plist-get model :id)
                  :name (plist-get model :name)
                  :description (plist-get model :description)
                  :efforts (append (plist-get model :efforts) nil)
                  :default-effort (plist-get model :defaultEffort)))
          (agent-opencode--state session :models)))

(cl-defmethod agent-session-backend-modes ((_ (eql opencode)) _session)
  '(ask edits auto full plan))

(cl-defmethod agent-session-backend-commands ((_ (eql opencode)) session)
  (append
   (mapcar (lambda (command)
             (list :name (plist-get command :name)
                   :description (plist-get command :description)))
           (agent-opencode--state session :commands))
   ;; opencode's own /compact has no API listing; it is still useful here.
   (list (list :name "compact" :description "压缩上下文"))))

(cl-defmethod agent-session-backend-apply-settings ((_ (eql opencode)) session changed)
  ;; Before initialize the settings travel with it instead.
  (when (agent-opencode--state session :ready)
    (let (params)
      (when (seq-intersection changed '(:model :effort))
        ;; Both together: a nil effort asks for the model's default variant.
        (setq params (append params
                             (list :model (agent-opencode--model-string session)
                                   :variant (or (agent-session-setting session :effort)
                                                :null)))))
      (when (memq :mode changed)
        (setq params (append params
                             (list :agent (agent-opencode--agent session)
                                   :permissions (vconcat (agent-opencode--permissions session))))))
      (when params
        (agent-opencode--request
         session "configure" params
         (lambda (result)
           (when-let* ((model (plist-get result :model)))
             (agent-opencode--set session :model model))))))))

(defun agent-opencode--message (text root)
  "Prompt parameters for user message TEXT in project ROOT.
For a remote project the bridge runs on the host, so images are copied
there first."
  (list :text (agent-session-message-text text)
        :images (vconcat (mapcar (lambda (file)
                                   (if (file-remote-p root) (agent-remote-upload root file) file))
                                 (agent-session-message-images text)))))

(defun agent-opencode--command-p (session text)
  "The slash command in TEXT, as (NAME . ARGUMENTS), or nil.
Local commands are handled by `agent-session' before this point."
  (when (string-match "\\`/\\([[:alnum:]_-]+\\)\\(?:[ \t]+\\([^ \t\n].*\\)\\)?\\'" text)
    (let ((name (match-string 1 text)))
      (when (seq-find (lambda (command)
                        (equal name (plist-get command :name)))
                      (agent-session-backend-commands 'opencode session))
        (cons name (or (match-string 2 text) ""))))))

(cl-defmethod agent-session-backend-send ((_ (eql opencode)) session text)
  (if-let* ((command (agent-opencode--command-p session (agent-session-message-text text))))
      (agent-opencode--request session "command"
                               (list :name (car command) :text (cdr command)))
    (agent-opencode--request session "prompt"
                             (agent-opencode--message text (agent-session-root session)))))

(cl-defmethod agent-session-backend-steer ((_ (eql opencode)) session text)
  ;; opencode delivers it at the next step boundary of the running turn.
  (agent-opencode--request session "steer"
                           (agent-opencode--message text (agent-session-root session)))
  t)

(cl-defmethod agent-session-backend-interrupt ((_ (eql opencode)) session)
  (agent-opencode--request session "cancel" nil))

;;; Past sessions: a short-lived bridge answers sessions/list

(defun agent-opencode--host-dir (dir)
  "Directory DIR as the bridge sees it, without a trailing slash."
  (directory-file-name (agent-session-process-directory dir)))

(defun agent-opencode--history-items (sessions dirs)
  "History items for SESSIONS (from sessions/list) run in DIRS.
DIRS is from `agent-session-worktree-dirs', its project root first.
Sessions of another worktree carry :root and :worktree."
  (mapcar (lambda (item)
            (append
             (list :id (plist-get item :id)
                   :title (car (split-string (string-trim (or (plist-get item :title) ""))
                                             "\n"))
                   :time (plist-get item :time))
             (when-let* ((dir (seq-find (lambda (dir)
                                          (equal (agent-opencode--host-dir (car dir))
                                                 (plist-get item :cwd)))
                                        (cdr dirs))))
               (list :root (car dir) :worktree (cdr dir)))))
          sessions))

(defun agent-opencode--list-sessions (root dirs callback)
  "Call CALLBACK with the history items of the sessions run in DIRS of ROOT."
  (let* ((pending "")
         (done nil)
         (default-directory root)
         (process
          (make-process
           :name "agent-opencode-list"
           :command (agent-opencode--command root)
           :connection-type 'pipe :coding 'utf-8-unix :noquery t
           ;; A remote project's sessions are stored on its host.
           :file-handler (and (file-remote-p root) t)
           :stderr (get-buffer-create " *agent-opencode-list stderr*")
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
                            (agent-opencode--history-items
                             (plist-get (plist-get message :result) :sessions) dirs))))))
           :sentinel (lambda (_process _event)
                       (unless done (setq done t) (funcall callback nil))))))
    (process-send-string
     process (concat (json-serialize
                      (list :jsonrpc "2.0" :id 1 :method "sessions/list"
                            :params (list :cwds (vconcat (mapcar (lambda (dir)
                                                                   (agent-opencode--host-dir (car dir)))
                                                                 dirs)))))
                     "\n"))))

(cl-defmethod agent-session-backend-history ((_ (eql opencode)) root callback)
  (agent-session-worktrees
   root (lambda (dirs) (agent-opencode--list-sessions root dirs callback))))

;;; Tool display

(defun agent-opencode--relative (session path)
  "PATH, as the agent reports it, relative to the project root of SESSION."
  (if (and (stringp path) (file-name-absolute-p path))
      (file-relative-name path (agent-session-process-directory (agent-session-root session)))
    path))

(defun agent-opencode--diff (path old new)
  "A simple diff for PATH from the text before (OLD) and after (NEW)."
  (cl-flet ((lines (prefix text)
              (when (and text (not (string-empty-p text)))
                (mapconcat (lambda (line) (concat prefix line))
                           (split-string (string-remove-suffix "\n" text) "\n")
                           "\n"))))
    (string-join (delq nil (list (and path (concat "--- " (or path "") "\n+++ " path))
                                 (lines "-" old)
                                 (lines "+" new)))
                 "\n")))

(defun agent-opencode--mcp-title (name)
  "Title for the MCP tool NAME, e.g. emacs_render -> emacs · render."
  (string-join (split-string name "_") " · "))

(defun agent-opencode--tool-view (session name arguments)
  "Display properties of tool NAME called with ARGUMENTS (a plist)."
  (let* ((arguments (and (listp arguments) arguments))
         (path (agent-opencode--relative session (plist-get arguments :path)))
         (pattern (plist-get arguments :pattern)))
    (pcase name
      ("shell"
       (append (list :kind 'command
                     :title (car (split-string
                                  (string-trim (or (plist-get arguments :command) ""))
                                  "\n")))
               (when-let* ((workdir (agent-opencode--relative
                                     session (plist-get arguments :workdir))))
                 (list :note workdir))))
      ((or "read" "list") (list :kind 'read :title (or path name)))
      ("write" (list :kind 'edit :title path
                     :diff (agent-opencode--diff path nil (plist-get arguments :content))))
      ("edit" (list :kind 'edit :title path
                    :diff (agent-opencode--diff path (plist-get arguments :oldString)
                                                (plist-get arguments :newString))))
      ("patch" (list :kind 'edit :title "补丁"
                     :diff (plist-get arguments :patchText)))
      ("glob" (list :kind 'search :title (format "glob %s" (or pattern ""))
                    :note path))
      ("grep" (list :kind 'search :title (format "grep %s" (or pattern ""))
                    :note path))
      ("webfetch" (list :kind 'web :title (plist-get arguments :url)))
      ("websearch" (list :kind 'web :title (plist-get arguments :query)))
      ("question" (list :kind 'question :title "提问"))
      ("skill" (list :kind 'other
                     :title (format "技能 %s"
                                    (or (plist-get arguments :id)
                                        (plist-get arguments :name) ""))))
      ((or "subagent" "task")
       (list :kind 'task
             :title (or (plist-get arguments :description)
                        (plist-get arguments :agent) "子任务")))
      ("execute" (list :kind 'other :title "Code Mode"))
      ((pred (string-match-p "_")) (list :kind 'mcp :title (agent-opencode--mcp-title name)))
      (_ (list :kind 'other :title (or path name))))))

;; Results that would only repeat what the call already shows.
(defconst agent-opencode--quiet-results '("write" "edit" "patch")
  "Tools whose successful result text is not shown.")

;;; Approvals

(defconst agent-opencode--actions
  '(("read" . "读取") ("edit" . "修改") ("shell" . "运行命令")
    ("webfetch" . "访问") ("websearch" . "搜索") ("glob" . "查找")
    ("grep" . "搜索") ("external_directory" . "访问项目外的目录")
    ("skill" . "使用技能") ("subagent" . "子任务") ("question" . "提问"))
  "What each permission action is described as.")

(defun agent-opencode--ask-title (action resources)
  "Title for a permission request: ACTION on RESOURCES."
  (let ((what (string-join (append resources nil) " ")))
    (if (string-empty-p what)
        (or (cdr (assoc action agent-opencode--actions)) action)
      (format "%s %s" (or (cdr (assoc action agent-opencode--actions)) action) what))))

(defun agent-opencode--permission (session id params)
  "Ask the user about the bridge's permission request ID with PARAMS."
  (let ((tool (plist-get params :tool)))
    (agent-session-ask
     session
     :title (agent-opencode--ask-title (plist-get params :action)
                                       (plist-get params :resources))
     :detail (or (plist-get params :message)
                 (when (length> (plist-get params :save) 0)
                   "总是允许会记住对它的选择"))
     :choices '((once "允许") (always "总是允许") (reject "拒绝"))
     :tool tool
     :callback (lambda (choice)
                 (agent-opencode--respond session id
                                          (list :decision (symbol-name choice)))))))

(defun agent-opencode--close-ask (session tool label)
  "Close the open confirmation of TOOL in SESSION with LABEL.
Used when another client (the TUI, the desktop app) answered it."
  (when-let* ((tool (and tool (agent-session--block session tool)))
              (ask (seq-find (lambda (ask)
                               (and (equal (plist-get ask :tool) tool)
                                    (null (plist-get ask :answer))))
                             (agent-session-asks session))))
    (agent-session--close-ask session ask label)
    (agent-session--refresh session)))

;;; Questions (opencode's forms)

(defun agent-opencode--options (field)
  "The UI's options for form FIELD: (LABEL . DESCRIPTION)."
  (mapcar (lambda (option)
            (cons (or (plist-get option :label) (plist-get option :value))
                  (plist-get option :description)))
          (append (plist-get field :options) nil)))

(defun agent-opencode--questions (fields)
  "The UI's questions for the bridge's form FIELDS."
  (mapcar
   (lambda (field)
     (let ((options (agent-opencode--options field)))
       (append
        (list :question (plist-get field :question)
              :header (plist-get field :title))
        (pcase (plist-get field :type)
          ("boolean" (list :options '(("是") ("否"))))
          ("multiselect" (list :options options :multi t :other t))
          ((or "number" "integer") (list :other t))
          (_ (append (when options (list :options options))
                     (list :other t :secret (plist-get field :secret))))))))
   fields))

(defun agent-opencode--answer-value (field answer)
  "The form value for FIELD from ANSWER, the UI's answer plist.
ANSWER is (:selected LABELS :custom TEXT); the value is what opencode
expects for the field's type: an option's value, a number, a boolean or
a list of them."
  (let* ((options (append (plist-get field :options) nil))
         (selected (append (plist-get answer :selected) nil))
         (custom (plist-get answer :custom))
         (custom (and (stringp custom) (not (string-empty-p custom)) custom))
         (value (lambda (label)
                  (or (plist-get (seq-find (lambda (option)
                                             (equal (plist-get option :label) label))
                                           options)
                                 :value)
                      label))))
    (pcase (plist-get field :type)
      ("boolean" (if (equal (car selected) "是") t :false))
      ((or "number" "integer") (string-to-number (or custom (car selected) "")))
      ("multiselect" (vconcat (mapcar value selected) (when custom (list custom))))
      (_ (or custom (and selected (funcall value (car selected))) "")))))

(defun agent-opencode--question (session id params)
  "Ask the user the questions of the bridge's form request ID with PARAMS."
  (let* ((fields (append (plist-get params :fields) nil))
         (tool (plist-get params :tool))
         (keyed (seq-map-indexed (lambda (field index) (cons index field)) fields)))
    (agent-session-ask-questions
     session
     :questions (agent-opencode--questions fields)
     :tool tool
     :callback
     (lambda (answers)
       (if (eq answers 'cancel)
           (agent-opencode--respond session id (list :cancel t))
         (agent-opencode--respond
          session id
          (list :answer
                (cl-mapcan (lambda (entry answer)
                             ;; A question left empty is left out: the tool
                             ;; fills it with its own default.
                             (when answer
                               (list (cons (plist-get (cdr entry) :key)
                                           (agent-opencode--answer-value (cdr entry) answer)))))
                           keyed answers))))))))

;;; Message handling

(defun agent-opencode--notification (session method params)
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
            :opencode-tool (plist-get params :name)
            (agent-opencode--tool-view session (plist-get params :name)
                                       (plist-get params :input))))
    ("tool/output"
     (agent-session-tool-output session (plist-get params :id) (plist-get params :delta)))
    ("tool/done"
     (let* ((id (plist-get params :id))
            (block (agent-session--block session id))
            (quiet (member (plist-get block :opencode-tool) agent-opencode--quiet-results))
            (exit (plist-get (plist-get params :metadata) :exit)))
       (when block
         (agent-session-tool
          session id
          :status (if (plist-get params :isError) 'error 'ok)
          (append
           (unless (and quiet (not (plist-get params :isError)))
             (list :output (if (plist-get params :isError)
                               (format "出错：%s" (plist-get params :error))
                             (plist-get params :output))))
           (when (and (numberp exit) (/= exit 0))
             (list :note (format "退出码 %s" exit))))))))
    ("permission" (agent-opencode--permission session (plist-get params :id) params))
    ("permission/done"
     (agent-opencode--close-ask session (plist-get params :tool)
                                (if (equal (plist-get params :reply) "reject")
                                    "已拒绝" "已回答")))
    ("question" (agent-opencode--question session (plist-get params :id) params))
    ("question/done"
     (agent-opencode--close-ask session (plist-get params :tool)
                                (if (plist-get params :cancelled) "已取消" "已回答")))
    ("renamed"
     (when-let* ((title (plist-get params :title)))
       (agent-session-set-info session :title title)))
    ("usage"
     (agent-session-set-info session :tokens (plist-get params :tokens)
                             :cost (plist-get params :cost)))
    ("config" (agent-opencode--apply-config session params))
    ("notice"
     (agent-session-notice session
                           (format "%s：%s" (agent-session-title session)
                                   (plist-get params :message))
                           (and (plist-get params :error) 'agent-session-error)))))

(cl-defmethod agent-session-backend-handle ((_ (eql opencode)) session message)
  (let ((id (plist-get message :id))
        (method (plist-get message :method))
        (params (plist-get message :params)))
    (cond
     ;; Response to one of our requests
     ((and id (not method))
      (if-let* ((err (plist-get message :error)))
          (agent-session-notice session (format "请求失败：%s" (plist-get err :message))
                                'agent-session-error)
        (when-let* ((callbacks (agent-opencode--state session :callbacks))
                    (callback (gethash id callbacks)))
          (remhash id callbacks)
          (funcall callback (plist-get message :result)))))
     ;; Request from the bridge
     (id
      (pcase method
        ("permission" (agent-opencode--permission session id params))
        ("question" (agent-opencode--question session id params))
        (_ (agent-session-write session (list :jsonrpc "2.0" :id id
                                              :error (list :code -32601
                                                           :message (format "unsupported: %s"
                                                                            method)))))))
     ;; Notification
     (t (agent-opencode--notification session method params)))))

(agent-session-define-agent opencode :title "opencode")

(provide 'agent-opencode)
;;; agent-opencode.el ends here
