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
		       :disabled :false :overridden t
		       :candidates
		       [(:agent "codex" :model "gpt-6" :effort "medium" :mode "auto" :disabled :false :disabledBy []
				:available t :strained "5h quota 92% used" :quotaSkip 0.97)
			(:agent "claude" :model "sonnet" :disabled :false :disabledBy []
				:available :false :unavailable "CLI not found" :quotaSkip 0.9)
			(:agent "pi" :model "flash" :disabled t :disabledBy ["coder:pi/flash"] :available t :quotaSkip 0.9)])
		(:name "reviewer" :cost "high" :description "Review work" :disabled :false
		       :candidates
		       [(:agent "codex" :model "gpt-6" :effort "high" :disabled :false :disabledBy []
				:available t :quotaSkip 0.97)])]))

(defvar agent-profiles-test--sent nil)
(defvar agent-profiles-test--response nil)

(defmacro agent-profiles-test--with-page (&rest body)
  "Run BODY with an isolated page and a synchronous daemon stub."
  (declare (indent 0) (debug t))
  `(let ((evil-mode nil)
         (agent-profiles-test--sent nil)
         (agent-profiles-test--response
          (copy-tree agent-profiles-test--fixture t))
         (agent-emx-config--value
          '(:collab (:disabled ["coder:pi/flash" "other:claude"] :quotaSkip 0.9)
		    :agents (:codex (:quotaSkip 0.97) :claude (:title "Claude")
				    :pi (:title "Pi"))
		    :profiles (:coder (:candidates [(:agent "pi" :model "opencode-go/grok")])))))
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
                     (should (equal params (list :root agent-profiles--root)))
                     (funcall callback agent-profiles-test--response))
                    ("agents/models"
                     (funcall callback '(:models [(:id "opencode-go/grok" :label "Grok")])))
                    ((or "config/set" "collab/disable")
                     (funcall callback (list :config agent-emx-config--value)))
                    (_ (ert-fail (format "Unexpected request: %s" method)))))))
	      (with-temp-buffer
		(agent-profiles-mode)
		(setq agent-profiles--root "/test/project/")
		(agent-profiles-refresh)
		(save-window-excursion
		  (switch-to-buffer (current-buffer))
		  (when (bound-and-true-p evil-local-mode) (evil-local-mode -1))
		  ,@body)))))

(defun agent-profiles-test--write ()
  "Return the latest config/set request params."
  (cdr (assoc "config/set" agent-profiles-test--sent)))

(defun agent-profiles-test--keys (keys &optional id)
  "Execute native KEYS on logical row ID, if supplied."
  (when id
    (agent-profiles--goto id)
    (should (equal (agent-profiles--selection) id)))
  (execute-kbd-macro (kbd keys)))

(ert-deftest agent-profiles-test-render ()
  (agent-profiles-test--with-page
   (let ((text (buffer-string)))
     (dolist (part '("子代理配置  /test/project/" "? 帮助" "coder*" "reviewer"
                     "Profile" "成本" "Agent" "模型" "Effort" "状态"
                     "codex gpt-6 medium" "可用" "已停用（coder:pi/flash）"
                     "余量紧张：5h quota 92% used" "不可用：CLI not found"
                     "全局 已用 90% 时跳过" "codex 已用 97% 时跳过 单独设置"
                     "claude 已用 90% 时跳过 继承全局"))
       (should (string-match-p (regexp-quote part) text)))
     (should-not (string-match-p "Implementation work" text))
     (should (= (length agent-profiles--rows) 8))
     (should (= 1 (how-many "^codex " (point-min) (point-max))))
     (should buffer-read-only)
     (should hl-line-mode)
     (should-not (text-property-any (point-min) (point-max) 'button t))
     (dolist (entry '(((candidate "coder" 0) . warning)
                      ((candidate "coder" 1) . agent-session-error)
                      ((candidate "coder" 2) . agent-session-dim)
                      ((candidate "reviewer" 0) . agent-session-ok)))
       (agent-profiles--goto (car entry))
       (let ((status (nth 5 (plist-get (agent-profiles--row) :cells))))
         (should (eq (get-text-property 0 'face status) (cdr entry)))))
     (let (description)
       (cl-letf (((symbol-function 'message)
                  (lambda (format &rest args)
                    (setq description (apply #'format format args)))))
         (agent-profiles--describe))
       (should (equal description "Review work"))))))

(ert-deftest agent-profiles-test-pixel-columns-and-cjk ()
  (agent-profiles-test--with-page
   (setf (plist-get (aref (plist-get agent-profiles--snapshot :profiles) 1) :name)
         "审查者")
   (setf (plist-get (aref (plist-get (aref (plist-get agent-profiles--snapshot :profiles) 1)
                                     :candidates) 0) :model) "中文模型 / long-model")
   (agent-profiles--render)
   (let (reference)
     (dolist (id '((candidate "coder" 0) (candidate "coder" 1)
                   (candidate "审查者" 0)))
       (agent-profiles--goto id)
       (let ((start (point)) widths)
         (dotimes (_ 5)
           (let* ((end (next-single-property-change start 'vtable-column))
                  (padding (get-text-property (1- end) 'display))
                  (text (buffer-substring start (1- end))))
             (should (eq (car padding) 'space))
             (push (+ (string-pixel-width text (current-buffer))
                      (car (plist-get (cdr padding) :width))) widths)
             (setq start end)))
         (if reference (should (equal widths reference))
           (setq reference widths)))))))

(ert-deftest agent-profiles-test-navigation-and-refresh ()
  (agent-profiles-test--with-page
   (should (eq (key-binding (kbd "C-c a p")) #'agent-profiles))
   (should (equal (agent-profiles--selection) '(candidate "coder" 0)))
   (dolist (keys '("n" "p" "C-n" "C-p"))
     (agent-profiles-test--keys keys)
     (should (equal (agent-profiles--selection)
                    (list 'candidate "coder" (if (member keys '("n" "C-n")) 1 0)))))
   (agent-profiles-test--keys "TAB")
   (should (equal (agent-profiles--selection) '(candidate "reviewer" 0)))
   (agent-profiles-test--keys "<backtab>")
   (should (equal (agent-profiles--selection) '(candidate "coder" 0)))
   (agent-profiles-test--keys "n TAB")
   (should (equal (agent-profiles--selection) '(candidate "reviewer" 0)))
    (agent-profiles-test--keys "S-TAB")
    (should (equal (agent-profiles--selection) '(candidate "coder" 0)))
    (agent-profiles-test--keys "TAB")
   (agent-profiles-test--keys "n")
   (should (equal (agent-profiles--selection) '(threshold "codex")))
   ;; Heading length changes must not affect logical selection.
   (setq agent-profiles--root "/test/a/longer/project/path/")
   (let ((before (length agent-profiles-test--sent)))
     (agent-profiles-test--keys "g")
     (should (= (length agent-profiles-test--sent) (1+ before)))
     (should (equal (agent-profiles--selection) '(threshold "codex"))))
   (agent-profiles-test--keys "p")
   (should (equal (agent-profiles--selection) '(candidate "reviewer" 0)))
   (let (quit)
     (cl-letf (((symbol-function 'quit-window)
                (lambda (&rest _) (interactive) (setq quit t))))
       (agent-profiles-test--keys "q"))
     (should quit))
   (save-window-excursion
     (agent-profiles-test--keys "?")
     (with-current-buffer "*子代理配置帮助*"
       (dolist (key '("M-p" "M-n" "SPC" "X" "RET" "e" "a" "D" "R" "z" "g" "q" "?" "J" "K" "gr"))
         (should (string-match-p (regexp-quote key) (buffer-string)))))
     (kill-buffer "*子代理配置帮助*"))))

(ert-deftest agent-profiles-test-toggle-keys-and-stale-cache ()
  (agent-profiles-test--with-page
   (setq agent-emx-config--value '(:collab (:disabled [])))
   (dolist (key '("SPC" "x"))
     (agent-profiles-test--keys key '(candidate "coder" 2))
     (should (equal (cdr (assoc "collab/disable" agent-profiles-test--sent))
                    '(:profile "coder" :disabled :false :candidate 2)))
     (should (equal (agent-profiles--selection) '(candidate "coder" 2))))
   (agent-profiles-test--keys "X" '(candidate "reviewer" 0))
   (should (equal (cdr (assoc "collab/disable" agent-profiles-test--sent))
                  '(:profile "reviewer" :disabled t)))
   (should-not (agent-profiles-test--write))
   (should (equal (caar agent-profiles-test--sent) "collab/profiles"))))

(ert-deftest agent-profiles-test-disabled-profile-reasons-and-default-model ()
  (agent-profiles-test--with-page
   (setq agent-profiles--snapshot
         '(:quotaSkip 1 :profiles
		      [(:name "coder" :cost "medium" :disabled t
			      :candidates [(:agent "codex" :model :null :disabled t
						   :disabledBy ["coder:codex" "coder:codex/gpt-6"]
						   :available t :quotaSkip 1)])]))
   (agent-profiles--render)
   (should (string-match-p "coder ⊘" (buffer-string)))
   (should (string-match-p "默认模型" (buffer-string)))
   (should (string-match-p "已停用（coder:codex、coder:codex/gpt-6）"
                           (buffer-string)))
   (should (string-match-p "全局 用到耗尽" (buffer-string)))
   (let ((cells (plist-get (agent-profiles--row) :cells)))
     (dolist (cell (seq-filter (lambda (s) (> (length s) 0)) cells))
       (should (eq (get-text-property 0 'face cell) 'agent-session-dim))))
   ;; Disabled only by candidates: X must add the whole-profile token.
   (agent-profiles-test--keys "X")
   (should (equal (cdr (assoc "collab/disable" agent-profiles-test--sent))
                  '(:profile "coder" :disabled t)))
   (setq agent-profiles--snapshot
         '(:quotaSkip 1 :profiles
		      [(:name "coder" :cost "medium" :disabled t
			      :candidates [(:agent "codex" :model :null :disabled t
						   :disabledBy ["coder"] :available t :quotaSkip 1)])]))
   (agent-profiles--render)
   (agent-profiles-test--keys "X")
   (should (equal (cdr (assoc "collab/disable" agent-profiles-test--sent))
                  '(:profile "coder" :disabled :false)))
   (agent-profiles--render)
   (agent-profiles-test--keys "x")
   (should (equal (cdr (assoc "collab/disable" agent-profiles-test--sent))
                  '(:profile "coder" :disabled t :candidate 0)))))

(ert-deftest agent-profiles-test-threshold-keys ()
  (agent-profiles-test--with-page
   (dolist (key '("e" "RET"))
     (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "92.5")))
       (agent-profiles-test--keys key '(threshold "codex")))
     (should (equal (agent-profiles-test--write)
                    '(:path ["agents" "codex" "quotaSkip"] :value 0.925)))
     (should (equal (agent-profiles--selection) '(threshold "codex"))))
   (agent-profiles-test--keys "z")
   (should (equal (agent-profiles-test--write)
                  '(:path ["agents" "codex" "quotaSkip"] :value 1)))
   (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "85")))
     (agent-profiles-test--keys "RET" '(threshold nil)))
   (should (equal (agent-profiles-test--write)
                  '(:path ["collab" "quotaSkip"] :value 0.85)))
   (should (equal (agent-profiles--selection) '(threshold nil)))
   (agent-profiles-test--keys "z")
   (should (equal (agent-profiles-test--write)
                  '(:path ["collab" "quotaSkip"] :value 1)))))

(ert-deftest agent-profiles-test-default-model-toggle-and-row-guards ()
  (agent-profiles-test--with-page
    (setf (plist-get
           (aref (plist-get (aref (plist-get agent-profiles--snapshot :profiles) 0)
                               :candidates) 0) :model) :null)
    (agent-profiles--render)
    (should (string-match-p "默认模型" (buffer-string)))
    (agent-profiles-test--keys "x")
    (should (equal (cdr (assoc "collab/disable" agent-profiles-test--sent))
                   '(:profile "coder" :disabled t :candidate 0)))
    (should-not (agent-profiles-test--write))
    (should-error (agent-profiles-exhaust) :type 'user-error)
    (agent-profiles--goto '(threshold "codex"))
    (dolist (command '(agent-profiles-toggle agent-profiles-toggle-profile
                       agent-profiles-move-down agent-profiles-add
                       agent-profiles-delete agent-profiles-restore))
      (should-error (funcall command) :type 'user-error))))

(ert-deftest agent-profiles-test-move-keys-and-preserve-fields ()
  (agent-profiles-test--with-page
   (let* ((original (vconcat (agent-profiles--candidates "coder")))
          (first (aref original 0)) (second (aref original 1))
          (third (aref original 2)))
     (dolist (key '("M-<down>" "M-n"))
       (agent-profiles-test--keys key '(candidate "coder" 0))
       (should (equal (agent-profiles-test--write)
                      (list :path ["profiles" "coder" "candidates"]
                            :value (vector second first third))))
       (should (equal (agent-profiles--selection) '(candidate "coder" 1))))
     (dolist (key '("M-<up>" "M-p"))
       (agent-profiles-test--keys key '(candidate "coder" 1))
       (should (equal (plist-get (agent-profiles-test--write) :value)
                      (vector second first third)))
       (should (equal (agent-profiles--selection) '(candidate "coder" 0))))
     (should (equal original (vconcat (agent-profiles--candidates "coder"))))
     (agent-profiles--goto '(candidate "coder" 0))
     (should-error (agent-profiles-move-up) :type 'user-error)
     (agent-profiles--goto '(candidate "coder" 2))
     (should-error (agent-profiles-move-down) :type 'user-error))))

(ert-deftest agent-profiles-test-delete-restore-confirmations-and-last-candidate ()
  (agent-profiles-test--with-page
   (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
     (agent-profiles-test--keys "D R")
     (should-not (agent-profiles-test--write)))
   (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
     (agent-profiles-test--keys "D" '(candidate "coder" 1))
     (should (equal (plist-get (agent-profiles-test--write) :value)
                    [(:agent "codex" :model "gpt-6" :effort "medium" :mode "auto")
                     (:agent "pi" :model "flash")]))
     (should (equal (agent-profiles--selection) '(candidate "coder" 1)))
     (agent-profiles-test--keys "R")
     (should (equal (agent-profiles-test--write)
                    '(:path ["profiles" "coder"] :value nil)))
     (setq agent-profiles-test--sent nil)
     (should-error (agent-profiles-test--keys "D" '(candidate "reviewer" 0))
                   :type 'user-error)
     (should-not (agent-profiles-test--write)))))

(ert-deftest agent-profiles-test-edit-model-agent-effort-and-add-after-row ()
  (agent-profiles-test--with-page
   (dolist (key '("RET" "e"))
     (let ((answers '("pi" "opencode-go/grok")))
       (cl-letf (((symbol-function 'completing-read)
                  (lambda (_prompt collection _predicate require-match &rest _)
                    (if (equal (car answers) "pi")
                        (progn (should require-match)
                               (should (equal collection '("codex" "claude" "pi"))))
                      (should-not require-match)
                      (should (member "opencode-go/grok" collection)))
                    (pop answers)))
                 ((symbol-function 'read-string) (lambda (&rest _) "high")))
         (agent-profiles-test--keys key '(candidate "coder" 0))))
     (should (equal (cdr (assoc "agents/models" agent-profiles-test--sent)) '(:agent "pi")))
     (should (equal (agent-profiles-test--write)
                    '(:path ["profiles" "coder" "candidates"]
			    :value [(:agent "pi" :model "opencode-go/grok" :effort "high" :mode "auto")
				    (:agent "claude" :model "sonnet")
				    (:agent "pi" :model "flash")])))
     (should (equal (agent-profiles--selection) '(candidate "coder" 0))))
   (let ((answers '("claude" "a-new-free-text-model")))
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) (pop answers)))
               ((symbol-function 'read-string) (lambda (&rest _) "")))
       (agent-profiles-test--keys "a" '(candidate "coder" 0))))
   (should (equal (plist-get (agent-profiles-test--write) :value)
                  [(:agent "codex" :model "gpt-6" :effort "medium" :mode "auto")
                   (:agent "claude" :model "a-new-free-text-model")
                   (:agent "claude" :model "sonnet") (:agent "pi" :model "flash")]))
   (should (equal (agent-profiles--selection) '(candidate "coder" 1)))))

(ert-deftest agent-profiles-test-clear-optionals-and-model-fallback ()
  (agent-profiles-test--with-page
   (let ((answers '("pi" ""))
         (request (symbol-function 'agent-emx--request)))
     (cl-letf (((symbol-function 'agent-emx--request)
                (lambda (connection method params &optional callback error-callback)
                  (if (equal method "agents/models")
                      (funcall error-callback '(:message "Unavailable"))
                    (funcall request connection method params callback error-callback))))
               ((symbol-function 'completing-read)
                (lambda (_prompt collection _predicate require-match &rest _)
                  (when (= (length answers) 1)
                    (should-not require-match)
                    (should (equal collection '("opencode-go/grok"))))
                  (pop answers)))
               ((symbol-function 'read-string) (lambda (&rest _) "")))
       (agent-profiles-test--keys "e")))
   (should (equal (aref (plist-get (agent-profiles-test--write) :value) 0)
                  '(:agent "pi" :mode "auto")))))

(ert-deftest agent-profiles-test-async-restoration-and-stale-refresh ()
  (agent-profiles-test--with-page
   (let ((request (symbol-function 'agent-emx--request)) replies)
     (agent-profiles--goto '(candidate "coder" 2))
     (cl-letf (((symbol-function 'agent-emx--request)
                (lambda (connection method params &optional callback error-callback)
                  (if (equal method "collab/profiles") (push callback replies)
                    (funcall request connection method params callback error-callback)))))
       (agent-profiles-test--keys "x")
       (agent-profiles--goto '(threshold "claude"))
       (agent-profiles-test--keys "g"))
     (setq agent-profiles--root "/changed/header/length/")
     (funcall (car replies) agent-profiles-test--response)
     (should (equal (agent-profiles--selection) '(threshold "claude")))
     (funcall (cadr replies) agent-profiles-test--response)
     (should (equal (agent-profiles--selection) '(threshold "claude"))))
   ;; Shrinking a restored group clamps to its remaining last candidate.
   (agent-profiles--goto '(candidate "coder" 2))
   (setf (plist-get (aref (plist-get agent-profiles-test--response :profiles) 0) :candidates)
         [(:agent "pi" :available t :quotaSkip 0.9)])
   (agent-profiles-test--keys "g")
   (should (equal (agent-profiles--selection) '(candidate "coder" 0)))))

(ert-deftest agent-profiles-test-follows-moved-row-and-clamps-deletion ()
  (agent-profiles-test--with-page
   (let ((request (symbol-function 'agent-emx--request)))
     (cl-letf (((symbol-function 'agent-emx--request)
                (lambda (connection method params &optional callback error-callback)
                  (when (and (equal method "config/set")
                             (equal (plist-get params :path)
                                    ["profiles" "coder" "candidates"]))
                    (setf (plist-get
                           (aref (plist-get agent-profiles-test--response :profiles) 0)
                           :candidates)
                          (vconcat
                           (mapcar (lambda (candidate)
                                     (append candidate '(:available t :quotaSkip 0.9)))
                                   (append (plist-get params :value) nil)))))
                  (funcall request connection method params callback error-callback)))
               ((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
       (agent-profiles-test--keys "M-n")
       (should (equal (agent-profiles--selection) '(candidate "coder" 1)))
       (should (equal (plist-get (plist-get (agent-profiles--row) :candidate) :agent)
                      "codex"))
       (agent-profiles-test--keys "g M-p")
       (should (equal (agent-profiles--selection) '(candidate "coder" 0)))
       (should (equal (plist-get (plist-get (agent-profiles--row) :candidate) :agent)
                      "codex"))
       (agent-profiles-test--keys "D" '(candidate "coder" 2))
       (should (equal (agent-profiles--selection) '(candidate "coder" 1)))
       (should (equal (plist-get (plist-get (agent-profiles--row) :candidate) :agent)
                      "claude"))))))

(ert-deftest agent-profiles-test-evil-bindings-override-operators ()
  (skip-unless (featurep 'evil))
  (agent-profiles-test--with-page
   (evil-local-mode 1)
   (evil-normal-state)
   (dolist (entry '(("J" . agent-profiles-move-down) ("K" . agent-profiles-move-up)
                    ("j" . agent-profiles-next-row) ("k" . agent-profiles-previous-row)
                    ("C-n" . agent-profiles-next-row) ("C-p" . agent-profiles-previous-row)
                    ("TAB" . agent-profiles-next-group)
                    ("S-TAB" . agent-profiles-previous-group)
                    ("<backtab>" . agent-profiles-previous-group)
                    ("x" . agent-profiles-toggle) ("SPC" . agent-profiles-toggle)
                    ("X" . agent-profiles-toggle-profile) ("e" . agent-profiles-edit)
                    ("RET" . agent-profiles-edit) ("a" . agent-profiles-add)
                    ("D" . agent-profiles-delete) ("R" . agent-profiles-restore)
                    ("z" . agent-profiles-exhaust) ("?" . agent-profiles-help)
                    ("gr" . agent-profiles-refresh) ("q" . quit-window)))
     (let (called)
       (should (eq (key-binding (kbd (car entry))) (cdr entry)))
       (cl-letf (((symbol-function (cdr entry))
                  (lambda () (interactive) (setq called t))))
         (execute-kbd-macro (kbd (car entry))))
       (should called)))
    (execute-kbd-macro (kbd "j j j j"))
    (should (equal (agent-profiles--selection) '(threshold "codex")))
    (execute-kbd-macro (kbd "k"))
    (should (equal (agent-profiles--selection) '(candidate "reviewer" 0)))
   (evil-local-mode -1)))

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

(ert-deftest agent-profiles-test-write-returned-config-and-errors ()
  (agent-profiles-test--with-page
   (let ((returned '(:collab (:disabled ["coder"])))
         captured-message)
     (cl-letf (((symbol-function 'agent-emx--request)
                (lambda (_connection method _params &optional callback error-callback)
                  (pcase method
                    ("collab/disable" (funcall callback (list :config returned)))
                    ("collab/profiles"
                     (funcall error-callback '(:message "Unsupported method"))))))
               ((symbol-function 'message)
                (lambda (format &rest args)
                  (setq captured-message (apply #'format format args)))))
       (agent-profiles--disable "coder" t)
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
       (agent-profiles--disable "coder" t)
       (should-not agent-profiles--writing)
       (should (equal agent-emx-config--value returned))
       (should (equal captured-message "子代理配置操作失败：Invalid config"))))))

(ert-deftest agent-profiles-test-model-reply-after-refresh-is-ignored ()
  (agent-profiles-test--with-page
   (let (reply)
     (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "pi"))
               ((symbol-function 'agent-emx--request)
                (lambda (_connection method _params &optional callback _error)
                  (should (equal method "agents/models"))
                  (setq reply callback))))
       (agent-profiles--edit-candidate "coder" 0))
     (cl-incf agent-profiles--generation)
     (funcall reply '(:models []))
     (should-not (agent-profiles-test--write)))))

(ert-deftest agent-profiles-test-remembers-invocation-root ()
  (dolist (project '(nil test-project))
    (let* ((agent-profiles--buffer (generate-new-buffer-name " *profiles-root*"))
           (origin (generate-new-buffer " *profiles-origin*"))
           (expected (if project "/test/project/" temporary-file-directory))
           requests)
      (unwind-protect
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) project))
                    ((symbol-function 'project-root) (lambda (_) "/test/project/"))
                    ((symbol-function 'pop-to-buffer) (lambda (&rest _)))
                    ((symbol-function 'agent-emx--local-connection)
                     (lambda (callback &rest _) (funcall callback 'local)))
                    ((symbol-function 'agent-emx--request)
                     (lambda (_ method params callback &rest _)
                       (should (equal method "collab/profiles"))
                       (push params requests)
                       (funcall callback agent-profiles-test--fixture))))
            (with-current-buffer origin
              (setq default-directory temporary-file-directory)
              (agent-profiles))
            (kill-buffer origin)
            (with-current-buffer agent-profiles--buffer
              (should (equal agent-profiles--root expected))
              (should (string-match-p (regexp-quote expected)
                                      (buffer-string)))
              (setq default-directory "/")
              (agent-profiles-refresh))
            (should (equal requests (list (list :root expected) (list :root expected)))))
        (when (buffer-live-p origin) (kill-buffer origin))
        (when (get-buffer agent-profiles--buffer) (kill-buffer agent-profiles--buffer))))))

(provide 'agent-profiles-test)
;;; agent-profiles-test.el ends here
