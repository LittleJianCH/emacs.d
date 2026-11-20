;;; agent-session-table-test.el --- Transcript table tests -*- lexical-binding: t; -*-

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'agent-session)
(require 'agent-session-table)

(ert-deftest agent-session-table-test-chinese-bold ()
  "Chinese cells and hidden bold delimiters keep every border aligned."
  (let* ((text (agent-session--markdown
                "| 指标 | ROG | Go |\n|---|---:|---:|\n| 首次构建 | 443.59 秒 | 53.32 秒 |\n| 减少 | **5.3%** | **10.6%** |\n"))
         (lines (split-string text "\n" t))
         (widths (mapcar #'string-width lines))
         (pos (string-match "5.3%" text)))
    (should (string-prefix-p "┌" text))
    (should (cl-every (lambda (width) (= width (car widths))) widths))
    (should-not (string-match-p "\\*\\*" text))
    (should (memq 'markdown-bold-face (get-text-property pos 'face text)))
    (should (memq 'fixed-pitch (get-text-property pos 'face text)))))

(ert-deftest agent-session-table-test-code-and-partial ()
  "Code examples and incomplete streamed tables stay unchanged."
  (dolist (text '("```text\n| a | b |\n|---|---|\n| 1 | 2 |\n```\n"
                  "| a | b |\n|---|"
                  "a | b\nordinary text\n"))
    (should-not (string-match-p "┌" (agent-session--markdown text)))))

(ert-deftest agent-session-table-test-inline-pipe ()
  "An inline code pipe does not add a table column."
  (let ((text (agent-session--markdown
               "| Name | Value |\n|---|---|\n| code | `a|b` |\n")))
    (should (string-prefix-p "┌" text))
    (should (string-match-p "a|b" text))
    (should (= 1 (cl-count ?┬ (car (split-string text "\n")))))))

(ert-deftest agent-session-table-test-multiple ()
  "Separate tables render without consuming the prose between them."
  (let ((text (agent-session--markdown
               "| a | b |\n|---|---|\n| 1 | 2 |\n\nmiddle\n\n| x | y |\n|---|---|\n| 3 | 4 |")))
    (should (= 2 (cl-count ?┌ text)))
    (should (string-match-p "\nmiddle\n" text))))

(defun agent-session-table-test--descriptions ()
  "Five long Chinese descriptions, including code and an unbreakable token."
  (cl-loop for i from 1 to 5
           collect (concat
                    (format "描述%d：" i)
                    (apply #'concat
                           (make-list 6 "窗口变窄时保留完整说明，按实际宽度重新排列中文内容。"))
                    "调用`resolve_path`处理"
                    (make-string 50 ?x) "并保留结尾。")))

(defun agent-session-table-test--long-table ()
  "A prose table resembling the reported unreadable transcript."
  (concat "| 功能 | 具体做了什么 |\n|---|---|\n"
          (mapconcat (lambda (description)
                       (concat "| 重排 | " description " |"))
                     (agent-session-table-test--descriptions) "\n")
          "\n"))

(defun agent-session-table-test--grid-lines (text)
  "Nonempty lines in TEXT, without text properties."
  (split-string (substring-no-properties text) "\n" t))

