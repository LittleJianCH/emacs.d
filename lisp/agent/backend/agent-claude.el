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
(require 'agent-usage)

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

(defcustom agent-claude-disallowed-tools '("Agent" "Workflow" "SendMessage" "ListAgents")
  "Built-in tools the CLI may not use.
Subagents and messages between agents go through Emacs (agent-collab.el),
so the CLI's own are off by default: Agent starts subagents, Workflow
orchestrates them, SendMessage and ListAgents talk to them."
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
     (when agent-claude-disallowed-tools
       (list "--disallowedTools" (string-join agent-claude-disallowed-tools ",")))
     ;; A session another agent started lives with its buffer.
     (when (agent-session-child-p session)
       (list "--no-session-persistence"))
     (when-let* ((model (agent-session-setting session :model)))
       (unless (equal model "default") (list "--model" model)))
     (when-let* ((effort (agent-session-setting session :effort)))
       (list "--effort" effort))
     (if-let* ((resume (plist-get (agent-session-state session) :resume)))
         (list "--resume" resume)
       ;; A fork starts as a copy of its source's conversation.  With the
       ;; same flags as the source it shares the source's prompt cache.
       (when-let* ((fork (plist-get (agent-session-info session) :fork-from)))
         (list "--resume" fork "--fork-session")))
     ;; Claude loads the skills under .claude/skills/ of an added directory.
     (when-let* ((skills (agent-session-skills-dir session)))
       (list "--add-dir" skills))
     (when-let* ((superseded (agent-session-superseded-skills)))
       (let ((overrides (make-hash-table :test #'equal)))
         (dolist (name superseded) (puthash name "off" overrides))
         (list "--settings" (json-serialize (list :skillOverrides overrides)))))
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

(defun agent-claude--encode-path (path)
  "Return the name the CLI files the sessions run in PATH under.
Every non-alphanumeric character in the path is replaced with -."
  (replace-regexp-in-string "[^[:alnum:]]" "-" (directory-file-name path)))

(defun agent-claude--project-dir (root)
  "Return the session directory of project ROOT.
The CLI of a remote project runs on its host, so its sessions are filed
there."
  (let ((name (agent-claude--encode-path (agent-session-process-directory root))))
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

;; Sessions of the project's git worktrees (see `agent-session-worktrees')
;; are filed under each worktree's path; the history gathers them all.

(defun agent-claude--history-dirs (dirs names)
  "Return where the sessions run in DIRS are filed.
DIRS is from `agent-session-worktree-dirs', its project root first.
NAMES are the directory names in ~/.claude/projects/: those of Claude
Desktop worktrees removed since (no longer listed by git) are found
there.  Each element is (NAME DIRECTORY LABEL): the sessions filed
under NAME ran in DIRECTORY, a worktree labeled LABEL, which is nil for
the root itself."
  (let* ((root (car (car dirs)))
         (result (mapcar (lambda (dir) (list (agent-claude--encode-path (car dir)) (car dir) (cdr dir)))
                         dirs))
         (desktop (concat (agent-claude--encode-path root) "--claude-worktrees-")))
    (dolist (name names)
      (when (and (string-prefix-p desktop name) (not (assoc name result)))
        (let ((label (substring name (length desktop))))
          (setq result
                (append result
                        (list (list name (file-name-as-directory
                                          (expand-file-name label (expand-file-name ".claude/worktrees/" root)))
                                    label)))))))
    result))

(defun agent-claude--history-items (dirs &optional limit)
  "Return the newest LIMIT (default 50) sessions filed in DIRS.
DIRS is a list of (DIRECTORY ROOT LABEL), as from
`agent-claude--history-dirs' but with full directory names.  Sessions
of a worktree (non-nil LABEL) carry :root ROOT and :worktree LABEL."
  (let* ((mtime (lambda (file)
                  (float-time (file-attribute-modification-time (file-attributes file)))))
         (files (mapcan (lambda (dir)
                          (and (file-directory-p (car dir))
                               (mapcar (lambda (file) (cons (funcall mtime file) (cons file (cdr dir))))
                                       (directory-files (car dir) t "\\.jsonl\\'"))))
                        dirs))
         (files (seq-take (sort files :key #'car :reverse t :in-place t) (or limit 50))))
    (mapcar (pcase-lambda (`(,time ,file ,root ,label))
              (append (list :id (file-name-base file)
                            :title (car (split-string (string-trim (agent-claude--session-title file))
                                                      "\n"))
                            :time time)
                      (and label (list :root root :worktree label))))
            files)))

(cl-defmethod agent-session-backend-history ((_ (eql claude)) root callback)
  (if (file-remote-p root)
      (funcall callback (agent-claude--history-items
                         (list (list (agent-claude--project-dir root) root nil))))
    (agent-session-worktrees
     root
     (lambda (dirs)
       (let* ((projects (expand-file-name "~/.claude/projects/"))
              (names (and (file-directory-p projects) (directory-files projects))))
         (funcall callback
                  (agent-claude--history-items
                   (mapcar (lambda (dir) (cons (expand-file-name (car dir) projects) (cdr dir)))
                           (agent-claude--history-dirs dirs names)))))))))

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

;;; Resumed sessions: the latest turns, earlier ones on request
;;
;; A long session's transcript runs to tens of megabytes, mostly bookkeeping
;; the display doesn't use (API requests, thinking, full tool results), and
;; for a remote project it is on the host.  Reading it in Emacs froze it for
;; seconds.  A python3 script reads it in the background instead, where the
;; file is, and prints only the last turns and the fields shown.

(defcustom agent-claude-history-turns 20
  "Turns of a resumed session shown at first; earlier ones load on request."
  :type 'integer)

(defconst agent-claude--python-lib "\
import json, os, select, sys, time

KEEP = {'text': ('text',), 'tool_use': ('id', 'name', 'input'),
        'tool_result': ('tool_use_id', 'is_error', 'content')}

def prompt(e):
    # Same test as agent-claude--user-text.
    if e.get('type') != 'user' or e.get('isMeta') or e.get('isSidechain'):
        return False
    c = (e.get('message') or {}).get('content')
    if isinstance(c, list):
        if not c or not all(isinstance(p, dict) and p.get('type') in ('text', 'image')
                            for p in c):
            return False
        c = '\\n'.join('[' if p['type'] == 'image' else p.get('text') or '' for p in c)
    return isinstance(c, str) and not c.lstrip().startswith('<')

def part(p):
    # Parts not shown stay as stubs, so the indices of the others are kept.
    t = p.get('type') if isinstance(p, dict) else None
    return dict({'type': t}, **{k: p[k] for k in KEEP.get(t, ()) if k in p})

def project(e):
    t = e.get('type')
    if e.get('isSidechain'):
        return None
    if t == 'attachment':
        a = e.get('attachment') or {}
        if a.get('type') != 'queued_command':
            return None
        return {'type': t, 'uuid': e.get('uuid'),
                'attachment': {'type': a['type'], 'prompt': a.get('prompt')}}
    if t not in ('user', 'assistant'):
        return None
    c = (e.get('message') or {}).get('content')
    if isinstance(c, list):
        c = [part(p) for p in c]
    return {'type': t, 'uuid': e.get('uuid'), 'isMeta': e.get('isMeta'),
            'message': {'content': c}}

def emit(o):
    try:
        data = json.dumps(o, ensure_ascii=False).encode('utf-8')
    except UnicodeEncodeError:
        data = json.dumps(o).encode()
    sys.stdout.buffer.write(data + b'\\n')

def load(line):
    try:
        e = json.loads(line)
    except ValueError:
        return None
    return e if isinstance(e, dict) else None
"
  "Python shared by the transcript scripts.
Its project() keeps only the fields of an entry that
`agent-claude--render-entry' uses.")

(defconst agent-claude--history-script "\
path = os.path.expanduser(sys.argv[1])
turns, stop = int(sys.argv[2]), int(sys.argv[3])
starts, end = [], 0
try:
    f = open(path, 'rb')
except OSError:
    f = None
if f is None:
    emit({'start': 0, 'end': 0})
else:
    with f:
        # An unfinished last line is left for syncing.
        for line in f:
            if not line.endswith(b'\\n') or 0 <= stop < end + len(line):
                break
            if b'\"user\"' in line:
                e = load(line)
                if e and prompt(e):
                    starts.append(end)
            end += len(line)
        start = starts[-turns] if len(starts) > turns else 0
        emit({'start': start, 'end': end})
        f.seek(start)
        pos = start
        for line in f:
            if pos >= end:
                break
            pos += len(line)
            e = load(line)
            o = e and project(e)
            if o:
                emit(o)
"
  "Prints the last turns of a transcript: ARGV is FILE TURNS STOP.
STOP is the byte offset to read up to, -1 for the end.  The first line
is {start, end}, the byte range read, then come the entries.")

(defconst agent-claude--follow-script "\
path, offset, own = os.path.expanduser(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
while True:
    # Ends when Emacs closes the pipe or goes away.
    if select.select([0], [], [], 0.5)[0] and not os.read(0, 1024):
        break
    try:
        size = os.path.getsize(path)
    except OSError:
        continue
    if offset < 0 or size < offset:
        offset = size
    if size > offset:
        with open(path, 'rb') as f:
            f.seek(offset)
            data = f.read(size - offset)
        # An unfinished last line is read next time.
        for line in data.split(b'\\n')[:-1]:
            offset += len(line) + 1
            e = load(line)
            source = e and e.get('entrypoint')
            o = source and source != own and project(e)
            if o:
                o['entrypoint'] = source
                emit(o)
        emit({'synced': offset})
        sys.stdout.flush()
"
  "Follows a transcript: ARGV is FILE OFFSET OWN-ENTRYPOINT.
Polls FILE from byte OFFSET (-1 for its end) and prints the entries
written by other clients, then {synced} with the offset read up to.")

(defun agent-claude--python (session name script args &rest props)
  "Run python3 on SCRIPT with ARGS in SESSION's root and return the process.
For a remote project it runs on the host.  The script goes through stdin,
which stays open; PROPS are passed to `make-process'."
  (let* ((default-directory (agent-session-root session))
         (code (concat agent-claude--python-lib script))
         (process (apply #'make-process
                         :name name
                         :command (append (list "python3" "-c"
                                                "import sys; exec(sys.stdin.buffer.read(int(sys.argv.pop(1))))"
                                                (number-to-string (string-bytes code)))
                                          args)
                         :connection-type 'pipe
                         :coding 'utf-8-unix
                         :noquery t
                         :file-handler (and (file-remote-p default-directory) t)
                         props)))
    (process-send-string process code)
    process))

(defun agent-claude--parse-line (line)
  "Parse JSON LINE as a plist, or return nil."
  (ignore-errors
    (json-parse-string line :object-type 'plist :null-object nil :false-object nil)))

(defun agent-claude--parse-history ()
  "Parse the output of `agent-claude--history-script' in this buffer.
Return (ENTRIES START END), or nil if it is incomplete."
  (let* ((lines (split-string (buffer-string) "\n" t))
         (header (agent-claude--parse-line (car lines))))
    (when (natnump (plist-get header :end))
      (list (delq nil (mapcar #'agent-claude--parse-line (cdr lines)))
            (plist-get header :start) (plist-get header :end)))))

(defun agent-claude--read-history (session stop callback)
  "Read the latest turns of SESSION's transcript before byte STOP.
STOP nil reads to the end.  Read in the background, then call CALLBACK
with (ENTRIES START END) as from `agent-claude--parse-history', or with
nil after showing why it failed."
  (let ((file (agent-claude--transcript session)))
    (if (and (not (file-remote-p (agent-session-root session)))
             (not (executable-find "python3")))
        ;; Without python3 read it all here, as before.
        (funcall callback (if (file-exists-p file)
                              (pcase-let ((`(,entries . ,end) (agent-claude--read-entries file 0)))
                                (list entries 0 end))
                            (list nil 0 0)))
      (let ((output (generate-new-buffer " *claude-history*"))
            (stderr (generate-new-buffer " *claude-history-stderr*")))
        (agent-claude--python
         session "claude-history" agent-claude--history-script
         (list (file-local-name file) (number-to-string agent-claude-history-turns)
               (number-to-string (or stop -1)))
         :buffer output
         :stderr stderr
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (let ((result (and (eq (process-status process) 'exit)
                                (zerop (process-exit-status process))
                                (with-current-buffer output
                                  (agent-claude--parse-history)))))
               (unless result
                 (agent-session-notice
                  session (format "载入历史记录失败：%s"
                                  (string-trim (with-current-buffer stderr (buffer-string))))
                  'agent-session-error))
               (kill-buffer output)
               (kill-buffer stderr)
               (when (buffer-live-p (agent-session-buffer session))
                 (funcall callback result))))))))))

(defun agent-claude--block-after (session id)
  "Return the ID of the block right after block ID in SESSION, or nil."
  (when-let* ((block (agent-session--block session id)))
    (let ((pos (1+ (plist-get block :end))) found)
      (maphash (lambda (key other) (when (= (plist-get other :start) pos) (setq found key)))
               (agent-session-blocks session))
      found)))

(defun agent-claude--history-line (session)
  "Redraw the line above the history of SESSION.
It says history is loading, offers the earlier turns, or goes away once
everything is shown."
  (let ((start (agent-claude--state session :history-start)))
    (cond ((agent-claude--state session :history-busy)
           (agent-session--update session "history" :type 'notice :face nil
                                  :text "正在载入历史记录…"))
          ((and start (> start 0))
           (agent-session--update
            session "history" :type 'notice :face 'agent-session-run-button
            :text (make-text-button
                   (format "▲ 载入更早的 %d 个回合" agent-claude-history-turns) nil
                   'follow-link t 'help-echo "载入更早的历史记录"
                   'action (lambda (_) (agent-claude--show-history
                                        session (agent-claude--state session :history-start))))))
          (t (agent-session--remove-block session "history")))))

(defun agent-claude--show-history (session &optional stop)
  "Show the latest turns of SESSION's transcript before byte STOP.
Without STOP this is the replay of a resumed session; with it, earlier
turns are added above those shown."
  (unless (agent-claude--state session :history-busy)
    (agent-claude--set session :history-busy t)
    (agent-claude--history-line session)
    (agent-claude--read-history
     session stop
     (lambda (result)
       (agent-claude--set session :history-busy nil)
       (pcase-let ((`(,entries ,start ,end) result))
         (when result
           (agent-session-call-before-block
            session (agent-claude--block-after session "history")
            (lambda ()
              (dolist (entry entries)
                (agent-claude--render-entry session entry))
              (unless stop (agent-session-notice session "—— 以上为历史记录 ——"))))
           (agent-claude--set session :history-start start)
           ;; A running turn is folded when it ends, with the others.
           (unless (eq (agent-session-status session) 'running)
             (agent-session--fold-turns session)))
         (agent-claude--history-line session)
         (unless stop
           ;; Watch from where the history ends, showing what other clients
           ;; wrote meanwhile.  Following a remote transcript starts there.
           (agent-claude--set session :sync-offset end)
           (agent-claude--watch session)
           (unless (file-remote-p (agent-session-root session))
             (agent-claude--sync session))))))))

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

(defconst agent-claude--sync-delay 0.5
  "Seconds to gather transcript changes before reading them.
The CLI writes a line per message, often several at once; each read is a
round trip for a remote project.")

(defun agent-claude--sync-soon (session)
  "Sync SESSION after `agent-claude--sync-delay', once for a burst of writes."
  (unless (timerp (agent-claude--state session :sync-timer))
    (agent-claude--set session :sync-timer
                       (run-with-timer agent-claude--sync-delay nil
                                       (lambda ()
                                         (agent-claude--set session :sync-timer nil)
                                         (when (buffer-live-p (agent-session-buffer session))
                                           (agent-claude--sync session)))))))

(defun agent-claude--follow (session)
  "Follow SESSION's remote transcript with a script on its host.
It passes on only what other clients write, so Emacs makes no round
trips for the lines its own CLI writes, nor to set up a file watch."
  (let ((pending ""))
    (agent-claude--set
     session :watch
     (agent-claude--python
      session "claude-follow" agent-claude--follow-script
      (list (file-local-name (agent-claude--transcript session))
            (number-to-string (or (agent-claude--state session :sync-offset) -1))
            agent-claude--own-entrypoint)
      :filter (lambda (_process output)
                (setq pending (concat pending output))
                (let ((lines (split-string pending "\n")))
                  (setq pending (car (last lines)))
                  (when (buffer-live-p (agent-session-buffer session))
                    (agent-claude--show-synced
                     session (delq nil (mapcar #'agent-claude--parse-line (butlast lines)))))))
      :sentinel #'ignore))
    ;; Remote file-notify descriptors are processes too.
    (process-put (agent-claude--state session :watch) 'agent-claude-follow t)))

(defun agent-claude--watch (session)
  "Start watching SESSION's transcript file.
Do nothing if it is already watched or the file doesn't exist yet.  A
loading history starts the watch itself once it knows where it ends."
  (let ((file (and (not (agent-claude--state session :watch))
                   (not (agent-claude--state session :history-busy))
                   (agent-claude--transcript session))))
    (cond
     ((null file))
     ((file-remote-p file) (agent-claude--follow session))
     ((and (file-exists-p file) (require 'filenotify nil t))
      (unless (agent-claude--state session :sync-offset)
        (agent-claude--set session :sync-offset (file-attribute-size (file-attributes file))))
      (agent-claude--set session :watch
                         (ignore-errors
                           (file-notify-add-watch
                            file '(change)
                            (lambda (event)
                              (when (and (eq (nth 1 event) 'changed)
                                         (buffer-live-p (agent-session-buffer session)))
                                (agent-claude--sync-soon session))))))))))

(defun agent-claude--unwatch (session)
  "Stop watching SESSION's transcript file."
  (when-let* ((watch (agent-claude--state session :watch)))
    (if (and (processp watch) (process-get watch 'agent-claude-follow))
        (delete-process watch)
      (file-notify-rm-watch watch))
    (agent-claude--set session :watch nil)))

(defun agent-claude--show-synced (session entries)
  "Show the ENTRIES of SESSION's transcript written by other clients.
An entry with :synced, from `agent-claude--follow-script', is the
offset read up to."
  (dolist (entry entries)
    (let ((source (plist-get entry :entrypoint)))
      (cond
       ((plist-get entry :synced)
        (agent-claude--set session :sync-offset (plist-get entry :synced)))
       ((and source (not (equal source agent-claude--own-entrypoint)))
        (unless (equal source (agent-claude--state session :sync-source))
          (agent-claude--set session :sync-source source)
          (agent-session-notice session (format "以下来自 %s"
                                                (agent-claude--source-name source))))
        (agent-claude--render-entry session entry)
        ;; Another client advanced the conversation; our context is now stale.
        (when (member (plist-get entry :type) '("user" "assistant"))
          (agent-claude--set session :external t)))))))

(defun agent-claude--sync (session)
  "Display messages newly written to SESSION's transcript by other clients."
  (let ((file (agent-claude--transcript session))
        (offset (agent-claude--state session :sync-offset)))
    (when (and file offset)
      (pcase-let ((`(,entries . ,end) (or (ignore-error file-error
                                            (agent-claude--read-entries file offset))
                                          (cons nil offset))))
        (agent-claude--set session :sync-offset end)
        (agent-claude--show-synced session entries)))))

(cl-defmethod agent-session-backend-start ((_ (eql claude)) session)
  ;; Load the history after starting the CLI: for a remote project both go
  ;; through one connection, and starting the CLI behind the history's
  ;; output kept Emacs waiting for a second.
  (let ((replay (and (agent-claude--state session :resume)
                     (zerop (hash-table-count (agent-session-blocks session))))))
    (agent-session-start-process session (agent-claude--command session))
    (when replay (agent-claude--show-history session)))
  (agent-claude--watch session)
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

(cl-defmethod agent-session-backend-reattached ((_ (eql claude)) session)
  ;; The follow script on the host went down with the connection.  It
  ;; resumes from the offset it last reported and skips our CLI's entries.
  (agent-claude--unwatch session)
  (agent-claude--watch session))

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
    (cond
     ;; Without a saved transcript a restart would lose the conversation.
     ((agent-session-child-p session)
      (agent-session-notice session "子会话不保存记录，不能重启来改推理强度"
                            'agent-session-error))
     ((eq (agent-session-status session) 'running)
      (agent-claude--set session :restart-pending t)
      (agent-session-notice session "推理强度将在本回合结束后生效"))
     (t (agent-session-restart-process session)))))

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
    ;; The CLI may carry on with the conversation's totals, theirs included.
    (agent-usage-forget-totals session)
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
      ("AskUserQuestion"
       (list :kind 'question
             :title (or (plist-get input :title)
                        (plist-get (seq-first (plist-get input :questions)) :question)
                        "提问")))
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

(defun agent-claude--model-usage (session result)
  "Record what the turn ending with RESULT used, per model.
Its modelUsage holds running totals: since the process started, or
carried on from those a resumed conversation restored.  When what is new
can't be told from them (see `agent-usage-totals'), only the turn's own
usage is recorded, under the session's model."
  (let* ((usage (plist-get result :usage))
         (turn (list :input (plist-get usage :input_tokens)
                     :cache-read (plist-get usage :cache_read_input_tokens)
                     :cache-write (plist-get usage :cache_creation_input_tokens)
                     :output (plist-get usage :output_tokens)))
         (totals (cl-loop for (key model-usage) on (plist-get result :modelUsage) by #'cddr
                          collect (cons (substring (symbol-name key) 1)
                                        (list :input (plist-get model-usage :inputTokens)
                                              :cache-read (plist-get model-usage :cacheReadInputTokens)
                                              :cache-write (plist-get model-usage :cacheCreationInputTokens)
                                              :output (plist-get model-usage :outputTokens)))))
         (deltas (agent-usage-totals session totals turn))
         (model (plist-get (agent-session-info session) :model)))
    (if (eq deltas 'unknown)
        (apply #'agent-usage-record session :model (or model (caar totals)) turn)
      ;; The session's model counts the turn, not a helper model it used.
      (let ((main (or (assoc model deltas) (car deltas))))
        (pcase-dolist (`(,name . ,delta) deltas)
          (apply #'agent-usage-record session :model name
                 :turns (if (eq (assoc name deltas) main) 1 0)
                 delta))))))

;; emx polls the account's rate limits with the CLI's /usage.
(setf (alist-get 'claude agent-usage-pollers) (lambda () (list agent-claude-executable)))

(defconst agent-claude--window-labels
  '(("five_hour" . "5h") ("seven_day" . "周")
    ("seven_day_opus" . "周·Opus") ("seven_day_sonnet" . "周·Sonnet"))
  "Labels of Claude's rate-limit windows.")

(defun agent-claude--rate-limit (session info)
  "Note the account's rate-limit windows from rate_limit_info INFO."
  (when-let* ((windows (plist-get info :unifiedWindows)))
    (agent-usage-set-quota
     session
     :windows (cl-loop for (key window) on windows by #'cddr
                       for id = (substring (symbol-name key) 1)
                       collect (list :id id
                                     :label (or (cdr (assoc id agent-claude--window-labels)) id)
                                     :minutes (if (string-prefix-p "five_hour" id) 300 10080)
                                     :used (plist-get window :utilization)
                                     :resets (plist-get window :resetsAt))))))

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

(defun agent-claude--questions (input)
  "The questions of AskUserQuestion INPUT, for `agent-session-ask-questions'.
Questions of kind \"text\" have no options; \"number\" ones have a range."
  (mapcar (lambda (question)
            (list :question (plist-get question :question)
                  :header (plist-get question :header)
                  :detail (plist-get question :description)
                  :options (mapcar (lambda (option)
                                     (cons (plist-get option :label) (plist-get option :description)))
                                   (plist-get question :options))
                  :multi (plist-get question :multiSelect)
                  :other t
                  :range (when (equal (plist-get question :kind) "number")
                           (list (plist-get question :min) (plist-get question :max)
                                 (plist-get question :unit)))))
          (plist-get input :questions)))

(defun agent-claude--answers (questions answers)
  "The `answers' field of AskUserQuestion: question text -> answer.
QUESTIONS and ANSWERS are as given to and returned by
`agent-session-ask-questions'.  Skipped questions are left out; a multiple
choice answer is an array, which the CLI joins."
  (let ((table (make-hash-table :test #'equal)))
    (cl-mapc (lambda (question answer)
               (when answer
                 (let ((values (append (plist-get answer :selected)
                                       (when-let* ((custom (plist-get answer :custom)))
                                         (list custom)))))
                   (puthash (plist-get question :question)
                            (if (plist-get question :multi) (vconcat values) (car values))
                            table))))
             questions answers)
    table))

(defun agent-claude--ask-user-question (session request-id request)
  "Answer the permission REQUEST (id REQUEST-ID) for AskUserQuestion.
The user answers in the footer of SESSION; the answers go back to the CLI
as the tool's input, beside the questions it showed."
  (let* ((tool-id (plist-get request :tool_use_id))
         (questions (agent-claude--questions (plist-get request :input)))
         ;; The CLI refuses an input whose shown fields changed: add to the
         ;; original JSON only.
         (raw-input (agent-session-raw-json "request" "input")))
    (agent-session-ask-questions
     session
     :questions questions
     :tool tool-id
     :callback
     (lambda (answers)
       (agent-session-write
        session
        (list :type "control_response"
              :response
              (list :subtype "success" :request_id request-id
                    :response
                    (if (eq answers 'cancel)
                        (progn
                          (agent-claude--set session :declined
                                             (cons tool-id (agent-claude--state session :declined)))
                          (list :behavior "deny"
                                :message "The user declined to answer these questions."))
                      (let ((input (if (hash-table-p raw-input)
                                       (copy-hash-table raw-input)
                                     (make-hash-table :test #'equal))))
                        (puthash "answers" (agent-claude--answers questions answers) input)
                        (list :behavior "allow" :updatedInput input))))))))))

(defun agent-claude--permission (session request-id request)
  "Handle permission REQUEST with id REQUEST-ID.
Ask the user in SESSION, then reply to the CLI."
  (if (equal (plist-get request :tool_name) "AskUserQuestion")
      (agent-claude--ask-user-question session request-id request)
    (agent-claude--ask-permission session request-id request)))

(defun agent-claude--ask-permission (session request-id request)
  "Ask the user in SESSION whether to allow REQUEST with id REQUEST-ID."
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
      ("rate_limit_event" (agent-claude--rate-limit session (plist-get message :rate_limit_info)))
      ("result"
       (agent-claude--model-usage session message)
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

(cl-defmethod agent-session-backend-fork-p ((_ (eql claude)))
  t)

(agent-session-define-agent claude :title "Claude" :executable agent-claude-executable)

(provide 'agent-claude)
;;; agent-claude.el ends here
