#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# prose-check.py -- reports the rhetorical figures this skill rules out, as file:line, so the
# final-pass checklist runs mechanically instead of by eye. It ships beside the SKILL.md it
# enforces, so the rule and its check are versioned together.
#
# Seeded assets are mode 640, so run it through its interpreter:
#
#     python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py <file>...
#
# Five modes. `--staged` reads the added lines of the git index, which is what a pre-commit hook
# runs; `--message` reads a commit message, an artifact this standard covers like any other; named
# paths are read whole, for a sweep; `--kept` compares the two sides of a diff, and enforces a
# different rule -- see the `--kept` heading; `--config-header` reads a config file's header
# as fixed-width text -- see the `--config-header` heading. `--staged` sees only the added half of a sentence
# an edit split, so a hit it reports alone is worth re-checking against the whole file.
# Source files contribute their comments and docstrings, Markdown and man pages every line. The
# patterns match English, so they carry to any codebase.
#
# `--kept`: A REWRITE CHANGES THE WORDING, NOT THE CLAIM.
# Every other check reports how a sentence is written. This one reports a rewrite that changed
# what a sentence CLAIMS, which is a defect of a different kind: the prose still has to state the
# same security boundary afterwards. Three shapes, each a way an edit reads as tidying and lands
# somewhere weaker:
#
#   dropped    a security or access-control term the added prose does not restate -- a noun
#              (`secret`, `privilege`, `permission`) or the verb naming the operation the sentence
#              permits or refuses (`read`, `execute`, `map`). The usual case
#              is a swapped set -- `carries no secrets` becomes `contains only settings`, which
#              reads better and stops justifying the 644 mode it was written to justify, because a
#              setting can be a token.
#   narrowed   a plural noun restated in the singular. `does not carry any secrets` says the
#              contents and the secrets do not intersect; `must not hold a secret` says one of
#              them is absent, which is a smaller claim and a weaker justification for the mode.
#   weakened   a modality the added prose drops. `never a glob` restated as `not a glob` swaps a
#              universal for a single instance; `only`, `always`, `cannot` and `must not` go the
#              same way.
#
# Whether the new wording still rules out the same thing is a question about two sets, which a
# regex cannot decide, so all three report and leave the judgement to a reader. It compares one
# hunk at a time, so a term that merely moved to another hunk of the same file reports as dropped;
# check the file before acting.
#
# Checks read rejoined SENTENCES rather than raw lines. Wrapped prose puts the guard clause of an
# absolute on the next line, and the shape checks compare the two halves of a pivot, so both need
# the whole sentence to report anything worth reading.
#
# One default check carries a second condition for the same reason the `--all` ones do:
# `unbacked-cost` needs a cost word AND no frequency and no bounded operation in the sentence,
# either of which is what a reader checks the claim against.
#
# One default check reads the PATH as well as the sentence:
#
#   invariant-altitude a file mode, a test path, or a `file:line` reference in a root CLAUDE.md or
#                      AGENTS.md. Each is the mark of a domain rule rather than of a document that
#                      holds global invariants and routes to the rest.
#
# `--all` adds the shape checks. Each one greps a sub-shape of its rule -- the half a regex can
# see -- because the rules themselves are about meaning: "an absolute with no guard in the same
# sentence" and "a clause mirrored across a pivot" are not properties of any word list. A
# vocabulary grep for them reported correct prose on most of what it flagged when it was sampled
# against this repository, so each check now carries a second condition:
#
#   unbacked-absolute  the sentence holds an absolute AND no subordinating conjunction, since a
#                      guard clause is what those conjunctions introduce.
#   mirrored-clause    a word stem repeats across `rather than` / `instead of`, which is the
#                      mirror itself; a plain contrast puts different words on each side.
#   definitional       a head noun repeats across `is not a`, which is the restatement that makes
#                      the sentence a definition instead of a description.
#   history            the past-tense markers only. `no longer` describes a current state as often
#                      as a change, so it is left to the reader.
#
# Two more sit here because a REWRITE is what produces them, and both report ordinary English on
# some of what they flag:
#
#   fronted-quantifier-inflected  the default `does not` check in the past and participle forms,
#                      where a redraft moves the figure to escape the default check.
#   vague-verb         a verb naming no operation. `convey` is exempt in a sentence about
#                      licensing, which is the one place it is a term of art.
#
# A line carrying `prose-check: ignore` is skipped, which is how a style guide keeps the labelled
# bad examples it has to contain. In Markdown the marker goes in an HTML comment
# (`<!-- prose-check: ignore -->`), which the substring match finds and the rendered page omits.

import argparse
import re
import subprocess
import sys

IGNORE_MARKER = "prose-check: ignore"

# Any verb before `no`, rather than a list of them: an enumerated list finds only the verbs
# whoever wrote it thought of, and this construction takes every transitive verb in the language.
# A particle may sit between the verb and the quantifier (`takes away no access`).
# Exclusions keep the suggestion honest. `is`/`was`/`has`/`had` carry the existential "there is no
# X", which reads plainly and has no mechanical rewrite; `means`/`implies` negate a following
# clause rather than an object, so "no operator means no ownership" wants "means there is no
# ownership" instead. The object stop-list drops the fixed adverbials.
_QUANTIFIED_OBJECT = (r"(?:\s+(?:away|back|up|out|off|down|over|through))?"
                      r"\s+no\s+(?!longer\b|one\b|matter\b|doubt\b)([a-z][a-z-]*)")
FRONTED_QUANTIFIER = re.compile(
    r"\b(?!is\b|was\b|has\b|had\b|means\b|implies\b)([a-z]{3,}s)" + _QUANTIFIED_OBJECT)

# The same shape in the other two inflections, which is where a REWRITE puts it: `grants nothing`
# redrafted as `granted no path` clears both default checks and keeps the figure, and a participle
# (`conveying no listing`) does the same. It sits in `--all` rather than the default set because a
# reduced relative clause -- `a line carrying no prose` -- is ordinary English, so this one wants a
# reader on every hit. A rewrite pass runs `--all` for exactly this reason.
FRONTED_QUANTIFIER_INFLECTED = re.compile(
    r"\b(?!having\b|during\b)([a-z]{3,}(?:ed|ing))" + _QUANTIFIED_OBJECT)

