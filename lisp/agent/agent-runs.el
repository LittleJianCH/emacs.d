;;; agent-runs.el --- Subagent run summaries -*- lexical-binding: t; -*-

;;; Commentary:
;; Display local daemon run statistics and expandable, rated run details.

;;; Code:

(require 'agent-emx)
(require 'pixel-fill)
(require 'seq)

(defface agent-runs-heading '((t :inherit bold))
  "Heading of the subagent run summary."
  :group 'agent-session)

(defface agent-runs-rework '((t :inherit warning))
  "Run ratings that required rework."
  :group 'agent-session)

(defconst agent-runs--buffer "*子代理评估*")
(defconst agent-runs--ranges '(604800 2592000 0))
(defconst agent-runs--columns
  '("角色" "模型" "次数" "失败率" "已评" "可用 / 返工 / 错误"
    "已核实" "中位耗时" "token 输入含缓存 / 输出"))
(defvar-local agent-runs--range 2592000 "Requested range in seconds.")
(defvar-local agent-runs--snapshot nil "Last successful daemon response.")
(defvar-local agent-runs--generation 0 "Newest refresh request number.")
(defvar-local agent-runs--expanded nil "Expanded profile, agent and model keys.")
(defvar-local agent-runs--rows nil "Logical row identifiers and positions.")
(defvar-local agent-runs--error nil "Current request error message.")
(defvar-local agent-runs--loading nil "Non-nil while a refresh is pending.")

(defun agent-runs--range-label ()
  "Return the localized range label."
  (pcase agent-runs--range (604800 "7 天") (2592000 "30 天") (_ "全部")))

(defun agent-runs--group-key (group)
  "Return GROUP's stable identity."
  (mapcar (lambda (key) (plist-get group key)) '(:profile :agent :model)))

(defun agent-runs--selection ()
  "Return the logical row at point."
  (get-text-property (line-beginning-position) 'agent-runs-row))

(defun agent-runs--goto (selection)
  "Restore SELECTION, falling back to its group or the first row."
  (when-let* ((row (or (assoc selection agent-runs--rows)
                      (assoc (seq-take selection 3) agent-runs--rows)
                      (car agent-runs--rows))))
    (goto-char (cdr row))))

(defun agent-runs-refresh (&rest _)
  "Fetch local subagent runs asynchronously."
  (interactive)
  (let* ((buffer (current-buffer))
         (range agent-runs--range)
         (generation (cl-incf agent-runs--generation))
         (current (lambda ()
                    (and (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (and (derived-mode-p 'agent-runs-mode)
                                (= generation agent-runs--generation))))))
         (failure (lambda (error)
                    (when (funcall current)
                      (with-current-buffer buffer
                        (setq agent-runs--loading nil
                              agent-runs--error
                              (format "加载失败：%s"
                                      (or (plist-get error :message) error)))
                        (agent-runs--render))))))
    (setq agent-runs--loading t agent-runs--error nil)
    (agent-runs--render)
    (agent-emx--local-connection
     (lambda (connection)
       (when (funcall current)
         (agent-emx--request
          connection "collab/runs" (list :range range)
          (lambda (result)
            (when (funcall current)
              (with-current-buffer buffer
                (setq agent-runs--snapshot result agent-runs--loading nil)
                (agent-runs--render))))
          failure)))
     failure)))

(defun agent-runs-cycle-range ()
  "Cycle through the last seven days, thirty days and all time."
  (interactive)
  (setq agent-runs--range
        (or (cadr (member agent-runs--range agent-runs--ranges))
            (car agent-runs--ranges))
        agent-runs--snapshot nil)
  (agent-runs-refresh))

(defun agent-runs--duration (seconds)
  "Format a duration in SECONDS, or a missing median."
  (if (not (numberp seconds)) "—"
    (let* ((seconds (round seconds))
           (hours (/ seconds 3600))
           (minutes (/ (% seconds 3600) 60))
           (rest (% seconds 60)))
      (string-join
       (delq nil (list (when (> hours 0) (format "%d 时" hours))
                       (when (> minutes 0) (format "%d 分" minutes))
                       (when (or (> rest 0) (= seconds 0)) (format "%d 秒" rest))))
       " "))))

(defun agent-runs--count (count)
  "Format token COUNT compactly."
  (let ((count (or count 0)))
    (cond ((>= count 1000000) (format "%.3gM" (/ count 1000000.0)))
          ((>= count 1000) (format "%.3gk" (/ count 1000.0)))
          (t (format "%d" count)))))

(defun agent-runs--tokens (tokens)
  "Format TOKENS as input including cache, then output."
  (format "%s / %s"
          (agent-runs--count (+ (or (plist-get tokens :input) 0)
                                (or (plist-get tokens :cache_read) 0)
                                (or (plist-get tokens :cache_write) 0)))
          (agent-runs--count (plist-get tokens :output))))

(defun agent-runs--percent (count total)
  "Format COUNT's share of TOTAL, or an unavailable share."
  (if (zerop total) "—" (format "%.0f%%" (* 100.0 (/ count (float total))))))

(defun agent-runs--verdict (verdict)
  "Return localized, colored VERDICT."
  (pcase verdict
    ("usable" (propertize "可用" 'face 'agent-session-ok))
    ("rework" (propertize "返工" 'face 'agent-runs-rework))
    ("wrong" (propertize "错误" 'face 'agent-session-error))
    (_ (propertize "未评" 'face 'agent-session-dim))))

(defun agent-runs--cells (group)
  "Return summary cells for GROUP."
  (let* ((key (agent-runs--group-key group))
         (agent (plist-get group :agent))
         (title (or (agent-session--get (intern agent) :title) agent))
         (model (plist-get group :model))
         (runs (plist-get group :runs))
         (rated (plist-get group :rated)))
    (list
     (concat (if (member key agent-runs--expanded) "▾ " "▸ ") (car key))
     (concat title " " (if (stringp model)
                            (agent-session-model-short-name model title) "未知模型"))
     (number-to-string runs)
     (propertize (agent-runs--percent (plist-get group :failed) runs)
                 'help-echo (format "失败 %d 次；提前关闭 %d 次"
                                    (plist-get group :failed) (plist-get group :closed)))
     (number-to-string rated)
     (mapconcat (lambda (pair)
                  (propertize (number-to-string (plist-get group (car pair)))
                              'face (cdr pair)))
                '((:usable . agent-session-ok) (:rework . agent-runs-rework)
                  (:wrong . agent-session-error)) " / ")
     (agent-runs--percent (plist-get group :verified) rated)
     (agent-runs--duration (plist-get group :duration))
     (agent-runs--tokens (plist-get group :tokens)))))

(defun agent-runs--insert-row (id insert-function)
  "Insert a logical row ID using INSERT-FUNCTION."
  (let ((start (point)))
    (funcall insert-function)
    (insert "\n")
    (put-text-property start (point) 'agent-runs-row id)
    (push (cons id start) agent-runs--rows)))

(defun agent-runs--insert-cells (cells widths)
  "Insert CELLS at pixel positions determined by WIDTHS."
  (let ((offset 0))
    (cl-loop for cell in cells for width in widths for index from 0 do
             (when (> index 0)
               (insert (propertize " " 'display `(space :align-to (,offset)))))
             (insert cell)
             (setq offset (+ offset width)))))

(defun agent-runs--insert-run (key item)
  "Insert ITEM underneath the group identified by KEY."
  (agent-runs--insert-row
   (append key (list (plist-get item :run)))
   (lambda ()
     (let* ((rating (plist-get item :rating))
            (errors (append (plist-get item :errors) nil))
            (outcome (pcase (plist-get item :outcome)
                       ("ok" (propertize "完成" 'face 'agent-session-ok))
                       ("failed" (propertize "失败" 'face 'agent-session-error))
                       (_ (propertize "提前关闭" 'face 'agent-session-dim)))))
       (insert (format "  #%d  %s  @%s  %s  "
                       (plist-get item :run)
                       (format-time-string "%Y-%m-%d %H:%M" (plist-get item :start))
                       (plist-get item :handle)
                       (replace-regexp-in-string "[\n\r]+" " "
                                                 (or (plist-get item :title) "无标题")))
               outcome (if errors (format "（%s）" (string-join errors "、")) "")
               (format "  %s  工具 %d 次  "
                       (agent-runs--duration (plist-get item :duration))
                       (plist-get item :tools))
               (agent-runs--verdict (plist-get rating :verdict)))
       (when rating
         (insert (if (eq (plist-get rating :verified) t) " · 已核实" " · 未核实"))
         (when-let* ((note (plist-get rating :note)))
           (insert "  " (replace-regexp-in-string "[\n\r]+" " " note))))))))

(defun agent-runs--render ()
  "Render the snapshot and restore the logical row at point."
  (let ((selection (agent-runs--selection))
        (inhibit-read-only t)
        (groups (append (plist-get agent-runs--snapshot :groups) nil)))
    (erase-buffer)
    (setq agent-runs--rows nil)
    (insert (propertize "子代理评估" 'face 'agent-runs-heading)
            "  " (agent-runs--range-label)
            (propertize "    ? 帮助\n" 'face 'agent-session-dim))
    (when agent-runs--snapshot
      (let ((total (lambda (key)
                     (apply #'+ (mapcar (lambda (g) (plist-get g key)) groups)))))
        (insert (format "%d 组 · %d 次 · 失败 %d 次 · 提前关闭 %d 次 · 已评 %d 次\n"
                        (length groups) (funcall total :runs) (funcall total :failed)
                        (funcall total :closed) (funcall total :rated)))))
    (insert (propertize "g 刷新 · r 范围 · TAB/RET 展开 · n/p 移动\n\n"
                        'face 'agent-session-dim))
    (cond (agent-runs--error
           (insert (propertize agent-runs--error 'face 'agent-session-error) "\n"))
          (agent-runs--loading (insert "加载中…\n")))
    (if (null groups)
        (when (and agent-runs--snapshot (not agent-runs--loading))
          (insert "此范围内暂无子代理运行记录。\n"))
      (let* ((rows (mapcar #'agent-runs--cells groups))
             (widths (cl-loop for index below (length agent-runs--columns)
                              collect (+ (* 2 (frame-char-width))
                                         (apply #'max
                                                (mapcar (lambda (row)
                                                          (string-pixel-width
                                                           (nth index row)))
                                                        (cons agent-runs--columns rows)))))))
        (agent-runs--insert-cells agent-runs--columns widths)
        (insert "\n")
        (cl-loop for group in groups for cells in rows do
                 (let ((key (agent-runs--group-key group)))
                   (agent-runs--insert-row
                    key (lambda () (agent-runs--insert-cells cells widths)))
                   (when (member key agent-runs--expanded)
                     (seq-doseq (item (plist-get group :items))
                       (agent-runs--insert-run key item)))))))
    (setq agent-runs--rows (nreverse agent-runs--rows))
    (agent-runs--goto selection)))

(defun agent-runs-toggle ()
  "Expand or collapse the group at point."
  (interactive)
  (let* ((selection (agent-runs--selection))
         (key (seq-take selection 3)))
    (unless key (user-error "请先选择运行组"))
    (if (member key agent-runs--expanded)
        (setq agent-runs--expanded (remove key agent-runs--expanded))
      (push key agent-runs--expanded))
    (agent-runs--render)))

(defun agent-runs-next-row (&optional count)
  "Move COUNT logical rows forward."
  (interactive "p")
  (let* ((count (or count 1))
         (positions (mapcar #'cdr agent-runs--rows))
         (choices (if (< count 0)
                      (reverse (seq-filter (lambda (p) (< p (line-beginning-position)))
                                           positions))
                    (seq-filter (lambda (p) (> p (line-beginning-position))) positions))))
    (when (and choices (/= count 0))
      (goto-char (nth (min (1- (abs count)) (1- (length choices))) choices)))))

(defun agent-runs-previous-row (&optional count)
  "Move COUNT logical rows backward."
  (interactive "p")
  (agent-runs-next-row (- (or count 1))))

(defun agent-runs-help ()
  "Show the run page's keyboard commands and metric definitions."
  (interactive)
  (with-help-window "*子代理评估帮助*"
    (princ "子代理评估 · 键盘操作\n\n")
    (princ "g：刷新    r：切换 7 天 / 30 天 / 全部（默认 30 天）\n")
    (princ "TAB / RET：展开或收起    n / p、C-n / C-p：逐行移动\n")
    (princ "q：返回    ?：帮助\n")
    (princ "Evil 普通状态：j / k 移动，g r 刷新。\n\n")
    (princ "失败率为失败次数 / 总次数；提前关闭次数见汇总及失败率提示。\n")
    (princ "可用 / 返工 / 错误按每次运行的最新评分计；已核实为已核实次数 / 已评次数。\n")
    (princ "token 为后端上报的用量：输入含缓存读取及写入 / 输出。仅统计本机记录。\n")))

(defvar-keymap agent-runs-mode-map
  :doc "Keys for the subagent run page."
  "g" #'agent-runs-refresh
  "r" #'agent-runs-cycle-range
  "TAB" #'agent-runs-toggle
  "<tab>" #'agent-runs-toggle
  "RET" #'agent-runs-toggle
  "n" #'agent-runs-next-row
  "p" #'agent-runs-previous-row
  "C-n" #'agent-runs-next-row
  "C-p" #'agent-runs-previous-row
  "q" #'quit-window
  "?" #'agent-runs-help)

(define-derived-mode agent-runs-mode special-mode "子代理评估"
  "Inspect subagent runs grouped by profile and concrete model."
  (setq-local revert-buffer-function #'agent-runs-refresh truncate-lines t)
  (hl-line-mode 1))

;;;###autoload
(defun agent-runs ()
  "Show local subagent runs and ratings."
  (interactive)
  (let ((buffer (get-buffer-create agent-runs--buffer)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-runs-mode) (agent-runs-mode))
      (agent-runs-refresh))
    (pop-to-buffer buffer)))

(provide 'agent-runs)
;;; agent-runs.el ends here
