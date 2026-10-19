;;; agent-collab.el --- Agents working with each other's sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; Every session has a handle, a short English name made from its topic by a
;; cheap model of its own agent (e.g. @cfi-meaning).  The user mentions
;; sessions with it in messages, and agents name sessions with it in these
;; methods:
;;   sessions      list the live sessions
;;   session_read  read the latest turns of a session, paging backwards
;;   session_ask   send a prompt to an idle existing session and wait for the
;;                 reply
;; Agents only talk to sessions the user opened; they never start sessions.
;; With `agent-collab-confirm', session_ask asks the user first, in the
;; caller's footer.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)
(require 'agent-ui)

(defgroup agent-collab nil
  "Agents working with each other's sessions."
  :group 'agent-session
  :prefix "agent-collab-")

(defcustom agent-collab-handle-command
  '("claude" "-p" "--model" "haiku" "--no-session-persistence" "--strict-mcp-config"
    "--tools" "" "--disable-slash-commands" "--setting-sources" "")
  "Command that names sessions with a cheap model, for agents without their own.
The prompt is appended as the last argument and the handle is read from
standard output.  nil means sessions keep their placeholder names (the
agent's name) unless their agent has a command in
`agent-collab-agent-handle-commands'."
  :type '(choice (const :tag "不起名" nil) (repeat string)))

(defcustom agent-collab-agent-handle-commands
  '((codex "codex" "exec" "--ephemeral" "--skip-git-repo-check" "-s" "read-only"
           "-m" "gpt-6-luna" "-c" "model_reasoning_effort=\"low\""))
  "Commands that name the sessions of each agent, like
`agent-collab-handle-command'.  An agent missing here, or whose command
fails, uses `agent-collab-handle-command'."
  :type '(alist :key-type symbol :value-type (repeat string)))

