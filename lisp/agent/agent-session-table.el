;;; agent-session-table.el --- Inline transcript tables -*- lexical-binding: t; -*-

;;; Commentary:
;; Render complete Markdown tables after fontification, preserving cell faces.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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

(defun agent-session-table--grid (rows formats)
  "Render ROWS as a fixed-pitch grid, respecting column FORMATS."
  (let* ((cells (mapcar (lambda (row)
                          (mapcar #'agent-session-table--visible row))
                        rows))
         (widths (cl-loop for i below (length formats)
                          collect (apply #'max 1
                                         (mapcar (lambda (row)
                                                   (string-width (or (nth i row) "")))
                                                 cells)))))
    (with-temp-buffer
      (cl-labels
          ((rule (left middle right)
             (insert left
                     (mapconcat (lambda (width) (make-string (+ width 2) ?─))
                                widths middle)
                     right "\n"))
           (row (values header)
             (insert "│")
             (cl-loop for width in widths for fmt in formats for i from 0
                      for cell = (or (nth i values) "")
                      for extra = (- width (string-width cell))
                      for left = (cond ((string-suffix-p ":" fmt)
                                        (if (string-prefix-p ":" fmt)
                                            (/ extra 2) extra))
                                       (t 0))
                      do (insert " " (make-string left ?\s)
                                 (if header (propertize cell 'face 'bold) cell)
                                 (make-string (- extra left) ?\s) " │"))
             (insert "\n")))
        (rule "┌" "┬" "┐")
        (row (car cells) t)
        (rule "├" "┼" "┤")
        (dolist (values (cdr cells)) (row values nil))
        (rule "└" "┴" "┘"))
      (add-face-text-property (point-min) (point-max) 'fixed-pitch t)
      (buffer-string))))

(defun agent-session-table-render (text)
  "Render complete pipe tables in fontified TEXT; leave code untouched."
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
                    (let ((grid (agent-session-table--grid
                                 (nreverse rows) formats)))
                      (delete-region start (point))
                      (goto-char start)
                      (insert grid))))))))))
    (buffer-string)))

(provide 'agent-session-table)
;;; agent-session-table.el ends here
