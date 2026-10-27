;;; agent-session-quick.el --- One-shot requests from the minibuffer -*- lexical-binding: t; -*-

;;; Commentary:
;; A quick request is a single message typed in the minibuffer: a simple
;; operation (open some file) or a short question, with no back and forth.
;; It runs in a session of its own that isn't shown.  When the turn ends,
;; the reply goes to the echo area and the session closes.  The session is
;; shown instead when its agent needs the user (a confirmation or
;; questions), when the reply is too long for the echo area, or when the
;; agent exits.

;;; Code:

(require 'agent-session)

(defcustom agent-session-quick-agent 'pi
  "Agent that runs quick requests."
  :type 'symbol
  :group 'agent-session)

(defcustom agent-session-quick-settings
  '(:model "opencode-go/deepseek-v4.1-flash" :effort "low" :mode auto)
  "Settings of quick request sessions (:model :effort :mode)."
  :type 'plist
  :group 'agent-session)

(defcustom agent-session-quick-echo-lines 4
  "Longest reply, in screen lines, shown in the echo area.
A longer reply is shown in its session."
  :type 'natnum
  :group 'agent-session)

(defvar agent-session-quick-history nil
  "Requests typed for `agent-session-quick'.")
(defvar savehist-additional-variables)
(with-eval-after-load 'savehist
  (add-to-list 'savehist-additional-variables 'agent-session-quick-history))

(defconst agent-session-quick--note
  "This is a one-shot request typed in the Emacs minibuffer; the user \
won't reply.  Do it directly without follow-up questions, and don't start \
other sessions.  Use the Emacs tools for editor actions such as opening a \
file.  Answer in one or two short sentences, in the user's language; the \
answer is shown in the echo area.  Don't call alert or notify."
  "Note for the agent sent after a quick request, not shown.")

(defun agent-session-quick--context ()
  "Describe where the user was when typing the request, or nil."
  (unless (or (minibufferp) (agent-session-buffer-p (current-buffer)))
    (if buffer-file-name
        (format "The user is in %s at line %d."
                (file-local-name buffer-file-name) (line-number-at-pos))
      (format "The user is in the Emacs buffer %s." (buffer-name)))))

(defun agent-session-quick--quick-p (session)
  "Non-nil if SESSION runs a quick request."
  (plist-get (agent-session-info session) :quick))

(defun agent-session-quick--reply (session)
  "Text of the last reply of SESSION, or nil."
  (when-let* ((entry (seq-find (lambda (entry)
                                 (and (eq (plist-get (cdr entry) :type) 'text)
                                      (eq (plist-get (cdr entry) :kind) 'assistant)))
                               (reverse (agent-session--blocks-in-order session)))))
    (string-trim (plist-get (cdr entry) :text))))

(defun agent-session-quick--lines (text)
  "Screen lines TEXT takes in the echo area."
  (let ((width (max 1 (1- (frame-width)))))
    (apply #'+ (mapcar (lambda (line) (max 1 (ceiling (string-width line) (float width))))
                       (split-string text "\n")))))

(defun agent-session-quick--show (session)
  "Show SESSION, which stays open, and stop treating it as quick."
  (setf (agent-session-info session) (plist-put (agent-session-info session) :quick nil))
  (agent-session-display (agent-session-buffer session)))

(defun agent-session-quick--turn-end (session previous)
  "Report the reply of quick SESSION once its turn ends after PREVIOUS."
  (when (and (agent-session-quick--quick-p session)
             (buffer-live-p (agent-session-buffer session)))
    (pcase (agent-session-status session)
      ('exited
       (message "快捷请求的 agent 已退出")
       (agent-session-quick--show session))
      ((and 'idle (guard (eq previous 'running))
            (guard (null (agent-session-queue session))))
       (let ((reply (agent-session-quick--reply session)))
         (if (and reply (> (agent-session-quick--lines reply)
                           agent-session-quick-echo-lines))
             (progn (agent-session-quick--show session)
                    (message "回复较长，已打开会话"))
           (message "%s" (if (and reply (not (string-empty-p reply))) reply "已完成"))
           ;; Not from within the status change that called us.
           (run-at-time 0 nil #'agent-session-kill-quietly
                        (agent-session-buffer session))))))))

(defun agent-session-quick--ask (session _id)
  "Show quick SESSION, whose agent waits for the user's answer."
  (when (agent-session-quick--quick-p session)
    (agent-session-quick--show session)))

(add-hook 'agent-session-status-functions #'agent-session-quick--turn-end)
(add-hook 'agent-session-ask-functions #'agent-session-quick--ask)

;;;###autoload
(defun agent-session-quick (text)
  "Send TEXT to an agent as a one-shot request in the current project.
The reply is shown in the echo area; see `agent-session-quick-agent' and
`agent-session-quick-settings' for who answers."
  (interactive (list (read-string "问 AI：" nil 'agent-session-quick-history)))
  (let ((text (string-trim text)))
    (when (string-empty-p text) (user-error "请求为空"))
    (let* ((root (agent-session--root))
           (hidden (string-join (delq nil (list agent-session-quick--note
                                                (agent-session-quick--context)))
                                "\n"))
           (buffer (agent-session-open agent-session-quick-agent root nil
                                       (copy-sequence agent-session-quick-settings)
                                       (list :quick t)))
           (session (buffer-local-value 'agent-session--current buffer)))
      (agent-session-submit session text nil hidden)
      ;; A fast reply may already be in the echo area.
      (when (and (agent-session-quick--quick-p session)
                 (memq (agent-session-status session) '(starting running)))
        (message "已交给 %s：%s" (or (plist-get agent-session-quick-settings :model)
                                    agent-session-quick-agent)
                 text)))))

(provide 'agent-session-quick)
;;; agent-session-quick.el ends here
