---
paths:
  - tests/**
---

# Test organization and invariants

Tests live under `tests/`, split by category, with one shared harness. `tests/run.sh
[unit|integration|boundary|all]` dispatches; the suite as a whole needs root, so it is invoked
via `sudo` (the harness derives the unprivileged project user from `SUDO_USER`). A file that
needs root says so itself with `require_root`, and the pure library suites — the ones that stub
what they drive and build fixtures they own — deliberately do not, so they can also be run
**directly as an unprivileged user** during development; the harness then takes the invoker as
the project user. Run as root with **no** sudo context it refuses: there is no unprivileged
identity to derive, and fixtures built root-owned would be skipped by every owner guard under
test — a suite that passes with no assertion behind it. It streams
each file's output live, then — on any failure — reprints the failing files and their `FAIL`
lines as an end-of-run summary, so a long run does not need scrolling; an all-green run exits zero
with no summary. Each file runs under a per-file wall-clock budget
(`AI_TOOLS_TEST_FILE_TIMEOUT`, default 600s): a file that blocks — on a terminal read, a wedged
daemon, or a fixture process holding a pipe open — is killed and reported as a failure with its
transcript, rather than hanging the run. That matters beyond convenience because `install.sh`
runs this suite as its verification phase, so an unbounded file stalls an install. A green file that recorded no `PASS` (every check skipped, or no
harness result line) and a category with no test files are listed in an end-of-run
`no coverage` notice, parsed from `finish()`'s result line: green-by-exit-status alone cannot
hide a run with no assertions behind it. The default stays lenient — a partial/dev install
legitimately skips — and `AI_TOOLS_TEST_STRICT=1` turns the notice into a failure. Strict is
the enforcing-host full-install gate (`sudo AI_TOOLS_TEST_STRICT=1 tests/run.sh all`); the
container selftest stays lenient because SELinux is legitimately absent there, so
`selinux.sh`'s all-skip is a documented limitation, not a broken prerequisite.

The harness carries a fourth emitter for that reason. `skip` records a check that could not
run, and reaching the notice is the point of it. `note` records which supported state a host is
in — `hooks.sh`'s `/tmp` posture, where `pam_namespace` polyinstantiation is optional and its
absence is a documented deployment — and does not increment the counter, so it stays out of the notice.
`AI_TOOLS_TEST_STRICT=1` then fails a run only where a check was left unrun.

```
tests/
  lib/harness.sh   pass/fail/skip/note, perm(), check_file(), the /tmp testdir + dummy-allowlist fixtures, teardown
  run.sh           dispatcher; aggregates by exit status
  unit/            hermetic helper-logic tests
  integration/     full-install checks (needs a deployed, running system)
  boundary/        confinement checks run as the agent (SANDBOX_USER)
  manual/          operator-run live flow verification (NOT dispatched by run.sh)
```

`manual/` is not dispatched by `run.sh`, because its contents cannot be run the way the suite
is: `verify-live-flows.sh` drives the CLI **as the operator**, which prompts on
`/dev/tty`, `sudo`s for each root step, and writes the operator's own registries — none of which a
root-run hermetic suite reproduces. It exists for what only a live run shows (a claim, lockdown
and unclaim completing end to end, and `ai-tools --status` read from the vantage point that has to
read it), and it is bounded by two rules that keep a convenience script from becoming a hazard:
it works only inside a workspace `mktemp -d` created for that run — never adopting an existing
path, and refusing to remove one outside it — and it **leaves every installed file untouched**, so a check
that would need to write shared runtime state (the updater's last-run stamp) reads it and asserts
agreement instead. A state the host is not already in is skipped rather than manufactured; the
unit suites drive those against fixtures they own.

The SELinux AVC bring-up tooling is **not** part of this suite: it lives with the policy it
supports, under `selinux/avc/` (`run.sh` does not dispatch it).

## Hermeticity contract

Every test works **only inside its own dedicated `/tmp` testdir** (`mktestdir` sets
`TESTDIR`), builds its fixtures there with **known content defined in the test**, never
reads or writes the operator's real files (notably the real
`~/.config/ai-tools/allowed-projects`), and removes everything it created on exit (the
harness `EXIT` trap). A test never relies on arbitrary pre-existing state, and never
touches a path outside its testdir boundary.

Nor does a test mutate **global system state** to exercise a helper — the host's local SELinux
policy (`semanage fcontext`) above all. A helper whose real work *is* to add and then remove a
policy entry is therefore covered only on the branch where it leaves the policy unchanged: the alternative is
a teardown that can strand an entry in the policy store on a failed run, which costs more than
the coverage buys. Where that trades away an assertion, the gap is named at the point it is
declined — `integration/selinux.sh` does this for `ai_tools_unlabel_project`'s revert path — so a
reader meets it as a decision rather than as an absence.

The deployed root helpers read a fixed allowlist path; a test points them at its own dummy
allowlist via the `AI_TOOLS_ALLOWLIST` environment override (`mk_allowlist` writes the
dummy and exports it). This override is a **root-only test hook**: `sudo` strips it
(`env_reset`, and it is not in `env_keep`) and the handback daemon execs the helpers with
its own environment, so neither the operator nor the agent can inject it in production —
only a root caller that sets the env and execs a helper directly (the test suite) can
redirect it.

The harness redirects the helpers' root-only **file log** the same way: it exports
`AI_TOOLS_LOG_DIR` (the third root-only hook, same rationale as `AI_TOOLS_ALLOWLIST`) at a
throwaway `/tmp` dir cleaned up on exit, so a helper a test execs directly writes its
`chown.log`/`setgid.log`/… lines there instead of appending to — or raising spurious
`ERROR` lines in (a negative-path test feeds a helper `/etc/passwd`, a missing group, a
bogus version) — the production `/var/log/ai-tools` trail. A helper the **live daemon**
execs (`integration/handback.sh`) keeps the real dir, since the daemon does not inherit the
override — the same limitation as `AI_TOOLS_ALLOWLIST`. The journald sink is unaffected, so
every line is still queryable by its per-component tag.

`AI_TOOLS_POSTUPGRADE_ROOT` is the fourth hook of that family and the widest in reach:
`ai-tools-admin system post-upgrade` reconciles a fixed registry of absolute control-plane paths, and
this prefixes every one of them, so `unit/postupgrade.sh` drives the real command against a
fixture tree in its testdir. It carries the same standing as the three above — the helper is
reachable only as root, `sudo` strips the name, and a caller who could set it may already edit
those files outright — and is unset in production, where the registry paths stand as written.

`AI_TOOLS_ADMIN_COMMANDS_DIR` (`ai-tools-admin`) belongs to that family too, and redirects the
directory the admin dispatch discovers its contributed command domains in, so
`unit/admin-commands.sh` drives the real dispatch against fixture fragments in its testdir instead
of the host's own. It carries the same standing as `AI_TOOLS_POSTUPGRADE_ROOT` — the tool is
reachable only as root, `sudo` strips the name, and a caller who could set it may already write the
directory it redirects.

`AI_TOOLS_ENTRYPOINT_PIN_DIR` (`entrypoint-verify.lib.sh`) is the fifth, and it carries more weight
than the others: the production pin decides whether a session may launch at all, so a test that
wrote a deliberately wrong checksum into it would refuse every launch on the host until the next
reconcile. `integration/ai-tools-run.sh` redirects it at a `mktemp -d` instead and drives the
mismatch refusal through the deployed shim — the feature's actual guarantee, and the one gate that
needs a VALID executable to reach, since every other refusal case exits before it. Its complement
(an unpinned entrypoint must NOT be refused, or an air-gapped host stops launching) is deliberately
left to the pure verdict: no other part of that run is invalid, so driving it would start a real
session. Its sibling `AI_TOOLS_ENTRYPOINT_LABEL_DIR`, which moves the labelling record written
beside the pin, carries none of that weight — the record is reported without gating a launch — so
`unit/entrypoint-verify.sh` redirects it at its testdir and writes real records through the library.

`AI_TOOLS_LAUNCHER_DIR` (`relabel.lib.sh`) is the sixth, and the one hook no automated test
consumes. It redirects where the entrypoint reconciliation looks for an agent's stable launcher
symlink, which is what lets the `stale` verdict be driven **end to end on a live host** — point it
at a directory whose `claude` link resolves to a real file the declared pattern does not cover, and
`ai-tools-relabel-agent` must print the stale warning and exit non-zero:

```
sudo bash -c 'n=$(find /opt/ai-tools/.nvm/versions/node/*/lib/node_modules/@anthropic-ai/claude-code/node_modules -name claude -type f | head -1); d=$(mktemp -d); ln -s "$n" "$d/claude"; env AI_TOOLS_LAUNCHER_DIR="$d" /usr/local/libexec/ai-tools/ai-tools-relabel-agent; echo "exit=$?"; rm -rf "$d"'
```

`AI_TOOLS_RELABEL_LOCK` and `AI_TOOLS_RELABEL_LOCK_WAIT` (`relabel.lib.sh`) are the seventh, and
the first of the family a test drives directly: they move the lock that serializes writes to the
policy store, and shorten the wait for it, so `unit/relabel.sh` exercises real cross-process
contention against a lock file in its own testdir. They carry the lightest standing of the family —
what they redirect is an advisory lock, so a caller who sets one can leave a run unserialized,
which is the documented fail-soft and never changes what a label may be applied to.

It is not in the suite because the full function registers a `semanage fcontext` rule, and this
suite does not mutate the host's SELinux policy to test a helper — the same line
`integration/selinux.sh` draws for `ai_tools_unlabel_project`. The check above is safe *because* it
re-asserts the rule that is already registered, leaving the policy store unchanged; a fixture
manifest would not, which is why the hook redirects the **launcher** rather than the manifest
directory. The pure decision behind the verdict is covered hermetically in `unit/relabel.sh`, and
the live agreement between declaration and installation in `integration/selinux.sh`; what this
exercises is the wiring between them and the renderer's exit status.

## Two-ended assertions

A security guarantee is covered by a **pair** of tests, not one, and the pair is what makes the
coverage meaningful:

- a **runtime** assertion that the refusal fires — drive the deployed code into the bad state
  (an untrusted config, a mislabelled entrypoint, a path outside the allowlist) and assert it
  resolves to *less* access and says so;
- a **boundary** assertion, executed **as the agent**, that the bad state is unreachable — the
  agent cannot write the file, directory, or binary whose corruption the refusal exists to catch.

Neither is sufficient alone. The runtime half catches a host someone has already broken (an
operator's `chmod`, a botched install, a tamper); the boundary half catches the agent trying to
break it. A guarantee with only the first is untested against its actual adversary; one with only
the second silently stops refusing the day the predicate regresses.

The provider seam is the worked example: `unit/providers.sh` drives each untrusted input through
the resolver and asserts the fail-closed verdict, while `boundary/providers.sh` probes the same
deployed files as the sandbox account and asserts none of them is agent-writable. A new guarantee
lands with both halves, in the category each belongs to.

## Categories

**`unit`** — hermetic logic tests of the deployed helpers (`ai-tools-chown`, `-setgid`,
`-setfacl`, `-unclaim`, `-safedir`, `-reclaim`, `-lockdown`). Each runs the **installed** helper (so it exercises
the real, token-substituted artifact) against a `/tmp` testdir and a dummy allowlist,
asserting the algorithm: allowlist gating, the owner guard (acts only on projects-user- or
sandbox-account-owned paths) where it applies, ACL/setgid/permission transforms, the
secret/exclusion/skip-list skips, and -- for `-lockdown` -- the proactive sweep that locks
**pre-existing user-owned** secrets (files `600`, dirs `700`, `<you>:<you>`) which
the reactive `-chown` never reaches, plus its seal pass over the paths sealed by *mode* rather
than by name, and its refusal to run as the sandbox account.
The seal cases run across three files, because the same guarantee has three consumers:
`owner-only.sh` pins the primitives, while `setgid.sh` and `lockdown.sh` assert the deployed
helpers apply them. What each asserts is that a sealed path is never pulled into the
agent's group and that the residue behind its mode is removed without the mode widening -- a
strip that raised the ACL mask would leave the residue "gone" and the path more open than
before. `unclaim.sh` closes with the CLI-side decision that feeds the helper — the hand-back
group — because it publishes **two** results (the group, and the hint that no hand-back can run)
as globals in its caller's shell rather than on stdout, which a `$(...)`-capturing test cannot
observe: the assertion is made from a real caller, under `set -u`, so a result the function fails
to publish aborts the test the same way it would abort an unclaim. No live
daemon, no SELinux dependency, no wrapper. Run as root (needed to set arbitrary ownership
and create third-party-owned fixtures). A fixture tree is `chown`ed to the projects user
before the run, or the owner guard skips it. `secret-patterns.sh` is the odd one out: it
sources the shared classifier library (`secret-patterns.lib.sh`) and forces the built-in
default pattern set, pinning the matcher itself — credential names match case-insensitively,
while plain configs and build artifacts the toolchain must read do not. `check-version.sh`
departs the installed-helper pattern the other way: it runs a `TESTDIR` copy of
`packaging/check-version.sh` (a repo release-gate script, not a deployed artifact) against
fixture `VERSION`/spec files, pinning the tag grammar — final `vX.Y.Z` requires the
three-way match, `vX.Y.Z-rc.N` compares its base and relaxes only the `%changelog` match,
any other dashed tag is refused, a missing `%changelog` entry is fatal for every form.
`cli-verbs.sh` is the same shape one layer in: a pure text check that the CLI's four
**gating tables** — `OPERATOR_VERBS`, `ROOT_ALLOWED_VERBS`, `BOOTSTRAP_EXEMPT_VERBS`,
`FOR_ALLOWED_VERBS` — still describe the verbs it dispatches. The failure it exists for is
silent and one-directional: a verb added to the dispatcher and forgotten in `OPERATOR_VERBS`
runs for an unenrolled caller, with no message to say so until a root helper refuses it midway. So
every dispatched verb must be classified — operator-acting, or in the informational set the test
names — no verb may be both operator-acting and root-allowed, no table may name a verb the
dispatcher no longer has, and the help must list exactly what the dispatcher accepts. Its last
check asserts required **content** rather than consistency: `--help` and `--version` must be in
`BOOTSTRAP_EXEMPT_VERBS`, because a CLI that cannot print its own usage on an unprovisioned host
leaves the gate's refusal as the only route to the provisioning command — a regression visible
only on the host nobody develops against.

`man.sh` is a pure text-sync check over both of this project's man pages and the `usage()`
heredoc of the command each documents — `ai-tools(1)` against the CLI, `ai-tools-admin(8)`
against the admin helper — validated from the repo sources (or the installed pair outside a
checkout) and executing neither command, since the CLI's bootstrap gate fail-closes on an
unprovisioned host and the helper refuses a non-root caller. In each pair the help is
orientation and the page is the reference (see [cli](cli.rule.md)), so it asserts relations
rather than set equality. For `ai-tools(1)`: the **verb** sets match in both directions, every
option the help names is documented, and every option the page documents is one a CLI **parser**
accepts. The last is the direction with teeth: what goes stale is an option outliving its parser,
whereas requiring the help to name every documented option is what makes slimming the help
impossible.

`ai-tools-admin(8)` gets the same relations over a surface spelled in bare words rather than long
options ([cli-grammar](cli-grammar.rule.md)), so what is compared is the whole **command path** —
`selinux groups enable`, three tokens. The parser direction becomes a dispatch check: the helper
splits its dispatch across nested `case` statements, one per domain and collection, so a whole
path never appears in a single arm and each token of a documented path must be an arm somewhere in
the helper. That is what catches a page still naming a command after the dispatch renamed it,
without pinning where in the nesting the arm sits. Both pages are then checked for a non-empty
`.TH` version field.

`sandbox.sh` closes with `tree_is_pristine`, which is not a sandbox helper but belongs to the same
class: a pure decision with a security consequence. `--project-create` skips the secret scan, the
git-history prompt and the proceed confirm when it returns 0, so every way it could wrongly say yes
is a way to grant an agent access to a tree no scan has covered — which is why the claim re-derives it
from the tree rather than trusting the caller's hint, and why the cases driven here are the states
that must read as **not** pristine (any file beyond the README, one nested deeper, any commit).

`conf.sh` and `providers.sh` are the library pair behind the provider seam (see
[providers](providers.rule.md)). `conf.sh` pins the shared `KEY=value` grammar every
`operator.conf` key and every manifest is read with — quotes optional, commas and whitespace
both separating, inline comments ending a value, a present-but-empty key distinguishable
from an absent one — plus two properties whose breakage is silent in production: the
splitter must be **IFS-independent** (it is sourced into scripts that set `IFS=$'\n\t'`,
where an inherited IFS collapses a multi-item value into one bogus item), and
`ai_tools_conf_is_trusted` must refuse every state a non-root writer can create
(non-root-owned, group- or other-writable, a symlink), for directories as well as files. Its
new-option report carries a third: a commented **default** (`#KEY=`, `# KEY=`) is a mention while
an indented **example** in a header block is not, so a file seeded with `operator.conf`'s own
grammar comments is not mistaken for one that already knows every option.
`providers.sh` drives the enablement truth table and then, for each untrusted input in turn
— `operator.conf`, a manifest, a manifest directory — asserts the resolver moves to *less*
access and says so, never more.

