---
paths:
  - "src/usr/local/libexec/ai-tools/ai-tools-lockdown.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-chown.sh"
  - "src/usr/local/lib/ai-tools/secret-patterns.lib.sh"
  - "src/usr/local/lib/ai-tools/owner-only.lib.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-setfacl.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-setgid.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-unclaim.sh"
---

# Secret-named file handling

Two consumers classify paths against one shared pattern set and revoke `SANDBOX_USER`'s read: `ai-tools-chown`
reactively (per agent-written path, see [ownership-and-hooks](ownership-and-hooks.rule.md)) and `ai-tools-lockdown`
proactively (over a whole project).

## Reactive: `ai-tools-chown`

A secret-named file the agent wrote is breached. `ai-tools-chown` classifies the path against the shared pattern set
(`.env`, `*.key`, `*.pem`, `id_*`, `kubeconfig`, `*.jks`, `.pgpass`, the name-anchored .NET config patterns, …)
and chowns a match (when `SANDBOX_USER`-owned, per the agent-written-paths rule) to `<you>:<you> 600`, so `SANDBOX_USER`
— neither owner nor group member — cannot read the contents. `<you>` is the operator that owns the path:
`ai-tools-chown` resolves it per path via `operator.lib.sh` (`ai_tools_operator__resolve_owner`) and loads the baseline
with that operator's patterns, so a secret returns to its project's operator at `600`, where only that operator can read
it. It writes a NOTICE to stderr, which claude-code's `PostToolUse` hook hands the model as context beside the tool
result ([ownership-and-hooks](ownership-and-hooks.rule.md) states the route), and, at `WARNING` level, to the operation
log (`/var/log/ai-tools/chown.log` and journald; see [logging](logging.rule.md)).

The revocation applies to an open made after it. The kernel checks owner and mode when a file is opened, so a descriptor
a session process opened before the handback keeps reading and writing the file; the quarantine responds to an exposure
that has already happened, which is why the NOTICE says to rotate the secret, and a credential kept outside
the agent-writable tree is the control that prevents one.

This revokes read only. `SANDBOX_USER` is a group-writer on the project dir (not its owner), so it can still
unlink/replace the path; a replacement is agent-written and re-triggers the same handling, and the audit log is
root-owned. A project-wide sticky bit does not apply: `SANDBOX_USER` is a group-writer and handed-back files are
`<you>`-owned, so it would block the agent's atomic-rename re-edits. To prevent unlink/replace of the operator's own
secrets, place them in a dir the agent cannot write (`700 <you>:<you>`) and `!`-exclude it — the allowlist is not a read
boundary.

<a id="ref-definition-e3h3"></a>**Owner-only seal**

A path whose mode grants neither group nor other bits (`0600`, `0700`) is the operator's standing seal. The claim-side
walks (`ai-tools-setfacl`, `ai-tools-setgid`), the unclaim and the re-claim scans leave such a path as it is — no ACL
entry, no default ACL, no mask recalculation, mode bits untouched — and a sealed directory takes its subtree with it;
the skip count is reported, and a project root at such a mode is refused by the claim before its first write
([cli](cli.rule.md)): the claim does not add a grant under the seal, and no session starts in an owner-only directory,
whichever account owns it. Widening the mode and re-claiming is how a path opts in — a manual step by design, since
a standing denial is not put to a single keypress. Granting it would not keep it protective: `setfacl -m` recalculates
the mask to cover the entries it adds, so a `700` directory would come back `0770`, with write on it and the ability
to unlink the secrets inside. Every walk also **strips** the sandbox residue such a path inherited at creation —
the project group, the setgid bit and the default ACL — rather than merely skipping it, since a later `chmod 700` masks
that residue and does not remove it, and widening the mode later would re-activate the grant over everything already
inside. `owner-only.lib.sh` is the reference for which paths are sealed, what the strip removes, and why a numeric
`chmod` and a default ACL leave the residue in place. A `!`-exclusion is the stronger form: an excluded subtree is
skipped by every walk whatever its mode.

## Shared secret-pattern set (one source, one matcher) <a id="ref-section-h4j6"></a>

