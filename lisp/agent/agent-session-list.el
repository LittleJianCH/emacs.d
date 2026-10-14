;;; agent-session-list.el --- 会话列表侧边栏 -*- lexical-binding: t; -*-

;;; Commentary:

;; 左侧的会话列表（参考 T3 Code 的 thread sidebar）：
;;   进行中  所有打开的会话：状态（工作中 / 等待确认 / 完成 / 空闲）、agent、标题
;;   历史    当前项目中各 agent 的历史会话（Claude 与 Codex），可直接恢复
;;
;; 按键：RET 打开 / 恢复，c 新建，k 结束会话，g 刷新，n / p 上下移动，q 关闭。

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'agent-session)

(defgroup agent-session-list nil
  "agent 会话列表。"
  :group 'agent-session
  :prefix "agent-session-list-")

(defcustom agent-session-list-width 40
  "会话列表侧边栏的宽度。"
  :type 'integer)

(defconst agent-session-list--buffer-name "*agent-sessions*")

(defvar agent-session-list--history (make-hash-table :test #'equal)
  "历史会话缓存：(ROOT . AGENT) → 列表。")

(defvar-local agent-session-list--root nil "列表当前对应的项目根目录。")

(defvar agent-session-list--timer nil "定时刷新（更新“工作中”的计时）。")

;;; 数据

(defun agent-session-list--fetch (root)
  "异步获取 ROOT 中各 agent 的历史会话，到达后重绘。"
  (dolist (entry agent-session-agents)
    (let ((agent (car entry)))
      (agent-session-backend-history
       (plist-get (cdr entry) :backend) root
       (lambda (items)
         (puthash (cons root agent) items agent-session-list--history)
         (agent-session-list--refresh-soon))))))

(defun agent-session-list--history-items (root)
  "ROOT 中尚未打开的历史会话，按时间倒序：((AGENT . ITEM) ...)。"
  (let ((open (delq nil (mapcar (lambda (b) (agent-session-resume-id
                                             (buffer-local-value 'agent-session--current b)))
                                (agent-session-buffers))))
        result)
    (dolist (entry agent-session-agents)
      (dolist (item (gethash (cons root (car entry)) agent-session-list--history))
        (unless (member (plist-get item :id) open)
          (push (cons (car entry) item) result))))
    (sort result :key (lambda (x) (- (or (plist-get (cdr x) :time) 0))))))

(defun agent-session-list--ago (time)
  "TIME（秒）距今的简短描述。"
  (let ((seconds (- (float-time) time)))
    (cond ((< seconds 60) "刚刚")
          ((< seconds 3600) (format "%d分钟前" (/ seconds 60)))
          ((< seconds 86400) (format "%d小时前" (/ seconds 3600)))
          ((< seconds (* 7 86400)) (format "%d天前" (/ seconds 86400)))
          (t (format-time-string "%m-%d" time)))))

;;; 渲染

(defface agent-session-list-heading '((t :inherit (bold shadow)))
  "分组标题。")

(defface agent-session-list-title '((t :inherit bold))
  "进行中的会话标题。")

(defun agent-session-list--project-name (root)
  "ROOT 的项目名。"
  (file-name-nondirectory (directory-file-name root)))

(defun agent-session-list-mouse-open (event)
  "鼠标点击会话条目：点在按钮（如 ×）上时执行按钮，否则打开该会话。"
  (interactive "e")
  (let* ((posn (event-start event))
         (pos (posn-point posn)))
    (select-window (posn-window posn))
    (goto-char pos)
    (if (button-at pos)
        (push-button pos)
      (agent-session-list-open))))

(defvar-keymap agent-session-list-entry-map
  :doc "会话条目上的鼠标操作（键盘按键仍由 `agent-session-list-mode-map' 处理）。"
  "<mouse-1>" #'agent-session-list-mouse-open
  "<mouse-2>" #'agent-session-list-mouse-open)

(defun agent-session-list--insert-entry (entry &rest strings)
  "插入一项，整段带上 ENTRY 属性；鼠标悬停高亮，单击打开。"
  (let ((start (point)))
    (apply #'insert strings)
    ;; 每行末尾补一个伸到窗口右边缘的空白，悬停高亮占满整行；
    ;; 换行符本身不高亮（见下），否则行尾会多出一小块。
    (save-excursion
      (let ((end (point-marker)))
        (goto-char start)
        (while (search-forward "\n" end t)
          (backward-char)
          (insert (propertize " " 'display '(space :align-to right)))
          (forward-char))
        (set-marker end nil)))
    ;; Emacs 把相邻且 mouse-face 相同（eq）的文字当成一片一起高亮，
    ;; 每项用新建的列表，悬停时只高亮这一项。
    (add-text-properties start (point)
                         (list 'agent-session-entry entry
                               'mouse-face (list 'highlight)
                               'keymap agent-session-list-entry-map))
    (save-excursion
      (let ((end (point)))
        (goto-char start)
        (while (search-forward "\n" end t)
          (remove-text-properties (1- (point)) (point) '(mouse-face nil)))))
    ;; “点击打开”的提示只加在非按钮部分，不覆盖 × 自己的提示。
    (let ((pos start))
      (while (< pos (point))
        (let ((next (next-single-property-change pos 'button nil (point))))
          (unless (get-text-property pos 'button)
            (put-text-property pos next 'help-echo "点击打开"))
          (setq pos next))))))

(defun agent-session-list--kill-button (buffer)
  "结束会话 BUFFER 的 × 按钮。"
  (make-text-button " ×" nil 'face 'agent-session-dim 'follow-link t
                    'help-echo "结束这个会话"
                    'action (lambda (_)
                              (when (yes-or-no-p (format "结束 %s？" (buffer-name buffer)))
                                (kill-buffer buffer)
                                (agent-session-list--refresh)))))

(defun agent-session-list--truncate (string)
  "按窗口宽度截断 STRING。"
  (truncate-string-to-width string (max 10 (- (window-body-width) 4)) nil nil "…"))

(defun agent-session-list--render ()
  "重绘当前 buffer 的会话列表，尽量保持光标所在的条目。"
  (let* ((inhibit-read-only t)
         (current (get-text-property (point) 'agent-session-entry))
         (root agent-session-list--root)
         (live (agent-session-buffers))
         (history (agent-session-list--history-items root)))
    (erase-buffer)
    (insert (propertize "进行中\n" 'face 'agent-session-list-heading))
    (if (null live)
        (insert (propertize "  还没有会话，按 c 新建\n" 'face 'agent-session-dim))
      (dolist (buffer live)
        (let* ((session (buffer-local-value 'agent-session--current buffer))
               (project (agent-session-list--project-name (agent-session-root session))))
          (agent-session-list--insert-entry
           (list :buffer buffer)
           "  " (agent-session-status-label session)
           (propertize (format "  %s · %s" (agent-session-title session) project)
                       'face 'agent-session-dim)
           (agent-session-list--kill-button buffer)
           "\n    "
           (propertize (agent-session-list--truncate (agent-session-display-title session))
                       'face 'agent-session-list-title)
           "\n"))))
    (insert "\n" (propertize (format "历史 · %s\n" (agent-session-list--project-name root))
                             'face 'agent-session-list-heading))
    (if (null history)
        (insert (propertize "  （没有历史会话）\n" 'face 'agent-session-dim))
      (pcase-dolist (`(,agent . ,item) history)
        (agent-session-list--insert-entry
         (list :agent agent :id (plist-get item :id) :root root :title (plist-get item :title))
         "  "
         (propertize (format "%-7s %-5s " (agent-session-list--ago (plist-get item :time))
                             (or (agent-session--get agent :title) agent))
                     'face 'agent-session-dim)
         (agent-session-list--truncate (plist-get item :title))
         "\n")))
    ;; 回到原来的条目
    (goto-char (point-min))
    (when current
      (let ((pos (point-min)))
        (while (and pos (not (equal (get-text-property pos 'agent-session-entry) current)))
          (setq pos (next-single-property-change pos 'agent-session-entry)))
        (when pos (goto-char pos))))
    (unless (get-text-property (point) 'agent-session-entry)
      (agent-session-list-next))))

(defvar agent-session-list--pending nil "已安排的重绘计时器。")

(defun agent-session-list--refresh-soon ()
  "稍后重绘会话列表；流式输出时状态频繁变化，合并为一次。"
  (unless (timerp agent-session-list--pending)
    (setq agent-session-list--pending
          ;; 用普通计时器而不是空闲计时器：Emacs 已空闲时新建的空闲计时器会立即触发。
          (run-with-timer 0.3 nil (lambda ()
                                    (setq agent-session-list--pending nil)
                                    (agent-session-list--refresh))))))

(defun agent-session-list--refresh ()
  "会话列表打开时重绘。"
  (when-let* ((buffer (get-buffer agent-session-list--buffer-name)))
    (with-current-buffer buffer
      (if-let* ((window (get-buffer-window buffer t)))
          (with-selected-window window (agent-session-list--render))
        (agent-session-list--render)))))

;;; 命令

(defun agent-session-list--entry ()
  "光标所在的条目。"
  (or (get-text-property (point) 'agent-session-entry)
      (user-error "光标不在会话上")))

(defun agent-session-list-open ()
  "打开光标所在的会话；历史会话则恢复它。"
  (interactive)
  (let ((entry (agent-session-list--entry)))
    (if-let* ((buffer (plist-get entry :buffer)))
        (select-window (agent-session-display buffer))
      (let ((buffer (agent-session-start (plist-get entry :agent) nil (plist-get entry :id)
                                         (plist-get entry :root))))
        (when (bufferp buffer)
          (let ((session (buffer-local-value 'agent-session--current buffer)))
            (setf (agent-session-info session)
                  (plist-put (agent-session-info session) :title (plist-get entry :title)))
            (agent-session--refresh session)))))))

(defun agent-session-list-create (&optional choose)
  "在列表对应的项目中新建会话；CHOOSE（前缀参数）时先选择 agent。"
  (interactive "P")
  (let ((default-directory agent-session-list--root))
    (select-window (or (get-buffer-window (agent-session-create choose)) (selected-window)))))

(defun agent-session-list-kill ()
  "结束光标所在的会话。"
  (interactive)
  (let ((buffer (or (plist-get (agent-session-list--entry) :buffer)
                    (user-error "历史会话无需结束"))))
    (when (yes-or-no-p (format "结束 %s？" (buffer-name buffer)))
      (kill-buffer buffer)
      (agent-session-list--refresh))))

(defun agent-session-list-refresh ()
  "重新获取历史会话并重绘。"
  (interactive)
  (agent-session-list--fetch agent-session-list--root)
  (agent-session-list--render))

(defun agent-session-list-next ()
  "移到下一个会话。"
  (interactive)
  (let ((pos (point)))
    (when (get-text-property pos 'agent-session-entry)
      (setq pos (next-single-property-change pos 'agent-session-entry nil (point-max))))
    (setq pos (text-property-not-all pos (point-max) 'agent-session-entry nil))
    (when pos (goto-char pos))))

(defun agent-session-list--entry-start (pos)
  "POS 所在条目的起点。"
  (let ((entry (get-text-property pos 'agent-session-entry)))
    (while (and (> pos (point-min))
                (equal (get-text-property (1- pos) 'agent-session-entry) entry))
      (setq pos (1- pos)))
    pos))

(defun agent-session-list-previous ()
  "移到上一个会话。"
  (interactive)
  (let ((pos (1- (agent-session-list--entry-start (point)))))
    (while (and (> pos (point-min)) (not (get-text-property pos 'agent-session-entry)))
      (setq pos (1- pos)))
    (when (get-text-property pos 'agent-session-entry)
      (goto-char (agent-session-list--entry-start pos)))))

(defvar-keymap agent-session-list-mode-map
  :doc "会话列表的按键。"
  "RET" #'agent-session-list-open
  "c" #'agent-session-list-create
  "k" #'agent-session-list-kill
  "g" #'agent-session-list-refresh
  "n" #'agent-session-list-next
  "p" #'agent-session-list-previous)

(defun agent-session-list--header-button (label command help)
  "标题栏上可点击的按钮：点击时在会话列表窗口中执行 COMMAND。"
  (propertize label
              'face 'agent-session-assistant
              'mouse-face 'header-line-highlight
              'help-echo help
              'local-map (let ((map (make-sparse-keymap)))
                           (define-key map [header-line mouse-1]
                                       (lambda (event)
                                         (interactive "e")
                                         (with-selected-window (posn-window (event-start event))
                                           (call-interactively command))))
                           map)))

(define-derived-mode agent-session-list-mode special-mode "Sessions"
  "agent 会话列表。"
  (setq-local truncate-lines t
              cursor-type 'bar
              revert-buffer-function (lambda (&rest _) (agent-session-list-refresh))
              header-line-format
              '(:eval (concat " 会话  "
                              (agent-session-list--header-button "[+ 新建]" #'agent-session-list-create
                                                                 "新建会话（c）")
                              " "
                              (agent-session-list--header-button "[刷新]" #'agent-session-list-refresh
                                                                 "重新获取历史会话（g）")
                              (propertize "  单击打开 · RET 打开 · k 结束"
                                          'face 'agent-session-dim))))
  (hl-line-mode 1))

;;;###autoload
(defun agent-session-list ()
  "在左侧打开会话列表：进行中的会话与当前项目的历史会话。"
  (interactive)
  (let* ((root (if-let* ((session agent-session--current))
                   (agent-session-root session)
                 (agent-session--root)))
         (buffer (get-buffer-create agent-session-list--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-session-list-mode) (agent-session-list-mode))
      (setq agent-session-list--root root))
    (setq agent-session--list-refresh-function #'agent-session-list--refresh-soon)
    (let ((window (display-buffer-in-side-window
                   buffer `((side . left) (slot . 0)
                            (window-width . ,agent-session-list-width)
                            (preserve-size . (t . nil))
                            (window-parameters . ((no-delete-other-windows . t)))))))
      (select-window window)
      (agent-session-list--render)
      (agent-session-list--fetch root))
    (unless (timerp agent-session-list--timer)
      (setq agent-session-list--timer
            (run-with-timer 10 10 (lambda ()
                                    (when (and (get-buffer-window agent-session-list--buffer-name t)
                                               (seq-some (lambda (b)
                                                           (eq (agent-session-status
                                                                (buffer-local-value
                                                                 'agent-session--current b))
                                                               'running))
                                                         (agent-session-buffers)))
                                      (agent-session-list--refresh))))))))

(provide 'agent-session-list)
;;; agent-session-list.el ends here
