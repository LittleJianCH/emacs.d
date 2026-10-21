;;; init-base-test.el --- Tests for init-base -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-base-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)

(defvar treesit-auto-install-grammar)
(defvar evil-mode)

(ert-deftest init-base-evil-keybinding-preset ()
  "evil's integration settings are set before evil can load by any path.
evil-collection warns when evil loaded with `evil-want-keybinding' on,
e.g. after a plain M-x evil-mode autoloaded it without init-evil."
  (should (default-value 'evil-want-integration))
  (should-not (default-value 'evil-want-keybinding)))

(ert-deftest init-base-scroll-with-point ()
  "C-j / C-k scroll a line and move point with it, keeping its screen row.
Scrolling needs a real display: run it in the running Emacs."
  (skip-unless (not noninteractive))
  (save-window-excursion
    (with-temp-buffer
      (dotimes (i 100) (insert (format "line %d\n" i)))
      (switch-to-buffer (current-buffer))
      (let ((row (lambda () (count-screen-lines (window-start) (point))))
            (line (lambda () (line-number-at-pos))))
        (goto-char (point-min))
        (forward-line 20)
        (move-to-column 3)
        (set-window-start nil (save-excursion (forward-line -5) (point)))
        (let ((row0 (funcall row)))
          (my/scroll-down-with-point)
          (should (= (funcall line) 22))
          (should (= (funcall row) row0))
          (should (= (current-column) 3))
          (my/scroll-up-with-point 2)
          (should (= (funcall line) 20))
          (should (= (funcall row) row0)))
        ;; At the start the text can't scroll: only point moves.
        (goto-char (point-min))
        (forward-line 3)
        (set-window-start nil (point-min))
        (my/scroll-up-with-point)
        (should (= (funcall line) 3))
        (should (= (window-start) (point-min)))))))

(ert-deftest init-base-no-scroll-margin ()
  "No scroll margin, which makes touchpad scrolling jump back."
  (should (= (default-value 'scroll-margin) 0)))

(ert-deftest init-base-truncates-code-lines ()
  "Code and config buffers truncate long lines; prose wraps."
  (with-temp-buffer
    (emacs-lisp-mode)
    (should truncate-lines))
  (with-temp-buffer
    (conf-unix-mode)
    (should truncate-lines))
  (when (fboundp 'toml-ts-mode)
    (with-temp-buffer
      ;; Hooks run even when the grammar is missing, as long as nothing asks
      ;; to install it (a checkout without tree-sitter/, such as a worktree).
      (let ((treesit-auto-install-grammar nil))
        (ignore-errors (toml-ts-mode)))
      (should truncate-lines)
      (should-not visual-line-mode)))
  (with-temp-buffer
    (text-mode)
    (should-not truncate-lines)
    (should visual-line-mode)))

(ert-deftest init-base-sis-english-source ()
  "The English source is whichever layout this Mac has enabled."
  (should (equal (my/sis--english-source
                  "({\"KeyboardLayout ID\" = 252;\n\"KeyboardLayout Name\" = ABC;},
{\"Input Mode\" = \"com.apple.inputmethod.SCIM.Shuangpin\";})")
                 "com.apple.keylayout.ABC"))
  (should (equal (my/sis--english-source
                  "({\"KeyboardLayout ID\" = 0;\n\"KeyboardLayout Name\" = \"U.S.\";})")
                 "com.apple.keylayout.US"))
  (should (equal (my/sis--english-source
                  "({\"KeyboardLayout ID\" = 19;},{\"KeyboardLayout ID\" = 252;})")
                 "com.apple.keylayout.ABC"))
  (should (equal (my/sis--english-source "()") "com.apple.keylayout.US")))

(ert-deftest init-base-sis-waits-for-a-graphical-frame ()
  "A daemon has no graphical frame during init: sis starts with the first."
  (let ((graphic nil) (configured 0)
        (after-make-frame-functions (list #'my/sis--start)))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) graphic))
              ((symbol-function 'executable-find) (lambda (&rest _) "/bin/macism"))
              ((symbol-function 'require) (lambda (&rest _) t))
              ((symbol-function 'my/sis--configure) (lambda () (cl-incf configured))))
      (let ((system-type 'darwin))
        (run-hook-with-args 'after-make-frame-functions (selected-frame))
        (should (= configured 0))
        (should (memq #'my/sis--start after-make-frame-functions))
        (setq graphic t)
        (run-hook-with-args 'after-make-frame-functions (selected-frame))
        (should (= configured 1))
        (should-not (memq #'my/sis--start after-make-frame-functions))))))

(ert-deftest init-base-sis-agent-prefixes ()
  "Keep prefix switching available in editable star-named conversations."
  (skip-unless (require 'sis nil t))
  (with-temp-buffer
    (rename-buffer "*sis-agent-test*" t)
    (should (sis--prefix-override-buffer-disable-p))
    (setq-local sis--prefix-override-map-enable nil)
    (my/sis-enable-agent-prefixes)
    (should-not (sis--prefix-override-buffer-disable-p))
    (should-not (local-variable-p 'sis--prefix-override-map-enable))))

(ert-deftest init-base-sis-prefix-restores-chinese ()
  "Prefix keys use English for a command, then restore the Chinese source."
  (skip-unless (require 'sis nil t))
  ;; Use a fake OS backend: tests must not change the user's input source.
  (dolist (prefix '("C-c" "C-x" "C-h"))
    (with-temp-buffer
      (let* ((source sis-other-source)
             (sis--ism-inited t)
             (sis--ism t)
             (sis-global-respect-mode nil)
             (sis-do-get (lambda () source))
             (sis-do-set (lambda (value) (setq source value)))
             (sis--current nil)
             (sis--previous nil)
             (sis--prefix-override-map-enable t)
             (sis--prefix-handle-stage 'normal)
             (sis--respect-go-english nil)
             (sis--respect-force-restore nil)
             (sis--respect-post-cmd-timer nil)
             (sis--buffer-before-command (current-buffer))
             (sis-prefix-override-buffer-disable-predicates nil)
             (sis--prefix-override-saved-bindings nil)
             (input-decode-map (copy-keymap input-decode-map)))
        (unwind-protect
            (progn
              (sis--prefix-override-install)
              (should (equal (funcall (lookup-key input-decode-map (kbd prefix)))
                             (vconcat (kbd prefix))))
              (should (equal source sis-english-source))
              (should (eq sis--for-buffer 'other))
              (should sis--for-buffer-locked)
              (sis--respect-post-command-handler)
              (should (timerp sis--respect-post-cmd-timer))
              (cancel-timer sis--respect-post-cmd-timer)
              (sis--respect-post-cmd-timer-fn)
              (should (equal source sis-other-source))
              (should-not sis--for-buffer-locked)
              (should (eq sis--prefix-handle-stage 'normal)))
          (when (timerp sis--respect-post-cmd-timer)
            (cancel-timer sis--respect-post-cmd-timer)))))))

(defmacro init-base-test--with-input-window (&rest body)
  "Run BODY with a fake OS input backend and a displayed editing buffer."
  (declare (indent 0))
  `(progn
     (skip-unless (require 'sis nil t))
     (save-window-excursion
       (let* ((test-window (selected-window))
              (saved-source (window-parameter test-window 'my/sis-source)))
         (unwind-protect
             (with-temp-buffer
               (let* ((input-source sis-english-source)
                      (sis--ism-inited t)
                      (sis--ism t)
                      (sis-global-respect-mode t)
                      (sis-do-get (lambda () input-source))
                      (sis-do-set (lambda (value) (setq input-source value)))
                      (sis--current 'english)
                      (sis--previous nil)
                      (sis-change-hook '(my/sis--remember-source))
                      (evil-mode nil)
                      (my/sis--window test-window)
                      (my/sis--temporary nil))
                 (switch-to-buffer (current-buffer))
                 (setq-local evil-local-mode nil
                             sis--for-buffer-locked nil)
                 (set-window-parameter test-window 'my/sis-source nil)
                 ,@body))
           (when (window-live-p test-window)
             (set-window-parameter test-window 'my/sis-source saved-source)))))))

(ert-deftest init-base-sis-insert-source-roundtrip ()
  "Both Chinese and English survive a trip through Evil normal state."
  (init-base-test--with-input-window
    (setq-local evil-local-mode t evil-state 'insert)
    (dolist (language '(other english))
      ;; No polling first: Escape must capture the actual, latest OS source.
      (setq input-source (if (eq language 'other)
                             sis-other-source sis-english-source))
      (my/sis--leave-insert)
      (should (eq (window-parameter nil 'my/sis-source) language))
      (should (equal input-source sis-english-source))
      (setq evil-state 'normal)
      (my/sis--restore-window)
      (should (eq (window-parameter nil 'my/sis-source) language))
      (should (equal input-source sis-english-source))
      (setq evil-state 'insert)
      (my/sis--enter-insert)
      (should (equal input-source (if (eq language 'other)
                                     sis-other-source sis-english-source))))))

(ert-deftest init-base-sis-independent-windows ()
  "Two windows showing the same buffer keep independent source preferences."
  (init-base-test--with-input-window
    (let* ((left (selected-window))
           (right (split-window-right)))
      (set-window-buffer right (current-buffer))
      ;; Switch the IME and immediately click another window, before polling.
      (setq input-source sis-other-source)
      (select-window right)
      (my/sis--window-change (selected-frame))
      (should (eq (window-parameter left 'my/sis-source) 'other))
      (should (equal input-source sis-english-source))
      (select-window left)
      ;; A sis post-command restore can run before the redisplay window hook.
      (my/sis--restore-buffer #'ignore)
      (should (equal input-source sis-other-source))
      (should (eq (window-parameter right 'my/sis-source) 'english))
      (select-window right)
      (my/sis--window-change (selected-frame))
      (should (equal input-source sis-english-source))
      (select-window left)
      (my/sis--window-change (selected-frame))
      (should (equal input-source sis-other-source)))))

(ert-deftest init-base-sis-window-survives-buffer-switch ()
  "The input preference belongs to the window, even when its buffer changes."
  (init-base-test--with-input-window
    (setq input-source sis-other-source)
    (sis--get)
    (with-temp-buffer
      (setq-local evil-local-mode nil sis--for-buffer-locked nil)
      (set-window-buffer (selected-window) (current-buffer))
      (setq input-source sis-english-source)
      (my/sis--restore-buffer #'ignore)
      (should (equal input-source sis-other-source)))))

(ert-deftest init-base-sis-prefix-preserves-window-source ()
  "Temporary prefix English cannot replace the remembered editing source."
  (init-base-test--with-input-window
    (setq-local evil-local-mode t evil-state 'insert)
    (setq input-source sis-other-source)
    (sis--get)
    (let ((sis--prefix-override-map-enable t)
          (sis--prefix-handle-stage 'normal))
      (funcall (sis--prefix-override-make-translation (kbd "C-x")))
      (should (equal input-source sis-english-source))
      (should (eq (window-parameter nil 'my/sis-source) 'other))
      (my/sis--restore-buffer #'ignore)
      (should (equal input-source sis-other-source))
      ;; Escape during a prefix must not save its temporary English source.
      (setq sis--prefix-handle-stage 'normal)
      (funcall (sis--prefix-override-make-translation (kbd "C-c")))
      (my/sis--leave-insert)
      (setq evil-state 'normal)
      (my/sis--restore-window)
      (should (equal input-source sis-english-source))
      (setq evil-state 'insert)
      (my/sis--enter-insert)
      (should (equal input-source sis-other-source)))))

(ert-deftest init-base-sis-minibuffer-preserves-source ()
  "A quick IME change before M-x survives the minibuffer's English source."
  (init-base-test--with-input-window
    (setq input-source sis-other-source)
    ;; Simulate minibuffer entry without polling the source change first.
    (with-current-buffer (window-buffer (minibuffer-window))
      (let ((sis--for-buffer-locked nil)
            (sis--for-buffer nil))
        (my/sis--before-minibuffer)
        (sis--minibuffer-setup-handler)))
    (should (equal input-source sis-english-source))
    (should (eq (window-parameter nil 'my/sis-source) 'other))
    (my/sis--restore-buffer #'ignore)
    (should (equal input-source sis-other-source))))

(ert-deftest init-base-sis-evil-transitions ()
  "Real Evil state hooks preserve Chinese through normal and replace states."
  (skip-unless (require 'evil nil t))
  (init-base-test--with-input-window
    (let ((evil-insert-state-entry-hook
           (copy-sequence evil-insert-state-entry-hook))
          (evil-insert-state-exit-hook
           (copy-sequence evil-insert-state-exit-hook))
          (evil-replace-state-entry-hook
           (copy-sequence evil-replace-state-entry-hook))
          (evil-replace-state-exit-hook
           (copy-sequence evil-replace-state-exit-hook)))
      (my/sis--setup-evil)
      (evil-local-mode 1)
      (evil-insert-state)
      (setq input-source sis-other-source)
      (evil-normal-state)
      (should (equal input-source sis-english-source))
      (should (eq (window-parameter nil 'my/sis-source) 'other))
      (evil-insert-state)
      (should (equal input-source sis-other-source))
      (evil-normal-state)
      (evil-replace-state)
      (should (equal input-source sis-other-source))
      (evil-normal-state)
      (should (equal input-source sis-english-source))
      (evil-insert-state)
      (should (equal input-source sis-other-source)))))

(provide 'init-base-test)
;;; init-base-test.el ends here
