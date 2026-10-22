;;; agent-profiles-test.el --- Profile page tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Exercise the editor page with a fake daemon; never write real config.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'agent-profiles)

(defconst agent-profiles-test--fixture
  '(:quotaSkip 0.9
    :profiles
    [(:name "coder" :cost "medium" :description "Implementation work"
      :disabled :false
      :candidates
      [(:agent "codex" :model "gpt-6" :effort "medium" :disabled :false
        :available t :strained "5h quota 92% used" :quotaSkip 0.97)
       (:agent "claude" :model "sonnet" :disabled :false
        :available :false :unavailable "CLI not found" :quotaSkip 0.9)
       (:agent "pi" :model "flash" :disabled t :available t :quotaSkip 0.9)])
     (:name "reviewer" :cost "high" :description "Review work" :disabled :false
      :candidates
      [(:agent "codex" :model "gpt-6" :effort "high" :disabled :false
        :available t :quotaSkip 0.97)])]))

(defvar agent-profiles-test--sent nil)
(defvar agent-profiles-test--response nil)

(defmacro agent-profiles-test--with-page (&rest body)
  "Run BODY with an isolated page and a synchronous daemon stub."
  (declare (indent 0) (debug t))
  `(let ((agent-profiles-test--sent nil)
         (agent-profiles-test--response
          (copy-tree agent-profiles-test--fixture t))
         (agent-emx-config--value
          '(:collab (:disabled ["coder:pi/flash" "other:claude"] :quotaSkip 0.9)
            :agents (:codex (:quotaSkip 0.97)))))
     (cl-letf (((symbol-function 'agent-emx--local-connection)
                (lambda (callback _error-callback &optional role)
                  (should-not role)
                  (funcall callback 'local)))
               ((symbol-function 'agent-emx--request)
                (lambda (connection method params &optional callback _error-callback)
                  (should (eq connection 'local))
                  (push (cons method params) agent-profiles-test--sent)
                  (pcase method
                    ("collab/profiles"
                     (should (hash-table-p params))
                     (should (= (hash-table-count params) 0))
                     (funcall callback agent-profiles-test--response))
                    ("config/set"
                     (funcall callback (list :config agent-emx-config--value)))
                    (_ (ert-fail (format "Unexpected request: %s" method)))))))
       (with-temp-buffer
         (agent-profiles-mode)
         (agent-profiles-refresh)
         ,@body))))

(defun agent-profiles-test--write ()
  "Return the latest config/set request params."
  (cdr (assoc "config/set" agent-profiles-test--sent)))

(ert-deftest agent-profiles-test-render ()
  (agent-profiles-test--with-page
    (let ((text (buffer-string)))
      (dolist (part '("子代理配置" "coder · 成本：medium · 已启用"
                      "reviewer · 成本：high" "Implementation work"
                      "codex · gpt-6 (medium)" "可用" "已停用"
                      "余量紧张：5h quota 92% used" "不可用：CLI not found"
                      "全局：已用 90% 时跳过" "codex：已用 97% 时跳过（单独设置）"
                      "claude：已用 90% 时跳过（继承全局）"))
        (should (string-match-p (regexp-quote part) text)))
      ;; An agent shared by several profiles gets one threshold row.
      (should (= 1 (how-many "^codex：" (point-min) (point-max))))
      (should buffer-read-only)
      (should (button-at (progn (goto-char (point-min))
                                (search-forward "停用") (- (point) 2)))))))

(ert-deftest agent-profiles-test-disabled-profile ()
  (agent-profiles-test--with-page
    (setq agent-profiles--snapshot
          '(:quotaSkip 0.9 :profiles
            [(:name "coder" :cost "medium" :description "Work" :disabled t
              :candidates [(:agent "codex" :model "gpt-6" :disabled :false
                            :available t :quotaSkip 0.9)])]))
    (agent-profiles--render)
    (should (string-match-p "coder · 成本：medium · 已停用" (buffer-string)))
    (should (string-match-p "codex · gpt-6  已停用" (buffer-string)))
    ;; Off only because its candidates are: the profile button enables nothing
    ;; it did not disable, so it still offers to disable the profile itself.
    (goto-char (point-min))
    (search-forward "已停用  ")
    (should (equal (button-label (button-at (point))) "停用"))))

(ert-deftest agent-profiles-test-candidate-without-model ()
  (agent-profiles-test--with-page
    (setq agent-profiles--snapshot
          '(:quotaSkip 1 :profiles
            [(:name "coder" :cost "medium" :description "Work" :disabled :false
              :candidates [(:agent "codex" :model :null :disabled :false
                            :available t :quotaSkip 1)])]))
    (agent-profiles--render)
    (should (string-match-p "codex · 默认模型  可用" (buffer-string)))
    (should (string-match-p "全局：用到耗尽" (buffer-string)))
    (goto-char (point-min))
    (search-forward "默认模型  可用  ")
    (push-button (point))
    (should (equal (plist-get (agent-profiles-test--write) :value)
                   ["coder:pi/flash" "other:claude" "coder:codex"]))))

(ert-deftest agent-profiles-test-toggle-candidate-preserves-other-entries ()
  (agent-profiles-test--with-page
    (agent-profiles--toggle "coder:codex/gpt-6")
    (should (equal (agent-profiles-test--write)
                   '(:path ["collab" "disabled"]
                     :value ["coder:pi/flash" "other:claude" "coder:codex/gpt-6"])))
    (should (equal (caar agent-profiles-test--sent) "collab/profiles"))
    ;; The returned config, rather than a stale page snapshot, drives the next edit.
    (setq agent-emx-config--value
          '(:collab (:disabled ["coder:codex/gpt-6" "reviewer:codex/gpt-6"])))
    (agent-profiles--toggle "coder:codex/gpt-6")
    (should (equal (plist-get (agent-profiles-test--write) :value)
                   ["reviewer:codex/gpt-6"]))))

(ert-deftest agent-profiles-test-toggle-whole-profile-and-empty-array ()
  (agent-profiles-test--with-page
    (agent-profiles--toggle "reviewer")
    (should (equal (plist-get (agent-profiles-test--write) :value)
                   ["coder:pi/flash" "other:claude" "reviewer"]))
    (setq agent-emx-config--value '(:collab (:disabled ["reviewer"])))
    (agent-profiles--toggle "reviewer")
    (should (equal (agent-profiles-test--write)
                   '(:path ["collab" "disabled"] :value [])))))

(ert-deftest agent-profiles-test-threshold-edit-remove-and-global ()
  (agent-profiles-test--with-page
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "92.5")))
      (agent-profiles--edit-threshold "codex"))
    (should (equal (agent-profiles-test--write)
                   '(:path ["agents" "codex" "quotaSkip"] :value 0.925)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  ")))
      (agent-profiles--edit-threshold "codex"))
    (should (equal (agent-profiles-test--write)
                   '(:path ["agents" "codex" "quotaSkip"] :value nil)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "100")))
      (agent-profiles--edit-threshold))
    (should (equal (agent-profiles-test--write)
                   '(:path ["collab" "quotaSkip"] :value 1.0)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "0")))
      (agent-profiles--edit-threshold "codex"))
    (should (= (plist-get (agent-profiles-test--write) :value) 0))))

(ert-deftest agent-profiles-test-reject-invalid-threshold ()
  (agent-profiles-test--with-page
    (dolist (input '("-1" "101" "oops" "NaN" "1e2" ""))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) input)))
        (should-error (agent-profiles--edit-threshold) :type 'user-error)))
    (should-not (agent-profiles-test--write))))

(ert-deftest agent-profiles-test-quick-zero-remaining ()
  (agent-profiles-test--with-page
    (goto-char (point-min))
    (search-forward "codex：")
    (search-forward "用到耗尽")
    (push-button (match-beginning 0))
    (should (equal (agent-profiles-test--write)
                   '(:path ["agents" "codex" "quotaSkip"] :value 1)))))

(ert-deftest agent-profiles-test-write-returned-config-and-errors ()
  (agent-profiles-test--with-page
    (let ((returned '(:collab (:disabled ["coder"])))
          captured-message)
      (cl-letf (((symbol-function 'agent-emx--request)
                 (lambda (_connection method _params &optional callback error-callback)
                   (pcase method
                     ("config/set" (funcall callback (list :config returned)))
                     ("collab/profiles"
                      (funcall error-callback '(:message "Unsupported method"))))))
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq captured-message (apply #'format format args)))))
        (agent-profiles--toggle "coder")
        (should (equal agent-emx-config--value returned))
        (should-not agent-profiles--writing)
        (should (equal captured-message
                       "子代理配置操作失败：Unsupported method")))
      (cl-letf (((symbol-function 'agent-emx--request)
                 (lambda (_connection _method _params &optional _callback error-callback)
                   (funcall error-callback '(:message "Invalid config"))))
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq captured-message (apply #'format format args)))))
        (agent-profiles--toggle "coder")
        (should-not agent-profiles--writing)
        (should (equal agent-emx-config--value returned))
        (should (equal captured-message "子代理配置操作失败：Invalid config"))))))

(ert-deftest agent-profiles-test-native-keys ()
  (agent-profiles-test--with-page
    (let ((my/use-evil nil))
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (when (bound-and-true-p evil-local-mode) (evil-local-mode -1))
        (should (eq (key-binding (kbd "C-c a p")) #'agent-profiles))
        (goto-char (point-min))
        (execute-kbd-macro (kbd "TAB RET"))
        (should (equal (plist-get (agent-profiles-test--write) :value)
                       ["coder:pi/flash" "other:claude" "coder"]))
        (let ((before (length agent-profiles-test--sent)))
          (execute-kbd-macro (kbd "g"))
          (should (= (length agent-profiles-test--sent) (1+ before))))
        (let (quit)
          (cl-letf (((symbol-function 'quit-window)
                     (lambda (&rest _) (interactive) (setq quit t))))
            (execute-kbd-macro (kbd "q")))
          (should quit))))))

(provide 'agent-profiles-test)
;;; agent-profiles-test.el ends here
