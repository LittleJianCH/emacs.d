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

(provide 'agent-session-table-test)
;;; agent-session-table-test.el ends here
