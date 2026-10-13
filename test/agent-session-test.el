;;; agent-session-test.el --- agent-session 的回归测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; 用一个假后端（立即回显）测试会话界面，不调用真实 agent。
;; 运行：
;;   emacs --batch -L lisp/agent -l test/agent-session-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)

(cl-defmethod agent-session-backend-start ((_ (eql test-echo)) session)
  (agent-session-set-status session 'idle))

(cl-defmethod agent-session-backend-send ((_ (eql test-echo)) session text)
  (unless (string-prefix-p "hold" text)
    (agent-session-text session (format "reply-%s" text) (concat "收到：" text))
    (agent-session-set-status session 'idle)))

(cl-defmethod agent-session-backend-stop ((_ (eql test-echo)) _session) nil)

(agent-session-define-agent test-echo :title "Echo")

(defmacro agent-session-test--with-session (&rest body)
  "在一个新的假会话 buffer 中执行 BODY。"
  `(let ((default-directory temporary-file-directory)
         (buffer nil))
     (unwind-protect
         (progn
           (setq buffer (agent-session-test-echo t))
           (with-current-buffer buffer
             (goto-char (point-max))
             ,@body))
       (when (buffer-live-p buffer) (kill-buffer buffer)))))

(defun agent-session-test--type (string)
  "在输入区末尾输入 STRING 并发送。"
  (goto-char (point-max))
  (insert string)
  (agent-session-send-input))

(defun agent-session-test--transcript ()
  "对话记录部分的纯文本。"
  (buffer-substring-no-properties (point-min) (agent-session-tail agent-session--current)))

(ert-deftest agent-session-test-multiple-messages ()
  "发送后输入区仍可编辑，可以继续发送下一条。"
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (should (= (point) (point-max)))
   (should (= (point) (agent-session-input agent-session--current)))
   (agent-session-test--type "two")
   (should (string-match-p "one\\(.\\|\n\\)*收到：one\\(.\\|\n\\)*two\\(.\\|\n\\)*收到：two"
                           (agent-session-test--transcript)))
   ;; 对话记录位于分隔线之前，输入区之后没有只读文本。
   (should-not (text-property-not-all (agent-session-input agent-session--current) (point-max)
                                      'read-only nil))))

(ert-deftest agent-session-test-transcript-read-only ()
  "对话记录不可编辑，输入区可编辑。"
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (goto-char (point-min))
   (should-error (insert "x") :type 'text-read-only)
   (goto-char (point-max))
   (insert "ok")
   (should (equal (buffer-substring-no-properties
                   (agent-session-input agent-session--current) (point-max))
                  "ok"))))

(ert-deftest agent-session-test-history ()
  "M-p / M-n 浏览输入历史。"
  (agent-session-test--with-session
   (agent-session-test--type "first")
   (agent-session-test--type "second")
   (agent-session-previous-input)
   (should (equal (agent-session--input-text agent-session--current) "second"))
   (agent-session-previous-input)
   (should (equal (agent-session--input-text agent-session--current) "first"))
   (agent-session-next-input)
   (should (equal (agent-session--input-text agent-session--current) "second"))))

(ert-deftest agent-session-test-queue-order ()
  "忙时输入的消息排队，发出时移到对话末尾，记录顺序与实际一致。"
  (agent-session-test--with-session
   (agent-session-test--type "hold")            ; 后端不回应，会话保持运行中
   (agent-session-test--type "q1")
   (agent-session-test--type "q2")
   (should (equal (mapcar #'cdr (agent-session-queue agent-session--current)) '("q1" "q2")))
   (agent-session-set-status agent-session--current 'idle)
   (should-not (agent-session-queue agent-session--current))
   (should (string-match-p "hold\\(.\\|\n\\)*q1\\(.\\|\n\\)*收到：q1\\(.\\|\n\\)*q2\\(.\\|\n\\)*收到：q2"
                           (agent-session-test--transcript)))))

(provide 'agent-session-test)
;;; agent-session-test.el ends here
