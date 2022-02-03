;;; -*- lexical-binding: t -*-

;; to use wakatime, you need to set this two variables below locally
;; (setq wakatime-api-key "your-api-key")
;; (setq wakatime-cli-path "/path/to/wakatime/cli")

(straight-use-package 'wakatime-mode)

(global-wakatime-mode)

(provide 'init-wakatime)