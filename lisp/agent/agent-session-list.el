;;; agent-session-list.el --- Session list sidebar -*- lexical-binding: t; -*-

;;; Commentary:

;; A session list on the left (modeled on T3 Code's thread sidebar):
;;   Active   all open sessions: status (working / awaiting approval / done /
;;            idle), agent, title
;;   History  past sessions of each agent (Claude and Codex) in the current
;;            project; they can be resumed directly
;;
;; Keys: RET open / resume, c new, k end session, g refresh, n / p move
;; down / up, q quit.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'agent-session)

(defgroup agent-session-list nil
  "Agent session list."
  :group 'agent-session
  :prefix "agent-session-list-")

(defcustom agent-session-list-width 40
  "Width of the session list sidebar."
  :type 'integer)

(defconst agent-session-list--buffer-name "*agent-sessions*")

(defvar agent-session-list--history (make-hash-table :test #'equal)
  "Cache of past sessions: (ROOT . AGENT) → list of items.")

(defvar-local agent-session-list--root nil "Project root the list shows.")

(defvar agent-session-list--timer nil "Periodic refresh timer (updates working time).")

;;; Data

(defun agent-session-list--fetch (root)
  "Fetch each agent's past sessions in ROOT asynchronously; redraw on arrival."
  (dolist (entry agent-session-agents)
    (let ((agent (car entry)))
      (agent-session-backend-history
       (plist-get (cdr entry) :backend) root
       (lambda (items)
         (puthash (cons root agent) items agent-session-list--history)
         (agent-session-list--refresh-soon))))))

(defun agent-session-list--history-items (root)
  "Return past sessions in ROOT that aren't open, newest first.
The value is ((AGENT . ITEM) ...)."
  (let ((open (delq nil (mapcar (lambda (b) (agent-session-resume-id
                                             (buffer-local-value 'agent-session--current b)))
                                (agent-session-buffers))))
        result)
    (dolist (entry agent-session-agents)
      (dolist (item (gethash (cons root (car entry)) agent-session-list--history))
        (unless (member (plist-get item :id) open)
          (push (cons (car entry) item) result))))
    (sort result :key (lambda (x) (- (or (plist-get (cdr x) :time) 0))))))

(defun agent-session-list--ago (time)
  "Return a short description of how long ago TIME (in seconds) was."
  (let ((seconds (- (float-time) time)))
    (cond ((< seconds 60) "刚刚")
          ((< seconds 3600) (format "%d分钟前" (/ seconds 60)))
          ((< seconds 86400) (format "%d小时前" (/ seconds 3600)))
          ((< seconds (* 7 86400)) (format "%d天前" (/ seconds 86400)))
          (t (format-time-string "%m-%d" time)))))

;;; Rendering

(defface agent-session-list-heading '((t :inherit (bold shadow)))
  "Face for group headings.")

(defface agent-session-list-title '((t :inherit bold))
  "Face for titles of active sessions.")

;;; Sessions asking for attention
;;
;; An agent can ask for the user's attention: its entry rises to the top of
;; the live sessions, flashes red and pink twice and stays pink until the
;; user opens the session.

(defface agent-session-list-alert '((t :background "#ffc0cb" :extend t))
  "Entry of a session whose agent asks for your attention.")

(defface agent-session-list-alert-flash '((t :background "#ff4d4f" :extend t))
  "Entry of such a session at the bright moments of its flash.")

(defvar-local agent-session-list--alert nil
  "In a session buffer: why its agent asks for attention, or nil.
The reason may be the empty string.")

(defvar-local agent-session-list--alert-time nil
  "In a session buffer: when its agent last asked for attention.")

(defvar agent-session-list--flashing nil
  "Session buffers whose entries are bright at this moment of their flash.")

(defun agent-session-list--seen-p (buffer)
  "Whether the user is looking at session BUFFER now."
  (and (eq (window-buffer (selected-window)) buffer)
       (eq (frame-focus-state (window-frame (selected-window))) t)))

(defun agent-session-list-alert (buffer &optional reason)
  "Raise the entry of session BUFFER to the top and flash it.
It stays pink until the session is opened.  REASON, if given, is shown
when the mouse is on the entry.  When the user is already looking at the
session, it only flashes."
  (with-current-buffer buffer
    (setq agent-session-list--alert (or reason "")
          agent-session-list--alert-time (float-time))
    (add-hook 'window-buffer-change-functions #'agent-session-list--opened nil t)
    (add-hook 'window-selection-change-functions #'agent-session-list--opened nil t)
    (add-hook 'post-command-hook #'agent-session-list--used nil t))
  ;; Rise first, where it can be seen, then flash.
  (agent-session-list--refresh)
  (when-let* ((window (get-buffer-window agent-session-list--buffer-name t)))
    (set-window-start window (with-current-buffer (window-buffer window) (point-min))))
  ;; After a pause: bright, pink, bright, then pink, 0.3 s each.
  (pcase-dolist (`(,delay ,bright ,last) '((0.3 t) (0.6 nil) (0.9 t) (1.2 nil t)))
    (run-with-timer
     delay nil
     (lambda ()
       (setq agent-session-list--flashing
             (if bright
                 (cl-adjoin buffer agent-session-list--flashing)
               (delq buffer agent-session-list--flashing)))
       ;; Someone looking at the session has seen it already.
       (when (and last (buffer-live-p buffer) (agent-session-list--seen-p buffer))
         (agent-session-list--clear buffer))
       (agent-session-list--refresh)))))

(defun agent-session-list--clear (buffer)
  "Stop showing that session BUFFER asks for attention."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when agent-session-list--alert
        (setq agent-session-list--alert nil
              agent-session-list--alert-time nil)
        (remove-hook 'window-buffer-change-functions #'agent-session-list--opened t)
        (remove-hook 'window-selection-change-functions #'agent-session-list--opened t)
        (remove-hook 'post-command-hook #'agent-session-list--used t)
        (agent-session-list--refresh)))))

(defun agent-session-list--opened (_window)
  "Clear the alert of this session buffer once it is in the selected window."
  (when (eq (window-buffer (selected-window)) (current-buffer))
    (agent-session-list--clear (current-buffer))))

(defun agent-session-list--used ()
  "Clear the alert of this session buffer: the user ran a command in it."
  (agent-session-list--clear (current-buffer)))

(defun agent-session-list--order (buffers)
  "BUFFERS of live sessions in list order.
Those asking for attention come first, the latest first; the others keep
their order."
  (let ((time (lambda (buffer) (buffer-local-value 'agent-session-list--alert-time buffer))))
    (append (sort (seq-filter time buffers) :key time :reverse t)
            (seq-remove time buffers))))

(defun agent-session-list--alert-face (buffer)
  "Face of the entry of session BUFFER for its alert, or nil."
  (cond ((memq buffer agent-session-list--flashing) 'agent-session-list-alert-flash)
        ((buffer-local-value 'agent-session-list--alert buffer) 'agent-session-list-alert)))

(defun agent-session-list--project-name (root)
  "Return the project name of ROOT."
  (file-name-nondirectory (directory-file-name root)))

(defun agent-session-list-mouse-open (event)
  "Handle mouse click EVENT on a session entry.
Push the button if the click is on one (such as ×), otherwise open the
session."
  (interactive "e")
  (let* ((posn (event-start event))
         (pos (posn-point posn)))
    (select-window (posn-window posn))
    (goto-char pos)
    (if (button-at pos)
        (push-button pos)
      (agent-session-list-open))))

(defvar-keymap agent-session-list-entry-map
  :doc "Mouse bindings on session entries.
Keyboard keys are still handled by `agent-session-list-mode-map'."
  "<mouse-1>" #'agent-session-list-mouse-open
  "<mouse-2>" #'agent-session-list-mouse-open)

(defun agent-session-list--insert-entry (entry &rest strings)
  "Insert STRINGS as one item carrying the ENTRY property.
The item is highlighted on mouse hover and opens on click."
  (let ((start (point)))
    (apply #'insert strings)
    ;; Pad each line end with space up to the window's right edge so the
    ;; hover highlight covers the whole line.
    (save-excursion
      (let ((end (point-marker)))
        (goto-char start)
        (while (search-forward "\n" end t)
          (backward-char)
          (insert (propertize " " 'display '(space :align-to right)))
          (forward-char))
        (set-marker end nil)))
    ;; Emacs highlights adjacent text with the same (eq) mouse-face as one
    ;; region; use a fresh list per item so hovering highlights only it.
    (add-text-properties start (point)
                         (list 'agent-session-entry entry
                               'mouse-face (list 'highlight)
                               'keymap agent-session-list-entry-map))
    ;; The padding pushes newlines inside the entry past the right edge (into
    ;; the fringe on GUI); keep their highlight so a multi-line entry forms
    ;; one block.  Don't highlight the final newline, or the highlight would
    ;; spill onto the start of the next line.
    (when (eq (char-before) ?\n)
      (remove-text-properties (1- (point)) (point) '(mouse-face nil)))
    (agent-session-list--set-help start (point) "点击打开")))

(defun agent-session-list--set-help (start end help)
  "Show HELP as the tooltip of the text from START to END.
Buttons, such as ×, keep their own tooltips."
  (let ((pos start))
    (while (< pos end)
      (let ((next (next-single-property-change pos 'button nil end)))
        (unless (get-text-property pos 'button)
          (put-text-property pos next 'help-echo help))
        (setq pos next)))))

(defun agent-session-list--kill-button (buffer)
  "Return a × button that ends the session in BUFFER, at the right edge."
  (concat
   ;; At least one space, then align × one column short of the edge (a
   ;; terminal reserves the last column for the wrap glyph).
   " " (propertize " " 'display `(space :align-to (- right ,(1+ (string-width "×")))))
   (make-text-button "×" nil 'face 'agent-session-dim 'follow-link t
                     'help-echo "结束这个会话"
                     'action (lambda (_)
                               (when (yes-or-no-p (format "结束 %s？" (buffer-name buffer)))
                                 (kill-buffer buffer)
                                 (agent-session-list--refresh))))))

(defun agent-session-list--truncate (string)
  "Truncate STRING to fit the window width."
  (truncate-string-to-width string (max 10 (- (window-body-width) 4)) nil nil "…"))

(defun agent-session-list--head-line (head handle)
  "HEAD then HANDLE, cut to leave room for the × at the window's right edge.
HEAD is cut first, so the handle stays readable."
  (let ((width (- (window-body-width) 3)))
    (truncate-string-to-width
     (concat (truncate-string-to-width head (max 10 (- width (string-width handle))) nil nil "…")
             handle)
     width nil nil "…")))

(defun agent-session-list--render ()
  "Redraw the session list in the current buffer.
Try to keep point on the same entry."
  (let* ((inhibit-read-only t)
         (current (get-text-property (point) 'agent-session-entry))
         (root agent-session-list--root)
         (live (agent-session-list--order (agent-session-buffers)))
         (history (agent-session-list--history-items root)))
    (erase-buffer)
    (insert (propertize "进行中\n" 'face 'agent-session-list-heading))
    (if (null live)
        (insert (propertize "  还没有会话，按 c 新建\n" 'face 'agent-session-dim))
      (dolist (buffer live)
        (let* ((session (buffer-local-value 'agent-session--current buffer))
               (project (agent-session-list--project-name (agent-session-root session)))
               (start (point)))
          (agent-session-list--insert-entry
           (list :buffer buffer)
           (agent-session-list--head-line
            (concat "  " (agent-session-status-label session)
                    (propertize (format "  %s · %s" (agent-session-title session) project)
                                'face 'agent-session-dim))
            (if-let* ((handle (agent-session-handle session)))
                (propertize (concat "  @" handle) 'face 'agent-session-dim)
              ""))
           (agent-session-list--kill-button buffer)
           "\n    "
           (propertize (agent-session-list--truncate (agent-session-display-title session))
                       'face 'agent-session-list-title)
           "\n")
          (when-let* ((face (agent-session-list--alert-face buffer)))
            (add-face-text-property start (point) face t)
            (let ((reason (buffer-local-value 'agent-session-list--alert buffer)))
              (when (and reason (not (string-empty-p reason)))
                (agent-session-list--set-help start (point) (concat reason "\n点击打开"))))))))
    (insert "\n" (propertize (format "历史 · %s\n" (agent-session-list--project-name root))
                             'face 'agent-session-list-heading))
    (if (null history)
        (insert (propertize "  （没有历史会话）\n" 'face 'agent-session-dim))
      (pcase-dolist (`(,agent . ,item) history)
        (agent-session-list--insert-entry
         (list :agent agent :id (plist-get item :id) :root (or (plist-get item :root) root)
               :title (plist-get item :title))
         "  "
         (propertize (format "%-7s %-5s " (agent-session-list--ago (plist-get item :time))
                             (or (agent-session--get agent :title) agent))
                     'face 'agent-session-dim)
         (agent-session-list--truncate
          (concat (if-let* ((worktree (plist-get item :worktree)))
                      (propertize (format "[%s] " (truncate-string-to-width worktree 16 nil nil "…"))
                                  'face 'agent-session-dim)
                    "")
                  (plist-get item :title)))
         "\n")))
    ;; Return to the original entry
    (goto-char (point-min))
    (when current
      (let ((pos (point-min)))
        (while (and pos (not (equal (get-text-property pos 'agent-session-entry) current)))
          (setq pos (next-single-property-change pos 'agent-session-entry)))
        (when pos (goto-char pos))))
    (unless (get-text-property (point) 'agent-session-entry)
      (agent-session-list-next))))

(defvar agent-session-list--pending nil "Timer for a scheduled redraw.")

(defun agent-session-list--refresh-soon ()
  "Redraw the session list shortly.
Status changes often while output streams, so coalesce them into one redraw."
  (unless (timerp agent-session-list--pending)
    (setq agent-session-list--pending
          ;; Use a plain timer, not an idle timer: an idle timer created while
          ;; Emacs is already idle fires immediately.
          (run-with-timer 0.3 nil (lambda ()
                                    (setq agent-session-list--pending nil)
                                    (agent-session-list--refresh))))))

(defun agent-session-list--refresh ()
  "Redraw the session list if it is open."
  (when-let* ((buffer (get-buffer agent-session-list--buffer-name)))
    (with-current-buffer buffer
      (if-let* ((window (get-buffer-window buffer t)))
          (with-selected-window window (agent-session-list--render))
        (agent-session-list--render)))))

;;; Commands

(defun agent-session-list--entry ()
  "Return the entry at point."
  (or (get-text-property (point) 'agent-session-entry)
      (user-error "光标不在会话上")))

(defun agent-session-list-open ()
  "Open the session at point; resume it if it is a past session."
  (interactive)
  (let ((entry (agent-session-list--entry)))
    (if-let* ((buffer (plist-get entry :buffer)))
        (select-window (agent-session-display buffer))
      (agent-session-start (plist-get entry :agent) nil (plist-get entry :id)
                           (plist-get entry :root) (plist-get entry :title)))))

(defun agent-session-list-create (&optional choose)
  "Create a session in the list's project.
With CHOOSE (prefix argument), choose the agent first."
  (interactive "P")
  (let ((default-directory agent-session-list--root))
    (select-window (or (get-buffer-window (agent-session-create choose)) (selected-window)))))

(defun agent-session-list-kill ()
  "End the session at point."
  (interactive)
  (let ((buffer (or (plist-get (agent-session-list--entry) :buffer)
                    (user-error "历史会话无需结束"))))
    (when (yes-or-no-p (format "结束 %s？" (buffer-name buffer)))
      (kill-buffer buffer)
      (agent-session-list--refresh))))

(defun agent-session-list-refresh ()
  "Refetch past sessions and redraw."
  (interactive)
  (agent-session-list--fetch agent-session-list--root)
  (agent-session-list--render))

(defun agent-session-list-next ()
  "Move to the next session."
  (interactive)
  (let ((pos (point)))
    (when (get-text-property pos 'agent-session-entry)
      (setq pos (next-single-property-change pos 'agent-session-entry nil (point-max))))
    (setq pos (text-property-not-all pos (point-max) 'agent-session-entry nil))
    (when pos (goto-char pos))))

(defun agent-session-list--entry-start (pos)
  "Return the start of the entry at POS."
  (let ((entry (get-text-property pos 'agent-session-entry)))
    (while (and (> pos (point-min))
                (equal (get-text-property (1- pos) 'agent-session-entry) entry))
      (setq pos (1- pos)))
    pos))

(defun agent-session-list-previous ()
  "Move to the previous session."
  (interactive)
  (let ((pos (1- (agent-session-list--entry-start (point)))))
    (while (and (> pos (point-min)) (not (get-text-property pos 'agent-session-entry)))
      (setq pos (1- pos)))
    (when (get-text-property pos 'agent-session-entry)
      (goto-char (agent-session-list--entry-start pos)))))

(defvar-keymap agent-session-list-mode-map
  :doc "Keymap for the session list."
  "RET" #'agent-session-list-open
  "c" #'agent-session-list-create
  "k" #'agent-session-list-kill
  "g" #'agent-session-list-refresh
  "n" #'agent-session-list-next
  "p" #'agent-session-list-previous)

(defun agent-session-list--header-button (label command help)
  "Return a clickable header-line button showing LABEL with tooltip HELP.
Clicking it runs COMMAND in the session list window."
  (propertize label
              'face 'agent-session-assistant
              'mouse-face 'highlight
              'help-echo help
              'local-map (let ((map (make-sparse-keymap)))
                           (define-key map [header-line mouse-1]
                                       (lambda (event)
                                         (interactive "e")
                                         (with-selected-window (posn-window (event-start event))
                                           (call-interactively command))))
                           map)))

(define-derived-mode agent-session-list-mode special-mode "Sessions"
  "Major mode for the agent session list."
  (setq-local truncate-lines t
              cursor-type 'bar
              revert-buffer-function (lambda (&rest _) (agent-session-list-refresh))
              header-line-format
              '(:eval (concat " 会话  "
                              (agent-session-list--header-button "[+ 新建]" #'agent-session-list-create
                                                                 "新建会话（c）")
                              " "
                              (agent-session-list--header-button "[刷新]" #'agent-session-list-refresh
                                                                 "重新获取历史会话（g）")
                              (propertize "  单击打开 · RET 打开 · k 结束"
                                          'face 'agent-session-dim))))
  (hl-line-mode 1))

;;;###autoload
(defun agent-session-list ()
  "Open the session list on the left.
It shows active sessions and past sessions of the current project."
  (interactive)
  (let* ((root (if-let* ((session agent-session--current))
                   (agent-session-root session)
                 (agent-session--root)))
         (buffer (get-buffer-create agent-session-list--buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-session-list-mode) (agent-session-list-mode))
      (setq agent-session-list--root root))
    (setq agent-session--list-refresh-function #'agent-session-list--refresh-soon)
    (let ((window (display-buffer-in-side-window
                   buffer `((side . left) (slot . 0)
                            (window-width . ,agent-session-list-width)
                            (preserve-size . (t . nil))
                            (window-parameters . ((no-delete-other-windows . t)))))))
      (select-window window)
      (agent-session-list--render)
      (agent-session-list--fetch root))
    (unless (timerp agent-session-list--timer)
      (setq agent-session-list--timer
            (run-with-timer 10 10 (lambda ()
                                    (when (and (get-buffer-window agent-session-list--buffer-name t)
                                               (seq-some (lambda (b)
                                                           (eq (agent-session-status
                                                                (buffer-local-value
                                                                 'agent-session--current b))
                                                               'running))
                                                         (agent-session-buffers)))
                                      (agent-session-list--refresh))))))))

(provide 'agent-session-list)
;;; agent-session-list.el ends here