`claude-prompt.sh` and `claude-endpoint.sh` are the runtime half of the custom system prompt and
custom API endpoint (see [launch](launch.rule.md) and [providers](providers.rule.md)). Each drives
its resolver over a root-only base-dir override and asserts the surface-widening guard: a prompt or
endpoint file the sandbox account could influence (group/other-writable, a symlink, a writable base
or `operator.conf`), one outside the trusted base, or otherwise invalid, resolves to **no injection
or a launch refusal**, never to passing an untrusted or wrong value to Claude Code. `claude-endpoint.sh`
additionally pins that only the four recognised keys are read (an arbitrary key never becomes session
environment) and that the auth token is imported by name (its value never appears in the resolved
arguments). The agent-side half of both — the files and libs are not agent-writable — is in
`boundary/access.sh`.

`filters.sh` pins the token-saving command filters (`filters.lib.sh`, see
[filters](filters.rule.md)). Filtering is not a boundary, so what the file asserts is that every
way a rule can fail to fit lands on **pass-through** — the command as the agent wrote it: the
shape allowlist (a pipeline, redirect, quote, substitution or glob is never rewritten), the
blocking words that let the agent's own flag win, rule precedence, the `AI_TOOLS_FILTERS` switch
including its empty-value kill form, and each untrusted rules file or directory. Its noise-strip
section pins the other half of the contract — control bytes go, every line survives.

