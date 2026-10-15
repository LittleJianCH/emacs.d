;; Theme picker: vtable rows with RET actions, filter buttons, and a live preview driven by a timer.
;; Shows: page state read at the top and changed from buttons, vtable, a timer
;; that watches point, and agent-canvas-send.
(require 'vtable)
(let* ((page (current-buffer))
       (source (agent-canvas-state 'source "全部"))
       (preview (agent-canvas-state 'preview))
       (original (agent-canvas-state 'original))
       (builtin-p (lambda (theme)
                    (let ((file (locate-file (format "%s-theme" theme)
                                             (custom-theme--load-path) '(".el" ".elc"))))
                      (and file (file-in-directory-p file data-directory)))))
       (themes (seq-filter (lambda (theme)
                             (pcase source
                               ("内置" (funcall builtin-p theme))
                               ("第三方" (not (funcall builtin-p theme)))
                               (_ t)))
                           (custom-available-themes)))
       (use (lambda (themes)
              (mapc #'disable-theme custom-enabled-themes)
              (dolist (theme (reverse themes)) (load-theme theme t))))
       (swatch (lambda (attribute)
                 (let ((color (face-attribute 'default attribute nil t)))
                   (concat (propertize "      " 'face (list :background color))
                           " " color)))))
  (agent-canvas-blocks
   (list (list :type "kv"
               :items (list (list "当前主题"
                                  (format "**%s**" (if custom-enabled-themes
                                                       (mapconcat #'symbol-name custom-enabled-themes ", ")
                                                     "默认")))
                            (list "背景 / 前景"
                                  (concat (funcall swatch :background) "    "
                                          (funcall swatch :foreground)))
                            (list "实时预览"
                                  (if preview "开：移动光标即预览" "关"))))))
  (insert "\n")
  (dolist (choice '("全部" "内置" "第三方"))
    (agent-canvas-button (if (equal choice source) (concat "● " choice) choice)
                         (lambda () (agent-canvas-set 'source choice)))
    (insert " "))
  (insert "\n\n")
  (make-vtable
   :columns '((:name "主题" :min-width 24) (:name "状态" :min-width 10) (:name "来源" :min-width 6))
   :objects themes
   :use-header-line nil
   :getter (lambda (theme column _table)
             (pcase column
               (0 (symbol-name theme))
               (1 (cond ((memq theme custom-enabled-themes) "✓ 使用中")
                        ((memq theme original) "原主题")
                        (t "")))
               (2 (if (funcall builtin-p theme) "内置" "第三方"))))
   :actions (list "RET" (lambda (theme)
                          (funcall use (list theme))
                          (with-current-buffer page
                            (agent-canvas-set 'original nil t)
                            (agent-canvas-set 'preview nil)))))
  ;; make-vtable leaves point at the start of the table.
  (goto-char (point-max))
  (insert "\n")
  (if preview
      (progn
        (agent-canvas-button "确认当前主题"
                             (lambda ()
                               (agent-canvas-set 'original nil t)
                               (agent-canvas-set 'preview nil)))
        (insert "  ")
        (agent-canvas-button "恢复原主题"
                             (lambda ()
                               (funcall use original)
                               (agent-canvas-set 'original nil t)
                               (agent-canvas-set 'preview nil)))
        ;; Preview the theme on the row at point whenever that row changes.
        (agent-canvas-timer
         0.4
         (lambda ()
           (let* ((window (get-buffer-window page t))
                  (theme (and window
                              (save-excursion
                                (goto-char (window-point window))
                                (vtable-current-object)))))
             (when (and theme (not (eq theme (agent-canvas-state 'previewed))))
               (agent-canvas-set 'previewed theme t)
               (funcall use (list theme)))))))
    (agent-canvas-button "开启实时预览"
                         (lambda ()
                           (agent-canvas-set 'original custom-enabled-themes t)
                           (agent-canvas-set 'previewed (car custom-enabled-themes) t)
                           (agent-canvas-set 'preview t))
                         "移动光标即切换主题，可以随时恢复"))
  (insert "  ")
  (agent-canvas-button "让 agent 写进配置"
                       (lambda ()
                         (agent-canvas-send
                          (format "把主题 %s 设为默认主题，写进配置"
                                  (car custom-enabled-themes)))))
  (insert "\n"))