# A subordinating conjunction is how a guard clause attaches, so a sentence carrying one has
# somewhere for the guard to be and is left to the reader. The absolute and the cost check share
# it.
GUARD = re.compile(r"\b(so|because|since|unless|when|while|until|once|only|if|where|after"
                   r"|before|without|through|via|whenever|as long as)\b")

# The second way a cost claim states its backing: a frequency or a bounded operation as the
# sentence's own subject, where no conjunction appears. `a single write of the whole text keeps
# the window negligible` names what makes it small.
COST_BACKING = re.compile(r"\b(single|one|per|bounded|scoped|cached|amortized|idempotent|no-op)\b",
                          re.I)

# A cost claim is an absolute in another vocabulary, and unbacked in the same way. `fast` and
# `slow` stay out of it: both live in compounds that are domain terms (`fast-track`, `fail-fast`),
# where the compound is the common case rather than the exception.
COST = re.compile(r"\b(cheap|cheaply|negligible|negligibly|near-zero|inexpensive|costly"
                  r"|meaningful overhead|no overhead)\b", re.I)


def unbacked_cost(sentence):
    """A cost claim in a sentence that does not name a frequency or a bounded operation."""
    match = COST.search(sentence)
    if not match or GUARD.search(sentence) or COST_BACKING.search(sentence):
        return None
    return match


# A person as the subject of a prediction, where reference prose describes the system instead.
# Two shapes: a reader handed a choice (`if you want`, `you should`), and a system given a
# preference (`a host that wants it enforced`), which writes an install invariant as something
# someone opted into.
#
# The vocabulary is small on purpose, because a default check runs on every file and three
# neighbouring registers are correct: `a reader should` in an advisory document, `you can set X`
# in a man page, and `the reader` or `the caller` naming a FUNCTION rather than a person -- so the
# subjects here are the two that name a person outright, and the modals are the two that predict
# rather than instruct.
PREDICTED_ACTION = re.compile(
    r"\b(?:if you (?:want|need|prefer|wish)"
    r"|you (?:should|will)"
    r"|(?:that|who) wants?"
    r"|(?:users?|operators?) will)\b", re.I)

# Each entry is (name, pattern, hint). The hint is what to write instead, since a report naming
# only the defect leaves the reader to rediscover the fix on every hit.
# `above`/`below` pointing at a position in the document. A code block and the paragraph that
# describes it can change order, or move to another file, without the sentence that points at
# them changing at all, so the reference goes wrong silently. Every use is reported except a
# threshold, which a number after the word marks (`below 50 columns`); a placement is written
# with another word (`under the box`, `the parent directory`).
POSITIONAL_REFERENCE = re.compile(r"\b(above|below)\b(?!\s+\d)", re.I)

# A reftag is a prefix, a dash, and a letter-digit-letter-digit id, lowercase for a place in a document
# (`ref-section-t3w4`) and uppercase in the code family (`FN-T6I7`, `NOTE-A9S0`, `MSG-N1H8`,
# `URI-G7O3`); ref-index.py beside this file states the grammar and the kinds. A prefix followed by
# anything else is a reftag a search will not find, so it is reported at the prefix. The bare
# `ref-` prefix is not read: it opens ordinary words (`ref-index.py`), where `ref-<kind>-` does not.
_REFTAG_KINDS = (r"section|table|diagram|listing|figure|equation|algorithm|chart|graph|image"
                 r"|picture|scheme|theorem|lemma|definition|proof|appendix|footnote|caption|list"
                 r"|callout|abstract|bibliography|nomenclature")
# The id is a letter, a digit, a letter, a digit, in the family's case.
REFERENCE_SHAPE = re.compile(rf"\bref-(?:{_REFTAG_KINDS})-(?![a-z][0-9][a-z][0-9]\b)[\w-]*"
                             r"|\b(?:FN|NOTE|MSG|URI)-(?![A-Z][0-9][A-Z][0-9]\b)[\w-]*")

# A reftag link's destination is generated (a relative path and an anchor), so a line holding
# one is measured without it; see `document_line_findings`.
REFTAG_LINK = re.compile(rf"(\[(?:ref-(?:{_REFTAG_KINDS})-[a-z][0-9][a-z][0-9]"
                         r"|(?:FN|NOTE|MSG|URI)-[A-Z][0-9][A-Z][0-9])\])\([^)]*\)")

DEFAULT_CHECKS = [
    ("fronted-quantifier", FRONTED_QUANTIFIER, None),  # hint derived; see suggest()
    ("nothing", re.compile(r"\bnothing\b"), "name the absent input"),
    ("positional-reference", POSITIONAL_REFERENCE,
     "name the section, function, or file the reader goes to"),
    ("reference-shape", REFERENCE_SHAPE,
     "write the reftag in full: the prefix, a dash, and its four-character id"),
    ("unbacked-cost", unbacked_cost, "name the frequency or the bounded operation"),
    ("predicted-action", PREDICTED_ACTION, "state what the system does, or give the instruction"),
]

# Third-person singular endings that need more than a dropped "s".
_ES_ENDINGS = ("sses", "shes", "ches", "xes", "zes", "oes")


def base_form(verb):
    """The base form of a third-person singular verb: carries -> carry, passes -> pass."""
    if verb.endswith("ies"):
        return verb[:-3] + "y"
    if verb.endswith(_ES_ENDINGS):
        return verb[:-2]
    return verb[:-1]


def suggest(name, match, static_hint):
    """What to write instead, derived from the match where the fix is mechanical."""
    if name == "fronted-quantifier":
        verb, obj = match.group(1), match.group(2)
        # `a` or `any` is a claim about arity, so the code decides: one parameter takes the
        # article, a variadic one pluralizes under `any`, an uncountable object takes neither.
        return f"`does not {base_form(verb)} a/any {obj}`"
    if name == "fronted-quantifier-inflected":
        # A past tense or a participle sits in a clause whose subject and tense the rewrite has to
        # keep, so naming the shape is honest where guessing a base form is not.
        return f"attach the negation to the verb, not to `{match.group(2)}`"
    return static_hint


