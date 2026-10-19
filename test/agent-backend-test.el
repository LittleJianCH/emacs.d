;;; agent-backend-test.el --- Backend module loading tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Check startup in fresh Emacs processes, without starting any agent CLI.

;;; Code:

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

(defmacro agent-backend-test--with-usage-files (&rest body)
  "Run BODY with fresh usage files and clean module state."
  (declare (indent 0) (debug t))
  `(let* ((agent-usage-file (make-temp-file "agent-backend-usage-" nil ".eld"))
          (agent-usage-quota-file
           (make-temp-file "agent-backend-quota-" nil ".eld"))
          (agent-usage--records nil)
          (agent-usage--loaded nil)
          (agent-usage--quotas 'unloaded)
          (agent-usage-change-functions nil))
     (unwind-protect
         (progn ,@body)
       (ignore-errors (delete-file agent-usage-file))
       (ignore-errors (delete-file agent-usage-quota-file)))))

(defun agent-backend-test--dsh-session ()
  "Make a local dsh test session."
  (agent-session--make
   :agent 'dsh
   :backend 'dsh
   :root "/tmp/proj/"
   :info (list :handle "h1" :model "deepseek-official/deepseek-chat")))

(ert-deftest agent-backend-test-enabled-modules ()
  "Only enabled backends are loaded and registered at startup."
  (dolist (enabled '(nil (codex) (claude codex dsh)))
    (with-temp-buffer
      (let* ((default-directory agent-backend-test--root)
             (setup (prin1-to-string
                     `(setq my/use-evil nil my/languages nil
                            my/agents ',enabled)))
             (check
              (prin1-to-string
               `(progn
                  (require 'cl-lib)
                  (cl-assert
                   (equal (sort (mapcar #'car agent-session-agents) #'string<)
                          (sort (copy-sequence my/agents) #'string<)))
                  (dolist (agent '(claude codex dsh))
                    (let ((enabled (memq agent my/agents)))
                      (cl-assert
                       (eq (not (null enabled))
                           (featurep (intern (format "agent-%s" agent)))))
                      (when enabled
                        (cl-assert
                         (commandp
                          (intern (format "agent-session-%s" agent)))))))
                  (when (memq 'dsh my/agents)
                    (dolist (file (agent-dsh--plugin-files))
                      (cl-assert (file-exists-p file))
                      (cl-assert
                       (string-prefix-p
                        (file-truename
                         (expand-file-name "lisp/agent/backend/dsh/"
                                           user-emacs-directory))
                        (file-truename file))))))))
             (status
              (call-process
               (expand-file-name invocation-name invocation-directory)
               nil t nil "--batch" "-Q"
               (concat "--init-directory=" agent-backend-test--root)
               "--eval" setup "-l" "init.el" "--eval" check)))
        (ert-info ((format "Enabled backends: %S\n%s" enabled (buffer-string)))
          (should (eql status 0)))))))

(ert-deftest agent-backend-test-dsh-usage ()
  "dsh counts a turn's model calls and records the balance at its end."
  (agent-backend-test--with-usage-files
    (let ((session (agent-backend-test--dsh-session))
          (requests nil))
      (cl-letf (((symbol-function 'agent-dsh--request)
                 (lambda (_session method params &optional callback _error-callback)
                   (push (cons method params) requests)
                   (when (and callback (equal method "balance"))
                     (funcall callback
                              (list :available t
                                    :balances
                                    (vector (list :currency "CNY"
                                                  :total "12.30"
                                                  :granted "0.00"
                                                  :toppedUp "12.30"))))))))
        ;; One call inside the turn, one replayed while idle.
        (agent-dsh--notification session "status" (list :status "running"))
        (agent-dsh--notification session "usage"
                                  (list :model "deepseek-official/deepseek-flash"
                                        :usage (list :inputTokens 100
                                                     :cacheReadTokens 30
                                                     :cacheWriteTokens 10
                                                     :outputTokens 20
                                                     :totalTokens 160)))
        (should (equal (plist-get (agent-session-info session) :tokens) 160))
        (agent-dsh--notification session "status" (list :status "idle"))
        (agent-dsh--notification session "usage"
                                  (list :model "deepseek-official/deepseek-chat"
                                        :usage (list :inputTokens 500
                                                     :outputTokens 50
                                                     :totalTokens 550)))
        ;; :tokens still follows the agent, but no record takes the call.
        (should (equal (plist-get (agent-session-info session) :tokens) 550))
        (should (= (length (plist-get (agent-session-state session) :usage-pending))
                   1))
        (agent-dsh--notification session "turn/end" (list :reason "completed"))
        (should-not (plist-get (agent-session-state session) :usage-pending))
        (should (equal (mapcar #'car (reverse requests)) '("balance")))
        (setq agent-usage--loaded nil)
        (let ((records (agent-usage-records)))
          (should (= (length records) 1))
          (let ((record (car records)))
            (should (equal (plist-get record :model)
                           "deepseek-official/deepseek-flash"))
            (should (equal (list (plist-get record :input)
                                 (plist-get record :cache-read)
                                 (plist-get record :cache-write)
                                 (plist-get record :output))
                           '(100 30 10 20)))
            (should (equal (plist-get record :turns) 1))
            (should (eq (plist-get record :agent) 'dsh))
            (should (equal (plist-get record :session) "h1"))))
        ;; The balance reply became the session's quota.
        (should (equal (plist-get (cdr (assoc '(dsh) (agent-usage-quotas)))
                                  :balance)
                       '((:amount 12.3 :currency "CNY"))))))))

(ert-deftest agent-backend-test-dsh-usage-model-fallback ()
  "A usage chunk without a model falls back to the session's model.
A cancelled turn still records what it used."
  (agent-backend-test--with-usage-files
    (let ((session (agent-backend-test--dsh-session)))
      (cl-letf (((symbol-function 'agent-dsh--request) #'ignore))
        (agent-dsh--notification session "status" (list :status "running"))
        (agent-dsh--notification session "usage"
                                  (list :usage (list :inputTokens 5
                                                     :outputTokens 2
                                                     :totalTokens 7)))
        (agent-dsh--notification session "turn/end" (list :reason "cancelled")))
      (setq agent-usage--loaded nil)
      (let ((records (agent-usage-records)))
        (should (= (length records) 1))
        (should (equal (plist-get (car records) :model)
                       "deepseek-official/deepseek-chat"))))))

(provide 'agent-backend-test)
;;; agent-backend-test.el ends here