`settings-merge.sh` pins install.sh's hook-declaration reconciler, the step that lets a newly
shipped hook reach a host whose `settings.json` is kept across an upgrade (see
[claude-settings](claude-settings.rule.md)). It edits an operator-owned control-plane file and
every way it can go wrong is quiet, so the assertions come in three groups — what must **arrive**
(each shipped declaration the kept file lacks), what must **survive** (the handback declaration,
the permission arrays, a relaxed deny entry, an operator's own hook), and what must be **said**
(the report names every addition, since the operator reviews the install log rather than the
JSON) — plus the two sidecars, which answer different questions and do not substitute for each
other: `.bak` is what the operator had, `.shipped` is what they were meant to get, written only
when the merge could not run. It drives the deployed `conf.lib.sh` directly, like the other
library unit tests: the decision lives there rather than in `install.sh` precisely so it can be
exercised without stubs or text extraction, and the installer keeps only the rendering.

`install-guards.sh` is the other `install.sh` unit test, and it covers the decision that sits
above the dispatch: which account the install enrols. Every refusal is driven through
`--operator`, the one route by which a name reaches that decision without a terminal (the prompt
reads `/dev/tty`, so its branch is not drivable here) — root, the sandbox account, an account that
does not exist, and the flag's own valueless form. Each case runs the installer with an
unrecognized action, so a run that reaches the dispatch at all prints usage and exits having
written no state, which is also how "admitted" is asserted. Beyond the refusals it pins what the
flag does **not** decide: a `SUDO_USER=root` invocation naming a usable operator is admitted,
while the same invocation naming nobody is refused, so the flag chooses who is enrolled and never
how the script was invoked.

`postupgrade.sh` is that same reconciliation seen from the RPM side: `ai-tools-admin system post-upgrade`
end to end, from dispatch through the registry to each treatment (see
[providers](providers.rule.md) and [claude-settings](claude-settings.rule.md)). It asserts which
treatment each file got — the settings JSON merged with its permission rules intact and a dated
`.bak` written first, `operator.conf` reported and byte-identical afterwards, the sudoers grant
shown and neither written nor dropped (its fixture is a grant of everything to everyone, so a
silent adoption fails loudly) — plus the cleanup prompt, which may default to yes only once the
two files match. Every run is under `setsid`, so each prompt takes its own default: that is the
unattended behaviour and what makes an interactive command reproducible. The agent-side half of
the pair is already deployed: `boundary/access.sh` covers `settings.json` and the helper
directory, `boundary/providers.sh` and `boundary/filters.sh` cover `operator.conf`, and
`boundary/sudo.sh` covers the grant, so no input this command reads is agent-writable.

`admin-commands.sh` pins the seam that lets a provider package add a domain to `ai-tools-admin`
(see [providers](providers.rule.md)). What it drives is a dispatch that **execs a file as root**, so
every assertion targets a way discovery could widen the surface: a group-writable or non-root-owned
fragment, a group-writable directory, a fragment claiming a base name (`system`, and the reserved
`status`), and a basename outside the domain charset are each driven and asserted to leave the
command surface smaller, with the refusal reported — and a path-shaped command name must read as an
unknown command rather than reaching an exec, since membership of the discovered set is the gate
and not the string. The positive half is the same contract from the other side: a trusted fragment
is exec'd with the remaining arguments intact, and `--help` lists exactly what dispatches, summary
included, because a help and a dispatch that disagree is the failure one discovery function exists
to prevent. Fixtures are root-owned by construction — anything else is untrusted, which is the
point — and the deployed helper reads them through `AI_TOOLS_ADMIN_COMMANDS_DIR`. Its boundary half
is in `boundary/providers.sh`: the agent cannot write the directory or any fragment in it.

`admin-operator-add.sh` pins the other reported decision that command makes: the line
`operators add` closes with, naming which of the two operator shapes the enrolment produced. The
verdict is read out of `sudo -l -U`, so what the file drives is the direction that misleads — a
sudo which fails for its own reasons must read as *undetermined* rather than as a verdict about
the account, since an administrator acts on that line at the moment of the decision and a false
"no grant" sends them to a `--for` workflow they do not need. `sudo` is stubbed as a shell
function and the helper is **sourced** rather than run (its root check and its dispatch are
guarded for exactly that), so one function is driven with no host to administer and no state
written anywhere; each case runs in its own `bash`, because the helper and the harness both
declare `SANDBOX_USER` readonly. Its second section covers the enrolment's other edit — the guard
line that sources the PATH dedup, which is what ranks the wrapper above the nvm shims — by driving
`wire_init_file` against fixture files in the testdir. Two of the three assertions are about a file
the command **creates**: `~/.bash_profile` is what bash reads at login, so the fixture home is run
through a real `bash -l` to assert the account's `.bashrc` is still read through it, and a file the
operator already has keeps its content and takes one guard line however often the accumulating
`operators add` runs.

`services.sh` pins the service-health registry (`services.lib.sh`) that `ai-tools --status` and
the launch wrapper's pre-launch warning share. Two properties carry weight beyond the accessors.
The **last-run stamp** is the one input here a non-root writer controls and it is rendered to the
operator's terminal, so every way a hostile or corrupt value could reach that terminal — a
symlinked stamp, a control byte or escape sequence, an over-long or unanchored line — is driven
and must read as *no value*, degrading the unit to `unknown` rather than to a wrong verdict. And
the age reader takes the key it reads (default `FINISHED`), because the entrypoint pin
records a `VERIFIED` time in the same grammar and both must age through one implementation — so the
default is pinned too, a regression there silently turning every existing caller's age unknown. And
the **freshness** mapping exists for a failure a `RESULT` cannot express — every recorded run
succeeds while the schedule driving them has stopped — so the file asserts that a successful run
goes `stale` past `max_age`, that a failed one stays `failed` at any age, that an unknown or
future-dated age never manufactures staleness out of an absence, and that `fired` mode reads
recency alone, letting one stamp yield two verdicts (a healthy trigger beside the failed run it
started). The same "the trigger is not the run" split appears for **system** units: a `Type=oneshot`
service is inactive whenever it is healthy, so the file drives its three states from unit properties
— never run reads `unknown` rather than an OK it has not earned, a successful last run reads OK
though `is-active` would say DOWN, and a failed one reads FAILED and needs attention — plus that a
unit with no `Type` is still judged by `is-active`, and that the launch wrapper's filter does not
select `ai-tools-relabel.service` (the `.path` already carries that warning). `systemctl` is stubbed
as a shell function, so no real unit is touched.

`relabel.sh` pins the other manifest-supplied decision with a security consequence: the
entrypoint file-context predicate (`relabel.lib.sh`). A declared pattern becomes a `semanage`
rule granting `ai_tools_exec_t`, the confined domain's exec entrypoint, so the test drives every
way a pattern could name something outside the sandbox toolchain (traversal, alternation, a
foreign prefix) and asserts each is refused — plus that the type is the library's constant, never
manifest-supplied. It then pins the two pure decisions behind the declared-vs-installed
reconciliation: `ai_tools_entrypoint_reconcile_verdict` over its whole truth table — where `stale`
is the verdict that must fail a relabel, being the one cause a rerun cannot clear, and an
uninterpretable flag must err toward it rather than toward blessing a divergence — and
`_ai_tools_entrypoint_path_reportable`, the allowlist that keeps an agent-influenced path from
splitting a status line or carrying an escape sequence to the operator's terminal. Both are pure,
so they need no provisioned host; the resolution they consume is exercised in
`integration/selinux.sh`.

Two further sections cover what happens when a rule does **not** register, with `semanage` stubbed
as a shell function so no policy store is touched. The first asserts the refusal carries
`semanage`'s stderr, collapsed to one line, and that it arrives on the **status line** rather than
in a variable — the labelling runs inside a `$(...)` in `ai-tools-relabel-agent`, so a variable set
there is gone by the time the renderer reads it, and the assertion is made through that same
capture. It also pins the stream split in the other direction: `semanage`'s stdout must never reach
the caller, which parses that stream as verdict lines. The second drives `ai_tools_relabel_lock`
across real processes — a held lock is reported as held, the contended run proceeds anyway, the
lock is released when its holder exits, and an uncreatable lock file is reported rather than fatal.
A third pins the per-agent verdict each agent's report closes with, which is what
`ai-tools-relabel-agent` files for `ai-tools --status`: both halves stubbed, over the whole truth
table. Two entries carry the weight — a path that is not installed yet must read as "nothing to
label" rather than as labels applied, and must not fail the run, or every host would report green
before provisioning and non-zero after it.

`entrypoint-verify.sh` pins the pure half of the entrypoint verifier (`entrypoint-verify.lib.sh`,
see [updater](updater.rule.md)). Every assertion targets a way the gate could fail **open**: an
absent pin must read as `unpinned` and never as a mismatch (collapsing them would report a fresh
install as tamper, or — inverted — bless a tampered one); a checksum is admitted only in exact
64-hex shape, so malformed JSON, an absent platform, or a crafted value yields an empty result rather than
a value that could compare equal to a partial observation; a URL template with no `{version}` slot
is refused rather than fetched as-is, since one manifest for every version reads as "verified"
while checking a release it never looked at; and the template charset excludes every character that could
carry a shell metacharacter or a traversal into `curl`. It also pins the public pin path, which `ai-tools --status` reads to report verification
state: an agent name becomes a path component, so a name that could escape the pin directory must
yield an empty result. Its pin-reuse section covers the shortcut the unattended callers take (see
[updater](updater.rule.md)), where the failure direction is the opposite of the rest of the file: a
reused verdict is indistinguishable downstream from a fresh one, so each assertion drives a way the
predicate could answer a question it was not asked — a changed checksum, version, or inputs digest,
and a pin recording no digest at all. The whole section is guarded on the deployed library carrying
the predicate, because an absent function exits 127, which every negative case would otherwise read
as a correct refusal. The label record written beside it is covered the same way — the shared path guard,
a `RESULT` outside the vocabulary refused rather than filed (an unrecognised value reads as "never
relabelled", which is a different report from the one it meant to make), a reason that is not a
token dropped rather than written where the reader's charset clamp would silently lose it, and a
round trip asserted through `services.lib.sh`'s **real** accessors, since a record and its reader
are worth little unless they agree on the grammar. It closes with the one impure assertion that does not need a vendor: the library refuses a
**non-root** pin write itself, rather than letting it fail on `EACCES`, so the caller can tell "not
permitted" from "the directory is missing". The
signed-manifest probe is not driven here — it needs the vendor's live endpoint, `gpgv`, and a
300 MB hash — and its boundary half (neither the pin, the pin directory, the shipped key, nor the
library is agent-writable) is in `boundary/access.sh`.

`selinux-groups.sh` pins the optional-group registry (`selinux-groups.lib.sh`, shared by
`ai-tools-admin selinux` and `install-selinux.sh`): the four-field accessors (including the
`stability` field, guarding the regression where a fourth pipe field bleeds into the reason), the
validity predicate the `selinux groups enable` gate depends on (an unknown name is rejected), and the
`is_experimental` predicate agreeing with the field (it decides whether `selinux groups enable` loads a
shipped module or refuses and points to the source workflow). And — because only **stable** groups
ship prebuilt — registry↔filesystem lockstep: every registered group has a `.te` source; a
**stable** group additionally has a **committed** `.pp` while an **experimental** group must have
**no committed** `.pp` (source-only, so a compiled dev copy left tracked is caught); and no policy
module on disk is missing from the registry. The lockstep half reads git track-state, so it needs
the checkout.

It closes with the registry's one impure accessor, `ai_tools_selinux_group_loaded`, whose failure
mode is a **race** rather than a wrong answer: `semodule -l` needs several writes to deliver a
few hundred module names, so reading it as `semodule -l | grep -qx` lets grep exit on the match
and leaves the writer to die of SIGPIPE, which `pipefail` reports as 141 — a loaded module read as
absent, about half the time. `semodule` is stubbed as a shell function emitting one line per
`printf`, so a single-write listing cannot hide the regression, and the probe is driven 25 times
because one green run is not evidence about a race. The same shape reached production twice (the
`.TH` check in `man.sh` failed at random on the EL container runners for exactly this reason), so
each remaining `semodule -l` probe now captures the listing before matching it.

**`integration`** — checks that need a completed install and the running system
(`perms.sh`, `wrapper.sh`, `hooks.sh`, `symlink-helper.sh`, `handback.sh`, `cli.sh`,
`ai-tools-run.sh`, `systemd.sh`, `selinux.sh`): installed-artifact ownership/modes, sudoers
syntax, the wrapper launched end-to-end (its allowlist gate, `!`-exclusion refusal,
fail-closed load of `safe-paths.lib.sh`, and consultation of the protected-paths backstop on
the launch CWD), the handback `socket → daemon → helper` chain (including its negative paths —
unknown verb, wrong/empty/non-absolute/control-character args, and an out-of-allowlist CHOWN
all refused), the CLI principal guard (refuses root and the sandbox account), `ai-tools-run`'s
`AI_TOOLS_AGENT_EXEC` / `AI_TOOLS_PROJECT_DIR` re-validation and its entrypoint gates (a bad value —
or an entrypoint that does not match its pin — is refused before any session launches — including a real sibling binary in the same versioned `bin` directory, which
is refused because no enabled agent manifest claims that launcher, and a non-semver version
directory) plus its pinned session-confinement properties
(`RestrictNamespaces`/`NoNewPrivileges`/`UMask`), the claude-code session-env pins
(`DISABLE_AUTOUPDATER`, `CLAUDE_CONFIG_DIR`, `NODE_COMPILE_CACHE` — asserted by **sourcing** the
fragment into the two arrays it is contracted to append to, so a fragment that stops appending or
appends to a renamed array fails rather than silently costing the session its environment), the
`settings.json` hook + deny-rule declarations, and SELinux labels (the `claude.exe` entrypoint and the handback daemon
binary). Every assertion about the shim lives in `ai-tools-run.sh` beside it — its input
validation, the unit properties it pins, and the session env it sources — so a change to the
shim has one file to answer to; `handback.sh` keeps the bridge and the entrypoint label.
`selinux.sh` asserts the confinement layer is enforcing: when the
`ai_tools` module is loaded the system is `Enforcing` and neither `ai_tools_t` nor
`ai_tools_handback_t` is marked permissive; it skips when the module is absent (the layer is
optional). It also holds the two entrypoint assertions that need a labelled host — that each
agent's declared file-context rule still covers what its package installed, and that no link in
the exec chain carries a type the confined domain may manage. `systemd.sh` is the single home for unit checks:
`systemd-analyze verify` on each shipped unit, plus enablement in the correct instance —
the `nvm-update` timer in the sandbox account's own `--user` instance, the relabel watcher
and handback socket in the system instance. The
handback chain cannot use the `AI_TOOLS_ALLOWLIST` override — the live daemon execs helpers
with its own environment, so the helper reads the **real** allowlist. The hooks test puts its
fixtures in a self-cleaning subdir **inside the project the suite is run from**, reusing that
project's existing allowlist entry (the session runs in it); it confirms the run-dir is
allowlisted and **skips** otherwise, and under enforcing labels the fixture
`ai_tools_project_t` so the confined chown can act on it. The wrapper test stays hermetic by
pointing `HOME` at a `/tmp` testdir (the wrapper keys its allowlist off `${HOME}`) and runs
the wrapper under `setsid`, so it never touches the real allowlist or fires a claim prompt.
Run as root.

`perms.sh` is the **single source** for the deployed-artifact permission assertions (every
installed file and directory's owner/group/mode): `install.sh` does not carry a parallel checker —
`sudo ./install.sh check-perms` execs `perms.sh`, and the install's verification phase reaches
it through `tests/run.sh all`. Adding or repermissioning an installed file means updating the
`check_file` list here, nowhere else.

**`boundary`** — confinement assertions executed **as the agent** (`sudo -u SANDBOX_USER`)
(`access.sh`, `providers.sh`, `filters.sh`, `sudo.sh`): the agent cannot read the secret-pattern library or write the
control plane, cannot reach the operator's credential stores (`~/.ssh`, `~/.gnupg`, …), and
does not hold any sudo rights — `sudo -l` reports it is not allowed to run sudo at all (both NOPASSWD
rules belong to the projects user and drop privilege), plus the account hygiene that invariant
leans on (nologin shell, locked password, non-membership in `ai-ops`). It also asserts the agent
cannot write the **pin**, the pin directory, the shipped signing key, or the verifier library — the
inputs that decide what a verified checksum is — so it can neither record nor authorise a checksum
for a binary it modified. Those are root-owned files, so they are DAC facts and this vantage sees
them. Its one assertion that is not a permission check is the journald one: it *writes* a line as
the agent under a root helper's syslog tag and asserts journald files it under the sandbox uid and
not under `_UID=0`. That is the boundary half of the documented query form (see
[logging](logging.rule.md)) — the forgery is reachable, and what makes it separable is the uid the
sender cannot set, not the tag. A host with no journald skips: an absent line is not evidence.
`providers.sh` asserts
the deployed half of "the sandbox cannot widen its own surface": none of `operator.conf`,
`conf.lib.sh`, `providers.lib.sh`, the four provider directories, the manifests, fragments and
contributed commands in them, or the `ai-tools-run` shim and the `bin` directory holding it is
agent-writable, while
the NuGet restore cache the dotnet integration needs
**is** — both directions matter, since a read-only cache breaks the integration as surely as a
writable tools dir breaks the boundary. `admin-commands.d` and the `dotnet` command in it are the
highest-privilege pair in that list: what a writable one would buy is not a wider session but a
command `ai-tools-admin` runs as root. It is the counterpart to `unit/providers.sh` and
`unit/admin-commands.sh`, which assert the runtime refusals; this one asserts the agent cannot
reach the state those refusals exist to catch. `filters.sh` is the same pair for the command filters: the engine, `filters.d`
and the rule sets in it, `operator.conf`, and the agent-side hook body are all asserted
non-agent-writable — the engine because it is sourced as the agent on every Bash call, the rule
sets because they decide what every command in a session becomes. These probe **DAC and
account state** from the sandbox account's vantage — they run as the sandbox *user*, not inside
the `ai_tools_t` SELinux domain (a launched session), so they assert the filesystem/credential
boundary; the SELinux enforcing posture is asserted separately in `integration/selinux.sh`. A
property the **type layout alone** enforces is therefore not assertable here, and reads as its DAC
answer: the agent's inability to write its own entrypoint is one (DAC permits it — the account owns
that tree), so it is asserted in `integration/selinux.sh` as the layout the policy rests on, one
check per swap vector.

## Quirks

- **The result word carries a colour escape.** `harness.sh` colours `PASS` green, `SKIP` yellow
  and `FAIL` red when stdout is a terminal or `AI_TOOLS_TEST_COLOR=1`. `run.sh` and `install.sh`
  both set that variable, because each pipes the suite through `tee` and the harness's own tty test
  then reads false while a terminal is still watching. Only the word is wrapped, so a grep on a
  result *message* is unaffected; a grep anchored on the *word* must allow the escape, as
  `run.sh`'s failure summary (`_FAIL_RE`) does. Anchored without it the summary comes back empty on
  a coloured run, while the suite still reports the failure and exits non-zero.
- **Setgid bits survive numeric `chmod`.** GNU coreutils `chmod` with an octal mode does
  not clear a directory's setgid/setuid bit; a testdir under a setgid parent inherits it.
  Assertions on the rwx bits use `perm()` (low 3 octal digits), not raw `stat %a`.
- **The wrapper prompts on `/dev/tty`, not stdin.** `</dev/null` does not suppress it;
  `setsid` (no controlling tty) does, so the wrapper takes its non-interactive default.
- **The wrapper keys off `${HOME}`** for the allowlist, so its test mocks the allowlist by
  pointing `HOME` at a `/tmp` testdir — no helper override needed there. **The CLI does not**: it
  resolves the invoking user's home through `getent passwd`, so that no environment variable
  can redirect a registry write. A test that drives both against one fixture must therefore set
  `HOME` *and* `AI_TOOLS_ALLOWLIST`; setting only the first steers the wrapper while the CLI
  quietly edits the operator's real allowlist.
- **The wrapper detects a controlling terminal by opening `/dev/tty`,** not by the node's
  permission bits (which read `rw` even with no controlling tty). Under `setsid` the open
  fails, so every wrapper invocation in a test cleanly skips the claim prompt instead of
  acting on it — the integration wrapper test relies on this to never claim a project.
- **The handback path cannot cross `/tmp`.** `/tmp` and `/var/tmp` are polyinstantiated per
  session by `pam_namespace` (`/etc/security/namespace.conf`), so a fixture the test creates
  under `/tmp` is invisible both to the hook's own `sudo -u SANDBOX_USER` session (a fresh,
  empty `/tmp` instance) and to the host-namespace handback daemon — the hand-back silently
  no-ops. Any test that drives the live `hook → daemon → helper` chain puts its fixtures
  under the projects user's `${HOME}` (shared across namespaces), not in a `/tmp` testdir.
