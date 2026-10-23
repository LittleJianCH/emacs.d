;;; agent-runs-test.el --- Run summary page tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise local run reports with a stubbed connection and daemon RPC.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'agent-runs)

(defconst agent-runs-test--fixture
  '(:now 1800000000 :range 2592000
    :groups
    [(:profile "coder" :agent "codex" :model "gpt-6"
      :runs 4 :failed 1 :closed 1 :rated 3 :usable 1 :rework 1 :wrong 1
      :verified 2 :duration 133
      :tokens (:input 600000 :cache_read 500000 :cache_write 100000 :output 34000)
      :items
      [(:run 12 :start 1799999800 :end 1799999933 :duration 133
        :handle "helper" :title "修复对齐" :context "fresh" :outcome "ok"
        :tools 8 :reply 400 :tokens (:input 1000 :output 200)
        :effort "medium" :mode "auto"
        :parent (:handle "parent" :agent "claude" :model "sonnet")
        :rating (:verdict "usable" :verified t :note "已运行回归测试" :time 1800000000))
       (:run 11 :start 1799999700 :end 1799999750 :duration 50
        :handle "retry" :title "补充检查" :outcome "failed"
        :errors ["quota" "transport"] :tools 2
        :rating (:verdict "rework" :verified :false :note "遗漏边界"))
       (:run 10 :start 1799999600 :end 1799999640 :duration 40
        :handle "closed" :title "取消任务" :outcome "closed" :tools 0)
       (:run 9 :start 1799999500 :end 1799999520 :duration 20
        :handle "wrong" :title "旧任务" :outcome "ok" :tools 1
        :rating (:verdict "wrong" :verified t :note "结论错误"))])
     (:profile "探索" :agent "claude" :model nil
      :runs 1 :failed 0 :closed 0 :rated 0 :usable 0 :rework 0 :wrong 0
      :verified 0 :duration nil :tokens (:input 50 :output 0) :items [])]))

(defvar agent-runs-test--response nil)
(defvar agent-runs-test--sent nil)