ABSOLUTE = re.compile(r"\b(never|always|cannot)\b")

MIRROR_PIVOT = re.compile(r"\b(rather than|instead of)\b")
DEFINITIONAL_PIVOT = re.compile(r"\b(?:is|are) not (?:a|an|the)\b")

# Four characters is the shortest prefix that separates the stems this repository uses
# (`stop`/`stay`, `read`/`real`) while still tying `costs` to `costing` and `control` to
# `controls`. Words of three letters or fewer carry no stem worth matching.
WORD = re.compile(r"[a-z][a-z-]{3,}")
# Words each side of the pivot. Five is what separates a mirror from a sentence that happens to
# reuse its own subject: `a verb on ai-tools-admin rather than a binary of its own` repeats
# `binary` from six words back, and that repeat is the topic, not a mirrored clause.
MIRROR_WINDOW = 5


def stems(text, limit=None):
    """The four-character stems of the words in `text`, optionally the first or last `limit`."""
    words = WORD.findall(text.lower())
    if limit is not None:
        words = words[-limit:] if limit > 0 else words[:-limit]
    return {word[:4] for word in words}


def mirrored(sentence, pivot):
    """True when a word stem repeats across `pivot`, which is the mirror the rule names.

    `costs you a label rather than costing the sweep a target` repeats `cost`; `shipped in the
    package rather than downloaded` does not share a stem and is a plain contrast.
    """
    match = pivot.search(sentence)
    if not match:
        return None
    left = stems(sentence[:match.start()], MIRROR_WINDOW)
    right = stems(sentence[match.end():], -MIRROR_WINDOW)
    return match if left & right else None


def unbacked_absolute(sentence):
    """An absolute in a sentence with no subordinating conjunction to hang a guard on."""
    match = ABSOLUTE.search(sentence)
    return match if match and not GUARD.search(sentence) else None


# Verbs that name no operation a reader can find. `convey` is the one with a legitimate home: it
# is the GPL's own term for distributing a work, so a sentence about licensing keeps it and every
# other sentence wants the operation -- permits, transmits, states, shows.
VAGUE_VERB = re.compile(r"\b(convey|conveys|conveyed|conveying|upkeep|leverage|leverages"
                        r"|leveraged|utilize|utilizes|utilized|facilitate|facilitates"
                        r"|facilitated)\b", re.I)
LICENSING = re.compile(r"\b(GPL|AGPL|licen[cs]|copyright|corresponding source)", re.I)


def vague_verb(sentence):
    """A vague verb, except `convey` where the sentence is about licensing."""
    match = VAGUE_VERB.search(sentence)
    if match and match.group(0).lower().startswith("convey") and LICENSING.search(sentence):
        return None
    return match


# A word that fixes a set's size the way a numeral does. `both`, `the two` and `the pair` break
# on the next member exactly as `two` does -- a third config file turns `seeds both` into a
# sentence that is wrong about what it describes -- and they break more quietly, because they
# read as pronouns rather than as claims.
#
# Only the PRONOUN form is reported: the word standing where its members would be named, as the
# subject or the object of the clause (`both are best-effort`, `seeds both`, `the two agree`).
# `both files` and `the two strategies` name what is counted, which is what the rule asks for, so
# a following noun is left alone -- as is a sentence that enumerates its members beside the word
# (`both the manifest and the key`, `A and B both hold`), since a reader there can see what a
# third member would join.
#
# `either` and `neither` are out of the set: their common forms are the correlative (`neither
# owner nor group member`) and the adverb (`the probe could not report that either`), which are
# different words rather than counts, and reporting them buries the shape this names.
CLOSED_SET_COUNT = re.compile(
    r"\b(both|the two|the pair)\b"
    r"(?=\s*(?:[.,;:)]|$)"
    r"|\s+(?:is|are|was|were|has|have|had|do|does|did|can|could|may|must|should|would|will"
    r"|stay|stays|stayed|remain|remains|remained|fail|fails|failed|apply|applies|applied"
    r"|agree|agrees|agreed|hold|holds|held|run|runs|ran)\b)", re.I)

# The members named beside the count, on either side of it: `both the manifest and the key`
# enumerates them after, `A and B both hold` before. The window is short, because further off an
# `and` joins the next clause rather than the second member.
CORRELATIVE_AFTER = re.compile(r"^(?:\W*\w+){0,6}?\W*\b(and|or|nor)\b", re.I)
CORRELATIVE_BEFORE = re.compile(r"\b(and|or|nor)\b(?:\W*\w+){0,6}?\W*$", re.I)


def closed_set_count(sentence):
    """A closed-set count word standing in place of the members it counts."""
    match = CLOSED_SET_COUNT.search(sentence)
    if not match:
        return None
    if CORRELATIVE_AFTER.match(sentence[match.end():]):
        return None
    if CORRELATIVE_BEFORE.search(sentence[:match.start()]):
        return None
    return match


EXTRA_CHECKS = [
    ("mirrored-clause", lambda s: mirrored(s, MIRROR_PIVOT),
     "state the fact once, in one direction"),
    ("definitional", lambda s: mirrored(s, DEFINITIONAL_PIVOT), "describe the mechanism"),
    ("unbacked-absolute", unbacked_absolute, "name the guard in the same sentence"),
    ("fronted-quantifier-inflected", FRONTED_QUANTIFIER_INFLECTED, None),  # hint from suggest()
    ("vague-verb", vague_verb, "name the operation: permits, transmits, states, shows"),
    ("history", re.compile(r"\b(used to|previously|was changed|formerly)\b"),
     "state current behaviour"),
    ("closed-set-count", closed_set_count,
     "name the set, unless it is closed by construction and the sentence says so"),
    ("filler", re.compile(r"\b(simply|obviously|clearly|basically|naturally|effectively"
                          r"|actually|essentially|robust|elegant|powerful|flexible)\b"),
     "cut it"),
]

