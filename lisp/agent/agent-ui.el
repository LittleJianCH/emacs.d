;;; agent-ui.el --- agent 操作 Emacs 的接口 -*- lexical-binding: t; -*-

;;; Commentary:

;; agent 通过 bin/emx（命令行或 MCP）调用这里注册的方法。
;;
;; 调用协议：emx 把 {"method": ..., "params": {...}} 写入请求文件，
;; 执行 emacsclient --eval '(agent-ui-rpc REQ RES)'，再从响应文件读取
;; {"ok": true, "result": ...} 或 {"ok": false, "error": "..."}。
;; 走文件而不是命令行参数，HTML / 代码等任意内容都无需转义。
;;
;; 扩展：用 `agent-ui-defmethod' 定义新方法，MCP 工具列表会自动包含它。

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'flymake)
(require 'project)
(require 'agent-session)


(defgroup agent-ui nil
  "agent 操作 Emacs 的接口。"
  :group 'tools
  :prefix "agent-ui-")

(defcustom agent-ui-max-text 200000
  "读取 buffer 文本时返回的最大字符数。"
  :type 'integer)

;;; 方法注册

(defvar agent-ui-caller nil
  "当前调用方信息，例如 (:agent_buffer \"*agent:claude@proj*\")。
emx 根据所在 agent 会话的环境变量自动填写，方法内可直接读取。")

(defvar agent-ui--methods nil
  "已注册方法：((NAME . (:function F :description D :params SPEC)) ...)。")

(defmacro agent-ui-defmethod (name params docstring &rest body)
  "定义 agent 可调用的方法 NAME（字符串）。
PARAMS 每项为 (SYMBOL TYPE DESCRIPTION [required])，TYPE 为 JSON Schema
类型符号：string、integer、boolean、array（对象数组）、object。BODY 中可直接使用与参数同名的变量，
返回值（plist / vector / 字符串 / 数字）会序列化为 JSON。"
  (declare (indent 2) (doc-string 3))
  (let ((fn (intern (format "agent-ui--method-%s" name)))
        (vars (mapcar #'car params)))
    `(progn
       (defun ,fn (params)
         ,docstring
         (let ,(mapcar (lambda (var)
                         `(,var (plist-get params ,(intern (format ":%s" var)))))
                       vars)
           (ignore params ,@vars)
           ,@body))
       (setf (alist-get ,name agent-ui--methods nil nil #'equal)
             (list :function #',fn :description ,docstring :params ',params))
       ,name)))

(defun agent-ui--coerce (params spec)
  "按 SPEC 把 PARAMS 中的字符串转换成声明的类型（命令行传入的都是字符串）。"
  (dolist (entry spec params)
    (let* ((key (intern (format ":%s" (car entry))))
           (value (plist-get params key)))
      (when (stringp value)
        (pcase (nth 1 entry)
          ('integer (setq params (plist-put params key (string-to-number value))))
          ('boolean (setq params (plist-put params key
                                             (member value '("true" "1" "yes"))))))))))

(defun agent-ui--check-required (name params spec)
  "缺少 SPEC 中必填参数时报错。"
  (dolist (entry spec)
    (when (and (memq 'required entry)
               (null (plist-get params (intern (format ":%s" (car entry))))))
      (error "%s: missing required parameter %s" name (car entry)))))

(defun agent-ui--schema (spec)
  "把参数 SPEC 转为 JSON Schema。"
  (let (properties required)
    (dolist (entry spec)
      (setq properties
            (plist-put properties (intern (format ":%s" (car entry)))
                       (append (pcase (nth 1 entry)
                                 ('array (list :type "array" :items (list :type "object")))
                                 (type (list :type (symbol-name type))))
                               (list :description (nth 2 entry)))))
      (when (memq 'required entry)
        (push (symbol-name (car entry)) required)))
    (list :type "object"
          :properties (or properties (make-hash-table))
          :required (vconcat (nreverse required)))))

(defun agent-ui--json-value (value)
  "把 nil 转为 JSON null，其余原样返回。"
  (if (null value) :null value))

;;;###autoload
(defun agent-ui-rpc (request-file response-file)
  "执行 REQUEST-FILE 中的调用，把结果写入 RESPONSE-FILE。供 emx 使用。"
  (let ((response
         (condition-case err
             (let* ((request (with-temp-buffer
                               (let ((coding-system-for-read 'utf-8))
                                 (insert-file-contents request-file))
                               (json-parse-buffer :object-type 'plist
                                                  :null-object nil
                                                  :false-object nil)))
                    (method (plist-get request :method))
                    (entry (or (alist-get method agent-ui--methods nil nil #'equal)
                               (error "Unknown method: %s" method)))
                    (spec (plist-get entry :params))
                    (params (agent-ui--coerce (plist-get request :params) spec))
                    (agent-ui-caller (plist-get request :context)))
               (agent-ui--check-required method params spec)
               (list :ok t
                     :result (agent-ui--json-value
                              (funcall (plist-get entry :function) params))))
           (error (list :ok :false :error (error-message-string err))))))
    (with-temp-buffer
      (condition-case err
          (json-insert response :null-object :null :false-object :false)
        (error
         (erase-buffer)
         (json-insert (list :ok :false
                            :error (format "Result cannot be serialized as JSON: %S" err)))))
      (let ((coding-system-for-write 'utf-8))
        (write-region nil nil response-file nil 'silent)))
    t))

;;; 窗口

(defun agent-ui--frame ()
  "agent 操作的目标框架：优先可见的图形界面框架。"
  (or (seq-find (lambda (frame) (and (frame-visible-p frame) (display-graphic-p frame)))
                (cons (selected-frame) (frame-list)))
      (selected-frame)))

(defun agent-ui--main-window ()
  "用户的工作窗口：最近使用的非 agent 窗口；没有时在 agent 列左侧新开。"
  (let* ((frame (agent-ui--frame))
         (windows (seq-remove (lambda (window)
                                (or (agent-session-buffer-p (window-buffer window))
                                    (window-parameter window 'window-side)
                                    (window-dedicated-p window)))
                              (window-list frame 'no-minibuf))))
    (or (car (sort windows :key #'window-use-time :reverse t))
        (split-window (frame-root-window frame) nil 'left))))

(defun agent-ui--show-buffer (buffer)
  "在工作窗口显示 BUFFER，不抢焦点，返回该窗口。"
  (let ((window (agent-ui--main-window)))
    (with-selected-window window
      (switch-to-buffer buffer nil t))
    window))

(defun agent-ui--view-buffer (title)
  "名为 TITLE 的内容展示 buffer，已存在时清空复用。"
  (let ((buffer (get-buffer-create (format "*agent-view: %s*" (or title "agent")))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (when (bound-and-true-p view-mode) (view-mode -1))
        (erase-buffer)))
    buffer))

(defun agent-ui--abs (path)
  "PATH 的绝对路径；文件不存在时报错。"
  (let ((file (expand-file-name path)))
    (unless (file-exists-p file) (error "No such file: %s" file))
    file))

;;; 方法：查看用户上下文

(defun agent-ui--window-info (window)
  "WINDOW 的可序列化描述。"
  (with-current-buffer (window-buffer window)
    (list :buffer (buffer-name)
          :file (agent-ui--json-value buffer-file-name)
          :mode (symbol-name major-mode)
          :first_line (line-number-at-pos (window-start window))
          :last_line (line-number-at-pos (max (window-start window)
                                              (1- (window-end window t)))))))

(agent-ui-defmethod "context" ()
  "Return what the user is looking at: the file in the main window, cursor line and column,
selected text, project root, and every visible window."
  (let* ((window (agent-ui--main-window))
         (buffer (window-buffer window)))
    (with-current-buffer buffer
      (let ((point (window-point window)))
        (append
         (agent-ui--window-info window)
         (list :line (line-number-at-pos point)
               :column (save-excursion (goto-char point) (current-column))
               :selection (agent-ui--json-value
                           (and (region-active-p)
                                (buffer-substring-no-properties (region-beginning)
                                                                (region-end))))
               :project (agent-ui--json-value
                         (when-let* ((project (project-current)))
                           (expand-file-name (project-root project))))
               :visible (vconcat (mapcar #'agent-ui--window-info
                                         (window-list (agent-ui--frame) 'no-minibuf)))))))))

(agent-ui-defmethod "buffers" ()
  "List open buffers: name, file, whether there are unsaved changes, and major mode."
  (vconcat
   (seq-keep (lambda (buffer)
               (let ((name (buffer-name buffer)))
                 (unless (string-prefix-p " " name)
                   (with-current-buffer buffer
                     (list :name name
                           :file (agent-ui--json-value buffer-file-name)
                           :modified (if (and buffer-file-name (buffer-modified-p)) t :false)
                           :mode (symbol-name major-mode))))))
             (buffer-list))))

(agent-ui-defmethod "read_buffer"
    ((name string "Buffer name, e.g. *compilation*" required)
     (start_line integer "First line (inclusive), default 1")
     (end_line integer "Last line (inclusive), default end of buffer"))
  "Read buffer text: unsaved changes, compilation output, REPLs and other non-file content."
  (with-current-buffer (or (get-buffer name) (error "No buffer named %s" name))
    (save-excursion
      (save-restriction
        (widen)
        (let* ((start (progn (goto-char (point-min))
                             (forward-line (1- (or start_line 1)))
                             (point)))
               (end (if end_line
                        (progn (goto-char (point-min)) (forward-line end_line) (point))
                      (point-max)))
               (text (buffer-substring-no-properties start (max start end))))
          (if (> (length text) agent-ui-max-text)
              (concat (substring text 0 agent-ui-max-text) "\n… (truncated)")
            text))))))

(defun agent-ui--severity (type)
  "flymake 诊断类型 TYPE 的简短名称。"
  (pcase (flymake--lookup-type-property type 'flymake-category)
    ('flymake-error "error")
    ('flymake-warning "warning")
    (_ "note")))

(agent-ui-defmethod "diagnostics"
    ((path string "File path; defaults to the user's current file"))
  "Return flymake / LSP diagnostics for a file (line, column, severity, message)."
  (let ((buffer (if path
                    (find-file-noselect (agent-ui--abs path))
                  (window-buffer (agent-ui--main-window)))))
    (with-current-buffer buffer
      (vconcat
       (mapcar (lambda (diag)
                 (let ((beg (flymake-diagnostic-beg diag)))
                   (list :line (line-number-at-pos beg)
                         :column (save-excursion (goto-char beg) (current-column))
                         :severity (agent-ui--severity (flymake-diagnostic-type diag))
                         :message (flymake-diagnostic-text diag))))
               (sort (flymake-diagnostics) :key #'flymake-diagnostic-beg))))))

;;; 方法：操作编辑器

(agent-ui-defmethod "open"
    ((path string "File path" required)
     (line integer "Line to jump to")
     (end_line integer "Last line of the highlighted range")
     (column integer "Column"))
  "Open a file in the user's main window, jump to a position and highlight the lines,
to guide the user to a piece of code."
  (let* ((buffer (find-file-noselect (agent-ui--abs path)))
         (window (agent-ui--show-buffer buffer)))
    (with-selected-window window
      (when line
        (goto-char (point-min))
        (forward-line (1- line))
        (when column (move-to-column column))
        (recenter)
        (let ((start (line-beginning-position))
              (end (save-excursion
                     (forward-line (- (or end_line line) line))
                     (line-end-position))))
          (pulse-momentary-highlight-region start end))))
    (list :buffer (buffer-name buffer))))

(defun agent-ui--setup-view (format)
  "按 FORMAT 设置当前展示 buffer 的模式。"
  (pcase format
    ("org" (org-mode))
    ((or "markdown" "md")
     (require 'markdown-mode)
     (gfm-view-mode))
    ("diff" (diff-mode))
    ((or "text" "" 'nil) (text-mode))
    (_ (let ((ts (intern (format "%s-ts-mode" format)))
             (plain (intern (format "%s-mode" format))))
         (cond ((fboundp ts) (funcall ts))
               ((fboundp plain) (funcall plain))
               (t (text-mode)))))))

(agent-ui-defmethod "show"
    ((content string "Text to display")
     (path string "Read the content from this file instead of content")
     (format string "org / markdown / diff / text, or a language name such as rust or json")
     (title string "Title of the view buffer; the same title reuses the same buffer"))
  "Show read-only content in the user's main window: reports, plans, org tables, diffs,
code snippets and so on."
  (unless (or content path) (error "Either content or path is required"))
  (let ((buffer (agent-ui--view-buffer title)))
    (with-current-buffer buffer
      (if content
          (insert content)
        (insert-file-contents (agent-ui--abs path))
        (setq default-directory (file-name-directory (agent-ui--abs path))))
      (goto-char (point-min))
      (agent-ui--setup-view (or format
                                (and path (file-name-extension path))
                                "text"))
      (view-mode 1))
    (agent-ui--show-buffer buffer)
    (list :buffer (buffer-name buffer))))

;;; 方法：通用

(agent-ui-defmethod "notify"
    ((message string "Notification text" required)
     (title string "Title, default Agent"))
  "Notify the user in the echo area; also sends a system notification when Emacs is not
in the foreground."
  (let ((title (or title "Agent")))
    (message "[%s] %s" title message)
    (when (and (eq system-type 'darwin)
               (not (eq (frame-focus-state (agent-ui--frame)) t)))
      (call-process "osascript" nil 0 nil "-e"
                    (format "display notification %S with title %S" message title)))
    t))

(agent-ui-defmethod "eval"
    ((code string "Emacs Lisp code; may contain several forms" required))
  "Evaluate arbitrary Elisp in Emacs and return the printed value of the last form.
Use it for operations the other methods do not cover, such as changing the window
layout or calling a mode's commands."
  (prin1-to-string (eval (car (read-from-string (concat "(progn " code "\n)"))) t)))

(agent-ui-defmethod "describe" ()
  "List all methods with their parameter schemas (used by emx help and MCP tools/list)."
  (vconcat
   (seq-keep (pcase-lambda (`(,name . ,entry))
               (unless (equal name "describe")
                 (list :name name
                       :description (plist-get entry :description)
                       :inputSchema (agent-ui--schema (plist-get entry :params)))))
             (reverse agent-ui--methods))))

;;; 交互命令

(defun agent-ui-last-view ()
  "回到最近一次 agent 展示的内容。"
  (interactive)
  (let ((buffer (seq-find (lambda (buffer)
                            (string-match-p "\\`\\*agent-\\(view\\|canvas\\):"
                                            (buffer-name buffer)))
                          (buffer-list))))
    (unless buffer (user-error "agent 还没有展示过内容"))
    (select-window (agent-ui--show-buffer buffer))))

(provide 'agent-ui)
;;; agent-ui.el ends here
