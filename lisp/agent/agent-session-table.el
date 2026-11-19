;;; agent-session-table.el --- Inline transcript tables -*- lexical-binding: t; -*-

;;; Commentary:
;; Render complete Markdown tables after fontification, preserving cell faces.
;; Retain fontified cells on the grid so cached replies can reflow without
;; fontifying again.  The linkify adapter and buffer-local redisplay hook keep
;; this integration here rather than changing the session's rendering pipeline.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defvar agent-session--current)
(declare-function agent-session-blocks "agent-session" (session))
(declare-function agent-session--render "agent-session" (session id))

(defvar-local agent-session-table--last-width nil)

(defun agent-session-table--width ()
  "Return the grid budget in columns for the current transcript.
Use the narrowest window showing it, allowing two columns for the reply
prefix and one for Emacs's continuation indicator."
  (max 1 (- (apply #'min
                   (mapcar #'window-body-width
                           (or (get-buffer-window-list (current-buffer) nil t)
                               (list (selected-window)))))
            3)))

(defun agent-session-table--face-p (pos face)
  "Return non-nil when FACE occurs at POS."
  (let ((faces (get-text-property pos 'face)))
    (or (eq faces face) (and (listp faces) (memq face faces)))))

(defun agent-session-table--cells ()
  "Read cells on the current line, preserving text properties."
  (let ((end (line-end-position)) cuts)
    (save-excursion
      (beginning-of-line)
      (while (search-forward "|" end t)
        (let ((pos (1- (point))) (slashes 0))
          (save-excursion
            (goto-char pos)
            (while (eq (char-before) ?\\)
              (cl-incf slashes)
              (backward-char)))
          (unless (or (cl-oddp slashes)
                      (agent-session-table--face-p pos 'markdown-inline-code-face))
            (push pos cuts)))))
    (setq cuts (nreverse cuts))
    (cl-loop for (left right) on cuts while right
             collect (string-trim (buffer-substring (1+ left) right)))))

(defun agent-session-table--visible (cell)
  "Remove hidden markup from CELL while retaining its visible faces."
  (let ((pos 0) parts)
    (while (< pos (length cell))
      (let ((next (or (next-single-property-change pos 'invisible cell)
                      (length cell))))
        (unless (get-text-property pos 'invisible cell)
          (push (substring cell pos next) parts))
        (setq pos next)))
    (apply #'concat (nreverse parts))))

(defun agent-session-table--wrap (cell width)
  "Split CELL into property-preserving lines of at most WIDTH columns.
Prefer whitespace breaks, but split long tokens and CJK prose as needed.
No character, including whitespace, is discarded.  A glyph wider than
WIDTH occupies a line by itself."
  (let ((start 0) (size (length cell)) lines)
    (while (< start size)
      (let ((end start) space)
        (while (and (< end size)
                    (or (= end start)
                        (<= (string-width (substring cell start (1+ end)))
                            width)))
          (when (memq (aref cell end) '(?\s ?\t))
            (setq space (1+ end)))
          (cl-incf end))
        (when (and (< end size) space (> space start))
          (setq end space))
        (push (substring cell start end) lines)
        (setq start end)))
    (or (nreverse lines) (list ""))))

(defun agent-session-table--widths (cells count budget)
  "Allocate COUNT column widths for CELLS within BUDGET, or return nil.
Short columns retain their natural width; spare space goes to longer ones."
  (let* ((natural (cl-loop for i below count
                           collect (apply #'max 1
                                          (mapcar (lambda (row)
                                                    (string-width
                                                     (or (nth i row) "")))
                                                  cells))))
         ;; Each column has two padding spaces and a border, plus the left edge.
         (available (- budget (* 3 count) 1))
         (widths (cl-loop for i below count
                          collect (apply #'max 1
                                         (cl-loop for row in cells append
                                                  (mapcar #'char-width
                                                          (nth i row)))))))
    (cond
     ((<= (apply #'+ natural) available) natural)
     ((<= (apply #'+ widths) available)
      (let ((left (- available (apply #'+ widths))))
        (while (> left 0)
          (let ((smallest
                 (cl-loop for width in widths for limit in natural
                          when (< width limit) minimize width)))
            (cl-loop for tail on widths for limit in natural
                     when (and (> left 0) (= (car tail) smallest)
                               (< (car tail) limit))
                     do (cl-incf (car tail)) (cl-decf left)))))
      widths))))

(defun agent-session-table--grid (rows formats &optional budget)
  "Render ROWS as a fixed-pitch grid within BUDGET, using column FORMATS.
When columns cannot fit even one glyph each, stack the cells vertically.
If a single boxed cell cannot fit, omit borders and separate cells by blank
lines."
  (let* ((cells (mapcar (lambda (row)
                          (mapcar #'agent-session-table--visible row))
                        rows))
         (budget (or budget (agent-session-table--width)))
         (widths (agent-session-table--widths cells (length formats) budget)))
    (unless widths
      (setq cells (cl-loop for row in cells append (mapcar #'list row))
            formats '("---")
            widths (agent-session-table--widths cells 1 budget)))
    (with-temp-buffer
      (cl-labels
          ((rule (left middle right)
             (insert left
                     (mapconcat (lambda (width) (make-string (+ width 2) ?─))
                                widths middle)
                     right "\n"))
           (row (values header)
             (let* ((lines (cl-loop for width in widths for i from 0
                                    collect (agent-session-table--wrap
                                             (or (nth i values) "") width)))
                    (height (apply #'max (mapcar #'length lines))))
               (dotimes (line height)
                 (insert "│")
                 (cl-loop for width in widths for fmt in formats
                          for parts in lines
                          for cell = (copy-sequence (or (nth line parts) ""))
                          for extra = (- width (string-width cell))
                          for left = (cond ((string-suffix-p ":" fmt)
                                            (if (string-prefix-p ":" fmt)
                                                (/ extra 2) extra))
                                           (t 0))
                          do (when header
                               (add-face-text-property 0 (length cell) 'bold t cell))
                          (insert " " (make-string left ?\s) cell
                                  (make-string (- extra left) ?\s) " │"))
                 (insert "\n")))))
        (if widths
            (progn
              (rule "┌" "┬" "┐")
              (row (car cells) t)
              (rule "├" "┼" "┤")
              (dolist (values (cdr cells)) (row values nil))
              (rule "└" "┴" "┘"))
          (dolist (values cells)
            (insert (string-join (agent-session-table--wrap (car values) budget)
                                 "\n")
                    "\n\n"))))
      (add-face-text-property (point-min) (point-max) 'fixed-pitch t)
      (buffer-string))))

(defun agent-session-table--render (rows formats width)
  "Render ROWS with FORMATS and WIDTH, retaining the source for reflow."
  (propertize (agent-session-table--grid rows formats width)
              'agent-session-table (list rows formats)))

(defun agent-session-table--linkify (function text root)
  "Reflow tables in TEXT and link their cells with FUNCTION relative to ROOT.
This small adapter keeps the cached Markdown independent of window size.
Linkify before hiding markup and wrapping so split link labels stay buttons."
  (if (not (text-property-not-all 0 (length text)
                                  'agent-session-table nil text))
      (funcall function text root)
    (let ((width (agent-session-table--width)))
      (when (derived-mode-p 'agent-session-mode)
        ;; Rendering one new reply must not mark older tables as reflowed.
        (unless agent-session-table--last-width
          (setq agent-session-table--last-width width))
        (add-hook 'pre-redisplay-functions #'agent-session-table--resize nil t))
      (funcall
       function
       (with-temp-buffer
         (insert text)
         (goto-char (point-min))
         (while (< (point) (point-max))
           (let* ((start (point))
                  (data (get-text-property start 'agent-session-table))
                  (end (next-single-property-change start 'agent-session-table
                                                    nil (point-max))))
             (if (not data)
                 (goto-char end)
               (let ((grid (agent-session-table--render
                            (mapcar (lambda (row)
                                      (mapcar (lambda (cell)
                                                (funcall function cell root))
                                              row))
                                    (car data))
                            (cadr data) width)))
                 ;; Buttons belong to this rendering, never to the cached source.
                 (put-text-property 0 (length grid) 'agent-session-table data grid)
                 (dolist (prop '(line-prefix wrap-prefix))
                   (put-text-property 0 (length grid) prop
                                      (get-text-property start prop) grid))
                 (delete-region start end)
                 (insert grid)))))
         (buffer-string))
       root))))

(defun agent-session-table--resize (window)
  "Reflow completed table replies when WINDOW's available width changes."
  (when (and (eq (window-buffer window) (current-buffer))
             agent-session--current
             (not (equal agent-session-table--last-width
                         (agent-session-table--width))))
    (let ((width (agent-session-table--width)) ids)
      (maphash
       (lambda (id block)
         (let ((cached (cdr (plist-get block :markdown))))
           (when (and (stringp cached)
                      (text-property-not-all 0 (length cached)
                                             'agent-session-table nil cached))
             (push id ids))))
       (agent-session-blocks agent-session--current))
      (dolist (id ids)
        (agent-session--render agent-session--current id))
      ;; Leave a failed resize eligible for retry on the next redisplay.
      (setq agent-session-table--last-width width))))

(with-eval-after-load 'agent-session
  (advice-add 'agent-session--linkify :around #'agent-session-table--linkify))

(defun agent-session-table-render (text)
  "Render complete pipe tables in fontified TEXT; leave code untouched.
In a session buffer, tag the source for expansion by the linkify adapter.
This preserves source offsets until code run buttons have been inserted."
  (let ((width (agent-session-table--width))
        (defer (derived-mode-p 'agent-session-mode)))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*|.*|[ \t]*$" nil t)
        (let ((start (line-beginning-position)))
          (when (agent-session-table--face-p start 'markdown-table-face)
            (let ((header (agent-session-table--cells)))
              (forward-line 1)
              (when (and (looking-at-p "^[ \t]*|[-:| \t]+|[ \t]*$")
                         (agent-session-table--face-p (point) 'markdown-table-face))
                (let ((formats (agent-session-table--cells)))
                  (when (and (= (length header) (length formats))
                             formats
                             (cl-every (lambda (s)
                                         (string-match-p "^:?-\\{3,\\}:?$" s))
                                       formats))
                    (forward-line 1)
                    (let ((rows (list header)))
                      (while (and (looking-at-p "^[ \t]*|.*|[ \t]*$")
                                  (agent-session-table--face-p
                                   (point) 'markdown-table-face))
                        (push (agent-session-table--cells) rows)
                        (forward-line 1))
                      (let ((grid (if defer
                                      (propertize (buffer-substring start (point))
                                                  'agent-session-table
                                                  (list (nreverse rows) formats))
                                    (agent-session-table--render
                                     (nreverse rows) formats width))))
                        (delete-region start (point))
                        (goto-char start)
                        (insert grid))))))))))
      (buffer-string))))

(provide 'agent-session-table)
;;; agent-session-table.el ends here
