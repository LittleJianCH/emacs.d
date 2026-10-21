;;; agent-emx-smoke-test.el --- Full cut-over smoke with fake CLIs -*- lexical-binding: t; -*-

;;; Commentary:
;; No editor server, default daemon, real CLI or remote connection is used.

;;; Code:
(require 'ert)
(require 'agent-emx-test
         (expand-file-name "agent-emx-test.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'agent-claude)
(require 'agent-codex)
(require 'agent-dsh)

(ert-deftest agent-emx-smoke-all-registrations-send-approve-child-and-history ()
  (let* ((agent-emx-var-directory (agent-emx-test--var-directory "emx-cutover-"))
         (home (make-temp-file "emx-cutover-home-" t))
         (root (file-name-as-directory (file-truename agent-emx-var-directory)))
         (projects (expand-file-name "projects" home))
         (agent-emx--connections (make-hash-table :test #'equal))
         (agent-usage--connection nil)
         (agent-session-skills nil)
         (agent-session-last-settings nil)
         (agent-session-submit-functions nil)
         (agent-session-status-functions nil)
         (agent-session--list-refresh-function nil)
         (agent-session--clock nil)
         (process-environment
          (append (list (concat "HOME=" home)
                        (concat "EMX_CLAUDE_PROJECTS_DIR=" projects)
                        (concat "EMX_CLAUDE_LOG=" (expand-file-name "claude.jsonl" home)))
                  process-environment))
         parents)
    (unwind-protect
        (progn
          ;; Executables come solely from config: no EMX_*_EXECUTABLE overrides.
          (dolist (name '("CLAUDE" "CODEX" "DSH"))
            (setenv (concat "EMX_" name "_EXECUTABLE") nil)
            (setenv (concat "EMX_" name "_CONFIG") nil))
          (with-temp-file (expand-file-name "emx/config.json" root)
            (let ((agents (make-hash-table :test #'equal)))
              (dolist (name '("claude" "codex" "dsh"))
                (puthash name (list :executable
                                    (expand-file-name (concat "test/emx/fixtures/" name ".mjs")
                                                      agent-emx--checkout)) agents))
              (insert (json-serialize
                       (list :agents agents :usage '(:pollInterval 0)
                             :collab (list :handleCommand [] :agentHandleCommands (make-hash-table)
                                           :closeFinished :false)
                             :profiles '(:smoke-worker (:agent "dsh" :model "fake/child" :mode "ask")))
                       :false-object :false))))
          (dolist (agent '(claude codex dsh))
            (should (eq (agent-session--get agent :backend) 'emx))
            (let* ((buffer (agent-session-open agent root nil '(:mode ask)))
                   (session (buffer-local-value 'agent-session--current buffer))
                   (connection (agent-emx--get session :emx-connection)))
              (push session parents)
              (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'idle)))
              (agent-session-send session (if (eq agent 'codex) "command-approval" "approval"))
              (agent-emx-test--wait (lambda () (agent-session--pending-asks session)))
              (agent-session--answer session (car (agent-session--pending-asks session)) 'allow)
              (agent-emx-test--wait (lambda () (eq (agent-session-status session) 'idle)))
              (should (seq-some (lambda (entry) (eq (plist-get (cdr entry) :type) 'text))
                                (agent-session--blocks-in-order session)))
              (agent-session-tool session "smoke-start" :kind 'mcp :status 'running
                                  :title "emacs · session_start")
              (let ((result (agent-emx-test--mcp
                             connection session "tools/call"
                             (list :name "session_start" :arguments
                                   (list :profile "smoke-worker" :handle (concat "child-" (symbol-name agent))
                                         :prompt "Complete the fake smoke task")))))
                (should-not (eq (plist-get result :isError) t)))
              (agent-emx-test--wait (lambda () (agent-session-children session)))
              (let ((child (car (agent-session-children session))))
                (should (eq (agent-session-parent child) session))
                (should (eq (plist-get (agent-session--block session "smoke-start") :subagent)
                            (agent-session-buffer child))))
              (message "smoke：%s 已发送、批准并启动子会话" agent)))
          ;; Native history belongs to the same root and comes through the daemon.
          (let ((dir (expand-file-name
                      (replace-regexp-in-string "[^[:alnum:]]" "-" (directory-file-name root)) projects)))
            (make-directory dir t)
            (with-temp-file (expand-file-name "past-claude.jsonl" dir)
              (insert "{\"type\":\"user\",\"message\":{\"content\":\"Past Claude\"}}\n")))
          (dolist (agent '(claude codex dsh))
            (let ((items 'pending))
              (agent-emx-history agent root (lambda (value) (setq items value)))
              (agent-emx-test--wait (lambda () (not (eq items 'pending))))
              (should (seq-find (lambda (item)
                                 (equal (plist-get item :id) (concat "past-" (symbol-name agent)))) items))
              (message "smoke：%s 已列出历史会话" agent))))
      (dolist (session parents)
        (agent-session-kill-quietly (agent-session-buffer session)))
      (maphash (lambda (_ connection)
                 (when (process-live-p (agent-emx--connection-process connection))
                   (delete-process (agent-emx--connection-process connection))))
               agent-emx--connections)
      (when (timerp agent-session--clock) (cancel-timer agent-session--clock))
      (call-process "node" nil nil nil (expand-file-name "bin/emx" agent-emx--checkout)
                    "daemon" "--var" agent-emx-var-directory "--stop")
      (delete-directory agent-emx-var-directory t)
      (delete-directory home t))))

(provide 'agent-emx-smoke-test)
;;; agent-emx-smoke-test.el ends here
