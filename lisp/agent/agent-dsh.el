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

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)

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

(defun agent-dsh--command ()
  "Command line that starts the bridge."
  (list agent-dsh-executable "--profile" "sdk" "--patch" agent-dsh--patch))

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
  (agent-session-start-process session (agent-dsh--command))
  (agent-dsh--request
   session "initialize"
   (append (list :cwd (directory-file-name (expand-file-name (agent-session-root session))))
           (when-let* ((resume (agent-dsh--state session :resume))) (list :resume resume))
           (when-let* ((model (agent-session-setting session :model))) (list :model model))
           (when-let* ((effort (agent-session-setting session :effort))) (list :effort effort)))
   (lambda (result)
     (agent-dsh--set session :resume (plist-get result :sessionId))
     (agent-session-set-info session :model (plist-get result :model))
     (agent-session-set-status session 'idle))))

(cl-defmethod agent-session-backend-modes ((_ (eql dsh)) _session)
  ;; Permission modes are not wired to dsh presets yet; approvals always ask.
  '(ask))

(cl-defmethod agent-session-backend-send ((_ (eql dsh)) session text)
  (agent-dsh--request session "prompt" (list :text (agent-session-message-text text))))

(cl-defmethod agent-session-backend-interrupt ((_ (eql dsh)) session)
  (agent-dsh--request session "cancel" nil))

;;; Tool display

(defun agent-dsh--arguments (arguments)
  "Parse the tool call ARGUMENTS JSON string into a plist."
  (and (stringp arguments)
       (ignore-errors (json-parse-string arguments :object-type 'plist
                                         :null-object nil :false-object nil))))

(defun agent-dsh--relative (session path)
  "PATH relative to the project root of SESSION."
  (if (and (stringp path) (file-name-absolute-p path))
      (file-relative-name path (agent-session-root session))
    path))

(defun agent-dsh--tool-view (session name arguments)
  "Display properties of tool NAME called with ARGUMENTS (a plist)."
  (let ((path (agent-dsh--relative session (or (plist-get arguments :path)
                                               (plist-get arguments :file_path)))))
    (pcase name
      ("bash" (list :kind 'command
                    :title (car (split-string (string-trim (or (plist-get arguments :command) ""))
                                              "\n"))))
      ((or "read" "read_image") (list :kind 'read :title path))
      ((or "edit" "write") (list :kind 'edit :title path))
      ((or "grep" "glob") (list :kind 'search :title (plist-get arguments :pattern)))
      ((or "web_fetch" "web_search")
       (list :kind 'web :title (or (plist-get arguments :url) (plist-get arguments :query))))
      ("todo_write" (list :kind 'plan :title "待办"))
      (_ (list :kind 'other :title (or path name))))))

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

;;; Message handling

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
      (if (equal method "approval")
          (agent-dsh--approval session id params)
        (agent-session-write session (list :jsonrpc "2.0" :id id
                                           :error (list :code -32601
                                                        :message (format "unsupported: %s" method))))))
     ;; Notification
     (t
      (pcase method
        ("status"
         (agent-session-set-status session (if (equal (plist-get params :status) "running")
                                               'running 'idle)))
        ("text"
         (agent-session-text session (plist-get params :id) (plist-get params :delta)
                             (if (equal (plist-get params :kind) "thinking") 'thinking 'assistant)))
        ("text/done"
         (agent-session-text-done session (plist-get params :id) (plist-get params :text)))
        ("discard"
         (seq-doseq (block (plist-get params :ids))
           (agent-session--remove-block session block)))
        ("tool"
         (apply #'agent-session-tool session (plist-get params :id) :status 'running
                (agent-dsh--tool-view session (plist-get params :name)
                                      (agent-dsh--arguments (plist-get params :arguments)))))
        ("tool/done"
         (agent-session-tool session (plist-get params :id)
                             :status (if (plist-get params :isError) 'error 'ok)
                             :output (plist-get params :output)))
        ;; Failed turns are already reported through "error".
        ("turn/end"
         (when (equal (plist-get params :reason) "max-tokens")
           (agent-session-notice session "输出达到 token 上限" 'agent-session-error)))
        ("usage"
         (agent-session-set-info session :tokens
                                 (plist-get (plist-get params :usage) :totalTokens)))
        ("error"
         (agent-session-notice session (format "出错：%s" (plist-get params :message))
                               'agent-session-error)))))))

(provide 'agent-dsh)
;;; agent-dsh.el ends here
