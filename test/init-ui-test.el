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

;;; init-ui-test.el ends here
