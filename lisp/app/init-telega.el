;;; init-telega.el --- Telegram client (telega) -*- lexical-binding: t; -*-

;;; Commentary:

;; telega talks to Telegram through TDLib, via its own `telega-server'
;; binary.  telega needs a recent TDLib (`telega-tdlib-min-version') and
;; Homebrew's tdlib is far too old, so build it from source at the commit
;; telega's etc/Dockerfile pins (`tdlib_branch') and install it into
;; `my/tdlib-prefix':
;;
;;   git clone https://github.com/tdlib/td.git && cd td
;;   git checkout <tdlib_branch>
;;   cmake -B build -DCMAKE_BUILD_TYPE=Release \
;;         -DOPENSSL_ROOT_DIR=/opt/homebrew/opt/openssl@3 \
;;         -DCMAKE_INSTALL_PREFIX=$HOME/.local/opt/tdlib
;;   cmake --build build --target install -j 8
;;
;; The first M-x telega builds telega-server against it.  When an updated
;; telega asks for a newer TDLib, rebuild TDLib the same way, then run
;; M-x telega-server-build.

;;; Code:

(defcustom my/tdlib-prefix (expand-file-name "~/.local/opt/tdlib")
  "Prefix TDLib is installed into, with include/ and lib/ below it."
  :type 'directory
  :group 'convenience)

(use-package telega
  :ensure t
  :bind-keymap ("C-c T" . telega-prefix-map)
  :custom
  ;; Login database, downloads and the telega-server binary live here.
  (telega-directory (my/var "telega/"))
  (telega-server-libs-prefix my/tdlib-prefix))

(provide 'init-telega)
;;; init-telega.el ends here
