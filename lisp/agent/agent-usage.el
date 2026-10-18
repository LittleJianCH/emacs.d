;;; agent-usage.el --- Usage of turns sent from Emacs -*- lexical-binding: t; -*-

;;; Commentary:

;; Only `agent-session--deliver' opens an accounting scope.  Replay and external
;; transcript sync never open one.  Backends submit request snapshots, not deltas;
;; repeated streaming updates replace the same request.  Journals contain only
;; metadata and counters, never prompts, responses or credentials.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'json)
(require 'tabulated-list)
(require 'agent-session)

(defgroup agent-usage nil
  "Local usage of agent turns sent from Emacs."
  :group 'agent-session)

(defcustom agent-usage-enabled t
  "Whether to record new turns sent from Emacs."
  :type 'boolean)

(defcustom agent-usage-directory (locate-user-emacs-file "var/usage/")
  "Local directory for usage journals."
  :type 'directory)

(defvar agent-usage--dirty (make-hash-table :test #'equal))
(defvar agent-usage--timer nil)
(defvar agent-usage--journal-name
  (format "%s-%s-%x.jsonl" (format-time-string "%Y%m%dT%H%M%S")
          (emacs-pid) (random most-positive-fixnum)))

(defconst agent-usage--counters
  '(:input_tokens :output_tokens :cache_read_tokens :cache_write_tokens
		  :reasoning_tokens :total_tokens :cost_usd)
  "Input includes cache tokens; reasoning is a subset of output.")

(defun agent-usage--state (session)
  "Return the active accounting scope of SESSION."
  (plist-get (agent-session-state session) :usage))

(defun agent-usage--set-state (session value)
  "Set SESSION's accounting scope to VALUE."
  (setf (agent-session-state session)
        (plist-put (agent-session-state session) :usage value)))

(defun agent-usage--save (record)
  "Queue a copy of RECORD for a coalesced journal write."
  (puthash (plist-get record :id) (copy-tree record) agent-usage--dirty)
  (unless agent-usage--timer
    (setq agent-usage--timer (run-at-time 1 nil #'agent-usage-flush))))

(defun agent-usage-flush ()
  "Append pending snapshots to the local journal, retaining them on error."
  (interactive)
  (when (timerp agent-usage--timer) (cancel-timer agent-usage--timer))
  (setq agent-usage--timer nil)
  (when (> (hash-table-count agent-usage--dirty) 0)
    (condition-case err
        (progn
          (when (file-remote-p agent-usage-directory)
            (error "Usage journals must be local"))
          (make-directory agent-usage-directory t)
          (let ((coding-system-for-write 'no-conversion))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (maphash (lambda (_ record)
                         (insert (json-serialize record) "\n"))
                       agent-usage--dirty)
              (write-region (point-min) (point-max)
                            (expand-file-name agent-usage--journal-name
                                              agent-usage-directory)
                            t 'silent)))
          (clrhash agent-usage--dirty))
      (error (message "用量记录保存失败：%s" (error-message-string err))))))

(defun agent-usage-begin (session)
  "Open a scope immediately before SESSION sends a new turn."
  (when agent-usage-enabled
    (agent-usage-finish session 'superseded)
    (let* ((root (agent-session-root session))
           (now (float-time))
           (record (list :id (format "%s-%x" agent-usage--journal-name
                                     (random most-positive-fixnum))
                         :started_at now :date (format-time-string "%F")
                         :backend (symbol-name (agent-session-backend session))
                         :project root :host (or (file-remote-p root 'host) "local")
                         :session_id (agent-session-resume-id session)
                         :model (or (agent-session-setting session :model)
                                    (plist-get (agent-session-info session) :model))
                         :status "running" :coverage "unknown")))
      (agent-usage--set-state
       session (list :record record :requests (make-hash-table :test #'equal)))
      (agent-usage--save record))))

(defun agent-usage-finish (session status)
  "Close SESSION's active scope with STATUS before another turn is delivered."
  (when-let* ((scope (agent-usage--state session)))
    (let ((record (plist-get scope :record)))
      (setq record (plist-put record :status (symbol-name status)))
      (setq record (plist-put record :ended_at (float-time)))
      (setq record (plist-put record :session_id (agent-session-resume-id session)))
      (agent-usage--save record))
    (agent-usage--set-state session nil)))

(defun agent-usage--status (session status)
  "Finish SESSION's accounting when STATUS becomes idle or exited."
  (when (memq status '(idle exited)) (agent-usage-finish session status)))

(defun agent-usage--sum (items)
  "Sum available counters in metric plists ITEMS, preserving unknown values."
  (let (result)
    (dolist (key agent-usage--counters result)
      (let ((values (delq nil (mapcar (lambda (item) (plist-get item key)) items))))
        (when values (setq result (plist-put result key (apply #'+ values))))))))

(defun agent-usage-record (session request metrics &optional partial)
  "Merge METRICS into REQUEST's snapshot in SESSION's active turn.
Counters are nonnegative numbers.  Missing counters stay unknown.  PARTIAL
means the backend cannot establish complete coverage of this turn."
  (when-let* ((scope (agent-usage--state session)) (request request))
    (let* ((requests (plist-get scope :requests))
           (snapshot (gethash request requests))
           (record (plist-get scope :record)))
      (dolist (key agent-usage--counters)
        (let ((value (plist-get metrics key)))
          (when (and (numberp value) (>= value 0))
            (setq snapshot (plist-put snapshot key value)))))
      (when (and (not (plist-get metrics :total_tokens))
                 (numberp (plist-get snapshot :input_tokens))
                 (numberp (plist-get snapshot :output_tokens)))
        (setq snapshot (plist-put snapshot :total_tokens
                                  (+ (plist-get snapshot :input_tokens)
                                     (plist-get snapshot :output_tokens)))))
      (when snapshot
        (puthash request snapshot requests)
        (setq record (append (agent-usage--sum (hash-table-values requests))
                             (cl-loop for (key value) on record by #'cddr
                                      unless (memq key agent-usage--counters)
                                      append (list key value))))
        (when partial (setq scope (plist-put scope :partial t)))
        (setq record (plist-put record :coverage
                                (cond ((or (plist-get scope :partial)
                                           (seq-some
                                            (lambda (r) (not (numberp (plist-get r :total_tokens))))
                                            (hash-table-values requests))) "partial")
                                      ((numberp (plist-get record :total_tokens)) "complete")
                                      (t "unknown"))))
        (when-let* ((model (plist-get metrics :model)))
          (let ((models (seq-uniq (cons model (plist-get scope :models)))))
            (setq scope (plist-put scope :models models))
            (setq record (plist-put record :model
                                    (if (length= models 1) model "multiple")))))
        (setq record (plist-put record :session_id (agent-session-resume-id session)))
        (setq scope (plist-put scope :record record))
        (agent-usage--set-state session scope)
        (agent-usage--save record)))))

(defun agent-usage-replace (session metrics &optional partial)
  "Replace SESSION's provisional request snapshots with final METRICS.
PARTIAL has the same meaning as in `agent-usage-record'."
  (when-let* ((scope (agent-usage--state session)))
    (clrhash (plist-get scope :requests))
    (setq scope (plist-put scope :partial nil))
    (setq scope (plist-put scope :models nil))
    (agent-usage--set-state session scope)
    (agent-usage-record session "result" metrics partial)))

