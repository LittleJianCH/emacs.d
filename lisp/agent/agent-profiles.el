;;; agent-profiles.el --- Subagent profile controls -*- lexical-binding: t; -*-

;;; Commentary:
;; Display local daemon profiles and edit their user config overlay.

;;; Code:

(require 'agent-emx)
(require 'vtable)
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

(defun agent-profiles-refresh (&rest _)
  "Fetch the local daemon's effective subagent profiles asynchronously."
  (interactive)
  (agent-profiles--fetch (agent-profiles--selection)))

(defun agent-profiles--fetch (selection)
  "Fetch profiles and restore the logical row SELECTION."
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
                  (agent-profiles--render selection)))))
          #'agent-profiles--error)))
     #'agent-profiles--error)))

(defun agent-profiles--write (method params &optional selection)
  "Send METHOD and PARAMS, then refresh and restore row SELECTION."
  (when agent-profiles--writing (user-error "正在保存配置，请稍候"))
  (setq agent-profiles--writing t)
  (cl-incf agent-profiles--generation)
  (let* ((buffer (current-buffer))
         (selection (or selection (agent-profiles--selection)))
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
                  (agent-profiles--fetch selection))))
            failure))))
     failure)))

(defun agent-profiles--set (path value &optional selection)
  "Write VALUE at config PATH, then refresh and restore row SELECTION."
  (agent-profiles--write "config/set" (list :path (vconcat path) :value value)
                         selection))

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

(defun agent-profiles--save-candidates (name candidates &optional selection)
  "Write NAME's CANDIDATES array, then restore logical row SELECTION."
  (agent-profiles--set (list "profiles" name "candidates") (vconcat candidates)
                       selection))

