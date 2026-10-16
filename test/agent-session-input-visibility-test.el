;;; agent-session-input-visibility-test.el --- Draft viewport tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-session)

(ert-deftest agent-session-input-visibility-streaming ()
  "Streaming output leaves the whole wrapped draft and a spare line visible."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (agent-session-mode)
      (insert (make-string 200 ?\n))
      (let ((input (copy-marker (point) t)))
        (setq agent-session--current
              (agent-session--make :buffer (current-buffer) :input input))
        (insert "first line\n" (make-string (+ 20 (window-body-width)) ?x))
        (set-marker-insertion-type input nil)
        ;; The cursor can be at the start, not just the end of the draft.
        (goto-char input)
        (set-window-start nil (point-min))
        (dotimes (_ 3)
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char input)
              (insert-before-markers (make-string 80 ?\n))))
          (let ((cursor (point))
                (draft (buffer-substring-no-properties input (point-max))))
            (agent-session--keep-input-visible (selected-window))
            (should (= cursor (point)))
            (should (equal draft
                           (buffer-substring-no-properties input (point-max))))
            (should (<= (window-start) input))
            (should (<= (cdr (window-text-pixel-size
                              nil (window-start) (point-max)))
                        (- (window-text-height nil t)
                           (window-font-height))))))))))

(ert-deftest agent-session-input-visibility-history ()
  "Reading history is not pulled back to the draft."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (agent-session-mode)
      (insert (make-string 200 ?\n))
      (setq agent-session--current
            (agent-session--make :buffer (current-buffer)
                                 :input (copy-marker (point))))
      (insert "draft")
      (goto-char (point-min))
      (set-window-start nil (point-min))
      (agent-session--keep-input-visible (selected-window))
      (should (= (window-start) (point-min)))
      (should (= (point) (point-min))))))

(ert-deftest agent-session-input-visibility-oversized ()
  "An oversized draft leaves ordinary cursor scrolling in control."
  (save-window-excursion
    (with-temp-buffer
      (switch-to-buffer (current-buffer))
      (agent-session-mode)
      (setq agent-session--current
            (agent-session--make :buffer (current-buffer)
                                 :input (copy-marker (point))))
      (insert (make-string 200 ?\n))
      (goto-char (point-min))
      (set-window-start nil (point-min))
      (agent-session--keep-input-visible (selected-window))
      (should (= (point) (point-min)))
      (should (= (window-start) (point-min))))))

(provide 'agent-session-input-visibility-test)
;;; agent-session-input-visibility-test.el ends here