**The file.** The patterns live in `~/.config/ai-tools/secret-patterns` (`<you>:<you> 600`, inside the `700`
`~/.config/ai-tools`), beside `~/.config/ai-tools/project-registry` and owned the same way: the operator edits it,
`SANDBOX_USER` — neither its owner nor in its group, and unable to enter the directory — can neither read nor write it,
and the root helpers read it on the operator's behalf, so the agent cannot weaken its own secret classification.
`atr admin operators add` seeds it with the header alone — what the file is, the additive rule, the `!` line form,
example lines and `ai-tools-secret-patterns(5)`, the page that holds the reference ([providers](providers.rule.md)
states why a seeded header is a pointer) — so the baseline classifies alone until the operator adds a pattern.

**The library.** Every component that classifies a path sources `/usr/local/lib/ai-tools/secret-patterns.lib.sh`
(`644 root:root`, in a directory `SANDBOX_USER` cannot write) for one loader and one path predicate over that file,
`ai_tools_secret_patterns__is_secret_path`, so no two of them drift apart. Its built-in list is the **public baseline**
— the credential names software writes in general — and ships in the source repo, so read is open: the installed copy
holds only what is already published. Root-only **write** is the boundary, since an agent that could edit the matcher
would decide its own classification; `tests/boundary/access.sh` asserts that as the agent. `ai-tools-chown` reads it
from `ai_tools_handback_t` (inherited from the handback daemon, no transition), which the policy grants
`libs_read_lib_files` for the `lib_t`-labelled library. The baseline is incomplete by construction, since it tracks
conventions that keep appearing: a deployment-specific name belongs in the operator's file, and a general one missing
from the baseline goes upstream, since the library is rpm-owned and not `%config`, so an edit there is lost on upgrade.

**The loader has two outcomes, and the file adds to the baseline.** `ai_tools_secret_patterns__load` builds the file's
path from the resolved operator's home, so every consumer calls it after the owner resolve (its doc comment states
what a load made earlier reads). The baseline is always in force, and an operator's file **adds** its patterns to it,
so no file classifies fewer names than the baseline and every name an upgrade adds reaches every operator:

**The set in force, by the state of the operator's file**

| the file | the set in force | status |
|---|---|---|
| absent, or a readable regular file | the baseline and the file's patterns | 0 |
| present and not a readable regular file — a directory, a dangling symlink, a FIFO, a read `access(2)` refuses | the baseline alone, the path in `AI_TOOLS_SECRET_PATTERNS__UNREADABLE`, and `MSG-S4T9` printed | 1 |

The second row is told apart from the first because the set in force lacks the patterns the operator's file adds:
a helper walking a tree on the baseline alone would treat a file only those patterns name as an ordinary one and widen
the agent's access to it. **Every helper that changes a tree reads the status and refuses before its first write**,
and refuses the same way when the library itself does not load, since a walk with no matcher would give the agent's
group every secret-named path, the baseline's included. `ai-tools-chown` leaves the path sandbox-owned rather than
handing a possible secret back as an ordinary file, `ai-tools-lockdown` does not lock a path (a `--gate` caller reads
exit 0 as every secret locked), `ai-tools-setgid` and `ai-tools-setfacl` do not write a group change or an ACL entry
under the project, and `ai-tools-unclaim` does not regroup a path. The two consumers that only report go
on with the baseline: the claim's `[secret]` mark ([cli](cli.rule.md)) is advisory, and the launch wrapper's journal
line names the unreadable file. `tests/unit/secret-patterns.sh` drives the loader through both rows and each helper's
unit test drives its refusal; the boundary half is the `700` directory `tests/boundary/access.sh` probes, which keeps
the sandbox account from putting the file into either state.

**The launch wrapper records an unreadable file.** A file the loader cannot read leaves the operator's sessions
classified on the baseline alone while their helpers refuse, and no log line says so until a helper runs.
`ai_tools_secret_patterns__format_unreadable_report` prints one line naming the file, and the launch wrapper logs it
to journald once per launch, for every agent ([launch](launch.rule.md)): the wrapper runs as the operator
before the privilege drop, so it is the one point per session where the file is both readable and attributable
to a launch, and the line is a record to act on later, so it goes to the journal and not the terminal. Any other state
of the file does not write a line.

