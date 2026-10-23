;;; init-update.el --- Fetch and apply the configuration -*- lexical-binding: t; -*-

;;; Commentary:

;; Two-stage update contract:
;; `my/update-config' is a bootstrap that may run from OLD code.  In the true
;; `user-emacs-directory' it asynchronously fetches the current upstream and
;; merges --ff-only @{u}, reloads this file and init-reload.el if either
;; changed, then calls the NEW definition of `my/update--apply' with FROM TO.
;; The name and two-argument arity of `my/update--apply' are frozen forever;
;; everything else, including build tools and apply steps, may change.
;; Failed compilation/reload stops the update without advancing the marker.
;; FROM is the last fully applied revision under var/update/applied, or HEAD
;; before merging on first use.  Only complete success advances it to TO;
;; restart_required counts as applied and is reported to the user.
;; Changes needing more than reload must ship idempotent, repository-derived
;; steps here, usable when bootstrapped by the previous revision's command.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'init-base)
(require 'init-reload)

(defvar my/update--state nil
  "Current asynchronous update state, or nil when idle.
Preserved across the bootstrap's reload of this module.")

(defvar my/update-last-report nil
  "Report from the most recently completed update.")

(defun my/update--log (text)
  "Append TEXT to the update output buffer."
  (with-current-buffer (get-buffer-create "*配置更新*")
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (insert text))))

(defun my/update--put (key value)
  "Store VALUE at KEY in the current update."
  (setq my/update--state (plist-put my/update--state key value)))

(defun my/update--finish (&optional error-text)
  "Finish the current update, optionally with ERROR-TEXT."
  (let* ((state my/update--state)
         (report (list :status (if error-text "failed" "applied")
                       :from (plist-get state :from) :to (plist-get state :to)
                       :git (or (plist-get state :git)
                                (list :status "failed" :error error-text))
                       :steps (vconcat (plist-get state :reports))
                       :reload (vconcat (plist-get state :reload))
                       :restart_required (vconcat (plist-get state :restart))
                       :error error-text)))
    (setq my/update--state nil my/update-last-report report)
    (my/update--log (concat (if error-text (concat "更新失败：" error-text)
                             "配置更新完成") "\n"))
    (message "%s" (if error-text (concat "配置更新失败：" error-text)
                    (format "配置更新完成；%s"
                            (my/reload--summary (plist-get state :reload)))))
    (when-let* ((callback (plist-get state :callback)))
      (funcall callback report))
    (when (and (not error-text) (plist-get state :interactive)
               (plist-get state :restart)
               (y-or-n-p "部分配置需要重启 Emacs，现在重启？ "))
      (restart-emacs))))

(defun my/update--guard (function &rest args)
  "Call FUNCTION with ARGS, reporting any error as an update failure."
  (condition-case err
      (apply function args)
    (error (when my/update--state
             (my/update--finish (error-message-string err))))))

(defun my/update--command (command callback &optional allow-failure)
  "Run COMMAND asynchronously; pass its output to CALLBACK on success.
With ALLOW-FAILURE, CALLBACK also receives a nonzero exit status."
  (let ((default-directory (plist-get my/update--state :root))
        (output "")
        ;; Keep Git prompts from waiting on an invisible terminal.
        (process-environment (cons "GIT_TERMINAL_PROMPT=0" process-environment)))
    (my/update--log (concat "$ " (mapconcat #'shell-quote-argument command " ") "\n"))
    (my/update--put
     :process
     (make-process
      :name "config-update" :command command :connection-type 'pipe :noquery t
      :filter (lambda (_process chunk)
                (setq output (concat output chunk))
                (my/update--log chunk))
      :sentinel
      (lambda (process _event)
        (when (and my/update--state (memq (process-status process) '(exit signal)))
          (if (or allow-failure (zerop (process-exit-status process)))
              (my/update--guard callback output (process-exit-status process))
            (my/update--finish
             (format "命令失败（退出码 %d）：%s"
                     (process-exit-status process) (string-trim output))))))))))

(defun my/update--git (args callback &optional allow-failure)
  "Run Git ARGS and invoke CALLBACK; see `my/update--command'."
  (my/update--command (cons "git" args) callback allow-failure))

(defun my/update--paths-p (paths regexp)
  "Return non-nil when PATHS contain a match for REGEXP."
  (seq-some (lambda (path) (string-match-p regexp path)) paths))

(defun my/update--deps-p (paths)
  "Whether PATHS or missing dependencies require npm installation."
  (or (my/update--paths-p paths "\\`emx/package\\(?:-lock\\)?\\.json\\'")
      (not (file-directory-p (expand-file-name
                              "emx/node_modules" (plist-get my/update--state :root))))))

(defun my/update--lisp-p (paths)
  "Whether PATHS contain configuration Lisp or startup files."
  (my/update--paths-p paths "\\`\\(?:lisp/.*\\.el\\|init\\.el\\|early-init\\.el\\)\\'"))

(defun my/update--emx-p (paths)
  "Whether PATHS require rebuilding or updating emx."
  (my/update--paths-p paths "\\`\\(?:emx/\\|bin/emx\\'\\|lisp/agent/backend/\\(?:pi\\|dsh\\)/\\)"))

(defun my/update--lisp ()
  "Reload changed loaded Lisp files, without invoking the daemon step."
  (let* ((root (plist-get my/update--state :root))
         (paths (plist-get my/update--state :paths))
         (loaded (mapcar #'car (my/reload--loaded)))
         (files (seq-filter
                 (lambda (file) (member (file-relative-name file root) paths)) loaded))
         (my/reload-emx-function nil)
         ;; nil means all changed files to reload-config, so skip an empty set.
         (report (and files (my/reload-config files))))
    (dolist (path '("init.el" "early-init.el"))
      (when (member path paths)
        (setq report (append report
                             (list (list :file (expand-file-name path root)
                                         :status 'restart_required
                                         :error "init files only run at startup"))))))
    (list :reload report)))

(defun my/update--emx ()
  "Apply daemon changes using the installed daemon reload function."
  (unless my/reload-emx-function
    (error "未安装 emx 更新函数"))
  (list :reload (list (list :emx (vconcat (funcall my/reload-emx-function))))))

(defconst my/update-steps
  '((:name "emx-deps" :when my/update--deps-p
     :run ("npm" "install" "--prefix" "emx"))
    (:name "lisp" :when my/update--lisp-p :run my/update--lisp)
    (:name "emx" :when my/update--emx-p :run my/update--emx))
  "Ordered update steps owned by this revision.
Each plist has :name, :when (a predicate of changed paths), and :run.
A run is an argv list for `make-process', or a zero-argument Lisp function
returning a plist with optional :reload entries.  Steps must be idempotent
and derive from repository state, including checks for missing artifacts.")

(defun my/update--record-step (step result)
  "Record STEP's RESULT and continue, unless a reload failed."
  (let* ((reload (plist-get result :reload))
         (failed (seq-some
                  (lambda (entry)
                    (or (eq (plist-get entry :status) 'failed)
                        (seq-some (lambda (daemon)
                                    (equal (plist-get daemon :status) "failed"))
                                  (plist-get entry :emx)))) reload)))
    (when reload (my/update--log (concat (my/reload--summary reload) "\n")))
    (my/update--put :reload (append (plist-get my/update--state :reload) reload))
    (my/update--put :restart
                    (append (plist-get my/update--state :restart)
                            (mapcar (lambda (entry) (plist-get entry :file))
                                    (seq-filter (lambda (entry)
                                                  (eq (plist-get entry :status)
                                                      'restart_required)) reload))))
    (my/update--put :reports
                    (append (plist-get my/update--state :reports)
                            (list (list :name (plist-get step :name)
                                        :status (if failed "failed" "applied")))))
    (if failed (my/update--finish "重载失败，请查看更新报告")
      (my/update--next-step))))

(defun my/update--next-step ()
  "Run the next selected step, or persist the successful revision."
  (if-let* ((step (car (plist-get my/update--state :remaining))))
      (progn
        (my/update--put :remaining (cdr (plist-get my/update--state :remaining)))
        (if (not (funcall (plist-get step :when) (plist-get my/update--state :paths)))
            (progn
              (my/update--put :reports
                              (append (plist-get my/update--state :reports)
                                      (list (list :name (plist-get step :name)
                                                  :status "skipped"))))
              (my/update--next-step))
          (my/update--put :active-step step)
          (my/update--log (format "执行步骤：%s\n" (plist-get step :name)))
          (condition-case err
              (let ((run (plist-get step :run)))
                (if (and (listp run) (stringp (car run)))
                    (my/update--command
                     run (lambda (output status)
                           (if (zerop status) (my/update--record-step step nil)
                             (my/update--put :reports
                                             (append (plist-get my/update--state :reports)
                                                     (list (list :name (plist-get step :name)
                                                                 :status "failed"))))
                             (my/update--finish
                              (format "步骤 %s 失败（退出码 %d）：%s"
                                      (plist-get step :name) status
                                      (string-trim output))))) t)
                  (my/update--record-step step (funcall run))))
            (error
             (my/update--put :reports
                             (append (plist-get my/update--state :reports)
                                     (list (list :name (plist-get step :name)
                                                 :status "failed"))))
             (my/update--finish (error-message-string err))))))
    (let* ((marker (plist-get my/update--state :marker))
           (dir (file-name-directory marker)))
      (make-directory dir t)
      (let ((temp (make-temp-file (expand-file-name ".applied-" dir))))
        (unwind-protect
            (progn
              (with-temp-file temp (insert (plist-get my/update--state :to) "\n"))
              (rename-file temp marker t))
          (when (file-exists-p temp) (delete-file temp))))
      (my/update--finish))))

(defun my/update--apply (from to)
  "Apply revision TO relative to FROM.  This name and arity are frozen forever."
  (my/update--git
   (list "diff" "--name-only" "-z" from to)
   (lambda (output _status)
     (my/update--put :paths (split-string output "\0" t))
     (my/update--put :remaining (copy-sequence my/update-steps))
     (my/update--next-step))))

(defun my/update--bootstrap-apply ()
  "Reload the updater if changed, then call the new frozen apply entry point.
The reloader is reloaded with it, so the new updater never runs on the old
reload API."
  (let* ((root (plist-get my/update--state :root))
         (paths '("lisp/core/init-reload.el" "lisp/core/init-update.el"))
         (files (seq-filter #'file-exists-p
                            (mapcar (lambda (path) (expand-file-name path root)) paths)))
         (my/reload-emx-function nil))
    (when (or (seq-intersection paths (plist-get my/update--state :paths))
              (seq-some #'my/reload--changed-p files))
      (let ((report (my/reload-config files)))
        (my/update--put :reload report)
        (my/update--log (concat (my/reload--summary report) "\n"))
        (unless (and report (seq-every-p (lambda (entry)
                                          (eq (plist-get entry :status) 'reloaded)) report))
          (error "更新模块编译或重载失败，请查看更新报告"))))
    ;; Symbol lookup must happen AFTER the bootstrap reload.
    (my/update--apply (plist-get my/update--state :from)
                      (plist-get my/update--state :to))))

(defun my/update--branch (branch status)
  "Validate BRANCH and STATUS, then read the initial revision."
  (unless (zerop status) (error "当前处于分离 HEAD 状态，无法更新"))
  (my/update--put :branch (string-trim branch))
  (my/update--git '("rev-parse" "--verify" "HEAD") #'my/update--head))

(defun my/update--head (head _status)
  "Remember HEAD and the applied marker, then check the upstream."
  (my/update--put :head (string-trim head))
  (my/update--put
   :from (if (file-exists-p (plist-get my/update--state :marker))
             (with-temp-buffer
               (insert-file-contents (plist-get my/update--state :marker))
               (string-trim (buffer-string)))
           (string-trim head)))
  (my/update--git '("rev-parse" "--symbolic-full-name" "@{u}")
                  #'my/update--upstream t))

(defun my/update--upstream (upstream status)
  "Validate UPSTREAM and STATUS, then resolve its configured remote."
  (unless (zerop status) (error "当前分支没有上游，无法更新"))
  (my/update--put :upstream (string-trim upstream))
  (my/update--git
   (list "config" "--get"
         (concat "branch." (plist-get my/update--state :branch) ".remote"))
   (lambda (remote _status)
     (my/update--git (list "fetch" "--" (string-trim remote))
                     (lambda (_output _status)
                       (my/update--git
                        '("rev-list" "--left-right" "--count" "HEAD...@{u}")
                        #'my/update--counts))))))

(defun my/update--counts (counts _status)
  "Refuse divergent COUNTS, otherwise attempt a fast-forward merge."
  (let ((numbers (mapcar #'string-to-number (split-string counts))))
    (when (and (> (car numbers) 0) (> (cadr numbers) 0))
      (error "本地与上游分支已分叉，请手动处理")))
  (my/update--git '("merge" "--ff-only" "--no-autostash" "@{u}") #'my/update--merged t))

(defun my/update--merged (output status)
  "Record merge OUTPUT and STATUS, then resolve the target revision."
  (my/update--put :git (list :status (if (zerop status) "merged" "failed")
                             :before (plist-get my/update--state :head)
                             :upstream (plist-get my/update--state :upstream)
                             :output output))
  (unless (zerop status)
    (error "无法快进合并，请检查工作区冲突：%s" (string-trim output)))
  (my/update--git
   '("rev-parse" "HEAD")
   (lambda (to _status)
     (my/update--put :to (string-trim to))
     (my/update--git
      (list "diff" "--name-only" "-z"
            (plist-get my/update--state :from) (string-trim to))
      (lambda (paths _status)
        (my/update--put :paths (split-string paths "\0" t))
        (my/update--bootstrap-apply))))))

(defun my/update-config (&optional callback)
  "Fetch, fast-forward and apply the configuration asynchronously.
CALLBACK receives the final report.  Interactive use offers a restart when
needed; programmatic use never prompts.  Output goes to *配置更新*."
  (interactive)
  (when my/update--state (user-error "配置更新正在进行"))
  (let ((root (file-name-as-directory (file-truename user-emacs-directory))))
    (setq my/update--state
          (list :root root :marker (my/var "update/applied") :callback callback
                :interactive (called-interactively-p 'any)))
    (my/update--log "\n开始更新配置\n")
    (my/update--guard #'my/update--git
                      '("symbolic-ref" "--quiet" "--short" "HEAD")
                      #'my/update--branch t)))

(provide 'init-update)
;;; init-update.el ends here
