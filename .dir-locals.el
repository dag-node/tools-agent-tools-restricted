;; SPDX-License-Identifier: AGPL-3.0-only
;; The column each file kind wraps its prose at, for Emacs's paragraph filler and for
;; tools/fill-comments.sh, which fills through it. It mirrors prose-check.py's widths, so the
;; formatter and the checker cannot disagree: a config file header holds to 72 (the RFC text
;; width), a source comment to 120, and a Markdown page to the column ITS READER takes -- 80 for
;; a page a person reads, 120 for the router, the rules and the skills an agent retrieves with
;; grep. The subdirectory entries carry that second column, and CLAUDE.md a file-local block of
;; its own, since dir-locals keys on a directory rather than on a file name. Where a line breaks
;; is the filler's, through tools/emacs/ai-tools-fill.el.
((conf-mode . ((fill-column . 72)))
 (conf-unix-mode . ((fill-column . 72)))
 (sh-mode . ((fill-column . 120)))
 (python-mode . ((fill-column . 120)))
 (csharp-mode . ((fill-column . 120)))
 (emacs-lisp-mode . ((fill-column . 120)))
 (markdown-mode . ((fill-column . 80)))
 (".claude/" . ((markdown-mode . ((fill-column . 120)))))
 ("src/usr/share/ai-tools/skills/" . ((markdown-mode . ((fill-column . 120))))))
