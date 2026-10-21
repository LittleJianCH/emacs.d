;;; agent-session-link-test.el --- Transcript links -*- lexical-binding: t; -*-

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(require 'agent-session)
(require 'agent-ui)

(defmacro agent-session-link-test--with (text root &rest body)
  "Render TEXT for ROOT and evaluate BODY in its transcript."
  (declare (indent 2))
  (let ((value (make-symbol "value")))
    `(let ((,value (agent-session--linkify
                   (agent-session--markdown ,text) ,root)))
       (with-temp-buffer
         (insert (agent-session--ro ,value))
         (goto-char (point-min))
         ,@body))))

(ert-deftest agent-session-link-test-remote-file ()
  "A report link is a real button and resolves to the originating host."
  (agent-session-link-test--with
      "[完整报告](/tmp/report.org)" "/rpc:dev:/work/project/"
    (search-forward "完整报告")
    (backward-char)
    (let ((button (button-at (point))) opened)
      (should button)
      (should (button-get button 'follow-link))
      (should (eq (key-binding (kbd "RET")) 'agent-session-ret))
      (cl-letf (((symbol-function 'agent-ui--method-open)
                 (lambda (params) (setq opened params))))
        (button-activate button))
      (should (equal (plist-get opened :path) "/rpc:dev:/tmp/report.org")))))

(ert-deftest agent-session-link-test-relative-position ()
  "Relative file links preserve project, line and column."
  (agent-session-link-test--with
      "[code](src/main.rs:12:3)" "/rpc:dev:/work/project/"
    (search-forward "code")
    (backward-char)
    (let (opened)
      (cl-letf (((symbol-function 'agent-ui--method-open)
                 (lambda (params) (setq opened params))))
        (button-activate (button-at (point))))
      (should (equal opened
                     '(:path "/rpc:dev:/work/project/src/main.rs"
                       :line 12 :column 2))))))

(ert-deftest agent-session-link-test-spaces ()
  "Angle-bracket file destinations can contain spaces."
  (agent-session-link-test--with
      "[report](</tmp/my report.org>)" "/work/"
    (search-forward "report")
    (backward-char)
    (let (opened)
      (cl-letf (((symbol-function 'agent-ui--method-open)
                 (lambda (params) (setq opened params))))
        (button-activate (button-at (point))))
      (should (equal (plist-get opened :path) "/tmp/my report.org")))))

(ert-deftest agent-session-link-test-code ()
  "Code examples and images do not become file buttons."
  (agent-session-link-test--with
      "`[inline](a)`\n\n```text\n[fenced](b)\n```\n\n![image](c)"
      "/work/"
    (should-not (next-button (point-min) t))))

(ert-deftest agent-session-link-test-url ()
  "Web links use the browser without remote file expansion."
  (agent-session-link-test--with
      "[web](https://example.com/a)" "/rpc:dev:/work/"
    (search-forward "web")
    (backward-char)
    (let (opened)
      (cl-letf (((symbol-function 'browse-url)
                 (lambda (url &rest _) (setq opened url))))
        (button-activate (button-at (point))))
      (should (equal opened "https://example.com/a")))))

(ert-deftest agent-session-link-test-positions ()
  "Button decoration never changes the text or its length."
  (let* ((text (agent-session--markdown "[a](x)\n\nplain text"))
         (result (agent-session--linkify text "/work/")))
    (should (equal (substring-no-properties text)
                   (substring-no-properties result)))))

(provide 'agent-session-link-test)
;;; agent-session-link-test.el ends here