(defmacro agent-runs-test--with-page (&rest body)
  "Run BODY with an isolated report and stubbed daemon."
  (declare (indent 0) (debug t))
  `(let ((evil-mode nil)
         (agent-runs-test--response (copy-tree agent-runs-test--fixture t))
         (agent-runs-test--sent nil))
     (cl-letf (((symbol-function 'agent-emx--local-connection)
                (lambda (callback _error &optional role)
                  (should-not role)
                  (funcall callback 'local)))
               ((symbol-function 'agent-emx--request)
                (lambda (connection method params &optional callback _error)
                  (should (eq connection 'local))
                  (should (equal method "collab/runs"))
                  (push params agent-runs-test--sent)
                  (funcall callback agent-runs-test--response))))
       (with-temp-buffer
         (agent-runs-mode)
         (agent-runs-refresh)
         (save-window-excursion
           (switch-to-buffer (current-buffer))
           (when (bound-and-true-p evil-local-mode) (evil-local-mode -1))
           ,@body)))))

(ert-deftest agent-runs-test-summary-columns-and-pixels ()
  (agent-runs-test--with-page
    (should buffer-read-only)
    (should hl-line-mode)
    (should (eq (keymap-lookup agent-session-command-map "U") #'agent-runs))
    (should (equal agent-runs-test--sent '((:range 2592000))))
    (dolist (text '("子代理评估  30 天" "2 组 · 5 次 · 失败 1 次 · 提前关闭 1 次 · 已评 3 次"
                    "▸ coder" "▸ 探索" "未知模型" "25%" "1 / 1 / 1" "67%"
                    "2 分 13 秒" "1.2M / 34k" "50 / 0"))
      (should (string-match-p (regexp-quote text) (buffer-string))))
    (let* ((group (aref (plist-get agent-runs--snapshot :groups) 0))
           (cells (agent-runs--cells group)))
      (should (equal (nth 1 cells)
                     (concat (agent-session--get 'codex :title) " "
                             (agent-session-model-short-name "gpt-6" "Codex"))))
      (should (equal (seq-drop cells 2)
                     '("4" "25%" "3" "1 / 1 / 1" "67%" "2 分 13 秒" "1.2M / 34k")))
      (should (equal (get-text-property 0 'help-echo (nth 3 cells))
                     "失败 1 次；提前关闭 1 次")))
    (let (alignments)
      (dolist (row agent-runs--rows)
        (goto-char (cdr row))
        (let ((pos (point)) offsets)
          (while (< pos (line-end-position))
            (when-let* ((display (get-text-property pos 'display)))
              (push display offsets))
            (setq pos (next-single-property-change pos 'display nil (line-end-position))))
          (push (nreverse offsets) alignments)))
      (should (= (length (car alignments)) 8))
      (should (equal (car alignments) (cadr alignments)))
      (should (cl-every (lambda (display) (numberp (car (plist-get (cdr display) :align-to))))
                        (car alignments))))))

(ert-deftest agent-runs-test-expand-native-navigation-and-notes ()
  (agent-runs-test--with-page
    (execute-kbd-macro (kbd "TAB"))
    (should (= (length agent-runs--rows) 6))
    (dolist (part '("▾ coder" "#12" "@helper  修复对齐  完成" "工具 8 次"
                    "可用 · 已核实  已运行回归测试" "失败（quota、transport）"
                    "返工 · 未核实  遗漏边界" "提前关闭" "未评" "错误 · 已核实  结论错误"))
      (should (string-match-p (regexp-quote part) (buffer-string))))
    (execute-kbd-macro (kbd "n"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6" 12)))
    (execute-kbd-macro (kbd "C-n C-p p"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6")))
    (execute-kbd-macro (kbd "RET"))
    (should (= (length agent-runs--rows) 2))
    (should-not (string-match-p "已运行回归测试" (buffer-string)))
    (execute-kbd-macro (kbd "n"))
    (should (equal (agent-runs--selection) '("探索" "claude" nil)))
    (execute-kbd-macro (kbd "n p p"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6")))))

(ert-deftest agent-runs-test-cycle-ranges-and-empty-state ()
  (agent-runs-test--with-page
    (setq agent-runs-test--response '(:now 1800000000 :range 0 :groups []))
    (dolist (range '(0 604800 2592000))
      (execute-kbd-macro (kbd "r"))
      (should (equal (car agent-runs-test--sent) (list :range range)))
      (should (= agent-runs--range range))
      (should (string-match-p (agent-runs--range-label) (buffer-string))))
    (should (string-match-p "此范围内暂无子代理运行记录。" (buffer-string)))
    (should (string-match-p "0 组 · 0 次" (buffer-string)))
    (should-not agent-runs--rows)
    (should-error (agent-runs-toggle) :type 'user-error)))

(ert-deftest agent-runs-test-refresh-keeps-group-run-and-expansion ()
  (agent-runs-test--with-page
    (execute-kbd-macro (kbd "TAB n"))
    (setf (plist-get agent-runs-test--response :groups)
          (vconcat (reverse (append (plist-get agent-runs-test--response :groups) nil))))
    (execute-kbd-macro (kbd "g"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6" 12)))
    (should (= (length agent-runs--rows) 6))
    (setf (plist-get (aref (plist-get agent-runs-test--response :groups) 1) :items) [])
    (execute-kbd-macro (kbd "g"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6")))
    (setf (plist-get agent-runs-test--response :groups)
          (vector (aref (plist-get agent-runs-test--response :groups) 0)))
    (execute-kbd-macro (kbd "g"))
    (should (equal (agent-runs--selection) '("探索" "claude" nil)))))

(ert-deftest agent-runs-test-stale-response-and-live-selection ()
  (agent-runs-test--with-page
    (let (replies)
      (cl-letf (((symbol-function 'agent-emx--request)
                 (lambda (_connection _method params callback &optional error)
                   (push (list params callback error) replies))))
        (agent-runs-refresh)
        (execute-kbd-macro (kbd "n"))
        (funcall (cadar replies) agent-runs-test--response)
        (should (equal (agent-runs--selection) '("探索" "claude" nil)))
        (agent-runs-refresh)
        (let ((old (car replies)))
          (agent-runs-cycle-range)
          (should (string-match-p "加载中" (buffer-string)))
          (funcall (cadr old) agent-runs-test--response)
          (funcall (nth 2 old) '(:message "Old failure"))
          (should-not agent-runs--snapshot)
          (should-not agent-runs--error)
          (funcall (cadar replies) '(:groups []))
          (should-not agent-runs--loading)
          (should-not agent-runs--rows))))))

(ert-deftest agent-runs-test-errors-and-delayed-connection ()
  (agent-runs-test--with-page
    (let (ready failure)
      (cl-letf (((symbol-function 'agent-emx--local-connection)
                 (lambda (callback error &rest _)
                   (setq ready callback failure error))))
        (agent-runs-refresh)
        (should agent-runs--loading)
        (funcall failure '(:message "Unavailable"))
        (should-not agent-runs--loading)
        (should (string-match-p "加载失败：Unavailable" (buffer-string)))
        (agent-runs-refresh)
        (funcall ready 'local)
        (should-not agent-runs--error)
        (should-not agent-runs--loading)
        (agent-runs-refresh)
        (let ((old-ready ready))
          (agent-runs-cycle-range)
          (let ((sent (length agent-runs-test--sent)))
            (funcall old-ready 'local)
            (should (= sent (length agent-runs-test--sent)))))))))

(ert-deftest agent-runs-test-callback-after-buffer-killed ()
  (let ((buffer (generate-new-buffer " *runs-dead*")) callback failure)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-emx--local-connection)
                   (lambda (ready _error &rest _) (funcall ready 'local)))
                  ((symbol-function 'agent-emx--request)
                   (lambda (_connection _method _params ready &optional error)
                     (setq callback ready failure error))))
          (with-current-buffer buffer (agent-runs-mode) (agent-runs-refresh))
          (kill-buffer buffer)
          (funcall callback agent-runs-test--fixture)
          (funcall failure '(:message "Unavailable")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest agent-runs-test-formatting-and-palette ()
  (should (equal (mapcar #'agent-runs--duration '(nil :null 0 59 60 133 3601))
                 '("—" "—" "0 秒" "59 秒" "1 分" "2 分 13 秒" "1 时 1 秒")))
  (should (equal (agent-runs--percent 0 0) "—"))
  (should (equal (agent-runs--tokens nil) "0 / 0"))
  (let* ((specs (my/nano-face-specs '(:strong "strong" :popout "popout")))
         (heading (cdr (assq t (cadr (assq 'agent-runs-heading specs)))))
         (rework (cdr (assq t (cadr (assq 'agent-runs-rework specs))))))
    (should (equal (plist-get heading :foreground) "strong"))
    (should (equal (plist-get rework :foreground) "popout"))))

(ert-deftest agent-runs-test-entry-reuses-page-state ()
  (agent-runs-test--with-page
    (let ((agent-runs--buffer (buffer-name)))
      (execute-kbd-macro (kbd "TAB n"))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (agent-runs))
      (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6" 12)))
      (should (= (length agent-runs--rows) 6)))))

(ert-deftest agent-runs-test-help-quit-and-evil-keys ()
  (agent-runs-test--with-page
    (dolist (entry '(("?" . agent-runs-help) ("q" . quit-window)))
      (let (called)
        (cl-letf (((symbol-function (cdr entry))
                   (lambda () (interactive) (setq called t))))
          (execute-kbd-macro (kbd (car entry))))
        (should called)))
    (when (featurep 'evil)
      (evil-local-mode 1)
      (evil-normal-state)
      (unwind-protect
          (dolist (entry '(("g" . agent-runs-refresh) ("r" . agent-runs-cycle-range)
                           ("TAB" . agent-runs-toggle) ("RET" . agent-runs-toggle)
                           ("j" . agent-runs-next-row) ("k" . agent-runs-previous-row)
                           ("n" . agent-runs-next-row) ("p" . agent-runs-previous-row)
                           ("C-n" . agent-runs-next-row) ("C-p" . agent-runs-previous-row)
                           ("?" . agent-runs-help) ("q" . quit-window)))
            (should (eq (key-binding (kbd (car entry))) (cdr entry))))
        (evil-local-mode -1)))))

(provide 'agent-runs-test)
;;; agent-runs-test.el ends here
