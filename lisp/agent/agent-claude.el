;;; agent-claude.el --- Claude Code backend (stream-json) -*- lexical-binding: t; -*-

;;; Commentary:

;; Runs a long-lived process via
;; `claude -p --input-format stream-json --output-format stream-json':
;;   - User messages: {"type":"user","message":{"role":"user","content":...}}
;;   - Output: stream_event (streaming deltas), assistant / user (complete
;;     messages, tool results), result (end of turn)
;;   - Permissions: --permission-prompt-tool stdio; the CLI sends
;;     control_request(can_use_tool) and we reply with control_response.
;;     An initialize control request must be sent first after startup.
;; The emacs MCP server is injected into this process only via --mcp-config;
;; the global configuration is left untouched.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)
(require 'agent-remote)

(defgroup agent-claude nil
  "Claude Code backend."
  :group 'agent-session
  :prefix "agent-claude-")

(defcustom agent-claude-executable "claude"
  "The claude command."
  :type 'string)

(defcustom agent-claude-extra-args nil
  "Extra command-line arguments."
  :type '(repeat string))

(defconst agent-claude--modes
  '((ask . "default") (edits . "acceptEdits") (auto . "auto")
    (full . "bypassPermissions") (plan . "plan"))
  "Mapping from unified permission modes to Claude permission modes.")

(defun agent-claude--mode (session)
  "Return the Claude value for SESSION's current permission mode."
  (alist-get (agent-session-setting session :mode) agent-claude--modes "default"))

(defun agent-claude--command (session)
  "Return the command line that starts SESSION.
Model, reasoning effort and permission mode come from the session settings."
  (let ((emx (if (file-remote-p (agent-session-root session))
                 (agent-remote-mcp-command session)
               (agent-session-emx-command))))
    (append
     (list agent-claude-executable "-p"
           "--input-format" "stream-json" "--output-format" "stream-json"
           "--verbose" "--include-partial-messages"
           "--permission-prompt-tool" "stdio"
           "--mcp-config" (json-serialize
                           (list :mcpServers
                                 (list :emacs (list :command (car emx)
                                                    :args (vconcat (cdr emx)))))))
     ;; Allow switching to full access later in the session; --permission-mode
     ;; decides whether it is enabled.
     (list "--allow-dangerously-skip-permissions"
           "--permission-mode" (agent-claude--mode session))
     (when-let* ((model (agent-session-setting session :model)))
       (unless (equal model "default") (list "--model" model)))
     (when-let* ((effort (agent-session-setting session :effort)))
       (list "--effort" effort))
     (when-let* ((resume (plist-get (agent-session-state session) :resume)))
       (list "--resume" resume))
     agent-claude-extra-args)))

(defun agent-claude--state (session key)
  "Return backend state KEY of SESSION."
  (plist-get (agent-session-state session) key))

(defun agent-claude--set (session key value)
  "Set backend state KEY of SESSION to VALUE."
  (setf (agent-session-state session) (plist-put (agent-session-state session) key value)))

(defun agent-claude--control (session request &optional callback)
  "Send control request REQUEST to the CLI for SESSION.
On a successful response, call CALLBACK with the response contents."
  (let ((id (symbol-name (gensym "emacs-"))))
    (when callback
      (agent-claude--set session :callbacks
                         (cons (cons id callback) (agent-claude--state session :callbacks))))
    (agent-session-write session (list :type "control_request" :request_id id :request request))))

;;; Past sessions (~/.claude/projects/<encoded-project-path>/<session-id>.jsonl)

(defun agent-claude--project-dir (root)
  "Return the session directory of project ROOT.
Every non-alphanumeric character in the path is replaced with -.  The CLI
of a remote project runs on its host, so its sessions are filed there."
  (let ((name (replace-regexp-in-string
               "[^[:alnum:]]" "-" (directory-file-name (agent-session-process-directory root)))))
    (if-let* ((remote (file-remote-p root)))
        ;; Left unexpanded: expanding ~ would need a round trip to the host.
        (concat remote "~/.claude/projects/" name)
      (expand-file-name name "~/.claude/projects/"))))

(defun agent-claude--json-lines (file &optional beg end)
  "Return the JSON lines of FILE between bytes BEG and END that parse fully."
  (with-temp-buffer
    (insert-file-contents file nil beg end)
    (let (result)
      (dolist (line (split-string (buffer-string) "\n" t) (nreverse result))
        (when-let* ((object (ignore-errors
                              (json-parse-string line :object-type 'plist
                                                 :null-object nil :false-object nil))))
          (push object result))))))

(defun agent-claude--user-text (entry)
  "Return the text of ENTRY if it is a message typed by the user.
Meta entries, command tags and subagent messages are excluded.  The
content of a message with images is a list (text and images); images
are shown as [图片].  Tool results do not count."
  (let* ((content (plist-get (plist-get entry :message) :content))
         (text (cond
                ((stringp content) content)
                ((and (vectorp content) (length> content 0)
                      (seq-every-p (lambda (part) (member (plist-get part :type) '("text" "image")))
                                   content))
                 (mapconcat (lambda (part)
                              (if (equal (plist-get part :type) "image")
                                  "[图片]"
                                (plist-get part :text)))
                            content "\n")))))
    (when (and (equal (plist-get entry :type) "user")
               text
               (not (plist-get entry :isMeta))
               (not (plist-get entry :isSidechain))
               (not (string-prefix-p "<" (string-trim-left text))))
      text)))

(defun agent-claude--session-title (file)
  "Return the title of session file FILE.
Use the title generated by Claude, or else the first user message."
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

(defun agent-claude--transcript (session)
  "Return the transcript file of SESSION, or nil if its session id is unknown."
  (when-let* ((id (agent-claude--state session :resume)))
    (expand-file-name (concat id ".jsonl") (agent-claude--project-dir (agent-session-root session)))))

(defun agent-claude--read-entries (file beg)
  "Read the complete lines of FILE starting at byte BEG.
Return (ENTRIES . END), where END is the byte position read up to.  An
unfinished last line (no trailing newline) is left for the next read."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file nil beg)
    (goto-char (point-max))
    (if (not (search-backward "\n" nil t))
        (cons nil beg)
      (let ((end (+ beg (point))))
        (delete-region (1+ (point)) (point-max))
        (decode-coding-region (point-min) (point-max) 'utf-8)
        (set-buffer-multibyte t)
        (cons (delq nil (mapcar (lambda (line)
                                  (ignore-errors
                                    (json-parse-string line :object-type 'plist
                                                       :null-object nil :false-object nil)))
                                (split-string (buffer-string) "\n" t)))
              end)))))

(defun agent-claude--render-entry (session entry)
  "Render transcript entry ENTRY into SESSION."
  (unless (plist-get entry :isSidechain)
    (let ((message (plist-get entry :message))
          (uuid (plist-get entry :uuid)))
      (pcase (plist-get entry :type)
        ;; Messages added by the user mid-turn are queued_command attachments.
        ("attachment"
         (let ((attachment (plist-get entry :attachment)))
           ;; Prompts starting with < are internal (e.g. a subagent's report);
           ;; don't show them as user messages.
           (when (and (equal (plist-get attachment :type) "queued_command")
                      (stringp (plist-get attachment :prompt))
                      (not (string-prefix-p "<" (string-trim-left (plist-get attachment :prompt)))))
             (agent-session--new-block session uuid
                                       (list :type 'user :text (plist-get attachment :prompt))))))
        ("user"
         (if-let* ((text (agent-claude--user-text entry)))
             (agent-session--new-block session uuid (list :type 'user :text text))
           (agent-claude--tool-results session message)))
        ("assistant"
         (seq-do-indexed
          (lambda (part index)
            (pcase (plist-get part :type)
              ("text" (agent-session-text-done session (format "%s-%s" uuid index)
                                               (plist-get part :text)))
              ("tool_use"
               (apply #'agent-session-tool session (plist-get part :id) :status 'ok
                      (agent-claude--tool-view session (plist-get part :name)
                                               (plist-get part :input))))))
          (plist-get message :content)))))))

(defun agent-claude--replay (session)
  "Render the history of a resumed session into SESSION."
  (let ((file (agent-claude--transcript session)))
    (when (and file (file-exists-p file))
      (pcase-let ((`(,entries . ,end) (agent-claude--read-entries file 0)))
        (dolist (entry entries)
          (agent-claude--render-entry session entry))
        (agent-claude--set session :sync-offset end)))
    (agent-session-notice session "—— 以上为历史记录 ——")))