**The patterns are name- or environment-anchored** (`appsettings.*.json`, `web.*.config`, `*.Production.*`, …), **not**
broad `*.*.json`/`*.*.config` catch-alls: those would also match build artifacts the toolchain must read (`*.deps.json`,
`*.runtimeconfig.json`, `project.assets.json`, `*.dll.config`), and quarantining them breaks builds. An environment
segment is followed by an extended-glob tail that leaves a script, a stylesheet and a source map alone (`.js`, `.mjs`,
`.cjs`, `.css`, `.map`), since a vendored bundle is named for its build (`react.production.min.js`) and a build or test
that loads a locked one fails; every other extension after the segment stays locked. The matcher's `[[ == ]]` reads
the tail whether or not `extglob` is set, so an operator's pattern ending in the same tail carries the same exclusion.
The set uses basename-safe globs only, no bare `config`.

**Two lists leave a matched path open, and neither covers a subtree.** The predicate matches the path's last component
against the set in force, then leaves the path open where an exemption names it; a file or directory under an exempt
path is classified by its own name, so a `.env` inside an exempt directory is locked.

- **The baseline's exemptions** are the paths a package or a project generator ships under a name the baseline matches
  and a build reads: Angular's `private` and `tokens` source directories, its library schematic's template,
  the environment files its application template writes. The registry is
  `_AI_TOOLS_SECRET_PATTERNS__BASELINE_EXEMPT_PATHS` in the library. An entry is literal path components compared
  case-sensitively with the last components of the path, so it matches under any project root, a nested client directory
  and pnpm's `.pnpm` layout, and does not take a glob. An exemption does not open a path that one of the operator's own
  patterns matches, since the operator named it after the baseline did; the loader counts a pattern as the operator's
  own when it is not a baseline entry, compared case-insensitively, so a file that copied the baseline leaves every
  exemption in force.
- **The operator's `!` lines** each name one canonical absolute path (a line opening with `!(` is a negation glob,
  a pattern like any other), compared byte for byte with the canonical path the consumer holds. A line that does not
  name a canonical absolute path (a relative path, a glob character, a `.` or `..` component, a doubled or trailing `/`)
  is ignored and reported under `MSG-T4W8`, its path stays locked, and the loader's status stays the one the rest
  of the file decides. The exemption is on the path, not the content: the operator states the path after reading
  the file, and the exemption holds whatever the file later holds.

An exemption changes classification and does not reverse a lock already applied: a path an earlier lockdown made
owner-only stays so, since the claim walks leave an owner-only path as it is, and the operator widens it by hand;
a later lockdown does not lock it again.

## Quirks

A file the agent writes whose path the shared set classifies as a secret is quarantined the instant it is written —
`ai-tools-chown` chowns it to `<you>:<you> 600`, which also catches files merely *named* after the topic, not just real
secrets: a doc or rule file called `secrets.md` matches `secrets.*` and becomes unreadable to the agent. This is
why rule files use a non-matching stem (`secret-handling.rule.md`, not `secrets.rule.md`; see
[authoring](authoring.rule.md)) and docs pages are named for their verb ([docs-pages](docs-pages.rule.md)).

## Proactive: `ai-tools-lockdown` <a id="ref-section-g6s6"></a>

