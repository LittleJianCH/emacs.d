;;; agent-canvas-test.el --- Tests for agent-canvas -*- lexical-binding: t; -*-

;;; Commentary:

;; Draws pages in the batch frame's window.
;; Run with the other tests (see AGENTS.md), or alone:
;;   emacs --batch --init-directory=. -l init.el -l test/agent-canvas-test.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'agent-canvas)

(defmacro agent-canvas-test--with-page (blocks &rest body)
  "Draw a page of BLOCKS in the selected window, then run BODY in it."
  (declare (indent 1))
  `(let ((buffer (agent-canvas--buffer "agent-canvas-test")))
     (unwind-protect
         (with-current-buffer buffer
           (set-window-buffer (selected-window) buffer)
           (setq agent-canvas--page
                 (list :title "agent-canvas-test"
                       :blocks (agent-canvas--load-sources ,blocks)))
           (agent-canvas--redraw (selected-window))
           ,@body)
       (kill-buffer buffer))))

(defun agent-canvas-test--text ()
  "The page text without properties."
  (buffer-substring-no-properties (point-min) (point-max)))

(defun agent-canvas-test--image-slices ()
  "Return (POSITION . DISPLAY) entries for all image slices in the buffer."
  (let ((pos (point-min)) slices)
    (while (< pos (point-max))
      (let ((display (get-text-property pos 'display)))
        (when (and (consp display) (eq (caar display) 'slice))
          (push (cons pos display) slices)))
      (setq pos (next-single-property-change pos 'display nil (point-max))))
    (nreverse slices)))

(ert-deftest agent-canvas-test-images-have-contiguous-line-sized-slices ()
  (dolist (size '((309 . 600) (348 . 621) (309 . 494) (309 . 7)))
    (let ((image '(image :type svg :data "<svg/>" :max-width 348 :ascent center)))
      (with-temp-buffer
        ;; Keep the real image inserter; batch Emacs cannot size GUI images.
        (cl-letf (((symbol-function 'image-size)
                   (lambda (spec pixels &optional _frame)
                     (should (equal spec image))
                     (should pixels)
                     size))
                  ((symbol-function 'default-line-height) (lambda () 20)))
          (agent-canvas--insert-image image "[图]"))
        (let ((slices (agent-canvas-test--image-slices))
              (end 0))
          (should (= (length slices) (max 1 (floor (cdr size) 20))))
          (dolist (entry slices)
            (pcase-let* ((`(,pos . ((slice ,x ,y ,width ,height) ,spec)) entry)
                         (newline (+ pos (length "[图]"))))
              (should (equal spec image))
              (should (= x 0))
              (should (= width (car size)))
              (should (= y end))
              (should (integerp height))
              (should (<= 1 height 39))
              (setq end (+ y height))
              (should (equal (buffer-substring-no-properties pos newline) "[图]"))
              (should (eq (char-after newline) ?\n))
              (should (eq (get-text-property newline 'line-height) t))
              (should-not (get-text-property newline 'display))))
          (should (= end (cdr size)))
          (should (eq (plist-get (cdr image) :ascent) 'center))
          (should (= (count-lines (point-min) (point-max)) (length slices))))))))

(ert-deftest agent-canvas-test-image-slices-preserve-pixel-size ()
  (skip-unless (and (display-graphic-p) (image-type-available-p 'svg)))
  (dolist (size '((309 . 600) (348 . 621) (309 . 494)))
    (dolist (prefix '("" "  " "▍ "))
      (with-temp-buffer
        (let* ((image (svg-image (svg-create (car size) (cdr size))
                                 :ascent 'center :max-width (car size)))
               (agent-canvas--prefix prefix))
          (agent-canvas--insert-image image "[图]")
          (agent-canvas--decorate (point-min))
          (should (equal (cons (+ (car size) (agent-canvas--px prefix)) (cdr size))
                         (buffer-text-pixel-size (current-buffer)
                                                 nil 1000 2000))))))))

(ert-deftest agent-canvas-test-all-image-blocks-slice-and-refresh ()
  (let* ((blocks (vector
                  (list :type "diagram" :id "diagram"
                        :nodes [(:id "a" :label "A")] :edges [])
                  (list :type "chart" :id "chart" :kind "bar"
                        :labels ["a"] :series [(:name "n" :values [1])])
                  (list :type "image" :id "image" :path "picture.png" :width 60)))
         (section (list :type "section" :title "Images" :blocks blocks))
         (size '(309 . 621)))
    ;; Exercise GUI renderer branches without requiring a batch window system.
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _display) t))
              ((symbol-function 'agent-canvas--px) #'string-width)
              ((symbol-function 'agent-canvas--hex)
               (lambda (_face &optional _attribute) "#888888"))
              ((symbol-function 'image-size)
               (lambda (_image &optional _pixels _frame) size))
              ((symbol-function 'default-line-height) (lambda () 20))
              ((symbol-function 'svg-image)
               (lambda (_svg &rest props) (cons 'image (append '(:type svg) props))))
              ((symbol-function 'create-image)
               (lambda (file &optional _type _data &rest props)
                 (cons 'image (append (list :type 'png :file file) props)))))
      (agent-canvas-test--with-page (vector section)
        (let ((before (agent-canvas-test--image-slices)))
          (should-not agent-canvas--errors)
          (should (= (length before) (* 3 (max 1 (floor (cdr size) 20)))))
          (dolist (block (append blocks nil))
            (let ((slices (seq-filter
                           (lambda (entry)
                             (eq (get-text-property (car entry) 'agent-canvas-block)
                                 block))
                           before)))
              (should (= (length slices) (max 1 (floor (cdr size) 20))))
              (dolist (entry slices)
                (let* ((pos (car entry))
                       (spec (cadr (cdr entry)))
                       (props (cdr spec))
                       (expected-width
                        (let ((agent-canvas--prefix "  "))
                          (min (agent-canvas--avail)
                               (or (plist-get block :width) most-positive-fixnum)))))
                  (should (= (plist-get props :max-width) expected-width))
                  (should (equal (get-text-property pos 'line-prefix) "  "))
                  (should (equal (get-text-property pos 'wrap-prefix) "  "))
                  (save-excursion
                    (goto-char pos)
                    (end-of-line)
                    (should (eq (get-text-property (point) 'agent-canvas-block)
                                block))
                    (should (eq (get-text-property (point) 'line-height) t)))))))
          (agent-canvas-refresh)
          (should-not agent-canvas--errors)
          (should (equal before (agent-canvas-test--image-slices))))))))

(ert-deftest agent-canvas-test-elisp-state-survives-redraws ()
  (agent-canvas-test--with-page
      (vector (list :type "elisp"
                    :code "(insert (format \"n=%d\\n\" (agent-canvas-state 'n 0)))"))
    (should (string-search "n=0" (agent-canvas-test--text)))
    (agent-canvas-set 'n 2)
    (should (string-search "n=2" (agent-canvas-test--text)))
    (agent-canvas--redraw (selected-window))
    (should (string-search "n=2" (agent-canvas-test--text)))))

(ert-deftest agent-canvas-test-elisp-set-while-drawing-does-not-recurse ()
  (agent-canvas-test--with-page
      (vector (list :type "elisp"
                    :code "(agent-canvas-set 'runs (1+ (agent-canvas-state 'runs 0)))
                           (insert \"ok\\n\")"))
    (should (= 1 (agent-canvas-state 'runs)))))

(ert-deftest agent-canvas-test-elisp-error-drops-partial-output ()
  (agent-canvas-test--with-page
      (vector (list :type "elisp" :id "bad" :code "(insert \"half drawn\") (error \"boom\")")
              (list :type "text" :text "after"))
    (let ((text (agent-canvas-test--text)))
      (should-not (string-search "half drawn" text))
      (should (string-search "boom" text))
      (should (string-search "after" text)))
    (should (equal agent-canvas--errors '("elisp#bad: boom")))))

(ert-deftest agent-canvas-test-refresh-updates-page-time ()
  (agent-canvas-test--with-page (vector (list :type "text" :text "x"))
    (setq agent-canvas--time 0)
    (agent-canvas--redraw (selected-window))
    (should (equal agent-canvas--time 0))
    (agent-canvas-refresh)
    (should-not (equal agent-canvas--time 0))))

(ert-deftest agent-canvas-test-elisp-timers-cancelled-on-redraw ()
  (agent-canvas-test--with-page
      (vector (list :type "elisp" :code "(agent-canvas-timer 60 #'ignore)"))
    (let ((timer (car agent-canvas--timers)))
      (should (memq timer timer-list))
      (agent-canvas--redraw (selected-window))
      (should-not (memq timer timer-list))
      (should (= 1 (length agent-canvas--timers))))
    (let ((timer (car agent-canvas--timers)))
      (kill-buffer (current-buffer))
      (should-not (memq timer timer-list)))))

(ert-deftest agent-canvas-test-elisp-file-is-read-at-render ()
  (let ((file (make-temp-file "agent-canvas-test-" nil ".el" "(insert \"from file\\n\")")))
    (agent-canvas-test--with-page
        (vector (list :type "section" :title "s"
                      :blocks (vector (list :type "elisp" :file file))))
      (delete-file file)
      (agent-canvas--redraw (selected-window))
      (should (string-search "from file" (agent-canvas-test--text))))))

(ert-deftest agent-canvas-test-blocks-drawn-by-elisp-belong-to-it ()
  (let ((block (list :type "elisp"
                     :code "(agent-canvas-blocks (list (list :type \"text\" :text \"inner\")))")))
    (agent-canvas-test--with-page (vector block)
      (goto-char (point-min))
      (search-forward "inner")
      (should (equal (plist-get (get-text-property (point) 'agent-canvas-block) :type)
                     "elisp")))))

(ert-deftest agent-canvas-test-nested-blocks-keep-their-source ()
  (agent-canvas-test--with-page
      (vector (list :type "section" :title "outer"
                    :blocks (vector (list :type "text" :text "inner text"))))
    (goto-char (point-min))
    (search-forward "inner text")
    (should (equal (plist-get (get-text-property (1- (point)) 'agent-canvas-block) :type)
                   "text"))
    (search-backward "outer")
    (should (equal (plist-get (get-text-property (point) 'agent-canvas-block) :type)
                   "section"))))

(ert-deftest agent-canvas-test-read-forms-names-the-line ()
  (should (equal (agent-canvas--read-forms "(insert \"a\") ; note\n(insert \"b\")")
                 '((insert "a") (insert "b"))))
  (should (string-match-p "\\`Line 2: form not closed"
                          (cadr (should-error (agent-canvas--read-forms "(insert \"a\")\n(let ((x 1))\n x")))))
  (should (string-match-p "\\`Line 1: .*extra closing"
                          (cadr (should-error (agent-canvas--read-forms "(insert \"a\"))"))))))

(ert-deftest agent-canvas-test-check-elisp-finds-misplaced-parens ()
  ;; The let closes too early, so the last form uses `file' unbound.
  (let ((warnings (agent-canvas--check-elisp
                   "(let ((file \"x\"))\n  (insert file))\n(insert file)")))
    (should (equal warnings '("reference to free variable ‘file’"))))
  (should-not (agent-canvas--check-elisp "(let ((file \"x\")) (insert file))"))
  (should (equal (agent-canvas--check-elisp "(agent-canvas-state)")
                 '("‘agent-canvas-state’ called with 0 arguments, but requires 1 or 2"))))

(ert-deftest agent-canvas-test-load-sources-collects-warnings ()
  (let ((agent-canvas--warnings nil))
    (agent-canvas--load-sources
     (vector (list :type "section" :title "s"
                   :blocks (vector (list :type "elisp" :id "x" :code "(insert y)")))))
    (should (equal agent-canvas--warnings '("elisp#x: reference to free variable ‘y’")))))

(ert-deftest agent-canvas-test-examples-are-clean ()
  (let ((files (directory-files agent-canvas--examples-directory t "\\.el\\'")))
    (should files)
    (dolist (file files)
      (let ((code (with-temp-buffer (insert-file-contents file) (buffer-string))))
        (should (equal (list file nil) (list file (agent-canvas--check-elisp code))))
        (agent-canvas-test--with-page (vector (list :type "elisp" :code code))
          (should (equal (list file nil) (list file agent-canvas--errors))))))))

(ert-deftest agent-canvas-test-guide-lists-and-returns-examples ()
  (let ((guide (agent-ui--method-canvas_guide nil)))
    (should (string-search "agent-canvas-timer" guide))
    (should (string-search "- command-bench: Command bench:" guide)))
  (should (string-prefix-p ";; Theme picker"
                           (agent-ui--method-canvas_guide '(:example "theme-picker"))))
  (should-error (agent-ui--method-canvas_guide '(:example "nope"))))

(ert-deftest agent-canvas-buttons-are-flat ()
  "Agent buttons are flat pills, independent of the mode-line faces.
They used to inherit `mode-line-inactive' and look like raised 3D keys."
  (dolist (face '(agent-session-button agent-canvas-button))
    (should (eq (plist-get (face-attribute face :box) :style) 'flat-button))
    (should (stringp (face-attribute face :background)))
    (should-not (memq 'mode-line-inactive
                      (ensure-list (face-attribute face :inherit))))))

(provide 'agent-canvas-test)

;;; agent-canvas-test.el ends here