(defcustom agent-collab-handle-timeout 60
  "Seconds a naming command may run before the next one is tried."
  :type 'integer)

(defcustom agent-collab-confirm nil
  "Non-nil means session_ask asks the user before sending a prompt."
  :type 'boolean)

(defcustom agent-collab-text-limit 4000
  "Maximum characters of one message or tool output in session_read."
  :type 'integer)

(defcustom agent-collab-wait 600
  "Seconds session_ask waits for a reply by default."
  :type 'integer)

(defconst agent-collab--max-wait 1500
  "Upper limit of session_ask's wait, below the agents' tool call timeouts.")

;;; Handles

(defun agent-collab--handle-prompt (text)
  "Prompt asking a model for a handle of a conversation starting with TEXT."
  (concat "Name this coding conversation with a short English handle: one or two "
          "lowercase words joined by '-', at most 16 characters, about its topic. "
          "Reply with the handle only.\n\nFirst message:\n"
          (truncate-string-to-width (agent-session-message-text text) 1000)))

(defun agent-collab--clean-handle (output)
  "The handle in model OUTPUT, or nil if there is none."
  (let* ((line (car (last (split-string (downcase (string-trim output)) "\n" t))))
         (handle (and line (replace-regexp-in-string
                            "\\`-+\\|-+\\'" ""
                            (replace-regexp-in-string "[^a-z0-9]+" "-" line)))))
    (when (and handle (string-match-p "\\`[a-z]" handle))
      (string-trim-right (truncate-string-to-width handle 20) "-"))))

(defun agent-collab--handle-commands (session)
  "Naming commands to try for SESSION, in order: its agent's own, then the global one."
  (seq-filter (lambda (command) (and command (executable-find (car command))))
              (delete-dups (list (alist-get (agent-session-agent session)
                                            agent-collab-agent-handle-commands)
                                 agent-collab-handle-command))))

(defun agent-collab--name (session text &optional commands)
  "Name SESSION after the topic of its first message TEXT, in the background.
Try COMMANDS (default `agent-collab--handle-commands') in turn until one
gives a handle."
  (when-let* ((commands (or commands (agent-collab--handle-commands session)))
              (output (generate-new-buffer " *agent-collab-handle*"))
              (errors (generate-new-buffer " *agent-collab-handle-stderr*")))
    (let ((default-directory temporary-file-directory)
          (prompt (agent-collab--handle-prompt text)))
      (let ((process
             (make-process
              :name "agent-collab-handle"
              :buffer output
              :command (append (car commands) (list prompt))
              :connection-type 'pipe
              :noquery t
              :stderr errors
              :sentinel
              (lambda (process _event)
                (unless (process-live-p process)
                  (let ((handle (and (zerop (process-exit-status process))
                                     (agent-collab--clean-handle
                                      (with-current-buffer output (buffer-string))))))
                    ;; The stderr pipe may outlive the process for a moment.
                    (let ((kill-buffer-query-functions nil))
                      (kill-buffer output)
                      (kill-buffer errors))
                    (cond ((not (buffer-live-p (agent-session-buffer session))))
                          (handle (agent-session-set-handle session handle))
                          ((cdr commands)
                           (agent-collab--name session text (cdr commands))))))))))
        ;; `codex exec' reads more prompt from a piped stdin until it ends.
        (process-send-eof process)
        ;; A command that hangs anyway gives way to the next one.
        (run-at-time agent-collab-handle-timeout nil
                     (lambda () (when (process-live-p process) (kill-process process))))))))

(defun agent-collab--name-on-submit (session text)
  "Name SESSION from TEXT when it gets its first message."
  (unless (plist-get (agent-session-info session) :named)
    (setf (agent-session-info session) (plist-put (agent-session-info session) :named t))
    (agent-collab--name session (or (plist-get (agent-session-info session) :title) text))))

(add-hook 'agent-session-submit-functions #'agent-collab--name-on-submit)

;; Sessions opened before handles existed (when this file is reloaded).
(dolist (buffer (agent-session-buffers))
  (let ((session (buffer-local-value 'agent-session--current buffer)))
    (unless (agent-session-handle session)
      (agent-session-set-handle session (symbol-name (agent-session-agent session))))))

(defun agent-collab--mention-note (session text)
  "Tell the agent of SESSION which @handles in TEXT are sessions."
  (let ((pos 0) mentioned)
    (while (string-match "\\(?:^\\|[ \t(]\\)@\\([a-z][a-z0-9-]*\\)" text pos)
      (setq pos (match-end 0))
      (let ((other (agent-session-find (match-string 1 text))))
        (when (and other (not (eq other session)) (not (memq other mentioned)))
          (push other mentioned))))
    (if (null mentioned)
        text
      (concat text "\n\n"
              (mapconcat (lambda (other)
                           (format "(@%s is the %s session \"%s\"; read it with the \
emacs session_read tool.)"
                                   (agent-session-handle other) (agent-session-title other)
                                   (agent-session-display-title other)))
                         (nreverse mentioned) "\n")))))

(add-hook 'agent-session-send-filters #'agent-collab--mention-note)

;;; Reading sessions

(defun agent-collab--session (name)
  "The session called NAME; signal an error if there is none."
  (or (agent-session-find (or name ""))
      (error "No agent session called %s; list them with sessions" name)))

(defun agent-collab--status (session)
  "Status of SESSION for agents."
  (if (agent-session--pending-asks session)
      "awaiting-approval"
    (symbol-name (agent-session-status session))))

(defun agent-collab--turns (session)
  "Turns of SESSION, oldest first: each a list of (ID . BLOCK), the user's first.
Blocks before the first user message and queued messages are left out."
  (let (turns)
    (dolist (entry (agent-session--blocks-in-order session))
      (cond ((plist-get (cdr entry) :queued))
            ((eq (plist-get (cdr entry) :type) 'user) (push (list entry) turns))
            (turns (push entry (car turns)))))
    (nreverse (mapcar #'reverse turns))))

(defun agent-collab--clip (text &optional tail)
  "TEXT as plain text of at most `agent-collab-text-limit' characters.
Keep its end with TAIL, else its start."
  (let* ((text (string-trim (substring-no-properties (or text ""))))
         (extra (- (length text) agent-collab-text-limit)))
    (cond ((<= extra 0) text)
          (tail (format "… (%d characters before)\n%s" extra
                        (substring text extra)))
          (t (format "%s\n… (%d more characters)"
                     (substring text 0 agent-collab-text-limit) extra)))))

(defun agent-collab--tool-line (block)
  "One line describing tool call BLOCK."
  (concat "- " (alist-get (plist-get block :kind) agent-session--tool-icons "•")
          " " (plist-get block :title)
          (pcase (plist-get block :status)
            ('running " (running)")
            ('error " (failed)")
            ('declined " (declined)")
            (_ ""))
          (if-let* ((diff (plist-get block :diff)))
              (concat " " (substring-no-properties (agent-session--diff-stat diff)))
            "")))

(defun agent-collab--format-turn (number turn tools running)
  "Turn NUMBER (TURN from `agent-collab--turns') as text.
TOOLS is none, summary or full; RUNNING means the turn isn't over."
  (let ((parts (list (format "## Turn %d%s\n%s:\n%s" number (if running " (in progress)" "")
                             (if-let* ((origin (plist-get (cdar turn) :origin)))
                                 (concat "Message from " origin)
                               "User")
                             (agent-collab--clip (agent-session-message-text
                                                  (plist-get (cdar turn) :text))))))
        (pending nil))
    (cl-flet ((flush ()
                (when pending
                  (push (concat "Tools:\n" (string-join (nreverse pending) "\n")) parts)
                  (setq pending nil))))
      (pcase-dolist (`(,_id . ,block) (cdr turn))
        (pcase (plist-get block :type)
          ('text (unless (eq (plist-get block :kind) 'thinking)
                   (flush)
                   (push (concat "Assistant:\n" (agent-collab--clip (plist-get block :text)))
                         parts)))
          ('tool (pcase tools
                   ('summary (push (agent-collab--tool-line block) pending))
                   ('full
                    (flush)
                    (let ((body (or (plist-get block :diff) (plist-get block :output))))
                      (push (concat "Tool" (substring (agent-collab--tool-line block) 1)
                                    (if (and body (not (string-blank-p body)))
                                        (concat "\n" (agent-collab--clip body t))
                                      ""))
                            parts)))))
          ('notice (flush)
                   (push (concat "Note: " (plist-get block :text)) parts))))
      (flush))
    (string-join (nreverse parts) "\n\n")))

(defun agent-collab--describe (session caller)
  "SESSION as a plist for the sessions method; CALLER is the calling session."
  (list :id (concat "@" (agent-session-handle session))
        :agent (symbol-name (agent-session-agent session))
        :title (agent-session-display-title session)
        :project (agent-session-root session)
        :status (agent-collab--status session)
        :turns (length (agent-collab--turns session))
        :yours (if (eq session caller) t :false)
        :parent (agent-ui--json-value
                 (when-let* ((parent (agent-session-parent session)))
                   (concat "@" (agent-session-handle parent))))
        :children (vconcat (mapcar (lambda (child) (concat "@" (agent-session-handle child)))
                                   (agent-session-children session)))))

(agent-ui-defmethod "sessions" ()
  "List the agent sessions open in this Emacs.  Each session has an id (its
@handle, which the user also uses to mention it), agent, title, project,
status, number of turns, whether it is your own, the session that started
it (parent) and the sessions it started (children)."
  (let ((caller (agent-ui-caller-session)))
    (list :sessions (vconcat (mapcar (lambda (buffer)
                                       (agent-collab--describe
                                        (buffer-local-value 'agent-session--current buffer)
                                        caller))
                                     (agent-session-buffers))))))

(agent-ui-defmethod "session_read"
    ((session string "Session id: its @handle, as listed by sessions" required)
     (last integer "Number of turns to read, counting back from the end (or from
before); default 2")
     (before integer "Read the turns before this turn number, to page backwards")
     (tools string "none: leave tool calls out; summary (default): one line per
call; full: with their output or diff"))
  "Read the latest turns of an agent session.  A turn is a user message and
everything the agent did for it.  Start with few turns and page backwards
with before when you need more."
  (let* ((target (agent-collab--session session))
         (tools (pcase (or tools "summary")
                  ("none" 'none) ("summary" 'summary) ("full" 'full)
                  (other (error "tools must be none, summary or full, not %s" other))))
         (turns (agent-collab--turns target))
         (total (length turns))
         (end (if before (max 0 (min total (1- before))) total))
         (start (max 0 (- end (max 1 (or last 2)))))
         (running (memq (agent-session-status target) '(running starting)))
         (header (format "Session @%s (%s, %s): %s"
                         (agent-session-handle target) (agent-session-title target)
                         (agent-collab--status target)
                         (agent-session-display-title target))))
    (if (= start end)
        (format "%s\nNo turns%s." header (if (zerop total) " yet" " there"))
      (concat
       header
       (format "\nTurns %d-%d of %d.%s\n\n" (1+ start) end total
               (if (> start 0)
                   (format " Earlier turns: call again with before=%d." (1+ start))
                 ""))
       (string-join
        (cl-loop for turn in (seq-subseq turns start end)
                 for number from (1+ start)
                 collect (agent-collab--format-turn number turn tools
                                                    (and running (= number total))))
        "\n\n")))))

;;; Asking another agent

(defun agent-collab--message (caller prompt)
  "PROMPT from the agent of CALLER, with a note on who is asking."
  ;; The quotes keep `agent-collab--mention-note' from explaining @handle again.
  (format "%s\n\n(Sent by the %s agent of session \"@%s\" through session_ask; your \
final reply goes back to it.)"
          prompt (agent-session-title caller) (agent-session-handle caller)))

(defun agent-collab--reply (target id)
  "The reply to user message ID in TARGET as (TEXT), or nil while it runs."
  (let ((block (agent-session--block target id)))
    (cond
     ((not (buffer-live-p (agent-session-buffer target)))
      (error "The session was closed before it replied"))
     ((null block) (error "The user withdrew the message"))
     ((or (plist-get block :queued)
          (memq (agent-session-status target) '(running starting)))
      nil)
     (t
      (let* ((turn (seq-find (lambda (turn) (equal (caar turn) id))
                             (agent-collab--turns target)))
             (reply (seq-find (lambda (entry)
                                (and (eq (plist-get (cdr entry) :type) 'text)
                                     (not (eq (plist-get (cdr entry) :kind) 'thinking))))
                              (reverse (cdr turn)))))
        (list (format "Reply from @%s (%s)%s:\n\n%s\n\nFollow up with session_ask session=@%s; \
see what it did with session_read."
                      (agent-session-handle target) (agent-session-title target)
                      (if (eq (agent-session-status target) 'exited) ", which then exited" "")
                      (if reply (agent-collab--clip (plist-get (cdr reply) :text)) "(no reply)")
                      (agent-session-handle target))))))))

(agent-ui-defmethod "session_ask"
    ((session string "The idle session to ask: its @handle, as listed by sessions"
              required)
     (prompt string "The message.  The other agent hasn't seen your conversation:
include the context it needs (files, diff, question)" required)
     (wait integer "Seconds to wait for the reply, default 600, at most 1500"))
  "Ask the agent of another open session and wait for its reply: a second
opinion, a review of your changes, or a question to a session the user
mentioned.  The user may have to confirm first.  Returns the final reply of
that turn; if it takes longer than wait, returns the session id: read the
reply later with session_read."
  (let* ((caller (or (agent-ui-caller-session)
                     (error "session_ask works only from an agent session")))
         (target (agent-collab--session session))
         (wait (min agent-collab--max-wait (max 1 (or wait agent-collab-wait))))
         (state (list :phase 'confirm))
         ask)
    (when (eq target caller) (error "That is your own session"))
    (pcase (agent-session-status target)
      ('running (error "@%s is busy; read it with session_read or try later"
                       (agent-session-handle target)))
      ('exited (error "@%s has exited" (agent-session-handle target))))
    (cl-flet ((send ()
                (condition-case err
                    (setq state (list :phase 'running :target target
                                      :id (agent-session-submit
                                           target (agent-collab--message caller prompt)
                                           (concat "@" (agent-session-handle caller)))))
                  (error (setq state (list :phase 'failed
                                           :error (error-message-string err))))))
              (close-ask (label)
                (when-let* ((pending (and ask (agent-session--ask caller ask))))
                  (unless (plist-get pending :answer)
                    (agent-session--close-ask caller pending label)
                    (agent-session--refresh caller)))))
      (if (not agent-collab-confirm)
          (send)
        (setq ask (agent-session-ask
                   caller
                   :title (format "向 @%s 发送消息" (agent-session-handle target))
                   :detail prompt
                   :choices '((allow "允许") (deny "拒绝"))
                   :callback (lambda (key)
                               (if (eq key 'allow)
                                   (send)
                                 (setq state (list :phase 'denied)))))))
      (agent-ui-defer
       (lambda ()
         (pcase (plist-get state :phase)
           ('confirm (when (plist-get (agent-session--ask caller ask) :answer)
                       (error "The confirmation expired")))
           ('denied (error "The user declined to send the message"))
           ('failed (error "Could not send the message: %s" (plist-get state :error)))
           ('running (agent-collab--reply (plist-get state :target) (plist-get state :id)))))
       :wait wait
       :timeout (lambda ()
                  (if (eq (plist-get state :phase) 'running)
                      (format "No reply within %d seconds; @%s is still working.  \
Read its reply later with session_read."
                              wait (agent-session-handle (plist-get state :target)))
                    (close-ask "已超时")
                    (error "The user didn't confirm within %d seconds" wait)))
       :cancel (lambda () (close-ask "已取消"))))))

(provide 'agent-collab)
;;; agent-collab.el ends here
