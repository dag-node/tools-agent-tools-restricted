# Entrypoint verification

How `ai-tools` proves that the agent binary it is about to run is the one its vendor published, what
you have to do about it (almost always nothing), and what each failure means. <!-- prose-check: allow: the reader is the actor; "nothing" is the action they take -->

## The short version

Every agent has one **entrypoint** — the executable a session actually starts. `ai-tools` checks it
two ways:

- **At update time**, against a checksum the vendor **signed**, using a signing key shipped in the
  `ai-tools` package rather than downloaded.
- **At launch time**, against a **pin**: a small root-owned file recording the checksum that was
  verified. The launch does not perform network I/O and does not read a key — it hashes the binary and compares.

If the binary changes after it was verified, the next launch refuses. That is the whole point: it
catches tampering that **persists** — modify the binary once, and every future session for every
operator would otherwise run it silently.

You do not maintain any of this by hand. There is no per-release step.

## The flow

```
  ┌─ update ────────────────────────────────────────────────────────────────────┐
  │                                                                             │
  │   nvm-update  (runs as the sandbox account, daily)                          │
  │        │                                                                    │
  │        │  npm install -g @anthropic-ai/claude-code   →  2.1.240 installed   │
  │        ▼                                                                    │
  │   ①  verify BEFORE activating                                               │
  │        fetch  downloads.claude.ai/.../2.1.240/manifest.json{,.sig}          │
  │        gpgv   against the SHIPPED key   (never a downloaded one)            │
  │        sha256 the new entrypoint, compare to the signed checksum            │
  │                                                                             │
  │        ✓ match      → continue                                              │
  │        ✗ MISMATCH   → stop. 2.1.233 stays active and pinned.                │
  │        ? can't tell → continue anyway, unpinned  (offline / no manifest)     │
  │                       …unless AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=yes         │
  │        ▼                                                                    │
  │   ②  repoint  /opt/ai-tools/bin/claude → 2.1.240   (via a root helper)      │
  │        ▼                                                                    │
  └────────┼────────────────────────────────────────────────────────────────────┘
           │  the bin directory changed
           ▼
     ai-tools-relabel.path      ← a systemd watcher, already enabled
           ▼
  ┌─ reconcile (root) ──────────────────────────────────────────────────────────┐
  │   ai-tools-relabel-agent                                                    │
  │        ③  verify again, and WRITE THE PIN                                   │
  │              /var/opt/ai-tools/state/entrypoint-pin.d/claude-code           │
  │              VERSION=2.1.240  SHA256=…                                      │
  │        ④  relabel the entrypoint → ai_tools_exec_t   (SELinux hosts only)   │
  └─────────────────────────────────────────────────────────────────────────────┘
           │
           ▼
  ┌─ launch ────────────────────────────────────────────────────────────────────┐
  │   claude  →  ai-tools-run                                                   │
  │        ⑤  sha256 the entrypoint, compare to the pin                         │
  │              match     → start the session                                  │
  │              MISMATCH  → REFUSE                                             │
  │              no pin    → start (or refuse, if you required verification)    │
  │           no network, no key, no vendor — just a hash and a compare         │
  └─────────────────────────────────────────────────────────────────────────────┘
```

## Two things, two lifetimes

The most common question is whether the signing-key fingerprint has to be updated per release. It
does not — it identifies the **signer**, not the release.

| | what it is | where it lives | changes when | who updates it |
|---|---|---|---|---|
| the key + fingerprint | who is allowed to sign a release | the `ai-tools` **package** (`0644 root:root`, not a config file) | the vendor rotates its signing key — years, not releases | a signed package update (`dnf update`) |
| the pin | what *this* installed binary hashes to | `/var/opt/ai-tools/state/entrypoint-pin.d/<agent>` | every agent update | root, automatically, via the watcher above |

One key signs every Claude Code release. So the static half does not need maintenance, and the
per-version half is derived automatically.

**A key rotation is not an outage.** Until the package carrying the new key reaches your host,
verification reports *cannot verify* — never *tamper* — and says so, naming `dnf update` as the fix.
During a rotation the package ships both keys and declares both fingerprints, so there is no window
where neither works.

## What you might have to do

| you see | it means | do |
|---|---|---|
| no output | the normal case | no action |
| `entrypoint verified … and pinned` after an update | working as intended | no action |
| `could not verify … pin unchanged` | the host could not reach the vendor, or no manifest exists for that release | no action; it re-verifies on the next update. If it persists, check egress to `downloads.claude.ai` |
| `signed by a key the pinned keyring does not hold` | the vendor rotated its signing key | `sudo dnf update 'ai-tools-agents-*'` |
| a launch refused: `does not match the checksum its vendor signed` | **the binary changed after it was verified** | treat the toolchain as tampered: `sudo ai-tools-bootstrap`, and investigate if it recurs |
| a launch refused: `carries no verified checksum` | you set `AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=yes` and this entrypoint was never pinned | `ai-tools --relabel` (needs the host online) |

`ai-tools --relabel` reconciles the entrypoint: it verifies and pins it, then fixes its SELinux
label. Both are answers to "the toolchain changed"; it is the same command you already run when a
Node upgrade leaves the entrypoint mislabelled.

## Strictness

By default a **mismatch** always refuses the launch, and an **unpinned** entrypoint launches
normally. Unpinned is not a suspicious state — it is also what you get on an air-gapped host, on one
whose vendor never published a manifest for the installed release, and on one that has not run a
reconcile yet. Refusing there would block untampered binaries.

To require verification, in `/etc/ai-tools/operator.conf`:

```
AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=yes
```

Then only a verified entrypoint starts a session, and the updater additionally declines to activate
a release it could not verify — so an unverifiable release never becomes the one your launches would
have to refuse. This is the same shape as `AI_TOOLS_REQUIRE_SELINUX`: the tool cannot tell an
intentionally offline host from a degraded one, so you declare it.

## Air-gapped and mirrored hosts

Nothing here requires reaching the vendor:

- The verification **fails soft**. No route to `downloads.claude.ai` means *cannot verify*, which
  warns and continues. Connection attempts are short-timeout, so an offline host is not made slow.
- Installing the RPM offline works. The package's `%post` reconciles the entrypoint and the
  verification step simply reports that it could not check.
- A host with an **internal npm mirror but no vendor access** keeps updating its agent normally; the
  entrypoint is just left unpinned. Setting `AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY=yes` on such a host
  will freeze the agent at its last verified release — which is the point of setting it, but worth
  knowing before you do.

## What this does and does not protect against

**Does:** a binary modified after installation — the case npm's own integrity hash and registry
signature cannot see, because they attest to what was *delivered*, not to what is on disk now. Since
`npm install -g` does not reinstall an unchanged version, such a change would otherwise persist
across sessions and across operators indefinitely.

**Does not:**

- It **detects**, it does not prevent. On a host running the SELinux policy the vector is already
  closed outright — the agent cannot write its own entrypoint at all — so there this is drift
  detection. On a DAC-only host it is the only check there is.
- It proves the binary is a **genuine** vendor release, not the **newest** one. Rolling back to an
  older signed release still verifies.
- It does not make any claim about what the agent *does* once running. That is the sandbox's job: the confined
  account, the project allowlist, and the ownership handback.

## See also

- `operator.conf(5)` — `AI_TOOLS_REQUIRE_ENTRYPOINT_VERIFY` and the other switches
- `docs/project-lifecycle.md` — claiming projects and running sessions
- `.claude/rules/updater.rule.md` — the mechanism, for contributors
