;;; init-ui-test.el --- Tests for the theme and UI layer -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/init-ui-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-session)
(require 'agent-session-list)
(require 'agent-canvas)

(defun init-ui-test--attrs (theme face)
  "Attributes plist THEME gives FACE."
  (cdar (nth 3 (seq-find (lambda (s) (and (eq (car s) 'theme-face) (eq (cadr s) face)))
                         (get theme 'theme-settings)))))

(ert-deftest init-ui-theme-follows-appearance ()
  "Each appearance enables exactly its own theme, never stacking them."
  (unwind-protect
      (progn
        (load-theme 'leuven t)
        (my/nano-apply-theme 'dark)
        (should (equal custom-enabled-themes '(my-nano-dark)))
        (should (eq frame-background-mode 'dark))
        (should (eq (alist-get 'ns-appearance default-frame-alist) 'dark))
        (my/nano-apply-theme 'light)
        (should (equal custom-enabled-themes '(my-nano-light))))
    (my/nano-apply-theme)))

(ert-deftest init-ui-theme-redefinition-replaces-specs ()
  "Redefining the themes replaces their specs, enabled or not.
Settings pushed onto a disabled theme used to be added beside the old
ones, so after a reload the other appearance kept its old colors."
  (unwind-protect
      (let ((my/nano-palettes (copy-tree my/nano-palettes)))
        (my/nano-apply-theme 'light)
        (plist-put (alist-get 'dark my/nano-palettes) :fg "#123456")
        (my/nano-define-themes)
        (my/nano-apply-theme 'dark)
        (should (equal (plist-get (init-ui-test--attrs 'my-nano-dark 'default) :foreground)
                       "#123456"))
        (should (= 1 (seq-count (lambda (s) (and (eq (car s) 'theme-face)
                                                  (eq (cadr s) 'default)))
                                (get 'my-nano-dark 'theme-settings)))))
    (my/nano-define-themes)
    (my/nano-apply-theme)))

(defun init-ui-test--contrast (a b)
  "WCAG contrast of hex colors A and B.
Parsed by hand: in batch, `color-name-to-rgb' snaps to terminal colors."
  (let ((lum (lambda (hex)
               (apply #'+ (cl-mapcar
                           (lambda (i w)
                             (let ((c (/ (string-to-number (substring hex i (+ i 2)) 16)
                                         255.0)))
                               (* w (if (<= c 0.03928) (/ c 12.92)
                                      (expt (/ (+ c 0.055) 1.055) 2.4)))))
                           '(1 3 5) '(0.2126 0.7152 0.0722))))))
    (let ((la (funcall lum a)) (lb (funcall lum b)))
      (/ (+ (max la lb) 0.05) (+ (min la lb) 0.05)))))

(ert-deftest init-ui-theme-text-contrast ()
  "Faces with their own text and background colors stay readable (>= 3:1).
In the dark theme the current search match used to be light text on
orange (2.5:1)."
  (dolist (variant '(light dark))
    (dolist (spec (my/nano-face-specs (alist-get variant my/nano-palettes)))
      (let* ((attrs (cdar (cadr spec)))
             (fg (plist-get attrs :foreground))
             (bg (plist-get attrs :background)))
        (when (and (stringp fg) (stringp bg))
          (should (>= (init-ui-test--contrast fg bg) 3.0)))))))

(ert-deftest init-ui-theme-keeps-structural-attributes ()
  "Theme specs replace defface specs, so they must carry their structure.
Buttons keep their flat box, panels and diffs extend to the window edge."
  (dolist (theme '(my-nano-light my-nano-dark))
    (dolist (face '(agent-session-button agent-canvas-button))
      (should (eq (plist-get (plist-get (init-ui-test--attrs theme face) :box) :style)
                  'flat-button)))
    (dolist (face '(region hl-line diff-added diff-removed my/nano-sidebar
                           agent-session-list-alert agent-session-list-alert-flash))
      (should (plist-get (init-ui-test--attrs theme face) :extend)))
    (should (plist-get (init-ui-test--attrs theme 'agent-canvas-title) :height))))

(ert-deftest init-ui-mode-line-tag ()
  "The status tag shows the buffer state, colored by it."
  (with-temp-buffer
    (let ((evil-local-mode nil))
      (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () t)))
        (should (equal (my/mode-line-tag) "RW"))
        (should (eq (get-text-property 0 'face (my/mode-line-tag)) 'my/nano-tag))
        (setq buffer-read-only t)
        (should (equal (my/mode-line-tag) "RO"))
        (should (eq (get-text-property 0 'face (my/mode-line-tag)) 'my/nano-tag-read-only)))
      (cl-letf (((symbol-function 'mode-line-window-selected-p) #'ignore))
        (should (eq (get-text-property 0 'face (my/mode-line-tag)) 'my/nano-tag-inactive))))))

(ert-deftest init-ui-side-panels ()
  "The session list is drawn as a side panel: tinted and without a mode line."
  (with-temp-buffer
    (agent-session-list-mode)
    (should (assq 'default face-remapping-alist))
    (should-not mode-line-format)))

;;; init-ui-test.el ends here