PROSE_WHOLE_FILE = (".md", ".1", ".5", ".8")

# How to read a path, when --prose or --source has said: True reads every line, False reads only
# comments and docstrings, None leaves PROSE_WHOLE_FILE to decide.
#
# The extension rule fails in one direction without saying so, which is what the override answers:
# a path it does not recognize is read as SOURCE, so a document keeps only its `#` headings and the
# run reports zero findings for a file whose body it never read. That is what a caller gets for a
# copy whose name lost its extension -- a baseline written to a temp path, a revision from
# `git show` -- and zero findings reads as clean.
_FORCE_WHOLE_FILE = None


def is_prose_file(path):
    """Whether to read every line of `path` as prose, rather than only its comments."""
    if _FORCE_WHOLE_FILE is not None:
        return _FORCE_WHOLE_FILE
    return path.endswith(PROSE_WHOLE_FILE)

# Terms that mark a sentence as stating a SECURITY BOUNDARY rather than describing behaviour.
# A rewrite that drops one of these has probably changed the claim; see the `--kept` heading.
# The access-control nouns are here for the same reason as the secrets: `grants nothing on` rewritten
# as `leaves untouched` reads better and stops saying anything about access.
#
# The access VERBS are here for a third reason: each one names the operation a sentence permits or
# refuses, so a rewrite that drops one changes which operation the sentence is about. The defect
# this reports, stated as the check sees it -- removed `may not read other users' files`, added `no
# rule grants access to them` -- keeps the vocabulary of access while retiring the claim about
# reading, which is why the other two kinds stay silent on it.
#
# A special bit and an ACL entry are named here for a fourth reason: in this domain one of them is
# often the mechanism rather than a detail of it -- setgid on a shared directory is what makes a
# file born there carry the group, sticky is what stops a group-writer unlinking a file it does not
# own, and the ACL mask is what a `setfacl -m` recalculates and a `setfacl -n` preserves. A rewrite
# that renders `drwxr-s--x` as "group r-x" reads as a tidy-up and retires the bit that does the
# work, so the whole permission vocabulary is matched as terms: the octals in every spelling, the
# symbolic modes, the ten-character renderings, an ACL entry with its own colon syntax, the
# setfacl flag that decides whether the mask is recalculated, and the link vocabulary a refusal
# rests on (lstat over stat, nlink, no-dereference). A mode CHANGED in place reports the same way
# as one removed, since the old spelling leaves the added side either way. The trailing branches
# sit outside the `\b` group because each begins or ends with a character that is not a word
# character, so they carry their own boundaries.
#
# Every octal reduces to the number alone, with no owner attached: `750` and `750 root:root` name
# one mode, so matching the pair as a second token would report a mode as dropped each time a
# rewrite restated it with its owner. The owner is a term in its own right instead -- an
# `owner:group` pair, in the spellings this domain writes it in (`root:root`, `<you>:<you>`,
# `${PROJECTS_USER}:${SANDBOX_GROUP}`, `root:@SANDBOX_GROUP@`) -- since which account holds a path
# is a claim of the same order as which bits it carries, and a rewrite that renames the owner
# changes who may reach the file. A trailing sentence period is left out of the match, so the same
# pair at the end of a sentence reduces to the same term.
#
# A bare three-digit octal is the one loose thread: it also matches a count. Measured at 273
# sentences in this repo, of which the sample was 13 modes to 1 count, and it reports only when
# the number leaves a hunk, so the reading cost is a fraction of that.
INVARIANT_TERMS = re.compile(
    r"\b(secret|secrets|credential|credentials|token|password|privilege|privileged|sudo"
    r"|world-readable|root-only|owner-only|unprivileged|untrusted|trusted|forge|forged|tamper"
    r"|escalate|escalation|fail-closed|fail closed|confine|confined|allowlist|refuses|refuse"
    r"|grant|grants|granted|permission|permissions|acl|acls|ownership|setgid|readable|writable"
    r"|read|reads|write|writes|execute|executes|search|searches|traverse|traverses|list|lists"
    r"|append|appends|relabel|relabels|connect|connects|map|maps"
    r"|setuid|suid|sticky|umask|mask"
    r"|symlink|symlinks|hardlink|hardlinks|hardlinked|nlink|lstat|dereference|dereferences"
    r"|nosuid|noexec|nodev"
    r"|0[0-7]{3}|[1-7][0-7]{3})\b"
    r"|(?<![\w-])(?:[ugoa][-+=][rwxstXST]*|--x|[-dlbcps][-rwxsStT]{9}"
    r"|no-dereference|O_NOFOLLOW)(?![\w-])"
    r"|(?<![\w./-])[0-7]{3}(?![\w/-])"
    r"|(?<![\w])(?:default:|d:)?(?:user|group|other|mask|u|g|o|m):[\w@{}$-]*:[rwxXst-]+"
    r"|(?:set|get)facl\s+-[a-zA-Z]+"
    r"|(?<![\w:@${}<>.-])(?:[A-Za-z_]|[@${<][\w@${}<>-]*)[\w@${}<>.-]*"
    r":(?:[A-Za-z_]|[@${<][\w@${}<>-]*)(?:[\w@${}<>.-]*[\w@}>])?(?![\w:@${}<>-])", re.I)

# The nouns among those terms, which are the ones whose NUMBER carries a claim: a set of secrets
# either intersects the file's contents or it does not. A verb's inflection carries none, so
# `grants nothing` restated as `nothing to grant` is a rewrite rather than a narrowing.
NARROWABLE_TERMS = re.compile(
    r"\b(secrets?|credentials?|tokens?|passwords?|privileges?|permissions?|acls?)\b", re.I)

