;;; agent-session-profile.el --- Profile-based conversation choices -*- lexical-binding: t; -*-

;;; Commentary:
;; The daemon owns effective profiles, candidate availability and selection.
;; Keep completion snapshots in the client plist without changing live structs.

;;; Code:

(require 'agent-emx)

(defun agent-session-profile--error (error)
  "Display a profile operation ERROR."
  (message "会话配置操作失败：%s" (or (plist-get error :message) error)))

(defun agent-session-profile--defer (function)
  "Run interactive FUNCTION outside the daemon process filter."
  (run-at-time 0 nil function))

(defun agent-session-profile--open (root profile)
  "Open a new conversation in ROOT with PROFILE's daemon-selected candidate."
  (let* ((agent (car (seq-find
                      (lambda (entry) (eq (plist-get (cdr entry) :backend) 'emx))
                      (reverse agent-session-agents))))
         (buffer (and agent (agent-session-open agent root nil nil
                                                (list :profile profile)))))
    (unless buffer (user-error "没有已启用的 daemon 代理"))
    (select-window (agent-session-display buffer))
    (agent-session-focus-input (buffer-local-value 'agent-session--current buffer))
    buffer))

(defun agent-session-profile-create (&optional root)
  "Choose an effective daemon profile and create a conversation in ROOT."
  (interactive)
  (setq root (or root (agent-session--root)))
  (let ((receive
         (lambda (connection)
           (agent-emx--request
            connection "collab/profiles"
            (list :root (agent-session-process-directory root))
            (lambda (result)
              (agent-session-profile--defer
               (lambda ()
                 (let* ((profiles (append (plist-get result :profiles) nil))
                        (choices
                         (mapcar
                          (lambda (profile)
                            (cons (plist-get profile :name)
                                  (concat (plist-get profile :description)
                                          (when (eq (plist-get profile :disabled) t)
                                            " · 已停用"))))
                          profiles))
                        (profile (agent-session--completing-read
                                  "新会话配置（默认 orchestrator）："
                                  choices "orchestrator")))
                   (unless (assoc profile choices)
                     (user-error "没有配置 %s" profile))
                   (agent-session-profile--open root profile)))))
            #'agent-session-profile--error))))
    (if (file-remote-p root)
        (agent-emx-remote-connection root receive #'agent-session-profile--error)
      (agent-emx--local-connection receive #'agent-session-profile--error)))
  nil)

(defun agent-session-profile--key (candidate)
  "Return an unambiguous slash-completion key for CANDIDATE."
  (concat (plist-get candidate :agent) "/"
          (or (plist-get candidate :model) "默认")
          (when-let* ((effort (plist-get candidate :effort)))
            (concat "@" effort))
          (when-let* ((mode (plist-get candidate :mode)))
            (concat ":" mode))))

(defun agent-session-profile--note (candidate)
  "Describe CANDIDATE's provider, model and effort."
  (format "代理 %s · 模型 %s · 推理 %s%s"
          (plist-get candidate :agent)
          (or (plist-get candidate :model) "默认")
          (or (plist-get candidate :effort) "默认")
          (if (eq (plist-get candidate :selectable) t) "" " · 当前不可选")))

(defun agent-session-profile--choices (session)
  "Return selectable profile completion rows for SESSION."
  (mapcar (lambda (candidate)
            (cons (agent-session-profile--key candidate)
                  (agent-session-profile--note candidate)))
          (seq-filter (lambda (candidate)
                        (eq (plist-get candidate :selectable) t))
                      (agent-emx--get session :profile-models))))

(defun agent-session-profile-model-completion (session)
  "Return an annotated completion table restricted to SESSION's profile."
  (let ((choices (agent-session-profile--choices session)))
    (lambda (string predicate action)
      (if (eq action 'metadata)
          (list 'metadata
                (cons 'annotation-function
                      (lambda (key)
                        (concat "  " (or (cdr (assoc key choices)) "")))))
        (complete-with-action action (mapcar #'car choices) string predicate)))))

(defun agent-session-profile-refresh-models (session &optional callback scope)
  "Fetch SESSION's models in SCOPE, then call CALLBACK with the result.
Only profile results update the slash-completion snapshot."
  (agent-emx--rpc
   session "session/models" (list :scope (or scope "profile"))
   (lambda (result)
     (when (buffer-live-p (agent-session-buffer session))
       (unless (equal scope "all")
         (when (plist-member result :profile)
           (agent-emx--info session (list :profile (plist-get result :profile))))
         (agent-emx--set session :profile-models
                         (append (plist-get result :models) nil)))
       (when callback (funcall callback result))))
   #'agent-session-profile--error))

(defun agent-session-profile--selected (session result)
  "Apply daemon selection RESULT to SESSION without replacing its transcript."
  (let* ((old (agent-emx--get session :emx-id))
         (id (or (plist-get result :id) old))
         (connection (agent-emx--get session :emx-connection)))
    (when connection
      (unless (equal old id)
        (remhash old (agent-emx--connection-sessions connection)))
      (puthash id session (agent-emx--connection-sessions connection)))
    (agent-emx--set session :emx-id id)
    (agent-emx--identity session (plist-get result :agent))
    (when (plist-member result :profile)
      (agent-emx--info session (list :profile (plist-get result :profile))))
    (when-let* ((info (plist-get result :info)))
      (agent-emx--info session info))
    (when-let* ((settings (plist-get result :settings)))
      (agent-emx--settings session settings))
    (agent-session-profile-refresh-models session)))

(defun agent-session-profile--select (session candidate &optional unrestricted)
  "Select CANDIDATE for SESSION, optionally UNRESTRICTED by its old profile."
  (agent-emx--rpc
   session "session/select"
   (append (list :agent (plist-get candidate :agent)
                 :model (plist-get candidate :model))
           (cl-loop for key in '(:effort :mode)
                    when (plist-member candidate key)
                    append (list key (plist-get candidate key)))
           ;; Omitting profile requests the daemon's orchestrator fallback.
           (when unrestricted (list :unrestricted t)))
   (lambda (result) (agent-session-profile--selected session result))
   #'agent-session-profile--error))

(defun agent-session-profile-select-model (&optional model)
  "Select MODEL from the current profile, including other providers."
  (interactive)
  (let ((session (agent-session--this)))
    (agent-session-profile-refresh-models
     session
     (lambda (_)
       (agent-session-profile--defer
        (lambda ()
          (when (buffer-live-p (agent-session-buffer session))
            (let* ((choices (agent-session-profile--choices session))
                   (key (or model
                            (agent-session--completing-read
                             (format "配置 %s 的模型："
                                     (or (plist-get (agent-session-info session)
                                                    :profile) "orchestrator"))
                             choices)))
                   (candidate
                    (seq-find (lambda (row)
                                (and (eq (plist-get row :selectable) t)
                                     (equal key (agent-session-profile--key row))))
                              (agent-emx--get session :profile-models))))
              (unless candidate (user-error "模型不在当前配置的可选候选中：%s" key))
              (agent-session-profile--select session candidate)))))))))

;;;###autoload
(defun agent-session-select-any-model ()
  "Choose any provider model and use orchestrator MCP capabilities.
The daemon retains the conversation and provides context across providers."
  (interactive)
  (let ((session (agent-session--this)))
    (unless (eq (agent-session-backend session) 'emx)
      (user-error "当前会话不由 emx daemon 管理"))
    (agent-session-profile-refresh-models
     session
     (lambda (result)
       (agent-session-profile--defer
        (lambda ()
          (when (buffer-live-p (agent-session-buffer session))
            (let* ((models (append (plist-get result :models) nil))
                   (agents (delete-dups
                            (mapcar (lambda (row) (plist-get row :agent)) models)))
                   (agent (completing-read
                           "任意模型 · 切回 orchestrator 能力；代理："
                           agents nil t))
                   (rows (seq-filter
                          (lambda (row) (equal agent (plist-get row :agent)))
                          models))
                   (model (completing-read
                           "全部模型目录（留空用默认；保留会话）："
                           (delq nil (mapcar (lambda (row) (plist-get row :model)) rows))
                           nil t))
                   (effort (read-string "推理强度（留空用默认）：")))
              (agent-session-profile--select
               session (list :agent agent
                             :model (unless (string-empty-p model) model)
                             :effort (unless (string-empty-p effort) effort))
               t))))))
     "all")))

(provide 'agent-session-profile)
;;; agent-session-profile.el ends here
