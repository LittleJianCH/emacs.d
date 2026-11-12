;;; knowledge-mcp-test.el --- Knowledge base MCP server tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Drive bin/knowledge-mcp as an MCP client would: a subprocess speaking JSON-RPC
;; over stdio, started with a minimal environment like a desktop client's.
;; Each test serves a temporary knowledge base with a temporary index cache.

;;; Code:

(require 'test-helper
         (expand-file-name "test-helper.el"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'ert)
(require 'cl-lib)
(add-to-list 'load-path (expand-file-name "lisp/app" emx-test--checkout))
(require 'knowledge-batch)

(defvar knowledge-mcp-test--process nil "The server of the running test.")
(defvar knowledge-mcp-test--output "" "Output of the server not yet read.")
(defvar knowledge-mcp-test--id 0 "Id of the last request.")

(defun knowledge-mcp-test--start (root cache &optional client)
  "Start the server on ROOT with the index cache CACHE, then initialize.
CLIENT is the client name sent; the result of initialize is returned."
  (setq knowledge-mcp-test--output ""
        knowledge-mcp-test--process
        (let ((process-environment
               (list (concat "HOME=" (getenv "HOME")) "PATH=/usr/bin:/bin"
                     (concat "KNOWLEDGE_MCP_CACHE=" cache)
                     ;; The Emacs running the tests, whatever PATH holds.
                     (concat "KNOWLEDGE_MCP_EMACS=" (expand-file-name invocation-name
                                                               invocation-directory))))
              (default-directory "/"))
          (make-process :name "knowledge-mcp-test" :connection-type 'pipe :noquery t
                        :command (list (expand-file-name "bin/knowledge-mcp" emx-test--checkout)
                                       root)
                        :stderr (get-buffer-create " *knowledge-mcp-test stderr*")
                        :filter (lambda (_ string)
                                  (setq knowledge-mcp-test--output
                                        (concat knowledge-mcp-test--output string))))))
  (knowledge-mcp-test--request "initialize"
                        `((protocolVersion . "2025-06-18") (capabilities)
                          (clientInfo (name . ,(or client "test-client"))
                                      (version . "1")))))

(defun knowledge-mcp-test--send (message)
  "Send MESSAGE, an alist, as one line."
  (process-send-string knowledge-mcp-test--process
                       (concat (decode-coding-string (json-serialize message) 'utf-8)
                               "\n")))

(defun knowledge-mcp-test--line ()
  "Return the next line the server writes, parsed."
  (let ((deadline (time-add nil 60)))
    (while (and (not (string-search "\n" knowledge-mcp-test--output))
                (time-less-p nil deadline))
      (accept-process-output knowledge-mcp-test--process 0.1))
    (let ((end (or (string-search "\n" knowledge-mcp-test--output)
                   (error "No response from knowledge-mcp"))))
      (prog1 (json-parse-string (decode-coding-string
                                 (substring knowledge-mcp-test--output 0 end) 'utf-8)
                                :object-type 'alist :array-type 'list
                                :null-object nil :false-object :false)
        (setq knowledge-mcp-test--output (substring knowledge-mcp-test--output (1+ end)))))))

(defun knowledge-mcp-test--request (method &optional params)
  "Send the request METHOD with PARAMS; return the whole response."
  (knowledge-mcp-test--send `((jsonrpc . "2.0") (id . ,(cl-incf knowledge-mcp-test--id))
                       (method . ,method)
                       ,@(and params `((params . ,params)))))
  (let ((response (knowledge-mcp-test--line)))
    (should (equal (alist-get 'id response) knowledge-mcp-test--id))
    response))

(defun knowledge-mcp-test--call (tool &optional arguments)
  "Call TOOL with ARGUMENTS; return its value, or (error . TEXT) on failure."
  (let* ((result (alist-get 'result
                            (knowledge-mcp-test--request
                             "tools/call" `((name . ,tool)
                                            (arguments . ,(or arguments
                                                              (make-hash-table)))))))
         (text (alist-get 'text (car (alist-get 'content result)))))
    (if (eq (alist-get 'isError result) t)
        (cons 'error text)
      (json-parse-string text :object-type 'alist :array-type 'list
                         :null-object nil :false-object :false))))

(defmacro knowledge-mcp-test--with-server (client &rest body)
  "Run BODY with a server for CLIENT on an empty knowledge base `root'.
`cache' is its index cache directory."
  (declare (indent 1) (debug t))
  `(let* ((root (file-name-as-directory (file-truename (make-temp-file "knowledge-mcp-" t))))
          (cache (make-temp-file "knowledge-mcp-cache-" t))
          (knowledge-mcp-test--id 0))
     (ignore cache)
     (unwind-protect
         (progn (knowledge-mcp-test--start root cache ,client) ,@body)
       (when (process-live-p knowledge-mcp-test--process)
         (process-send-eof knowledge-mcp-test--process)
         (let ((deadline (time-add nil 10)))
           (while (and (process-live-p knowledge-mcp-test--process)
                       (time-less-p nil deadline))
             (accept-process-output knowledge-mcp-test--process 0.1))))
       (delete-directory root t)
       (delete-directory cache t))))

(defun knowledge-mcp-test--file (root file)
  "Return the contents of FILE under ROOT."
  (with-temp-buffer
    (insert-file-contents (expand-file-name file root))
    (buffer-string)))

(defun knowledge-mcp-test--errors (root)
  "Return the error findings of the validator for ROOT."
  (seq-filter (lambda (finding) (eq (nth 3 finding) 'error))
              (cdr (my/knowledge-findings root))))

;;; Protocol

(ert-deftest knowledge-mcp-handshake-and-protocol-errors ()
  "Initialize echoes the version; notifications get no answer; bad input
and unknown methods or tools get errors, and the server keeps serving."
  (knowledge-mcp-test--with-server "claude-code"
    (let ((result (alist-get 'result (knowledge-mcp-test--request
                                      "initialize"
                                      '((protocolVersion . "2025-03-26")
                                        (clientInfo (name . "claude-code")))))))
      (should (equal (alist-get 'protocolVersion result) "2025-03-26"))
      (should (equal (alist-get 'name (alist-get 'serverInfo result)) "knowledge"))
      (should (string-match-p "never confirm" (alist-get 'instructions result))))
    (knowledge-mcp-test--send '((jsonrpc . "2.0") (method . "notifications/initialized")))
    ;; The next line answers the ping, not the notification.
    (should (equal (alist-get 'result (knowledge-mcp-test--request "ping")) nil))
    (should (equal (mapcar (lambda (tool) (alist-get 'name tool))
                           (alist-get 'tools (alist-get 'result
                                                        (knowledge-mcp-test--request "tools/list"))))
                   '("knowledge_search" "knowledge_get_concept" "knowledge_create_concept" "knowledge_set_level"
                     "knowledge_add_relation" "knowledge_append_notes" "knowledge_log_session" "knowledge_check")))
    (process-send-string knowledge-mcp-test--process "not json\n")
    (should (equal (alist-get 'code (alist-get 'error (knowledge-mcp-test--line))) -32700))
    (should (equal (alist-get 'code (alist-get 'error (knowledge-mcp-test--request "nope/nope")))
                   -32601))
    (should (equal (knowledge-mcp-test--call "knowledge_nope") '(error . "Unknown tool knowledge_nope")))
    (should (equal (alist-get 'total (knowledge-mcp-test--call "knowledge_search")) 0))))

;;; Tools

(ert-deftest knowledge-mcp-creates-valid-concepts ()
  "Concepts created by assistants follow the format, start unconfirmed,
take the slug as file name and keep ordinary file modes; names are unique."
  (knowledge-mcp-test--with-server nil
    (let ((created (knowledge-mcp-test--call
                    "knowledge_create_concept"
                    '((title . "Martin-Löf Type Theory") (aliases . ["MLTT" "依值类型论"])
                      (tags . ["type_theory"]) (level . "can-explain")
                      (notes . "- Π、Σ 和恒等类型")))))
      (should (equal (alist-get 'file created) "concepts/martin_lof_type_theory.org"))
      (should (eq (alist-get 'confirmed created) :false))
      (knowledge-mcp-test--call "knowledge_create_concept"
                         '((title . "Normalization by Evaluation") (aliases . ["NbE"])
                           (relations . [((relation . "requires") (concept . "mltt"))])))
      (let ((text (knowledge-mcp-test--file root "concepts/martin_lof_type_theory.org")))
        (should (string-prefix-p
                 (format ":PROPERTIES:\n:ID:       %s\n:ROAM_ALIASES: MLTT 依值类型论\n"
                         (alist-get 'id created))
                 text))
        (should (string-match-p ":LEVEL:    can-explain\n:CONFIRMED: nil\n" text))
        (should (string-match-p "#\\+filetags: :type_theory:\n\n\\* Notes\n- Π、Σ 和恒等类型\n"
                                text)))
      (should (string-match-p
               (format "\\* Relations\n- requires :: \\[\\[id:%s\\]\\[Martin-Löf Type Theory\\]\\]"
                       (alist-get 'id created))
               (knowledge-mcp-test--file root "concepts/normalization_by_evaluation.org")))
      (should (= (file-modes (expand-file-name "concepts/normalization_by_evaluation.org"
                                               root))
                 (logand #o666 (default-file-modes))))
      (should-not (knowledge-mcp-test--errors root))
      (dolist (bad '(((title . "依值类型论"))
                     ((title . "Two\nlines"))
                     ((title . "X") (level . "expert"))
                     ((title . "Y") (notes . "* Heading"))
                     ((title . "Z") (tags . ["bad tag"]))
                     ((title . "W") (relations . [((relation . "likes") (concept . "NbE"))]))
                     ((title . "V") (relations . [((relation . "requires") (concept . "Nope"))]))))
        (ert-info ((format "%S" bad))
          (should (eq (car-safe (knowledge-mcp-test--call "knowledge_create_concept" bad)) 'error))))
      (should (= (length (directory-files (expand-file-name "concepts" root) nil "\\.org\\'"))
                 2)))))

(ert-deftest knowledge-mcp-never-confirms-a-level ()
  "Setting a level, even of a confirmed concept, leaves it unconfirmed."
  (knowledge-mcp-test--with-server nil
    (make-directory (expand-file-name "concepts" root))
    (with-temp-file (expand-file-name "concepts/nbe.org" root)
      (insert ":PROPERTIES:\n:ID:       id-n\n:LEVEL:    can-explain\n:CONFIRMED: t\n"
              ":UPDATED:  [2026-01-01]\n:END:\n#+title: NbE\n"))
    (should (equal (knowledge-mcp-test--call "knowledge_set_level" '((concept . "id-n")
                                                       (level . "implemented")))
                   '((id . "id-n") (title . "NbE") (previous . "can-explain")
                     (level . "implemented") (confirmed . :false))))
    (let ((text (knowledge-mcp-test--file root "concepts/nbe.org")))
      (should (string-match-p ":LEVEL:    implemented\n:CONFIRMED: nil\n" text))
      (should (string-match-p (regexp-quote (concat ":UPDATED:  " (my/knowledge-date-string)))
                              text)))
    (should (equal (knowledge-mcp-test--call "knowledge_search" '((confirmed . t))) '((total . 0) (concepts))))
    (should (eq (car-safe (knowledge-mcp-test--call "knowledge_set_level" '((concept . "NbE")
                                                              (level . "master"))))
                'error))))

(ert-deftest knowledge-mcp-relations-notes-sessions-and-reading ()
  "Relations, notes and sessions are written in the editor's format and
read back with incoming relations and covering sessions."
  (knowledge-mcp-test--with-server "claude-ai"
    (knowledge-mcp-test--call "knowledge_create_concept" '((title . "MLTT")))
    (knowledge-mcp-test--call "knowledge_create_concept" '((title . "NbE") (tags . ["type_theory"])))
    (should (equal (knowledge-mcp-test--call "knowledge_add_relation" '((concept . "NbE") (relation . "requires")
                                                          (target . "MLTT")))
                   '((concept . "NbE") (relation . "requires") (target . "MLTT"))))
    (should (eq (car-safe (knowledge-mcp-test--call "knowledge_add_relation"
                                             '((concept . "NbE") (relation . "requires")
                                               (target . "MLTT"))))
                'error))
    (knowledge-mcp-test--call "knowledge_append_notes" '((concept . "NbE") (text . "- eval 进语义域")))
    (knowledge-mcp-test--call "knowledge_append_notes" '((concept . "NbE") (text . "- quote 读回范式")))
    (let ((logged (knowledge-mcp-test--call "knowledge_log_session"
                                     '((topic . "NbE 的实现") (concepts . ["NbE" "MLTT" "nbe"])
                                       (date . "2026-11-12") (time . "14:30")
                                       (notes . "- 讨论了 quote")))))
      ;; The client is Claude, so the AI is too; NbE counts once.
      (should (equal logged '((file . "sessions/2026-11-12.org") (heading . "14:30 NbE 的实现")
                              (ai . "claude") (concepts "NbE" "MLTT")))))
    (knowledge-mcp-test--call "knowledge_log_session" '((topic . "Later") (ai . "chatgpt")
                                          (date . "2026-11-12") (time . "16:00")))
    (let ((session (knowledge-mcp-test--file root "sessions/2026-11-12.org")))
      (should (string-match-p
               (concat "\\`:PROPERTIES:\n:ID:       [-0-9a-f]+\n:END:\n#\\+title: 2026-11-12\n\n"
                       "\\* 14:30 NbE 的实现\n:PROPERTIES:\n:AI:       claude\n"
                       ":CONCEPTS: \\[\\[id:[-0-9a-f]+\\]\\[NbE\\]\\] \\[\\[id:[-0-9a-f]+\\]\\[MLTT\\]\\]\n"
                       ":END:\n- 讨论了 quote\n\n\\* 16:00 Later\n:PROPERTIES:\n:AI:       chatgpt\n"
                       ":CONCEPTS:\n:END:\n\\'")
               session)))
    (should (string-match-p "\\* Notes\n- eval 进语义域\n- quote 读回范式\n\n\\* Relations\n"
                            (knowledge-mcp-test--file root "concepts/nbe.org")))
    (should-not (knowledge-mcp-test--errors root))
    (let ((nbe (knowledge-mcp-test--call "knowledge_get_concept" '((concept . "nbe")))))
      (should (equal (alist-get 'notes nbe) "- eval 进语义域\n- quote 读回范式"))
      (should (equal (mapcar (lambda (relation) (alist-get 'relation relation))
                             (alist-get 'relations nbe))
                     '("requires")))
      (should (equal (alist-get 'sessions nbe)
                     '(((date . "2026-11-12") (heading . "14:30 NbE 的实现") (ai . "claude")))))
      (should (string-match-p "#\\+title: NbE" (alist-get 'org nbe))))
    (should (equal (mapcar (lambda (relation) (alist-get 'title relation))
                           (alist-get 'incoming (knowledge-mcp-test--call "knowledge_get_concept"
                                                                   '((concept . "MLTT")))))
                   '("NbE")))
    (should (equal (mapcar (lambda (concept) (alist-get 'title concept))
                           (alist-get 'concepts (knowledge-mcp-test--call "knowledge_search"
                                                                   '((tag . "type_theory")))))
                   '("NbE")))
    (should (equal (alist-get 'errors (knowledge-mcp-test--call "knowledge_check")) 0))))

(ert-deftest knowledge-mcp-needs-an-ai-for-unknown-clients ()
  "A session needs its AI when the client's name does not tell."
  (knowledge-mcp-test--with-server "some-editor"
    (should (string-match-p "ai is one of claude, chatgpt"
                            (cdr (knowledge-mcp-test--call "knowledge_log_session" '((topic . "X"))))))
    (should (equal (alist-get 'ai (knowledge-mcp-test--call "knowledge_log_session"
                                                     '((topic . "X") (ai . "chatgpt"))))
                   "chatgpt"))))

(ert-deftest knowledge-mcp-follows-external-changes-and-keeps-its-index ()
  "Files changed by others are read again; a restarted server reuses the
saved index."
  (knowledge-mcp-test--with-server nil
    (knowledge-mcp-test--call "knowledge_create_concept" '((title . "Alpha")))
    (let ((file (expand-file-name "concepts/alpha.org" root)))
      (with-temp-file file
        (insert (string-replace "#+title: Alpha" "#+title: Alpha Prime"
                                (knowledge-mcp-test--file root "concepts/alpha.org"))))
      (set-file-times file (time-add nil 5)))
    (should (equal (alist-get 'title (car (alist-get 'concepts (knowledge-mcp-test--call "knowledge_search"))))
                   "Alpha Prime"))
    (let ((saved (directory-files cache t "\\.eld\\'")))
      (should (= (length saved) 1))
      (should (string-search "Alpha Prime" (with-temp-buffer
                                              (insert-file-contents (car saved))
                                              (buffer-string)))))))

(provide 'knowledge-mcp-test)
;;; knowledge-mcp-test.el ends here
