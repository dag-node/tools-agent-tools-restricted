;; SPDX-License-Identifier: AGPL-3.0-only
;; The column each file kind wraps its prose at, for Emacs's paragraph filler and for
;; tools/fill-comments.sh, which fills through it. A config file header holds to 72 (the RFC
;; text width); a source comment wraps at 120; a Markdown page at 100. The tie rule that goes
;; with these widths is tools/emacs/ai-tools-fill.el.
((conf-mode . ((fill-column . 72)))
 (conf-unix-mode . ((fill-column . 72)))
 (sh-mode . ((fill-column . 120)))
 (python-mode . ((fill-column . 120)))
 (csharp-mode . ((fill-column . 120)))
 (emacs-lisp-mode . ((fill-column . 100)))
 (markdown-mode . ((fill-column . 100))))
