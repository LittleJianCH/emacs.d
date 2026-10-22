;;; agent-session-profile-test.el --- Profile conversation UI tests -*- lexical-binding: t; -*-

;;; Code:
(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'agent-session-profile)

(defmacro agent-session-profile-test--with-session (&rest body)
  "Run BODY in an isolated fake daemon view."
  (declare (indent 0) (debug t))
  `(let* ((buffer (generate-new-buffer " *profile-test*"))
          (agent-session--clock nil)
          (agent-session-status-functions nil)
          (agent-session--list-refresh-function nil)
          (connection (agent-emx--make-connection))
          (session (agent-session--make
                    :agent 'claude :backend 'emx :root temporary-file-directory
                    :buffer buffer :status 'idle
                    :info (copy-sequence '(:profile "coder" :sessionId "old-native"))
                    :client (list :emx-id "old" :emx-epoch "epoch"
                                  :resume "old-native" :emx-connection connection))))
     (unwind-protect
         (progn
           (puthash "old" session (agent-emx--connection-sessions connection))
           (agent-session--setup-buffer session)
           (with-current-buffer buffer ,@body))
       (when (timerp agent-session--clock) (cancel-timer agent-session--clock))
       (kill-buffer buffer))))

(defconst agent-session-profile-test--models
  '((:agent "claude" :model "opus-test" :effort "high" :selectable t)
    (:agent "codex" :model "sol-test" :effort "xhigh" :selectable t)
    (:agent "codex" :model "blocked" :selectable :false)))

(ert-deftest agent-session-profile-test-create-entry ()
  "The normal entry always chooses a profile, independent of the last agent."
  (let ((agent-session-default-agent 'codex) called)
    (cl-letf (((symbol-function 'agent-session-profile-create)
               (lambda (&optional root) (setq called (list 'profile root)))))
      (agent-session-create)
      (should (equal called '(profile nil)))
      (setq called nil)
      (agent-session-create t)
      (should (equal called '(profile nil))))))

(ert-deftest agent-session-profile-test-project-default-and-completion ()
  "Effective daemon profiles populate the chooser with orchestrator default."
  (let (request opened)
    (cl-letf (((symbol-function 'agent-emx--local-connection)
               (lambda (success _) (funcall success 'connection)))
              ((symbol-function 'agent-emx--request)
               (lambda (_ method params success &optional _failure)
                 (setq request (list method params))
                 (funcall success
                          '(:profiles [(:name "orchestrator" :description "协调")
                                       (:name "custom" :description "自定义")]))))
              ((symbol-function 'agent-session-profile--defer) #'funcall)
              ((symbol-function 'agent-session--completing-read)
               (lambda (_ choices default)
                 (should (equal default "orchestrator"))
                 (should (equal (mapcar #'car choices) '("orchestrator" "custom")))
                 default))
              ((symbol-function 'agent-session-profile--open)
               (lambda (root profile) (setq opened (list root profile)))))
      (agent-session-profile-create temporary-file-directory)
      (should (equal (car request) "collab/profiles"))
      (should (equal (plist-get (cadr request) :root) temporary-file-directory))
      (should (equal opened (list temporary-file-directory "orchestrator"))))))

(ert-deftest agent-session-profile-test-new-same-root ()
  (agent-session-profile-test--with-session
   (let (root)
     (cl-letf (((symbol-function 'agent-session-profile-create)
                (lambda (value) (setq root value))))
       (agent-session-new)
       (should (equal root (agent-session-root session)))))))

(ert-deftest agent-session-profile-test-open-wire-and-native-resume ()
  "New profile views omit provider hints; native resumes retain their provider."
  (agent-session-profile-test--with-session
   (let (wire)
     (agent-emx--set session :emx-id nil)
     (agent-emx--set session :resume nil)
     (cl-letf (((symbol-function 'agent-emx--request)
                (lambda (_ method params &rest _callbacks)
                  (should (equal method "session/open"))
                  (setq wire params)))
               ((symbol-function 'agent-emx--skills-context) (lambda (_) "")))
       (agent-emx--attach session connection)
       (should (equal (plist-get wire :profile) "coder"))
       (should-not (plist-member wire :agent))
        (should-not (plist-member wire :settings))
       (agent-emx--set session :resume "native")
       (agent-emx--attach session connection)
       (should (equal (plist-get wire :agent) "claude"))
       (should (equal (plist-get wire :resume) "native"))
       (should-not (plist-member wire :profile))))))

(ert-deftest agent-session-profile-test-no-inherited-provider-settings ()
  "A profile's first candidate is selected entirely by the daemon."
  (let ((agent-session-last-settings '((claude :model "old" :effort "low")))
        (agent-session-opening-view t)
        (agent-session--clock nil)
        buffer)
    (cl-letf (((symbol-function 'agent-session-backend-start) #'ignore)
              ((symbol-function 'agent-session-backend-stop) #'ignore))
      (unwind-protect
          (progn
            (setq buffer (agent-session-open 'claude temporary-file-directory
                                             nil nil '(:profile "orchestrator")))
            (should-not (agent-session-settings
                         (buffer-local-value 'agent-session--current buffer))))
        (when buffer (kill-buffer buffer))))))

(ert-deftest agent-session-profile-test-slash-candidate-completion ()
  "Slash completion offers selectable cross-provider profile rows with notes."
  (agent-session-profile-test--with-session
   (agent-emx--set session :profile-models agent-session-profile-test--models)
   (agent-emx--set session :emx-capabilities
                   '(:models [(:id "unlisted-provider-model")]))
   (goto-char (point-max))
   (insert "/model ")
   (pcase-let ((`(,_ ,_ ,table . ,_) (agent-session-completion-at-point)))
     (should (equal (all-completions "" table)
                    '("claude/opus-test@high" "codex/sol-test@xhigh")))
     (let* ((metadata (completion-metadata "" table nil))
            (annotate (completion-metadata-get metadata 'annotation-function)))
       (should (string-match-p "codex.*sol-test.*xhigh"
                               (funcall annotate "codex/sol-test@xhigh")))))))

(ert-deftest agent-session-profile-test-slash-rejects-unlisted ()
  "Typed slash arguments cannot escape the current candidate list."
  (agent-session-profile-test--with-session
   (cl-letf (((symbol-function 'agent-session-profile--defer) #'funcall)
             ((symbol-function 'agent-emx--rpc)
              (lambda (_ method _params callback &optional _failure)
                (should (equal method "session/models"))
                (funcall callback (list :models
                                        (vconcat agent-session-profile-test--models))))))
     (should-error (agent-session-select-model "anything") :type 'user-error)
     (should-error (agent-session-select-model "codex/blocked") :type 'user-error))))

(ert-deftest agent-session-profile-test-cross-provider-same-view ()
  "Selection updates registration and metadata without erasing text or draft."
  (agent-session-profile-test--with-session
   (let (selection)
     (agent-session-text session "answer" "已有上下文")
     (goto-char (point-max))
     (insert "草稿")
     (cl-letf (((symbol-function 'agent-session-profile--defer) #'funcall)
               ((symbol-function 'agent-emx--rpc)
                (lambda (_ method params callback &optional _failure)
                  (pcase method
                    ("session/models"
                     (funcall callback
                              (list :models (vconcat agent-session-profile-test--models))))
                    ("session/select"
                     (setq selection params)
                     (funcall callback
                              '(:id "new" :agent "codex" :profile "coder"
                                    :settings (:model "sol-test" :effort "xhigh"))))))))
       (agent-session-select-model "codex/sol-test@xhigh")
       (should (equal (plist-get selection :agent) "codex"))
       (should (equal (plist-get selection :effort) "xhigh"))
       (should-not (plist-get selection :unrestricted))
       (should (eq (agent-session-agent session) 'codex))
       (should (equal (agent-session-setting session :model) "sol-test"))
       (should (eq (gethash "new" (agent-emx--connection-sessions connection)) session))
       (should-not (gethash "old" (agent-emx--connection-sessions connection)))
       (should-not (agent-session-resume-id session))
       (should (string-match-p "已有上下文" (buffer-string)))
       (should (equal (agent-session--input-text session) "草稿"))))))

(ert-deftest agent-session-profile-test-any-model-orchestrator ()
  "The explicit arbitrary model command restores orchestrator capabilities."
  (agent-session-profile-test--with-session
   (let ((answers '("codex" "free-model")) selection)
     (cl-letf (((symbol-function 'agent-session-profile--defer) #'funcall)
               ((symbol-function 'completing-read)
                (lambda (_prompt _collection _predicate require-match &rest _)
                   (should require-match)
                   (pop answers)))
               ((symbol-function 'read-string) (lambda (&rest _) "xhigh"))
               ((symbol-function 'agent-emx--rpc)
                (lambda (_ method params callback &optional _failure)
                  (pcase method
                    ("session/models"
                     (funcall callback
                              (list :models
                                     (vconcat
                                      (if (equal (plist-get params :scope) "all")
                                          (cons '(:agent "codex" :model "free-model"
                                                  :selectable t)
                                                agent-session-profile-test--models)
                                        agent-session-profile-test--models)))))
                    ("session/select"
                     (setq selection params)
                     (funcall callback
                              '(:id "old" :agent "codex" :profile "orchestrator"
                                    :settings (:model "free-model" :effort "xhigh"))))))))
       (agent-session-select-any-model)
       (should (eq (plist-get selection :unrestricted) t))
       (should-not (plist-member selection :profile))
       (should (equal (plist-get selection :model) "free-model"))
       (should (equal (plist-get (agent-session-info session) :profile)
                      "orchestrator"))))))

(ert-deftest agent-session-profile-test-recovery-metadata ()
  "Daemon summaries refresh existing views and provider identity in place."
  (agent-session-profile-test--with-session
   (let ((agent-session-agents
          '((claude :backend emx) (codex :backend emx))))
     (cl-letf (((symbol-function 'agent-session-buffers) (lambda (&rest _) (list buffer))))
       (should (eq (agent-emx--adopt
                    connection
                    (list :id "old" :agent "codex" :root temporary-file-directory
                          :status "idle" :info '(:profile "reviewer" :sessionId "new-native")))
                   session))
       (should (eq (agent-session-agent session) 'codex))
       (should (equal (plist-get (agent-session-info session) :profile) "reviewer"))
       (should (equal (agent-session-resume-id session) "new-native"))
       (should (string-match-p "reviewer"
                               (substring-no-properties (agent-session--mode-line session))))))))

(ert-deftest agent-session-profile-test-root-summary-provider-change ()
  "Live root summary notifications update the mapped view too."
  (agent-session-profile-test--with-session
   (agent-emx--dispatch
    connection
    (list :method "sessions"
          :params (list :sessions
                        (vector (list :id "old" :agent "codex"
                                      :root temporary-file-directory :status "idle"
                                      :info '(:profile "orchestrator"))))))
   (should (eq (agent-session-agent session) 'codex))
   (should (equal (plist-get (agent-session-info session) :profile) "orchestrator"))))

(ert-deftest agent-session-profile-test-selection-rejection-keeps-status ()
  "A rejected model choice must not disconnect a running conversation."
  (agent-session-profile-test--with-session
    (setf (agent-session-status session) 'running)
    (cl-letf (((symbol-function 'agent-emx--ready)
               (lambda (_ callback) (funcall callback)))
              ((symbol-function 'agent-emx--request)
               (lambda (_ _method _params _callback failure)
                 (funcall failure '(:message "Finish pending work")))))
      (agent-session-profile--select session (car agent-session-profile-test--models))
      (should (eq (agent-session-status session) 'running)))))

(ert-deftest agent-session-profile-test-null-native-id-clears-resume ()
  "A provider switch's explicit null invalidates the old native resume id."
  (agent-session-profile-test--with-session
    (agent-emx--info session '(:profile "orchestrator" :sessionId nil))
    (should-not (agent-session-resume-id session))))

(ert-deftest agent-session-profile-test-model-selection-applies-profile-mode ()
  "Model selection applies the profile candidate's mode and reasoning effort."
  (agent-session-profile-test--with-session
   (let ((models '((:agent "codex" :model "sol-test" :effort "xhigh"
                           :mode "auto" :selectable t)))
         selection)
     (setf (agent-session-settings session) '(:mode plan))
     (cl-letf (((symbol-function 'agent-session-profile--defer) #'funcall)
               ((symbol-function 'agent-emx--rpc)
                (lambda (_ method params callback &optional _failure)
                  (pcase method
                    ("session/models"
                     (funcall callback (list :profile "coder" :models (vconcat models))))
                    ("session/select"
                     (setq selection params)
                     (funcall callback
                              '(:id "old" :agent "codex" :profile "coder"
                                :settings (:model "sol-test" :effort "xhigh"
                                           :mode "auto"))))))))
       (agent-session-select-model "codex/sol-test@xhigh:auto")
       (should (equal (plist-get selection :mode) "auto"))
       (should (equal (plist-get selection :effort) "xhigh"))
       (should (eq (agent-session-setting session :mode) 'auto))))))

(provide 'agent-session-profile-test)
;;; agent-session-profile-test.el ends here