(defun agent-usage-difference (current previous)
  "Subtract PREVIOUS metric snapshot from CURRENT, or return nil on reset.
A missing PREVIOUS is an unknown baseline and must never count history."
  (when previous
    (let (result reset)
      (dolist (key agent-usage--counters)
        (let ((value (plist-get current key)) (old (plist-get previous key)))
          (when (and (numberp value) (numberp old))
            (if (< value old) (setq reset t)
              (setq result (plist-put result key (- value old)))))))
      (unless reset result))))

(defun agent-usage--valid-record-p (record)
  "Whether RECORD is a usable journal snapshot."
  (and (listp record) (stringp (plist-get record :id))
       (numberp (plist-get record :started_at))
       (stringp (plist-get record :date))
       (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'"
                       (plist-get record :date))
       (stringp (plist-get record :backend))
       (stringp (plist-get record :project))
       (member (plist-get record :coverage) '("unknown" "partial" "complete"))
       (cl-every (lambda (key)
                   (let ((value (plist-get record key)))
                     (or (null value) (and (numberp value) (>= value 0)))))
                 agent-usage--counters)))

(defun agent-usage-records ()
  "Read latest snapshots from local journals and pending writes.
Ignore malformed lines, including interrupted writes, without discarding
other records.  Separate writer files avoid interleaved Emacs processes."
  (let ((records (make-hash-table :test #'equal)) (bad 0))
    (when (file-remote-p agent-usage-directory)
      (error "Usage journals must be local"))
    (when (file-directory-p agent-usage-directory)
      (dolist (file (directory-files agent-usage-directory t "\\.jsonl\\'"))
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (while (not (eobp))
            (condition-case nil
                (let ((record (json-parse-string
                               (buffer-substring-no-properties
                                (line-beginning-position) (line-end-position))
                               :object-type 'plist :null-object nil)))
                  (if (agent-usage--valid-record-p record)
                      (puthash (plist-get record :id) record records)
                    (cl-incf bad)))
              (error (cl-incf bad)))
            (forward-line 1)))))
    (maphash (lambda (id record) (puthash id record records)) agent-usage--dirty)
    (list :records (hash-table-values records) :invalid_lines bad)))

(defun agent-usage--period-start (period)
  "Return the first local calendar date in PERIOD."
  (let* ((now (decode-time))
         (day (decoded-time-day now)))
    (pcase period
      ("all" nil)
      ("today" (format-time-string "%F"))
      ("week"
       (setf (decoded-time-day now)
             (- day (mod (+ 6 (decoded-time-weekday now)) 7)))
       (format-time-string "%F" (encode-time now)))
      ("month" (setf (decoded-time-day now) 1)
       (format-time-string "%F" (encode-time now)))
      (_ (error "Unknown usage period: %s" period)))))

(cl-defun agent-usage-query (&key (period "today") (group "project") project backend ids details)
  "Summarize locally observed turns in PERIOD, grouped by GROUP.
Optional PROJECT and BACKEND restrict the records.  Calendar boundaries
use local time, with Monday as the start of the week."
  (unless (member group '("date" "project" "backend" "model" "session" "turn"))
    (error "Unknown usage grouping: %s" group))
  (let* ((start (agent-usage--period-start period))
         (end (format-time-string "%F"))
         (loaded (agent-usage-records))
         (records (seq-filter
                   (lambda (record)
                     (let ((date (plist-get record :date)))
                       (and (or (null start) (not (string< date start)))
                            (not (string< end date))
                            (or (null ids) (member (plist-get record :id) ids))
                            (or (null project) (equal project (plist-get record :project)))
                            (or (null backend) (equal backend (plist-get record :backend))))))
                   (plist-get loaded :records)))
         (groups (make-hash-table :test #'equal)))
    (dolist (record records)
      (let ((key (agent-usage--group-key record group)))
        (puthash key (cons record (gethash key groups)) groups)))
    (list :scope "emacs" :period period :group group
          :invalid_lines (plist-get loaded :invalid_lines)
          :totals (agent-usage--summary records)
          :groups (vconcat
                   (sort (cl-loop for key being the hash-keys of groups
                                  using (hash-values items)
                                  collect (append (list :key key)
                                                  (agent-usage--summary items)))
                         (lambda (a b) (string< (plist-get a :key) (plist-get b :key)))))
          :records (when (or details (equal group "turn"))
                     (vconcat (sort records (lambda (a b) (> (plist-get a :started_at)
                                                             (plist-get b :started_at)))))))))

(defun agent-usage--group-key (record group)
  "Return RECORD's key in GROUP."
  (pcase group
    ("session" (format "%s:%s:%s" (plist-get record :backend)
                       (plist-get record :host)
                       (or (plist-get record :session_id) (plist-get record :id))))
    ("turn" (plist-get record :id))
    (_ (or (plist-get record (intern (concat ":" group))) "unknown"))))

(defun agent-usage--summary (records)
  "Summarize counters and coverage of RECORDS."
  (append (list :turns (length records)
                :unknown_turns (cl-count "unknown" records :key
                                         (lambda (r) (plist-get r :coverage)) :test #'equal)
                :partial_turns (cl-count "partial" records :key
                                         (lambda (r) (plist-get r :coverage)) :test #'equal)
                :cost_known_turns (cl-count-if
                                   (lambda (r) (numberp (plist-get r :cost_usd))) records))
          (if records (agent-usage--sum records) '(:total_tokens 0))))

;;; Native usage page

(defvar-local agent-usage--period "today")
(defvar-local agent-usage--group "project")
(defvar-local agent-usage--filters nil)
(defvar-local agent-usage--back-stack nil)

(defconst agent-usage--period-labels
  '(("today" . "今日") ("week" . "本周") ("month" . "本月") ("all" . "全部")))
(defconst agent-usage--group-labels
  '(("date" . "日期") ("project" . "项目") ("backend" . "后端")
    ("model" . "模型") ("session" . "会话") ("turn" . "轮次")))

(defun agent-usage--number (value)
  "Format VALUE, preserving unknown counters."
  (if (numberp value) (format "%s" value) "未知"))

(defun agent-usage--row-label (row records)
  "Return ROW's readable label, using turn metadata in RECORDS."
  (let ((key (plist-get row :key)))
    (cond
     ((equal agent-usage--group "turn")
      (let ((record (seq-find (lambda (r) (equal key (plist-get r :id))) records)))
        (format "%s · %s · %s"
                (format-time-string "%m-%d %H:%M:%S" (plist-get record :started_at))
                (plist-get record :backend)
                (or (plist-get record :model) "未知"))))
     ((equal key "unknown") "未知")
     ((and (equal agent-usage--group "model") (equal key "multiple")) "多模型")
     (t key))))

(defun agent-usage--refresh (&rest _)
  "Refresh the current usage page."
  (let* ((result (apply #'agent-usage-query :period agent-usage--period
                        :group agent-usage--group agent-usage--filters))
         (total (plist-get result :totals)))
    (setq header-line-format
          (format " %s · 按%s · %d 轮 · %s token · 未知 %d / 不完整 %d · 异常记录 %d"
                  (cdr (assoc agent-usage--period agent-usage--period-labels))
                  (cdr (assoc agent-usage--group agent-usage--group-labels))
                  (plist-get total :turns)
                  (agent-usage--number (plist-get total :total_tokens))
                  (plist-get total :unknown_turns) (plist-get total :partial_turns)
                  (plist-get result :invalid_lines))
          tabulated-list-entries
          (mapcar
           (lambda (row)
             (list (plist-get row :key)
                   (vector (agent-usage--row-label row (plist-get result :records))
                           (number-to-string (plist-get row :turns))
                           (agent-usage--number (plist-get row :total_tokens))
                           (agent-usage--number (plist-get row :input_tokens))
                           (agent-usage--number (plist-get row :output_tokens))
                           (agent-usage--number (plist-get row :cache_read_tokens))
                           (if-let* ((cost (plist-get row :cost_usd)))
                               (format "$%.4f (%d/%d)" cost
                                       (plist-get row :cost_known_turns)
                                       (plist-get row :turns)) "未知")
                           (format "%d/%d" (plist-get row :unknown_turns)
                                   (plist-get row :partial_turns)))))
           (append (plist-get result :groups) nil)))
    (tabulated-list-print t)))

(defun agent-usage-select-period ()
  "Select the usage page's calendar period."
  (interactive)
  (let ((label (completing-read "时间范围：" (mapcar #'cdr agent-usage--period-labels)
                                nil t)))
    (setq agent-usage--period (car (rassoc label agent-usage--period-labels))
          agent-usage--filters nil agent-usage--back-stack nil))
  (agent-usage--refresh))

(defun agent-usage-select-group ()
  "Select the usage page's grouping."
  (interactive)
  (let ((label (completing-read "按什么汇总：" (mapcar #'cdr agent-usage--group-labels)
                                nil t)))
    (setq agent-usage--group (car (rassoc label agent-usage--group-labels))
          agent-usage--filters nil agent-usage--back-stack nil))
  (agent-usage--refresh))

(defun agent-usage-drill-down ()
  "Show individual turns for the current group, or metadata for a turn."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (if (equal agent-usage--group "turn")
        (let* ((result (apply #'agent-usage-query :period agent-usage--period
                              :group "turn" agent-usage--filters))
               (record (seq-find (lambda (r) (equal id (plist-get r :id)))
                                 (plist-get result :records))))
          (with-help-window "*用量明细*"
            (princ (format "日期：%s\n后端：%s\n项目：%s\n主机：%s\n模型：%s\n会话：%s\n状态：%s\n覆盖：%s\n"
                           (plist-get record :date) (plist-get record :backend)
                           (plist-get record :project) (plist-get record :host)
                           (pcase (plist-get record :model)
                             ("multiple" "多模型") ((pred null) "未知") (model model))
                           (or (plist-get record :session_id) "未知")
                           (pcase (plist-get record :status)
                             ("running" "进行中") ("idle" "已结束")
                             ("exited" "已退出") (_ "已中断"))
                           (pcase (plist-get record :coverage)
                             ("complete" "完整") ("partial" "不完整") (_ "未知"))))
            (princ (format "\n输入：%s\n输出：%s\n缓存读取：%s\n缓存写入：%s\n推理：%s\n总量：%s\n"
                           (agent-usage--number (plist-get record :input_tokens))
                           (agent-usage--number (plist-get record :output_tokens))
                           (agent-usage--number (plist-get record :cache_read_tokens))
                           (agent-usage--number (plist-get record :cache_write_tokens))
                           (agent-usage--number (plist-get record :reasoning_tokens))
                           (agent-usage--number (plist-get record :total_tokens))))
            (princ (format "后端估算费用：%s\n"
                           (if-let* ((cost (plist-get record :cost_usd)))
                               (format "$%.4f" cost) "未知")))))
      (let* ((result (apply #'agent-usage-query :period agent-usage--period :details t
                            :group agent-usage--group agent-usage--filters))
             (ids (cl-loop for r across (plist-get result :records)
                           when (equal id (agent-usage--group-key r agent-usage--group))
                           collect (plist-get r :id))))
        (push (list agent-usage--period agent-usage--group agent-usage--filters)
              agent-usage--back-stack)
        (setq agent-usage--filters (plist-put (copy-sequence agent-usage--filters) :ids ids)
              agent-usage--group "turn")
        (agent-usage--refresh)))))

(defun agent-usage-back ()
  "Return to the preceding summary on the usage page."
  (interactive)
  (when-let* ((previous (pop agent-usage--back-stack)))
    (setq agent-usage--period (nth 0 previous)
          agent-usage--group (nth 1 previous)
          agent-usage--filters (nth 2 previous))
    (agent-usage--refresh)))

(defvar-keymap agent-usage-mode-map
  :doc "Keys for the local usage page."
  :parent tabulated-list-mode-map
  "p" #'agent-usage-select-period
  "G" #'agent-usage-select-group
  "RET" #'agent-usage-drill-down
  "b" #'agent-usage-back)

(defun agent-usage--numeric-sort (column)
  "Return a numeric table comparator for COLUMN, with unknown values first."
  (lambda (a b)
    (let ((left (aref (cadr a) column)) (right (aref (cadr b) column)))
      (< (if (equal left "未知") -1 (string-to-number left))
         (if (equal right "未知") -1 (string-to-number right))))))

(define-derived-mode agent-usage-mode tabulated-list-mode "用量"
  "Browse usage recorded for turns sent from Emacs."
  (setq tabulated-list-format
        (vector (list "分组" 34 t)
                (list "轮数" 5 (agent-usage--numeric-sort 1))
                (list "总量" 12 (agent-usage--numeric-sort 2))
                (list "输入（含缓存）" 15 (agent-usage--numeric-sort 3))
                (list "输出" 10 (agent-usage--numeric-sort 4))
                (list "缓存读取" 12 (agent-usage--numeric-sort 5))
                '("后端估算费用（已知/总轮）" 25 nil)
                '("未知/不完整" 14 nil))
        tabulated-list-padding 1
        revert-buffer-function #'agent-usage--refresh
        mode-line-process "  p 时间范围 · G 分组 · RET 明细 · b 上层 · g 刷新 · q 返回")
  (tabulated-list-init-header))

(defun agent-usage-show ()
  "Show the local usage page; only Emacs-delivered turns are included."
  (interactive)
  (pop-to-buffer (get-buffer-create "*Agent 用量*"))
  (unless (derived-mode-p 'agent-usage-mode) (agent-usage-mode))
  (agent-usage--refresh))

(add-hook 'agent-session-before-send-functions #'agent-usage-begin)
(add-hook 'agent-session-status-change-functions #'agent-usage--status)
(add-hook 'kill-emacs-hook #'agent-usage-flush)

(provide 'agent-usage)
;;; agent-usage.el ends here
