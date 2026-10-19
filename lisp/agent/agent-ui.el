;;; agent-ui.el --- Interface for agents to operate Emacs -*- lexical-binding: t; -*-

;;; Commentary:

;; Agents call the methods registered here through bin/emx (command line or MCP).
;;
;; Protocol: emx writes {"method": ..., "params": {...}} to a request file,
;; runs emacsclient --eval '(agent-ui-rpc REQ RES)', then reads
;; {"ok": true, "result": ...} or {"ok": false, "error": "..."} from the response file.
;; Going through files instead of command-line arguments means arbitrary content
;; such as HTML or code needs no escaping.
;;
;; Extending: define a new method with `agent-ui-defmethod'; the MCP tool list
;; picks it up automatically.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'flymake)
(require 'project)
(require 'agent-session)
(require 'agent-session-list)
(require 'init-reload)


(defgroup agent-ui nil
  "Interface for agents to operate Emacs."
  :group 'tools
  :prefix "agent-ui-")

(defcustom agent-ui-max-text 200000
  "Maximum number of characters returned when reading buffer text."
  :type 'integer)

;;; Method registration

(defvar agent-ui-caller nil
  "Current caller info, e.g. (:agent_buffer \"*agent:claude@proj*\").
emx fills it in from the environment of the agent session it runs in;
methods can read it directly.")

(defvar agent-ui--methods nil
  "Registered methods: ((NAME . (:function F :description D :params SPEC)) ...).")

(defmacro agent-ui-defmethod (name params docstring &rest body)
  "Define NAME (a string) as a method callable by agents.
Each entry of PARAMS is (SYMBOL TYPE DESCRIPTION [required]), where TYPE is a
JSON Schema type symbol: string, integer, boolean, array (an array of objects)
or object.  BODY can use variables named after the parameters directly; its
return value (plist / vector / string / number) is serialized as JSON."
  (declare (indent 2) (doc-string 3))
  (let ((fn (intern (format "agent-ui--method-%s" name)))
        (vars (mapcar #'car params)))
    `(progn
       (defun ,fn (params)
         ,docstring
         (let ,(mapcar (lambda (var)
                         `(,var (plist-get params ,(intern (format ":%s" var)))))
                       vars)
           (ignore params ,@vars)
           ,@body))
       (setf (alist-get ,name agent-ui--methods nil nil #'equal)
             (list :function #',fn :description ,docstring :params ',params))
       ,name)))

(defun agent-ui--coerce (params spec)
  "Convert strings in PARAMS to the types declared in SPEC.
Everything passed on the command line arrives as a string."
  (dolist (entry spec params)
    (let* ((key (intern (format ":%s" (car entry))))
           (value (plist-get params key)))
      (when (stringp value)
        (pcase (nth 1 entry)
          ('integer (setq params (plist-put params key (string-to-number value))))
          ('boolean (setq params (plist-put params key
                                             (member value '("true" "1" "yes"))))))))))

(defun agent-ui--check-required (name params spec)
  "Signal an error if PARAMS lacks a parameter that SPEC marks as required.
NAME is the method name used in the error message."
  (dolist (entry spec)
    (when (and (memq 'required entry)
               (null (plist-get params (intern (format ":%s" (car entry))))))
      (error "%s: missing required parameter %s" name (car entry)))))

(defun agent-ui--schema (spec)
  "Convert the parameter SPEC to a JSON Schema."
  (let (properties required)
    (dolist (entry spec)
      (setq properties
            (plist-put properties (intern (format ":%s" (car entry)))
                       (append (pcase (nth 1 entry)
                                 ('array (list :type "array" :items (list :type "object")))
                                 (type (list :type (symbol-name type))))
                               (list :description (nth 2 entry)))))
      (when (memq 'required entry)
        (push (symbol-name (car entry)) required)))
    (list :type "object"
          :properties (or properties (make-hash-table))
          :required (vconcat (nreverse required)))))

(defun agent-ui--json-value (value)
  "Return VALUE, converting nil to JSON null."
  (if (null value) :null value))

;;; Deferred results
;;
;; A method that waits for something slow (another agent's reply) must not block
;; Emacs.  It returns `agent-ui-defer' at once; emx then calls the internal
;; method _poll about once a second until the result is ready.

(defvar agent-ui--deferred (make-hash-table :test #'equal)
  "Pending results: ID -> (:poll FN :deadline TIME :timeout FN :cancel FN).")

(defun agent-ui-defer (poll &rest props)
  "Return a deferred result, to be produced by POLL.
POLL is called on every poll with no arguments and returns nil while the
result is pending, else a list whose car is the result; an error it
signals is the method's error.  PROPS: :wait seconds until :timeout, a
function returning the result then; :cancel, called when the caller gives
up."
  (let ((id (format "%s-%s" (float-time) (random 100000)))
        (now (float-time)))
    ;; Drop results whose caller went away without polling to the end.
    (maphash (lambda (key entry)
               (when (> now (+ (plist-get entry :deadline) 300))
                 (remhash key agent-ui--deferred)))
             agent-ui--deferred)
    (puthash id (list :poll poll
                      :deadline (+ now (or (plist-get props :wait) 3600))
                      :timeout (plist-get props :timeout)
                      :cancel (plist-get props :cancel))
             agent-ui--deferred)
    (list :agent-ui-pending id)))

(defun agent-ui--poll (id cancel)
  "Poll deferred result ID; with CANCEL, give it up instead."
  (let ((entry (or (gethash id agent-ui--deferred)
                   (error "No pending result %s" id))))
    (cond
     (cancel
      (remhash id agent-ui--deferred)
      (when-let* ((fn (plist-get entry :cancel))) (funcall fn))
      nil)
     ((condition-case err
          (when-let* ((done (funcall (plist-get entry :poll))))
            (remhash id agent-ui--deferred)
            (car done))
        (error (remhash id agent-ui--deferred)
               (signal (car err) (cdr err)))))
     ((> (float-time) (plist-get entry :deadline))
      (remhash id agent-ui--deferred)
      (if-let* ((fn (plist-get entry :timeout))) (funcall fn) (error "Timed out")))
     (t (list :agent-ui-pending id)))))

;;;###autoload
(defun agent-ui-rpc (request-file response-file)
  "Run the call in REQUEST-FILE and write the result to RESPONSE-FILE.
Used by emx."
  (let ((response
         (condition-case err
             (let* ((request (with-temp-buffer
                               (let ((coding-system-for-read 'utf-8))
                                 (insert-file-contents request-file))
                               (json-parse-buffer :object-type 'plist
                                                  :null-object nil
                                                  :false-object nil)))
                    (method (plist-get request :method))
                    (agent-ui-caller (plist-get request :context))
                    (result
                     (if (equal method "_poll")
                         (let ((params (plist-get request :params)))
                           (agent-ui--poll (plist-get params :id) (plist-get params :cancel)))
                       (let* ((entry (or (alist-get method agent-ui--methods nil nil #'equal)
                                         (error "Unknown method: %s" method)))
                              (spec (plist-get entry :params))
                              (params (agent-ui--coerce (plist-get request :params) spec)))
                         (agent-ui--check-required method params spec)
                         (funcall (plist-get entry :function) params)))))
               (if (eq (car-safe result) :agent-ui-pending)
                   (list :ok t :pending (cadr result))
                 (list :ok t :result (agent-ui--json-value result))))
           (error (list :ok :false :error (error-message-string err))))))
    (with-temp-buffer
      (condition-case err
          (json-insert response :null-object :null :false-object :false)
        (error
         (erase-buffer)
         (json-insert (list :ok :false
                            :error (format "Result cannot be serialized as JSON: %S" err)))))
      (let ((coding-system-for-write 'utf-8))
        (write-region nil nil response-file nil 'silent)))
    t))

;;; Windows

(defun agent-ui--frame ()
  "Return the frame agents operate on, preferring a visible graphical frame."
  (or (seq-find (lambda (frame) (and (frame-visible-p frame) (display-graphic-p frame)))
                (cons (selected-frame) (frame-list)))
      (selected-frame)))

(defun agent-ui--main-window ()
  "Return the user's working window: the most recently used non-agent window.
If there is none, split a new one to the left of the agent column."
  (let* ((frame (agent-ui--frame))
         (windows (seq-remove (lambda (window)
                                (or (agent-session-buffer-p (window-buffer window))
                                    (window-parameter window 'window-side)
                                    (window-dedicated-p window)))
                              (window-list frame 'no-minibuf))))
    (or (car (sort windows :key #'window-use-time :reverse t))
        (split-window (frame-root-window frame) nil 'left))))

(defun agent-ui--show-buffer (buffer)
  "Show BUFFER in the working window without stealing focus; return the window."
  (let ((window (agent-ui--main-window)))
    (with-selected-window window
      (switch-to-buffer buffer nil t))
    window))

(defun agent-ui--view-buffer (title)
  "Return the view buffer named after TITLE, erasing it if it already exists."
  (let ((buffer (get-buffer-create (format "*agent-view: %s*" (or title "agent")))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (when (bound-and-true-p view-mode) (view-mode -1))
        (erase-buffer)))
    buffer))

(defun agent-ui-caller-session ()
  "The calling agent session, or nil."
  (when-let* ((name (plist-get agent-ui-caller :agent_buffer))
              (buffer (get-buffer name))
              ((agent-session-buffer-p buffer)))
    (buffer-local-value 'agent-session--current buffer)))

(defun agent-ui--caller-root ()
  "Project root of the calling agent session, or nil."
  (when-let* ((session (agent-ui-caller-session)))
    (agent-session-root session)))

(defun agent-ui--abs (path)
  "Return the absolute path of PATH; signal an error if the file does not exist.
PATH is as the calling agent sees it: an agent of a remote project names
files on its host."
  (let ((file (if-let* ((root (agent-ui--caller-root)))
                  (agent-session-expand-file-name path root)
                (expand-file-name path))))
    (unless (file-exists-p file) (error "No such file: %s" file))
    file))

;;; Methods: inspect the user's context

(defun agent-ui--window-info (window)
  "Return a serializable description of WINDOW."
  (with-current-buffer (window-buffer window)
    (list :buffer (buffer-name)
          :file (agent-ui--json-value buffer-file-name)
          :mode (symbol-name major-mode)
          :first_line (line-number-at-pos (window-start window))
          :last_line (line-number-at-pos (max (window-start window)
                                              (1- (window-end window t)))))))

(agent-ui-defmethod "context" ()
  "Return what the user is looking at: the file in the main window, cursor line and column,
selected text, project root, and every visible window."
  (let* ((window (agent-ui--main-window))
         (buffer (window-buffer window)))
    (with-current-buffer buffer
      (let ((point (window-point window)))
        (append
         (agent-ui--window-info window)
         (list :line (line-number-at-pos point)
               :column (save-excursion (goto-char point) (current-column))
               :selection (agent-ui--json-value
                           (and (region-active-p)
                                (buffer-substring-no-properties (region-beginning)
                                                                (region-end))))
               :project (agent-ui--json-value
                         (when-let* ((project (project-current)))
                           (expand-file-name (project-root project))))
               :visible (vconcat (mapcar #'agent-ui--window-info
                                         (window-list (agent-ui--frame) 'no-minibuf)))))))))

(agent-ui-defmethod "buffers" ()
  "List open buffers: name, file, whether there are unsaved changes, and major mode."
  (vconcat
   (seq-keep (lambda (buffer)
               (let ((name (buffer-name buffer)))
                 (unless (string-prefix-p " " name)
                   (with-current-buffer buffer
                     (list :name name
                           :file (agent-ui--json-value buffer-file-name)
                           :modified (if (and buffer-file-name (buffer-modified-p)) t :false)
                           :mode (symbol-name major-mode))))))
             (buffer-list))))

(agent-ui-defmethod "read_buffer"
    ((name string "Buffer name, e.g. *compilation*" required)
     (start_line integer "First line (inclusive), default 1")
     (end_line integer "Last line (inclusive), default end of buffer"))
  "Read buffer text: unsaved changes, compilation output, REPLs and other non-file content."
  (with-current-buffer (or (get-buffer name) (error "No buffer named %s" name))
    (save-excursion
      (save-restriction
        (widen)
        (let* ((start (progn (goto-char (point-min))
                             (forward-line (1- (or start_line 1)))
                             (point)))
               (end (if end_line
                        (progn (goto-char (point-min)) (forward-line end_line) (point))
                      (point-max)))
               (text (buffer-substring-no-properties start (max start end))))
          (if (> (length text) agent-ui-max-text)
              (concat (substring text 0 agent-ui-max-text) "\n… (truncated)")
            text))))))

(defun agent-ui--severity (type)
  "Return a short name for the flymake diagnostic type TYPE."
  (pcase (flymake--lookup-type-property type 'flymake-category)
    ('flymake-error "error")
    ('flymake-warning "warning")
    (_ "note")))

(agent-ui-defmethod "diagnostics"
    ((path string "File path; defaults to the user's current file"))
  "Return flymake / LSP diagnostics for a file (line, column, severity, message)."
  (let ((buffer (if path
                    (find-file-noselect (agent-ui--abs path))
                  (window-buffer (agent-ui--main-window)))))
    (with-current-buffer buffer
      (vconcat
       (mapcar (lambda (diag)
                 (let ((beg (flymake-diagnostic-beg diag)))
                   (list :line (line-number-at-pos beg)
                         :column (save-excursion (goto-char beg) (current-column))
                         :severity (agent-ui--severity (flymake-diagnostic-type diag))
                         :message (flymake-diagnostic-text diag))))
               (sort (flymake-diagnostics) :key #'flymake-diagnostic-beg))))))

;;; Methods: operate the editor

(agent-ui-defmethod "open"
    ((path string "File path" required)
     (line integer "Line to jump to")
     (end_line integer "Last line of the highlighted range")
     (column integer "Column"))
  "Open a file in the user's main window, jump to a position and highlight the lines,
to guide the user to a piece of code."
  (let* ((buffer (find-file-noselect (agent-ui--abs path)))
         (window (agent-ui--show-buffer buffer)))
    (with-selected-window window
      (when line
        (goto-char (point-min))
        (forward-line (1- line))
        (when column (move-to-column column))
        (recenter)
        (let ((start (line-beginning-position))
              (end (save-excursion
                     (forward-line (- (or end_line line) line))
                     (line-end-position))))
          (pulse-momentary-highlight-region start end))))
    (list :buffer (buffer-name buffer))))

(defun agent-ui--setup-view (format)
  "Set the mode of the current view buffer according to FORMAT."
  (pcase format
    ("org" (org-mode))
    ((or "markdown" "md")
     (require 'markdown-mode)
     (gfm-view-mode))
    ("diff" (diff-mode))
    ((or "text" "" 'nil) (text-mode))
    (_ (let ((ts (intern (format "%s-ts-mode" format)))
             (plain (intern (format "%s-mode" format))))
         (cond ((fboundp ts) (funcall ts))
               ((fboundp plain) (funcall plain))
               (t (text-mode)))))))

(agent-ui-defmethod "show"
    ((content string "Text to display")
     (path string "Read the content from this file instead of content")
     (format string "org / markdown / diff / text, or a language name such as rust or json")
     (title string "Title of the view buffer; the same title reuses the same buffer"))
  "Show read-only content in the user's main window: reports, plans, org tables, diffs,
code snippets and so on."
  (unless (or content path) (error "Either content or path is required"))
  (let ((buffer (agent-ui--view-buffer title)))
    (with-current-buffer buffer
      (if content
          (insert content)
        (insert-file-contents (agent-ui--abs path))
        (setq default-directory (file-name-directory (agent-ui--abs path))))
      (goto-char (point-min))
      (agent-ui--setup-view (or format
                                (and path (file-name-extension path))
                                "text"))
      (view-mode 1))
    (agent-ui--show-buffer buffer)
    (list :buffer (buffer-name buffer))))

;;; Methods: general

(agent-ui-defmethod "notify"
    ((message string "Notification text" required)
     (title string "Title, default Agent"))
  "Notify the user in the echo area; also sends a system notification when Emacs is not
in the foreground."
  (let ((title (or title "Agent")))
    (message "[%s] %s" title message)
    (when (and (eq system-type 'darwin)
               (not (eq (frame-focus-state (agent-ui--frame)) t)))
      (call-process "osascript" nil 0 nil "-e"
                    (format "display notification %S with title %S" message title)))
    t))

(agent-ui-defmethod "alert"
    ((reason string "Why you need the user, shown when the mouse is on your entry"))
  "Ask for the user's attention: your session's entry in the session list flashes red
and stays pink until the user opens your session.  Use it when you finish a long task
the user is waiting for, or when you are blocked on a decision only the user can make;
not for ordinary replies."
  (let ((session (or (agent-ui-caller-session) (error "Only an agent session can ask for attention"))))
    (agent-session-list-alert (agent-session-buffer session) reason)
    t))

(agent-ui-defmethod "eval"
    ((code string "Emacs Lisp code; may contain several forms" required))
  "Evaluate arbitrary Elisp in Emacs and return the printed value of the last form.
Use it for operations the other methods do not cover, such as changing the window
layout or calling a mode's commands."
  (prin1-to-string (eval (car (read-from-string (concat "(progn " code "\n)"))) t)))

(defun agent-ui--reload-entry (entry)
  "Convert ENTRY of a `my/reload-config' report to JSON-ready form."
  (let (json)
    (cl-loop for (key value) on entry by #'cddr
             when value
             do (setq json (plist-put json key
                                      (cond ((stringp value) value)
                                            ((symbolp value) (symbol-name value))
                                            (t (vconcat (mapcar (lambda (item)
                                                                  (format "%s" item))
                                                                value)))))))
    json))

(agent-ui-defmethod "reload"
    ((files string "Files to reload, separated by spaces, relative to the Emacs \
configuration root or absolute. Default: every loaded configuration file changed \
on disk since it was loaded"))
  "Apply edited Emacs configuration files to the running Emacs, no restart.
Call it once your edits are done, instead of loading the files through eval.
Files load in dependency order, byte-compiled first so their functions run
compiled; compiler warnings are returned per file, and a file that does not
compile is not loaded.  Unlike a plain load, keymap definitions are
merged into the live keymaps, options nobody customized move to their new
default and changed faces are applied; other defvars keep their state.  A file
whose struct layout changed, and init.el, are not loaded: they report
restart_required."
  (let* ((report (my/reload-config (and files (split-string files))))
         (statuses (mapcar (lambda (entry) (plist-get entry :status)) report)))
    (list :files (vconcat (mapcar #'agent-ui--reload-entry report))
          :next_step
          (agent-ui--json-value
           (cond ((null report)
                  "Nothing to reload: no loaded configuration file changed on disk.")
                 ((memq 'failed statuses)
                  "Fix the errors and call reload again.  A file that failed \
to compile was not loaded; one that failed while loading may be partly loaded.")
                 ((memq 'restart_required statuses)
                  "Tell the user these changes take effect after restarting \
Emacs."))))))

(defvar agent-ui-description-functions nil
  "Functions extending method descriptions: ((NAME . FUNCTION) ...).
FUNCTION returns text appended to the description of method NAME when
agents list the methods, such as choices that come from the user's
configuration.  It must not depend on the calling session: a forked
session has to see exactly its parent's tools, or it loses the prompt
cache it shares with the parent.")

(defun agent-ui--describe ()
  "The methods for agents: their names, descriptions and parameter schemas."
  (vconcat
   (seq-keep (pcase-lambda (`(,name . ,entry))
               (unless (equal name "describe")
                 (list :name name
                       :description
                       (concat (plist-get entry :description)
                               (when-let* ((fn (alist-get name agent-ui-description-functions
                                                          nil nil #'equal)))
                                 (concat "\n\n" (funcall fn))))
                       :inputSchema (agent-ui--schema (plist-get entry :params)))))
             (reverse agent-ui--methods))))

(agent-ui-defmethod "describe" ()
  "List all methods with their parameter schemas (used by emx help and MCP tools/list)."
  (agent-ui--describe))

;;; Announcing changed methods
;;
;; Agents read the methods as MCP tools when they start.  When they change
;; (a reload, a changed profile), the file `agent-session-tools-stamp' gets
;; their new signature; each emx watches it and tells its client to list the
;; tools again.  Claude and dsh do; Codex doesn't, so its backend compares
;; the signature it started with before each send.

(defun agent-ui-tools-signature ()
  "A hash of the methods as agents see them, which changes with any of them."
  (secure-hash 'sha1 (json-serialize (agent-ui--describe)
                                     :null-object :null :false-object :false)))

(defvar agent-ui--tools-signature nil
  "The signature last written to the stamp file.")

(defun agent-ui--update-tools-stamp ()
  "Write the signature of the methods to the stamp file if it changed."
  ;; From a timer: a module half reloaded mustn't raise errors here.
  (ignore-errors
    (let ((signature (agent-ui-tools-signature))
          (file (agent-session-tools-stamp)))
      (unless (equal signature agent-ui--tools-signature)
        (unless (equal signature (ignore-errors
                                   (with-temp-buffer
                                     (insert-file-contents file)
                                     (buffer-string))))
          (make-directory (file-name-directory file) t)
          (write-region signature nil file nil 'silent))
        ;; Only once written: a failed write is tried again.
        (setq agent-ui--tools-signature signature)))))

(defvar agent-ui--tools-timer nil
  "Timer running `agent-ui--update-tools-stamp'.")

;; Not an idle timer: that repeats only once Emacs stopped being idle, and
;; the emacsclient calls of emx and reload don't count.  A check takes about
;; 0.1 ms.  Batch Emacs serves no agents; a reload replaces the timer.
(unless noninteractive
  (when (timerp agent-ui--tools-timer)
    (cancel-timer agent-ui--tools-timer))
  (setq agent-ui--tools-timer (run-with-timer 2 2 #'agent-ui--update-tools-stamp)))

;;; Buffers of files written by emx

;; emx's config_* methods write files themselves; they ask these first and after.

(defun agent-ui-file-modified-p (file)
  "Non-nil if a buffer visiting FILE has unsaved changes."
  (when-let* ((buffer (find-buffer-visiting file)))
    (and (buffer-modified-p buffer) t)))

(defun agent-ui-file-written (file)
  "Revert the buffer visiting FILE after an agent wrote it, unless it is modified."
  (when-let* ((buffer (find-buffer-visiting file)))
    (with-current-buffer buffer
      (unless (buffer-modified-p)
        (revert-buffer t t t))))
  nil)

;;; Interactive commands

(defun agent-ui-last-view ()
  "Go back to the content an agent displayed most recently."
  (interactive)
  (let ((buffer (seq-find (lambda (buffer)
                            (string-match-p "\\`\\*agent-\\(view\\|canvas\\):"
                                            (buffer-name buffer)))
                          (buffer-list))))
    (unless buffer (user-error "agent 还没有展示过内容"))
    (select-window (agent-ui--show-buffer buffer))))

(provide 'agent-ui)
;;; agent-ui.el ends here
