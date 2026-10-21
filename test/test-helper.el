;;; test-helper.el --- Isolated batch test state -*- lexical-binding: t; -*-

;;; Commentary:
;; Keep the invoking HOME, but never inherit daemon state or model commands.

;;; Code:
(require 'ert)
(require 'cl-lib)

;; Batch UI tests drive their own timers.  Unrelated file and non-file buffers
;; must not restart the global polling timer on every major-mode change while
;; a test intercepts `run-with-timer'.
(when (bound-and-true-p global-auto-revert-mode)
  (global-auto-revert-mode -1))

(defconst emx-test--checkout
  (file-name-directory
   (directory-file-name
    (expand-file-name (file-name-directory (or load-file-name buffer-file-name))))))
(defconst emx-test--default-state (expand-file-name "var/emx/" emx-test--checkout))
(defconst emx-test--var (make-temp-file "emx-ert-state-" t))

(defun emx-test--assert-default-state-empty ()
  "Fail if any test used the checkout's default daemon state directory."
  (when (file-directory-p emx-test--default-state)
    (should-not (directory-files emx-test--default-state nil
                                 directory-files-no-dot-files-regexp))))

;; Load this helper from every suite, including when running one file alone.
;; The init files do not start services in batch mode.
(setq agent-emx-var-directory emx-test--var
      agent-usage-file (expand-file-name "agent-usage.jsonl" emx-test--var)
      agent-usage-quota-file (expand-file-name "agent-quota.json" emx-test--var))
(let ((bin (expand-file-name "test/emx/fixtures/bin/" emx-test--checkout)))
  (setenv "PATH" (concat bin path-separator (getenv "PATH")))
  (add-to-list 'exec-path bin))
(dolist (name '("CLAUDE" "CODEX" "DSH"))
  (setenv (concat "EMX_" name "_EXECUTABLE") nil)
  (setenv (concat "EMX_" name "_CONFIG") nil))
(dolist (name '("EMX_CLAUDE_LOG" "EMX_CODEX_LOG" "EMX_DSH_LOG"
                "EMX_CODEX_BAD_CONFIG" "EMX_CODEX_RESTART_GATE"))
  (setenv name nil))
(setenv "EMX_CLAUDE_PROJECTS_DIR" (expand-file-name "projects" emx-test--var))
(make-directory (expand-file-name "emx" emx-test--var))
(with-temp-file (expand-file-name "emx/config.json" emx-test--var)
  (insert "{\"collab\":{\"handleCommand\":[],\"agentHandleCommands\":{}},"
          "\"usage\":{\"pollInterval\":0}}"))

(defun emx-test--check-state (_name test)
  "Check the forbidden state directory after TEST, including failed tests."
  (let ((body (ert-test-body test)))
    (setf (ert-test-body test)
          (lambda ()
            (unwind-protect (funcall body)
              (emx-test--assert-default-state-empty))))))
(advice-add 'ert-set-test :before #'emx-test--check-state)
(emx-test--assert-default-state-empty)

(defun emx-test--cleanup ()
  "Stop the shared test daemon before removing its temporary state."
  (call-process "node" nil nil nil (expand-file-name "bin/emx" emx-test--checkout)
                "daemon" "--var" emx-test--var "--stop")
  (delete-directory emx-test--var t))
(add-hook 'kill-emacs-hook #'emx-test--cleanup)

(ert-deftest emx-test-helper-rejects-default-state ()
  "The per-test guard rejects a leaked outbox, log or session index."
  (let ((emx-test--default-state (make-temp-file "emx-guard-" t)))
    (unwind-protect
        (progn
          (emx-test--assert-default-state-empty)
          (with-temp-file (expand-file-name "sessions.json" emx-test--default-state)
            (insert "[]"))
          (should-error (emx-test--assert-default-state-empty) :type 'ert-test-failed))
      (delete-directory emx-test--default-state t))))

(provide 'test-helper)
;;; test-helper.el ends here
