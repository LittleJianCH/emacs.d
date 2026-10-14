;;; agent-session-test.el --- agent-session 的回归测试 -*- lexical-binding: t; -*-

;;; Commentary:

;; 用一个假后端（立即回显）测试会话界面，不调用真实 agent。
;; 布局参考 telega：对话 | 页脚（分隔线、辅助行、提示符）| 输入区。
;; 运行：
;;   emacs --batch -L lisp/agent -l test/agent-session-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)
(require 'agent-session-list)

(cl-defmethod agent-session-backend-start ((_ (eql test-echo)) session)
  (agent-session-set-status session 'idle))

(cl-defmethod agent-session-backend-send ((_ (eql test-echo)) session text)
  (unless (string-prefix-p "hold" text)
    (agent-session-text session (format "reply-%s" text) (concat "收到：" text))
    (agent-session-set-status session 'idle)))

(cl-defmethod agent-session-backend-stop ((_ (eql test-echo)) _session) nil)

(cl-defmethod agent-session-backend-models ((_ (eql test-echo)) _session)
  '((:id "small" :name "Small" :efforts ("low" "high") :default-effort "low")
    (:id "big" :name "Big" :efforts ("high" "max"))))

(cl-defmethod agent-session-backend-modes ((_ (eql test-echo)) _session)
  '(ask edits full plan))

(cl-defmethod agent-session-backend-commands ((_ (eql test-echo)) _session)
  '((:name "compact" :description "压缩上下文")))

(agent-session-define-agent test-echo :title "Echo")
(agent-session-define-agent test-echo2 :title "Echo2" :backend test-echo)

(defmacro agent-session-test--with-session (&rest body)
  "在一个新的假会话 buffer 中执行 BODY。"
  `(let ((default-directory temporary-file-directory)
         ;; 每个测试从默认设置开始，互不影响。
         (agent-session-last-settings nil)
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
  "对话记录部分（页脚之前）的纯文本。"
  (buffer-substring-no-properties (point-min) (agent-session-tail agent-session--current)))

(defun agent-session-test--footer ()
  "页脚（分隔线、辅助行、提示符）的纯文本。"
  (buffer-substring-no-properties (agent-session-tail agent-session--current)
                                  (agent-session-input agent-session--current)))

(defun agent-session-test--mode-line ()
  "状态栏的纯文本（batch 中 `format-mode-line' 不求值 :eval，直接调用生成函数）。"
  (substring-no-properties (agent-session--mode-line agent-session--current)))

(ert-deftest agent-session-test-multiple-messages ()
  "可以连续发送多条消息，对话按顺序追加。"
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (agent-session-test--type "two")
   (should (string-match-p "one\\(.\\|\n\\)*收到：one\\(.\\|\n\\)*two\\(.\\|\n\\)*收到：two"
                           (agent-session-test--transcript)))))

(ert-deftest agent-session-test-transcript-read-only ()
  "对话记录与页脚只读，输入区可编辑。"
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (goto-char (point-min))
   (should-error (insert "x") :type 'text-read-only)
   (goto-char (agent-session-tail agent-session--current))
   (should-error (insert "x") :type 'text-read-only)
   (goto-char (point-max))
   (insert "ok")
   (should (equal (agent-session--input-text agent-session--current) "ok"))))

(ert-deftest agent-session-test-footer ()
  "页脚：分隔线、提示符；排队消息与待确认请求显示在辅助行。"
  (agent-session-test--with-session
   (should (string-match-p "\\`\n *\n.*Echo ❯ \\'" (agent-session-test--footer)))
   (agent-session-test--type "hold")
   (agent-session-test--type "排队的消息")
   (should (string-match-p "工作中" (agent-session-test--footer)))
   (should (string-match-p "⏳ 排队：排队的消息" (agent-session-test--footer)))
   (agent-session-ask agent-session--current :title "Write：a.txt"
                      :choices '((allow "允许") (deny "拒绝")) :callback #'ignore)
   (should (string-match-p "⚠ Write：a.txt +允许 +拒绝" (agent-session-test--footer)))))

(ert-deftest agent-session-test-typing-in-transcript ()
  "在对话记录中打字会跳到输入区末尾。"
  (agent-session-test--with-session
   (agent-session-test--type "one")
   (switch-to-buffer (current-buffer))
   (goto-char (point-min))
   (execute-kbd-macro "xy")
   (should (equal (agent-session--input-text agent-session--current) "xy"))))

(ert-deftest agent-session-test-point-out-of-prompt ()
  "光标不会停在提示符内。"
  (agent-session-test--with-session
   (switch-to-buffer (current-buffer))
   (goto-char (point-max))
   (execute-kbd-macro (kbd "x <left> <left> <left>"))
   (should (>= (point) (agent-session-input agent-session--current)))))

(ert-deftest agent-session-test-footer-keeps-input ()
  "重绘页脚（例如状态变化）时保留输入区内容与光标。"
  (agent-session-test--with-session
   (goto-char (point-max))
   (insert "草稿中")
   (backward-char 1)
   (agent-session-configure agent-session--current :mode 'full)
   (agent-session-set-status agent-session--current 'running)
   (agent-session--refresh agent-session--current)
   (should (equal (agent-session--input-text agent-session--current) "草稿中"))
   (should (equal (char-after) ?中))))

(ert-deftest agent-session-test-queue-order ()
  "忙时输入的消息排队，发出时移到对话末尾，记录顺序与实际一致。"
  (agent-session-test--with-session
   (agent-session-test--type "hold")            ; 后端不回应，会话保持运行中
   (agent-session-test--type "q1")
   (agent-session-test--type "q2")
   (should (equal (mapcar #'cdr (agent-session-queue agent-session--current)) '("q1" "q2")))
   (should (string-match-p "排队 2" (agent-session-test--mode-line)))
   (agent-session-set-status agent-session--current 'idle)
   (should-not (agent-session-queue agent-session--current))
   (should (string-match-p "hold\\(.\\|\n\\)*q1\\(.\\|\n\\)*收到：q1\\(.\\|\n\\)*q2\\(.\\|\n\\)*收到：q2"
                           (agent-session-test--transcript)))))

(defun agent-session-test--complete (_session input)
  "在会话输入区输入 INPUT（提示符与输入同一行），返回补全候选，随后清空输入。"
  (goto-char (point-max))
  (insert input)
  (prog1 (pcase-let ((`(,beg ,end ,table . ,_) (agent-session-completion-at-point)))
           (all-completions (buffer-substring-no-properties beg end) table))
    (delete-region (agent-session-input agent-session--current) (point-max))))

(ert-deftest agent-session-test-local-command ()
  "本地命令在 Emacs 中执行，不作为消息发出。"
  (agent-session-test--with-session
   (let ((agent-session-last-settings nil))
     (agent-session-test--type "/model big")
     (should (equal (agent-session-setting agent-session--current :model) "big"))
     (agent-session-test--type "/effort max")
     (should (equal (agent-session-setting agent-session--current :effort) "max"))
     ;; 换到不支持当前强度的模型时，强度恢复默认。
     (agent-session-test--type "/model small")
     (should-not (agent-session-setting agent-session--current :effort))
     (agent-session-test--type "/mode full")
     (should (eq (agent-session-setting agent-session--current :mode) 'full))
     (should-not (agent-session--has-conversation agent-session--current))
     ;; agent 自己的命令照常发出。
     (agent-session-test--type "/compact")
     (should (string-match-p "收到：/compact" (agent-session-test--transcript))))))

(ert-deftest agent-session-test-completion ()
  "/ 补全命令名与参数，@ 不在行首也能触发。"
  (agent-session-test--with-session
   (let ((session agent-session--current))
     (should (member "/model" (agent-session-test--complete session "/mo")))
     (should (member "/compact" (agent-session-test--complete session "/com")))
     (should (equal (sort (agent-session-test--complete session "/model ") #'string<)
                    '("big" "small")))
     (should (equal (agent-session-test--complete session "/effort h") '("high")))
     ;; 第二行行首的 / 同样可以补全。
     (should (member "/model" (agent-session-test--complete session "说明\n/mo"))))))

(ert-deftest agent-session-test-switch-agent ()
  "没有对话时原地切换 agent；有对话后新开会话并带上草稿。"
  (agent-session-test--with-session
   (let ((buffer (current-buffer)))
     (agent-session-select-agent 'test-echo2)
     (should (eq (agent-session-agent agent-session--current) 'test-echo2))
     (should (eq (current-buffer) buffer))
     (agent-session-test--type "hi")
     (goto-char (point-max))
     (insert "草稿")
     (agent-session-select-agent 'test-echo)
     (let ((new (seq-find (lambda (b) (and (not (eq b buffer))
                                           (eq (agent-session-agent
                                                (buffer-local-value 'agent-session--current b))
                                               'test-echo)))
                          (agent-session-buffers))))
       (should new)
       (should (equal (with-current-buffer new
                        (agent-session--input-text agent-session--current))
                      "草稿"))
       (kill-buffer new)))))

(ert-deftest agent-session-test-mode-line ()
  "状态栏显示 agent、模型、推理强度、权限模式与状态。"
  (agent-session-test--with-session
   (let ((agent-session-last-settings nil))
     (should (string-match-p "空闲.*Echo · Small · 推理 默认 · 自动接受编辑"
                             (agent-session-test--mode-line)))
     (agent-session-configure agent-session--current :model "big" :effort "max" :mode 'full)
     (should (string-match-p "Big · 推理 max · 完全访问" (agent-session-test--mode-line)))
     (agent-session-test--type "/plan")
     (should (string-match-p "计划模式" (agent-session-test--mode-line)))
     (agent-session-test--type "/default")
     (should (eq (agent-session-setting agent-session--current :mode) 'full)))))

(ert-deftest agent-session-test-approval ()
  "待确认的请求显示在对话中并反映在状态栏；回答后状态恢复。"
  (agent-session-test--with-session
   (let (answer)
     (agent-session-ask agent-session--current :title "Write：a.txt"
                        :choices '((allow "允许") (deny "拒绝"))
                        :callback (lambda (key) (setq answer key)))
     (should (string-match-p "⚠ Write：a.txt\\(.\\|\n\\)* 允许 +拒绝" (agent-session-test--transcript)))
     (should (string-match-p "⚠ Write：a.txt" (agent-session-test--footer)))
     (should (string-match-p "等待确认" (agent-session-test--mode-line)))
     (agent-session-approve)
     (should (eq answer 'allow))
     (should (string-match-p "→ 允许" (agent-session-test--transcript)))
     (should-not (string-match-p "等待确认" (agent-session-test--mode-line)))
     (should-not (string-match-p "⚠" (agent-session-test--footer))))))

(ert-deftest agent-session-test-list ()
  "会话列表显示进行中的会话及其标题。"
  (agent-session-test--with-session
   (agent-session-test--type "修复输入区的问题")
   (let ((buffer (current-buffer)))
     (with-temp-buffer
       (agent-session-list-mode)
       (setq agent-session-list--root temporary-file-directory)
       (agent-session-list--render)
       (should (string-match-p "进行中\\(.\\|\n\\)*Echo\\(.\\|\n\\)*修复输入区的问题"
                               (buffer-string)))
       (goto-char (point-min))
       (agent-session-list-next)
       (should (eq (plist-get (get-text-property (point) 'agent-session-entry) :buffer) buffer))))))

(ert-deftest agent-session-test-list-debounce ()
  "防抖重绘的回调只重绘一次，不会再次安排自己（曾导致 Emacs 卡死）。"
  (let ((agent-session-list--pending nil)
        (scheduled 0) (refreshed 0))
    (agent-session-list--refresh-soon)
    (let ((timer agent-session-list--pending))
      (should (timerp timer))
      (cancel-timer timer)
      (cl-letf* ((original (symbol-function 'agent-session-list--refresh-soon))
                 ((symbol-function 'agent-session-list--refresh-soon)
                  (lambda () (cl-incf scheduled) (funcall original)))
                 ((symbol-function 'agent-session-list--refresh)
                  (lambda () (cl-incf refreshed))))
        (funcall (timer--function timer))
        (should (= refreshed 1))
        (should (= scheduled 0))
        (should-not agent-session-list--pending)))))

(provide 'agent-session-test)
;;; agent-session-test.el ends here