;;; Syncing with other clients (same session open in Claude Desktop, a terminal...)
;;
;; Every client appends the conversation to the same transcript file.  Watch
;; that file and display messages written by CLIs other than this Emacs's.  The
;; CLI process keeps its context in memory and can't see those messages, so
;; before the next send, restart it with --resume to reread the full transcript.

(defconst agent-claude--own-entrypoint "sdk-cli"
  "Entrypoint recorded in the transcript by the CLI this Emacs starts.")

(defun agent-claude--source-name (entrypoint)
  "Return the client name for transcript ENTRYPOINT."
  (pcase entrypoint
    ("claude-desktop" "Claude Desktop")
    ("cli" "终端中的 Claude Code")
    (_ (or entrypoint "其他客户端"))))

(defun agent-claude--watch (session)
  "Start watching SESSION's transcript file.
Do nothing if it is already watched or the file doesn't exist yet."
  (let ((file (agent-claude--transcript session)))
    (when (and file (file-exists-p file)
               (not (agent-claude--state session :watch))
               (require 'filenotify nil t))
      (unless (agent-claude--state session :sync-offset)
        (agent-claude--set session :sync-offset (file-attribute-size (file-attributes file))))
      (agent-claude--set session :watch
                         (ignore-errors
                           (file-notify-add-watch
                            file '(change)
                            (lambda (event)
                              (when (and (eq (nth 1 event) 'changed)
                                         (buffer-live-p (agent-session-buffer session)))
                                (agent-claude--sync session)))))))))

(defun agent-claude--unwatch (session)
  "Stop watching SESSION's transcript file."
  (when-let* ((watch (agent-claude--state session :watch)))
    (file-notify-rm-watch watch)
    (agent-claude--set session :watch nil)))

(defun agent-claude--sync (session)
  "Display messages newly written to SESSION's transcript by other clients."
  (let ((file (agent-claude--transcript session))
        (offset (agent-claude--state session :sync-offset)))
    (when (and file offset (file-exists-p file))
      (pcase-let ((`(,entries . ,end) (agent-claude--read-entries file offset)))
        (agent-claude--set session :sync-offset end)
        (dolist (entry entries)
          (let ((source (plist-get entry :entrypoint)))
            (when (and source (not (equal source agent-claude--own-entrypoint)))
              (unless (equal source (agent-claude--state session :sync-source))
                (agent-claude--set session :sync-source source)
                (agent-session-notice session (format "以下来自 %s"
                                                      (agent-claude--source-name source))))
              (agent-claude--render-entry session entry)
              ;; Another client advanced the conversation; our context is now stale.
              (when (member (plist-get entry :type) '("user" "assistant"))
                (agent-claude--set session :external t)))))))))

(cl-defmethod agent-session-backend-start ((_ (eql claude)) session)
  (when (and (agent-claude--state session :resume)
             (zerop (hash-table-count (agent-session-blocks session))))
    (agent-claude--replay session))
  (agent-claude--watch session)
  (agent-session-start-process session (agent-claude--command session))
  (agent-claude--control
   session (list :subtype "initialize")
   (lambda (response)
     ;; The initialize result contains the model list (with each model's
     ;; supported reasoning efforts) and the slash commands.
     (agent-claude--set session :models (plist-get response :models))
     (agent-claude--set session :commands (plist-get response :commands))
     ;; After a restart a message may already have been sent (see
     ;; `agent-session-backend-send'); don't overwrite running.
     (when (eq (agent-session-status session) 'starting)
       (agent-session-set-status session 'idle)))))

(cl-defmethod agent-session-backend-stop ((_ (eql claude)) session)
  (agent-claude--unwatch session)
  (cl-call-next-method))

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
  ;; Reasoning effort can only be set at startup: restart with --resume now
  ;; if idle, otherwise wait for the turn to end.
  (when (memq :effort changed)
    (if (eq (agent-session-status session) 'running)
        (progn (agent-claude--set session :restart-pending t)
               (agent-session-notice session "推理强度将在本回合结束后生效"))
      (agent-session-restart-process session))))

(defun agent-claude--content (text)
  "Return the content of user message TEXT.
A string when there are no images, otherwise a vector with the images
first and the text last."
  (let ((images (agent-session-message-images text))
        (plain (agent-session-message-text text)))
    (if (null images)
        plain
      (vconcat
       (mapcar (lambda (file)
                 (list :type "image"
                       :source (list :type "base64"
                                     :media_type (agent-session-image-media-type file)
                                     :data (with-temp-buffer
                                             (set-buffer-multibyte nil)
                                             (insert-file-contents-literally file)
                                             (base64-encode-region (point-min) (point-max) t)
                                             (buffer-string)))))
               images)
       (unless (string-empty-p plain)
         (list (list :type "text" :text plain)))))))

(cl-defmethod agent-session-backend-send ((_ (eql claude)) session text)
  ;; Other clients wrote messages: restart first so the CLI reads the full
  ;; transcript.
  (when (agent-claude--state session :external)
    (agent-claude--set session :external nil)
    (agent-session-notice session "载入其他客户端的消息后继续")
    (agent-session-restart-process session)
    (agent-session-set-status session 'running))
  (agent-claude--set session :sync-source nil)
  (agent-session-write session (list :type "user"
                                     :message (list :role "user"
                                                    :content (agent-claude--content text)))))

(cl-defmethod agent-session-backend-steer ((_ (eql claude)) session text)
  ;; A user message written mid-turn is inserted into the current turn by
  ;; the CLI at the next gap (e.g. between tool calls).
  (agent-session-write session (list :type "user"
                                     :message (list :role "user"
                                                    :content (agent-claude--content text))))
  t)

(cl-defmethod agent-session-backend-interrupt ((_ (eql claude)) session)
  (agent-claude--control session (list :subtype "interrupt")))

;;; Displaying tool calls

(defun agent-claude--relative (session path)
  "Return PATH relative to the project root of SESSION."
  (if (and (stringp path) (file-name-absolute-p path))
      (file-relative-name path (agent-session-process-directory (agent-session-root session)))
    path))

(defun agent-claude--diff (path old new)
  "Make a simple diff for PATH from the text before (OLD) and after (NEW)."
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
  "Return how to display tool NAME with arguments INPUT.
The value is a plist (:kind :title [:diff])."
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
  "Convert tool result CONTENT (a string or content block array) to text."
  (if (stringp content)
      content
    (mapconcat (lambda (part) (or (plist-get part :text) "")) content "\n")))

;;; Message handling

(defun agent-claude--block-id (session index)
  "Return the block id of the INDEXth content block in the current message."
  (format "%s-%s" (agent-claude--state session :message) index))

(defun agent-claude--stream-event (session event)
  "Handle streaming event EVENT for SESSION."
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
  "Update SESSION's context token count from USAGE."
  (when usage
    (let ((tokens (+ (or (plist-get usage :input_tokens) 0)
                     (or (plist-get usage :cache_creation_input_tokens) 0)
                     (or (plist-get usage :cache_read_input_tokens) 0)
                     (or (plist-get usage :output_tokens) 0))))
      (when (> tokens 0) (agent-session-set-info session :tokens tokens)))))

(defun agent-claude--assistant (session message)
  "Handle complete assistant MESSAGE: fill in the tool call argument display."
  (seq-doseq (part (plist-get message :content))
    (when (equal (plist-get part :type) "tool_use")
      (apply #'agent-session-tool session (plist-get part :id) :status 'running
             (agent-claude--tool-view session (plist-get part :name) (plist-get part :input))))))

(defun agent-claude--tool-results (session message)
  "Handle tool results in user MESSAGE: update each tool's status and output."
  (let ((content (plist-get message :content)))
    (unless (stringp content)
      (seq-doseq (part content)
        (when (equal (plist-get part :type) "tool_result")
          (let* ((id (plist-get part :tool_use_id))
                 (declined (member id (agent-claude--state session :declined))))
            ;; Only update tools already shown; when syncing we may read a result
            ;; without its call (written before watching started).
            (when (agent-session--block session id)
              (agent-session-tool session id
                                :status (cond (declined 'declined)
                                              ((plist-get part :is_error) 'error)
                                              (t 'ok))
                                :output (agent-claude--result-text (plist-get part :content))))))))))

(defun agent-claude--permission (session request-id request)
  "Handle permission REQUEST with id REQUEST-ID.
Ask the user in SESSION, then reply to the CLI."
  (let* ((input (plist-get request :input))
         (tool-id (plist-get request :tool_use_id))
         (view (agent-claude--tool-view session (plist-get request :tool_name) input))
         (suggestions (plist-get request :permission_suggestions))
         ;; Arguments sent back to the CLI must match the original JSON exactly.
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
  ;; Don't show the steps of subagents (non-nil parent_tool_use_id), only
  ;; their final result.
  (unless (plist-get message :parent_tool_use_id)
    (pcase (plist-get message :type)
      ("system"
       (when (equal (plist-get message :subtype) "init")
         (agent-claude--set session :resume (plist-get message :session_id))
         (agent-claude--watch session)
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
       ;; A new session's transcript file is only created during the first turn.
       (agent-claude--watch session)
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
