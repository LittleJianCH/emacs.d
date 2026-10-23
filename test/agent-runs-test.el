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
      :runs 4 :failed 1 :closed 1 :rated 3 :score 7.0 :duration 133
      :tokens (:input 600000 :cache_read 500000 :cache_write 100000 :output 34000))
     (:profile "探索" :agent "claude" :model nil
      :runs 2 :failed 0 :closed 0 :rated 1 :score 9.0 :duration nil
      :tokens (:input 50 :output 0))]))

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
    (dolist (text '("子代理评估  30 天"
                    "2 组 · 6 次 · 失败 1 次 · 提前关闭 1 次 · 已评 4 次 · 均分 7.5"
                    "coder" "探索" "未知模型" "g 刷新 · r 范围 · n/p 移动"
                    "25%" "7.0" "9.0" "0%" "2 分 13 秒" "1.2M / 34k" "50 / 0"))
      (should (string-match-p (regexp-quote text) (buffer-string))))
    (let* ((group (aref (plist-get agent-runs--snapshot :groups) 0))
           (cells (agent-runs--cells group)))
      (should (equal (nth 1 cells)
                     (concat (agent-session--get 'codex :title) " "
                             (agent-session-model-short-name "gpt-6" "Codex"))))
      (should (equal (seq-drop cells 2)
                     '("4" "25%" "3" "7.0" "2 分 13 秒" "1.2M / 34k")))
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
      (should (= (length (car alignments)) 7))
      (should (equal (car alignments) (cadr alignments)))
      (should (cl-every (lambda (display) (numberp (car (plist-get (cdr display) :align-to))))
                        (car alignments))))))

(ert-deftest agent-runs-test-navigation-without-expansion ()
  (agent-runs-test--with-page
    (should-not (fboundp 'agent-runs-toggle))
    (should-not (boundp 'agent-runs--expanded))
    (dolist (key '("TAB" "<tab>" "RET"))
      (should-not (lookup-key agent-runs-mode-map (kbd key))))
    (should (= (length agent-runs--rows) 2))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6")))
    (execute-kbd-macro (kbd "n"))
    (should (equal (agent-runs--selection) '("探索" "claude" nil)))
    (execute-kbd-macro (kbd "n"))
    (should (equal (agent-runs--selection) '("探索" "claude" nil)))
    (execute-kbd-macro (kbd "p"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6")))
    (execute-kbd-macro (kbd "C-n C-p"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6")))
    (execute-kbd-macro (kbd "p"))
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
    (should (string-match-p
             "0 组 · 0 次 · 失败 0 次 · 提前关闭 0 次 · 已评 0 次 · 均分 —"
             (buffer-string)))
    (should-not agent-runs--rows)))

(ert-deftest agent-runs-test-refresh-keeps-group-selection ()
  (agent-runs-test--with-page
    (execute-kbd-macro (kbd "n"))
    (should (equal (agent-runs--selection) '("探索" "claude" nil)))
    (setf (plist-get agent-runs-test--response :groups)
          (vconcat (reverse (append (plist-get agent-runs-test--response :groups) nil))))
    (execute-kbd-macro (kbd "g"))
    (should (equal (agent-runs--selection) '("探索" "claude" nil)))
    (should (= (length agent-runs--rows) 2))
    (setf (plist-get agent-runs-test--response :groups)
          (vector (aref (plist-get agent-runs-test--response :groups) 1)))
    (execute-kbd-macro (kbd "g"))
    (should (equal (agent-runs--selection) '("coder" "codex" "gpt-6")))
    (setf (plist-get agent-runs-test--response :groups) [])
    (execute-kbd-macro (kbd "g"))
    (should-not agent-runs--rows)))

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
  (should (equal (mapcar #'agent-runs--score '(nil :null 0 6.74 10))
                 '("—" "—" "0.0" "6.7" "10.0")))
  (should (equal (agent-runs--score
                  (agent-runs--mean '((:score 8 :rated 2) (:score 5 :rated 1))))
                 "7.0"))
  (should-not (agent-runs--mean '((:score nil :rated 3) (:score 9 :rated 0))))
  (should (equal (agent-runs--percent 0 0) "—"))
  (should (equal (agent-runs--tokens nil) "0 / 0"))
  (let* ((specs (my/nano-face-specs '(:strong "strong" :popout "popout")))
         (heading (cdr (assq t (cadr (assq 'agent-runs-heading specs))))))
    (should (equal (plist-get heading :foreground) "strong"))
    (should-not (assq 'agent-runs-rework specs))))

(ert-deftest agent-runs-test-entry-reuses-page-state ()
  (agent-runs-test--with-page
    (let ((agent-runs--buffer (buffer-name)))
      (execute-kbd-macro (kbd "n"))
      (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
        (agent-runs))
      (should (equal (agent-runs--selection) '("探索" "claude" nil)))
      (should (= (length agent-runs--rows) 2)))))

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
          (dolist (entry '(("g r" . agent-runs-refresh) ("r" . agent-runs-cycle-range)
                           ("j" . agent-runs-next-row) ("k" . agent-runs-previous-row)
                           ("n" . agent-runs-next-row) ("p" . agent-runs-previous-row)
                           ("C-n" . agent-runs-next-row) ("C-p" . agent-runs-previous-row)
                           ("?" . agent-runs-help) ("q" . quit-window)))
            (should (eq (key-binding (kbd (car entry))) (cdr entry))))
        (evil-local-mode -1)))))

(provide 'agent-runs-test)
;;; agent-runs-test.el ends here
