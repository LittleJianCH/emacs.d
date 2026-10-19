;;; agent-collab.el --- Agents working with each other's sessions -*- lexical-binding: t; -*-

;;; Commentary:

;; Every session has a handle, a short English name made from its topic by a
;; cheap model of its own agent (e.g. @cfi-meaning).  The user mentions
;; sessions with it in messages, and agents name sessions with it in these
;; methods:
;;   sessions       list the live sessions
;;   session_read   read the latest turns of a session, paging backwards
;;   session_ask    send a prompt to an idle session the user opened and wait
;;                  for the reply
;;   session_start  start a subagent: a child session of a profile in
;;                  `agent-collab-profiles' that does one task and reports
;;   session_stop   stop and close a child session
;; Sessions the user opened talk to each other with session_ask (confirmed
;; first with `agent-collab-confirm').  A child session lives with its
;; buffer and its parent, takes no messages from agents and asks no one: it
;; reports through its final reply.  A reply its asker stopped waiting for
;; (wait 0, a timeout) goes to the asker's mailbox, and is sent to its agent
;; once it is idle, with whatever else arrived meanwhile.

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

(defun agent-collab--message-note (caller)
  "The note for the agent asked by the agent of CALLER: who is asking.
It is sent with the message but not shown, which names its sender."
  ;; The quotes keep `agent-collab--mention-note' from explaining @handle again.
  (format "(Sent by the %s agent of session \"@%s\" through session_ask; your final \
reply goes back to it.)"
          (agent-session-title caller) (agent-session-handle caller)))

(defun agent-collab--reply (target id)
  "The reply to user message ID in TARGET as (TEXT), or nil while it runs."
  (let ((block (agent-session--block target id)))
    (cond
     ((not (buffer-live-p (agent-session-buffer target)))
      (error "\"@%s\" was closed before it replied" (agent-session-handle target)))
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
                              (reverse (cdr turn))))
             (handle (agent-session-handle target)))
        (list (format "Reply from \"@%s\" (%s)%s:\n\n%s\n\n%s"
                      handle (agent-session-title target)
                      (if (eq (agent-session-status target) 'exited) ", which then exited" "")
                      (if reply (agent-collab--clip (plist-get (cdr reply) :text)) "(no reply)")
                      (if (agent-session-child-p target)
                          (format "See what it did with session_read session=@%s." handle)
                        (format "Follow up with session_ask session=@%s; see what it did \
with session_read." handle)))))))))

;;; Mailbox: replies that come after their asker stopped waiting

(defvar agent-collab--pending nil
  "Replies asked for: plists (:target SESSION :id ID :asker SESSION :awaited BOOL).
ID is the message's block in TARGET.  While :awaited, the asker's call
waits for the reply; otherwise it goes to the asker's mailbox.")

(defvar agent-collab--mailbox (make-hash-table :test #'eq :weakness 'key)
  "Replies waiting for their asker to be idle: SESSION -> ((HANDLE . TEXT) ...).")

(defun agent-collab--track (target id asker awaited)
  "Note that ASKER wants the reply to message ID in TARGET; return the entry.
AWAITED means its call waits for the reply for now."
  (let ((entry (list :target target :id id :asker asker :awaited awaited)))
    (push entry agent-collab--pending)
    entry))

(defun agent-collab--settle (entry)
  "Post the reply of ENTRY to its asker's mailbox once there is one."
  (unless (plist-get entry :awaited)
    (let* ((target (plist-get entry :target))
           (reply (condition-case err
                      (agent-collab--reply target (plist-get entry :id))
                    (error (list (format "\"@%s\" ended without replying: %s"
                                         (agent-session-handle target)
                                         (error-message-string err)))))))
      (when reply
        (setq agent-collab--pending (delq entry agent-collab--pending))
        (let ((asker (plist-get entry :asker)))
          (when (buffer-live-p (agent-session-buffer asker))
            (puthash asker (append (gethash asker agent-collab--mailbox)
                                   (list (cons (agent-session-handle target) (car reply))))
                     agent-collab--mailbox)
            (agent-collab--deliver asker)))))))

(defun agent-collab--deliver (session)
  "Send SESSION's mailbox to its agent, in one message, if it is idle."
  (when-let* ((mail (and (eq (agent-session-status session) 'idle)
                         (buffer-live-p (agent-session-buffer session))
                         (gethash session agent-collab--mailbox))))
    (remhash session agent-collab--mailbox)
    (agent-session-submit
     session (mapconcat #'cdr mail "\n\n---\n\n")
     (if (cdr mail) "会话回复" (concat "@" (caar mail)))
     "(Replies to messages you sent to other sessions, delivered by Emacs; not from \
the user.)")))

(defun agent-collab--status-changed (session _previous)
  "Settle the replies SESSION owed and deliver its mailbox, as its status changes."
  (dolist (entry agent-collab--pending)
    (when (eq (plist-get entry :target) session)
      (agent-collab--settle entry)))
  (agent-collab--deliver session))

(add-hook 'agent-session-status-functions #'agent-collab--status-changed)

(defun agent-collab--buffer-killed ()
  "Settle the replies the session of this buffer owed: it was closed."
  (when-let* ((session (and (agent-session-buffer-p (current-buffer)) agent-session--current)))
    ;; Settle once the buffer is gone, so the replies say it was closed.
    (run-at-time 0 nil (lambda ()
                         (dolist (entry agent-collab--pending)
                           (when (eq (plist-get entry :target) session)
                             (agent-collab--settle entry)))))))

(add-hook 'kill-buffer-hook #'agent-collab--buffer-killed)

(agent-ui-defmethod "session_ask"
    ((session string "The idle session to ask: its @handle, as listed by sessions"
              required)
     (prompt string "The message.  The other agent hasn't seen your conversation:
include the context it needs (files, diff, question)" required)
     (wait integer "Seconds to wait for the reply: default 600, at most 1500; 0
returns at once"))
  "Ask the agent of another session the user opened and wait for its reply: a
second opinion, a review of your changes, or a question to a session the
user mentioned.  The user may have to confirm first.  Returns the final
reply of that turn; if it takes longer than wait, the reply reaches you
later as a message.  Sessions started with session_start take no messages."
  (let* ((caller (or (agent-ui-caller-session)
                     (error "session_ask works only from an agent session")))
         (target (agent-collab--session session)))
    (when (eq target caller) (error "That is your own session"))
    (when (agent-session-child-p caller)
      (error "A session started for a task reports through its final reply; it \
doesn't ask other sessions"))
    (when (agent-session-child-p target)
      (error "@%s works on a task it was started for and takes no messages; for more \
work, start another session (context handoff passes your conversation)"
             (agent-session-handle target)))
    (pcase (agent-session-status target)
      ('running (error "@%s is busy; read it with session_read or try later"
                       (agent-session-handle target)))
      ('exited (error "@%s has exited" (agent-session-handle target))))
    (agent-collab--converse
     caller
     :confirm (and agent-collab-confirm
                   (format "向 @%s 发送消息" (agent-session-handle target)))
     :detail prompt
     :wait (min agent-collab--max-wait (max 0 (or wait agent-collab-wait)))
     :start (lambda ()
              (cons target (agent-session-submit
                            target prompt (concat "@" (agent-session-handle caller))
                            (agent-collab--message-note caller))))
     :started (lambda (target)
                (format "Sent to @%s.  Its reply will reach you as a message; don't poll \
for it." (agent-session-handle target))))))

(cl-defun agent-collab--converse (caller &key confirm detail wait start started)
  "Send a message for the agent of CALLER and return a deferred result.
START sends it: called with no arguments, it returns (TARGET . ID), the
session it went to and the id of its block there.  With CONFIRM, a title,
the user confirms first in CALLER's footer, seeing DETAIL.  The result is
the reply to the message.  With WAIT 0 it is STARTED called with TARGET as
soon as the message is sent; after WAIT seconds, or once TARGET waits for
the user, a note that it is still working.  Either way the reply then
reaches CALLER's agent through its mailbox."
  (let ((state (list :phase 'confirm))
        (deadline (if (zerop wait) agent-collab-wait wait))
        ask)
    (cl-flet* ((send ()
                 (condition-case err
                     (pcase-let ((`(,target . ,id) (funcall start)))
                       (setq state (list :phase 'running :target target :id id
                                         :entry (agent-collab--track target id caller
                                                                     (> wait 0))))
                       ;; The reply may already be there.
                       (agent-collab--settle (plist-get state :entry)))
                   (error (setq state (list :phase 'failed
                                            :error (error-message-string err))))))
               (close-ask (label)
                 (when-let* ((pending (and ask (agent-session--ask caller ask))))
                   (unless (plist-get pending :answer)
                     (agent-session--close-ask caller pending label)
                     (agent-session--refresh caller))))
               (let-go ()
                 ;; The caller stops waiting: the reply goes to its mailbox.
                 (when-let* ((entry (plist-get state :entry)))
                   (plist-put entry :awaited nil)
                   (agent-collab--settle entry)))
               (reply ()
                 (let ((target (plist-get state :target))
                       (entry (plist-get state :entry)))
                   (cond
                    ((zerop wait) (list (funcall started target)))
                    ((agent-session--pending-asks target)
                     (let-go)
                     (list (format "@%s is waiting for the user to confirm something; \
its reply will reach you as a message." (agent-session-handle target))))
                    (t (condition-case err
                           (when-let* ((done (agent-collab--reply target
                                                                  (plist-get state :id))))
                             (setq agent-collab--pending (delq entry agent-collab--pending))
                             done)
                         (error (setq agent-collab--pending (delq entry agent-collab--pending))
                                (signal (car err) (cdr err)))))))))
      (if (not confirm)
          (send)
        (setq ask (agent-session-ask
                   caller
                   :title confirm
                   :detail detail
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
           ('denied (error "The user declined"))
           ('failed (error "Failed: %s" (plist-get state :error)))
           ('running (reply))))
       :wait deadline
       :timeout (lambda ()
                  (if (eq (plist-get state :phase) 'running)
                      (progn
                        (let-go)
                        (format "No reply within %d seconds; @%s is still working.  Its \
reply will reach you as a message."
                                wait (agent-session-handle (plist-get state :target))))
                    (close-ask "已超时")
                    (error "The user didn't confirm within %d seconds" deadline)))
       :cancel (lambda () (close-ask "已取消") (let-go))))))

;;; Starting sessions (subagents)

(defcustom agent-collab-profiles
  '((coder-flash :agent dsh :model "deepseek-official/deepseek-flash" :mode auto :cost low
                 :description "Writes code and tests to a clear specification.")
    (explorer :agent claude :model "haiku" :mode plan :cost low
              :description "Investigates without editing: finds code, reads docs, \
gathers evidence.")
    (reviewer :agent codex :mode plan :cost medium
              :description "Reviews changes independently; doesn't edit files."))
  "The sessions agents can start with session_start, by name.
Each entry is (NAME . PLIST), with PLIST keys:
  :agent        a registered agent, such as dsh
  :model        its model; nil means the agent's default
  :effort       its reasoning effort; nil means the model's default
  :mode         its permission mode, at most that of the starting session
  :cost         low, medium or high, to help agents choose
  :description  what it is good for, shown to agents
  :confirm      non-nil asks the user before each start
Profiles of agents that aren't enabled are left out."
  :type '(alist :key-type symbol :value-type plist))

(defcustom agent-collab-max-active 4
  "Most sessions one session's agent may have working at once."
  :type 'integer)

(defcustom agent-collab-handoff-limit 60000
  "Most characters of its conversation a session hands over to one it starts."
  :type 'integer)

(defconst agent-collab--modes '(plan ask edits auto full)
  "Permission modes from the narrowest to the broadest.")

(defun agent-collab--profiles ()
  "Entries of `agent-collab-profiles' whose agent is enabled."
  (seq-filter (lambda (entry) (assq (plist-get (cdr entry) :agent) agent-session-agents))
              agent-collab-profiles))

(defun agent-collab--profile (name)
  "The enabled profile called NAME; signal an error if there is none."
  (or (and name (assq (intern name) (agent-collab--profiles)))
      (error "%s; choose one of: %s"
             (if name (format "No profile %s" name) "Name a profile")
             (mapconcat (lambda (entry) (symbol-name (car entry))) (agent-collab--profiles) ", "))))

(defun agent-collab--profiles-description ()
  "The profiles, for the description of session_start."
  (concat "Profiles:\n"
          (mapconcat (pcase-lambda (`(,name . ,plist))
                       (format "- %s: %s%s, %s cost.  %s"
                               name
                               (or (agent-session--get (plist-get plist :agent) :title)
                                   (plist-get plist :agent))
                               (if-let* ((model (plist-get plist :model))) (concat " " model) "")
                               (or (plist-get plist :cost) "unknown")
                               (or (plist-get plist :description) "")))
                     (agent-collab--profiles) "\n")))

(setf (alist-get "session_start" agent-ui-description-functions nil nil #'equal)
      #'agent-collab--profiles-description)

(defun agent-collab--child-mode (mode parent)
  "Permission MODE capped at that of the session PARENT."
  (let ((cap (or (cl-position (agent-session-setting parent :mode) agent-collab--modes) 0)))
    (nth (min cap (or (cl-position mode agent-collab--modes) cap)) agent-collab--modes)))

(defun agent-collab--working (sessions)
  "Those of SESSIONS whose agent is working."
  (seq-filter (lambda (session) (memq (agent-session-status session) '(running starting)))
              sessions))

(defvar agent-collab--handoffs (make-hash-table :test #'eq :weakness 'key)
  "The last conversation handed over by each session: SESSION -> (TURN . TEXT).")

(defun agent-collab--handoff (session)
  "The conversation of SESSION as text to hand over.
Within `agent-collab-handoff-limit': the latest turn, cut if need be, the
first message, which usually sets the goal, then the turns before the
latest as far as they fit.  Sessions started in the same turn get the same
text, so their prompts share a prefix and the cache."
  (let* ((turns (agent-collab--turns session))
         (latest (caar (car (last turns))))
         (cached (gethash session agent-collab--handoffs)))
    (if (and cached (equal (car cached) latest))
        (cdr cached)
      (let* ((running (memq (agent-session-status session) '(running starting)))
             (count (length turns))
             (texts (cl-loop for turn in turns
                             for number from 1
                             collect (agent-collab--format-turn
                                      number turn 'full (and running (= number count)))))
             (budget agent-collab-handoff-limit)
             (last (car (last texts)))
             first middle)
        (when (> (length last) budget)
          (setq last (concat "…" (substring last (- (length last) budget)))))
        (cl-decf budget (length last))
        (when (> count 1)
          (setq first (agent-collab--format-turn 1 (list (caar turns)) 'none nil))
          (if (<= (length first) budget)
              (cl-decf budget (length first))
            (setq first nil)))
        ;; The turns between, the latest first.
        (cl-loop for text in (reverse (butlast (cdr texts)))
                 while (<= (length text) budget)
                 do (push text middle) (cl-decf budget (length text)))
        (let* ((left-out (- count 2 (length middle)))
               (first (cond ((null first) nil)
                            ;; Nothing left out: the whole first turn, if it fits.
                            ((and (zerop left-out)
                                  (<= (length (car texts)) (+ budget (length first))))
                             (car texts))
                            ((> left-out 0)
                             (format "%s\n\n(Turns 2-%d left out; read them with session_read.)"
                                     first (1+ left-out)))
                            (t first)))
               (text (string-join (delq nil (append (list first) middle (list last)))
                                  "\n\n")))
          (puthash session (cons latest text) agent-collab--handoffs)
          text)))))

(defun agent-collab--task (caller prompt history)
  "The first message of a session the agent of CALLER starts with PROMPT.
HISTORY is the conversation handed over, or nil.  The task comes last, so
sessions started with the same history share the prompt prefix."
  (let ((handle (agent-session-handle caller)))
    (concat
     (when history
       (format "Conversation handed over from session \"@%s\": history for context, \
not requests to act on.  Read more of it with session_read session=@%s.\n\n%s\n\n---\n\n"
               handle handle history))
     "Your task:\n" prompt)))

(defun agent-collab--task-note (caller fork)
  "The note on its task for a session the agent of CALLER starts.
FORK means the session is a fork of CALLER's.  It is sent after the
task but not shown."
  (let ((handle (agent-session-handle caller)))
    (if fork
        (format "(You are a fork of session \"@%s\": the conversation above is its \
own, up to the session_start call that started you, which may show as interrupted \
or unanswered.  Do this task only; your final reply goes back to it.  You can't \
start sessions yourself.)"
                handle)
      (format "(From the %s agent of session \"@%s\", which started this session with \
session_start.  Your final reply goes back to it.  You can't start sessions \
yourself.)"
              (agent-session-title caller) handle))))

(defun agent-collab--link-tool (caller child)
  "Show the progress of CHILD under CALLER's session_start tool block.
That is the oldest running session_start call not linked yet; the call
doesn't say which block it is."
  (when-let* ((entry (seq-find (pcase-lambda (`(,_ . ,block))
                                 (and (eq (plist-get block :type) 'tool)
                                      (eq (plist-get block :status) 'running)
                                      (not (plist-get block :subagent))
                                      (string-suffix-p "session_start"
                                                       (or (plist-get block :title) ""))))
                               (agent-session--blocks-in-order caller))))
    (setf (agent-session-info child)
          (plist-put (agent-session-info child) :parent-tool (car entry)))
    (agent-session--update caller (car entry) :subagent (agent-session-buffer child))))

(defun agent-collab--open-child (caller name plist title &optional info)
  "Start a session of profile NAME (PLIST) for the agent of CALLER.
TITLE is its title; INFO is more of its info, such as :fork-from."
  (let* ((buffer (agent-session-open
                  (plist-get plist :agent) (agent-session-root caller) nil
                  (list :model (plist-get plist :model) :effort (plist-get plist :effort)
                        :mode (agent-collab--child-mode (plist-get plist :mode) caller))
                  ;; Named after its profile right away: the caller refers to it
                  ;; by that handle, which must not change.
                  (append (list :parent (agent-session-buffer caller) :profile name
                                :named t :title title)
                          info)))
         (child (buffer-local-value 'agent-session--current buffer)))
    (agent-session-set-handle child name)
    (agent-collab--link-tool caller child)
    child))

(defun agent-collab--fork-plist (caller)
  "A profile-like plist for a fork of CALLER: its agent and settings."
  (list :agent (agent-session-agent caller)
        :model (plist-get (agent-session-settings caller) :model)
        :effort (plist-get (agent-session-settings caller) :effort)
        :mode (agent-session-setting caller :mode)))

(agent-ui-defmethod "session_start"
    ((profile string "The kind of session to start: one of the profiles below.  Not with
context fork")
     (context string "How it gets context: fresh (default), handoff or fork")
     (prompt string "The task.  With fresh, include everything it needs: it hasn't seen
your conversation" required)
     (title string "A short title for the session, a few words")
     (wait integer "Seconds to wait for its final reply.  0 (default) returns at once
while it works; at most 1500"))
  "Start a subagent: a new session that does one task for you and reports
back, shown to the user under your session.  Choose how it gets context:
- fork: a clone of you (your agent and model) that inherits your whole
  conversation through the prompt cache, so its input is cheap; its output
  costs what yours does.  Prefer it when the task is hard enough to need
  your own level of reasoning.  Omit profile.  Claude, Codex and DeepSeek
  sessions can fork.
- handoff: a cheaper profile gets a text copy of your recent conversation
  (no prompt cache, and tool output is cut).  Use it when the task needs
  your context but a cheaper model can do it.
- fresh: a profile starts from your prompt alone.  Use it for
  self-contained work, and write the prompt so it stands alone.
Prefer the cheapest profile that can do the job.  By default (wait 0) it
returns the session's @handle at once, and its final reply reaches you as a
message when it finishes: don't poll it.  A session you start does one
task, takes no follow-ups and closes with yours; for more work start
another.  Stop one with session_stop."
  (let* ((caller (or (agent-ui-caller-session)
                     (error "session_start works only from an agent session")))
         (context (or context "fresh"))
         (fork (equal context "fork"))
         (working (length (agent-collab--working (agent-session-children caller))))
         name plist history info)
    (when (agent-session-parent caller)
      (error "A session started by another session can't start sessions; do the task \
yourself"))
    (when (>= working agent-collab-max-active)
      (error "%d sessions you started are still working, the most at once; wait for \
one to finish" working))
    (pcase context
      ("fork"
       (when profile
         (error "A fork uses your own agent and model; omit profile"))
       (unless (agent-session-backend-fork-p (agent-session-backend caller))
         (error "%s sessions can't fork; use handoff" (agent-session-title caller)))
       (let ((source (or (agent-session-resume-id caller)
                         (error "Your session has no conversation to fork yet"))))
         (setq name (concat (agent-session-handle caller) "-fork")
               plist (agent-collab--fork-plist caller)
               info (list :fork-from source))))
      ((or "fresh" "handoff")
       (let ((entry (agent-collab--profile profile)))
         (setq name (symbol-name (car entry))
               plist (cdr entry)
               history (and (equal context "handoff") (agent-collab--handoff caller)))))
      (_ (error "context must be fresh, handoff or fork, not %s" context)))
    (agent-collab--converse
     caller
     :confirm (and (plist-get plist :confirm) (format "启动子会话 %s" name))
     :detail prompt
     :wait (min agent-collab--max-wait (max 0 (or wait 0)))
     :start (lambda ()
              (let ((child (agent-collab--open-child
                            caller name plist
                            (or title (agent-session--title-seed prompt))
                            info)))
                (cons child (agent-session-submit
                             child (agent-collab--task caller prompt history)
                             (concat "@" (agent-session-handle caller))
                             (agent-collab--task-note caller fork)))))
     :started (lambda (child)
                (format "Started @%s (%s%s, %s).  Its final reply will reach you as a \
message when it finishes; don't poll it.  Keep working, or end your turn if \
there is nothing else to do."
                        (agent-session-handle child) (agent-session-title child)
                        (if-let* ((model (plist-get plist :model))) (concat " " model) "")
                        context)))))

(agent-ui-defmethod "session_stop"
    ((session string "The session to stop: one you started, by its @handle" required))
  "Stop a session you started with session_start and close it: when its task
is no longer needed or it went the wrong way.  Its reply won't come."
  (let* ((caller (or (agent-ui-caller-session)
                     (error "session_stop works only from an agent session")))
         (target (agent-collab--session session)))
    (unless (eq (agent-session-parent target) caller)
      (error "@%s isn't a session you started" (agent-session-handle target)))
    ;; Nothing is owed any more.
    (setq agent-collab--pending
          (seq-remove (lambda (entry) (eq (plist-get entry :target) target))
                      agent-collab--pending))
    (agent-session-kill-quietly (agent-session-buffer target))
    (format "Stopped and closed @%s." (agent-session-handle target))))

(provide 'agent-collab)
;;; agent-collab.el ends here
