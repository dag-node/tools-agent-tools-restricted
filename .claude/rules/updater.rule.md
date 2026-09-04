---
paths:
  - "src/opt/ai-tools/bin/nvm-update.sh"
  - "src/usr/local/lib/ai-tools/npm-verify.lib.sh"
  - "src/usr/local/lib/ai-tools/entrypoint-verify.lib.sh"
  - "src/usr/local/lib/ai-tools/keys/**"
  - "src/usr/local/libexec/ai-tools/ai-tools-bootstrap.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-launcher-symlink.sh"
  - "src/usr/local/libexec/ai-tools/ai-tools-relabel-agent.sh"
  - "src/usr/lib/systemd/user/nvm-update.service"
  - "src/usr/lib/systemd/user/nvm-update.timer"
  - "src/usr/lib/systemd/system/ai-tools-relabel.path"
  - "src/usr/lib/systemd/system/ai-tools-relabel.service"
---

# Node/claude updater and symlink repoint

A scheduled `nvm-update` job keeps Node.js and the enabled agents' npm packages current under
`/opt/ai-tools`. Which agents — their npm package and launcher — is resolved from the
per-package manifests, not hardcoded; see [providers](providers.rule.md). After an upgrade the
versioned `claude` symlink is repointed through a root helper and the new entrypoint is
relabelled for the SELinux transition.

## Toolchain provisioning (`ai-tools-bootstrap`)

`ai-tools-bootstrap` provisions the toolchain the updater then maintains: run once as root,
it creates the `SANDBOX_USER` account and its `/opt/ai-tools` home if absent, installs nvm,
Node (`AI_TOOLS_NODE_MAJOR`, default 22), and each enabled agent's npm package as `SANDBOX_USER`
(the enabled set resolved via [providers](providers.rule.md)), points
`/opt/ai-tools/bin/<launcher>` at each versioned binary, relabels the freshly
installed entrypoint (`ai-tools-relabel-agent`, gated on that helper being deployed, so
the first launch after a fresh provision is confined without a manual `ai-tools --relabel`),
and captures the initial control plane in a root-private git repo. It is the one network
step, so it is an operator command rather than an RPM scriptlet (which must succeed
offline). It is idempotent: an
existing account, nvm install, or Node version is reused. It enables `SANDBOX_USER` linger
and the `nvm-update.timer` in that instance (best-effort), so the maintenance schedule is
live once the toolchain exists.

