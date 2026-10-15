;;; agent-session.el --- Agent sessions rendered by Emacs itself -*- lexical-binding: t; -*-

;;; Commentary:

;; The agent CLI runs as a background process (Claude: stream-json, Codex:
;; app-server), and the conversation is rendered here into an Emacs buffer:
;; a read-only transcript on top, an input area below.
;;
;; Layers:
;;   - This file: session management, UI, input; exposes a "UI API" to backends
;;     (agent-session-text, agent-session-tool, agent-session-ask ...) and does
;;     not care about the concrete protocol.
;;   - Backends (agent-claude.el, agent-codex.el): implement the
;;     agent-session-backend-* generic functions, translating their protocol's
;;     messages into UI API calls.
;;
;; To add an agent: implement a backend, then register it with
;; `agent-session-define-agent'.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'project)
(require 'server)
(require 'button)
(require 'dnd)
(require 'ansi-color)

;; Bound dynamically in a let so rendering code blocks doesn't prompt to install
;; tree-sitter grammars.
(defvar treesit-auto-install-grammar)
(declare-function evil-insert-state "evil-states")
(require 'transient)

(defgroup agent-session nil
  "Agent sessions rendered by Emacs."
  :group 'tools
  :prefix "agent-session-")

(defcustom agent-session-window-width 0.42
  "Width of the session window; a fraction means a ratio of the frame width."
  :type 'number)

(defcustom agent-session-bin-directory (expand-file-name "bin" user-emacs-directory)
  "Directory prepended to the background process's PATH; it holds emx."
  :type 'directory)

(defcustom agent-session-output-lines 20
  "Maximum lines of tool output shown when expanded (the tail is shown)."
  :type 'integer)

;;; Faces

(defface agent-session-user '((t :inherit (bold font-lock-keyword-face)))
  "User message heading.")
(defface agent-session-assistant '((t :inherit (bold font-lock-function-name-face)))
  "Agent message heading.")
(defface agent-session-thinking '((t :inherit (italic shadow)))
  "Thinking process.")
(defface agent-session-tool '((t :inherit font-lock-type-face))
  "Tool call heading.")
(defface agent-session-dim '((t :inherit shadow))
  "Secondary information.")
(defface agent-session-ok '((t :inherit success))
  "Success status.")
(defface agent-session-error '((t :inherit error))
  "Failure status.")
(defface agent-session-ask '((t :inherit (bold warning)))
  "Awaiting user confirmation.")
(defface agent-session-button
  '((t :inherit (mode-line-inactive bold)
       :box (:line-width (6 . 2) :style released-button)))
  "Button.")

;;; Session object

(cl-defstruct (agent-session (:constructor agent-session--make))
  agent          ; registered name, e.g. claude
  backend        ; backend symbol, used for generic dispatch
  root           ; project root directory
  buffer
  process
  (status 'starting)   ; starting / idle / running / exited
  info           ; info plist shown in the header line: :model :tokens :cost ...
  state          ; backend-private state plist
  (blocks (make-hash-table :test #'equal))
  tail           ; end of the transcript (where new blocks are inserted)
  input          ; start of the input area (after the footer)
  asks           ; confirmation requests (in order), shown in the footer, not transcript
  queue          ; messages typed while running, sent one by one after the turn ends
  history
  settings)      ; user choices: :model :effort :mode (nil means the agent's default)

(defvar-local agent-session--current nil "The session object of this buffer.")
(put 'agent-session--current 'permanent-local t)

(defvar agent-session-agents nil
  "Registered agents: ((NAME . PLIST) ...).
PLIST supports :backend :title :key.")

(defun agent-session--get (agent prop)
  "Return property PROP of the registered AGENT."
  (plist-get (alist-get agent agent-session-agents) prop))

(defun agent-session-display-title (session)
  "Title of SESSION: the one carried over on resume, else the first message."
  (or (plist-get (agent-session-info session) :title) "新会话"))

(defun agent-session--title-seed (text)
  "Make a title from user message TEXT.
Collapse whitespace and keep the first 50 characters (images show as the
text [图片])."
  (let ((text (string-trim (replace-regexp-in-string "[ \t\n]+" " "
                                                     (substring-no-properties text)))))
    (if (> (length text) 50) (concat (substring text 0 50) "…") text)))

(defun agent-session-resume-id (session)
  "The agent-native session id of SESSION, possibly nil.
That is the Claude session id or the Codex thread id."
  (and session (plist-get (agent-session-state session) :resume)))

(defun agent-session-title (session)
  "Display name of SESSION, e.g. Claude."
  (or (agent-session--get (agent-session-agent session) :title)
      (symbol-name (agent-session-agent session))))

;;; Handles: short names to mention sessions with, e.g. @cfi-meaning

(defun agent-session-handle (session)
  "Handle of SESSION, a short unique name without the @."
  (plist-get (agent-session-info session) :handle))

(defun agent-session--unique-handle (base &optional except)
  "BASE, or BASE-N if another live session than EXCEPT already uses it."
  (let ((taken (delq nil (mapcar (lambda (buffer)
                                   (let ((session (buffer-local-value 'agent-session--current
                                                                      buffer)))
                                     (unless (eq session except)
                                       (agent-session-handle session))))
                                 (agent-session-buffers))))
        (handle base)
        (n 1))
    (while (member handle taken)
      (setq handle (format "%s-%d" base (cl-incf n))))
    handle))

(defun agent-session-set-handle (session base)
  "Name SESSION after BASE (made unique) and return the handle."
  (let ((handle (agent-session--unique-handle base session)))
    (setf (agent-session-info session) (plist-put (agent-session-info session) :handle handle))
    (agent-session--refresh session)
    handle))

(defun agent-session-find (name)
  "The live session called NAME: a handle (with or without @) or a buffer name."
  (let ((handle (string-remove-prefix "@" name)))
    (seq-some (lambda (buffer)
                (let ((session (buffer-local-value 'agent-session--current buffer)))
                  (and (or (equal handle (agent-session-handle session))
                           (equal name (buffer-name buffer)))
                       session)))
              (agent-session-buffers))))

(defun agent-session-parent (session)
  "The live session that started SESSION through another agent, or nil."
  (when-let* ((buffer (plist-get (agent-session-info session) :parent))
              ((agent-session-buffer-p buffer)))
    (buffer-local-value 'agent-session--current buffer)))

;;; Backend interface

(cl-defgeneric agent-session-backend-start (backend session)
  "Start the background process of SESSION.  BACKEND is the backend symbol.")

(cl-defgeneric agent-session-backend-send (backend session text)
  "Send user message TEXT to the agent.")

(cl-defgeneric agent-session-backend-interrupt (backend session)
  "Interrupt the current turn.")

(cl-defgeneric agent-session-backend-handle (backend session message)
  "Handle one JSON MESSAGE (a plist) output by the background process.")

(cl-defgeneric agent-session-backend-stop (backend session)
  "End the session.  By default just kill the process."
  (ignore backend)
  (when-let* ((process (agent-session-process session)))
    ;; Detach first, so the old process's sentinel ignores this exit.
    (setf (agent-session-process session) nil)
    (when (process-live-p process) (delete-process process))))

(cl-defgeneric agent-session-backend-models (backend session)
  "Available models.
A list of (:id ID :name NAME :description DESC :efforts (EFFORT...)
:default-effort E)."
  (ignore backend session)
  nil)

(cl-defgeneric agent-session-backend-modes (backend session)
  "Supported permission modes (keys of `agent-session-modes')."
  (ignore backend session)
  '(ask edits full))

(cl-defgeneric agent-session-backend-commands (backend session)
  "Slash commands offered by the agent: ((:name N :description D :hint H) ...)."
  (ignore backend session)
  nil)

(cl-defgeneric agent-session-backend-apply-settings (backend session changed)
  "Apply changed settings.  CHANGED is the list of changed keys.
The keys are among :model :effort :mode."
  (ignore backend session changed))

(cl-defgeneric agent-session-backend-steer (backend session text)
  "Feed user message TEXT into the ongoing turn (steering).
Return non-nil if supported.  Unsupported by default, in which case the
caller falls back to \"interrupt, then send\"."
  (ignore backend session text)
  nil)

(cl-defgeneric agent-session-backend-history (backend root callback)
  "List past sessions in project ROOT, calling CALLBACK with the list.
CALLBACK may be called asynchronously.  Each item is (:id ID :title TITLE
:time SECONDS), newest first."
  (ignore backend root)
  (funcall callback nil))

;;; Settings: model, reasoning effort, permission mode

(defconst agent-session-modes
  '((ask "需确认" "命令和文件改动都需要确认")
    (edits "自动接受编辑" "文件改动自动通过，其他操作仍需确认")
    (auto "自动审查" "由 agent 的自动审查放行常规操作，其余询问")
    (full "完全访问" "命令和改动都不再询问")
    (plan "计划" "只读规划，不做改动"))
  "Unified permission modes (after T3 Code), mapped by each backend.")

