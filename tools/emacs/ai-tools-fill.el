;;; ai-tools-fill.el --- fill comment prose without ending a line on a tie word  -*- lexical-binding: t -*-
;; SPDX-License-Identifier: AGPL-3.0-only
;;
;; The formatter for the wrap rule the writing standard states: a comment is read as written, so
;; each file kind wraps at its own column, and no comment line ends on an article, a conjunction,
;; a preposition, or a wh-word. Where a line BREAKS is this file's rule alone -- `prose-check.py'
;; measures the width and does not read where a line ends. The column is `fill-column', which
;; `.dir-locals.el' at the repository root sets per mode. Emacs's paragraph filler already knows
;; every language's comment syntax, so the rule is a `fill-nobreak-predicate' hook.
;;
;; Interactive use: load this file, then `M-q' on a comment block. Batch use over whole files:
;; `bash tools/fill-comments.sh <file>...', which calls `ai-tools-fill-comments-file'.
;;
;; The batch filler is conservative on purpose. It fills a run of consecutive lines that carry the
;; same comment prefix followed by one space and text, and leaves every other shape as it finds
;; it: a run holding a line with extra indentation (an aligned table, an example command), a
;; linter directive, an SPDX header, a commented default (`#KEY=value'), a shebang, a lone token
;; on a line of its own (a path, a URL), a rule or banner line, and a lone `#' separator.
;; A docstring is not a comment and is not read.

(defconst ai-tools-tie-words
  '("a" "an" "the" "and" "or" "nor" "but" "so" "yet"
    "of" "to" "in" "on" "at" "by" "for" "with" "from" "into" "onto" "upon" "over" "under"
    "above" "below" "between" "among" "through" "during" "before" "after" "about" "against"
    "along" "across" "around" "near" "off" "out" "up" "down" "via" "per" "as"
    "what" "which" "who" "whom" "whose" "that" "when" "where" "why" "how")
  "The words a line does not end on: they tie to the word after them.
Mirrors `_AI_TOOLS_MSG_TIES' in `msg.lib.sh', the runtime's own copy. `tools/fill-markdown.py'
reads this list at run time, so the two formatters share it.")

(defun ai-tools-no-break-after-tie ()
  "Non-nil when the word before point is a tie word, so the filler does not break here.
A word closing a sentence is not a tie; trailing punctuation around the word is ignored."
  (save-excursion
    (skip-chars-backward " \t")
    (let ((end (point)))
      (skip-chars-backward "^ \t\n")
      (let ((word (buffer-substring-no-properties (point) end)))
        (and (not (string-match-p "[.!?]\\'" word))
             (member (downcase (string-trim-right word "[,;:)\"'`]+")) ai-tools-tie-words))))))

(add-hook 'fill-nobreak-predicate #'ai-tools-no-break-after-tie)

(defconst ai-tools-fill--prose-line "^\\([ \t]*\\(?:#\\|//\\)\\) \\([^ \t].*\\)$"
  "A comment line the batch filler may fill: prefix, one space, text.")

(defconst ai-tools-fill--skip-line
  (concat "^[ \t]*\\(?:#\\|//\\)[ \t]*"
          "\\(?:!\\|shellcheck\\b\\|noqa\\b\\|pylint:\\|type:\\|pragma\\b\\|SPDX-"
          "\\|ref-index:\\|prose-check:"
          "\\|[A-Za-z_][A-Za-z0-9_]*=\\|[^ \t\n]+$\\|.*[-=_*─━]\\{3,\\}\\)")
  "A comment line the batch filler leaves alone, and that ends the run before it: a shebang,
a linter directive, an SPDX header, a checker marker (`ref-index: ignore-file', `prose-check:
ignore'), a commented default, a lone token (a path, a URL, a name on a line of its own), and a
rule or banner line. A marker joined into the paragraph above it stops marking.")

(defconst ai-tools-fill--joined-sentence "\\([.!?][]\"')}]*\\)  \\([^ ]\\)"
  "A sentence end carrying two spaces: the punctuation with its closers, and the next word.")

(defun ai-tools-fill--single-space (beg end)
  "Leave one space after each sentence end between BEG and END.
`fill-delete-newlines' adds a space after a sentence that ended a line, and the squeeze pass that
would take it back is the one NOSQUEEZE turns off. NOSQUEEZE is what keeps an aligned fragment's
own column spacing -- a doc comment's `$1 path   file to check' -- so the fill keeps it and the
space a join added is taken back here, where a column of spaces is not touched."
  (save-excursion
    (goto-char beg)
    (while (re-search-forward ai-tools-fill--joined-sentence end t)
      (replace-match "\\1 \\2" t))))

(defun ai-tools-fill--run-in-ranges (beg end ranges)
  "Non-nil when the lines from BEG to END (exclusive) meet a range in RANGES.
RANGES is a list of (FIRST . LAST) line-number pairs, inclusive; nil means every run."
  (or (null ranges)
      (let ((first (line-number-at-pos beg))
            (last (1- (line-number-at-pos end))))
        (seq-some (lambda (range) (and (<= (car range) last) (>= (cdr range) first)))
                  ranges))))

(defun ai-tools-fill-comments (&optional ranges)
  "Fill every plain comment paragraph in the current buffer at `fill-column'.
With RANGES, a list of (FIRST . LAST) line-number pairs, fill only a paragraph meeting one,
which is how `tools/format.sh' fills what a diff touched. Returns the number of paragraphs
filled. See the file header for what is left alone."
  (let ((filled 0)
        (sentence-end-double-space nil)
        (colon-double-space nil))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (if (and (looking-at ai-tools-fill--prose-line)
                 (not (looking-at ai-tools-fill--skip-line)))
            (let* ((prefix (match-string 1))
                   (beg (point))
                   (plain t)
                   (run-re (concat "^" (regexp-quote prefix) " "))
                   (line-re (concat "^" (regexp-quote prefix) " [^ \t]")))
              (while (and (not (eobp))
                          (looking-at run-re)
                          (not (looking-at ai-tools-fill--skip-line)))
                (unless (looking-at line-re) (setq plain nil))
                (forward-line 1))
              (when (and plain (ai-tools-fill--run-in-ranges beg (point) ranges))
                (let ((end (point-marker))
                      (fill-prefix (concat prefix " ")))
                  (fill-region beg end nil t)
                  (ai-tools-fill--single-space beg end)
                  (goto-char end)
                  (setq filled (1+ filled)))))
          (forward-line 1))))
    filled))

(defun ai-tools-fill-comments-file (file &optional width ranges)
  "Fill the plain comment paragraphs of FILE in place and save it.
The mode and `fill-column' come from the file's extension and the repository's .dir-locals.el;
WIDTH overrides the column, and RANGES confines the fill as in `ai-tools-fill-comments'.
Writes no backup and no lock file."
  (let ((create-lockfiles nil)
        (make-backup-files nil))
    (with-current-buffer (find-file-noselect file)
      (let ((fill-column (or width fill-column))
            (require-final-newline nil))
        (let ((count (ai-tools-fill-comments ranges)))
          (when (buffer-modified-p)
            (save-buffer))
          (message "%s: %d comment paragraph(s) filled at %d columns" file count fill-column))))))

(provide 'ai-tools-fill)
;;; ai-tools-fill.el ends here
