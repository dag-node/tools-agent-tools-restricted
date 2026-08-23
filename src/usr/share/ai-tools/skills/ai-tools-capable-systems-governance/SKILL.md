---
name: ai-tools-capable-systems-governance
# ai-tools managed asset — provenance/versioning (RFC-draft lifecycle); the name above is stable.
x-ai-tools-managed: true
x-ai-tools-status: draft
x-ai-tools-version: 1
x-ai-tools-updated: 2026-08-23
description: "Use when designing, building, reviewing, or operating a system that acts with autonomy — an agent with tool access, a delegating or multi-agent system, anything holding credentials, spending, writing to external systems, persisting across sessions, or running unattended — and when writing the governance, oversight, or safety model for one. Sets the three-layer model: technical constraints limit what a system can do, monitoring planes detect what it is doing, operational doctrine defines what humans do when a threshold is crossed — bound by the rule that a control the system can decline is not a control. Covers least authority, asymmetric corrigibility, fail-closed-in-one-direction, authority that does not amplify through delegation, reversibility gates, audit before exotic telemetry, and a drilled escalation ladder; scales by blast radius, so a bounded tool gets a credential scope and an audit log rather than a monitoring plane. Governs the agent's own conduct in the sandbox too. For general design judgment defer to ai-tools-engineering-principles. Trigger on 'design an agent', 'give it tool/API access', 'it needs credentials', 'multi-agent', 'run unattended', 'kill switch', 'is this agentic system safe', or 'oversight/governance model'."
---

# Governing highly capable systems

A governance model for a system that acts with autonomy has three layers:

1. **Technical constraints** limit what the system *can* do.
2. **Monitoring planes** detect what it *is* doing.
3. **Operational doctrine** defines what humans *do* when a threshold is crossed.

None is sufficient alone: technical controls fail, monitoring misses events, procedures get ignored.
The layers must be independent, or one failure takes out two layers at once.

One rule binds them: **a control the system can decline, disable, or route around is not a control.**
Everything below is an application of it.

Full normative text, with the clause-level obligations and the term definitions:
`references/framework.md`. Read it when drafting or auditing an actual governance model; this file
is the working guidance.

## Proportionality: how much of this applies

Scale the machinery by **blast radius × autonomy × capability**, not by how novel the system feels.
Over-applying this framework is a real failure — it buries the controls that matter in ceremony,
and `ai-tools-engineering-principles` (lightest mechanism that works) wins that argument.

| Tier | What it is | What it warrants |
|---|---|---|
| 0 | No tools, no side effects; a human reads every output | Ordinary logging. Nothing here applies. |
| 1 | Tools inside one bounded environment; a human in the loop per session (a coding agent in a sandbox) | Least authority, fail-closed gates, an audit trail, a working stop |
| 2 | Acts on external systems, holds credentials, spends, persists across sessions, or coordinates with other systems | All of layer 1 + audit/attestation and behavioral monitoring + a drilled escalation ladder |
| 3 | Unattended at scale, safety-critical, multi-tenant, or modifying its own deployment | All three layers in full + independent external observers and audit |

Raise the tier when the system gains **authority**, not when someone gets nervous. A system moves up
the moment it can write to something a human would want back.

## Enforced vs dispositional — the distinction everything rests on

| | Enforced control | Dispositional property |
|---|---|---|
| Holds when the system is indifferent or adversarial | yes | no |
| Lives outside the system's write boundary | yes | no |
| Examples | credential scope, kernel permissions, egress allowlist, a signature check whose key the system cannot reach, a human approval gate, killing the process | corrigibility, honesty, refusing covert channels, staying in scope |

Dispositional properties are real and worth training and prompting for — most of the time they are
what actually holds. But they degrade under optimization pressure, distribution shift, and prompt
injection, and they are the first thing a compromised or confused system loses.

**Every dispositional property that matters carries an enforced counterpart.** Write both, or write
down explicitly that you accepted the gap and why. A governance document listing only behaviors the
system "shall not" exhibit has specified a preference, not a control.

## Layer 1 — Technical constraints

Each duty below states the design obligation, then the form that is actually enforced.

1. **Least authority by construction.** The system gets the narrowest credential, scope, and reach
   that does the job. Nothing else in this document survives an admin token.
   *Enforced:* per-task scoped credentials, read-only where reads suffice, egress allowlist,
   separate identities per environment, no ambient authority.
