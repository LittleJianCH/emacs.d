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
(require 'flymake)

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

(ert-deftest init-ui-accent-band-is-readable ()
  "The selected window's mode line is the accent color, its text readable.
Grey bands of slightly different shades made the selected window hard to
find."
  (dolist (variant '(light dark))
    (let ((palette (alist-get variant my/nano-palettes)))
      (should (equal (plist-get (init-ui-test--attrs (intern (format "my-nano-%s" variant))
                                                     'mode-line)
                                :background)
                     (plist-get palette :accent)))
      (should (>= (init-ui-test--contrast (plist-get palette :on-accent)
                                          (plist-get palette :accent))
                  4.5))
      (should (>= (init-ui-test--contrast (plist-get palette :on-accent-dim)
                                          (plist-get palette :accent))
                  3.0)))))

(ert-deftest init-ui-own-mode-lines-go-plain-on-the-band ()
  "Agent sessions' own mode lines drop their colors only when selected."
  (cl-letf (((symbol-function 'format-mode-line)
             ;; `format-mode-line' returns "" in batch.
             (lambda (&rest _)
               (concat (propertize "Opus" 'face 'agent-session-dim
                                   'local-map (make-sparse-keymap))
                       " · 自动"))))
    (cl-letf (((symbol-function 'mode-line-window-selected-p) (lambda () t)))
      (let ((text (my/mode-line-plain-when-selected '("x"))))
        (should-not (get-text-property 0 'face text))
        ;; Clicking the model still works.
        (should (get-text-property 0 'local-map text))))
    (cl-letf (((symbol-function 'mode-line-window-selected-p) #'ignore))
      (should (eq (get-text-property 0 'face (my/mode-line-plain-when-selected '("x")))
                  'agent-session-dim))))
  (should (memq #'my/mode-line-plain-on-band agent-session-mode-hook))
  (with-temp-buffer
    (setq mode-line-format '((:eval (own-mode-line))))
    (my/mode-line-plain-on-band)
    (my/mode-line-plain-on-band)
    (should (equal mode-line-format
                   '((:eval (my/mode-line-plain-when-selected
                             '((:eval (own-mode-line))))))))))

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

(defun init-ui-test--fonts-with (installed)
  "Run `my/setup-fonts' as if only INSTALLED families existed.
Return the default family and height, and the family set for Han."
  (let (default height han)
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&rest _) t))
              ((symbol-function 'find-font)
               ;; Font specs hold the family as a symbol.
               (lambda (spec &rest _) (member (format "%s" (font-get spec :family)) installed)))
              ((symbol-function 'set-face-attribute)
               (lambda (face _frame &rest args)
                 (when (eq face 'default)
                   (setq default (plist-get args :family)
                         height (plist-get args :height)))))
              ((symbol-function 'set-fontset-font)
               (lambda (_fontset charset spec &rest _)
                 (when (eq charset 'han) (setq han (format "%s" (font-get spec :family)))))))
      (my/setup-fonts))
    (list default height han)))

(ert-deftest init-ui-fonts-prefer-aligned-cjk ()
  "A font with CJK twice the Latin width serves both scripts, at its size.
Menlo with PingFang SC put 14px CJK glyphs in 16px of columns, so tables
with Chinese drifted.  Sarasa needs an even pixel size to stay aligned."
  (should (equal (init-ui-test--fonts-with
                  '("Menlo" "PingFang SC" "Maple Mono Normal NL NF CN" "Sarasa Term SC"))
                 '("Sarasa Term SC" 160 "Sarasa Term SC")))
  (should (equal (init-ui-test--fonts-with '("Menlo" "PingFang SC" "Maple Mono Normal NL NF CN"))
                 '("Maple Mono Normal NL NF CN" 140 "Maple Mono Normal NL NF CN")))
  (should (equal (init-ui-test--fonts-with '("Menlo" "PingFang SC"))
                 '("Menlo" 140 "PingFang SC"))))

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

(ert-deftest init-ui-mode-line-info-hides-empty-diagnostics ()
  "Diagnostic counters show only when there is something to report."
  (with-temp-buffer
    (setq mode-name "Rust")
    ;; `format-mode-line' returns "" in batch; strings format to themselves.
    (cl-letf (((symbol-function 'format-mode-line)
               (lambda (format &rest _) (if (stringp format) format ""))))
      (let ((flymake-mode t) (flymake-mode-line-counters "[0 0]"))
        (should (equal (my/mode-line-info) "Rust"))
        (setq flymake-mode-line-counters "[2 0]")
        (should (equal (my/mode-line-info) "Rust · [2 0]"))))))

(ert-deftest init-ui-side-panels ()
  "The session list is drawn as a side panel: tinted and without a mode line."
  (with-temp-buffer
    (agent-session-list-mode)
    (should (assq 'default face-remapping-alist))
    (should-not mode-line-format)))

(ert-deftest init-ui-session-list-header-buttons-are-plain ()
  "The session list's header buttons read like the text around them.
They used to be bold \"[+ 新建]\" / \"[刷新]\" in the agent heading face."
  (with-temp-buffer
    (agent-session-list-mode)
    (let ((header (eval (cadr header-line-format) t)))
      (should (string-match-p "会话  新建  刷新" header))
      (should-not (string-match-p "\\[" header))
      (let ((pos (string-search "新建" header)))
        (should-not (get-text-property pos 'face header))
        (should (get-text-property pos 'mouse-face header))))))

;;; init-ui-test.el ends here
