;;; agent-profiles.el --- Subagent profile controls -*- lexical-binding: t; -*-

;;; Commentary:
;; Display local daemon profiles and edit their user config overlay.

;;; Code:

(require 'agent-emx)
(require 'button)
(require 'project)
(require 'seq)

(defconst agent-profiles--buffer "*agent-profiles*")
(defvar-local agent-profiles--snapshot nil "Last profiles response.")
(defvar-local agent-profiles--generation 0 "Newest refresh request number.")
(defvar-local agent-profiles--writing nil "Non-nil while a config write is pending.")
(defvar-local agent-profiles--root nil "Project root used for availability checks.")

(defun agent-profiles--error (error)
  "Show a daemon ERROR with a localized prefix."
  (message "子代理配置操作失败：%s" (or (plist-get error :message) error)))

(defun agent-profiles--button (label action)
  "Insert a clickable LABEL that invokes ACTION."
  (insert-text-button label
                      'face 'agent-session-button
                      'mouse-face (list 'highlight)
                      'follow-link t
                      'help-echo "RET 或鼠标点击执行"
                      'action (lambda (_) (funcall action))))

(defun agent-profiles-refresh (&rest _)
  "Fetch the local daemon's effective subagent profiles asynchronously."
  (interactive)
  (let ((buffer (current-buffer))
        (root (or agent-profiles--root default-directory))
        (generation (cl-incf agent-profiles--generation)))
    (agent-emx--local-connection
     (lambda (connection)
       (when (buffer-live-p buffer)
         (agent-emx--request
          connection "collab/profiles" (list :root root)
          (lambda (result)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (= generation agent-profiles--generation)
                  (setq agent-profiles--snapshot result)
                  (agent-profiles--render)))))
          #'agent-profiles--error)))
     #'agent-profiles--error)))

(defun agent-profiles--write (method params)
  "Send a config mutation with METHOD and PARAMS, then refresh this page."
  (when agent-profiles--writing (user-error "正在保存配置，请稍候"))
  (setq agent-profiles--writing t)
  (cl-incf agent-profiles--generation)
  (let* ((buffer (current-buffer))
         (failure (lambda (error)
                    (when (buffer-live-p buffer)
                      (with-current-buffer buffer
                        (setq agent-profiles--writing nil)))
                    (agent-profiles--error error))))
    (agent-emx--local-connection
     (lambda (connection)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (agent-emx--request
            connection method params
            (lambda (result)
              (when-let* ((config (plist-get result :config)))
                (agent-emx-config-receive config))
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (setq agent-profiles--writing nil)
                  (agent-profiles-refresh))))
            failure))))
     failure)))

(defun agent-profiles--set (path value)
  "Write VALUE at config PATH, then refresh this page."
  (agent-profiles--write "config/set" (list :path (vconcat path) :value value)))

(defun agent-profiles--disable (profile disabled &optional candidate)
  "Set PROFILE's DISABLED state, optionally for CANDIDATE's index only."
  (agent-profiles--write
   "collab/disable"
   (append (list :profile profile :disabled (if disabled t :false))
           (when candidate (list :candidate candidate)))))

(defun agent-profiles--candidates (name)
  "Copy NAME's candidates, keeping only writable configuration fields."
  (let ((profile (seq-find (lambda (p) (equal (plist-get p :name) name))
                           (plist-get agent-profiles--snapshot :profiles))))
    (unless profile (user-error "配置已更新，请刷新页面"))
    (mapcar (lambda (candidate)
              (let ((result (list :agent (plist-get candidate :agent))))
                (dolist (key '(:model :effort :mode))
                  (when (stringp (plist-get candidate key))
                    (setq result (plist-put result key (plist-get candidate key)))))
                result))
            (append (plist-get profile :candidates) nil))))

(defun agent-profiles--save-candidates (name candidates)
  "Write the whole CANDIDATES array for profile NAME."
  (agent-profiles--set (list "profiles" name "candidates") (vconcat candidates)))

(defun agent-profiles--move-candidate (name index delta)
  "Move NAME's candidate at INDEX by DELTA places."
  (let* ((candidates (vconcat (agent-profiles--candidates name)))
         (target (+ index delta)))
    (unless (<= 0 target (1- (length candidates)))
      (user-error "候选已在边界"))
    (cl-rotatef (aref candidates index) (aref candidates target))
    (agent-profiles--save-candidates name candidates)))

(defun agent-profiles--delete-candidate (name index)
  "Delete NAME's candidate at INDEX, retaining at least one candidate."
  (let ((candidates (agent-profiles--candidates name)))
    (when (= (length candidates) 1) (user-error "至少保留一个候选"))
    (agent-profiles--save-candidates
     name (append (seq-take candidates index) (seq-drop candidates (1+ index))))))

(defun agent-profiles--model-fallback (agent)
  "Collect AGENT's models already present in the effective configuration."
  (let ((profiles (plist-get agent-emx-config--value :profiles)) models)
    (while profiles
      (let* ((profile (cadr profiles))
             (candidates (if (plist-get profile :agent) (list profile)
                           (append (plist-get profile :candidates) nil))))
        (dolist (candidate candidates)
          (when (and (equal (plist-get candidate :agent) agent)
                     (stringp (plist-get candidate :model)))
            (push (plist-get candidate :model) models))))
      (setq profiles (cddr profiles)))
    (delete-dups (nreverse models))))

(defun agent-profiles--edit-candidate (name &optional index)
  "Edit NAME's candidate at INDEX, or append a new one when INDEX is nil."
  (when agent-profiles--writing (user-error "正在保存配置，请稍候"))
  (let* ((buffer (current-buffer))
         (generation agent-profiles--generation)
         (candidates (agent-profiles--candidates name))
         (old (and index (nth index candidates)))
         (agents (let ((config (plist-get agent-emx-config--value :agents)) names)
                   (while config
                     (push (substring (symbol-name (car config)) 1) names)
                     (setq config (cddr config)))
                   (nreverse names)))
         (agent (completing-read "代理：" agents nil t nil nil
                                 (plist-get old :agent)))
         (finish
          (lambda (choices)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (if (/= generation agent-profiles--generation)
                    (message "配置已更新，请重新编辑")
                  (let* ((model (string-trim
                                 (completing-read
                                  "模型（留空使用默认，可自由输入）："
                                  (delete-dups
                                   (append choices (agent-profiles--model-fallback agent)))
                                  nil nil (and (equal agent (plist-get old :agent))
                                               (plist-get old :model)))))
                         (effort (string-trim
                                  (read-string "推理强度（可选，留空不指定）："
                                               (plist-get old :effort))))
                         (candidate (list :agent agent)))
                    (unless (string-empty-p model)
                      (setq candidate (plist-put candidate :model model)))
                    (unless (string-empty-p effort)
                      (setq candidate (plist-put candidate :effort effort)))
                    (when (plist-get old :mode)
                      (setq candidate (plist-put candidate :mode (plist-get old :mode))))
                    (if index (setf (nth index candidates) candidate)
                      (setq candidates (append candidates (list candidate))))
                    (agent-profiles--save-candidates name candidates))))))))
    (agent-emx--local-connection
     (lambda (connection)
       (agent-emx--request
        connection "agents/models" (list :agent agent)
        (lambda (result)
          (funcall finish (mapcar (lambda (m) (plist-get m :id))
                                 (append (plist-get result :models) nil))))
        (lambda (_) (funcall finish nil))))
     (lambda (_) (funcall finish nil)))))

(defun agent-profiles--edit-profile (name)
  "Choose and edit a candidate in profile NAME."
  (let* ((candidates (agent-profiles--candidates name))
         (choices (cl-loop for candidate in candidates for index from 0
                           collect (cons (format "%d · %s · %s" (1+ index)
                                                 (plist-get candidate :agent)
                                                 (or (plist-get candidate :model)
                                                     "默认模型")) index)))
         (choice (completing-read "编辑候选：" choices nil t)))
    (agent-profiles--edit-candidate name (cdr (assoc choice choices)))))

(defun agent-profiles--edit-threshold (&optional agent)
  "Edit AGENT's quota threshold, or the global threshold when nil."
  (let* ((input (string-trim
                 (read-string
                  (format "%s 已用配额百分比（0–100%s）："
                          (or agent "全局")
                          (if agent "，留空继承全局" "")))))
         (empty (string-empty-p input)))
    (unless (or (and agent empty)
                (and (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" input)
                     (<= 0 (string-to-number input) 100)))
      (user-error "请输入 0 到 100 的百分比"))
    (agent-profiles--set
     (if agent (list "agents" agent "quotaSkip") '("collab" "quotaSkip"))
     (unless empty (/ (string-to-number input) 100.0)))))

(defun agent-profiles--status (candidate profile-disabled)
  "Return CANDIDATE's status, respecting PROFILE-DISABLED."
  (cond ((or profile-disabled (eq (plist-get candidate :disabled) t))
         (let ((entries (append (plist-get candidate :disabledBy) nil)))
           (concat "已停用" (when entries
                              (format "（%s）" (string-join entries "、"))))))
        ((not (eq (plist-get candidate :available) t))
         (concat "不可用：" (or (plist-get candidate :unavailable) "原因未知")))
        ((plist-get candidate :strained)
         (concat "余量紧张：" (plist-get candidate :strained)))
        (t "可用")))

(defun agent-profiles--threshold-label (threshold)
  "Format the used quota fraction THRESHOLD for display."
  (if (>= threshold 1)
      "用到耗尽"
    (format "已用 %s%% 时跳过" (format "%.4g" (* 100 threshold)))))

(defun agent-profiles--render ()
  "Render the last daemon snapshot without changing this buffer's mode."
  (let ((inhibit-read-only t)
        (position (point))
        agents)
    (erase-buffer)
    (insert (propertize "子代理配置\n\n" 'face 'agent-session-assistant)
            (format "项目：%s\n" (or agent-profiles--root default-directory))
            "g 刷新 · TAB 选择按钮 · RET 执行 · q 返回\n\n")
    (if (null agent-profiles--snapshot)
        (insert "加载中…\n")
      (seq-doseq (profile (plist-get agent-profiles--snapshot :profiles))
        (let* ((name (plist-get profile :name))
               (off (eq (plist-get profile :disabled) t))
               (profile-off
                (seq-some (lambda (candidate)
                            (member name (append (plist-get candidate :disabledBy) nil)))
                          (plist-get profile :candidates))))
          (insert (propertize name 'face 'agent-session-assistant)
                  (format " · 成本：%s · %s  " (plist-get profile :cost)
                          (if off "已停用" "已启用")))
          ;; A profile is also off when every candidate is; only its own
          ;; token toggles it as a whole.
          (agent-profiles--button
           (if profile-off "启用" "停用")
           (lambda () (agent-profiles--disable name (not profile-off))))
          (insert "  ")
          (agent-profiles--button "编辑" (lambda () (agent-profiles--edit-profile name)))
          (when (eq (plist-get profile :overridden) t)
            (insert "  ")
            (agent-profiles--button
             "恢复默认" (lambda () (agent-profiles--set (list "profiles" name) nil))))
          (insert "\n  " (or (plist-get profile :description) "") "\n")
          (cl-loop for candidate across (plist-get profile :candidates)
                   for index from 0 do
            (let* ((agent (plist-get candidate :agent))
                   (model (and (stringp (plist-get candidate :model))
                               (plist-get candidate :model)))
                   (effort (plist-get candidate :effort))
                   (candidate-off (eq (plist-get candidate :disabled) t))
                   (i index))
              (unless (assoc agent agents)
                (push (cons agent (plist-get candidate :quotaSkip)) agents))
              (insert (format "  %s · %s%s  %s  " agent (or model "默认模型")
                              (if effort (format " (%s)" effort) "")
                              (agent-profiles--status candidate off)))
              (agent-profiles--button
               (if candidate-off "启用" "停用")
               (lambda () (agent-profiles--disable name (not candidate-off) i)))
              (let ((i index))
                (dolist (action
                         (append
                          (when (> i 0)
                            (list (cons "上移" (lambda ()
                                                 (agent-profiles--move-candidate name i -1)))))
                          (when (< i (1- (length (plist-get profile :candidates))))
                            (list (cons "下移" (lambda ()
                                                 (agent-profiles--move-candidate name i 1)))))
                          (list (cons "删除" (lambda ()
                                               (agent-profiles--delete-candidate name i)))
                                (cons "修改" (lambda ()
                                               (agent-profiles--edit-candidate name i))))))
                  (insert "  ")
                  (agent-profiles--button (car action) (cdr action))))
              (insert "\n")))
          (insert "  ")
          (agent-profiles--button
           "添加候选" (lambda () (agent-profiles--edit-candidate name)))
          (insert "\n")))
      (let ((global (plist-get agent-profiles--snapshot :quotaSkip)))
        (insert (propertize "配额阈值\n" 'face 'agent-session-assistant)
                "配额已用比例达到阈值时跳过该代理；“用到耗尽”表示一直用到余量为 0。\n"
                "全局：" (agent-profiles--threshold-label global) "  ")
        (agent-profiles--button "修改" #'agent-profiles--edit-threshold)
        (insert "\n")
        (dolist (entry (nreverse agents))
          (let* ((agent (car entry))
                 (override (agent-emx-config-agent (intern agent) :quotaSkip)))
            (insert agent "："
                    (agent-profiles--threshold-label (or (cdr entry) override global))
                    (if override "（单独设置）  " "（继承全局）  "))
            (agent-profiles--button
             "修改" (lambda () (agent-profiles--edit-threshold agent)))
            (insert "  ")
            (agent-profiles--button
             "用到耗尽" (lambda ()
                         (agent-profiles--set (list "agents" agent "quotaSkip") 1)))
            (insert "\n")))))
    (goto-char (min position (point-max)))))

(defvar-keymap agent-profiles-mode-map
  :doc "Keys for the subagent profiles page."
  :parent special-mode-map
  "g" #'agent-profiles-refresh
  "q" #'quit-window
  "RET" #'push-button
  "TAB" #'forward-button
  "<backtab>" #'backward-button)

(define-derived-mode agent-profiles-mode special-mode "Agent-Profiles"
  "View and toggle daemon subagent profiles."
  (setq-local revert-buffer-function #'agent-profiles-refresh
              truncate-lines t))

;;;###autoload
(defun agent-profiles ()
  "Show the local daemon's subagent profiles and quota thresholds."
  (interactive)
  (let ((root (if (derived-mode-p 'agent-profiles-mode)
                  (or agent-profiles--root default-directory)
                (or (when-let* ((project (project-current nil)))
                      (project-root project))
                    default-directory)))
        (buffer (get-buffer-create agent-profiles--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-profiles-mode) (agent-profiles-mode))
      (setq agent-profiles--root root)
      (agent-profiles--render)
      (agent-profiles-refresh))
    (pop-to-buffer buffer)))

(provide 'agent-profiles)
;;; agent-profiles.el ends here
