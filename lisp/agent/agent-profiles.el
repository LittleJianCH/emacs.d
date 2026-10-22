;;; agent-profiles.el --- Subagent profile controls -*- lexical-binding: t; -*-

;;; Commentary:
;; Display local daemon profiles and edit their user config overlay.

;;; Code:

(require 'agent-emx)
(require 'button)
(require 'seq)

(defconst agent-profiles--buffer "*agent-profiles*")
(defvar-local agent-profiles--snapshot nil "Last profiles response.")
(defvar-local agent-profiles--generation 0 "Newest refresh request number.")
(defvar-local agent-profiles--writing nil "Non-nil while a config write is pending.")

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
        (generation (cl-incf agent-profiles--generation)))
    (agent-emx--local-connection
     (lambda (connection)
       (when (buffer-live-p buffer)
         (agent-emx--request
          connection "collab/profiles" (make-hash-table :test #'equal)
          (lambda (result)
            (when (buffer-live-p buffer)
              (with-current-buffer buffer
                (when (= generation agent-profiles--generation)
                  (setq agent-profiles--snapshot result)
                  (agent-profiles--render)))))
          #'agent-profiles--error)))
     #'agent-profiles--error)))

(defun agent-profiles--set (path value)
  "Write VALUE at config PATH, then refresh this page.
VALUE may be a function reading the latest config cache before the write."
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
            connection "config/set"
            (list :path (vconcat path)
                  :value (if (functionp value) (funcall value) value))
            (lambda (result)
              (when-let* ((config (plist-get result :config)))
                (agent-emx-config-receive config))
              (when (buffer-live-p buffer)
                (with-current-buffer buffer
                  (setq agent-profiles--writing nil)
                  (agent-profiles-refresh))))
            failure))))
     failure)))

(defun agent-profiles--toggle (token)
  "Toggle the exact disabled TOKEN while preserving other config entries."
  (agent-profiles--set
   '("collab" "disabled")
   (lambda ()
     (let ((disabled (append (agent-emx-config-collab :disabled) nil)))
       (vconcat (if (member token disabled)
                    (delete token disabled)
                  (append disabled (list token))))))))

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
  (cond ((or profile-disabled (eq (plist-get candidate :disabled) t)) "已停用")
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
        (disabled (append (agent-emx-config-collab :disabled) nil))
        agents)
    (erase-buffer)
    (insert (propertize "子代理配置\n\n" 'face 'agent-session-assistant)
            "g 刷新 · TAB 选择按钮 · RET 执行 · q 返回\n\n")
    (if (null agent-profiles--snapshot)
        (insert "加载中…\n")
      (seq-doseq (profile (plist-get agent-profiles--snapshot :profiles))
        (let* ((name (plist-get profile :name))
               (off (eq (plist-get profile :disabled) t)))
          (insert (propertize name 'face 'agent-session-assistant)
                  (format " · 成本：%s · %s  " (plist-get profile :cost)
                          (if off "已停用" "已启用")))
          ;; A profile is also off when every candidate is; only its own
          ;; token toggles it as a whole.
          (agent-profiles--button
           (if (member name disabled) "启用" "停用")
           (lambda () (agent-profiles--toggle name)))
          (insert "\n  " (or (plist-get profile :description) "") "\n")
          (seq-doseq (candidate (plist-get profile :candidates))
            (let* ((agent (plist-get candidate :agent))
                   (model (and (stringp (plist-get candidate :model))
                               (plist-get candidate :model)))
                   (effort (plist-get candidate :effort))
                   (token (concat name ":" agent (and model (concat "/" model)))))
              (unless (assoc agent agents)
                (push (cons agent (plist-get candidate :quotaSkip)) agents))
              (insert (format "  %s · %s%s  %s  " agent (or model "默认模型")
                              (if effort (format " (%s)" effort) "")
                              (agent-profiles--status candidate off)))
              (agent-profiles--button
               (if (member token disabled) "启用" "停用")
               (lambda () (agent-profiles--toggle token)))
              (insert "\n")))
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
  (let ((buffer (get-buffer-create agent-profiles--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-profiles-mode) (agent-profiles-mode))
      (agent-profiles--render)
      (agent-profiles-refresh))
    (pop-to-buffer buffer)))

(provide 'agent-profiles)
;;; agent-profiles.el ends here
