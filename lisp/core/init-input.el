;;; init-input.el --- Input sources per editing window -*- lexical-binding: t; -*-

;;; Commentary:

;; Keep each window's preferred input source across temporary English commands.
;; Window parameters also keep two views of the same buffer independent.

;;; Code:

(defvar sis-global-respect-mode)
(defvar sis--current)
(defvar sis--for-buffer-locked)
(defvar sis-do-get)
(defvar evil-state)

(declare-function sis--normalize-to-lang "sis")
(declare-function sis--set "sis")
(declare-function sis-set-english "sis")
(declare-function sis-prefix-override-buffer-enable "sis")

(defvar my/sis--window nil
  "Last selected non-minibuffer window.")
(defvar my/sis--temporary nil
  "Non-nil while applying a temporary input source.")

(defun my/sis--editing-p (window)
  "Return non-nil when WINDOW accepts text rather than modal commands."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (with-current-buffer (window-buffer window)
         (and (not buffer-read-only)
              (or (not (bound-and-true-p evil-local-mode))
                  (memq evil-state '(insert replace emacs)))))))

(defun my/sis--save-window (window &optional source)
  "Remember SOURCE for WINDOW, reading the OS when SOURCE is nil."
  (when (my/sis--editing-p window)
    (with-current-buffer (window-buffer window)
      ;; A prefix or focus change may already have forced English.
      (unless sis--for-buffer-locked
        (let ((language (or source
                            (sis--normalize-to-lang (funcall sis-do-get)))))
          (when (memq language '(english other))
            (set-window-parameter window 'my/sis-source language)))))))

(defun my/sis--remember-source ()
  "Remember observed source changes in the active editing window."
  (when (and sis-global-respect-mode
             (not my/sis--temporary)
             (eq my/sis--window (selected-window))
             (eq (current-buffer) (window-buffer my/sis--window)))
    (my/sis--save-window my/sis--window sis--current)))

(defun my/sis--select-window ()
  "Save the outgoing window before restoring the selected window."
  (unless (or (window-minibuffer-p (selected-window))
              (eq my/sis--window (selected-window)))
    ;; Read once at the transition, including IME changes not yet polled by sis.
    (when (window-live-p my/sis--window)
      (my/sis--save-window my/sis--window))
    (setq my/sis--window (selected-window))))

(defun my/sis--restore-window ()
  "Restore the selected window's source, using English for modal commands."
  (my/sis--select-window)
  (with-current-buffer (window-buffer (selected-window))
    (setq sis--for-buffer-locked nil)
    (let ((my/sis--temporary t))
      (sis--set (if (my/sis--editing-p (selected-window))
                    (or (window-parameter nil 'my/sis-source) 'english)
                  'english)))))

(defun my/sis--restore-buffer (original &rest args)
  "Use window preferences in place of sis's ORIGINAL buffer restoration."
  (if sis-global-respect-mode
      (my/sis--restore-window)
    (apply original args)))

(defun my/sis--window-change (frame)
  "Restore input preference after selection changes in FRAME."
  (when (and sis-global-respect-mode
             (eq frame (selected-frame))
             (not (window-minibuffer-p (selected-window)))
             (not (eq my/sis--window (selected-window))))
    (my/sis--restore-window)))

(defun my/sis--before-minibuffer (&rest _)
  "Save the editing source before a minibuffer temporarily selects English."
  (when sis-global-respect-mode
    (my/sis--save-window (or (minibuffer-selected-window) my/sis--window))))

(defun my/sis--leave-insert ()
  "Save the editing source before temporarily switching to English."
  (when sis-global-respect-mode
    (my/sis--select-window)
    (my/sis--save-window (selected-window))
    (let ((my/sis--temporary t))
      (sis-set-english))))

(defun my/sis--enter-insert ()
  "Recover this window's editing source on entering insert or replace state."
  (when sis-global-respect-mode
    (my/sis--restore-window)))

(defun my/sis--setup-evil (&rest _)
  "Preserve insert-state sources when sis configures Evil."
  (with-eval-after-load 'evil
    (remove-hook 'evil-insert-state-exit-hook #'sis-set-english)
    (dolist (hook '(evil-insert-state-exit-hook evil-replace-state-exit-hook))
      (add-hook hook #'my/sis--leave-insert))
    (dolist (hook '(evil-insert-state-entry-hook evil-replace-state-entry-hook))
      (add-hook hook #'my/sis--enter-insert))))

(defun my/sis--english-source (&optional enabled-sources)
  "Return the English keyboard layout enabled in macOS.
ENABLED-SOURCES is the output of reading AppleEnabledInputSources;
it is read from the system when nil.  Machines enable either the ABC
or the U.S. layout, and sis can only switch to an enabled one."
  (let ((text (or enabled-sources
                  (with-output-to-string
                    (call-process "defaults" nil standard-output nil "read"
                                  "com.apple.HIToolbox"
                                  "AppleEnabledInputSources"))))
        (start 0)
        source)
    (while (and (not source)
                (string-match "\"KeyboardLayout ID\" = \\([0-9]+\\);"
                              text start))
      (setq start (match-end 0)
            source (pcase (match-string 1 text)
                     ("252" "com.apple.keylayout.ABC")
                     ("0" "com.apple.keylayout.US"))))
    (or source "com.apple.keylayout.US")))

(defun my/sis-enable-agent-prefixes ()
  "Keep input-source switching active in agent conversation buffers."
  ;; sis normally excludes buffers named *...*, including our editable UI.
  (setq-local sis-prefix-override-buffer-disable-predicates nil)
  (sis-prefix-override-buffer-enable))

(defvar sis-prefix-override-keys)
(defvar sis-prefix-override-buffer-disable-predicates)
(declare-function sis-ism-lazyman-config "sis")
(declare-function sis-global-respect-mode "sis")

(use-package sis
  :ensure t
  :defer t)

(defun my/sis--configure ()
  "Configure sis for macism; safe to run again on reload."
  (setq sis-prefix-override-keys '("C-c" "C-x" "C-h" "M-g" "M-s"))
  (sis-ism-lazyman-config (my/sis--english-source)
                         "com.apple.inputmethod.SCIM.Shuangpin" 'macism)
  (advice-add 'sis--restore-from-buffer :around #'my/sis--restore-buffer)
  (advice-add 'sis--respect-evil :after #'my/sis--setup-evil)
  (advice-add 'sis--minibuffer-setup-handler :before
              #'my/sis--before-minibuffer)
  (add-hook 'sis-change-hook #'my/sis--remember-source)
  (add-hook 'window-selection-change-functions #'my/sis--window-change)
  (add-hook 'agent-session-mode-hook #'my/sis-enable-agent-prefixes)
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p 'agent-session-mode)
        (my/sis-enable-agent-prefixes))))
  ;; Re-enabling respect mode during reload must not erase window preferences.
  (let ((my/sis--temporary t))
    (sis-global-respect-mode 1))
  (my/sis--restore-window))

(defun my/sis--start (&optional frame)
  "Set up sis once FRAME, or the selected frame, is graphical.
A daemon has no graphical frame while it reads the init files, so it
waits for the first one a client opens."
  (when (and (eq system-type 'darwin)
             (display-graphic-p frame)
             (executable-find "macism"))
    (remove-hook 'after-make-frame-functions #'my/sis--start)
    (with-selected-frame (or frame (selected-frame))
      (require 'sis)
      (my/sis--configure))))

(if (and (daemonp) (not (display-graphic-p)))
    (add-hook 'after-make-frame-functions #'my/sis--start)
  (my/sis--start))

(provide 'init-input)
;;; init-input.el ends here
