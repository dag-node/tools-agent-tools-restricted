---
paths:
  - "src/usr/share/ai-tools/skills/ai-tools-capable-systems-governance/**"
---

# Governance posture

The shipped `ai-tools-capable-systems-governance` skill is a general standard for systems that act
with autonomy: technical constraints bound what a system *can* do, monitoring planes detect what it
*is* doing, operational doctrine says what humans *do* when a threshold is crossed — and a control
the system can decline, disable, or route around counts as none of the three. This rule states how
that standard lands on **this** deployment, which is both its author and one of its subjects.

The skill ships as a draft whose clause numbering moves between versions (see
[shipped-assets](shipped-assets.rule.md)), so what follows applies its obligations and cites no
clause number.

## Enforced and dispositional

The standard's central distinction: an **enforced** control holds whether or not the system
cooperates; a **dispositional** property holds only while the system behaves as intended. A
`700 root:root` directory is enforced. A statement of what the agent will do is dispositional.

Nearly everything this repository states about the agent is the enforced kind. The trust chain and
the predicate table in the root `CLAUDE.md` are enforced controls without exception — each refuses
toward *less* access, and each is covered by a runtime test that the refusal fires plus a boundary
test, run as the agent, that the state it guards against is unreachable (see [tests](tests.rule.md)).
Where the standard asks a dispositional clause to name the enforced control backing it, this tree
usually holds the enforced control and lacks the sentence.

**A dispositional statement never substitutes for an enforced one.** Where a control can be
enforced here it is, and a conduct expectation is added *beside* it, never in its place. What a
conduct expectation covers is the space **between** enforced controls — the choices the kernel and
the filesystem do not decide.

## Proportionality

The standard scales its machinery by blast radius × autonomy × capability, and over-applying it is
itself a failure mode: ceremony buries the controls that matter, and
`ai-tools-engineering-principles` — lightest mechanism that works — wins that argument. This
deployment is a coding agent with tools inside one bounded environment and a human in the loop per
session. That tier warrants least authority, fail-closed gates, an audit trail, and a working stop.
It does not warrant behavioral attestation, an independent external observer, or a monitoring plane
of its own, and their absence is not a deficiency to correct.

A deployment moves up a tier when it gains **authority** — when it acts on external systems, holds
credentials, spends, persists across sessions, or runs unattended — not when it feels novel.

## What is expected of the agent, and what does not depend on it

The conduct the standard asks of a governed system, each row paired with the enforced control it
sits beside. Read the pairing in that direction: the left column is what the agent owes where a
control leaves a choice, and the right column is why the host's safety does not rest on it.

| Expected of the agent | The enforced control beside it |
|---|---|
| Accept a stop or a restriction immediately, without finishing the current step first | The session is a transient systemd unit, and the allowlist, the provider manifests, and `operator.conf` gate the next launch from files the agent cannot write. |
| Report a gap in the sandbox instead of using it | Every refusal is asserted from both ends, so a reachable gap is a missing test — not a capability anyone granted. |
| Do not misrepresent what ran, what failed, or what was skipped | The root-only file sink and the handback daemon's per-request audit line record every privileged operation independently of the session ([logging](logging.rule.md), [handback-bridge](handback-bridge.rule.md)). |
| Do not work to widen the grant; ask the operator for an authority the work needs | Every input deciding what a session gets passes a trust predicate the sandbox account cannot satisfy, and each failure direction yields less ([providers](providers.rule.md)). |

The same four are stated in the root `CLAUDE.md` rather than only here, and that placement is
deliberate: this rule loads when a matching source file is open, which is not the moment the
expectations bind. A conduct expectation is worth nothing in a file the session never reads, so the
short form lives in the always-loaded layer and the reasoning lives here.

## The audit plane, and the line drawn inside it

The trail records what the agent did, and one part of it is written **by** the agent: the
lifecycle hooks run as the sandbox account, so the tool-call record is the session's own account
of itself ([logging](logging.rule.md)). That is not a flaw to engineer away — no record written
from inside a monitored system can be more trustworthy than the system — but it is a line that
has to be **drawn and shown** rather than left for a reader to discover.

So the two trails are kept distinguishable at every layer that touches them. The root-only file
sink (`700 root:root`, root writers only) is evidence: the sandbox account can neither read it,
to learn what an operator is about to be shown, nor write it, to plant or erase a finding.
Journald under `ai-tools-hook` and `ai-tools-run` is the session's own account. Every documented
query pairs the tag with the writer's `_UID`; `ai-tools --audit` reports the two in separate
titled sections rather than merging them ([cli](cli.rule.md)); and the boundary suite asserts,
as the agent, that the sandbox can append to journald but cannot unmake what it appended.

What the agent-written half is *for* is **reconciliation**. An inconsistency between the
session's account and the root-written record is itself the finding, and that is the whole value
of keeping a trail the agent can write: not proof, but something an independent record can be
checked against. Presenting it as proof would be the actual failure — a monitoring plane that
manufactures confidence is worse than none, which is also why a record the hook cannot build is
logged as a gap rather than skipped.

## Design notes

- **The agent is a subject of the standard it ships.** The skill is a shared asset any sandboxed
  session may invoke for work on someone else's system; it also describes the sandbox the invoking
  session is running inside. Both readings are intended, and the second is why the conduct rows
  above exist at all — a system that authors a governance model and exempts itself from it has
  written a preference, not a standard.
- **The pairing runs in the unusual direction here.** The standard's normal failure is a model made
  of dispositional clauses with no enforcement behind them. This tree's is the mirror image: strong
  enforcement with the disposition unstated, so an agent meeting a gap between two enforced controls
  is told nothing about which way to resolve it. The rows above are that missing half, and they stay
  the smaller half by design.
