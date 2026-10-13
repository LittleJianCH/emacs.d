;;; agent-canvas.el --- agent 生成的原生 Emacs 页面 -*- lexical-binding: t; -*-

;;; Commentary:

;; agent 用 JSON 描述页面（由若干 block 组成），这里把它渲染成 Emacs buffer：
;; 文字和配色跟随当前主题，代码块用对应 major mode 高亮，图表与流程图用
;; svg.el 绘制，区块可折叠，按钮可以把指令发回给 agent 会话。
;;
;; 入口是 agent-ui 方法 render / patch，block 格式见 render 的说明。
;; 新增 block 类型：写一个接收 block plist 的函数，加入 `agent-canvas-renderers'。
;;
;; 页面中的按键：TAB 折叠区块 / 下一个按钮，RET 点击，c 回复 agent，g 重绘，q 关闭。

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'color)
(require 'ansi-color)
(require 'svg)
(require 'dom)
(require 'button)
(require 'agent-term)
(require 'agent-ui)

(defgroup agent-canvas nil
  "agent 生成的原生页面。"
  :group 'agent-ui
  :prefix "agent-canvas-")

(defcustom agent-canvas-max-width 110
  "表格、图表等内容的最大宽度，单位为字符。"
  :type 'integer)

(defcustom agent-canvas-svg-font "Helvetica Neue, PingFang SC, sans-serif"
  "图表与流程图使用的字体。"
  :type 'string)

;;; Faces

(defface agent-canvas-title '((t :inherit (bold outline-1) :height 1.5))
  "页面标题。")
(defface agent-canvas-h1 '((t :inherit (bold outline-1) :height 1.3))
  "一级标题。")
(defface agent-canvas-h2 '((t :inherit (bold outline-2) :height 1.15))
  "二级标题与区块标题。")
(defface agent-canvas-h3 '((t :inherit (bold outline-3)))
  "三级标题。")
(defface agent-canvas-meta '((t :inherit shadow))
  "次要信息。")
(defface agent-canvas-code '((t :inherit (fixed-pitch font-lock-constant-face)))
  "行内代码。")
(defface agent-canvas-link '((t :inherit link))
  "链接。")
(defface agent-canvas-button
  '((t :inherit (mode-line-inactive bold)
       :box (:line-width (6 . 3) :style released-button)))
  "按钮。")

;;; 页面状态（buffer-local）

(defvar-local agent-canvas--page nil "页面数据 (:title T :blocks [...])。")
(defvar-local agent-canvas--agent nil "生成页面的 agent 会话 buffer 名。")
(defvar-local agent-canvas--root nil "解析相对路径的根目录。")
(defvar-local agent-canvas--folds nil "用户折叠状态：((KEY . COLLAPSED) ...)，重绘时保留。")
(defvar-local agent-canvas--errors nil "最近一次渲染中出错的 block。")
(defvar-local agent-canvas--width nil "渲染时窗口文本区宽度（图形界面为像素）。")
(defvar-local agent-canvas--time nil "页面最近更新时间。")

(defvar agent-canvas--prefix ""
  "当前嵌套层级的行前缀（区块缩进、提示框左边线）。")

(defvar agent-canvas--fs 13 "SVG 字号（像素）。")

;;; 尺寸与颜色

(defun agent-canvas--px (string)
  "STRING 的显示宽度：图形界面为像素，终端为列。"
  (if (display-graphic-p) (string-pixel-width string) (string-width string)))

(defun agent-canvas--space-to (x)
  "对齐到横向位置 X 的空白（单位同 `agent-canvas--px'）。"
  (propertize " " 'display `(space :align-to ,(if (display-graphic-p) (list x) x))))

(defun agent-canvas--avail ()
  "当前嵌套层级可用的内容宽度。"
  (- (min (or agent-canvas--width 800)
          (* agent-canvas-max-width (frame-char-width)))
     (agent-canvas--px agent-canvas--prefix)
     (frame-char-width)))

(defun agent-canvas--hex (face &optional attribute)
  "FACE 的颜色（默认前景）转成 #rrggbb，供 SVG 使用。"
  (let* ((name (face-attribute face (or attribute :foreground) nil 'default))
         (rgb (and (stringp name) (color-name-to-rgb name))))
    (if rgb (apply #'color-rgb-to-hex (append rgb '(2))) "#888888")))

(defconst agent-canvas--palette-faces
  '(ansi-color-blue ansi-color-green ansi-color-yellow
    ansi-color-magenta ansi-color-cyan ansi-color-red)
  "数据系列配色，取自主题的 ANSI 颜色。")

(defun agent-canvas--palette (i)
  "第 I 个数据系列的颜色。"
  (agent-canvas--hex (nth (mod i (length agent-canvas--palette-faces))
                          agent-canvas--palette-faces)))

(defun agent-canvas--style-color (style)
  "语义样式 STYLE 对应的颜色。"
  (agent-canvas--hex (pcase style
                       ("primary" 'ansi-color-blue)
                       ("info" 'ansi-color-cyan)
                       ("success" 'ansi-color-green)
                       ("warning" 'ansi-color-yellow)
                       ("error" 'ansi-color-red)
                       (_ 'shadow))))

(defun agent-canvas--surface ()
  "代码块、节点等“卡片”的背景色。"
  (agent-canvas--hex 'mode-line-inactive :background))

;;; 文本工具

(defun agent-canvas--cell (value)
  "把 JSON 值转成显示用字符串。"
  (cond ((stringp value) value)
        ((null value) "")
        ((integerp value) (number-to-string value))
        ((and (floatp value) (= value (ftruncate value)) (< (abs value) 1e15))
         (format "%d" (truncate value)))
        ((floatp value) (format "%.4g" value))
        (t (format "%s" value))))

(defun agent-canvas--truncate (string width)
  "把 STRING 截断到宽度 WIDTH 以内。"
  (cond ((<= (agent-canvas--px string) width) string)
        ((display-graphic-p) (truncate-string-pixelwise string width nil "…"))
        (t (truncate-string-to-width string width nil nil "…"))))

(defun agent-canvas--decorate (start &optional extra)
  "给 START 到当前位置的文本加上行前缀；EXTRA 为折行时额外的缩进。"
  (add-text-properties start (point)
                       (list 'line-prefix agent-canvas--prefix
                             'wrap-prefix (concat agent-canvas--prefix (or extra "")))))

(defun agent-canvas--resolve (path)
  "相对于页面根目录解析 PATH。"
  (expand-file-name path agent-canvas--root))

(defun agent-canvas--open (target)
  "打开 TARGET：网址用 eww，否则视为 path[:line[-end]] 在另一个窗口打开。"
  (if (string-match-p "\\`https?://" target)
      (eww target)
    (string-match "\\`\\(.*?\\)\\(?::\\([0-9]+\\)\\(?:-\\([0-9]+\\)\\)?\\)?\\'" target)
    (let ((file (agent-canvas--resolve (match-string 1 target)))
          (line (and (match-string 2 target) (string-to-number (match-string 2 target))))
          (end (and (match-string 3 target) (string-to-number (match-string 3 target)))))
      (pop-to-buffer (find-file-noselect file) '(display-buffer-use-some-window
                                                 (inhibit-same-window . t)))
      (when line
        (goto-char (point-min))
        (forward-line (1- line))
        (recenter)
        (pulse-momentary-highlight-region
         (line-beginning-position)
         (save-excursion (forward-line (- (or end line) line)) (line-end-position)))))))

(defconst agent-canvas--inline-re
  (rx (or (seq "**" (group-n 1 (+? anything)) "**")
          (seq "`" (group-n 2 (+ (not "`"))) "`")
          (seq "[" (group-n 3 (+ (not "]"))) "](" (group-n 4 (+ (not ")"))) ")")))
  "行内标记：**粗体**、`代码`、[文字](目标)。")

(defun agent-canvas--insert-inline (text &optional face)
  "插入带行内标记的 TEXT，整体使用 FACE。"
  (let ((pos 0)
        (text (agent-canvas--cell text)))
    (while (string-match agent-canvas--inline-re text pos)
      (let ((before (substring text pos (match-beginning 0)))
            (bold (match-string 1 text))
            (code (match-string 2 text))
            (label (match-string 3 text))
            (target (match-string 4 text)))
        (setq pos (match-end 0))
        (insert (if face (propertize before 'face face) before))
        (cond (bold (insert (propertize bold 'face (if face (list 'bold face) 'bold))))
              (code (insert (propertize code 'face 'agent-canvas-code)))
              (t (insert-text-button label 'face 'agent-canvas-link 'help-echo target
                                     'follow-link t
                                     'action (lambda (_) (agent-canvas--open target)))))))
    (let ((rest (substring text pos)))
      (insert (if face (propertize rest 'face face) rest)))))

;;; 代码高亮

(defcustom agent-canvas-lang-modes
  '(("elisp" . emacs-lisp-mode) ("emacs-lisp" . emacs-lisp-mode)
    ("sh" . sh-mode) ("bash" . sh-mode) ("shell" . sh-mode) ("zsh" . sh-mode)
    ("rs" . "rust") ("py" . "python") ("js" . "js") ("ts" . "typescript")
    ("yml" . "yaml") ("md" . markdown-mode) ("markdown" . markdown-mode)
    ("cpp" . "c++") ("diff" . diff-mode) ("org" . org-mode))
  "代码块语言名到 major mode（符号）或语言基名（字符串）的映射。"
  :type '(alist :key-type string :value-type (choice symbol string)))

(defun agent-canvas--lang-mode (lang)
  "代码语言 LANG 对应的 major mode：优先已装语法的 tree-sitter 模式。"
  (let* ((entry (cdr (assoc (downcase lang) agent-canvas-lang-modes)))
         (base (if (stringp entry) entry (downcase lang)))
         (ts (intern (format "%s-ts-mode" base)))
         (grammar (intern (pcase base ("js" "javascript") ("c++" "cpp") (_ base))))
         (plain (intern (format "%s-mode" base))))
    (cond ((and entry (symbolp entry) (fboundp entry)) entry)
          ((and (fboundp ts) (treesit-language-available-p grammar)) ts)
          ((fboundp plain) plain))))

(defun agent-canvas--fontify (code mode)
  "用 MODE 高亮 CODE，返回带 face 的字符串。"
  (if (null mode)
      code
    (with-temp-buffer
      (insert code)
      (let ((treesit-auto-install-grammar nil))
        (ignore-errors
          (delay-mode-hooks (funcall mode))
          (font-lock-ensure)))
      ;; 有些模式用 font-lock-face，统一转成 face，在页面里不依赖 font-lock。
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let ((next (next-single-property-change pos 'font-lock-face nil (point-max)))
                (face (get-text-property pos 'font-lock-face)))
            (when face (put-text-property pos next 'face face))
            (setq pos next))))
      (buffer-string))))

;;; block 渲染器

(defun agent-canvas--heading (block)
  "heading：{text, level}。"
  (let ((start (point)))
    (agent-canvas--insert-inline (plist-get block :text)
                                 (pcase (plist-get block :level)
                                   (1 'agent-canvas-h1) (3 'agent-canvas-h3)
                                   (_ 'agent-canvas-h2)))
    (insert "\n")
    (agent-canvas--decorate start)))

(defun agent-canvas--text (block)
  "text：{text}，支持行内标记，按窗口宽度自动折行。"
  (let ((start (point)))
    (agent-canvas--insert-inline (plist-get block :text))
    (insert "\n")
    (agent-canvas--decorate start)))

(defun agent-canvas--list (block)
  "list：{items, ordered}；item 为字符串或 {text, items, checked}。"
  (let ((n 0))
    (seq-doseq (item (plist-get block :items))
      (setq n (1+ n))
      (let* ((object (and (listp item) item))
             (check (and object (plist-member object :checked)))
             (done (and check (plist-get object :checked)))
             (bullet (cond (check (if done "☑ " "☐ "))
                           ((plist-get block :ordered) (format "%d. " n))
                           (t "• ")))
             (indent (make-string (string-width bullet) ?\s))
             (start (point)))
        (insert (propertize bullet 'face 'agent-canvas-meta))
        (agent-canvas--insert-inline (if object (plist-get object :text) item)
                                     (and done 'agent-canvas-meta))
        (insert "\n")
        (agent-canvas--decorate start indent)
        (when-let* ((children (and object (plist-get object :items))))
          (let ((agent-canvas--prefix (concat agent-canvas--prefix indent)))
            (agent-canvas--list (list :items children
                                      :ordered (plist-get block :ordered)))))))))

(defun agent-canvas--file-lines (file start end)
  "读取 FILE 的第 START 到 END 行。"
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (forward-line (1- start))
    (let ((from (point)))
      (forward-line (1+ (- end start)))
      (string-trim-right (buffer-substring-no-properties from (point)) "\n"))))

(defun agent-canvas--code (block)
  "code：{code, lang, title} 或 {path, start, end} 引用文件片段（带行号）。"
  (let* ((path (plist-get block :path))
         (first (or (plist-get block :start) (and path 1)))
         (code (if path
                   (let ((file (agent-canvas--resolve path)))
                     (agent-canvas--file-lines file first
                                               (or (plist-get block :end) most-positive-fixnum)))
                 (string-trim-right (agent-canvas--cell (plist-get block :code)))))
         (lang (or (plist-get block :lang)
                   (and path (file-name-extension path))))
         (mode (if (and path (not (plist-get block :lang)))
                   (assoc-default path auto-mode-alist #'string-match)
                 (and lang (agent-canvas--lang-mode lang))))
         (bg (agent-canvas--surface))
         (start (point)))
    (cond (path
           (let ((target (format "%s:%d-%d" path first
                                 (+ first (cl-count ?\n code)))))
             (insert-text-button target 'face 'agent-canvas-link 'follow-link t
                                 'action (lambda (_) (agent-canvas--open target)))))
          ((plist-get block :title)
           (insert (propertize (plist-get block :title) 'face 'agent-canvas-meta)))
          (lang (insert (propertize lang 'face 'agent-canvas-meta))))
    (unless (= start (point))
      (insert "\n")
      (agent-canvas--decorate start))
    (let ((body (point))
          (text (agent-canvas--fontify code (and (functionp mode) mode)))
          (pad (propertize "  " 'face `(:background ,bg))))
      (if (not first)
          (insert text "\n")
        (let ((width (length (number-to-string (+ first (cl-count ?\n text))))))
          (cl-loop for line in (split-string text "\n")
                   for n from first
                   do (insert (propertize (format (format "%%%dd  " width) n)
                                          'face 'line-number)
                              line "\n"))))
      (let ((overlay (make-overlay body (point))))
        (overlay-put overlay 'face `(:background ,bg :extend t)))
      (add-text-properties body (point)
                           (list 'line-prefix (concat agent-canvas--prefix pad)
                                 'wrap-prefix (concat agent-canvas--prefix pad))))))

(defconst agent-canvas--number-re "\\`[-+]?[$¥€]?[0-9][0-9,]*\\(?:\\.[0-9]+\\)?[%x]?\\'"
  "看起来像数字的单元格，表格中右对齐。")

(defun agent-canvas--table (block)
  "table：{columns, rows, caption}。数字列自动右对齐，过宽时截断最宽的列。"
  (let* ((header (mapcar #'agent-canvas--cell (plist-get block :columns)))
         (rows (mapcar (lambda (row) (mapcar #'agent-canvas--cell row))
                       (plist-get block :rows)))
         (ncol (apply #'max (length header) (mapcar #'length rows)))
         (gap (agent-canvas--px "   "))
         (base (+ (agent-canvas--px agent-canvas--prefix) (agent-canvas--px " ")))
         (numeric (cl-loop for i below ncol
                           collect (and rows
                                        (seq-every-p
                                         (lambda (row)
                                           (let ((cell (or (nth i row) "")))
                                             (or (string-empty-p cell)
                                                 (string-match-p agent-canvas--number-re cell))))
                                         rows))))
         (widths (cl-loop for i below ncol
                          collect (apply #'max 1 (mapcar (lambda (row)
                                                           (agent-canvas--px (or (nth i row) "")))
                                                         (cons header rows)))))
         (avail (agent-canvas--avail))
         (minimum (agent-canvas--px "xxxxxxxx"))
         (start (point)))
    ;; 总宽超出时，反复收窄最宽的一列。
    (let (excess)
      (while (and (> (setq excess (- (+ (apply #'+ widths) (* gap (1- ncol))) avail)) 0)
                  (> (apply #'max widths) minimum))
        (let ((i (cl-position (apply #'max widths) widths)))
          (setf (nth i widths) (max minimum (- (nth i widths) excess))))))
    (cl-flet ((row (cells face)
                (let ((x base))
                  (insert " ")
                  (cl-loop for i below ncol
                           for width in widths
                           do (let* ((cell (agent-canvas--truncate (or (nth i cells) "") width))
                                     (cell-width (agent-canvas--px cell)))
                                (when (nth i numeric)
                                  (insert (agent-canvas--space-to (+ x (- width cell-width)))))
                                (insert (if face (propertize cell 'face face) cell))
                                (setq x (+ x width gap))
                                (when (< i (1- ncol))
                                  (insert (agent-canvas--space-to x)))))
                  (insert "\n"))))
      (when-let* ((caption (plist-get block :caption)))
        (insert (propertize caption 'face 'agent-canvas-meta) "\n"))
      (when header
        (row header 'bold)
        (let ((total (+ (apply #'+ widths) (* gap (1- ncol)))))
          (insert " " (propertize (make-string (ceiling total (max 1 (agent-canvas--px "─"))) ?─)
                                  'face 'agent-canvas-meta)
                  "\n")))
      (dolist (cells rows) (row cells nil)))
    (agent-canvas--decorate start)))

(defun agent-canvas--kv (block)
  "kv：{items: [[键, 值], ...]}，值支持行内标记。"
  (let* ((items (mapcar (lambda (item)
                          (if (and (listp item) (keywordp (car item)))
                              (list (plist-get item :key) (plist-get item :value))
                            (append item nil)))
                        (plist-get block :items)))
         (keys (mapcar (lambda (item) (agent-canvas--cell (car item))) items))
         (column (+ (agent-canvas--px agent-canvas--prefix)
                    (apply #'max 0 (mapcar #'agent-canvas--px keys))
                    (agent-canvas--px "   ")))
         (start (point)))
    (cl-loop for key in keys
             for item in items
             do (insert (propertize key 'face 'agent-canvas-meta)
                        (agent-canvas--space-to column))
                (agent-canvas--insert-inline (cadr item))
                (insert "\n"))
    (agent-canvas--decorate start)))

(defun agent-canvas--callout (block)
  "callout：{style, title, text, blocks}，左侧带彩色竖线的提示框。"
  (let* ((color (agent-canvas--style-color (or (plist-get block :style) "info")))
         (agent-canvas--prefix (concat agent-canvas--prefix
                                       (propertize "▍ " 'face `(:foreground ,color)))))
    (when-let* ((title (plist-get block :title)))
      (let ((start (point)))
        (insert (propertize title 'face `(:foreground ,color :weight bold)) "\n")
        (agent-canvas--decorate start)))
    (when (plist-get block :text)
      (agent-canvas--text block))
    (when-let* ((blocks (plist-get block :blocks)))
      (agent-canvas--render-blocks blocks))))

(defun agent-canvas--progress (block)
  "progress：{label, value, max, style} 或 {items: [...]}，多项时进度条对齐。"
  (let* ((items (or (append (plist-get block :items) nil) (list block)))
         (labels (mapcar (lambda (item) (agent-canvas--cell (plist-get item :label))) items))
         (column (+ (agent-canvas--px agent-canvas--prefix)
                    (apply #'max 0 (mapcar #'agent-canvas--px labels))
                    (agent-canvas--px "  ")))
         (cells 24)
         (start (point)))
    (cl-loop for item in items
             for label in labels
             do (let* ((value (or (plist-get item :value) 0))
                       (max (or (plist-get item :max) 100))
                       (ratio (min 1.0 (max 0.0 (/ (float value) (max max 1e-9)))))
                       (filled (round (* ratio cells)))
                       (color (agent-canvas--style-color (or (plist-get item :style) "success"))))
                  (insert label (agent-canvas--space-to column)
                          (propertize (make-string filled ?█) 'face `(:foreground ,color))
                          (propertize (make-string (- cells filled) ?░) 'face 'agent-canvas-meta)
                          (propertize (format "  %d%%" (round (* 100 ratio))) 'face 'bold)
                          (if (plist-get item :max)
                              (propertize (format "  %s/%s" (agent-canvas--cell value)
                                                  (agent-canvas--cell max))
                                          'face 'agent-canvas-meta)
                            "")
                          "\n")))
    (agent-canvas--decorate start)))

(defun agent-canvas--divider (_block)
  "divider：分隔线。"
  (let ((start (point)))
    (insert (propertize (make-string (max 1 (/ (agent-canvas--avail)
                                               (max 1 (agent-canvas--px "─"))))
                                     ?─)
                        'face 'agent-canvas-meta)
            "\n")
    (agent-canvas--decorate start)))

(defun agent-canvas--image (block)
  "image：{path, width}。"
  (let ((start (point))
        (width (min (agent-canvas--avail) (or (plist-get block :width) most-positive-fixnum))))
    (insert-image (create-image (agent-canvas--resolve (plist-get block :path)) nil nil
                                :max-width width)
                  "[图片]")
    (insert "\n")
    (agent-canvas--decorate start)))

;;; 区块折叠

(defun agent-canvas--section (block)
  "section：{title, collapsed, blocks}，标题可点击或按 TAB 折叠。"
  (let* ((title (agent-canvas--cell (plist-get block :title)))
         (key (or (plist-get block :id) title))
         (state (assoc key agent-canvas--folds))
         (collapsed (if state (cdr state) (plist-get block :collapsed)))
         (start (point))
         (button (insert-text-button (concat (if collapsed "▸ " "▾ ") title)
                                     'face 'agent-canvas-h2 'follow-link t
                                     'agent-canvas-key key
                                     'action #'agent-canvas--toggle-section)))
    (insert "\n")
    (agent-canvas--decorate start)
    (let ((body (point)))
      (let ((agent-canvas--prefix (concat agent-canvas--prefix "  ")))
        (agent-canvas--render-blocks (plist-get block :blocks)))
      (let ((overlay (make-overlay body (point))))
        (overlay-put overlay 'invisible (and collapsed t))
        (overlay-put overlay 'isearch-open-invisible
                     (lambda (o) (overlay-put o 'invisible nil)))
        (button-put button 'agent-canvas-overlay overlay)))))

(defun agent-canvas--toggle-section (button)
  "折叠或展开 BUTTON 所在区块。"
  (let* ((overlay (button-get button 'agent-canvas-overlay))
         (collapsed (not (overlay-get overlay 'invisible)))
         (inhibit-read-only t))
    (overlay-put overlay 'invisible collapsed)
    (setf (alist-get (button-get button 'agent-canvas-key) agent-canvas--folds nil nil #'equal)
          collapsed)
    (save-excursion
      (goto-char (button-start button))
      (let ((props (text-properties-at (point))))
        (delete-char 1)
        (insert (apply #'propertize (if collapsed "▸" "▾") props))))))

;;; 按钮：把指令发回 agent

(defun agent-canvas--agent-buffer ()
  "页面所属的 agent 会话 buffer。"
  (or (and agent-canvas--agent (get-buffer agent-canvas--agent))
      (agent-term--target)
      (user-error "找不到 agent 会话")))

(defun agent-canvas--press (spec)
  "执行按钮 SPEC：发送 prompt 给 agent，或打开 open 指向的位置。"
  (cond ((plist-get spec :prompt)
         (agent-term-send-string (plist-get spec :prompt)
                                 (agent-canvas--agent-buffer)
                                 (if (plist-member spec :submit) (plist-get spec :submit) t)))
        ((plist-get spec :open) (agent-canvas--open (plist-get spec :open)))))

(defun agent-canvas--buttons (block)
  "buttons：{buttons: [{label, prompt, submit, open}]}。"
  (let ((start (point)))
    (seq-doseq (spec (plist-get block :buttons))
      (insert-text-button (format " %s " (agent-canvas--cell (plist-get spec :label)))
                          'face 'agent-canvas-button 'follow-link t
                          'help-echo (or (plist-get spec :prompt) (plist-get spec :open))
                          'action (lambda (_) (agent-canvas--press spec)))
      (insert "  "))
    (insert "\n")
    (agent-canvas--decorate start)))

;;; SVG 工具

(defun agent-canvas--text-w (string)
  "估算 STRING 在 SVG 中的宽度。"
  (* (string-width string) agent-canvas--fs 0.6))

(defun agent-canvas--fit (string width)
  "把 STRING 截断到 SVG 宽度 WIDTH 内。"
  (if (<= (agent-canvas--text-w string) width)
      string
    (truncate-string-to-width string (max 1 (floor width (* agent-canvas--fs 0.6))) nil nil "…")))

(defun agent-canvas--svg-text (svg text x y &rest attributes)
  "在 SVG 的 (X, Y) 处写 TEXT。"
  (apply #'svg-text svg text :x x :y y
         :font-size agent-canvas--fs :font-family agent-canvas-svg-font
         (if (plist-member attributes :fill)
             attributes
           (append attributes (list :fill (agent-canvas--hex 'default))))))

(defun agent-canvas--svg-path (svg d color &optional dashed)
  "在 SVG 上画路径 D。"
  (dom-append-child svg (dom-node 'path `((d . ,d) (fill . "none") (stroke . ,color)
                                          (stroke-width . "1.5")
                                          ,@(when dashed '((stroke-dasharray . "5 4")))))))

(defun agent-canvas--insert-svg (svg)
  "插入 SVG 图像，宽度不超过可用宽度。"
  (insert-image (svg-image svg :ascent 'center :max-width (agent-canvas--avail)) "[图]")
  (insert "\n"))

(defun agent-canvas--num (value)
  "坐标轴上的数值文字。"
  (agent-canvas--cell value))

(defun agent-canvas--nice (x)
  "不小于 X 的“整齐”刻度步长。"
  (if (<= x 0)
      1
    (let* ((e (expt 10.0 (floor (log x 10))))
           (f (/ x e)))
      (* e (cond ((<= f 1) 1) ((<= f 2) 2) ((<= f 2.5) 2.5) ((<= f 5) 5) (t 10))))))

;;; 图表

(defun agent-canvas--series (block)
  "BLOCK 的数据系列：((NAME . VALUES) ...)。"
  (mapcar (lambda (series)
            (cons (agent-canvas--cell (plist-get series :name))
                  (mapcar (lambda (v) (if (numberp v) v 0)) (plist-get series :values))))
          (plist-get block :series)))

(defun agent-canvas--legend (svg series x)
  "在 SVG 顶部从 X 开始画图例。"
  (let ((dim (agent-canvas--hex 'shadow))
        (size (* agent-canvas--fs 0.8)))
    (cl-loop for (name . _) in series
             for i from 0
             do (svg-rectangle svg x 4 size size :rx 2 :fill (agent-canvas--palette i))
                (agent-canvas--svg-text svg name (+ x size 5) (+ 4 size -1) :fill dim)
                (setq x (+ x size 18 (agent-canvas--text-w name))))))

(defun agent-canvas--svg-axes (labels series width height)
  "柱状图 / 折线图共用的坐标系，返回 (SVG LEFT TOP PLOT-W Y-OF)。"
  (let* ((values (apply #'append (mapcar #'cdr series)))
         (vmax (apply #'max 0 values))
         (vmin (apply #'min 0 values))
         (step (agent-canvas--nice (/ (float (max (- vmax vmin) 1e-9)) 4)))
         (top-v (* step (ceiling (/ vmax step))))
         (bottom-v (* step (floor (/ vmin step))))
         (top-v (if (= top-v bottom-v) (+ bottom-v step) top-v))
         (left (+ 10 (max (agent-canvas--text-w (agent-canvas--num top-v))
                          (agent-canvas--text-w (agent-canvas--num bottom-v)))))
         (top (if (> (length series) 1) (+ agent-canvas--fs 16) 10))
         (plot-w (- width left 10))
         (plot-h (- height top agent-canvas--fs 14))
         (y-of (lambda (v) (+ top (* plot-h (/ (- top-v v) (float (- top-v bottom-v)))))))
         (svg (svg-create width height))
         (dim (agent-canvas--hex 'shadow))
         (gw (/ plot-w (float (max 1 (length labels))))))
    (let ((v bottom-v))
      (while (<= v (+ top-v (* step 1e-6)))
        (let ((y (funcall y-of v)))
          (svg-line svg left y (+ left plot-w) y :stroke dim
                    :stroke-opacity (if (zerop v) 0.7 0.25) :stroke-width 1)
          (agent-canvas--svg-text svg (agent-canvas--num v) (- left 6) (+ y (/ agent-canvas--fs 3.0))
                                  :text-anchor "end" :fill dim))
        (setq v (+ v step))))
    (cl-loop for label in labels
             for i from 0
             do (agent-canvas--svg-text svg (agent-canvas--fit label (- gw 4))
                                        (+ left (* gw (+ i 0.5))) (- height 6)
                                        :text-anchor "middle" :fill dim))
    (when (> (length series) 1) (agent-canvas--legend svg series left))
    (list svg left gw y-of)))

(defun agent-canvas--svg-bar (labels series width height)
  "分组柱状图。"
  (pcase-let* ((`(,svg ,left ,gw ,y-of) (agent-canvas--svg-axes labels series width height))
               (bar (/ (* gw 0.72) (max 1 (length series))))
               (y0 (funcall y-of 0)))
    (cl-loop for (_ . values) in series
             for si from 0
             do (cl-loop for v in values
                         for i below (length labels)
                         do (let ((y (funcall y-of v)))
                              (svg-rectangle svg (+ left (* i gw) (* gw 0.14) (* si bar))
                                             (min y y0) (max 1 (- bar 2)) (max 1 (abs (- y0 y)))
                                             :rx 2 :fill (agent-canvas--palette si)))))
    svg))

(defun agent-canvas--svg-line (labels series width height)
  "折线图。"
  (pcase-let ((`(,svg ,left ,gw ,y-of) (agent-canvas--svg-axes labels series width height)))
    (cl-loop for (_ . values) in series
             for si from 0
             do (let* ((color (agent-canvas--palette si))
                       (points (cl-loop for v in values
                                        for i below (length labels)
                                        collect (cons (+ left (* gw (+ i 0.5))) (funcall y-of v)))))
                  (svg-polyline svg points :fill "none" :stroke color :stroke-width 2)
                  (dolist (p points)
                    (svg-circle svg (car p) (cdr p) 3 :fill color))))
    svg))

(defun agent-canvas--svg-hbar (labels series width)
  "横向柱状图，适合标签较长或类别较多的数据。"
  (let* ((fs agent-canvas--fs)
         (ns (max 1 (length series)))
         (bar (round (* fs 1.1)))
         (row (+ (* ns (+ bar 3)) 8))
         (top (if (> ns 1) (+ fs 16) 4))
         (height (+ top (* (length labels) row)))
         (values (apply #'append (mapcar #'cdr series)))
         (vmax (float (max 1e-9 (apply #'max 0 values))))
         (label-w (min (* width 0.35) (+ 10 (apply #'max 0 (mapcar #'agent-canvas--text-w labels)))))
         (value-w (+ 10 (apply #'max 0 (mapcar (lambda (v) (agent-canvas--text-w (agent-canvas--num v)))
                                               values))))
         (plot-w (- width label-w value-w))
         (svg (svg-create width height))
         (dim (agent-canvas--hex 'shadow)))
    (cl-loop for label in labels
             for i from 0
             do (let ((y (+ top (* i row))))
                  (agent-canvas--svg-text svg (agent-canvas--fit label (- label-w 10))
                                          (- label-w 8) (+ y (/ (- row 8) 2.0) (/ fs 3.0))
                                          :text-anchor "end")
                  (cl-loop for (_ . vals) in series
                           for si from 0
                           do (let* ((v (or (nth i vals) 0))
                                     (len (max 1 (* plot-w (/ (max v 0) vmax))))
                                     (by (+ y (* si (+ bar 3)))))
                                (svg-rectangle svg label-w by len bar :rx 2
                                               :fill (agent-canvas--palette si))
                                (agent-canvas--svg-text svg (agent-canvas--num v)
                                                        (+ label-w len 6) (+ by (* bar 0.75))
                                                        :fill dim)))))
    (when (> ns 1) (agent-canvas--legend svg series label-w))
    svg))

(defun agent-canvas--chart (block)
  "chart：{kind: bar|hbar|line, labels, series: [{name, values}], title, height}。"
  (let* ((labels (mapcar #'agent-canvas--cell (plist-get block :labels)))
         (series (agent-canvas--series block))
         (width (agent-canvas--avail))
         (height (or (plist-get block :height) 240))
         (start (point)))
    (when-let* ((title (plist-get block :title)))
      (insert (propertize title 'face 'bold) "\n"))
    (if (not (display-graphic-p))
        (agent-canvas--table
         (list :columns (vconcat (cons "" (mapcar #'car series)))
               :rows (vconcat (seq-map-indexed
                               (lambda (label i)
                                 (vconcat (cons label (mapcar (lambda (s) (nth i (cdr s))) series))))
                               labels))))
      (agent-canvas--insert-svg
       (pcase (plist-get block :kind)
         ("hbar" (agent-canvas--svg-hbar labels series width))
         ("line" (agent-canvas--svg-line labels series width height))
         (_ (agent-canvas--svg-bar labels series width height)))))
    (agent-canvas--decorate start)))

;;; 流程图 / 架构图

(defun agent-canvas--layers (ids edges)
  "按最长路径给节点分层（忽略成环的回边），返回 id → 层号 的哈希表。"
  (let ((layer (make-hash-table :test #'equal))
        (indeg (make-hash-table :test #'equal))
        (done (make-hash-table :test #'equal))
        queue)
    (dolist (id ids) (puthash id 0 layer) (puthash id 0 indeg))
    (dolist (e edges) (cl-incf (gethash (nth 1 e) indeg)))
    (setq queue (seq-filter (lambda (id) (zerop (gethash id indeg))) ids))
    (while (< (hash-table-count done) (length ids))
      (unless queue
        (push (seq-find (lambda (id) (not (gethash id done))) ids) queue))
      (let ((id (pop queue)))
        (unless (gethash id done)
          (puthash id t done)
          (dolist (e edges)
            (let ((to (nth 1 e)))
              (when (and (equal (nth 0 e) id) (not (gethash to done)))
                (puthash to (max (gethash to layer) (1+ (gethash id layer))) layer)
                (when (zerop (cl-decf (gethash to indeg)))
                  (setq queue (append queue (list to))))))))))
    layer))

(defun agent-canvas--arrow (svg x y direction color)
  "在 (X, Y) 画指向 DIRECTION 的箭头。"
  (svg-polygon svg (pcase direction
                     ('right `((,x . ,y) (,(- x 8) . ,(- y 4)) (,(- x 8) . ,(+ y 4))))
                     ('left `((,x . ,y) (,(+ x 8) . ,(- y 4)) (,(+ x 8) . ,(+ y 4))))
                     ('down `((,x . ,y) (,(- x 4) . ,(- y 8)) (,(+ x 4) . ,(- y 8))))
                     ('up `((,x . ,y) (,(- x 4) . ,(+ y 8)) (,(+ x 4) . ,(+ y 8)))))
               :fill color))

(defun agent-canvas--diagram-svg (block)
  "把 diagram BLOCK 画成 SVG。"
  (let* ((fs agent-canvas--fs)
         (line-h (* fs 1.35))
         (nodes (make-hash-table :test #'equal))
         ids
         (edges (seq-keep (lambda (e)
                            (let ((from (agent-canvas--cell (plist-get e :from)))
                                  (to (agent-canvas--cell (plist-get e :to))))
                              (unless (equal from to)
                                (list from to (plist-get e :label) (plist-get e :style)))))
                          (plist-get block :edges))))
    (seq-doseq (n (plist-get block :nodes))
      (let ((id (agent-canvas--cell (plist-get n :id))))
        (puthash id (list :label (agent-canvas--cell (or (plist-get n :label) id))
                          :style (plist-get n :style))
                 nodes)
        (push id ids)))
    (dolist (e edges)
      (dolist (id (list (nth 0 e) (nth 1 e)))
        (unless (gethash id nodes)
          (puthash id (list :label id) nodes)
          (push id ids))))
    (setq ids (nreverse ids))
    (let* ((layer (agent-canvas--layers ids edges))
           (nlayers (1+ (apply #'max 0 (hash-table-values layer))))
           (columns (make-vector nlayers nil))
           (size (make-hash-table :test #'equal))
           (geo (make-hash-table :test #'equal))
           (back (seq-some (lambda (e) (<= (gethash (nth 1 e) layer) (gethash (nth 0 e) layer)))
                           edges))
           (margin 8) (gap-node 18))
      ;; 每层节点按出现顺序排列，再按前驱的平均位置调整一次以减少交叉。
      (dolist (id ids)
        (aset columns (gethash id layer) (append (aref columns (gethash id layer)) (list id))))
      (dotimes (l nlayers)
        (when (> l 0)
          (let ((pos (make-hash-table :test #'equal)))
            (dotimes (k l)
              (cl-loop for id in (aref columns k) for i from 0 do (puthash id i pos)))
            (aset columns l
                  (sort (aref columns l)
                        :key (lambda (id)
                               (let ((preds (seq-keep (lambda (e) (and (equal (nth 1 e) id)
                                                                       (gethash (nth 0 e) pos)))
                                                      edges)))
                                 (if preds (/ (apply #'+ preds) (float (length preds))) 1e6))))))))
      (dolist (id ids)
        (let ((lines (split-string (plist-get (gethash id nodes) :label) "\n")))
          (puthash id (cons (max 80 (+ 24 (apply #'max (mapcar #'agent-canvas--text-w lines))))
                            (+ 14 (* line-h (length lines))))
                   size)))
      (let* ((direction (plist-get block :direction))
             (span (lambda (l key) (let ((ns (aref columns l)))
                                     (+ (apply #'+ (mapcar (lambda (id) (funcall key (gethash id size))) ns))
                                        (* gap-node (1- (length ns)))))))
             (thick (lambda (l key) (apply #'max 0 (mapcar (lambda (id) (funcall key (gethash id size)))
                                                           (aref columns l)))))
             ;; 横向布局时层间距要放得下连线标签。
             (label-w (apply #'max 0 (mapcar (lambda (e) (if (nth 2 e) (agent-canvas--text-w (nth 2 e)) 0))
                                             edges)))
             (lr-gap (max 64 (+ label-w 48)))
             (lr-width (+ (* 2 margin) (* lr-gap (1- nlayers))
                          (apply #'+ (mapcar (lambda (l) (funcall thick l #'car)) (number-sequence 0 (1- nlayers))))))
             (lr (cond ((equal direction "LR") t)
                       ((equal direction "TB") nil)
                       (t (<= lr-width (agent-canvas--avail)))))
             (gap-layer (if lr lr-gap (max 48 (* fs 3))))
             (main-size (if lr #'car #'cdr))
             (cross-size (if lr #'cdr #'car))
             (cross-total (apply #'max (mapcar (lambda (l) (funcall span l cross-size))
                                               (number-sequence 0 (1- nlayers)))))
             (main-pos margin))
        ;; 计算每个节点的 (x y w h)。
        (dotimes (l nlayers)
          (let ((thickness (funcall thick l main-size))
                (cross (+ margin (/ (- cross-total (funcall span l cross-size)) 2.0))))
            (dolist (id (aref columns l))
              (let* ((wh (gethash id size))
                     (main (+ main-pos (/ (- thickness (funcall main-size wh)) 2.0))))
                (puthash id (if lr (list main cross (car wh) (cdr wh))
                              (list cross main (car wh) (cdr wh)))
                         geo)
                (setq cross (+ cross (funcall cross-size wh) gap-node))))
            (setq main-pos (+ main-pos thickness gap-layer))))
        (let* ((extra (if back 56 0))
               (main-total (+ (- main-pos gap-layer) margin))
               (width (if lr main-total (+ cross-total (* 2 margin) extra)))
               (height (if lr (+ cross-total (* 2 margin) extra) main-total))
               (svg (svg-create (ceiling width) (ceiling height)))
               (fg (agent-canvas--hex 'default))
               (dim (agent-canvas--hex 'shadow))
               (surface (agent-canvas--surface))
               (bg (agent-canvas--hex 'default :background))
               labels arrows)
          ;; 连线：先画线，节点盖在上面，最后画箭头和标签。
          (dolist (e edges)
            (pcase-let* ((`(,x1 ,y1 ,w1 ,h1) (gethash (nth 0 e) geo))
                         (`(,x2 ,y2 ,w2 ,h2) (gethash (nth 1 e) geo))
                         (forward (> (gethash (nth 1 e) layer) (gethash (nth 0 e) layer)))
                         (`(,p0 ,c1 ,c2 ,p3 ,tip ,dir)
                          (cond
                           ((and forward lr)
                            (let* ((a (cons (+ x1 w1) (+ y1 (/ h1 2.0))))
                                   (b (cons (- x2 7) (+ y2 (/ h2 2.0))))
                                   (dx (max 20 (/ (- (car b) (car a)) 2.0))))
                              (list a (cons (+ (car a) dx) (cdr a)) (cons (- (car b) dx) (cdr b)) b
                                    (cons x2 (cdr b)) 'right)))
                           (forward
                            (let* ((a (cons (+ x1 (/ w1 2.0)) (+ y1 h1)))
                                   (b (cons (+ x2 (/ w2 2.0)) (- y2 7)))
                                   (dy (max 16 (/ (- (cdr b) (cdr a)) 2.0))))
                              (list a (cons (car a) (+ (cdr a) dy)) (cons (car b) (- (cdr b) dy)) b
                                    (cons (car b) y2) 'down)))
                           (lr
                            (let ((a (cons (+ x1 (/ w1 2.0)) (+ y1 h1)))
                                  (b (cons (+ x2 (/ w2 2.0)) (+ y2 h2 7))))
                              (list a (cons (car a) (+ (cdr a) 50)) (cons (car b) (+ (cdr b) 50)) b
                                    (cons (car b) (+ y2 h2)) 'up)))
                           (t
                            (let ((a (cons (+ x1 w1) (+ y1 (/ h1 2.0))))
                                  (b (cons (+ x2 w2 7) (+ y2 (/ h2 2.0)))))
                              (list a (cons (+ (car a) 50) (cdr a)) (cons (+ (car b) 50) (cdr b)) b
                                    (cons (+ x2 w2) (cdr b)) 'left)))))
                         (color (if (nth 3 e) (agent-canvas--style-color (nth 3 e)) dim)))
              (agent-canvas--svg-path svg (format "M %.1f %.1f C %.1f %.1f, %.1f %.1f, %.1f %.1f"
                                                  (car p0) (cdr p0) (car c1) (cdr c1)
                                                  (car c2) (cdr c2) (car p3) (cdr p3))
                                      color (equal (nth 3 e) "dashed"))
              (push (list tip dir color) arrows)
              (when (nth 2 e)
                (push (list (nth 2 e)
                            (/ (+ (car p0) (* 3 (car c1)) (* 3 (car c2)) (car p3)) 8.0)
                            (/ (+ (cdr p0) (* 3 (cdr c1)) (* 3 (cdr c2)) (cdr p3)) 8.0))
                      labels))))
          (dolist (id ids)
            (pcase-let* ((`(,x ,y ,w ,h) (gethash id geo))
                         (node (gethash id nodes))
                         (style (plist-get node :style))
                         (lines (split-string (plist-get node :label) "\n")))
              (svg-rectangle svg x y w h :rx 8 :fill surface
                             :stroke (if style (agent-canvas--style-color style) dim)
                             :stroke-width (if style 2 1))
              (cl-loop for line in lines
                       for i from 0
                       do (agent-canvas--svg-text svg line (+ x (/ w 2.0))
                                                  (+ y 7 (* line-h (+ i 0.5)) (/ fs 3.0))
                                                  :text-anchor "middle" :fill fg
                                                  :font-weight (if (= i 0) "bold" "normal")))))
          (pcase-dolist (`(,tip ,dir ,color) arrows)
            (agent-canvas--arrow svg (car tip) (cdr tip) dir color))
          (pcase-dolist (`(,text ,x ,y) labels)
            (let ((w (+ 8 (agent-canvas--text-w text))))
              (svg-rectangle svg (- x (/ w 2.0)) (- y (* fs 0.7)) w (* fs 1.4) :rx 3 :fill bg)
              (agent-canvas--svg-text svg text x (+ y (/ fs 3.0)) :text-anchor "middle" :fill dim)))
          svg)))))

(defun agent-canvas--diagram (block)
  "diagram：{nodes: [{id, label, style}], edges: [{from, to, label, style}], direction}。"
  (let ((start (point)))
    (when-let* ((title (plist-get block :title)))
      (insert (propertize title 'face 'bold) "\n"))
    (if (display-graphic-p)
        (agent-canvas--insert-svg (agent-canvas--diagram-svg block))
      (seq-doseq (e (plist-get block :edges))
        (insert (format "%s → %s%s\n" (plist-get e :from) (plist-get e :to)
                        (if (plist-get e :label) (format "  (%s)" (plist-get e :label)) "")))))
    (agent-canvas--decorate start)))

;;; 渲染入口

(defvar agent-canvas-renderers
  '(("heading" . agent-canvas--heading)
    ("text" . agent-canvas--text)
    ("list" . agent-canvas--list)
    ("code" . agent-canvas--code)
    ("table" . agent-canvas--table)
    ("kv" . agent-canvas--kv)
    ("callout" . agent-canvas--callout)
    ("chart" . agent-canvas--chart)
    ("diagram" . agent-canvas--diagram)
    ("progress" . agent-canvas--progress)
    ("section" . agent-canvas--section)
    ("buttons" . agent-canvas--buttons)
    ("image" . agent-canvas--image)
    ("divider" . agent-canvas--divider))
  "block 类型到渲染函数的映射。渲染函数接收 block plist，在点处插入内容。")

(defun agent-canvas--render-block (block)
  "渲染单个 BLOCK；出错时显示提示并记录，不影响其他 block。"
  (let* ((type (plist-get block :type))
         (renderer (alist-get type agent-canvas-renderers nil nil #'equal)))
    (condition-case err
        (if renderer
            (funcall renderer block)
          (error "未知的 block 类型：%s" type))
      (error
       (let ((message (format "%s%s：%s" (or type "?")
                              (if (plist-get block :id) (format "#%s" (plist-get block :id)) "")
                              (error-message-string err)))
             (start (point)))
         (push message agent-canvas--errors)
         (insert (propertize (concat "⚠ 渲染失败 " message) 'face 'error) "\n")
         (agent-canvas--decorate start))))))

(defun agent-canvas--render-blocks (blocks)
  "依次渲染 BLOCKS，之间空一行。"
  (let ((first t))
    (seq-doseq (block blocks)
      (unless first
        (let ((start (point)))
          (insert "\n")
          (agent-canvas--decorate start)))
      (setq first nil)
      (agent-canvas--render-block block))))

(defun agent-canvas--redraw (&optional window)
  "按当前窗口宽度重绘页面，尽量保持各窗口的滚动位置。"
  (let* ((window (or window (get-buffer-window (current-buffer) t) (agent-ui--main-window)))
         (positions (mapcar (lambda (w) (list w (window-start w) (window-point w)))
                            (get-buffer-window-list (current-buffer) nil t)))
         (inhibit-read-only t))
    (with-selected-frame (window-frame window)
      (let ((agent-canvas--fs (max 11 (round (* 0.8 (frame-char-height)))))
            (agent-canvas--prefix ""))
        (setq agent-canvas--width (window-body-width window t)
              agent-canvas--errors nil)
        (delete-all-overlays)
        (erase-buffer)
        (insert (propertize (agent-canvas--cell (plist-get agent-canvas--page :title))
                            'face 'agent-canvas-title)
                "\n"
                (propertize (format "%s · %s · TAB 折叠  RET 点击  c 回复 agent  g 重绘\n"
                                    (or agent-canvas--agent "agent")
                                    (format-time-string "%H:%M:%S" agent-canvas--time))
                            'face 'agent-canvas-meta)
                "\n")
        (agent-canvas--render-blocks (plist-get agent-canvas--page :blocks))
        (goto-char (point-min))))
    (pcase-dolist (`(,w ,start ,point) positions)
      (set-window-start w (min start (point-max)) t)
      (set-window-point w (min point (point-max))))))

(defvar agent-canvas--resize-timer nil)

(defun agent-canvas--on-resize (window)
  "窗口宽度明显变化时重绘图表和表格。"
  (with-current-buffer (window-buffer window)
    (when (and agent-canvas--width
               (> (abs (- (window-body-width window t) agent-canvas--width))
                  (* 4 (frame-char-width (window-frame window)))))
      (when (timerp agent-canvas--resize-timer) (cancel-timer agent-canvas--resize-timer))
      (let ((buffer (current-buffer)))
        (setq agent-canvas--resize-timer
              (run-with-idle-timer 0.3 nil
                                   (lambda ()
                                     (when (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (agent-canvas--redraw))))))))))

;;; 页面模式与命令

(defun agent-canvas-tab ()
  "在区块标题上折叠 / 展开，否则跳到下一个按钮。"
  (interactive)
  (let ((button (button-at (point))))
    (if (and button (button-get button 'agent-canvas-overlay))
        (agent-canvas--toggle-section button)
      (forward-button 1 t))))

(defun agent-canvas-comment (text)
  "就当前页面给 agent 发一句话 TEXT。"
  (interactive (list (read-string "回复 agent：")))
  (agent-term-send-string (format "[关于页面「%s」] %s"
                                  (plist-get agent-canvas--page :title) text)
                          (agent-canvas--agent-buffer) t))

(defvar-keymap agent-canvas-mode-map
  :doc "agent 页面的按键。"
  "TAB" #'agent-canvas-tab
  "<backtab>" #'backward-button
  "n" #'forward-button
  "p" #'backward-button
  "c" #'agent-canvas-comment)

(define-derived-mode agent-canvas-mode special-mode "Canvas"
  "显示 agent 生成的页面。"
  (setq-local truncate-lines nil
              word-wrap t
              word-wrap-by-category t
              revert-buffer-function (lambda (&rest _) (agent-canvas--redraw)))
  (add-hook 'window-size-change-functions #'agent-canvas--on-resize nil t))

(defun agent-canvas--buffer (title)
  "标题为 TITLE 的页面 buffer。"
  (let ((buffer (get-buffer-create (format "*agent-canvas: %s*" title))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-canvas-mode) (agent-canvas-mode)))
    buffer))

(defun agent-canvas--caller-root (agent)
  "AGENT 会话所属的项目根目录。"
  (or (when-let* ((buffer (and agent (get-buffer agent))))
        (buffer-local-value 'agent-term--root buffer))
      (with-current-buffer (window-buffer (agent-ui--main-window))
        (when-let* ((project (project-current))) (project-root project)))
      default-directory))

(defun agent-canvas--replace-block (blocks id new)
  "把 BLOCKS（含嵌套）中 id 为 ID 的 block 换成 NEW，返回 (FOUND . BLOCKS)。"
  (let* ((found nil)
         (result
          (vconcat
           (mapcar (lambda (block)
                     (cond ((equal (plist-get block :id) id)
                            (setq found t)
                            (if (plist-get new :id) new (plist-put (copy-sequence new) :id id)))
                           ((plist-get block :blocks)
                            (let ((inner (agent-canvas--replace-block (plist-get block :blocks) id new)))
                              (when (car inner) (setq found t))
                              (plist-put (copy-sequence block) :blocks (cdr inner))))
                           (t block)))
                   blocks))))
    (cons found result)))

(defun agent-canvas--publish (buffer)
  "显示并重绘 BUFFER，返回给 agent 的结果。"
  (let ((window (agent-ui--show-buffer buffer)))
    (with-current-buffer buffer
      (setq agent-canvas--time (current-time))
      (agent-canvas--redraw window)
      (list :buffer (buffer-name buffer)
            :errors (vconcat (reverse agent-canvas--errors))))))

(agent-ui-defmethod "render"
    ((title string "页面标题；同标题会更新同一个页面" required)
     (blocks array "页面内容：block 列表，格式见说明" required)
     (append boolean "为 true 时追加到已有页面末尾，而不是整页替换"))
  "在 Emacs 中渲染一个原生页面（不是网页）：配色跟随用户主题，代码按语言高亮，
图表和流程图用 SVG 绘制，区块可折叠，按钮能把指令发回给你。适合方案对比、计划、
代码审查结果、架构图、统计数据、进度汇报等需要排版的内容。返回 errors 列出渲染失败的 block。

每个 block 是一个对象，type 决定格式；任何 block 都可带 id，之后用 patch 局部更新：
- {\"type\":\"heading\",\"text\":\"…\",\"level\":1|2|3}
- {\"type\":\"text\",\"text\":\"支持 **粗体**、`代码`、[文件](src/main.rs:42)、[网址](https://…)\"}
- {\"type\":\"list\",\"items\":[\"…\",{\"text\":\"…\",\"items\":[\"子项\"]},{\"text\":\"待办\",\"checked\":false}],\"ordered\":false}
- {\"type\":\"code\",\"code\":\"…\",\"lang\":\"rust\",\"title\":\"可选\"}
- {\"type\":\"code\",\"path\":\"src/lib.rs\",\"start\":10,\"end\":30}  引用文件片段，带行号，可点击跳转
- {\"type\":\"table\",\"columns\":[\"模块\",\"耗时\"],\"rows\":[[\"parse\",12],[\"emit\",30]],\"caption\":\"可选\"}
- {\"type\":\"kv\",\"items\":[[\"版本\",\"1.2.0\"],[\"状态\",\"**通过**\"]]}
- {\"type\":\"callout\",\"style\":\"info|success|warning|error\",\"title\":\"…\",\"text\":\"…\",\"blocks\":[…]}
- {\"type\":\"chart\",\"kind\":\"bar|hbar|line\",\"labels\":[\"一月\",\"二月\"],\"series\":[{\"name\":\"耗时\",\"values\":[3,5]}],\"title\":\"…\",\"height\":240}
- {\"type\":\"diagram\",\"nodes\":[{\"id\":\"a\",\"label\":\"客户端\\n第二行说明\",\"style\":\"primary|success|warning|error\"}],\"edges\":[{\"from\":\"a\",\"to\":\"b\",\"label\":\"HTTP\",\"style\":\"dashed\"}],\"direction\":\"LR|TB\"}
- {\"type\":\"progress\",\"items\":[{\"label\":\"编译\",\"value\":3,\"max\":5}]}  或单项 {\"type\":\"progress\",\"label\":…,\"value\":…}
- {\"type\":\"section\",\"title\":\"…\",\"collapsed\":false,\"blocks\":[…]}
- {\"type\":\"buttons\",\"buttons\":[{\"label\":\"按方案 A 实施\",\"prompt\":\"按方案 A 实施\"},{\"label\":\"看代码\",\"open\":\"src/main.rs:10\"}]}
  用户点击 prompt 按钮时，prompt 会作为用户消息发送到你的会话（submit:false 则只填入输入框）
- {\"type\":\"image\",\"path\":\"…\",\"width\":600}
- {\"type\":\"divider\"}
文件路径相对于项目根目录。"
  (let* ((buffer (agent-canvas--buffer title))
         (agent (plist-get agent-ui-caller :agent_buffer)))
    (with-current-buffer buffer
      (setq agent-canvas--page
            (list :title title
                  :blocks (if (and append agent-canvas--page)
                              (vconcat (plist-get agent-canvas--page :blocks) blocks)
                            blocks)))
      (when agent (setq agent-canvas--agent agent))
      (setq agent-canvas--root (agent-canvas--caller-root agent-canvas--agent)))
    (agent-canvas--publish buffer)))

(agent-ui-defmethod "patch"
    ((title string "页面标题" required)
     (id string "要替换的 block 的 id" required)
     (block object "新的 block" required))
  "替换已渲染页面中指定 id 的 block（可在嵌套区块内），用于更新进度、状态等局部内容。"
  (let ((buffer (or (get-buffer (format "*agent-canvas: %s*" title))
                    (error "没有标题为「%s」的页面" title))))
    (with-current-buffer buffer
      (let ((result (agent-canvas--replace-block (plist-get agent-canvas--page :blocks) id block)))
        (unless (car result) (error "页面中没有 id 为 %s 的 block" id))
        (setq agent-canvas--page (plist-put agent-canvas--page :blocks (cdr result)))))
    (agent-canvas--publish buffer)))

(provide 'agent-canvas)

;; render 的说明里有给 agent 看的 JSON 示例，不按 88 列折行。
;; Local Variables:
;; byte-compile-docstring-max-column: 200
;; End:

;;; agent-canvas.el ends here
