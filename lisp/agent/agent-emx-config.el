;;; agent-emx-config.el --- Cached daemon policy -*- lexical-binding: t; -*-

;;; Commentary:
;; The daemon pushes effective policy on hello and config notifications.
;; Accessors only read memory; an unavailable daemon uses Lisp defaults.

;;; Code:
(require 'cl-lib)
(require 'seq)
(defvar agent-ui-description-functions)
(defvar agent-session-agents)
(defvar agent-emx-config--value nil
  "Last effective local daemon configuration, or nil before connection.")

(defun agent-emx-config-receive (config)
  "Cache effective CONFIG without making an editor round trip."
  (setq agent-emx-config--value config)
  ;; The remaining Lisp backends keep their defcustoms as offline defaults.
  ;; Apply daemon-owned launch policy before their next process is started.
  (dolist (agent '(claude codex dsh))
    (when-let* ((settings (plist-get (plist-get config :agents)
                                    (intern (concat ":" (symbol-name agent))))))
      (dolist (field '((:executable . "executable") (:extraArgs . "extra-args")
                       (:nativeSubagents . "native-subagents")
                       (:disallowedTools . "disallowed-tools")
                       (:historyTurns . "history-turns")))
        (when (plist-member settings (car field))
          (let* ((symbol (intern (format "agent-%s-%s" agent (cdr field))))
                 (value (plist-get settings (car field))))
            (set symbol (cond ((eq value :false) nil)
                              ((vectorp value) (append value nil))
                              (t value))))))
      ;; :executable is a variable reference, whose value was set above.
      (when-let* ((entry (assq agent agent-session-agents))
                  ((plist-member settings :title)))
        (setcdr entry (plist-put (cdr entry) :title (plist-get settings :title)))))))

(defun agent-emx-config-collab (key fallback)
  "Return cached collaboration KEY, or FALLBACK without a configuration."
  (if agent-emx-config--value
      (let ((value (plist-get (plist-get agent-emx-config--value :collab) key)))
        (if (eq value :false) nil value))
    fallback))

(defun agent-emx-config-agent (agent key)
  "Read configured AGENT's KEY without contacting the daemon."
  (plist-get (plist-get (plist-get agent-emx-config--value :agents)
                        (intern (concat ":" (symbol-name agent)))) key))

(defun agent-emx-config-profiles (fallback)
  "Return cached profiles as Lisp entries, or FALLBACK."
  (if (not agent-emx-config--value) fallback
    (cl-loop for (name profile) on (plist-get agent-emx-config--value :profiles)
             by #'cddr
             collect
             (cons (intern (substring (symbol-name name) 1))
                   (cl-loop for (key value) on profile by #'cddr
                            append (list key (cond
                                              ((eq value :false) nil)
                                              ((memq key '(:agent :mode :cost))
                                               (and value (intern value)))
                                              (t value))))))))

(defun agent-emx-config-tool (name place)
  "Return the configured collaboration definition for NAME at PLACE."
  (when agent-emx-config--value
    (when-let* ((tool (seq-find (lambda (tool)
                                 (equal name (plist-get tool :name)))
                               (plist-get (plist-get agent-emx-config--value :collab)
                                          :tools))))
      (let ((tool (copy-sequence tool)))
        (when-let* ((fn (alist-get name agent-ui-description-functions
                                   nil nil #'equal)))
          (setq tool (plist-put tool :description
                                (concat (plist-get tool :description)
                                        "\n\n" (funcall fn place)))))
        tool))))

(provide 'agent-emx-config)
;;; agent-emx-config.el ends here
