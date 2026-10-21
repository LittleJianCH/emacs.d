;;; agent-pi.el --- Pi daemon registration -*- lexical-binding: t; -*-

;;; Commentary:
;; Execution and policy live in emx/backends/pi.ts and emx/config.json.
;; This module is loaded only when pi is enabled in `my/agents'.

;;; Code:
(require 'agent-emx)

(agent-session-define-agent pi :title "Pi" :backend emx
  :executable "pi" :emx-agent "pi")

(provide 'agent-pi)
;;; agent-pi.el ends here