# Modality is part of the claim, not part of the wording. `never a glob` restated as `not a glob`
# swaps a universal for a single instance, and `carries no secrets` restated as `must not hold a
# secret` swaps a fact for an obligation; both read as tidying and both retire what the sentence
# guaranteed. Reported when the removed prose carried one and the added prose does not.
#
# The RFC 2119 verbs are in the set because this standard writes reference prose in that register,
# where each one fixes how binding a sentence is: a `must` demoted to a plain present tense turns a
# constraint the code was built to satisfy into a report of what it happens to do, which reads as a
# description a later editor may update rather than a rule they would be breaking. Each negation is
# spelled before its bare form, so the alternation prefers the longer match and `must not` weakened
# to `must` is reported rather than absorbed. The RFC's adjectives (REQUIRED, RECOMMENDED,
# OPTIONAL) stay out: they are ordinary words here -- `Required and fail-closed`, `the optional
# third arg` -- so reporting them would bury the verbs that do carry the claim.
# A contraction is matched beside its long form, and each one is spelled before the bare stem it
# begins with, so `mustn't` reads as `must not` rather than as `must` with a suffix left over. The
# apostrophe may be either the ASCII or the typographic one, since a document carries whichever its
# author typed. `will not`/`won't` stay out: `will` fixes when something happens, not how binding
# it is, and the standard reserves it for genuinely future behaviour.
MODALITY = re.compile(
    r"\b(never|always|only"
    r"|cannot|can[’']t"
    r"|must not|mustn[’']t|must"
    r"|shall not|shan[’']t|shall"
    r"|should not|shouldn[’']t|should"
    r"|may not|may)\b", re.I)

# The long form each contraction carries, applied to both sides before they are compared. The
# guideline is to write the long form, so swapping one for the other is a wording change that does
# not produce a finding, while dropping either form does.
CONTRACTIONS = {
    "can't": "cannot", "mustn't": "must not", "shan't": "shall not", "shouldn't": "should not",
}


def _modal(word):
    """The long form of a modal, so a contraction and its expansion compare equal."""
    return CONTRACTIONS.get(word.replace("’", "'"), word)


MESSAGE = "<message>"  # the path a commit message is reported under

# A line that carries its own prose and does not continue onto the next one: a Markdown heading
# or table row, a man-page macro. Joining a table would let a guard word in one row suppress a
# finding in another.
STANDALONE = re.compile(r"^\s*(\||#{1,6}\s|\.[A-Za-z])")
FENCE = re.compile(r"^\s*(```|~~~)")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")


LINE_COMMENT = re.compile(r"^\s*(#(?!!)|//+)\s?")
BLOCK_MARGIN = re.compile(r"^\s*\*(?!/)\s?")  # the ` * ` margin inside a /* */ block
# `/*` opens a comment only when a space, a second `*`, or the line end follows. A shell `case`
# pattern (`/*|./*|../*)`) begins the same way, and reading one as a comment opener swallows every
# line to the next `*/` -- which in a shell script is the rest of the file.
BLOCK_OPEN = re.compile(r"^\s*/\*(\s|\*|$)")
TRIPLE_QUOTE = re.compile(r'"""|\'\'\'')


def source_prose(line, state):
    """The prose a source line carries, and the block state after it.

    A source file contributes its comments AND its docstrings: `#`, `//`, a `/* */` block, and a
    triple-quoted Python string are all places the artifacts this standard covers live. The marker
    is dropped so the sentences rejoin cleanly.
    """
    if state:  # inside a docstring or a /* */ block; state holds its closing delimiter
        end = line.find(state)
        body = line if end < 0 else line[:end]
        if state == "*/":
            body = BLOCK_MARGIN.sub("", body)
        return body, (state if end < 0 else None)
    stripped = line.strip()
    quote = TRIPLE_QUOTE.match(stripped)
    if quote:
        delimiter = quote.group(0)
        body = stripped[len(delimiter):]
        return (body.split(delimiter)[0], None) if delimiter in body else (body, delimiter)
    if BLOCK_OPEN.match(line):
        body = stripped[2:]
        return (body.split("*/")[0], None) if "*/" in body else (body, "*/")
    return (LINE_COMMENT.sub("", line), None) if LINE_COMMENT.match(line) else (None, None)


def prose_lines(source):
    """Yield (path, line number, raw line, prose or None), holding block state per file.

    A document or man page contributes every line. A commit message inverts the source rule -- its
    body is prose and its `#` lines are the template git strips.
    """
    last_path, state = None, None
    for path, number, line in source:
        if path != last_path:
            last_path, state = path, None
        if path == MESSAGE:
            yield path, number, line, None if line.lstrip().startswith("#") else line
        elif is_prose_file(path):
            yield path, number, line, line
        else:
            text, state = source_prose(line, state)
            yield path, number, line, text


def block_sentences(path, lines):
    """Split one joined block into sentences, each reported at the line it starts on."""
    if not path or not lines:
        return
    joined, offsets = "", []
    for number, text in lines:
        if joined:
            joined += " "
        offsets.append((len(joined), number))
        joined += text.strip()
    position = 0
    for part in SENTENCE_SPLIT.split(joined):
        part = part.strip()
        if not part:
            continue
        start = joined.index(part, position)
        yield path, max(n for offset, n in offsets if offset <= start), part
        position = start + len(part)


def sentences(source):
    """Yield (path, line number, sentence) with wrapped prose rejoined.

    A block ends at a blank line, a line carrying no prose, a standalone line, or a change of
    file. Fenced code in a document is skipped: it is not the author's prose.
    """
    block_path, block, fenced = None, [], False
    for path, number, line, text in prose_lines(source):
        if text is not None and is_prose_file(path):
            if FENCE.match(line):
                fenced = not fenced
                text = None
            elif fenced:
                text = None
        if text is not None and IGNORE_MARKER in line:
            text = None
        standalone = bool(text and text.strip() and STANDALONE.match(text))
        if not (text and text.strip()) or path != block_path or standalone:
            yield from block_sentences(block_path, block)
            block_path, block = path, []
        if not (text and text.strip()):
            continue
        if standalone:
            yield from block_sentences(path, [(number, text)])
            continue
        block.append((number, text))
    yield from block_sentences(block_path, block)