(defun agent-profiles--move-candidate (name index delta)
  "Move NAME's candidate at INDEX by DELTA places."
  (let* ((candidates (vconcat (agent-profiles--candidates name)))
         (target (+ index delta)))
    (unless (<= 0 target (1- (length candidates)))
      (user-error "候选已在边界"))
    (cl-rotatef (aref candidates index) (aref candidates target))
    (agent-profiles--save-candidates name candidates
                                     (list 'candidate name target))))

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

(defun agent-profiles--edit-candidate (name &optional index after-index)
  "Edit NAME's candidate at INDEX, or insert after AFTER-INDEX.
When both indices are nil, append a candidate."
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
                    (let ((target (or index (and after-index (1+ after-index))
                                      (length candidates))))
                      (if index (setf (nth index candidates) candidate)
                        (setq candidates
                              (append (seq-take candidates target) (list candidate)
                                      (seq-drop candidates target))))
                      (agent-profiles--save-candidates
                       name candidates (list 'candidate name target))))))))))
    (agent-emx--local-connection
     (lambda (connection)
       (agent-emx--request
        connection "agents/models" (list :agent agent)
        (lambda (result)
          (funcall finish (mapcar (lambda (m) (plist-get m :id))
                                  (append (plist-get result :models) nil))))
        (lambda (_) (funcall finish nil))))
     (lambda (_) (funcall finish nil)))))

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

(defvar-local agent-profiles--rows nil "Logical row identifiers and positions.")
(defvar-local agent-profiles--description nil "Last description shown in echo area.")

(defun agent-profiles--row ()
  "Return the row at point, including when point is at the end of a line."
  (get-text-property (line-beginning-position) 'agent-profiles-row))

(defun agent-profiles--selection ()
  "Return the logical identity of the row at point."
  (plist-get (agent-profiles--row) :id))

(defun agent-profiles--goto (selection)
  "Go to SELECTION, clamping removed candidate indices within their group."
  (let ((entry (or (assoc selection agent-profiles--rows)
                   (when (eq (car selection) 'candidate)
                     (car (last (seq-filter
                                 (lambda (entry)
                                   (and (eq (caar entry) 'candidate)
                                        (equal (cadar entry) (cadr selection))))
                                 agent-profiles--rows))))
                   (car agent-profiles--rows))))
    (goto-char (if entry (cdr entry) (point-min)))))

(defun agent-profiles-next-row (&optional count)
  "Move COUNT selectable rows forward, skipping headings."
  (interactive "p")
  (let* ((count (or count 1))
         (positions (mapcar #'cdr agent-profiles--rows))
         (choices (if (< count 0)
                      (reverse (seq-filter (lambda (p) (< p (line-beginning-position)))
                                           positions))
                    (seq-filter (lambda (p) (> p (line-beginning-position))) positions))))
    (when (and choices (/= count 0))
      (goto-char (nth (min (1- (abs count)) (1- (length choices))) choices)))))

(defun agent-profiles-previous-row (&optional count)
  "Move COUNT selectable rows backward."
  (interactive "p")
  (agent-profiles-next-row (- (or count 1))))

(defun agent-profiles-next-group (&optional backward)
  "Jump to the next profile group, or the previous when BACKWARD is non-nil."
  (interactive)
  (let* ((id (agent-profiles--selection))
         (name (and (eq (car id) 'candidate) (cadr id)))
         (groups (seq-filter
                  (lambda (entry)
                    (and (eq (caar entry) 'candidate) (= (nth 2 (car entry)) 0)))
                  agent-profiles--rows))
         (target (seq-find
                  (lambda (entry)
                    (and (not (equal name (cadar entry)))
                         (if backward (< (cdr entry) (point))
                           (> (cdr entry) (point)))))
                  (if backward (reverse groups) groups))))
    (when target (goto-char (cdr target)))))

(defun agent-profiles-previous-group ()
  "Jump to the previous profile group."
  (interactive)
  (agent-profiles-next-group t))

(defun agent-profiles--candidate-row ()
  "Return the candidate row at point, or signal a user error."
  (let ((row (agent-profiles--row)))
    (unless (eq (car (plist-get row :id)) 'candidate)
      (user-error "请先选择候选行"))
    row))

(defun agent-profiles-move-down (&optional up)
  "Move the candidate at point down, or up when UP is non-nil."
  (interactive)
  (let ((id (plist-get (agent-profiles--candidate-row) :id)))
    (agent-profiles--move-candidate (nth 1 id) (nth 2 id) (if up -1 1))))

(defun agent-profiles-move-up ()
  "Move the candidate at point up within its profile."
  (interactive)
  (agent-profiles-move-down t))

(defun agent-profiles-toggle ()
  "Toggle the candidate at point using the daemon's disabled state."
  (interactive)
  (let* ((row (agent-profiles--candidate-row))
         (id (plist-get row :id)))
    (agent-profiles--disable (nth 1 id)
                             (not (eq (plist-get (plist-get row :candidate) :disabled) t))
                             (nth 2 id))))

(defun agent-profiles-toggle-profile ()
  "Toggle the whole profile at point using its daemon disable reasons."
  (interactive)
  (let* ((row (agent-profiles--candidate-row))
         (profile (plist-get row :profile))
         (name (plist-get profile :name))
         ;; All candidates can be disabled without the profile token being set.
         (off (seq-some
               (lambda (candidate)
                 (member name (append (plist-get candidate :disabledBy) nil)))
               (plist-get profile :candidates))))
    (agent-profiles--disable name (not off))))

(defun agent-profiles-edit ()
  "Edit the candidate or quota threshold at point."
  (interactive)
  (pcase (agent-profiles--selection)
    (`(candidate ,name ,index) (agent-profiles--edit-candidate name index))
    (`(threshold ,agent) (agent-profiles--edit-threshold agent))
    (_ (user-error "请先选择候选或阈值行"))))

(defun agent-profiles-add ()
  "Insert a new candidate after the row at point."
  (interactive)
  (let ((id (plist-get (agent-profiles--candidate-row) :id)))
    (agent-profiles--edit-candidate (nth 1 id) nil (nth 2 id))))

(defun agent-profiles-delete ()
  "Confirm deletion of the candidate at point."
  (interactive)
  (let ((id (plist-get (agent-profiles--candidate-row) :id)))
    (when (y-or-n-p (format "删除 %s 的第 %d 个候选？" (nth 1 id) (1+ (nth 2 id))))
      (agent-profiles--delete-candidate (nth 1 id) (nth 2 id)))))

(defun agent-profiles-restore ()
  "Confirm restoring the profile at point to its default configuration."
  (interactive)
  (let* ((profile (plist-get (agent-profiles--candidate-row) :profile))
         (name (plist-get profile :name)))
    (unless (eq (plist-get profile :overridden) t)
      (user-error "该配置已使用默认值"))
    (when (y-or-n-p (format "恢复 %s 的默认配置？" name))
      (agent-profiles--set (list "profiles" name) nil))))

(defun agent-profiles-exhaust ()
  "Allow the threshold row at point to use all its quota."
  (interactive)
  (pcase (agent-profiles--selection)
    (`(threshold ,agent)
     (agent-profiles--set (if agent (list "agents" agent "quotaSkip")
                            '("collab" "quotaSkip")) 1))
    (_ (user-error "请先选择阈值行"))))

(defun agent-profiles-help ()
  "Show the profile page's keyboard commands."
  (interactive)
  (with-help-window "*子代理配置帮助*"
    (princ "子代理配置 · 键盘操作\n\n")
    (princ "n / p、C-n / C-p：逐行移动    TAB / S-TAB：切换配置组\n")
    (princ "M-↑ / M-p：上移候选    M-↓ / M-n：下移候选\n")
    (princ "SPC / x：切换候选    X：切换整组配置\n")
    (princ "RET / e：编辑候选或阈值    a：在本行后添加候选\n")
    (princ "D：删除候选（确认）    R：恢复配置默认值（确认）\n")
    (princ "阈值行 z：用到耗尽；编辑时留空继承全局（全局行除外）\n")
    (princ "g：刷新    q：返回    ?：帮助\n\n")
    (princ "Evil 普通状态：j / k 移动，J / K 下移 / 上移候选，gr 刷新。\n")
    (princ "配置名后的 * 表示自定义覆盖，⊘ 表示整组已停用。\n")
    (princ "配额已用比例达到阈值时跳过；用到耗尽表示一直用到余量为 0。\n")))

(defun agent-profiles--describe ()
  "Show the current profile description in the echo area."
  (let ((description (plist-get (plist-get (agent-profiles--row) :profile)
                                :description)))
    (unless (equal description agent-profiles--description)
      (setq agent-profiles--description description)
      (message "%s" (or description "")))))

(defun agent-profiles--table (columns rows)
  "Insert a pixel-aligned table with COLUMNS and logical ROWS."
  (let ((start (point)))
    (make-vtable
     :columns (mapcar (lambda (name) (list :name name :min-width (1+ (string-width name))
                                           :align 'left)) columns)
     :objects rows :getter (lambda (row column _) (nth column (plist-get row :cells)))
     :use-header-line nil :face 'default :separator-width 2 :ellipsis nil)
    ;; Sorting would destroy profile grouping.  Keep one page-wide keymap.
    (goto-char start)
    (forward-line 1)
    (dolist (row rows)
      (let ((begin (point)))
        (push (cons (plist-get row :id) begin) agent-profiles--rows)
        (forward-line 1)
        (put-text-property begin (point) 'agent-profiles-row row)))
    (remove-text-properties start (point) '(keymap nil mouse-face nil))))

(defun agent-profiles--render (&optional selection)
  "Render the snapshot, restoring logical row SELECTION rather than a position."
  (let ((inhibit-read-only t)
        (selection (or selection (agent-profiles--selection)))
        agents rows)
    (erase-buffer)
    (setq agent-profiles--rows nil)
    (insert (propertize "子代理配置  " 'face 'agent-session-assistant)
            (abbreviate-file-name (or agent-profiles--root default-directory))
            (propertize "    ? 帮助\n" 'face 'agent-session-dim)
            (propertize "n/p 移动 · TAB 切组 · x/X 开关 · e 编辑 · a 添加 · M-↑/↓ 排序\n\n"
                        'face 'agent-session-dim))
    (if (null agent-profiles--snapshot)
        (insert "加载中…\n")
      (seq-doseq (profile (plist-get agent-profiles--snapshot :profiles))
        (let ((name (plist-get profile :name))
              (off (eq (plist-get profile :disabled) t)))
          (cl-loop for candidate across (plist-get profile :candidates)
                   for index from 0 do
		   (let* ((agent (plist-get candidate :agent))
			  (disabled (or off (eq (plist-get candidate :disabled) t)))
			  (face (cond (disabled 'agent-session-dim)
				      ((not (eq (plist-get candidate :available) t))
                                       'agent-session-error)
				      ((plist-get candidate :strained) 'warning)
				      (t 'agent-session-ok)))
			  (cells (list
				  (if (= index 0)
				      (concat name (when (eq (plist-get profile :overridden) t) "*")
					      (when off " ⊘")) "")
				  (if (= index 0) (or (plist-get profile :cost) "") "")
				  agent
				  (if (stringp (plist-get candidate :model))
				      (plist-get candidate :model) "默认模型")
				  (or (plist-get candidate :effort) "")
				  (propertize (agent-profiles--status candidate off) 'face face))))
		     (unless (assoc agent agents)
                       (push (cons agent (plist-get candidate :quotaSkip)) agents))
		     (when off
                       (setq cells (mapcar (lambda (s) (propertize s 'face 'agent-session-dim))
					   cells)))
		     (push (list :id (list 'candidate name index) :profile profile
				 :candidate candidate :cells cells) rows)))))
      (agent-profiles--table '("Profile" "成本" "Agent" "模型" "Effort" "状态")
                             (nreverse rows))
      (insert "\n" (propertize "配额阈值\n" 'face 'agent-session-assistant))
      (let ((global (plist-get agent-profiles--snapshot :quotaSkip)) thresholds)
        (dolist (entry (nreverse agents))
          (let* ((agent (car entry))
                 (override (agent-emx-config-agent (intern agent) :quotaSkip)))
            (push (list :id (list 'threshold agent)
                        :cells (list agent
                                     (agent-profiles--threshold-label
                                      (or (cdr entry) override global))
                                     (if override "单独设置" "继承全局"))) thresholds)))
        (agent-profiles--table
         '("Agent" "阈值" "来源")
         (append (nreverse thresholds)
                 (list (list :id '(threshold nil)
                             :cells (list "全局" (agent-profiles--threshold-label global)
                                          "")))))))
    (setq agent-profiles--rows (nreverse agent-profiles--rows))
    (agent-profiles--goto selection)))

(defvar-keymap agent-profiles-mode-map
  :doc "Keys for the subagent profiles table."
  :parent special-mode-map
  "n" #'agent-profiles-next-row
  "p" #'agent-profiles-previous-row
  "C-n" #'agent-profiles-next-row
  "C-p" #'agent-profiles-previous-row
  "TAB" #'agent-profiles-next-group
  "S-TAB" #'agent-profiles-previous-group
  "<backtab>" #'agent-profiles-previous-group
  "M-<up>" #'agent-profiles-move-up
  "M-<down>" #'agent-profiles-move-down
  "M-p" #'agent-profiles-move-up
  "M-n" #'agent-profiles-move-down
  "SPC" #'agent-profiles-toggle
  "x" #'agent-profiles-toggle
  "X" #'agent-profiles-toggle-profile
  "RET" #'agent-profiles-edit
  "e" #'agent-profiles-edit
  "a" #'agent-profiles-add
  "D" #'agent-profiles-delete
  "R" #'agent-profiles-restore
  "z" #'agent-profiles-exhaust
  "?" #'agent-profiles-help
  "g" #'agent-profiles-refresh
  "q" #'quit-window)

(define-derived-mode agent-profiles-mode special-mode "Agent-Profiles"
  "Edit daemon subagent profiles using the row at point."
  (setq-local revert-buffer-function #'agent-profiles-refresh
              truncate-lines t)
  (hl-line-mode 1)
  (add-hook 'post-command-hook #'agent-profiles--describe nil t))

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
