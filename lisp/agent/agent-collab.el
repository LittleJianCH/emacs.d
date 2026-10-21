;;; agent-collab.el --- Collaboration views for daemon sessions -*- lexical-binding: t; -*-

;;; Commentary:
;; The daemon owns naming, profiles, session tools and mailboxes.
;; Emacs links child progress to its parent's tool block.  Approval mirroring
;; lives in agent-session; agent-emx adopts and attaches daemon child views.
;; Mentions add context to user input using the cached daemon wording.

;;; Code:
(require 'agent-session)
(require 'agent-emx-config)

(defun agent-collab--mention-note (session text)
  "Tell the agent of SESSION which @handles in TEXT are sessions."
  (let ((pos 0) mentioned)
    (while (string-match "\\(?:^\\|[ \t(]\\)@\\([a-z][a-z0-9-]*\\)" text pos)
      (setq pos (match-end 0))
      (let ((other (agent-session-find (match-string 1 text))))
        (when (and other (not (eq other session)) (not (memq other mentioned)))
          (push other mentioned))))
    (if (or (null mentioned)
            (null (plist-get (agent-emx-config-collab :prompts) :mention)))
        text
      (concat text "\n\n"
              (mapconcat (lambda (other)
                           (format (plist-get (agent-emx-config-collab :prompts) :mention)
                                   (agent-session-handle other) (agent-session-title other)
                                   (agent-session-display-title other)))
                         (nreverse mentioned) "\n")))))

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
    (agent-session--update caller (car entry) :subagent (agent-session-buffer child)
                           :subagent-handle (agent-session-handle child))))

(add-hook 'agent-session-send-filters #'agent-collab--mention-note)

(provide 'agent-collab)
;;; agent-collab.el ends here