Starting the timer **pre-seeds its `Persistent=` run-stamp** (`$XDG_DATA_HOME/systemd/timers/
stamp-nvm-update.timer` under `/opt/ai-tools`, written as `SANDBOX_USER`) so it begins on its
next scheduled window rather than an **immediate catch-up run**. The timer's daily `OnCalendar` has usually already
passed when the toolchain is provisioned, and with no prior stamp `Persistent=true` would run
`nvm-update.service` at once — which reinstalls the agent package, reminting `claude.exe` at
`lib_t` (a freshly written entrypoint is born the default type; only `restorecon` applies
`ai_tools_exec_t`, see [post-upgrade relabel](#post-upgrade-entrypoint-relabel) below), and its
asynchronous repoint→relabel chain races the operator's first launch into the mislabel refusal.
Provisioning has just installed the current toolchain, so recording "last run = now" is
truthful; the next run is the next scheduled window. `ai-tools-bootstrap` and `install.sh` both
seed the stamp before starting the timer (the RPM/dev flows), and each also runs from a neutral
CWD so the `sudo -u SANDBOX_USER` steps do not inherit an operator directory the account cannot
traverse back into.

As a closing interactive step it offers to set the **sandbox git commit identity** in the
control-plane gitconfig — the name/email the agent authors commits with. This is the one
interactive point both install flows share: the RPM `%post` (and `install.sh`) seed a
default (`ai-tools@<domain-or-hostname>`) but `%post` cannot prompt, so the operator adopts
their own git identity, keeps the default, or edits the file by hand here. It runs only when
the control plane is present (the gitconfig exists) — a bootstrap that precedes control-plane
install skips; past that gate `msg.lib` is deployed, so the
prompt requires it and fails closed like any other, no fallback (see
[messaging](messaging.rule.md)).

## Where the update runs

`nvm-update.service` and `nvm-update.timer` ship in `%{_userunitdir}` and are enabled in
`SANDBOX_USER`'s own `systemd --user` instance, so the updater runs as `SANDBOX_USER` and
writes the shared `.nvm` tree (`%h=/opt/ai-tools`) directly. The timer fires daily; one
instance maintains the toolchain the whole team shares. `ai-tools-bootstrap` enables the
timer once it has provisioned the toolchain and `SANDBOX_USER`'s linger; `install.sh`
enables it for the dev flow.

## Last-run stamp

Running there puts the updater's health out of the operator's reach: querying a `--user` manager
needs that account's own bus, the machine transport (`systemctl --user -M`) needs root, and no
sudo rule grants either — so a failing update is invisible from an operator session while the
toolchain silently stops advancing. `nvm-update.sh` closes that by recording every run's outcome
in a **last-run stamp**, `/var/opt/ai-tools/state/nvm-update.status`, which
`ai-tools --status` reads through `services.lib.sh` (see [cli](cli.rule.md)).

The stamp is the second of two independent records, and deliberately so: the first is what the run
*says* (its `log`/`warn`/`die` output, which the unit routes to the journal), and a run can fail
silently. `nvm-update.sh`'s emitters therefore write to stdout/stderr **before**
their best-effort `systemd-cat` copy, and guard that copy — under `set -e` with `pipefail` a bare
`printf | systemd-cat` pipeline whose `systemd-cat` fails aborts the updater, and aborts it silently,
because the line explaining why comes after the statement that failed. A logger never decides the
fate of the operation it reports on, here as in `log.lib.sh` (see [logging](logging.rule.md)).

`write_stamp` is installed as the script's `EXIT` trap, so the record covers every exit path — a
`die`, an uncaught `set -e` failure, and a clean run alike — and it is best-effort throughout: it
never turns a successful update into a failed unit, and a host whose stamp is absent gets a warning
naming the reinstall that restores it, while the report states the unit as unknown rather than
guessing. The whole text goes out in a single write, so the window in which a reader could see a
partial stamp is negligible; one that lands there anyway does not carry a parseable `RESULT` and reads as
unknown, never as a wrong verdict. The content is the shared `KEY=value` grammar:
`RESULT=ok|skipped|failed`, `EXIT_CODE`, `FINISHED` (UTC, ISO-8601), `TRIGGER=unit|manual`, `NODE`,
and `REASON` on a skip.

### The run classifies itself: ok, skipped, or failed

`RESULT` is the run's exit status classified for a reader, and the classification is the updater's
own (`nvm-update.sh`'s exit codes: `0` current, `1` a fault on this host, `3` transient). The third
exists because the most common way this job does not update anything is not a fault at all: the
host was offline at the timer's daily window, so the registry could not be reached, the toolchain
was left alone, and the previous trusted version stays active. That run exits `3`, records
`RESULT=skipped` with a `REASON` token, and reports as `SKIPPED` rather than `FAILED` — there is
no fault for an operator to fix, and a red line that means "your laptop was disconnected" spends
attention that a real fault then has to compete with.

The split is coarse by intent. It does not diagnose *why* the registry was unreachable — a
disconnected machine and a registry outage are one state from inside a confined `--user` job — only
whether a retry is the right response (the unit retries `3` and not `1`; see
[the retry policy](#retrying-a-transient-failure) below) and whether an operator should be alarmed
now. What keeps `skipped` from becoming a way to hide a real problem is that it does not stop the
clock: the stamp still ages, and a condition that persists past the record's 48h grace reports
`STALE`, the same escalation a schedule that stopped firing gets. Offline once is routine; offline for a week is a toolchain that has stopped advancing.

### Retrying a transient failure

`nvm-update.service` carries `Restart=on-failure` with `RestartPreventExitStatus=1`, so the
transient class retries and the fault class does not: a broken toolchain or a failed signature check
will fail the same way on a retry, and neither should churn against the registry. Retries are
bounded by the unit's start limit — 6 starts per 6h, 30 minutes apart — which recovers an outage of
a couple of hours and then stops, leaving the stamp to age into `STALE` for one that lasts longer.

This is the only recovery path a *failed* run has. The timer's `Persistent=true` covers a window
missed while the manager was not running; a window taken by a run that then failed is spent, because
systemd stamps a timer when it elapses and not when the service succeeds. Ordering on
`network-online.target` is not a path either — it gates unit startup, while this unit is started by a
daily timer on a machine that has typically been up for days — so the unit is not ordered against it
and connectivity is handled where it arises, in the run's own exit status.

The daily window is the host's local time; an operator moves it with `sudo systemctl --user -M
ai-tools@.host edit nvm-update.timer`.

Each field has a distinct reader. `RESULT` and `EXIT_CODE` are the service's verdict. `FINISHED`
carries two: it dates that verdict, and its **age** is what `nvm-update.timer` — which can
otherwise report only `?` — infers its own health from, since a run systemd started proves
the timer fired (see [cli](cli.rule.md) for the `stamp_mode`/`max_age` fields that express this).
`TRIGGER` is what makes that inference sound: only a systemd-started run is evidence about a
*schedule*, so it records whether `INVOCATION_ID` — set by systemd for every unit it starts — was
present, and the timer's verdict is declined for anything else. Without it a run the operator did
by hand would report a dead timer as healthy for the whole grace window and, worse, suppress the
staleness that is the only way a stopped schedule surfaces at all. A run started by hand *through*
the manager (`systemctl --user start nvm-update.service`) is indistinguishable from a triggered one
and counts as `unit`: the inference is bounded to systemd-started runs, not to scheduled ones.
`NODE` lets `ai-tools --status` report the active Node version without reading the `700` toolchain,
which the operator cannot. `REASON` is written only on a skip and says which transient condition
ended the run (`offline`), so the report can state why a run made no change instead of leaving the
operator to infer it.

### What the stamp is trusted for

Nothing. Its writer is `SANDBOX_USER`, so that account can state any outcome it likes, and the
permissions around it bound **what it can touch**, never whether the contents are true:

- `/var/opt/ai-tools/state` is `0750 root:SANDBOX_GROUP` — root-owned and **not** group-writable,
  so the account has traverse only and cannot create, unlink, rename, or symlink-swap anything
  there. Operators reach it through a `g:ai-ops:r-x` ACL, the same grant pattern as the rest of
  the sandbox area. The setgid bit inherited from the `2750` parent is stripped **symbolically**
  (`chmod g-s`): neither `install -d -m` nor a numeric `chmod` clears setgid on a directory.
- The stamp itself is `0640 SANDBOX_USER:ai-ops`, created by the package (`%post`, and
  `install.sh` for the dev flow) and only ever **rewritten in place** by the updater. The added
  surface is therefore exactly one inode's contents.

That the contents are forgeable is accepted, on two grounds. **No decision reads the stamp** — it is
rendered in one status report and never evaluated, and every value is read defensively
(`ai_tools_service_stamp_field`: a symlink is refused, only the first 4 KiB is examined, and a
value must be a short `[A-Za-z0-9:+._-]` token or it reads as no value at all), so no control byte
or escape sequence can reach the operator's terminal through it and a corrupt stamp degrades the
unit to *unknown* rather than to a wrong verdict. And it is **never the weakest link**: an account
able to write the stamp can already write the toolchain the stamp reports on, which is by far the
more valuable target. On an enforcing host it can write neither — both resolve to `usr_t` (the
`/var/opt` → `/opt` base alias, see the `sandbox-projects` note in `ai_tools.fc`), which
`ai_tools_t` may only read, while `nvm-update.service` runs outside that domain and writes
normally.

## Version resolution

`nvm-update.sh` resolves the latest LTS in the `NVM_NODE_MAJOR` series itself
(`nvm ls-remote --lts | sort -V | tail -1` selects the highest semver, not "first match"
or "currently active"); an explicit version argument overrides the lookup. Prune logic
collects all versions referenced by any named alias into an associative array before
removing anything, so a version another alias points to is retained, as is any version a
live session still runs from.

## Launcher symlink repoint root helper (`ai-tools-launcher-symlink`)

`/opt/ai-tools/bin` is `0551` and not group-writable (see
[ownership-and-hooks](ownership-and-hooks.rule.md)), so `SANDBOX_USER` reaches a stable
launcher symlink only through a root helper. `ai-tools-launcher-symlink` takes one argument and
**is agent-agnostic**. It validates the path is exactly
`…/node/v<MAJOR>.<MINOR>.<PATCH>/bin/<launcher>` and exists, takes `<launcher>` from that path's
own basename, and accepts it only when an **enabled agent manifest claims that launcher** — the
same allowlist `ai-tools-run` matches an executable against (see [providers](providers.rule.md)).
Two properties follow: the link it writes is always `/opt/ai-tools/bin/<launcher>` for the binary
of that same name, so the two can never diverge; and the set of links it can write is exactly the
set of enabled agents. An allowlist it cannot resolve **refuses** rather than admitting anything.

The updater (one call per enabled agent) and `install.sh` are the only callers; the updater
reaches it through the [handback bridge](handback-bridge.rule.md) `SYMLINK` verb. The helper
repoints the symlink but does not relabel the new entrypoint — it runs in the handback domain,
which does not hold any relabel rights.

## Post-upgrade entrypoint relabel

A freshly installed entrypoint is born the default type (`bin_t`/`lib_t`), so the
`→ ai_tools_t` domain transition fires only once it carries `ai_tools_exec_t`.
`ai-tools-relabel-agent` applies that label, and it is **agent-agnostic**: the base policy
does not carry an entrypoint rule, so for each *enabled* agent the helper reads the path pattern that
agent's manifest declares (`entrypoint_fcontext`, see [providers](providers.rule.md)), registers
it as a local `semanage fcontext` rule mapping it to `ai_tools_exec_t`, restorecons every file it
matches, and verifies each took the type. It runs as root (a domain that holds relabel), is
idempotent, and no-ops when SELinux is off or the `ai_tools` module is not installed — there is
then no `ai_tools_exec_t` to assign, the same condition `ai-tools-run` keys on.

The type is pinned in `relabel.lib.sh` and a declared pattern is accepted only when it can match
no path outside the sandbox toolchain root (no traversal, no alternation, an anchored literal
head), so a manifest chooses **which** file is its entrypoint, never what label a file gets. The
whole body lives in `relabel.lib.sh`, shared with `install-selinux.sh`'s verify pass.

**Relabels serialize, and a refusal names its cause.** Three callers run this helper and an
upgrade drives two of them at once — the agent package's `%post` and the `ai-tools-relabel.path`
watcher, which the same transaction's `restorecon` of `/opt/ai-tools` triggers. `semanage`
serializes on the policy store and reports an error to whichever process finds it held rather than
waiting, so overlapping runs leave rules unregistered and both report a failure neither caused.
`ai_tools_relabel_lock` (`relabel.lib.sh`, taken by `ai-tools-relabel-agent` and by
`ai-tools-relabel`, which writes the same store for a project claim) makes the second wait. It is
best-effort in one direction only: no `flock`, an uncreatable lock file, or a wait that runs out
proceeds unserialized and says so, since labelling is idempotent and every refusal is reported, so
an untaken lock costs a repeat run rather than a wrong label.

`semanage`'s own stderr is what a refusal reports, carried on the status line the helper renders
and logs (`relabel.log`, journald, and so `ai-tools --audit`) — the store being held and a type the
loaded policy does not define need different remedies, and the message is the only thing that tells
them apart.

### The labelling half leaves a record too

Each run records what it could do about every enabled agent's labels, in
`/var/opt/ai-tools/state/entrypoint-label.d/<agent>` — the same `KEY=value` grammar, directory
ownership, and defensive reader as the pin beside it (`AGENT`, `RESULT=ok|failed|skipped`,
`LABELLED`, and a `REASON` token on anything but `ok`). `ai-tools --status` reports it under that
agent's verification line (see [cli](cli.rule.md)).

It exists because **the operator can observe neither the label nor the run that applies it**. The
entrypoint is in a toolchain they cannot traverse, `matchpathcon` computes only what a label should
be, and two of the three callers — an rpm `%post` and `ai-tools --relabel` — are not units, so
no systemd record covers them. A run that fails leaves its account in a journal the operator
does not read; the pin, written earlier in the same run, is left standing and green.

The record is written by `ai-tools-relabel-agent` from a per-agent verdict the labelling library
closes each agent's report with (`agent <name> <ok|failed|none>`, see `relabel.lib.sh`), so one
place decides an agent's outcome and one place files it. `none` — no entrypoint installed to label —
is filed as `skipped`, not `ok`: before `ai-tools-bootstrap` provisions the toolchain there is
no entrypoint to label, and reporting that as labels applied would show green for work that did not
happen. It is written on the DAC-only path too, where the run exits early because there is no
`ai_tools_exec_t` to assign, so that host reports "nothing to label" rather than "cannot tell".
Writing it is best-effort and never changes the outcome of the relabel it describes.

The helper then **reconciles** what it applied against what is installed: it resolves
`/opt/ai-tools/bin/<launcher>` the way the launch preflight does and reports `stale` — non-zero —
when an entrypoint is installed at a path the declared pattern does not cover, instead of the
`none`/success a pattern matching no path would otherwise produce. So a relabel that exits 0 means
the next launch will not fail closed on the entrypoint label, and a manifest that has stopped
describing its own package is named as the cause rather than diagnosed as a missing install. It
never labels the resolved path: the files that take `ai_tools_exec_t` stay exactly those the
root-owned manifests declare (see [agent-claude-code](agent-claude-code.rule.md)).
`ai-tools-relabel-agent --remove <agent>` is the erase-time counterpart: the agent package's
`%preun` drops its rule while its manifest is still on disk.

`ai-tools-bootstrap` runs the helper directly at provision time (above). Two further paths
run it after an upgrade, both as root, never `SANDBOX_USER`:

- **Automatically**, through the `ai-tools-relabel.path` watcher. The `.path` watches the
  `/opt/ai-tools/bin` **directory** — whose entries are the stable launcher symlinks the updater
  repoints, atomically (`mv -T` over the old link), so the rename lands as a change in that
  directory whichever agent's launcher moved — and triggers `ai-tools-relabel.service` (a root
  oneshot in the system instance), which relabels **every** enabled agent's entrypoint, so a Node
  bump runs without operator action and one watch covers any number of agents. Only root writes that
  directory, so a trigger is always a control-plane change, and the service is idempotent, so an
  unrelated one costs a no-op pass. `ai-tools-launcher-symlink` is idempotent too: it
  skips the repoint (and so the watcher) only when the link is already current **and** it has
  confirmed the target entrypoint carries `ai_tools_exec_t`, so a repoint that would drive a
  needed relabel — a version bump, or a same-version reinstall that reminted the entrypoint at
  `bin_t` — always fires, while a daily no-op run stops churning the link. The repoint is the
  sole trigger: the sandbox
  updater does not hold any relabel rights and reaches root only through the handback bridge, whose
  domain deliberately holds none either, so a repoint that does not land (handback down in a
  manual run) leaves the relabel to `ai-tools-run`'s fail-closed preflight and the operator's
  `ai-tools --relabel`. The watcher is **enabled by default** on install through the shipped
  systemd preset — `%systemd_post ai-tools-relabel.path` applies `85-ai-tools.preset`, which lists
  it beside the handback socket; without that explicit line the distribution's `disable *` default
  would leave `%systemd_post` a no-op (the same enablement the socket needs). Enabling a `.path`
  unit does not start it, so the `ai-tools-integration-nodejs` `%posttrans` starts it — the twin of
  `ai-tools-base`'s `%posttrans` starting the handback socket — making the watcher live on a fresh
  install without a reboot; it is also restarted across upgrades (`%postun_with_restart`), so it
  runs without a manual bootstrap. Should it be down
  anyway, `services.lib.sh` surfaces it before the next Node bump would fail-close a launch on a
  mislabelled entrypoint: proactively at launch (`claude.sh` warns, warn-not-block, from the same
  registry) and in `ai-tools --status` (see [cli](cli.rule.md)).
- **On demand**, through `ai-tools --relabel` (see [cli](cli.rule.md)), which runs the
  same helper via the `%ai-ops` NOPASSWD sudo rule (the relabel rule in
  `sudoers.d/ai-tools`; see [launch](launch.rule.md)). `install-selinux.sh relabel`
  is the comprehensive source-tree sweep.

The relabel runs outside the handback domain by design: `ai_tools_handback_t` is
agent-reachable and does not hold any relabel rights (`ai_tools.te`), so the privilege stays off
the agent's reach. The watcher is best-effort; `ai-tools-run`'s fail-closed preflight (see
[confinement](confinement.rule.md)) is the backstop — when SELinux is enforcing and the
module is installed, it refuses to launch a session whose entrypoint is not
`ai_tools_exec_t`, so a watcher relabel that does not land degrades to a refused launch the
operator clears with `ai-tools --relabel`, never an unconfined session.

## `loginctl enable-linger`

Linger on `SANDBOX_USER` keeps its `systemd --user` instance running without an
interactive login, so both the daily `nvm-update` timer and each `ai-tools-run` session unit
have a live user manager. Required for headless/unattended operation.

## Toolchain provenance

`nvm` verifies Node's published `SHASUMS256` on download, and `install_packages` gates npm
install-script execution behind an `--allow-scripts` allowlist scoped to the named managed
tools (never a blanket allow-all). `npm install` verifies each package's registry integrity
hash, so a corrupted download is rejected.

The integrity hash proves only that the download matches what the registry advertised, so npm
registry **signature** verification closes the compromised-registry/mirror vector.
`npm-verify.lib.sh` runs `npm audit signatures` (the registry ECDSA signature over each
package, plus SLSA provenance where published) over the installed toolchain. `npm audit
signatures` refuses a global install (`EAUDITGLOBAL`), so the verifier audits a throwaway
project whose `node_modules` is a symlink to the global tree (`npm root -g`) and whose
`package.json` lists the global top-level packages: npm's arborist reads the real installed
tree, including transitive dependencies, with no reinstall and no network beyond the registry
key/attestation fetch.

The verifier runs as the sandbox account, never root: it audits the sandbox-owned (agent-
writable) global tree, and as root it would resolve root's global prefix — a verdict over the
wrong tree — and run `npm`/`node` over agent-controlled files as root. `nvm-update.sh` runs it
directly; `ai-tools-bootstrap` runs it inside a `sudo -u` sandbox-account step; and the impure
entry `ai_tools_verify_npm_signatures` refuses to run as root as a fail-closed backstop. The
pure decision `ai_tools_npm_verdict` — no npm, no filesystem, no privilege — is split out and
unit-tested over the audit-output truth table (`tests/unit/npm-verify.sh`), mirroring
`confinement.lib.sh`'s pure verdict. That verdict parses its JSON with `node`, which exists only
in the sandbox toolchain and never on root's `PATH`, so the root-run test resolves it the way the
launch wrapper resolves the agent binary — one `readlink` hop through a stable launcher symlink to
the active version's `bin` — and exposes **that one binary** under the name the library calls
rather than putting the sandbox-owned toolchain directory on root's `PATH`. Resolving from `PATH`
alone would skip the file on a fully provisioned host, which strict mode reports as no coverage.

The verdict gates activation fail-closed. An **invalid** signature (tamper) aborts before the
prune and the launcher-symlink repoint, so the previous, trusted version stays active and the
tampered tree is left unwired. An **inability to verify** — offline, an npm without `audit
signatures`, or a missing library (root-owned, so a missing one is a broken install, not agent
action) — warns and proceeds, since the update itself is not the danger and the check is
best-effort against such hosts. The signing keys are fetched from the registry keys endpoint
(`<registry>/-/npm/v1/keys`) over HTTPS on each run.

## Entrypoint verification and the pin

The checks above attest to what was **delivered**. Neither can see what the entrypoint *is now*: the
exec root is sandbox-owned, and `npm install -g` does not reinstall an unchanged version, so on a
DAC-only host a modified entrypoint persists across sessions and operators indefinitely (under
SELinux the vector is closed outright — see [confinement](confinement.rule.md)).
`entrypoint-verify.lib.sh` closes it by comparing the installed entrypoint against a checksum the
**vendor signed**. The three optional manifest fields that declare where to find it — and why the
signing key is shipped rather than fetched — are in [providers](providers.rule.md); the library
itself is agent-agnostic.

The work splits by principal, which is what keeps the network off the launch path. The operator
cannot read the entrypoint at all (the toolchain is `0750` sandbox-owned), so the verification runs
as **root**, and its result travels to the launch as a **pin**:
`/var/opt/ai-tools/state/entrypoint-pin.d/<agent>`, in the shared `KEY=value` grammar
(`AGENT`, `VERSION`, `SHA256`, `VERIFIED`, `INPUTS`, `SOURCE`). Its directory is root-owned and not
group-writable inside the `0750 root:SANDBOX_GROUP` state root — the same two independent layers
(DAC, plus `usr_t` under enforcing) that bound the last-run stamp — so the account the pin
constrains can read it and cannot write it. It is read back defensively: symlink refused, bounded
read, and a value admitted only in exact 64-hex shape, so a corrupt pin reads as *unpinned* rather
than as a wrong verdict.

| when | who | what |
|---|---|---|
| provision | `ai-tools-bootstrap` (root) | reconciles the entrypoint, which pins it |
| update | `nvm-update` (sandbox) | verifies **before** the repoint — the same position as the npm signature gate |
| update | `ai-tools-relabel.service` (root) | the repoint fires the existing `.path` watcher → reconcile → **write the pin** |
| launch | `ai-tools-run` (sandbox) | hash the entrypoint, compare to the pin — no network, no `gpgv`, no key |

There is deliberately **no manifest cache**. Every fetch happens at a moment the host is already
online (immediately after an update downloaded the package), and the pin is what makes the launch
offline-safe, so a cache would add an input to reason about for no availability gained.

### Answering from the pin, and the one caller that never does

An unattended run may answer from the existing pin instead of refetching. It does so only when
every input to the verdict is unchanged: the installed version, the entrypoint's own bytes, and an
`INPUTS` digest over the manifest URL template, the signing key's path **and content**, and the
declared fingerprints. A pin recording no `INPUTS` is never reused, so an unrecordable digest costs
a re-verification. `ai_tools_entrypoint_pin_reusable` is the predicate, unit-tested over that truth
table.

This is worth doing because the repeat runs are frequent and the cost is not: one upgrade can fire
the `.path` watcher several times, the agent package's `%post` runs on every package update, and on
an air-gapped host each of those spends two connection timeouts per agent to reach "unable to
verify" and leave the pin exactly as it was.

What it gives up is a vendor **republishing or withdrawing** a release it already signed, which
goes unnoticed until something else changes. What it keeps is everything that makes the pin a
tamper gate: a modified entrypoint changes its checksum and a rotated key or repointed manifest
changes the digest, and either takes the full path.

`AI_TOOLS_ENTRYPOINT_PIN_REUSE=1` selects it, and the two unattended callers set it — the
`ai-tools-relabel.service` unit and the agent package's `%post`. **`ai-tools --relabel` never
does**, and by construction rather than by convention: the operator reaches the helper through the
`%ai-ops` sudo rule, which scrubs the environment, so the on-demand verb re-checks the vendor's
signature every time — the behaviour it documents and the one an operator runs it for.
`ai-tools-bootstrap` leaves it unset too, so a fresh provision always verifies in full.

### Three outcomes, and only one of them is tamper

The status contract is `npm-verify.lib.sh`'s, so the two gates in `nvm-update` read alike: `0`
verified, `1` **mismatch**, `2` **unable to verify**. Keeping `1` and `2` apart is the whole
usability of the feature, and `gpgv`'s own exit status separates them exactly — `1` for a signature
it rejects, `2` for a key it does not hold.

- **Mismatch** refuses, everywhere and unconditionally: the relabel fails, the updater declines to
  activate, the launch refuses. No configuration turns it off.
- **Unable to verify** — offline, no manifest published for that release (they are per-release and
  not guaranteed), no `gpgv`, an agent declaring no provenance, or a **vendor key rotation** — warns
  and proceeds, leaving any previous pin standing. A rotation reporting as tamper would fail every
  host closed on an untouched binary, so the agent package ships old and new keys in one keyring and
  declares both fingerprints for the overlap.

`AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY` (`operator.conf`, read through
`ai_tools_entrypoint_verify_required` so the updater and the launch cannot disagree about how strict
the host is) turns the *unverifiable* case into a refusal: the launch will not start an unpinned
entrypoint, and the updater will not activate a release it could not verify. Its default is **no**,
and that is an air-gap decision — unpinned is also the state of a host with an internal npm mirror
and no vendor route, and blocking there would quietly freeze its agent forever. Nothing in this
layer hard-fails offline: the fetch carries a short `--connect-timeout` because it runs inside the
relabel, and so inside an rpm `%post` that must succeed offline.

### Why the pin lives in the relabel helper

`ai-tools-relabel-agent` verifies and pins **before** it labels, on every host — including the
DAC-only one, where the labelling half has no label to apply. Both halves answer one question, *the
entrypoint changed, reconcile it*, and they share the three things that would otherwise be
duplicated: the **trigger** (`ai-tools-relabel.path` watches the launcher directory, so it fires on
exactly the event that changes an entrypoint), the **privilege** (root, which the sandbox-account
updater does not have), and the **timing**. Splitting them would buy one name at the cost of a
second `%ai-ops` sudoers rule and a second unit for a step that must run at the same instant anyway
— so `--relabel` keeps its established name and its scope is stated to be the whole reconciliation,
not the SELinux half alone.

The costs of that folding are bounded rather than absent, and both are handled where they arise: a
networked step now sits inside an otherwise-local verb (which is why it fails soft and connects with
a short timeout), and a pin mismatch fails a command an operator may have run for a label (which is
correct — an entrypoint that is not the binary its vendor published is the more serious finding, and
it is reported first).

## Deferred

**Pinning the registry signing key.** Fetching the keys each run detects a mirror or cache
that serves a tampered package without the real signature, but not a fully compromised primary
registry that serves a forged package, signature, and matching keys together. npm does not expose any
configuration to pin the signing key for `npm audit signatures`, so pinning requires replacing
it with a bespoke verification against a hardcoded key — which forgoes npm's maintained
verifier and the free transitive-tree coverage, and must track npm's key rotation (the endpoint
already serves one retired and one active key) or a rotation breaks updates. TLS covers the
man-in-the-middle key swap, so pinning is defense in depth against a primary-registry
root-of-trust compromise, held against that cost.

For the **agent binary** specifically that gap is now closed from the other side: the entrypoint
verification above pins its key in a root-owned file rather than fetching one, so a compromised
registry serving a forged package, signature, and keys together still fails the release-manifest
comparison. What stays deferred is the rest of the toolchain — Node and npm itself — where no
equivalent signed-checksum manifest is consumed.
