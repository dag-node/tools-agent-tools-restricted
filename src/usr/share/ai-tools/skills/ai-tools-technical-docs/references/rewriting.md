# Rewriting existing prose <a id="ref-section-q9p8"></a>

Every writing rule in the standard governs a first draft, where the claim is in the writer's head and only the words are
in question. Editing prose that already exists is a different operation: the claim is already in the sentence,
and the job of the edit is to keep it. The rules for that are collected here, because a rewrite pass reads one section
and then changes several hundred sentences.

**A rewrite changes the wording, not the claim.** What remains states what the original stated — same subject, same set,
same number, same modality — and does not add anything the original did not say. Where the new wording cannot carry
the claim, leave the sentence unchanged: a style rule that cannot be applied without retiring a guarantee does not
apply.

## Rewrite from the source, not from the flagged token <a id="ref-section-e8b7"></a>

A finding names a symptom, and every rule here is about the claim, so:

1. Open what the sentence describes — the code, or the invariant it states.
2. Settle any disagreement between the two in the direction the doc/code conflict rule
   [ref-section-p6c5](../SKILL.md#ref-section-p6c5) sets.
3. Write the sentence again from that source.
4. Leave the reported token out of the result.

Substituting a synonym for that token instead clears the check and keeps the defect:

| `grants nothing` becomes | and | |
|---|---|---|
| `confers no authority` | the grep is clear, a domain term is now a legal one, and the quantifier is still fronted | ✗ |
| `granted no path` | both default checks are clear, and the same figure sits in another inflection for a later pass to find | ✗ |
| `uses a grant the caller already holds` | read off the code in one pass | ✓ |

Reading the source also answers what no rule decides in the abstract — arity among them.

**Review the whole sentence, not only the flagged token.** A check highlights one word, yet the rest of the sentence
came from the same pass and is equally likely to be wrong. Before moving on, re-read the count, the mechanism name,
and the fail direction that stand beside the token. Do not treat a corrected token as evidence that the sentence has
been reviewed.

## Carry four things through every edit <a id="ref-section-z4d3"></a>

Check each one before accepting a rewrite. A change that moves any of them has changed the claim.

- **The set.** Rewrite over the set the original named. `carries no secrets` → `does not carry any secrets`, never
  `contains only settings`: a setting can be a token, so the second stops justifying the `644` mode the first was
  written to justify.
- **The number.** Keep a plural plural and a singular singular. `does not carry any secrets` says the contents
  and the secrets do not intersect, where the narrowed `must not hold a secret` says only that one of them is absent.
- **The modality.** Keep `never`, `always`, `cannot`, `only`, and `must` where the original used one, and name the guard
  that backs it in the same sentence. Do not trade an absolute for `not`; the absolute rule
  [ref-section-d7n6](../SKILL.md#ref-section-d7n6) has the cases where the absolute itself goes.
- **Every fact, and no new ones.** Account for each fact in the old sentence before deleting it.
  `stable, and leaks nothing regardless of who runs it` → `stable whoever runs it` drops a disclosure claim. No
  vocabulary check sees that, so read the two versions side by side.

## Keep the sentence and raise the finding

Leave a sentence as it stands, and report the conflict, when it states any of:

- a **security boundary** — what a mode permits, what a file may hold, who may act, what a refusal refuses;
- an **invariant in an always-loaded layer** — a root `CLAUDE.md`, a rule file, a prohibition addressed to an agent;
  a weakened guarantee is still read as a guarantee;
- an **identity or disclosure claim** — what a value leaks, what an output carries.

"This rewrite would weaken an invariant" is a finding: report it and leave the sentence as it stands. Readability is not
a reason to weaken a guarantee.

## Run the checks a rewrite needs <a id="ref-section-g5n4"></a>

Run both, on the files the pass touched and on the diff it produced:

```bash
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py --all <file>...
python3 /opt/ai-tools/skills/ai-tools-technical-docs/prose-check.py --kept <base>
```

`--all` catches a figure moved into an inflection the default checks leave alone. `--kept` compares the two sides
of the diff and reports a dropped term, a narrowed number, and a weakened modality — three of the four that [Carry four
things through every edit](#carry-four-things-through-every-edit) names. The fourth, a dropped fact, has no check,
so read for it. Both modes report and neither decides: whether two sets are disjoint is not a question a regex answers.

Two points about running the checks:

- **For a multi-part change, baseline each pass at the tip of the previous part.** `--kept` accepts any revision range,
  so `--kept <rev>` reports only the findings belonging to the part in hand, rather than every change since the branch
  point.
- **To see what the edit itself added, use `--new <revision>` rather than comparing two runs.** It pairs findings
  by content, where a line-wise comparison of two runs treats every finding that merely moved as new. [Running
  the checker](checks.md) has the modes.
