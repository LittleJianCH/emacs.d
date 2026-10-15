;; Command bench: time shell commands in background processes and compare them across runs.
;; Shows: slow work started from a button with make-process and a sentinel,
;; progress drawn while running, results and history kept in page state.
;; Change `commands' and `runs' for your own comparison.
(let* ((page (current-buffer))
       (commands '(("ls -R" . "ls -laR /usr/bin > /dev/null")
                   ("shell loop" . "i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done")))
       (runs 10)
       (results (agent-canvas-state 'results))   ; ((NAME SECONDS ...) ...)
       (progress (agent-canvas-state 'progress)) ; (DONE . TOTAL) while running
       (history (agent-canvas-state 'history))   ; ((TIME MEAN-MS ...) ...), one MEAN per command
       (mean (lambda (xs) (/ (apply #'+ xs) (length xs))))
       (ms (lambda (seconds) (format "%.1f" (* 1000 seconds))))
       (start
        (lambda ()
          (let ((queue (apply #'append (make-list runs commands)))
                (total (* runs (length commands)))
                (times nil)
                (failed nil)
                next)
            ;; Run the queue one process at a time; each sentinel starts the next.
            (setq next
                  (lambda ()
                    (when (buffer-live-p page)
                      (with-current-buffer page
                        (if (null queue)
                            (let ((times (mapcar (lambda (c)
                                                   (cons (car c) (alist-get (car c) times nil nil #'equal)))
                                                 commands)))
                              (agent-canvas-set 'history
                                                (append (agent-canvas-state 'history)
                                                        (list (cons (format-time-string "%H:%M:%S")
                                                                    (mapcar (lambda (c)
                                                                              (* 1000 (funcall mean (cdr c))))
                                                                            times))))
                                                t)
                              (agent-canvas-set 'failed failed t)
                              (agent-canvas-set 'results times t)
                              (agent-canvas-set 'progress nil))
                          (let ((command (pop queue))
                                (begin (current-time)))
                            (agent-canvas-set 'progress (cons (- total (length queue) 1) total) t)
                            (make-process
                             :name "command-bench" :noquery t :connection-type 'pipe
                             :command (list shell-file-name shell-command-switch (cdr command))
                             :sentinel (lambda (proc _event)
                                         (unless (process-live-p proc)
                                           (unless (zerop (process-exit-status proc))
                                             (cl-pushnew (car command) failed :test #'equal))
                                           (push (float-time (time-since begin))
                                                 (alist-get (car command) times nil nil #'equal))
                                           (funcall next))))))))))
            (agent-canvas-set 'progress (cons 0 total))
            (funcall next)))))
  (agent-canvas-blocks
   (list (list :type "table"
               :columns ["命令" "内容"]
               :rows (mapcar (lambda (c) (list (car c) (propertize (cdr c) 'face 'agent-canvas-code)))
                             commands)
               :caption (format "每个命令跑 %d 次，交替进行" runs))))
  (insert "\n")
  (cond
   (progress
    (agent-canvas-blocks
     (list (list :type "progress" :label "测量中" :value (car progress) :max (cdr progress))))
    (agent-canvas-timer 0.5 #'agent-canvas-refresh))
   (t
    (agent-canvas-button (if results "重新测量" "开始测量") start
                         "在后台逐个运行，不会阻塞 Emacs")
    (when history
      (insert "  ")
      (agent-canvas-button "清空历史"
                           (lambda ()
                             (agent-canvas-set 'history nil t)
                             (agent-canvas-set 'results nil))))
    (insert "\n")))
  (when-let* ((failed (agent-canvas-state 'failed)))
    (insert (propertize (format "⚠ 有命令返回了非零状态：%s\n" (string-join failed "、"))
                        'face 'warning)))
  (when results
    (let ((fastest (apply #'min (mapcar (lambda (r) (funcall mean (cdr r))) results))))
      (insert "\n")
      (agent-canvas-blocks
       (list (list :type "table"
                   :columns ["命令" "平均 ms" "最快 ms" "最慢 ms" "相对最快"]
                   :rows (mapcar (lambda (r)
                                   (let ((avg (funcall mean (cdr r))))
                                     (list (car r) (funcall ms avg)
                                           (funcall ms (apply #'min (cdr r)))
                                           (funcall ms (apply #'max (cdr r)))
                                           (propertize (format "%.2fx" (/ avg fastest))
                                                       'face (if (> avg (* 1.1 fastest)) 'error 'success)))))
                                 results))
             (list :type "chart" :kind "hbar" :title "平均耗时 ms"
                   :labels (vconcat (mapcar #'car results))
                   :series (vector (list :name "平均"
                                         :values (vconcat (mapcar (lambda (r)
                                                                    (* 1000 (funcall mean (cdr r))))
                                                                  results)))))))))
  (when (cdr history)
    (insert "\n")
    (agent-canvas-blocks
     (list (list :type "chart" :kind "line" :title "历次测量：平均耗时 ms" :height 180
                 :labels (vconcat (mapcar #'car history))
                 :series (vconcat
                          (seq-map-indexed (lambda (c i)
                                             (list :name (car c)
                                                   :values (vconcat (mapcar (lambda (h) (nth (1+ i) h))
                                                                            history))))
                                           commands)))))))