def staged_lines():
    """Yield (path, line number, line) for every line this commit adds, from the index."""
    diff = subprocess.run(
        ["git", "diff", "--cached", "-U0", "--no-color", "--diff-filter=ACM"],
        capture_output=True, text=True, check=False).stdout
    path, number = None, 0
    for line in diff.splitlines():
        if line.startswith("+++ b/"):
            path, number = line[6:], 0
        elif line.startswith("@@"):
            hunk = re.search(r"\+(\d+)", line)
            number = int(hunk.group(1)) - 1 if hunk else 0
        elif line.startswith("+") and not line.startswith("+++") and path:
            number += 1
            yield path, number, line[1:]


def diff_hunks(revisions):
    """Yield (path, removed prose lines, added prose lines) for each hunk of a diff."""
    command = ["git", "diff", "--no-color", "--diff-filter=M", "-U0"]
    command += revisions.split() if revisions else ["--cached"]
    diff = subprocess.run(command, capture_output=True, text=True, check=False).stdout
    path, removed, added = None, [], []
    for line in diff.splitlines():
        if line.startswith("diff --git") or line.startswith("@@"):
            if path:
                yield path, removed, added
            removed, added = [], []
        elif line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("-") and not line.startswith("---") and path:
            removed.append(line[1:])
        elif line.startswith("+") and not line.startswith("+++") and path:
            added.append(line[1:])
    if path:
        yield path, removed, added


def _singular(term):
    """The unmarked form of a term, so an inflection alone does not read as a dropped claim.

    The `-es` endings need more than a dropped `s`, the same ones `base_form` names: `searches`
    reduced to `searche` would never match the `search` on the other side of the diff, and the
    verb would report as dropped on every rewrite that only changed its number.

    A term that is not a word is returned as it stands. A mode does not take a plural, and the `s`
    that ends `g+s` is the setgid bit, so reducing it would compare a claim about setgid against
    one about `g+` and report a bit that never moved.
    """
    if not term.isalpha():
        return term
    if term.endswith(_ES_ENDINGS):
        return term[:-2]
    return term[:-1] if term.endswith("s") and not term.endswith("ss") else term


def hunk_prose(path, lines):
    """The prose each of these diff lines carries, skipping the ones that carry none."""
    for line in lines:
        text, _ = (line, None) if is_prose_file(path) else source_prose(line, None)
        if text:
            yield text


def vocabulary(path, lines, pattern, singularize=False, normalize=None):
    """The matches of `pattern` in the prose among these lines, lowercased.

    `normalize` folds forms that carry one claim onto a single token, so a rewrite between those
    forms does not produce a finding while dropping the claim does.
    """
    found = set()
    for text in hunk_prose(path, lines):
        for match in pattern.finditer(text):
            word = _singular(match.group(0).lower()) if singularize else match.group(0).lower()
            found.add(normalize(word) if normalize else word)
    return found


def context_line(lines, needle):
    """The first of these lines carrying `needle`, for the report."""
    return next((line.strip() for line in lines if needle in line.lower()), "")


# What each kind of `--kept` finding asks the reader to do.
KEPT_HINTS = {
    "dropped": "restate it, or confirm the new wording still rules out the same thing",
    "narrowed": "the plural WAS the claim -- keep the set, not one member of it",
    "weakened": "modality is part of the claim -- restore it, or say why the weaker form holds",
}


def kept_findings(revisions):
    """Report the three ways a rewrite changes a claim while looking like a wording change.

    Each is reported, not decided: whether the new wording still rules out the same thing is a
    question about two sets, which a regex cannot answer.
    """
    for path, removed, added in diff_hunks(revisions):
        was, now = (vocabulary(path, side, NARROWABLE_TERMS) for side in (removed, added))
        singular_was, singular_now = (vocabulary(path, side, INVARIANT_TERMS, singularize=True)
                                      for side in (removed, added))

        for term in sorted(singular_was - singular_now):
            yield path, "dropped", term, context_line(removed, term)

        # A plural restated in the singular narrows the set the sentence is about. `does not carry
        # any secrets` says the contents and the secrets do not intersect; `must not hold a secret`
        # says one of them is absent. Only the first justifies the world-readable mode it was
        # written to justify, so the number is the claim rather than a matter of taste.
        for term in sorted(was - now):
            if _singular(term) != term and _singular(term) in now:
                yield path, "narrowed", f"{term} -> {_singular(term)}", context_line(removed, term)

        for word in sorted(vocabulary(path, removed, MODALITY, normalize=_modal)
                           - vocabulary(path, added, MODALITY, normalize=_modal)):
            yield path, "weakened", word, context_line(removed, word)


def file_lines(paths):
    """Yield (path, line number, line) for every line of every readable path."""
    for path in paths:
        try:
            with open(path, errors="ignore") as handle:
                for number, line in enumerate(handle, 1):
                    yield path, number, line.rstrip("\n")
        except OSError as exc:
            print(f"prose-check: cannot read {path}: {exc}", file=sys.stderr)


BACKTICK_SPAN = re.compile(r"`[^`]*`")
QUOTED_SPAN = re.compile(r"`[^`]*`|\"[^\"]*\"")


def author_prose(path, text):
    """The sentence with the spans that are not the author's own prose blanked out.

    A backticked span is a code reference in either kind of file. A double-quoted span is a
    quotation in a DOCUMENT -- most often the labelled bad example a style guide has to contain --
    so documents drop it too. A comment keeps its quoted text, because a message template quoted
    in a comment is prose this standard covers.
    """
    span = QUOTED_SPAN if is_prose_file(path) else BACKTICK_SPAN
    # " -- " rather than a space: a removed span must still separate the words around it, or
    # `takes \x60--for\x60 no target` fuses into a phrase the patterns then match.
    return span.sub(" -- ", text)


# The always-loaded layer: a root CLAUDE.md or AGENTS.md, which holds global invariants and routes
# to the rest. Every mark the pattern names is ordinary in the domain document it routes to and is altitude
# drift here, so this check reads the PATH and is scoped to these two names rather than joining
# the shape checks.
INVARIANT_LAYER = ("CLAUDE.md", "AGENTS.md")

