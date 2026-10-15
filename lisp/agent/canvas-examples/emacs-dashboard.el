;; Emacs dashboard: live stats refreshed by a timer, a filtered vtable of buffers, and a chart.
;; Shows: agent-canvas-timer with agent-canvas-refresh, filter state, vtable
;; followed by more blocks, and agent-canvas-blocks for kv and chart.
(require 'vtable)
(let* ((filter (agent-canvas-state 'filter "全部"))
       (all (buffer-list))
       (human (lambda (n)
                (cond ((>= n 1000000) (format "%.1fM" (/ n 1000000.0)))
                      ((>= n 1000) (format "%.1fk" (/ n 1000.0)))
                      (t (number-to-string n)))))
       (mode-of (lambda (b) (format "%s" (buffer-local-value 'major-mode b))))
       (category (lambda (b)
                   (cond ((agent-session-buffer-p b) "agent")
                         ((buffer-file-name b) "文件")
                         (t "其他"))))
       (shown (seq-filter (lambda (b)
                            (or (equal filter "全部")
                                (equal filter (funcall category b))))
                          all)))
  (agent-canvas-blocks
   (list (list :type "kv"
               :items (list (list "Emacs 版本" (format "**%s**" emacs-version))
                            (list "启动时长" (emacs-uptime))
                            (list "Buffer 数量" (format "**%d** 个（筛选「%s」：%d 个）"
                                                        (length all) filter (length shown)))
                            (list "GC" (format "**%d** 次，共 **%.2f** 秒"
                                               gcs-done gc-elapsed))))))
  (insert "\n")
  (dolist (choice '("全部" "文件" "agent" "其他"))
    (agent-canvas-button (if (equal choice filter) (concat "● " choice) choice)
                         (lambda () (agent-canvas-set 'filter choice))
                         (format "只看「%s」的 buffer" choice))
    (insert "  "))
  (insert "\n\n")
  ;; The 15 largest buffers; RET shows one in another window.
  (make-vtable
   :columns (list (list :name "Buffer" :min-width 28)
                  (list :name "Major mode" :min-width 18)
                  (list :name "大小" :min-width 8)
                  (list :name "已修改" :min-width 8))
   :objects (seq-take (sort (copy-sequence shown)
                            (lambda (a b) (> (buffer-size a) (buffer-size b))))
                      15)
   :use-header-line nil
   :getter (lambda (b column _table)
             (pcase column
               (0 (buffer-name b))
               (1 (funcall mode-of b))
               (2 (funcall human (buffer-size b)))
               (3 (if (buffer-modified-p b) (propertize "●" 'face 'warning) ""))))
   :actions (list "RET" (lambda (b)
                          (select-window
                           (display-buffer b '(display-buffer-reuse-window
                                               display-buffer-pop-up-window
                                               display-buffer-use-some-window))))))
  ;; make-vtable leaves point at the start of the table.
  (goto-char (point-max))
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (b shown)
      (cl-incf (gethash (funcall mode-of b) counts 0)))
    (let ((top (seq-take (sort (hash-table-keys counts)
                               (lambda (a b) (> (gethash a counts) (gethash b counts))))
                         8)))
      (insert "\n")
      (agent-canvas-blocks
       (list (list :type "chart" :kind "hbar"
                   :title (format "各 major mode 的 buffer 数（筛选「%s」，前 8）" filter)
                   :labels (vconcat top)
                   :series (list (list :name "buffer 数"
                                       :values (vconcat (mapcar (lambda (m) (gethash m counts))
                                                                top)))))))))
  (insert "\n")
  (agent-canvas-button "问问 agent"
                       (lambda ()
                         (agent-canvas-send
                          (format "当前筛选是「%s」：该筛选下 %d 个 buffer，全部 buffer 共 %d 个。请说说这些 buffer 的情况。"
                                  filter (length shown) (length all)))))
  (insert "\n")
  ;; Redraw every 2 seconds while the page is visible.
  (agent-canvas-timer 2 #'agent-canvas-refresh))
