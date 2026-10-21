;;; agent-backend-test.el --- Backend module loading tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Check startup in fresh Emacs processes, without starting any agent CLI.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'agent-session)
(require 'agent-usage)
(require 'agent-dsh)

(defconst agent-backend-test--root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Configuration root used by the startup checks.")

(ert-deftest agent-backend-test-enabled-modules ()
  "Only enabled backends are loaded and registered at startup."
  (dolist (enabled '(nil (codex) (claude codex dsh pi)))
    (with-temp-buffer
      (let* ((default-directory agent-backend-test--root)
             (setup (prin1-to-string
                     `(setq package-user-dir ,package-user-dir
                            my/use-evil nil my/languages nil
                            my/agents ',enabled)))
             (check
              (prin1-to-string
               `(progn
                  (require 'cl-lib)
                  (cl-assert
                   (equal (sort (mapcar #'car agent-session-agents) #'string<)
                          (sort (copy-sequence my/agents) #'string<)))
                  (dolist (agent '(claude codex dsh pi))
                    (let ((enabled (memq agent my/agents)))
                      (cl-assert
                       (eq (not (null enabled))
                           (featurep (intern (format "agent-%s" agent)))))
                      (when enabled
                        (cl-assert
                         (commandp
                          (intern (format "agent-session-%s" agent)))))))
                  (dolist (agent my/agents)
                    (cl-assert (eq (agent-session--get agent :backend) 'emx))
                    (cl-assert (equal (agent-session--get agent :emx-agent)
                                      (symbol-name agent)))))))
             (status
              (call-process
               (expand-file-name invocation-name invocation-directory)
               nil t nil "--batch" "-Q"
               (concat "--init-directory=" agent-backend-test--root)
               "--eval" setup "-l" "init.el" "--eval" check)))
        (ert-info ((format "Enabled backends: %S\n%s" enabled (buffer-string)))
          (should (eql status 0)))))))

(provide 'agent-backend-test)
;;; agent-backend-test.el ends here