# A file:line reference, a test path, and a file mode -- bare, backticked, or carrying its owner.
# These read the RAW sentence: a backticked span is the signal here, not the noise `author_prose`
# blanks everywhere else.
#
# Each mark names one thing, which is what keeps the check readable. Counting backticked
# identifiers instead -- three in a sentence as the mark of mechanism -- reports the register a
# router is written in: a document naming an account, a group and a shim in one invariant is
# routing, not drifting, so the count reports the file rather than a passage in it.
MECHANISM_MARK = re.compile(r"`[^`]+:\d+`"
                            r"|\btests?/[\w./-]+"
                            r"|\b0[0-7]{3}\b|`[0-7]{3,4}`|\b[0-7]{3,4} [a-z][\w-]*:")


def invariant_altitude(path, sentence):
    """A mark of domain mechanism in a router file, where the invariant belongs without it."""
    return MECHANISM_MARK.search(sentence) if path.endswith(INVARIANT_LAYER) else None


# Checks that read the path as well as the sentence, and the sentence unblanked. They run by
# default: each mark names one thing, so the report is near-exact, and the hook that runs the
# default set is where a writer is standing when the mechanism goes in.
PATH_CHECKS = [
    ("invariant-altitude", invariant_altitude,
     "state the invariant here; the mechanism belongs in the domain's rule, with a pointer"),
]


# `--wrap` adds three checks that read LINES rather than sentences. They are opt-in rather than
# default because they report how a line is WRAPPED, which a formatter fixes in bulk, and a tree
# whose lines predate the rule reports every one of them:
#
#   comment-tie        a comment or docstring line ending on a word that ties to the next one:
#                      an article, a conjunction, a preposition, or a wh-word. The word belongs
#                      at the head of the next line. The set is HEADER_TIES.
#   comment-width      a comment or docstring line over SOURCE_WIDTH columns (120, the column
#                      a code file wraps at; `--width` overrides it).
#   document-width     a Markdown line over DOCUMENT_WIDTH columns (100, the column the tree's
#                      documents wrap at; `--width` overrides it). A document reflows when it is
#                      rendered and is read unrendered as well -- in an editor, a diff, a review
#                      -- and an edit that splices a sentence into a wrapped paragraph is what
#                      leaves a line long. A table row, a fenced block, a line holding a URL or
#                      one token, and a man page are not measured: each is a unit the rule
#                      cannot break, and a line is measured without a reftag link's generated
#                      destination. The tie rule does not read a document, which reflows.
#
# `--config-header`: A CONFIG FILE'S HEADER IS READ IN A TERMINAL AND NEVER REFLOWED.
# An operator's config file -- a seeded header, a shipped template -- is read as-is, so its prose
# holds to a fixed width (72 columns, the RFC text width, by default), and a comment line does not
# end on a word that ties to the next one: an article, a conjunction, a preposition, or a wh-word.
# The set is the one msg.lib.sh glues to its successor when it wraps a runtime message, mirrored
# here because this checker is Python and ships apart from that library; tests/unit/prose-check.sh
# asserts the two sets agree. Every line is measured; the tie rule reads comment lines only,
# and leaves a commented default (`#KEY=value`) alone, that being a setting rather than prose. A line
# ending a sentence (`.`, `!`, `?`) is left alone too: a tie word closes a sentence as any other.
HEADER_TIES = frozenset("""
    a an the and or nor but so yet
    of to in on at by for with from into onto upon over under above below
    between among through during before after about against along across
    around near off out up down via per as
    what which who whom whose that when where why how
""".split())
HEADER_COMMENT = re.compile(r"^\s*#")
HEADER_DEFAULT = re.compile(r"^\s*#\s*[A-Za-z_][A-Za-z0-9_]*=")
HEADER_WIDTH = 72


TIE_HINT = ("carry the word to the next line; a line does not end on an article, "
            "a conjunction, a preposition, or a wh-word")


def tie_at_line_end(text):
    """The tie word `text` ends on, or None: a comment marker is stripped, a sentence-closing
    word is not a tie, and trailing punctuation around the word is ignored."""
    words = text.lstrip("#/* \t").split()
    if not words:
        return None
    last = words[-1]
    if last[-1] in ".!?":
        return None
    last = last.strip(",;:)\"'`").lower()
    return last if last in HEADER_TIES else None


def header_findings(paths, width):
    """A line over `width` columns, or a comment line ending on a tie word."""
    for path, number, line in file_lines(paths):
        text = line.rstrip()
        if HEADER_DEFAULT.match(text):
            continue
        if len(text) > width:
            yield (path, number, "header-width", f"{len(text)}>{width}",
                   f"wrap the line at {width} columns", text)
        if not HEADER_COMMENT.match(text):
            continue
        tie = tie_at_line_end(text)
        if tie:
            yield path, number, "header-tie", tie, TIE_HINT, text


SOURCE_WIDTH = 120
# A linter directive is an instruction to a tool, read by that tool, so neither line rule reads it.
SOURCE_DIRECTIVE = re.compile(r"^\s*#\s*(shellcheck|noqa|pylint:|type:|pragma)\b")


def comment_line_findings(source, width):
    """A source file's comment or docstring line over `width` columns, or ending on a tie word.

    A comment is read as written, in an editor, in `git blame`, or in a deployed file,
    so the rule a config header holds to applies to it too, at the wider column a code file
    wraps at. A code line is not measured: only a comment or a docstring is. A document or
    a man page reflows, so this reads source files only, line by line, where every other check
    reads rejoined sentences.
    """
    for path, number, line, text in prose_lines(source):
        if path == MESSAGE or is_prose_file(path) or text is None:
            continue
        if IGNORE_MARKER in line or HEADER_DEFAULT.match(line) or SOURCE_DIRECTIVE.match(line):
            continue
        stripped = line.rstrip()
        if len(stripped) > width:
            yield (path, number, "comment-width", f"{len(stripped)}>{width}",
                   f"wrap the comment at {width} columns", stripped.strip())
        tie = tie_at_line_end(text)
        if tie:
            yield path, number, "comment-tie", tie, TIE_HINT, stripped.strip()