(defcustom agent-session-default-mode 'auto
  "Default permission mode for new sessions.
The default is “自动审查” (auto review): the agent's auto review lets
routine operations through and only asks when the risk is higher (same as
auto mode in the Claude Code desktop app)."
  :type '(choice (const ask) (const edits) (const auto) (const full)))

(defvar agent-session-default-agent nil
  "Agent used by default for new sessions: the most recently used one.")

(defvar agent-session-last-settings nil
  "Latest settings per agent: ((AGENT . PLIST) ...); new sessions reuse them.")
(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'agent-session-last-settings)
  (add-to-list 'savehist-additional-variables 'agent-session-default-agent))

(defun agent-session-setting (session key)
  "Setting KEY of SESSION; the mode falls back to the default mode."
  (or (plist-get (agent-session-settings session) key)
      (and (eq key :mode) agent-session-default-mode)))

(defun agent-session-configure (session &rest props)
  "Change settings of SESSION (:model :effort :mode) and apply them."
  (let (changed)
    (cl-loop for (key value) on props by #'cddr
             unless (equal value (agent-session-setting session key))
             do (push key changed)
                (setf (agent-session-settings session)
                      (plist-put (agent-session-settings session) key value)))
    (when changed
      (setf (alist-get (agent-session-agent session) agent-session-last-settings)
            (agent-session-settings session))
      (agent-session-backend-apply-settings (agent-session-backend session) session changed)
      (agent-session--refresh session))
    changed))

(defun agent-session-model-info (session &optional model)
  "Info plist of model MODEL (default the current model) in SESSION."
  (let ((models (agent-session-backend-models (agent-session-backend session) session))
        (model (or model (agent-session-setting session :model))))
    (or (seq-find (lambda (m) (equal (plist-get m :id) model)) models)
        (car models))))

(defun agent-session-restart-process (session)
  "Restart the background process of SESSION.
E.g. to switch settings that can only be given at startup."
  (agent-session-backend-stop (agent-session-backend session) session)
  (setf (agent-session-status session) 'starting)
  (agent-session-backend-start (agent-session-backend session) session))

;;; Background process

(defun agent-session-environment (session)
  "Environment of the background process: it can find emx and reach this Emacs."
  (append
   (list (concat "PATH=" agent-session-bin-directory path-separator (getenv "PATH"))
         (concat "EMACS_SOCKET_NAME=" (expand-file-name server-name server-socket-dir))
         (concat "EMX_AGENT_BUFFER=" (buffer-name (agent-session-buffer session))))
   process-environment))

(defun agent-session-emx-command ()
  "Command line that starts the emx MCP server."
  (list (expand-file-name "emx" agent-session-bin-directory) "mcp"))

(defun agent-session-process-directory (root)
  "Project ROOT as the agent process sees it.
Agents of a remote project run on its host, so that is the host's path."
  (or (file-remote-p root 'localname) (expand-file-name root)))

(defun agent-session-expand-file-name (path root)
  "PATH reported by the agent of project ROOT, as an Emacs file name.
Relative paths are relative to ROOT; absolute paths from an agent of a
remote project live on its host."
  (if (and (file-remote-p root) (file-name-absolute-p path) (not (file-remote-p path)))
      (concat (file-remote-p root) path)
    (expand-file-name path root)))

(defun agent-session-start-process (session command)
  "Start the background process of SESSION with COMMAND.
Each JSON line is handed to the backend.  For a remote project the
process runs on its host through the file handler (tramp-rpc), where
the project, its toolchain and the agent's own history live."
  (let* ((buffer (agent-session-buffer session))
         (default-directory (agent-session-root session))
         (remote (file-remote-p default-directory))
         ;; The local PATH and emx variables mean nothing on the host (tramp
         ;; forwards changed variables); a remote agent reaches emx through
         ;; the bridge of agent-remote.el instead.
         (process-environment (if remote
                                  process-environment
                                (agent-session-environment session)))
         (pending "")
         (process
          (make-process
           :name (format "agent-%s" (agent-session-agent session))
           :command command
           :connection-type 'pipe
           :coding 'utf-8-unix
           :noquery t
           :file-handler (and remote t)
           :stderr (get-buffer-create (format " *%s stderr*" (buffer-name buffer)))
           :filter
           (lambda (_process output)
             (setq pending (concat pending output))
             (let ((lines (split-string pending "\n")))
               (setq pending (car (last lines)))
               (dolist (line (butlast lines))
                 (unless (string-blank-p line)
                   (agent-session--dispatch session line)))))
           :sentinel
           (lambda (process _event)
             (unless (process-live-p process)
               ;; A process that was replaced or stopped on purpose isn't an
               ;; unexpected exit.
               (when (and (buffer-live-p buffer) (eq process (agent-session-process session)))
                 (agent-session-set-status session 'exited)
                 (agent-session-notice
                  session (format "进程已退出（%s，退出码 %s）"
                                  (process-status process) (process-exit-status process))
                  'agent-session-error)))))))
    (setf (agent-session-process session) process)))

(defvar agent-session-raw-message nil
  "Raw JSON line of the message being handled.
Parsing into a plist loses the difference between false / null / {}; when
data must be sent back to the agent verbatim, re-parse it from here with
`agent-session-raw-json'.")

(defun agent-session-raw-json (&rest path)
  "Get the value at key PATH from the current raw message.
JSON false / null / empty objects are preserved."
  (let ((value (json-parse-string agent-session-raw-message :object-type 'hash-table
                                  :null-object :null :false-object :false)))
    (dolist (key path value)
      (setq value (and (hash-table-p value) (gethash key value))))))

(defun agent-session--dispatch (session line)
  "Parse one JSON LINE and hand it to the backend.
Errors are recorded in the session without interrupting the process."
  (when (buffer-live-p (agent-session-buffer session))
    (condition-case err
        (let ((agent-session-raw-message line))
          (agent-session-backend-handle
         (agent-session-backend session) session
           (json-parse-string line :object-type 'plist :null-object nil :false-object nil)))
      (error
       (agent-session-notice session (truncate-string-to-width
                                      (format "处理消息出错：%s" (error-message-string err)) 200 nil nil "…")
                             'agent-session-error)))))

(defun agent-session-write (session object)
  "Serialize OBJECT as one JSON line and write it to the background process."
  (let ((process (agent-session-process session)))
    (unless (process-live-p process) (user-error "agent 进程未运行"))
    (process-send-string process (concat (json-serialize object :null-object :null :false-object :false)
                                         "\n"))))

;;; Transcript: inserting and redrawing blocks

(defvar-keymap agent-session-transcript-map
  :doc "Keys on the transcript and footer: typing jumps to the input area."
  :parent button-map
  "RET" #'agent-session-ret
  "<remap> <self-insert-command>" #'agent-session-self-insert-to-input)

(defun agent-session--ro (string)
  "Mark STRING as transcript: read-only, typing jumps to the input area."
  (propertize string 'read-only t 'front-sticky '(read-only) 'rear-nonsticky t
              'keymap agent-session-transcript-map))

(defmacro agent-session--with-buffer (session &rest body)
  "Run BODY in the buffer of SESSION.
Modifying the read-only transcript is allowed, and each window's point is
preserved."
  (declare (indent 1))
  (let ((buffer (make-symbol "buffer")))
    `(let ((,buffer (agent-session-buffer ,session)))
       (when (buffer-live-p ,buffer)
         (with-current-buffer ,buffer
           (let ((inhibit-read-only t)
                 (inhibit-modification-hooks t))
             (save-excursion ,@body)))))))

(defun agent-session--block (session id)
  "Block data (a plist) for ID in SESSION, or nil if there is none."
  (gethash id (agent-session-blocks session)))

(defun agent-session--new-block (session id data)
  "Create block ID at the end of the transcript, rendered from DATA."
  (agent-session--with-buffer session
    (let ((tail (agent-session-tail session)))
      (goto-char tail)
      (let ((start (copy-marker (point)))
            (end (copy-marker (point))))
        (insert (agent-session--ro "\n"))
        ;; Neither start nor end moves on insertion; content is rendered between
        ;; them, and the trailing newline separates adjacent blocks.
        (puthash id (plist-put (plist-put data :start start) :end end)
                 (agent-session-blocks session))
        (agent-session--render session id)))))

(defun agent-session--render (session id)
  "Redraw block ID from its data."
  (let* ((block (agent-session--block session id))
         (start (plist-get block :start))
         (end (plist-get block :end))
         (buffer (agent-session-buffer session))
         ;; Windows whose point is inside the block: remember the offset and restore it
         ;; after redrawing, so point doesn't jump to the block start.
         (inside (and (buffer-live-p buffer)
                      (seq-keep (lambda (window)
                                  (let ((point (window-point window)))
                                    (and (< start point end) (cons window (- point start)))))
                                (get-buffer-window-list buffer nil t)))))
    (agent-session--with-buffer session
      (delete-region start end)
      (goto-char start)
      (insert (agent-session--ro (agent-session--format session id block)))
      (set-marker end (point)))
    (when inside
      (with-current-buffer buffer
        (pcase-dolist (`(,window . ,offset) inside)
          (set-window-point window (min (+ start offset) end)))))))

(defun agent-session--remove-block (session id)
  "Delete block ID from the transcript (along with its separating newline)."
  (when-let* ((block (agent-session--block session id)))
    (agent-session--with-buffer session
      (delete-region (plist-get block :start) (1+ (plist-get block :end))))
    (remhash id (agent-session-blocks session))))

(defun agent-session--update (session id &rest props)
  "Merge PROPS into block ID and redraw it; create the block if missing."
  (let ((block (agent-session--block session id)))
    (if (null block)
        (agent-session--new-block session id props)
      (cl-loop for (key value) on props by #'cddr
               do (setq block (plist-put block key value)))
      (puthash id block (agent-session-blocks session))
      (agent-session--render session id))))

(defun agent-session--format (session id block)
  "Render BLOCK into a string."
  (pcase (plist-get block :type)
    ('user (agent-session--format-user id block))
    ('text (agent-session--format-text session id block))
    ('tool (agent-session--format-tool id block))
    ('notice (concat (propertize (plist-get block :text)
                                 'face (or (plist-get block :face) 'agent-session-dim))
                     "\n"))))

;;; Markdown and code highlighting

(defun agent-session-fontify (text mode &optional keep-markup)
  "Highlight TEXT with major MODE and return a string with faces.
With KEEP-MARKUP, keep markdown-mode's markup hiding: `invisible' text
of the `markdown-markup' kind and string `display' replacements."
  (if (not (fboundp mode))
      text
    (with-temp-buffer
      (insert text)
      (let ((treesit-auto-install-grammar nil))
        (ignore-errors
          (delay-mode-hooks (funcall mode))
          (font-lock-ensure)))
      ;; Some modes use font-lock-face; convert it to face so display doesn't
      ;; depend on font-lock.
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((next (next-single-property-change pos 'font-lock-face nil (point-max)))
                (face (get-text-property pos 'font-lock-face)))
            (when face (put-text-property pos next 'face face))
            (setq pos next))))
      (remove-list-of-text-properties (point-min) (point-max)
                                      '(keymap local-map mouse-face help-echo))
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((next (next-property-change pos nil (point-max))))
            (unless (and keep-markup (eq (get-text-property pos 'invisible) 'markdown-markup))
              (remove-text-properties pos next '(invisible nil)))
            (unless (and keep-markup (stringp (get-text-property pos 'display)))
              (remove-text-properties pos next '(display nil)))
            (setq pos next))))
      (buffer-string))))

(defvar markdown-fontify-code-blocks-natively)
(defvar markdown-hide-markup)

(defun agent-session--markdown (text)
  "Highlight markdown TEXT (code blocks by their language) and hide its markup.
The markup stays in the text, hidden through the `markdown-markup'
invisibility spec of the session buffer."
  (if (require 'markdown-mode nil t)
      (let ((markdown-fontify-code-blocks-natively t)
            (markdown-hide-markup t))
        (agent-session--fence-labels (agent-session-fontify text 'gfm-mode t)))
    text))

(defun agent-session--fence-labels (text)
  "Show each opening code fence in TEXT as just its language, in place.
markdown-mode hides fence lines whole; keeping the opening line visible
gives the run buttons placed at its end a line of their own."
  (let ((start 0))
    (while (string-match "^[ \t]*\\(\\(?:`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*\\([^ \t\n`{]+\\)\\)[^\n]*$"
                         text start)
      (let ((fence (match-beginning 1))
            (fence-end (match-end 1))
            (lang (match-string 2 text))
            (eol (match-end 0)))
        (remove-text-properties fence (min (1+ eol) (length text)) '(invisible nil) text)
        (put-text-property fence fence-end 'display (propertize lang 'face 'agent-session-dim) text)
        (put-text-property fence-end eol 'invisible 'markdown-markup text)
        ;; Skip the block body and its closing fence.
        (setq start (if (string-match "^[ \t]*\\(?:`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*$" text eol)
                        (match-end 0)
                      (length text)))))
    text))

;;; Formats of each block type

(define-button-type 'agent-session-toggle
  'face nil 'follow-link t 'action #'agent-session--toggle-block
  'help-echo "折叠 / 展开")

(define-button-type 'agent-session-choice
  'face 'agent-session-button 'follow-link t)

(defun agent-session--indent (text)
  "Indent each line of TEXT by two spaces (via line-prefix, text unchanged)."
  (propertize text 'line-prefix "  " 'wrap-prefix "  "))

(define-button-type 'agent-session-fold
  'face nil 'follow-link t 'action #'agent-session--toggle-fold
  'help-echo "展开 / 收起这一回合的过程")

(defun agent-session--format-user (id block)
  "Format a user message.
When the turn is folded, a one-line summary of the process follows below
\(click to expand)."
  (let ((fold (plist-get block :fold)))
    (concat (propertize "▍ 你" 'face 'agent-session-user)
            (cond ((plist-get block :queued) (propertize "  排队中" 'face 'agent-session-dim))
                  ((plist-get block :steer) (propertize "  ↪ 引导" 'face 'agent-session-dim))
                  (t ""))
            "\n"
            (agent-session--indent (plist-get block :text))
            "\n"
            (when (consp fold)
              (concat "  "
                      (make-text-button
                       (concat (if (plist-get fold :collapsed) "▸ " "▾ ")
                               (propertize (plist-get fold :summary) 'face 'agent-session-dim))
                       nil 'type 'agent-session-fold 'agent-session-block id)
                      "\n")))))

(defun agent-session--format-text (session id block)
  "Format an agent reply or thinking.
A reply shows raw text while streaming and is rendered as markdown when
done; thinking is folded into one line by default, click to expand."
  (let ((text (string-trim-right (or (plist-get block :text) ""))))
    (if (eq (plist-get block :kind) 'thinking)
        (let ((collapsed (agent-session--collapsed-p block)))
          (concat
           (make-text-button
            (concat (if collapsed "▸ " "▾ ")
                    (propertize (if (plist-get block :done) "思考" "思考中…")
                                'face 'agent-session-dim))
            nil 'type 'agent-session-toggle 'agent-session-block id)
           "\n"
           (unless collapsed
             (concat (agent-session--indent (propertize text 'face 'agent-session-thinking)) "\n"))))
      (concat
       (propertize (concat "● " (agent-session-title session)) 'face 'agent-session-assistant)
       "\n"
       (if (plist-get block :done)
           (agent-session--format-reply session id block text)
         (agent-session--indent text))
       "\n"))))

;;; Running commands from replies
;;
;; Shell code blocks in replies (```bash etc.) get a run button after the opening
;; fence line.  Clicking it runs the block in the project root (on the remote host
;; for remote projects); status and output appear below the block, and the run can
;; be stopped or repeated.  Runs live in the block's :runs as ((INDEX . RUN) ...),
;; RUN being a plist (:command :process :output :start :end :exit :stopped :timer)
;; that is modified in place while the command runs.

(defcustom agent-session-runnable-languages
  '("bash" "sh" "shell" "zsh" "console" "shell-session")
  "Code block languages in replies that get a run button."
  :type '(repeat string))

(defcustom agent-session-run-output-lines 5
  "Maximum number of output lines shown below a code block (the tail)."
  :type 'integer)

(defface agent-session-run-output '((t :inherit default))
  "Command output shown below a code block.")

(defface agent-session-run-button '((t :inherit link :underline nil))
  "Run, stop and copy buttons of a code block.")

(defun agent-session--code-blocks (text)
  "Runnable fenced code blocks in TEXT: ((INDEX HEADER-END CLOSE-END CODE) ...).
HEADER-END is the end of the opening fence line and CLOSE-END the end of the
closing one, both as indices into TEXT."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let ((index 0) blocks)
      (while (re-search-forward
              "^\\([ \t]*\\)\\(`\\{3,\\}\\|~\\{3,\\}\\)[ \t]*\\([^ \t\n`{]*\\)[^\n]*$" nil t)
        (let* ((indent (match-string 1))
               (fence (match-string 2))
               (lang (downcase (match-string 3)))
               (header-end (point))
               (close (re-search-forward
                       (format "^[ \t]*%s%s*[ \t]*$" (regexp-quote fence)
                               (regexp-quote (substring fence 0 1)))
                       nil 'move)))
          (when (and close (member lang agent-session-runnable-languages))
            (let ((code (buffer-substring-no-properties
                         (min (1+ header-end) (match-beginning 0)) (match-beginning 0))))
              (push (list index (1- header-end) (1- close)
                          (agent-session--code-command code indent lang))
                    blocks)
              (cl-incf index)))))
      (nreverse blocks))))

(defun agent-session--code-command (code indent lang)
  "The command to run for code block contents CODE.
Strip the fence indentation INDENT; for console-like LANG keep only the
lines starting with $, without the prompt."
  (let* ((lines (mapcar (lambda (line) (string-remove-prefix indent line))
                        (split-string (string-trim-right code) "\n")))
         (prompts (and (member lang '("console" "shell-session"))
                       (seq-keep (lambda (line)
                                   (and (string-match "\\`\\$ ?" line)
                                        (substring line (match-end 0))))
                                 lines))))
    (string-join (or prompts lines) "\n")))

(defun agent-session--format-reply (session id block text)
  "Render a finished reply: markdown, plus run buttons and runs for code blocks.
The highlighted markdown is cached in BLOCK's :markdown so redraws during a
run don't highlight it again."
  (let* ((cache (plist-get block :markdown))
         (rendered (if (equal (car cache) text)
                       (cdr cache)
                     (let ((rendered (agent-session--markdown text)))
                       (puthash id (plist-put block :markdown (cons text rendered))
                                (agent-session-blocks session))
                       rendered)))
         (runs (plist-get block :runs))
         (pos 0)
         parts)
    (pcase-dolist (`(,index ,header-end ,close-end ,_command) (agent-session--code-blocks text))
      (let ((run (alist-get index runs)))
        (push (agent-session--indent (substring rendered pos header-end)) parts)
        (push (agent-session--run-buttons id index run) parts)
        (push (agent-session--indent (substring rendered header-end close-end)) parts)
        (when run (push (agent-session--format-run run) parts))
        (setq pos close-end)))
    (push (agent-session--indent (substring rendered pos)) parts)
    (apply #'concat (nreverse parts))))

(define-button-type 'agent-session-run
  'face 'agent-session-run-button 'follow-link t 'action #'agent-session--run-button)

(defun agent-session--run-button (button)
  "Run, stop or copy the code block command of BUTTON."
  (let ((session agent-session--current)
        (id (button-get button 'agent-session-block))
        (index (button-get button 'agent-session-code)))
    (pcase (button-get button 'agent-session-action)
      ('run (agent-session-run-code session id index))
      ('stop (agent-session-stop-code session id index))
      ('copy (kill-new (agent-session--code-command-at session id index))
             (message "已复制命令")))))

(defun agent-session--run-buttons (id index run)
  "Buttons after the opening fence line of code block INDEX."
  (cl-flet ((button (label action help)
              (concat "  " (make-text-button label nil 'type 'agent-session-run 'help-echo help
                                             'agent-session-action action
                                             'agent-session-block id 'agent-session-code index))))
    (concat (if (process-live-p (plist-get run :process))
                (button "■ 停止" 'stop "停止运行中的命令")
              (button (if run "↻ 重新运行" "▶ 运行") 'run "在项目根目录运行这段命令"))
            (button "⧉ 复制" 'copy "复制命令"))))

(defun agent-session--clean-output (output)
  "Clean command OUTPUT: drop ANSI escapes, keep each line's text after its
last carriage return (progress bars)."
  (mapconcat (lambda (line) (car (last (split-string line "\r" t))))
             (split-string (ansi-color-filter-apply output) "\n")
             "\n"))

(defun agent-session--format-run (run)
  "The record of RUN below a code block: a status line and the output tail."
  (let* ((end (or (plist-get run :end) (float-time)))
         (elapsed (format "%.1fs" (- end (plist-get run :start))))
         (exit (plist-get run :exit))
         (status
          (cond ((process-live-p (plist-get run :process))
                 (propertize "… 运行中" 'face 'agent-session-dim))
                ((plist-get run :stopped)
                 (propertize (concat "■ 已停止 · " elapsed) 'face 'agent-session-error))
                ((eql exit 0)
                 (propertize (concat "✓ 完成 · " elapsed) 'face 'agent-session-ok))
                (t (propertize (format "✗ 退出码 %s · %s" exit elapsed)
                               'face 'agent-session-error))))
         (output (string-trim-right (agent-session--clean-output (plist-get run :output)))))
    (concat
     "\n"
     (agent-session--indent status)
     (unless (string-empty-p output)
       (concat "\n"
               (propertize (agent-session--tail-lines output agent-session-run-output-lines)
                           'face 'agent-session-run-output
                           'line-prefix (propertize "  │ " 'face 'agent-session-dim)
                           'wrap-prefix (propertize "  │ " 'face 'agent-session-dim)))))))

(defun agent-session--code-command-at (session id index)
  "Command of the INDEXth runnable code block of message block ID in SESSION."
  (nth 3 (assq index (agent-session--code-blocks
                      (plist-get (agent-session--block session id) :text)))))

(defun agent-session--rerender-run (session id run)
  "Redraw block ID after RUN changed, at most once every 0.2 seconds."
  (unless (plist-get run :timer)
    (setf (plist-get run :timer)
          (run-at-time 0.2 nil (lambda ()
                                 (setf (plist-get run :timer) nil)
                                 (when (agent-session--block session id)
                                   (agent-session--render session id)))))))

(defun agent-session--run-command (command)
  "Process command line running shell COMMAND in `default-directory'.
Remote hosts start processes without a login environment, so tools
installed under the home directory (rustup, cargo) are not on PATH;
run COMMAND through the remote user's login shell instead."
  (if (file-remote-p default-directory)
      (list "/bin/sh" "-c" "exec \"${SHELL:-/bin/sh}\" -lc \"$1\"" "sh" command)
    (list shell-file-name shell-command-switch command)))

(defun agent-session-run-code (session id index)
  "Run code block INDEX of message block ID in the project root of SESSION.
The output is shown below the code block."
  (let* ((block (agent-session--block session id))
         (old (alist-get index (plist-get block :runs))))
    (when (process-live-p (plist-get old :process))
      (user-error "这段命令正在运行"))
    (let* ((command (agent-session--code-command-at session id index))
           ;; All keys exist up front so setf modifies the plist in place and
           ;; the record stored in the block follows.
           (run (list :command command :process nil :output "" :start (float-time)
                      :end nil :exit nil :stopped nil :timer nil))
           (default-directory (agent-session-root session))
           (process-environment (append '("TERM=dumb" "NO_COLOR=1" "PAGER=cat" "GIT_PAGER=cat")
                                        process-environment))
           (process
            (make-process
             :name "agent-run"
             ;; Tied to the session buffer, so closing the session ends it.
             :buffer (agent-session-buffer session)
             :command (agent-session--run-command command)
             :connection-type 'pipe
             ;; Run on the remote host for remote projects.
             :file-handler t
             :noquery t
             :filter (lambda (_process output)
                       (setf (plist-get run :output) (concat (plist-get run :output) output))
                       (agent-session--rerender-run session id run))
             :sentinel (lambda (process _event)
                         (unless (process-live-p process)
                           (setf (plist-get run :end) (float-time)
                                 (plist-get run :exit) (process-exit-status process))
                           (when-let* ((timer (plist-get run :timer)))
                             (cancel-timer timer)
                             (setf (plist-get run :timer) nil))
                           (when (agent-session--block session id)
                             (agent-session--render session id)))))))
      ;; No stdin, so a command waiting for input doesn't hang.  A remote
      ;; process may already be gone by now (tramp-rpc then signals), which
      ;; must not keep the run from being recorded.
      (ignore-errors (process-send-eof process))
      (setf (plist-get run :process) process)
      (setf (alist-get index (plist-get block :runs)) run)
      (puthash id block (agent-session-blocks session))
      (agent-session--render session id))))

(defun agent-session-stop-code (session id index)
  "Stop the running command of code block INDEX in message block ID."
  (let* ((run (alist-get index (plist-get (agent-session--block session id) :runs)))
         (process (plist-get run :process)))
    (when (process-live-p process)
      (setf (plist-get run :stopped) t)
      (interrupt-process process)
      ;; Kill it if it ignores the interrupt.
      (run-at-time 2 nil (lambda () (when (process-live-p process) (kill-process process)))))))

(defconst agent-session--tool-icons
  '((command . "$") (edit . "✎") (read . "≡") (search . "⌕") (web . "◎")
    (mcp . "⚙") (task . "◆") (plan . "☰") (other . "•"))
  "Icons for tool kinds.")

(defun agent-session--diff-stat (diff)
  "Count added and removed lines in DIFF."
  (let ((added 0) (removed 0))
    (dolist (line (split-string (or diff "") "\n"))
      (cond ((string-match-p "\\`\\+\\(?:[^+]\\|\\'\\)" line) (cl-incf added))
            ((string-match-p "\\`-\\(?:[^-]\\|\\'\\)" line) (cl-incf removed))))
    (concat (propertize (format "+%d" added) 'face 'diff-added)
            " "
            (propertize (format "-%d" removed) 'face 'diff-removed))))

(defun agent-session--tail-lines (text n)
  "The last N lines of TEXT."
  (let ((lines (split-string (string-trim-right text) "\n")))
    (if (> (length lines) n)
        (concat (propertize (format "…（省略 %d 行）\n" (- (length lines) n))
                            'face 'agent-session-dim)
                (string-join (last lines n) "\n"))
      (string-join lines "\n"))))

(defun agent-session--collapsed-p (block)
  "Return non-nil if BLOCK is folded.
If the user toggled it, follow that choice; thinking is folded by default;
tool calls are folded by default but expanded when they have a diff or failed."
  (cond ((plist-member block :collapsed) (plist-get block :collapsed))
        ((eq (plist-get block :kind) 'thinking) t)
        (t (not (or (plist-get block :diff) (eq (plist-get block :status) 'error))))))

(defun agent-session--format-tool (id block)
  "Format a tool call.
Clicking the header line folds it; when expanded, the diff or output is shown."
  (let* ((status (plist-get block :status))
         (diff (plist-get block :diff))
         (output (plist-get block :output))
         (has-body (or diff (and output (not (string-blank-p output)))))
         (collapsed (agent-session--collapsed-p block))
         (header (concat
                  (if has-body (if collapsed "▸ " "▾ ") "  ")
                  (propertize (format "%s %s"
                                      (alist-get (plist-get block :kind) agent-session--tool-icons "•")
                                      (plist-get block :title))
                              'face 'agent-session-tool)
                  "  "
                  (pcase status
                    ('running (propertize "…" 'face 'agent-session-dim))
                    ('error (propertize "✗" 'face 'agent-session-error))
                    ('declined (propertize "已拒绝" 'face 'agent-session-error))
                    (_ (propertize "✓" 'face 'agent-session-ok)))
                  (if diff (concat "  " (agent-session--diff-stat diff)) "")
                  (if-let* ((note (plist-get block :note)))
                      (concat "  " (propertize note 'face 'agent-session-dim))
                    ""))))
    (concat
     (if has-body
         (make-text-button header nil 'type 'agent-session-toggle 'agent-session-block id)
       header)
     "\n"
     (when (and has-body (not collapsed))
       (concat
        (agent-session--indent
         (if diff
             (agent-session-fontify (string-trim-right diff) 'diff-mode)
           (propertize (agent-session--tail-lines output agent-session-output-lines)
                       'face 'agent-session-dim)))
        "\n")))))

(defun agent-session--toggle-block (button)
  "Fold or expand the block (tool call, thinking) that BUTTON is in."
  (let* ((session agent-session--current)
         (id (button-get button 'agent-session-block)))
    (agent-session--update session id
                           :collapsed (not (agent-session--collapsed-p
                                            (agent-session--block session id))))))

;;; Turn folding (after T3 Code)
;;
;; After a turn ends, the process between the user message and the final reply
;; (tool calls, thinking, intermediate remarks) is hidden with an invisible
;; overlay, and a one-line summary appears under the user message; clicking it
;; expands. Turns in progress are not folded.

(defconst agent-session--fold-kinds
  '((command . "条命令") (edit . "次编辑") (read . "次读取") (search . "次搜索")
    (web . "次网页访问") (mcp . "次工具调用") (task . "个子任务") (plan . "次计划更新")
    (other . "次其他操作"))
  "Measure words for each tool-call kind in the summary.")

(defun agent-session--blocks-in-order (session)
  "Blocks of SESSION sorted by buffer position: ((ID . BLOCK) ...)."
  (let (entries)
    (maphash (lambda (id block) (push (cons id block) entries)) (agent-session-blocks session))
    (sort entries :key (lambda (entry) (marker-position (plist-get (cdr entry) :start))))))

(defun agent-session--fold-summary (tools duration)
  "Make a summary from tool calls TOOLS and elapsed time DURATION."
  (let ((counts nil) (failed 0))
    (dolist (tool tools)
      (cl-incf (alist-get (plist-get tool :kind) counts 0))
      (when (memq (plist-get tool :status) '(error declined)) (cl-incf failed)))
    (string-join
     (delq nil
           (append
            (list (format "执行了 %d 个操作" (length tools)))
            (mapcar (pcase-lambda (`(,kind . ,unit))
                      (when-let* ((n (alist-get kind counts))) (format "%d %s" n unit)))
                    agent-session--fold-kinds)
            (list (and (> failed 0) (format "%d 个失败" failed))
                  (and duration (concat "用时 " duration)))))
     " · ")))

(defun agent-session--fold-overlay (session start end)
  "Create an invisible folding overlay from START to END."
  (let ((overlay (make-overlay start end (agent-session-buffer session))))
    (overlay-put overlay 'invisible t)
    (overlay-put overlay 'agent-session-fold t)
    (overlay-put overlay 'isearch-open-invisible (lambda (o) (overlay-put o 'invisible nil)))
    overlay))

(defun agent-session--fold-turn (session user-id activity limit &optional duration)
  "Fold the turn starting at user message USER-ID.
ACTIVITY is the blocks that follow it (in order).  LIMIT is the end of the
turn (the start of the next user message, or the end of the transcript for
the last turn).  The turn's last agent remark stays visible (an interrupted
turn may have tool calls after it); the process before and after it is
folded separately.  Nothing is folded when the process has no tool calls.
DURATION is the turn's elapsed time, used in the summary."
  (let* ((final (seq-find (lambda (entry) (and (eq (plist-get (cdr entry) :type) 'text)
                                               (eq (plist-get (cdr entry) :kind) 'assistant)))
                          (reverse activity)))
         (before (if final (seq-take-while (lambda (entry) (not (eq entry final))) activity)
                   activity))
         (after (and final (cdr (memq final activity))))
         (tools (seq-keep (lambda (entry) (and (eq (plist-get (cdr entry) :type) 'tool) (cdr entry)))
                          (append before after)))
         (start-of (lambda (entry) (marker-position (plist-get (cdr entry) :start)))))
    (if (null tools)
        (agent-session--update session user-id :fold 'none)
      (agent-session--update
       session user-id
       :fold (list :collapsed t
                   :summary (agent-session--fold-summary tools duration)
                   :overlays
                   (delq nil
                         (list (and before
                                    (agent-session--fold-overlay
                                     session (funcall start-of (car before))
                                     (if final (funcall start-of final) limit)))
                               (and after
                                    (agent-session--fold-overlay
                                     session (funcall start-of (car after)) limit)))))))))

(defun agent-session--fold-turns (session &optional duration)
  "Fold all finished turns that aren't folded yet.
DURATION is the elapsed time of the latest turn."
  (let ((turns nil) (current nil))
    ;; Split into turns by user message: ((USER-ID . ACTIVITY) ...)
    (dolist (entry (agent-session--blocks-in-order session))
      (cond
       ;; Queued messages sit inside the previous turn for now and move to the
       ;; end when sent, so they don't delimit turns.
       ((plist-get (cdr entry) :queued))
       ((eq (plist-get (cdr entry) :type) 'user)
        (when current (push current turns))
        (setq current (list (car entry))))
       (current (setcdr (last current) (list entry)))))
    (when current (push current turns))
    (let ((latest (car turns))
          (turns (nreverse turns)))
      (cl-loop for (turn . rest) on turns
               do (let ((user (agent-session--block session (car turn)))
                        (limit (if rest
                                   (marker-position
                                    (plist-get (agent-session--block session (caar rest)) :start))
                                 (marker-position (agent-session-tail session)))))
                    (unless (plist-get user :fold)
                      (agent-session--fold-turn session (car turn) (cdr turn) limit
                                                (and (eq turn latest) duration))))))))

(defun agent-session--toggle-fold (button)
  "Expand or collapse the process of the turn that BUTTON is in."
  (let* ((session agent-session--current)
         (id (button-get button 'agent-session-block))
         (fold (plist-get (agent-session--block session id) :fold))
         (collapsed (not (plist-get fold :collapsed))))
    (dolist (overlay (plist-get fold :overlays))
      (overlay-put overlay 'invisible collapsed))
    (agent-session--update session id :fold (plist-put (copy-sequence fold) :collapsed collapsed))))

;;; UI API (called by backends)

(defun agent-session-text (session id text &optional kind)
  "Append TEXT to message block ID; KIND is assistant (default) or thinking."
  (let ((block (agent-session--block session id)))
    (if (null block)
        (agent-session--new-block session id (list :type 'text :kind (or kind 'assistant)
                                                   :text text))
      (puthash id (plist-put block :text (concat (plist-get block :text) text))
               (agent-session-blocks session))
      (if (eq (plist-get block :kind) 'thinking)
          ;; Thinking is usually folded, so just redraw (one line when folded).
          (when (not (agent-session--collapsed-p block))
            (agent-session--render session id))
        ;; Streaming reply: append at the end of the block, no full redraw.
        (agent-session--with-buffer session
          (let ((end (plist-get block :end)))
            (goto-char (1- end))                    ; before the trailing newline
            (insert (agent-session--ro (agent-session--indent text)))))))))

(defun agent-session-text-done (session id &optional text)
  "Mark message block ID as finished and redraw it as markdown.
When TEXT is non-nil, it becomes the final full text."
  (if (agent-session--block session id)
      (apply #'agent-session--update session id :done t (and text (list :text text)))
    (when (and text (not (string-blank-p text)))
      (agent-session--new-block session id (list :type 'text :kind 'assistant :text text :done t)))))

(defun agent-session-tool (session id &rest props)
  "Create or update tool block ID.
PROPS: :kind :title :status :output :diff :note."
  (apply #'agent-session--update session id
         (if (agent-session--block session id) props (append (list :type 'tool) props))))

(defun agent-session-tool-output (session id delta)
  "Append output increment DELTA to tool block ID."
  (when-let* ((block (agent-session--block session id)))
    (agent-session--update session id :output (concat (plist-get block :output) delta))))

(cl-defun agent-session-ask (session &key title detail diff choices callback tool)
  "Ask the user to confirm.
CHOICES is ((KEY LABEL) ...); after the user picks one, CALLBACK is called
with KEY.  The request is shown in the footer's auxiliary line; TOOL is the
id of the related tool block, on which the waiting state and the answer are
noted, with no separate entry in the transcript.  TITLE and DETAIL describe
the request.  DIFF is already shown by the tool block, so it isn't repeated."
  (ignore diff)
  (let ((id (symbol-name (gensym "ask-"))))
    (setf (agent-session-asks session)
          (append (agent-session-asks session)
                  ;; :answer and :copies are placeholders modified in place,
                  ;; so this list entry updates with them.
                  (list (list :id id :title title :detail detail :choices choices
                              :callback callback :tool tool :answer nil :copies nil))))
    (when (and tool (agent-session--block session tool))
      (agent-session--update session tool :note "等待确认"))
    (agent-session--refresh session)
    (message "%s 需要确认：%s（C-c C-y 允许，C-c C-n 拒绝）"
             (agent-session-title session) title)
    (agent-session--copy-ask session id)
    id))

(defun agent-session--copy-ask (session id)
  "Repeat confirmation request ID of SESSION in the session that started it.
A session started by another agent runs out of sight, so the user answers
its requests where that agent runs; answering either one answers both."
  (when-let* ((parent (agent-session-parent session)))
    (let* ((ask (agent-session--ask session id))
           (tool (agent-session--block session (plist-get ask :tool)))
           (copy (agent-session-ask
                  parent
                  :title (format "@%s：%s" (agent-session-handle session) (plist-get ask :title))
                  :detail (or (plist-get ask :detail) (plist-get tool :title))
                  :choices (plist-get ask :choices))))
      (plist-put (agent-session--ask parent copy) :origin (cons session id))
      (plist-put ask :copies (cons (cons parent copy) (plist-get ask :copies))))))

(defun agent-session--ask (session id)
  "The confirmation request ID in SESSION."
  (seq-find (lambda (ask) (equal (plist-get ask :id) id)) (agent-session-asks session)))

(defun agent-session--close-ask (session ask label)
  "Mark confirmation request ASK as handled; note result LABEL on its tool.
Its copies in other sessions close with it."
  (plist-put ask :answer label)
  (when-let* ((tool (plist-get ask :tool))
              ((agent-session--block session tool)))
    (agent-session--update session tool :note label))
  (pcase-dolist (`(,other . ,id) (plist-get ask :copies))
    (when-let* ((copy (agent-session--ask other id))
                ((not (plist-get copy :answer))))
      (agent-session--close-ask other copy label)
      (agent-session--refresh other))))

(defun agent-session--answer (session id key)
  "Answer confirmation request ID with KEY.
A copy answers the request it was made from."
  (let ((ask (agent-session--ask session id)))
    (unless (or (null ask) (plist-get ask :answer))
      (if-let* ((origin (plist-get ask :origin)))
          (agent-session--answer (car origin) (cdr origin) key)
        (agent-session--close-ask session ask (cadr (assq key (plist-get ask :choices))))
        (funcall (plist-get ask :callback) key)
        (agent-session--refresh session)))))

(defun agent-session-notice (session text &optional face)
  "Insert a notice line TEXT with FACE into the transcript."
  (agent-session--new-block session (format "notice-%s" (random)) (list :type 'notice :text text
                                                                       :face face)))

(defun agent-session-set-info (session &rest props)
  "Update the header-line info PROPS: :model :tokens :cost etc."
  (cl-loop for (key value) on props by #'cddr
           do (setf (agent-session-info session)
                    (plist-put (agent-session-info session) key value)))
  (agent-session--refresh session))

(defun agent-session--settle (session)
  "Wrap up when a turn ends or the process exits.
Tools still running are marked interrupted; unanswered confirmations expire."
  (maphash (lambda (id block)
             (pcase (plist-get block :type)
               ('tool (when (eq (plist-get block :status) 'running)
                        (agent-session--update session id :status 'error :note "已中断")))
               ('text (unless (plist-get block :done)
                        (agent-session--update session id :done t)))))
           (agent-session-blocks session))
  (dolist (ask (agent-session-asks session))
    (unless (plist-get ask :answer)
      (agent-session--close-ask session ask "已失效"))))

(defun agent-session-set-status (session status)
  "Set the session STATUS: idle / running / exited.
Send queued messages when idle."
  (let ((previous (agent-session-status session))
        (info (agent-session-info session)))
    (when (and (eq status 'running) (not (eq previous 'running)))
      (setq info (plist-put info :started (current-time))))
    ;; Mark as unread when a turn finishes in the background; cleared on opening.
    (when (and (eq previous 'running) (eq status 'idle)
               (not (get-buffer-window (agent-session-buffer session) t)))
      (setq info (plist-put info :unread t)))
    (setf (agent-session-info session) info))
  (let ((finished (and (eq (agent-session-status session) 'running) (eq status 'idle)
                       (plist-get (agent-session-info session) :started))))
    (setf (agent-session-status session) status)
    (when (memq status '(idle exited))
      (agent-session--settle session)
      ;; Turn ended: fold finished turns into summaries (also reached after
      ;; replaying a resumed session).
      (agent-session--fold-turns session (and finished (agent-session--elapsed finished)))))
  (agent-session--refresh session)
  (when (and (eq status 'idle) (agent-session-queue session))
    (let ((next (pop (agent-session-queue session))))
      ;; Shown at the then-end when queued; move it to the end of the
      ;; transcript when actually sent so the order matches reality.
      (agent-session--remove-block session (car next))
      (agent-session--new-block session (car next) (list :type 'user :text (cdr next)))
      (agent-session--deliver session (cdr next)))))

;;; Mode line: agent / model / reasoning effort / permission mode / usage / status

(defun agent-session--pending-asks (session)
  "Ids of unanswered confirmation requests in SESSION, in order of appearance."
  (mapcar (lambda (ask) (plist-get ask :id))
          (seq-remove (lambda (ask) (plist-get ask :answer)) (agent-session-asks session))))

(defun agent-session--elapsed (since)
  "Short duration from SINCE until now, e.g. 5s, 3m, 1h2m."
  (let ((seconds (round (float-time (time-since since)))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          (t (format "%dh%dm" (/ seconds 3600) (/ (% seconds 3600) 60))))))

(defun agent-session-status-label (session)
  "Status label of SESSION (with faces), shared by mode line and session list."
  (cond ((agent-session--pending-asks session)
         (propertize "● 等待确认" 'face 'agent-session-ask))
        (t (pcase (agent-session-status session)
             ('starting (propertize "○ 启动中" 'face 'agent-session-dim))
             ('running (propertize (format "● 工作中 %s"
                                           (agent-session--elapsed
                                            (or (plist-get (agent-session-info session) :started)
                                                (current-time))))
                                   'face 'warning))
             ('idle (if (plist-get (agent-session-info session) :unread)
                        (propertize "● 完成" 'face 'agent-session-ok)
                      (propertize "○ 空闲" 'face 'agent-session-dim)))
             ('exited (propertize "○ 已退出" 'face 'agent-session-error))))))

(defun agent-session--model-label (session)
  "Display name of the current model of SESSION."
  (let ((info (agent-session-model-info session)))
    (or (plist-get info :name)
        (plist-get (agent-session-info session) :model)
        "默认模型")))

(defun agent-session--mode-line-control (label command help)
  "Clickable mode-line segment LABEL: a mouse click runs COMMAND.
HELP is the help echo."
  (propertize label
              'mouse-face 'mode-line-highlight
              'help-echo (concat help "（鼠标点击）")
              'local-map (make-mode-line-mouse-map
                          'mouse-1 (lambda (event)
                                     (interactive "e")
                                     (with-selected-window (posn-window (event-start event))
                                       (call-interactively command))))))

(defun agent-session--mode-line (session)
  "Mode-line contents of the SESSION buffer."
  (let* ((info (agent-session-info session))
         (mode (agent-session-setting session :mode))
         (sep (propertize " · " 'face 'agent-session-dim)))
    (concat
     " " (agent-session-status-label session) "  "
     (agent-session--mode-line-control
      (propertize (agent-session-title session) 'face 'agent-session-assistant)
      #'agent-session-select-agent "切换 agent")
     sep
     (agent-session--mode-line-control (agent-session--model-label session)
                                       #'agent-session-select-model "切换模型（m）")
     (when (plist-get (agent-session-model-info session) :efforts)
       (concat sep (agent-session--mode-line-control
                    (concat "推理 " (or (agent-session-setting session :effort) "默认"))
                    #'agent-session-select-effort "切换推理强度（e）")))
     sep
     (if (eq mode 'plan)
         (agent-session--mode-line-control (propertize "计划模式" 'face 'warning)
                                           #'agent-session-toggle-plan "退出计划模式（P）")
       (agent-session--mode-line-control (agent-session--mode-label mode)
                                         #'agent-session-select-mode "切换权限模式（M）"))
     (when-let* ((tokens (plist-get info :tokens)))
       (propertize (format "  %.1fk" (/ tokens 1000.0)) 'face 'agent-session-dim))
     (when-let* ((cost (plist-get info :cost)))
       (propertize (format " · $%.2f" cost) 'face 'agent-session-dim))
     (when-let* ((queued (length (agent-session-queue session)))
                 ((> queued 0)))
       (propertize (format "  排队 %d" queued) 'face 'agent-session-dim))
     (propertize (format "  %s" (file-name-nondirectory
                                 (directory-file-name (agent-session-root session))))
                 'face 'agent-session-dim)
     (when-let* ((handle (agent-session-handle session)))
       (propertize (concat " @" handle) 'face 'agent-session-dim
                   'help-echo "在其他会话里用这个名字提及本会话")))))

(defvar agent-session--list-refresh-function nil
  "Refresh function of the session list (set by it), called on status changes.")

(defvar agent-session--clock nil "Timer refreshing elapsed times of running sessions.")

(defun agent-session--tick ()
  "Refresh elapsed times on mode lines and separators of running sessions.
Stop the timer when no session is running."
  (let ((running (seq-filter (lambda (b) (eq (agent-session-status
                                              (buffer-local-value 'agent-session--current b))
                                             'running))
                             (agent-session-buffers))))
    (if running
        (dolist (buffer running)
          (agent-session--render-footer (buffer-local-value 'agent-session--current buffer))
          (with-current-buffer buffer (force-mode-line-update)))
      (cancel-timer agent-session--clock)
      (setq agent-session--clock nil))))

(defun agent-session--refresh (session)
  "Refresh the footer and mode line of SESSION and notify the session list."
  (when (buffer-live-p (agent-session-buffer session))
    (agent-session--render-footer session)
    (with-current-buffer (agent-session-buffer session)
      (force-mode-line-update))
    (when (and (eq (agent-session-status session) 'running) (not agent-session--clock))
      (setq agent-session--clock (run-with-timer 5 5 #'agent-session--tick)))
    (when agent-session--list-refresh-function
      (funcall agent-session--list-refresh-function))))

;;; Footer: separator, auxiliary lines, prompt (after telega's chatbuf)
;;
;; Buffer layout:
;;   transcript | tail | separator · auxiliary lines · prompt | input | input text
;; Transcript and footer are read-only; the prompt can't be entered
;; (cursor-intangible), and from it to the end of buffer is the input area.

(defface agent-session-separator '((t :inherit shadow :underline t))
  "Separator line between transcript and input.")

(defface agent-session-prompt '((t :inherit (bold font-lock-function-name-face)))
  "Input prompt.")

(defun agent-session--footer (session)
  "Footer text of SESSION.
That is the separator (ongoing status on its left), auxiliary lines, prompt."
  (let* ((status (agent-session-status session))
         (asks (agent-session--pending-asks session))
         (state (cond (asks (agent-session-status-label session))
                      ((memq status '(running starting exited))
                       (agent-session-status-label session)))))
    (concat
     "\n"
     ;; Separator: an underline spanning the window width, ongoing status on the left.
     (propertize (concat (if state (concat " " state " ") "")
                         (propertize " " 'display '(space :align-to right)))
                 'face 'agent-session-separator)
     "\n"
     ;; Auxiliary lines: pending requests (with choice buttons) and queued messages.
     (when-let* ((id (car asks)))
       (let ((ask (agent-session--ask session id)))
         (concat
          (propertize (concat " ⚠ " (plist-get ask :title) "  ") 'face 'agent-session-ask)
          (mapconcat (pcase-lambda (`(,key ,label))
                       (make-text-button (format " %s " label) nil
                                         'type 'agent-session-choice
                                         'action (lambda (_) (agent-session--answer session id key))))
                     (plist-get ask :choices) " ")
          "\n"
          ;; Without a related tool block, the detail (e.g. the command) is only
          ;; visible here.
          (when-let* ((detail (and (not (agent-session--block session (plist-get ask :tool)))
                                   (plist-get ask :detail))))
            (propertize (concat "   " (truncate-string-to-width
                                       (replace-regexp-in-string "\n" " ⏎ " detail) 200 nil nil "…")
                                "\n")
                        'face 'font-lock-string-face)))))
     (mapconcat (lambda (queued)
                  (concat
                   (propertize (concat " ⏳ 排队：" (agent-session--title-seed (cdr queued)) "  ")
                               'face 'agent-session-dim)
                   (make-text-button " 引导 " nil 'type 'agent-session-choice
                                     'help-echo "立刻送进当前回合"
                                     'action (lambda (_) (agent-session-steer-queued (car queued))))
                   " "
                   (make-text-button " 取消 " nil 'type 'agent-session-choice
                                     'help-echo "撤回这条排队消息"
                                     'action (lambda (_) (agent-session-cancel-queued (car queued))))
                   "\n"))
                (agent-session-queue session) "")
     ;; Prompt: read-only and can't be entered; the text after it is editable.
     (propertize (concat (agent-session-title session) " ❯ ")
                 'face 'agent-session-prompt
                 'cursor-intangible t 'field 'agent-session-prompt))))

(defun agent-session--render-footer (session)
  "Redraw the footer of SESSION.
Point inside the input area of each window and the input text are preserved."
  (let ((buffer (agent-session-buffer session)))
    (when (and (buffer-live-p buffer) (agent-session-input session))
      (with-current-buffer buffer
        (let* ((input (agent-session-input session))
               (tail (agent-session-tail session))
               (windows (get-buffer-window-list buffer nil t))
               ;; Record point in the input area as an offset from the input
               ;; start, restored after redrawing.
               (offsets (mapcar (lambda (w) (let ((p (window-point w)))
                                              (and (>= p input) (- p input))))
                                windows))
               (offset (and (>= (point) input) (- (point) input)))
               (inhibit-read-only t)
               (inhibit-modification-hooks t)
               (start (marker-position tail)))
          (save-excursion
            (delete-region start input)
            (goto-char start)
            (insert (agent-session--ro (agent-session--footer session)))
            (set-marker tail start)
            (set-marker input (point)))
          (when offset (goto-char (+ input offset)))
          (cl-mapc (lambda (w o) (when o (set-window-point w (+ input o)))) windows offsets))))))

;;; Input: the input area after the footer

(defvar-local agent-session--history-index nil "Current position in the input history.")

(defun agent-session--input-text (session)
  "Text of the input area of SESSION.
Image attachments remain as placeholder text with an `agent-session-image'
property."
  (with-current-buffer (agent-session-buffer session)
    (let* ((start (agent-session-input session))
           (text (buffer-substring-no-properties start (point-max)))
           (pos start))
      (while (setq pos (text-property-not-all pos (point-max) 'agent-session-image nil))
        (let ((end (next-single-property-change pos 'agent-session-image nil (point-max))))
          (add-text-properties (- pos start) (- end start)
                               (text-properties-at
                                0 (agent-session--image-string
                                   (get-text-property pos 'agent-session-image)))
                               text)
          (setq pos end)))
      text)))

;;; Image attachments
;;
;; An image in the input area is the placeholder text “[图片]” with an
;; `agent-session-image' property (the file path), shown as a thumbnail in the
;; GUI. Message text keeps this property when queued, steered and in history;
;; backends extract images and text with `agent-session-message-images' /
;; `agent-session-message-text'.

(defcustom agent-session-image-directory (locate-user-emacs-file "var/agent-images/")
  "Directory where pasted images are saved."
  :type 'directory :group 'agent-session)

(defconst agent-session--clipboard-image-types
  '((image/png . "png") (image/jpeg . "jpg") (image/gif . "gif") (image/webp . "webp")
    (image/tiff . "tiff"))
  "Clipboard types pasteable as images, with extensions, in priority order.")

(defun agent-session--image-string (file)
  "Placeholder text for image attachment FILE; shown as a thumbnail in the GUI."
  (apply #'propertize "[图片]"
         'agent-session-image file
         'help-echo (abbreviate-file-name file)
         'rear-nonsticky t
         (when (display-images-p)
           (list 'display (create-image file nil nil
                                        :max-height (* 6 (default-line-height))
                                        :ascent 'center)))))

(defun agent-session-message-images (text)
  "Image files in message TEXT, in order of appearance."
  (let ((pos 0) files)
    (while (setq pos (text-property-not-all pos (length text) 'agent-session-image nil text))
      (push (get-text-property pos 'agent-session-image text) files)
      (setq pos (next-single-property-change pos 'agent-session-image text (length text))))
    (nreverse files)))

(defun agent-session-message-text (text)
  "Plain text of message TEXT with image placeholders removed."
  (let ((pos 0) parts)
    (while (< pos (length text))
      (let ((next (next-single-property-change pos 'agent-session-image text (length text))))
        (unless (get-text-property pos 'agent-session-image text)
          (push (substring-no-properties text pos next) parts))
        (setq pos next)))
    (string-trim (apply #'concat (nreverse parts)))))

(defun agent-session-image-media-type (file)
  "MIME type of image FILE."
  (pcase (downcase (or (file-name-extension file) ""))
    ((or "jpg" "jpeg") "image/jpeg")
    ("gif" "image/gif")
    ("webp" "image/webp")
    (_ "image/png")))

(defun agent-session--clipboard-image ()
  "Save the clipboard image to a file and return its path, else nil.
Only when the clipboard has an image and no text.  With text, paste as
text: e.g. a file copied in Finder puts both its name and icon there."
  (when-let* ((targets (ignore-errors (gui-get-selection 'CLIPBOARD 'TARGETS)))
              ((not (seq-some (lambda (type) (seq-contains-p targets type))
                              '(STRING UTF8_STRING text/plain))))
              (type (seq-find (lambda (type) (seq-contains-p targets (car type)))
                              agent-session--clipboard-image-types))
              (data (ignore-errors (gui-get-selection 'CLIPBOARD (car type))))
              ((> (length data) 0)))
    (make-directory agent-session-image-directory t)
    (let* ((base (expand-file-name (format-time-string "%Y%m%d-%H%M%S-%3N")
                                   agent-session-image-directory))
           (file (concat base "." (cdr type))))
      (let ((coding-system-for-write 'no-conversion))
        (write-region data nil file nil 'silent))
      ;; macOS screenshots sometimes come only as TIFF, which agents don't
      ;; support; convert to PNG.
      (when (equal (cdr type) "tiff")
        (let ((png (concat base ".png")))
          (when (eq 0 (call-process "sips" nil nil nil "-s" "format" "png" file "--out" png))
            (delete-file file)
            (setq file png))))
      file)))

(defun agent-session-insert-image (file)
  "Insert image attachment FILE in the input area.
If point isn't in the input area, insert at the end."
  (interactive (list (read-file-name "图片：" nil nil t nil
                                     (lambda (f) (or (file-directory-p f)
                                                     (string-match-p (image-file-name-regexp) f))))))
  (unless (agent-session--in-input-p) (goto-char (point-max)))
  (insert (agent-session--image-string (expand-file-name file))))

(defun agent-session-yank (&optional arg)
  "Paste: insert a clipboard image as an attachment, else like `yank'.
ARG is passed to `yank'."
  (interactive "*P")
  (if-let* ((file (agent-session--clipboard-image)))
      (agent-session-insert-image file)
    (unless (agent-session--in-input-p) (goto-char (point-max)))
    (setq this-command 'yank)
    (yank arg)))

(defun agent-session--dnd-file (uri action)
  "Attach an image dropped into the session buffer; open other files as usual.
URI and ACTION are as for `dnd-open-file'."
  (let ((file (dnd-get-local-file-name uri t)))
    (if (and file (string-match-p (image-file-name-regexp) file))
        (progn (agent-session-insert-image file) 'private)
      (dnd-open-file uri action))))

(defun agent-session--in-input-p ()
  "Return non-nil if point is in the input area."
  (and agent-session--current (>= (point) (agent-session-input agent-session--current))))

(defvar agent-session-send-filters nil
  "Functions rewriting a user message on its way to the agent.
Each is called with the session and the text and returns the text to
send; the transcript keeps showing what the user wrote.")

(defvar agent-session-submit-functions nil
  "Functions called with the session and the text of each submitted message.")

(defun agent-session--outgoing (session text)
  "TEXT as sent to the agent of SESSION, after `agent-session-send-filters'."
  (dolist (filter agent-session-send-filters text)
    (setq text (funcall filter session text))))

(defun agent-session--deliver (session text)
  "Hand TEXT to the backend of SESSION for sending."
  (agent-session-set-status session 'running)
  (agent-session-backend-send (agent-session-backend session) session
                              (agent-session--outgoing session text)))

(defun agent-session-submit (session text)
  "Send TEXT as the user: show it in the transcript; queue it if busy.
Return the id of its block in the transcript."
  (unless (plist-get (agent-session-info session) :title)
    (setf (agent-session-info session)
          (plist-put (agent-session-info session) :title (agent-session--title-seed text))))
  (run-hook-with-args 'agent-session-submit-functions session text)
  (let ((id (format "user-%s" (random)))
        (busy (memq (agent-session-status session) '(running starting))))
    (agent-session--new-block session id (list :type 'user :text text :queued busy))
    (if busy
        (progn
          (setf (agent-session-queue session)
                (append (agent-session-queue session) (list (cons id text))))
          (agent-session--refresh session))
      (agent-session--deliver session text))
    id))

(defun agent-session-send (session text)
  "Handle user input TEXT.
Local /commands run in Emacs; everything else goes to the agent."
  (let ((text (string-trim text)))
    (unless (string-empty-p text)
      (when (eq (agent-session-status session) 'exited) (user-error "agent 进程已退出"))
      (unless (agent-session--run-local-command session text)
        (agent-session-submit session text)))))

(defun agent-session-send-input ()
  "Send the contents of the input area."
  (interactive)
  (let* ((session (agent-session--this))
         (text (string-trim (agent-session--input-text session))))
    (when (string-empty-p text) (user-error "输入为空"))
    (push text (agent-session-history session))
    (setq agent-session--history-index nil)
    (let ((inhibit-read-only t))
      (delete-region (agent-session-input session) (point-max)))
    (agent-session-send session text)))

(defun agent-session-steer (session text)
  "Feed TEXT into the ongoing turn of SESSION (steering).
When the agent isn't running, this is an ordinary send; when the backend
doesn't support steering, interrupt the current turn and send TEXT first."
  (cond
   ((not (eq (agent-session-status session) 'running))
    (agent-session-send session text))
   ;; Local commands like /model run in Emacs as usual.
   ((agent-session--run-local-command session text))
   (t
    (if (agent-session-backend-steer (agent-session-backend session) session
                                     (agent-session--outgoing session text))
        (agent-session--new-block session (format "user-%s" (random))
                                  (list :type 'user :text text :steer t))
      (let ((id (format "user-%s" (random))))
        (agent-session--new-block session id (list :type 'user :text text :queued t))
        (setf (agent-session-queue session) (cons (cons id text) (agent-session-queue session)))
        (agent-session-backend-interrupt (agent-session-backend session) session)
        (agent-session-notice session "该 agent 不支持引导，已中断当前回合，随后发送")))
    (agent-session--refresh session))))

(defun agent-session-steer-input ()
  "Send the input area contents as steering.
While the agent is running, feed it into the current turn right away
instead of queueing."
  (interactive)
  (let* ((session (agent-session--this))
         (text (string-trim (agent-session--input-text session))))
    (when (string-empty-p text) (user-error "输入为空"))
    (push text (agent-session-history session))
    (setq agent-session--history-index nil)
    (let ((inhibit-read-only t))
      (delete-region (agent-session-input session) (point-max)))
    (agent-session-steer session text)))

(defun agent-session--take-queued (session id)
  "Take ID (default the oldest) out of the queue of SESSION.
Delete its display and return (ID . TEXT)."
  (let ((entry (if id (assoc id (agent-session-queue session)) (car (agent-session-queue session)))))
    (unless entry (user-error "没有排队的消息"))
    (setf (agent-session-queue session) (delq entry (agent-session-queue session)))
    (agent-session--remove-block session (car entry))
    entry))

(defun agent-session-steer-queued (&optional id)
  "Turn queued message ID (default the oldest) into steering right away."
  (interactive)
  (let ((session (agent-session--this)))
    (agent-session-steer session (cdr (agent-session--take-queued session id)))))

(defun agent-session-cancel-queued (&optional id)
  "Withdraw queued message ID (default the oldest) back into the input area."
  (interactive)
  (let* ((session (agent-session--this))
         (entry (agent-session--take-queued session id)))
    (agent-session--refresh session)
    (agent-session-insert-input (agent-session-buffer session) (cdr entry))))

(defun agent-session-goto-input ()
  "Go to the end of the input area."
  (interactive)
  (goto-char (point-max)))

(defun agent-session-ret ()
  "Send in the input area; push a button on one; else go to the input area."
  (interactive)
  (cond ((agent-session--in-input-p) (agent-session-send-input))
        ((button-at (point)) (push-button))
        (t (agent-session-goto-input))))

(defun agent-session-self-insert-to-input ()
  "When typing in the transcript, go to the end of the input area and insert."
  (interactive)
  (goto-char (point-max))
  (call-interactively #'self-insert-command))

(defun agent-session-cancel-dwim ()
  "Clear the input area if it has input; otherwise interrupt the agent."
  (interactive)
  (let ((session (agent-session--this)))
    (if (string-blank-p (agent-session--input-text session))
        (agent-session-interrupt)
      (let ((inhibit-read-only t))
        (delete-region (agent-session-input session) (point-max))))))

(defun agent-session--history-step (step)
  "Move STEP entries in the input history."
  (let* ((session (agent-session--this))
         (history (agent-session-history session))
         (index (+ (or agent-session--history-index -1) step)))
    (cond ((< index 0)
           (setq agent-session--history-index nil)
           (delete-region (agent-session-input session) (point-max)))
          ((< index (length history))
           (setq agent-session--history-index index)
           (delete-region (agent-session-input session) (point-max))
           (goto-char (point-max))
           (insert (nth index history)))
          (t (user-error "没有更早的输入")))))

(defun agent-session-previous-input ()
  "Recall the previous input."
  (interactive)
  (agent-session--history-step 1))

(defun agent-session-next-input ()
  "Recall the next input."
  (interactive)
  (agent-session--history-step -1))

(defun agent-session-focus-input (&optional session)
  "Focus the input area of SESSION (default the current or target session)."
  (interactive)
  (let* ((session (or session agent-session--current
                      (when-let* ((buffer (agent-session-target)))
                        (buffer-local-value 'agent-session--current buffer))
                      (user-error "没有 agent 会话，先用 C-c a n 新建")))
         (window (agent-session-display (agent-session-buffer session))))
    (select-window window)
    (goto-char (point-max))
    (when (bound-and-true-p evil-local-mode)
      (evil-insert-state))))

(defun agent-session-tab ()
  "Complete in the input area; move to the next button in the transcript."
  (interactive)
  (if (agent-session--in-input-p)
      (completion-at-point)
    (forward-button 1 t)))

(defun agent-session-interrupt ()
  "Interrupt the agent's current turn and clear queued messages."
  (interactive)
  (let ((session (agent-session--this)))
    (setf (agent-session-queue session) nil)
    (agent-session-backend-interrupt (agent-session-backend session) session)
    (agent-session-notice session "已中断")))

(defun agent-session--answer-latest (key-fn)
  "Answer the oldest pending request with the choice KEY-FN picks."
  (let* ((session (agent-session--this))
         (id (or (car (agent-session--pending-asks session)) (user-error "没有待确认的请求")))
         (choices (plist-get (agent-session--ask session id) :choices)))
    (agent-session--answer session id (funcall key-fn choices))))

(defun agent-session-approve ()
  "Allow the oldest pending request (first choice)."
  (interactive)
  (agent-session--answer-latest #'caar))

(defun agent-session-deny ()
  "Deny the oldest pending request (last choice)."
  (interactive)
  (agent-session--answer-latest (lambda (choices) (car (car (last choices))))))

(defun agent-session--message-positions ()
  "Start positions of the messages (user and agent) in the transcript."
  (let (positions)
    (maphash (lambda (_id block)
               (let ((pos (marker-position (plist-get block :start))))
                 ;; Skip intermediate remarks that are folded (invisible).
                 (when (and (memq (plist-get block :type) '(user text))
                            (not (invisible-p pos)))
                   (push pos positions))))
             (agent-session-blocks (agent-session--this)))
    (sort positions #'<)))

(defun agent-session-next-message ()
  "Go to the next message, or to the input area if there is none."
  (interactive)
  (if-let* ((pos (seq-find (lambda (p) (> p (point))) (agent-session--message-positions))))
      (goto-char pos)
    (agent-session-goto-input)))

(defun agent-session-previous-message ()
  "Go to the previous message."
  (interactive)
  (when-let* ((pos (seq-find (lambda (p) (< p (point))) (reverse (agent-session--message-positions)))))
    (goto-char pos)))

;;; Switching agent / model / reasoning effort / permission mode

(defun agent-session--has-conversation (session)
  "Return non-nil if SESSION has a conversation (user messages or replies)."
  (catch 'found
    (maphash (lambda (_id block)
               (when (memq (plist-get block :type) '(user text tool))
                 (throw 'found t)))
             (agent-session-blocks session))
    nil))

(defun agent-session--mode-label (mode)
  "Display name of permission mode MODE."
  (or (cadr (assq mode agent-session-modes)) (symbol-name mode)))

(defun agent-session--completing-read (prompt candidates &optional default)
  "A `completing-read' with annotations, using PROMPT and DEFAULT.
CANDIDATES is ((VALUE . NOTE) ...)."
  (let ((completion-extra-properties
         (list :annotation-function
               (lambda (candidate)
                 (when-let* ((note (cdr (assoc candidate candidates))))
                   (concat "  " (propertize note 'face 'completions-annotations)))))))
    (completing-read prompt (mapcar #'car candidates) nil t nil nil default)))

(defun agent-session-select-model (&optional model)
  "Switch the model of the current session to MODEL."
  (interactive)
  (let* ((session (agent-session--this))
         (models (or (agent-session-backend-models (agent-session-backend session) session)
                     (user-error "%s 还没有返回模型列表" (agent-session-title session))))
         (model (or model
                    (agent-session--completing-read
                     "模型: "
                     (mapcar (lambda (m) (cons (plist-get m :id)
                                               (string-join (delq nil (list (plist-get m :name)
                                                                            (plist-get m :description)))
                                                            " · ")))
                             models)
                     (agent-session-setting session :model)))))
    (unless (seq-find (lambda (m) (equal (plist-get m :id) model)) models)
      (user-error "没有模型 %s" model))
    (agent-session-configure session :model model)
    ;; Reset to the default if the new model doesn't support the current effort.
    (let ((efforts (plist-get (agent-session-model-info session) :efforts))
          (effort (agent-session-setting session :effort)))
      (when (and effort efforts (not (member effort efforts)))
        (agent-session-configure session :effort nil)))))

(defun agent-session-select-effort (&optional effort)
  "Switch the reasoning effort of the current session to EFFORT."
  (interactive)
  (let* ((session (agent-session--this))
         (info (agent-session-model-info session))
         (efforts (or (plist-get info :efforts)
                      (user-error "当前模型不支持调整推理强度")))
         (effort (or effort
                     (agent-session--completing-read
                      "推理强度: "
                      (mapcar (lambda (e) (cons e (and (equal e (plist-get info :default-effort))
                                                      "默认")))
                              efforts)
                      (agent-session-setting session :effort)))))
    (unless (member effort efforts) (user-error "当前模型不支持强度 %s" effort))
    (agent-session-configure session :effort effort)))

(defun agent-session-select-mode (&optional mode)
  "Switch the permission mode of the current session to MODE."
  (interactive)
  (let* ((session (agent-session--this))
         (modes (agent-session-backend-modes (agent-session-backend session) session))
         (mode (or mode
                   ;; Candidates carry both the Chinese and English names so
                   ;; either matches, e.g. “完全访问 full”.
                   (let* ((candidates (mapcar (lambda (m) (cons (format "%s %s"
                                                                       (agent-session--mode-label m) m)
                                                                 (nth 2 (assq m agent-session-modes))))
                                              modes))
                          (label (agent-session--completing-read
                                  "权限模式: " candidates
                                  (car (seq-find (lambda (c) (string-suffix-p
                                                              (format " %s" (agent-session-setting
                                                                             session :mode))
                                                              (car c)))
                                                 candidates)))))
                     (intern (car (last (split-string label " "))))))))
    (unless (memq mode modes) (user-error "%s 不支持该权限模式" (agent-session-title session)))
    (agent-session-configure session :mode mode)))

(defun agent-session-plan-on ()
  "Enter plan mode (/plan): plan only, make no changes."
  (interactive)
  (let* ((session (agent-session--this))
         (mode (agent-session-setting session :mode)))
    (unless (memq 'plan (agent-session-backend-modes (agent-session-backend session) session))
      (user-error "%s 不支持计划模式" (agent-session-title session)))
    (unless (eq mode 'plan)
      (agent-session-configure session :before-plan mode :mode 'plan))))

(defun agent-session-plan-off ()
  "Leave plan mode (/default), restoring the previous permission mode."
  (interactive)
  (let ((session (agent-session--this)))
    (when (eq (agent-session-setting session :mode) 'plan)
      (agent-session-configure session :mode (or (plist-get (agent-session-settings session)
                                                            :before-plan)
                                                 agent-session-default-mode)))))

(defun agent-session-toggle-plan ()
  "Toggle plan mode."
  (interactive)
  (if (eq (agent-session-setting (agent-session--this) :mode) 'plan)
      (agent-session-plan-off)
    (agent-session-plan-on)))

(defun agent-session-select-agent (&optional agent)
  "Switch to AGENT.
Replace in place if there is no conversation yet; otherwise open a new
session carrying over the input draft."
  (interactive)
  (let* ((session (agent-session--this))
         (agent (or agent
                    (intern (agent-session--completing-read
                             "Agent: "
                             (mapcar (lambda (a) (cons (symbol-name (car a))
                                                       (plist-get (cdr a) :title)))
                                     (reverse agent-session-agents))
                             (symbol-name (agent-session-agent session)))))))
    (unless (assq agent agent-session-agents) (user-error "未注册 agent：%s" agent))
    (unless (eq agent (agent-session-agent session))
      (if (agent-session--has-conversation session)
          (let ((draft (agent-session--input-text session)))
            (agent-session-insert-input
             (agent-session-start agent t nil (agent-session-root session)) draft))
        (agent-session-backend-stop (agent-session-backend session) session)
        (setf (agent-session-agent session) agent
              (agent-session-backend session) (agent-session--get agent :backend)
              (agent-session-state session) nil
              (agent-session-info session) nil
              (agent-session-settings session)
              (copy-sequence (alist-get agent agent-session-last-settings))
              (agent-session-status session) 'starting)
        ;; Without a conversation the handle is still the old agent's placeholder.
        (agent-session-set-handle session (symbol-name agent))
        (with-current-buffer (agent-session-buffer session)
          (rename-buffer (format "*%s@%s*" agent (file-name-nondirectory
                                                   (directory-file-name (agent-session-root session))))
                         t))
        (agent-session-backend-start (agent-session-backend session) session)))))

(defun agent-session-new ()
  "Open a new session in the same project with the same agent."
  (interactive)
  (let ((session (agent-session--this)))
    (agent-session-start (agent-session-agent session) t nil (agent-session-root session))))

(defun agent-session-resume (&optional agent)
  "Resume a past session of AGENT (default the current one) in this project."
  (interactive)
  (let* ((session agent-session--current)
         (agent (or agent (and session (agent-session-agent session)) (agent-session--read-agent)))
         (root (if session (agent-session-root session) (agent-session--root)))
         (items 'pending))
    (agent-session-backend-history (agent-session--get agent :backend) root
                                   (lambda (result) (setq items result)))
    (with-timeout (20 (user-error "获取历史会话超时"))
      (while (eq items 'pending) (accept-process-output nil 0.05)))
    (unless items (user-error "本项目没有 %s 的历史会话" agent))
    (let* ((candidates (mapcar (lambda (item)
                                 (cons (format "%s  %s" (format-time-string "%m-%d %H:%M"
                                                                            (plist-get item :time))
                                               (plist-get item :title))
                                       (plist-get item :id)))
                               items))
           (choice (completing-read "恢复会话: " candidates nil t)))
      (agent-session-start agent nil (cdr (assoc choice candidates)) root))))

;;; Slash commands and completion

(defvar agent-session-local-commands
  '(("model" agent-session-select-model "切换模型" agent-session--model-ids)
    ("effort" agent-session-select-effort "切换推理强度" agent-session--effort-names)
    ("mode" agent-session-select-mode "切换权限模式" agent-session--mode-names)
    ("agent" agent-session-select-agent "切换 agent" agent-session--agent-names)
    ("plan" agent-session-plan-on "进入计划模式：只规划，不改动")
    ("default" agent-session-plan-off "退出计划模式")
    ("new" agent-session-new "新开会话")
    ("resume" agent-session-resume "恢复历史会话")
    ("interrupt" agent-session-interrupt "中断当前回合"))
  "Commands run in Emacs, not sent to the agent.
Each is (NAME FUNCTION DESCRIPTION [ARG-CANDIDATES-FUNCTION]).  With an
argument, FUNCTION is called with the argument string (converted to a
symbol for mode and agent).")

(defun agent-session--model-ids (session)
  "Model ids available in SESSION."
  (mapcar (lambda (m) (plist-get m :id))
          (agent-session-backend-models (agent-session-backend session) session)))

(defun agent-session--effort-names (session)
  "Reasoning efforts supported by the current model of SESSION."
  (plist-get (agent-session-model-info session) :efforts))

(defun agent-session--mode-names (session)
  "Names of permission modes supported by SESSION."
  (mapcar #'symbol-name (agent-session-backend-modes (agent-session-backend session) session)))

(defun agent-session--agent-names (_session)
  "Names of registered agents."
  (mapcar (lambda (a) (symbol-name (car a))) (reverse agent-session-agents)))

(defun agent-session--run-local-command (session text)
  "If TEXT is a local command, run it in SESSION and return non-nil."
  (when (string-match "\\`/\\([[:alnum:]-]+\\)\\(?:[ \t]+\\(.*\\)\\)?\\'" text)
    (when-let* ((entry (assoc (match-string 1 text) agent-session-local-commands)))
      (let ((arg (match-string 2 text)))
        (with-current-buffer (agent-session-buffer session)
          (if (and arg (nth 3 entry))
              (funcall (nth 1 entry)
                       (if (memq (nth 1 entry) '(agent-session-select-mode agent-session-select-agent))
                           (intern arg)
                         arg))
            (call-interactively (nth 1 entry)))))
      t)))

(defun agent-session--command-candidates (session)
  "Slash command candidates for SESSION.
A list of (\"/name\" DESCRIPTION ARG-HINT SOURCE)."
  (append
   (mapcar (lambda (c) (list (concat "/" (car c)) (nth 2 c) nil 'local)) agent-session-local-commands)
   (mapcar (lambda (c) (list (concat "/" (plist-get c :name)) (plist-get c :description)
                             (plist-get c :hint) 'agent))
           (agent-session-backend-commands (agent-session-backend session) session))))

(defun agent-session--project-files (session)
  "Files in the project of SESSION (relative paths), for @ completion."
  (let ((default-directory (agent-session-root session)))
    (when-let* ((project (project-current nil default-directory)))
      (mapcar (lambda (f) (file-relative-name f default-directory))
              (seq-take (project-files project) 20000)))))

(defun agent-session--annotation-width (names)
  "Width of the annotation column in the completion popup.
That is the window width minus the longest of NAMES, clamped to 10-70
columns.  Also limit the corfu popup's maximum width to the session window
\(the agent column is usually narrow)."
  (let ((window (window-body-width)))
    (setq-local corfu-max-width (max 20 (1- window)))
    (max 10 (min 70 (- window (apply #'max 0 (mapcar #'string-width names)) 6)))))

(defun agent-session--command-annotation (command width)
  "Annotation for COMMAND: argument hint and description.
Padded or truncated to exactly WIDTH columns.  corfu right-aligns
annotations to the popup edge, so rows line up only if annotations have
equal width."
  (pcase-let ((`(,_name ,description ,hint ,source) command))
    (concat "  "
            (truncate-string-to-width
             (concat (if (and hint (not (string-empty-p hint)))
                         (propertize (concat hint " ") 'face 'completions-common-part)
                       "")
                     (propertize (concat (if (eq source 'local) "· " "") (or description ""))
                                 'face 'completions-annotations))
             width nil ?\s "…"))))

(defun agent-session-completion-at-point ()
  "Completion in the input area: /commands at line start, arguments, @files.
\"Line start\" means after the prompt or after a newline, since the prompt
shares a line with the input."
  (when-let* ((session agent-session--current)
              ((agent-session--in-input-p)))
    (let* ((start (max (line-beginning-position) (agent-session-input session)))
           (text (buffer-substring-no-properties start (point)))
           (exit (lambda (_name status) (when (eq status 'finished) (insert " ")))))
      (cond
       ;; Command argument: /model xxx
       ((and (string-match "\\`/\\([[:alnum:]-]+\\)[ \t]+\\([^ \t\n]*\\)\\'" text)
             (nth 3 (assoc (match-string 1 text) agent-session-local-commands)))
        (list (+ start (match-beginning 2)) (point)
              (funcall (nth 3 (assoc (match-string 1 text) agent-session-local-commands)) session)
              :exclusive 'no))
       ;; /command at line start
       ((string-match "\\`/[^ \t\n]*\\'" text)
        (let* ((candidates (agent-session--command-candidates session))
               (width (agent-session--annotation-width (mapcar #'car candidates))))
          (list start (point) (mapcar #'car candidates)
                :exclusive 'no
                :annotation-function
                (lambda (name)
                  (when-let* ((c (assoc name candidates)))
                    (agent-session--command-annotation c width)))
                :exit-function exit)))
       ;; @file, or @handle of another session
       ((string-match "\\(?:\\`\\|[ \t]\\)@\\([^ \t\n]*\\)\\'" text)
        (let ((sessions (agent-session--mention-candidates session)))
          (list (+ start (match-beginning 1)) (point)
                (completion-table-with-cache
                 (lambda (_) (append (mapcar #'car sessions)
                                     (agent-session--project-files session))))
                :exclusive 'no
                :category 'file
                :annotation-function
                (lambda (name)
                  (when-let* ((note (cdr (assoc name sessions))))
                    (concat "  " (propertize note 'face 'completions-annotations))))
                :exit-function exit)))))))

(defun agent-session--mention-candidates (session)
  "Handles of the sessions other than SESSION: ((HANDLE . NOTE) ...)."
  (seq-keep (lambda (buffer)
              (let ((other (buffer-local-value 'agent-session--current buffer)))
                (when-let* (((not (eq other session)))
                            (handle (agent-session-handle other)))
                  (cons handle (format "%s 会话 · %s" (agent-session-title other)
                                       (agent-session-display-title other))))))
            (agent-session-buffers)))

;;; Settings menu (C-c C-o)

(defun agent-session--menu-value (key)
  "Current value of setting KEY, as shown in the menu."
  (when-let* ((session agent-session--current))
    (propertize
     (pcase key
       (:agent (agent-session-title session))
       (:model (agent-session--model-label session))
       (:effort (or (agent-session-setting session :effort) "默认"))
       (:mode (agent-session--mode-label (agent-session-setting session :mode))))
     'face 'transient-value)))

(transient-define-prefix agent-session-menu ()
  "Session settings (agent, model, effort, permission mode) and actions."
  [["设置"
    ("a" agent-session-select-agent
     :description (lambda () (concat "Agent     " (agent-session--menu-value :agent))))
    ("m" agent-session-select-model
     :description (lambda () (concat "模型      " (agent-session--menu-value :model))))
    ("e" agent-session-select-effort
     :description (lambda () (concat "推理强度  " (agent-session--menu-value :effort))))
    ("p" agent-session-select-mode
     :description (lambda () (concat "权限模式  " (agent-session--menu-value :mode))))
    ("P" "计划模式开 / 关" agent-session-toggle-plan)]
   ["会话"
    ("n" "新会话" agent-session-new)
    ("r" "恢复历史会话" agent-session-resume)
    ("s" "会话列表" agent-session-list)]
   ["回合"
    ("k" "中断" agent-session-interrupt)
    ("g" "引导：最早的排队消息送进当前回合" agent-session-steer-queued)
    ("y" "允许" agent-session-approve)
    ("d" "拒绝" agent-session-deny)]])

;;; Mode

(defvar-keymap agent-session-mode-map
  :doc "Keys of agent sessions: RET sends in the input area, C-j adds a newline."
  "RET" #'agent-session-ret
  "C-j" #'newline
  "M-p" #'agent-session-previous-input
  "M-n" #'agent-session-next-input
  "TAB" #'agent-session-tab
  "<backtab>" #'backward-button
  "C-c C-c" #'agent-session-send-input
  "M-RET" #'agent-session-steer-input
  "C-c C-g" #'agent-session-steer-queued
  "C-c C-k" #'agent-session-cancel-dwim
  "C-c C-o" #'agent-session-menu
  "C-c C-y" #'agent-session-approve
  "C-c C-n" #'agent-session-deny
  "C-c C-i" #'agent-session-goto-input
  "C-c C-b" #'agent-session-previous-message
  "C-c C-f" #'agent-session-next-message
  "C-c C-s" #'agent-session-list
  "C-c C-a" #'agent-session-insert-image
  "<remap> <yank>" #'agent-session-yank)

(define-derived-mode agent-session-mode fundamental-mode "Agent"
  "Agent session rendered by Emacs (after telega).
The transcript is on top, the input area follows the footer.
\\{agent-session-mode-map}"
  (setq-local truncate-lines nil
              word-wrap t
              word-wrap-by-category t
              scroll-conservatively 101
              header-line-format nil
              mode-line-format '((:eval (agent-session--mode-line agent-session--current))))
  (cursor-intangible-mode 1)
  ;; Hide the markdown markup of finished replies (see `agent-session--markdown').
  (add-to-invisibility-spec 'markdown-markup)
  (setq-local dnd-protocol-alist (cons '("^file:" . agent-session--dnd-file) dnd-protocol-alist))
  (add-hook 'post-command-hook #'agent-session--keep-point-out-of-prompt nil t)
  (add-hook 'completion-at-point-functions #'agent-session-completion-at-point nil t)
  ;; Pop up completion right after typing /.
  (setq-local corfu-auto-prefix 1
              corfu-auto-delay 0.1)
  ;; Transcript text keeps being inserted before the input area, which would
  ;; garble undo positions, so disable undo.
  (buffer-disable-undo))

(defun agent-session--keep-point-out-of-prompt ()
  "Move point to the input start when it lands inside the prompt.
Same as telega; doesn't rely on when cursor-intangible redisplays."
  (when (and agent-session--current
             (eq (get-text-property (point) 'field) 'agent-session-prompt))
    (goto-char (agent-session-input agent-session--current))))

(defun agent-session--this ()
  "Session of the current buffer; signal an error if there is none."
  (or agent-session--current (user-error "不在 agent 会话中")))

(defun agent-session--setup-buffer (session)
  "Set up the buffer of SESSION.
That is the transcript, footer (separator, auxiliary lines, prompt) and input
area."
  (with-current-buffer (agent-session-buffer session)
    (agent-session-mode)
    (setq agent-session--current session)
    (let ((inhibit-read-only t))
      (erase-buffer))
    ;; The transcript is inserted at tail (which advances on insertion); the
    ;; footer sits between tail and input, and `agent-session--render-footer'
    ;; maintains both markers.
    (setf (agent-session-tail session) (copy-marker (point-min) t)
          (agent-session-input session) (copy-marker (point-min)))
    (agent-session--render-footer session)
    (goto-char (point-max))))

;;; Session management

(defun agent-session-buffer-p (buffer)
  "Return non-nil if BUFFER is an agent session."
  (and (buffer-live-p buffer)
       (buffer-local-value 'agent-session--current buffer)
       t))

(defun agent-session--root ()
  "Project root of the current context, else `default-directory'."
  (expand-file-name
   (if-let* ((project (project-current)))
       (project-root project)
     default-directory)))

(defun agent-session-buffers (&optional root agent)
  "Session buffers, most recently used first; optionally filtered by ROOT, AGENT."
  (seq-filter (lambda (buffer)
                (when-let* ((session (and (buffer-live-p buffer)
                                          (buffer-local-value 'agent-session--current buffer))))
                  (and (or (null root) (equal root (agent-session-root session)))
                       (or (null agent) (eq agent (agent-session-agent session))))))
              (buffer-list)))

(defun agent-session--visible-window ()
  "Window in the current frame showing a session."
  (seq-find (lambda (window) (agent-session-buffer-p (window-buffer window)))
            (window-list nil 'no-minibuf)))

(defun agent-session-target ()
  "Target session buffer for commands.
Visible one > most recent in this project > most recent anywhere."
  (or (when-let* ((window (agent-session--visible-window)))
        (window-buffer window))
      (car (agent-session-buffers (agent-session--root)))
      (car (agent-session-buffers))))

(defun agent-session-display (buffer)
  "Show BUFFER in the agent column on the right and return the window."
  (when-let* ((session (buffer-local-value 'agent-session--current buffer)))
    (when (plist-get (agent-session-info session) :unread)
      (setf (agent-session-info session) (plist-put (agent-session-info session) :unread nil))
      (agent-session--refresh session)))
  (or (get-buffer-window buffer)
      (when-let* ((window (agent-session--visible-window)))
        (set-window-buffer window buffer)
        window)
      (display-buffer buffer
                      `((display-buffer-in-direction)
                        (direction . right)
                        (window . main)
                        (window-width . ,agent-session-window-width)))))

(defun agent-session--read-agent ()
  "Choose a registered agent."
  (intern (completing-read "Agent: " (reverse (mapcar #'car agent-session-agents)) nil t)))

;;;###autoload
(defun agent-session-start (agent &optional new resume root)
  "Open an AGENT session for the current project.
With NEW non-nil (prefix arg), always create a new one.  RESUME is the id
of a past session to resume; ROOT defaults to the current project root."
  (interactive (list (agent-session--read-agent) current-prefix-arg))
  ;; Don't start the server in batch mode (tests): it would take over the user's
  ;; Emacs socket and delete it on exit.
  (unless (or noninteractive (server-running-p)) (server-start))
  (setq agent-session-default-agent agent)
  (let ((root (or root (agent-session--root))))
    (if-let* ((existing (if resume
                            (seq-find (lambda (b) (equal resume (agent-session-resume-id
                                                                 (buffer-local-value
                                                                  'agent-session--current b))))
                                      (agent-session-buffers))
                          (and (not new) (car (agent-session-buffers root agent))))))
        (select-window (agent-session-display existing))
      (let ((buffer (agent-session-open agent root resume)))
        (select-window (agent-session-display buffer))
        (goto-char (point-max))
        buffer))))

(defun agent-session-open (agent root &optional resume settings info)
  "Start an AGENT session in ROOT without showing it; return its buffer.
RESUME is the id of a past session to resume.  SETTINGS defaults to the
agent's latest settings; INFO is the initial info plist."
  (let* ((buffer (generate-new-buffer
                  (format "*%s@%s*" agent (file-name-nondirectory (directory-file-name root)))))
         (session (agent-session--make
                   :agent agent
                   :backend (or (agent-session--get agent :backend)
                                (user-error "未注册 agent：%s" agent))
                   :root root :buffer buffer
                   :info info
                   :state (and resume (list :resume resume))
                   :settings (or settings
                                 (copy-sequence
                                  (alist-get agent agent-session-last-settings))))))
    ;; A placeholder name until one is made from the topic (see agent-collab.el).
    (agent-session-set-handle session (symbol-name agent))
    (agent-session--setup-buffer session)
    (with-current-buffer buffer
      (setq default-directory root)
      (add-hook 'kill-buffer-hook
                (lambda ()
                  (agent-session-backend-stop (agent-session-backend session) session)
                  ;; The buffer isn't deleted yet; refresh the session list later.
                  (when agent-session--list-refresh-function
                    (run-at-time 0 nil agent-session--list-refresh-function)))
                nil t)
      (goto-char (point-max)))
    (agent-session-backend-start (agent-session-backend session) session)
    buffer))

;;;###autoload
(defun agent-session-create (&optional choose)
  "Create a session in the current project with the most recently used agent.
With CHOOSE (prefix arg), choose the agent first.  Within a session, agent,
model and reasoning effort can be switched any time with /agent or the
toolbar."
  (interactive "P")
  (let ((buffer (agent-session-start
                 (if (or choose (not (assq agent-session-default-agent agent-session-agents)))
                     (agent-session--read-agent)
                   agent-session-default-agent)
                 t)))
    ;; When called interactively, start typing the first message right away.
    (when (called-interactively-p 'interactive)
      (agent-session-focus-input (buffer-local-value 'agent-session--current buffer)))
    buffer))

;;;###autoload
(defun agent-session-toggle ()
  "Show or hide the agent column; without sessions, choose an agent to start."
  (interactive)
  (if-let* ((window (agent-session--visible-window)))
      (if (one-window-p) (switch-to-buffer (other-buffer)) (delete-window window))
    (if-let* ((buffer (agent-session-target)))
        (select-window (agent-session-display buffer))
      (agent-session-create))))

;;;###autoload
(defun agent-session-switch ()
  "Switch among all sessions."
  (interactive)
  (let ((buffers (mapcar #'buffer-name (agent-session-buffers))))
    (unless buffers (user-error "还没有 agent 会话"))
    (select-window (agent-session-display
                    (get-buffer (completing-read "会话: " buffers nil t))))))

(defun agent-session-kill ()
  "End the current (or target) session."
  (interactive)
  (let ((buffer (if (agent-session-buffer-p (current-buffer))
                    (current-buffer)
                  (agent-session-target))))
    (unless buffer (user-error "没有 agent 会话"))
    (when (yes-or-no-p (format "结束 %s？" (buffer-name buffer)))
      (kill-buffer buffer))))

;;; Referencing code buffers into the input area

(defun agent-session-insert-input (buffer text)
  "Insert TEXT at the end of the input area of session BUFFER and focus it."
  (with-current-buffer buffer
    (goto-char (point-max))
    (unless (or (= (point) (agent-session-input agent-session--current))
                (memq (char-before) '(?\s ?\n)))
      (insert " "))
    (insert text))
  (agent-session-focus-input (buffer-local-value 'agent-session--current buffer))
  buffer)

;;;###autoload
(defun agent-session-insert-reference ()
  "Bring a reference to the current file into the session input.
With an active region, include its line range."
  (interactive)
  (let* ((buffer (or (agent-session-target) (user-error "没有 agent 会话")))
         (root (agent-session-root (buffer-local-value 'agent-session--current buffer)))
         (file (or buffer-file-name (user-error "当前 buffer 没有对应文件")))
         (lines (and (use-region-p)
                     (format ":%d-%d" (line-number-at-pos (region-beginning))
                             (line-number-at-pos (max (region-beginning) (1- (region-end))))))))
    (deactivate-mark)
    (agent-session-insert-input buffer (concat (file-relative-name file root) lines " "))))

;;;###autoload
(defun agent-session-insert-region (start end)
  "Bring code from START to END and its origin into the input as a code block."
  (interactive "r")
  (let* ((buffer (or (agent-session-target) (user-error "没有 agent 会话")))
         (root (agent-session-root (buffer-local-value 'agent-session--current buffer)))
         (where (if buffer-file-name
                    (format "%s:%d-%d" (file-relative-name buffer-file-name root)
                            (line-number-at-pos start)
                            (line-number-at-pos (max start (1- end))))
                  (buffer-name)))
         (lang (string-remove-suffix "-ts" (string-remove-suffix "-mode" (symbol-name major-mode))))
         (code (buffer-substring-no-properties start end)))
    (deactivate-mark)
    (agent-session-insert-input buffer (format "\n%s\n```%s\n%s\n```\n" where lang code))))

;;; Registering agents

(defvar-keymap agent-session-command-map
  :doc "Prefix map of agent commands (C-c a)."
  "a" #'agent-session-toggle
  "i" #'agent-session-focus-input
  "n" #'agent-session-create
  "s" #'agent-session-list
  "k" #'agent-session-kill
  "f" #'agent-session-insert-reference
  "r" #'agent-session-insert-region)

(defmacro agent-session-define-agent (name &rest plist)
  "Register agent NAME and define the command agent-session-NAME.
PLIST: :backend the backend symbol (default NAME), :title the display
name, :key the key that starts it in `agent-session-command-map'."
  (declare (indent 1))
  (let ((command (intern (format "agent-session-%s" name)))
        (key (plist-get plist :key)))
    `(progn
       (setf (alist-get ',name agent-session-agents)
             (list :backend ',(or (plist-get plist :backend) name)
                   :title ,(or (plist-get plist :title) (capitalize (symbol-name name)))
                   :key ,key))
       (defun ,command (&optional new)
         ,(format "Open a %s session for the current project.
With a prefix arg, create a new one." name)
         (interactive "P")
         (agent-session-start ',name new))
       ,(when key `(keymap-set agent-session-command-map ,key #',command))
       ',command)))

(provide 'agent-session)
;;; agent-session.el ends here
