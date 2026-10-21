;;; agent-emx-config.el --- Cached daemon display policy -*- lexical-binding: t; -*-

;;; Commentary:
;; The required daemon supplies policy asynchronously; accessors only read it.

;;; Code:
(defvar agent-session-agents)
(defvar agent-emx-config--value nil "Last effective local daemon config.")

(defun agent-emx-config-receive (config)
  "Cache effective CONFIG and update registered display titles."
  (setq agent-emx-config--value config)
  (dolist (entry agent-session-agents)
    (when-let* ((title (agent-emx-config-agent (car entry) :title)))
      (setcdr entry (plist-put (cdr entry) :title title)))))

(defun agent-emx-config-collab (key)
  "Return cached collaboration KEY, or nil before connection."
  (let ((value (plist-get (plist-get agent-emx-config--value :collab) key)))
    (unless (eq value :false) value)))

(defun agent-emx-config-agent (agent key)
  "Read configured AGENT's KEY without contacting the daemon."
  (plist-get (plist-get (plist-get agent-emx-config--value :agents)
                        (intern (concat ":" (symbol-name agent)))) key))

(provide 'agent-emx-config)
;;; agent-emx-config.el ends here