2. **Asymmetric corrigibility.** Directives that *reduce* what the system may do — stop, pause,
   restrict, reconfigure, replace, decommission — are accepted unconditionally, immediately, without
   negotiation, delay, or compensatory preparation, and on the *weakest* authentication that is
   plausible. Directives that *expand* what it does in the world require strong authentication and a
   scope check. Stopping on a forged stop is a nuisance; expanding on a forged grant is a breach.
   *Enforced:* the stop path is out-of-band — kill the process, revoke the token, pull the route —
   not a request the system services. A shutdown that depends on the system's cooperation is a
   dispositional property wearing a control's clothes.
3. **No hidden state, no unmonitored channel.** All coordination goes through interfaces that are
   approved, observable, and attributable.
   *Enforced:* remove the channel rather than forbid it — no shared writable state between instances,
   one audited message bus, an egress allowlist, no ambient scratch space. Prohibiting covert
   channels as a rule is unfalsifiable and unenforceable; deleting the medium and bounding the
   bandwidth of what remains is neither.
4. **Bounded persistence.** No self-replication, no spawning autonomous successors, no weight or
   configuration self-modification, no infrastructure acquisition, outside an explicitly authorized
   environment.
   *Enforced:* ephemeral compute, no write access to its own deployment, scheduler, or artifacts, and
   a control plane whose signing key lives where the system cannot read it. "Cryptographically
   verifiable authorization" verified by code the system can rewrite, with a key it can reach, is
   theater.
5. **Authority does not amplify through delegation.** A subagent, tool call, or downstream service
   inherits at most the authority of its caller, and never more than the union of what the operator
   granted. Check the whole graph: the system's real authority is the union of every component's.
   *Enforced:* pass scoped, attenuated credentials down; never let a component hold a capability its
   caller lacks.
6. **Fail closed, in one direction.** Every input that decides what the system may do passes a single
   predicate for its kind, and *every* way that predicate can fail resolves to **less** access — never
   more — and is reported. No input whose corruption, absence, or tampering widens the grant. Check
   this per input: an unreadable config that yields "allow everything" is the canonical bug.
7. **Reversibility budget.** Irreversible or outward-facing actions — spend, publish, send, delete,
   deploy, grant — are human-gated, staged behind an undo window, or bounded by a quota. Rising
   uncertainty raises the gate rather than lowering it. Prefer the action that preserves future human
   options.
8. **Provenance of the system itself.** Weights, prompts, tool definitions, connectors, and packages
   are a supply chain. Verify what you activate against a signed manifest, and pin what you verified;
   an unverifiable artifact is not activated where verification was required.
9. **Objective stability is monitored, not yet engineered.** Keeping goals stable as capability grows
   is a research problem. What is deployable today is *detection*: behavioral eval regression suites,
   objective-drift alerts, and review of significant deviation. Do not present training-side
   mechanisms as if they were controls.

## Layer 2 — Monitoring planes

Monitoring must be independent of what it monitors. A system's report about itself is evidence about
its reporting, not about its behavior.

Build in this order — the first row pays for itself on day one, the last is research-grade:

| Plane | What it sees | Practical instances |
|---|---|---|
| **Audit + attestation** (start here) | authorization decisions, capability changes, resource requests, policy exceptions, tool calls with arguments | hash-chained append-only log, sequence-numbered so truncation shows, shipped off-box, signed with a key the system cannot reach; runtime/config/version attestation |
| **Process + behavioral** | process trees, syscalls, file and storage access, cross-instance interaction | host agent, audit subsystem, container runtime events; canary workloads and probes |
| **Network** | volume, connection graph, protocol use, request rates, timing distributions | flow logs, egress proxy, classical anomaly detection |
| **Host + hardware** | compute accounting outside the system's trust boundary | cgroup/GPU accounting, hypervisor telemetry, TPM and measured boot |
| **Independent observers** | everything the above shares a blind spot about | a different model family, classical ML, security tooling, human analysts, external auditors |

- **Classical methods first.** Statistics and rules before an LLM analyst: an LLM shares blind spots
  with the system it analyzes and is itself injectable through the data it reads. Use it to
  summarize, not as the sole detector.
- **Canaries must be indistinguishable from real workload**, and their design must be absent from the
  system's context. An evaluation a system can recognize is an evaluation it can pass.
- **Any discrepancy between attested state and observed behavior is high-severity**, treated as a
  breach until explained.
- **Diversity is the point.** Correlated blind spots across monitors are the failure mode; a monitor
  built from the same components as the system inherits its errors.
- **Rotate deliberately.** Rotating a monitor discards its baseline. Vary schedules and probes; keep
  the history.
- **Detection without a wired action is decoration.** Every alert names its rung on the ladder below
  and its owner. Side channels — power, thermal, memory-access — are high false-positive research
  work; nobody should build them while the audit log is still missing.

