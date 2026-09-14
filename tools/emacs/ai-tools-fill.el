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
;; The batch filler is conservative on purpose. It fills a run of consecutive lines carrying the
;; same comment prefix, one space and text, and leaves every other shape as it finds it: a run
;; one of whose lines is indented deeper (an aligned table, an example command), a run drawing a
;; table or a diagram (two lines carrying a vertical rule at the same column -- the reading
;; `tools/align-tables.py' states, and the tool that puts such a table in order), a line inside a
;; string or inside a CDATA or `<pre>' region, and every line `ai-tools-fill--skip-line' names.
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

(defconst ai-tools-fill--code-span "\\(`+\\)[^`]*?\\1"
  "An inline code span: a backtick run, content without a backtick, and a matching run.
`tools/fill-markdown.py' reads the checker's `BACKTICK_SPAN' for the same rule, which elisp
cannot read, so this states it again -- narrower in one way, since a span whose content holds a
backtick run of another length is not matched.")

(defun ai-tools-no-break-in-code-span ()
  "Non-nil when point stands inside a code span, so the filler does not break there.
A span holds a literal a reader searches for whole -- a command line, an owner and mode, a flag
with its operand -- and `grep' finds one only while its span is on one line. A span wider than
the column runs the line over instead, since a wider line is still a line."
  (save-match-data
    (let ((break (point))
          (inside nil))
      (save-excursion
        (goto-char (line-beginning-position))
        (let ((limit (line-end-position)))
          (while (and (not inside)
                      (re-search-forward ai-tools-fill--code-span limit t))
            (when (and (< (match-beginning 0) break) (> (match-end 0) break))
              (setq inside t)))))
      inside)))

(add-hook 'fill-nobreak-predicate #'ai-tools-no-break-in-code-span)

(defconst ai-tools-fill--prose-line "^\\([ \t]*\\(?:#\\|//\\)\\) \\([^ \t].*\\)$"
  "A comment line the batch filler may fill: prefix, one space, text.")

(defconst ai-tools-fill--verbatim-open "<!\\[CDATA\\[\\|<pre\\b"
  "What opens a region a reader gets byte for byte: a CDATA section, a `<pre>' block.")

(defconst ai-tools-fill--verbatim-close "\\]\\]>\\|</pre>"
  "What closes the region `ai-tools-fill--verbatim-open' opens.")

(defconst ai-tools-fill--skip-line
  (concat "^[ \t]*\\(?:#\\|//\\)[ \t]*"
          "\\(?:!\\|shellcheck\\b\\|noqa\\b\\|pylint:\\|type:\\|pragma\\b\\|SPDX-"
          "\\|ref-index:\\|prose-check:"
          "\\|args:\\|stdout:\\|stderr:\\|returns?:\\|\\$[0-9]"
          "\\|[A-Za-z_][A-Za-z0-9_]*=\\|[^ \t\n]+$\\|.*[^ ] \\{3,\\}[^ ]"
          "\\|.*\\(?:" ai-tools-fill--verbatim-open "\\|" ai-tools-fill--verbatim-close "\\)"
          "\\|.*[-=_*─━]\\{3,\\}\\)")
  "A comment line the batch filler leaves alone, and that ends the run before it: a shebang,
a linter directive, an SPDX header, a checker marker (`ref-index: ignore-file', `prose-check:
ignore'), a commented default, a lone token (a path, a URL, a name on a line of its own), a rule
or banner line, a doc comment's contract line (`args:', `stdout:', `$1 path'), and a line holding
a column of three or more spaces. The last two are code rather than prose -- a signature, a
parameter table, an example rule -- and a fill reads them as a sentence and wraps the columns
away. A marker joined into the paragraph above it stops marking.")

(defconst ai-tools-fill--vertical-rule "[|│┃║]"
  "A character drawing a vertical rule in an ASCII diagram or a comment table.")

(defun ai-tools-fill--vertical-columns (line)
  "The columns LINE carries a vertical rule at.
`string-match' sets the match data, so the caller's own match is saved around it."
  (save-match-data
    (let ((columns nil) (start 0))
      (while (string-match ai-tools-fill--vertical-rule line start)
        (push (match-beginning 0) columns)
        (setq start (match-end 0)))
      columns)))

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

(defvar ai-tools-fill--verbatim-present nil
  "Non-nil while the buffer being filled holds a verbatim opener.
`ai-tools-fill-comments' binds it, so the scan behind `ai-tools-fill--in-verbatim-p' runs only
over a buffer that has one.")

(defun ai-tools-fill--in-verbatim-p ()
  "Non-nil when the line at point sits inside a CDATA section or a `<pre>' block.
Both hold text a reader gets byte for byte -- an XML payload, preformatted output -- so a line
break inside one is content, whatever comment marker the line carries."
  (and ai-tools-fill--verbatim-present
       (save-match-data
         (save-excursion
           (let ((limit (line-beginning-position))
                 (depth 0)
                 (either (concat ai-tools-fill--verbatim-open "\\|"
                                 ai-tools-fill--verbatim-close)))
             (goto-char (point-min))
             (while (re-search-forward either limit t)
               (setq depth (if (string-match-p ai-tools-fill--verbatim-close (match-string 0))
                               (max 0 (1- depth))
                             (1+ depth))))
             (> depth 0))))))

(defun ai-tools-fill--in-string-p ()
  "Non-nil when the line at point sits inside a string, which the mode's syntax decides.
A heredoc body is the case that matters: the text is data this file writes or feeds elsewhere --
a seeded config header, a fixture, an embedded script -- so a comment marker in it belongs to
that text rather than to this file, and filling it rewrites what the file emits.
`syntax-ppss' searches, so the caller's `looking-at' match is saved around it."
  (save-match-data (nth 3 (syntax-ppss (line-beginning-position)))))

(defun ai-tools-fill--range-markers (ranges)
  "RANGES, a list of (FIRST . LAST) line-number pairs, as (START . END) marker pairs.
Filling a paragraph shortens the buffer, so a line number read after the first fill names a line
the caller did not ask for. The numbers are resolved once, before any fill, and the markers then
move with the text they cover."
  (mapcar (lambda (range)
            (cons (save-excursion (goto-char (point-min))
                                  (forward-line (1- (car range)))
                                  (point-marker))
                  (save-excursion (goto-char (point-min))
                                  (forward-line (cdr range))
                                  (point-marker))))
          ranges))

(defun ai-tools-fill--run-in-ranges (beg end ranges)
  "Non-nil when the region from BEG to END meets a range in RANGES.
RANGES is the marker list `ai-tools-fill--range-markers' builds; nil means every run."
  (or (null ranges)
      (seq-some (lambda (range) (and (< (marker-position (car range)) end)
                                     (> (marker-position (cdr range)) beg)))
                ranges)))

(defun ai-tools-fill-comments (&optional ranges)
  "Fill every plain comment paragraph in the current buffer at `fill-column'.
With RANGES, a list of (FIRST . LAST) line-number pairs, fill only a paragraph meeting one,
which is how `tools/format.sh' fills what a diff touched. Returns the number of paragraphs
filled. See the file header for what is left alone."
  (let ((filled 0)
        (sentence-end-double-space nil)
        (colon-double-space nil)
        (ranges (and ranges (ai-tools-fill--range-markers ranges)))
        (ai-tools-fill--verbatim-present
         (save-excursion (goto-char (point-min))
                         (re-search-forward ai-tools-fill--verbatim-open nil t))))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (if (and (looking-at ai-tools-fill--prose-line)
                 (not (looking-at ai-tools-fill--skip-line))
                 (not (ai-tools-fill--in-string-p))
                 (not (ai-tools-fill--in-verbatim-p)))
            (let* ((prefix (match-string 1))
                   (beg (point))
                   (plain t)
                   (drawn nil)
                   (verticals nil)
                   (run-re (concat "^" (regexp-quote prefix) " "))
                   (line-re (concat "^" (regexp-quote prefix) " [^ \t]")))
              (while (and (not (eobp))
                          (looking-at run-re)
                          (not (looking-at ai-tools-fill--skip-line)))
                (unless (looking-at line-re) (setq plain nil))
                (let ((columns (ai-tools-fill--vertical-columns
                                (buffer-substring-no-properties (point) (line-end-position)))))
                  (when (seq-intersection columns verticals) (setq drawn t))
                  (setq verticals columns))
                (forward-line 1))
              (when (and plain (not drawn) (ai-tools-fill--run-in-ranges beg (point) ranges))
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