`ai-tools-chown` is reactive — it acts only on `SANDBOX_USER`-owned paths, so it never touches a pre-existing user-owned
secret the agent could already read. `ai-tools-lockdown` (`/usr/local/libexec/ai-tools/ai-tools-lockdown`, run
`atr projects lockdown <project>` or `sudo ai-tools-lockdown <project>`) is the proactive counterpart: it walks
the project directory its argument names, or the current directory without one, and, for every path matching the shared
secret patterns, sets regular files `600`, directories `700`, and owner `<you>:<you>` — revoking `SANDBOX_USER`'s read
regardless of who created the path. The owner's own private group is the target, the same one `ai-tools-chown` gives
an agent-written secret, so a secret ends up identically owned whether it was locked down proactively or quarantined
on write; leaving the group as `SANDBOX_GROUP` would re-expose it the moment the mode was widened. Each locked path also
has its sandbox residue stripped. The seal pass that follows covers the owner-only paths **under** the target and leaves
the target directory itself as it is, still pruning the subtree of an owner-only root the way the claim walkers do.
`atr projects clone` creates the clone root owner-only without a default ACL and runs its `git clone` under `umask 077`,
so a clone reaches the gate owner-only throughout, and the seal pass leaving the target alone keeps the setgid bit
and the sandbox group the clone area gave the root ([ref-section-u9a9](cli.rule.md#ref-section-u9a9)). It runs only
when that directory is an enabled project — it refuses under a disabled (`%`) line, as every walking helper does
([cli](cli.rule.md)) — and skips `!`-excluded paths, and applies each change through a pinned fd (re-verifying inode
and type) so a `SANDBOX_USER` path swap cannot redirect root's chmod/chown. `--yes` skips the TTY confirmation, and is
refused with exit 2 beside `--dry-run`, which does not ask.

`--dry-run` previews **both** passes — the secret lock and the seal — naming each path and, for a seal, what would come
off it. The seal half is the one that acts on paths the operator did not name, so a preview that showed only the secret
half would understate what an apply does. The preview runs the seal pass itself with the strip in report-only mode
(`AI_TOOLS_RESIDUE_DRY_RUN`), rather than a read-only re-implementation beside it: "what is sandbox residue" has one
answer, in `owner-only.lib.sh`, so the preview cannot come to describe a pass other than the one that follows it. Only
the mutations are skipped — every gate, guard and pinned-fd re-check still runs — and the apply confirm is never
reached, since a preview must not ask to apply.

A declined confirmation exits **6**, the code `ai-tools(1)` reserves for an operator's explicit decline, so a caller
tells a decline from a lockdown that ran. **`--gate`** is the claim's and the clone's secret gate in one call, which is
what keeps the gate to one `sudo` on a host whose sudo does not cache a credential: it lists each path relative
to the project, asks with a default of **yes** (the answer without a terminal, since locking moves to less access
and a declined gate stops the claim), reports the lock as one summary line with a line per path only for one that did
not lock, and writes every secret-matching path NUL-terminated to stdout, which under `--gate` does not carry any other
byte — the list `normalize_clone` prunes. The per-path record stays in the journal and `lockdown.log`. Every way
the lock can fall short exits non-zero rather than 0, since the gate grants access on 0 alone: a `find` that exits
non-zero or writes to stderr is an incomplete scan and refuses the run, each `chown` and `chmod` is checked and read
back from the pinned inode, and a secret-matching path left unlocked — hardlinked, swapped, or refused a mode — is named
and fails the run after the seal pass. `--gate` is the CLI's calling contract and is left out of the helper's usage
text; typed by hand it is parsed and refused the same way, and `--gate` with `--dry-run` is refused with exit 2
before the scan: the dry run exits 0 with the paths written and none locked, which a caller would read as a lock.
The walk does not take a skip list: a secret under `node_modules` or another heavy tree is reached through the project
root's traversal, the tree's own world bits and the recursive relabel, which the claim's walks skipping that tree do not
close, and `normalize_clone` opens the tree outright. Under `.git` it prunes `objects`, `refs` and `logs` alone,
the subtrees git names itself, an object by its hash and a ref and its reflog by the branch name: no secret-named file
lands there by an operator's choice, and a ref locked owner-only would refuse git to the agent. `hooks`, `info`
and the rest are walked, since a template or a resumed clone puts an operator-written file there. The set is fixed
in the helper rather than read from `skip-dirs.lib.sh`, whose categories an operator edits in `operator.conf`,
so a category override cannot reopen it.

It is a user tool: there is **no** sudoers grant letting `SANDBOX_USER` run it, and it refuses to run as `SANDBOX_USER`.
The `ai-tools` CLI wraps it as `atr projects lockdown [path]` (it `sudo`s the helper with the project after `--`, so
sudo prompts for the projects user's password and a caller that cannot enter the tree still reaches it; `--dry-run`
and `-y`/`--yes` pass through). The argument adds a way to name the target and does not widen a predicate: root
resolves the path, the registry still decides whether it is a project and whose, and the backstop still refuses
a system directory.

### Lockdown on claim and clone

A claim runs the `--gate` form before any step that widens the agent's access, and a clone runs it between the shallow
clone and the step that opens the clone to the agent group; a declined or failed gate stops either fail-closed.
Which steps count as widening, and how a clone stays private under a guard `CLAUDE.md` until a resume passes the gate,
are [ref-section-u5h3](cli.rule.md#ref-section-u5h3) and [ref-section-u9a9](cli.rule.md#ref-section-u9a9).