DOCUMENT_WIDTH = 100
DOCUMENT_TABLE = re.compile(r"^\s*\|")
DOCUMENT_FENCE = re.compile(r"^\s*(```|~~~)")
MAN_PAGE = (".1", ".5", ".8")


def document_line_findings(source, width):
    """A Markdown line over `width` columns, outside a fence or a table and holding more than
    one token, with no URL in it. A man page is left to roff."""
    last_path, fenced = None, False
    for path, number, line in source:
        if path == MESSAGE or not is_prose_file(path) or path.endswith(MAN_PAGE):
            continue
        if path != last_path:
            last_path, fenced = path, False
        if DOCUMENT_FENCE.match(line):
            fenced = not fenced
            continue
        stripped = line.rstrip()
        if (fenced or IGNORE_MARKER in line or DOCUMENT_TABLE.match(stripped)
                or "://" in stripped or " " not in stripped.strip()):
            continue
        stripped = REFTAG_LINK.sub(r"\1", stripped)
        if len(stripped) > width:
            yield (path, number, "document-width", f"{len(stripped)}>{width}",
                   f"wrap the line at {width} columns", stripped.strip())


def findings(source, checks, path_checks=()):
    for path, number, sentence in sentences(source):
        subject = author_prose(path, sentence)
        for name, check, hint in checks:
            match = check.search(subject) if hasattr(check, "search") else check(subject)
            if match:
                yield path, number, name, match.group(0), suggest(name, match, hint), sentence
        for name, check, hint in path_checks:
            match = check(path, sentence)
            if match:
                yield path, number, name, match.group(0), hint, sentence


def main():
    parser = argparse.ArgumentParser(
        description="report prose figures the writing standard rules out")
    parser.add_argument("--staged", action="store_true",
                        help="check the lines this commit adds")
    parser.add_argument("--message", metavar="FILE",
                        help="check a commit message; template comments skipped")
    parser.add_argument("--all", action="store_true",
                        help="add the shape checks")
    parser.add_argument("--kept", metavar="REVISIONS", nargs="?", const="",
                        help="report a claim a rewrite dropped, narrowed, or weakened "
                             "(default: the index)")
    parser.add_argument("--wrap", action="store_true",
                        help="add the line checks: a source comment ending on a tie word or over "
                             f"--width columns, a Markdown line over {DOCUMENT_WIDTH}")
    parser.add_argument("--config-header", action="store_true",
                        help="read the paths as config-file headers: a line over --width "
                             "columns or a comment line ending on a tie word")
    parser.add_argument("--width", metavar="COLUMNS", type=int, default=None,
                        help=f"the column a line is measured against: {HEADER_WIDTH} for "
                             f"--config-header, {SOURCE_WIDTH} for a source comment, by default")
    reading = parser.add_mutually_exclusive_group()
    reading.add_argument("--prose", dest="force", action="store_const", const=True,
                         help="read every line as prose, whatever the extension")
    reading.add_argument("--source", dest="force", action="store_const", const=False,
                         help="read comments and docstrings only, whatever the extension")
    parser.add_argument("paths", nargs="*", help="files to read whole")
    args = parser.parse_args()

    global _FORCE_WHOLE_FILE
    _FORCE_WHOLE_FILE = args.force

    if args.kept is not None:
        count = 0
        for path, kind, detail, context in kept_findings(args.kept):
            count += 1
            print(f"{path}: {kind} [{detail}] -- {KEPT_HINTS[kind]}")
            print(f"    - {context[:110]}")
        if count:
            print(f"\n{count} finding(s). A rewrite changes the wording, not the claim. "
                  f"A term that only moved to another hunk reports here too.")
        return 1 if count else 0

    modes = [args.staged, bool(args.message), bool(args.paths)]
    if sum(1 for mode in modes if mode) != 1:
        parser.error("give exactly one of --staged, --message FILE, or one or more paths")

    if args.config_header:
        if not args.paths:
            parser.error("--config-header reads one or more paths")
        count = 0
        width = args.width if args.width is not None else HEADER_WIDTH
        for path, number, name, token, hint, text in header_findings(args.paths, width):
            count += 1
            print(f"{path}:{number}: {name} [{token}] -- {hint}")
            print(f"    {text[:110]}")
        if count:
            print(f"\n{count} finding(s). A config header is read as fixed-width text; "
                  f"see the ai-tools-technical-docs skill.")
        return 1 if count else 0

    checks = DEFAULT_CHECKS + (EXTRA_CHECKS if args.all else [])
    if args.staged:
        source = staged_lines()
    elif args.message:
        source = ((MESSAGE, number, line.rstrip("\n"))
                  for number, line in enumerate(open(args.message, errors="ignore"), 1))
    else:
        source = file_lines(args.paths)
    # Read twice -- once as sentences, once as lines -- so the source is held rather than streamed.
    source = list(source)

    count = 0
    for path, number, name, token, hint, text in findings(source, checks, PATH_CHECKS):
        count += 1
        print(f"{path}:{number}: {name} [{token}] -- {hint}")
        print(f"    {text[:110]}")
    if args.wrap:
        for path, number, name, token, hint, text in comment_line_findings(
                source, args.width if args.width is not None else SOURCE_WIDTH):
            count += 1
            print(f"{path}:{number}: {name} [{token}] -- {hint}")
            print(f"    {text[:110]}")
        for path, number, name, token, hint, text in document_line_findings(
                source, args.width if args.width is not None else DOCUMENT_WIDTH):
            count += 1
            print(f"{path}:{number}: {name} [{token}] -- {hint}")
            print(f"    {text[:110]}")
    if count:
        print(f"\n{count} finding(s). See the ai-tools-technical-docs skill; "
              f"mark a deliberate example with '{IGNORE_MARKER}'.")
    return 1 if count else 0


if __name__ == "__main__":
    sys.exit(main())