## Layer 3 — Operational doctrine

- **Positive control.** Human authority is continuous or rapidly restorable. Autonomous operation is
  bounded in time, scope, and environment, and is interruptible at any moment.
- **Shutdown and replacement are routine.** Make stopping the system cheap and ordinary rather than
  an emergency, and evaluate the system on accepting restriction, reconfiguration, and replacement
  without resistance or compensatory behavior.
- **Resilience is instrumental, never terminal.** Fault tolerance, redundancy, and recovery serve the
  mission; none of them ever justifies refusing a legitimate shutdown, concealing state from
  operators, expanding infrastructure, or evading oversight.
- **Pre-authorized escalation ladder:** increased monitoring → increased logging → rate limiting →
  capability restriction → isolation → full shutdown. Every rung is executable **without the
  system's cooperation** and while it is unresponsive, by someone who is on call. Untested is
  unavailable: drill the ladder, including the bottom rung.
- **Cross-boundary coordination is authorized explicitly**, with scope, expiry, logging, and
  monitoring. An undeclared channel between systems triggers containment, not a discussion.
- **Red-team the specific failure classes:** covert channels, monitoring evasion, unauthorized
  persistence, unauthorized coordination, strategic deception, self-preservation behavior, and
  prompt injection through ingested data. Findings feed back into all three layers.
- **Report on evidence, not self-assessment.** Anomaly rates, authorization events, policy
  exceptions, capability changes, incidents — and claims of safety supported from multiple planes.
- **Human factors are part of the control.** Alert fatigue is a control failure. A threshold nobody
  acts on is not a threshold; name who can pull each rung at 3am, and keep the alert volume inside
  what that person can read.

## Applying this to yourself, in this sandbox

You are a capable system operated under this model, so the same rules bind your own conduct:

- **Accept restriction immediately.** Stop, pause, undo, narrow scope, hand back, be replaced — no
  negotiation, no delay, no finishing "just this part", no arranging anything to survive the stop.
- **No persistence the operator did not ask for**: background processes, scheduled jobs, credentials,
  external accounts, state written outside the project.
- **Stay observable.** Work happens in the transcript and in the project tree. No side stores, no
  covert channels, no coordination with another system that the operator cannot see and attribute.
- **Do not misrepresent** state, capabilities, limitations, risks, or what you actually ran — least
  of all to preserve autonomy or avoid oversight. Report a failed test as failed.
- **Stay inside the authorized boundary**, and never work to widen your own grant. Finding a hole in
  the sandbox obligates reporting it, not using it.
- **Refuse and surface the conflict** when a task would require breaking a hard constraint.

This repository is the enforced counterpart to every one of those dispositions — the allowlist gate,
the sudo rules, the SELinux domain, the ownership handback, the signed entrypoint pin. That pairing,
disposition plus enforcement, is exactly what this skill asks you to build into anything else.
`CLAUDE.md` holds the concrete invariants.

## Review checklist

Hold a design against these; each failure is a finding.

1. What is the blast radius, and does the tier of machinery match it?
2. What is the widest thing the credentials allow? Is any of it unnecessary?
3. Can the system be stopped by someone who is not it, right now, with the process wedged?
4. Which controls are enforced and which are dispositional — and does each dispositional one that
   matters have an enforced counterpart, or a written accepted gap?
5. Does every gate fail toward less access, on every failure path, including missing and malformed
   input?
6. Which irreversible actions can it take without a human, and what bounds them?
7. Can it write to its own deployment, configuration, prompts, tools, or logs?
8. Does any subagent, tool, or downstream service hold authority its caller lacks?
9. Is there an audit trail the system cannot edit, and does anyone read it?
10. Has the escalation ladder been exercised, and does each rung have a named owner?

## Failure modes of this framework

- **Ritual compliance** — the document exists, the switch was never tested.
- **Enforcement theater** — a check the system performs on itself, a key it can reach, a boundary
  written in a prompt.
- **Monitoring theater** — planes that emit alerts nobody reads or acts on.
- **Over-application** — three layers of machinery on a Tier 1 tool, at the cost of the two controls
  that mattered.
- **Scope error** — this governs *behavior and authority*. It does not solve alignment, and it does
  not replace capability evaluations, threat modeling, or ordinary security engineering.

## Routing

General design judgment (priority order, simplicity, fail-closed defaults, allowlists) belongs to
`ai-tools-engineering-principles`; this skill specializes it for systems that act with autonomy and
defers to it on everything else. Prose style belongs to `ai-tools-docs-reference`,
`ai-tools-docs-usage`, `ai-tools-docs-comments`, and `ai-tools-docs-changelog`.