(ert-deftest agent-session-table-test-long-chinese ()
  "Long prose, code and unbreakable tokens fit without losing text or faces."
  (let* ((descriptions (agent-session-table-test--descriptions))
         (text (cl-letf (((symbol-function 'agent-session-table--width)
                          (lambda () 60)))
                 (agent-session--markdown
                  (agent-session-table-test--long-table))))
         (lines (agent-session-table-test--grid-lines text))
         (body (mapconcat
                (lambda (line)
                  (if (string-prefix-p "│" line)
                      (string-trim (nth 2 (split-string line "│"))) ""))
                lines ""))
         (code-characters 0))
    (should (cl-every (lambda (s) (<= 150 (length s) 250)) descriptions))
    (should (> (length lines) 40))
    (should (cl-every (lambda (line) (= (string-width line) 60)) lines))
    (should (equal body
                   (concat "具体做了什么"
                           (replace-regexp-in-string
                            "`" "" (apply #'concat descriptions)))))
    (should-not (string-match-p "…" text))
    (dotimes (pos (length text))
      (when (memq 'markdown-inline-code-face
                  (ensure-list (get-text-property pos 'face text)))
        (cl-incf code-characters)
        (should (memq 'fixed-pitch (get-text-property pos 'face text)))))
    (should (= code-characters (* 5 (length "resolve_path"))))))

(ert-deftest agent-session-table-test-wrap-preserves-properties ()
  "Wrapping preserves whitespace, combining characters and inline properties."
  (let* ((cell (concat "中文 " (propertize "á_LONG_TOKEN" 'face 'markdown-inline-code-face)
                       "  后文"))
         (lines (agent-session-table--wrap cell 4)))
    (should (equal-including-properties (apply #'concat lines) cell))
    (should (cl-every (lambda (line) (<= (string-width line) 4)) lines))
    (should-not (cl-some (lambda (line) (= (aref line 0) #x301)) lines))))

(ert-deftest agent-session-table-test-small-widths ()
  "Impossible column budgets stack cells; tiny windows still keep every glyph."
  (let ((rows '(("功能" "说明") ("甲" "中文xxxxxxxxxxxxxxxx尾"))))
    (dolist (width '(2 3 4 5 6 7 8 9 10 11 12 16 24))
      (let* ((text (agent-session-table--grid rows '("---" "---") width))
             (lines (agent-session-table-test--grid-lines text))
             (content (replace-regexp-in-string
                       "[ │─┌┬┐├┼┤└┴┘\n]" "" text)))
        (should (cl-every (lambda (line) (<= (string-width line) width)) lines))
        ;; Grid lines interleave wrapped columns; every character survives.
        (should (equal (sort (string-to-list content) #'<)
                       (sort (string-to-list "功能说明甲中文xxxxxxxxxxxxxxxx尾")
                             #'<)))))))

(ert-deftest agent-session-table-test-short-and-alignment ()
  "Short tables stay compact; continuation lines keep Markdown alignment."
  (let* ((rows '(("L" "C" "R") ("abcdef" "xy" "z")))
         (formats '("---" ":---:" "---:"))
         (short (agent-session-table--grid rows formats 80)))
    (should (equal short (agent-session-table--grid rows formats 40)))
    (should (< (string-width (car (split-string short "\n"))) 40))
    (should (string-match-p "│ L      │ C  │ R │" short))
    (let ((narrow (agent-session-table--grid rows formats 15)))
      (should (string-match-p "│ L  │ C  │ R │" narrow))
      (should (string-match-p "│ ab │ xy │ z │\n│ cd │    │   │" narrow)))))

(ert-deftest agent-session-table-test-wrapped-links ()
  "Split link labels keep clickable targets, including remote file roots."
  (cl-letf (((symbol-function 'agent-session-table--width) (lambda () 18)))
    (let* ((label "完整报告与代码位置完整报告与代码位置")
           (rendered (agent-session--markdown
                      (concat "| 项 | 详情 |\n|---|---|\n| 甲 | [" label
                              "](/tmp/report.org:12:3) |\n")))
           (data (get-text-property 0 'agent-session-table rendered))
           (text (agent-session--linkify rendered "/rpc:dev:/work/"))
           (labels "") opened)
      (should (eq data (get-text-property 0 'agent-session-table text)))
      (with-temp-buffer
        (insert text)
        (goto-char (point-min))
        (while-let ((button (next-button (point))))
          (setq labels (concat labels (button-label button)))
          (should (equal (button-get button 'agent-session-link-target)
                         "/tmp/report.org:12:3"))
          (cl-letf (((symbol-function 'agent-ui--method-open)
                     (lambda (params) (setq opened params))))
            (button-activate button))
          (should (equal opened '(:path "/rpc:dev:/tmp/report.org" :line 12 :column 2)))
          (goto-char (button-end button))))
      (should (equal labels label)))))

(ert-deftest agent-session-table-test-literal-box ()
  "Literal box drawings are not mistaken for fontified Markdown tables."
  (let ((text "┌────┬────┐\n│ 功能 │ 原文 │\n└────┴────┘\n"))
    (should (equal text (agent-session--markdown text)))))

(ert-deftest agent-session-table-test-row-rules ()
  "A horizontal rule separates the header and every pair of body rows."
  (should (equal (substring-no-properties
                  (agent-session-table--grid
                   '(("a" "b") ("1" "2") ("3" "4")) '("---" "---") 80))
                 (concat "┌───┬───┐\n│ a │ b │\n├───┼───┤\n"
                         "│ 1 │ 2 │\n├───┼───┤\n│ 3 │ 4 │\n└───┴───┘\n"))))

(ert-deftest agent-session-table-test-code-buttons-after-table ()
  "Wrapping tables does not shift fenced-code run buttons into their cells."
  (with-temp-buffer
    (let* ((session (agent-session--make
                     :agent 'codex :root "/tmp/" :buffer (current-buffer)
                     :status 'idle))
           (table (agent-session-table-test--long-table))
           (source (concat table "\n```sh\nprintf hello\n```\n\n" table)))
      (agent-session--setup-buffer session)
      (agent-session-text-done session "mixed" source)
      (should (equal (substring-no-properties
                      (cdr (plist-get (agent-session--block session "mixed") :markdown)))
                     (string-trim-right source)))
      (let ((text (buffer-string)))
        (should (= (cl-count ?┌ text) 2))
        (should (= (cl-count ?└ text) 2))
        (should (string-match-p "printf hello" text))
        (goto-char (point-min))
        (search-forward "▶ 运行")
        (let ((button (button-at (1- (point)))))
          (should button)
          (should (eq (button-type button) 'agent-session-run))
          (should-not (get-text-property (button-start button) 'agent-session-table))
          (should (> (button-start button) (string-match "└" text)))
          (should (< (button-end button) (string-match "printf hello" text))))))))

(ert-deftest agent-session-table-test-resize-streaming-cleanup ()
  "Real windows reflow cached tables without stale text, input or overlays."
  (save-window-excursion
    (with-temp-buffer
      (let* ((session (agent-session--make
                       :agent 'codex :root "/tmp/" :buffer (current-buffer)
                       :status 'idle))
             (source (agent-session-table-test--long-table)))
        (switch-to-buffer (current-buffer))
        (agent-session--setup-buffer session)
        (agent-session-text session "table" source)
        (should-not (text-property-not-all (point-min) (point-max)
                                           'agent-session-table nil))
        (agent-session-text-done session "table")
        (should (memq #'agent-session-table--resize pre-redisplay-functions))
        (goto-char (point-max))
        (insert "draft草稿")
        (let* ((block (agent-session--block session "table"))
               (cache (plist-get block :markdown))
               (wide (buffer-string))
               (other (split-window-right 26)))
          ;; The narrowest window wins when the same buffer has two views.
          (set-window-buffer other (current-buffer))
          (set-window-margins other 1 1)
          ;; A reply arriving before redisplay must not hide the resize of
          ;; older cached tables.
          (agent-session-text-done session "new" "| 新 | 表 |\n|---|---|\n| 甲 | 乙 |\n")
          (let ((previous agent-session-table--last-width))
            (cl-letf (((symbol-function 'agent-session--render)
                       (lambda (&rest _) (error "Test rendering failure"))))
              (should-error (agent-session-table--resize (selected-window))))
            (should (= previous agent-session-table--last-width)))
          (run-hook-with-args 'pre-redisplay-functions (selected-window))
          (should (eq cache (plist-get (agent-session--block session "table") :markdown)))
          (should (> (count-lines (point-min) (agent-session-tail session))
                     (length (split-string wide "\n"))))
          (save-excursion
            (goto-char (point-min))
            (while (re-search-forward "^[┌│├└].*$" (agent-session-tail session) t)
              (should (<= (string-width (match-string 0))
                          (agent-session-table--width)))))
          (agent-session--remove-block session "new")
          (should (equal (buffer-substring-no-properties
                          (agent-session-input session) (point-max)) "draft草稿"))
          (let ((narrow (buffer-string)))
            (run-hook-with-args 'pre-redisplay-functions other)
            (should (equal-including-properties narrow (buffer-string))))
          (delete-window other)
          (run-hook-with-args 'pre-redisplay-functions (selected-window))
          (should (equal wide (buffer-string)))
          (should-not (overlays-in (point-min) (point-max)))
          (should (equal source (plist-get (agent-session--block session "table") :text)))
          ;; Replacing/removing a table leaves no metadata or stale display.
          (agent-session-text-done session "table" "普通回复")
          (should-not (text-property-not-all (point-min) (point-max)
                                             'agent-session-table nil))
          (should-not (string-match-p "[┌┬┐│└┴┘]" (buffer-string)))
          (agent-session-table--resize (selected-window))
          (should (string-match-p "普通回复" (buffer-string)))
          (should (equal (buffer-substring-no-properties
                          (agent-session-input session) (point-max)) "draft草稿")))))))

(provide 'agent-session-table-test)
;;; agent-session-table-test.el ends here
