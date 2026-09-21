# Lock secrets away

[Projects](index.md) · [Permissions](permissions.md) · **Lockdown** — [all
docs](../index.md)

How a secret-named file is kept out of the agent's reach, when the scan
that finds one runs on its own, and what the pattern set can and cannot
recognize.

```bash
ai-tools projects lockdown ~/src/api   # scan for secret-named files and lock what it finds
```

## A secret-named file is locked, not shared

A file whose name matches a known secret pattern — `.env`, `*.key`, `*.pem`,
SSH private keys, `kubeconfig`, and the rest of the shipped set — is treated
apart from every other file in a claimed tree. Where the agent writes one,
the hand-back locks it to you alone rather than restoring it to the shared
ownership every other file gets ([Permissions](permissions.md)), which removes
the sandbox account's read on it; the session and the operation log each get
a `NOTICE` saying so.

The same scan runs **before** a claim grants anything, and declining it stops
the claim, so access is never granted over exposed secrets. `projects lockdown`
runs it on demand — after adding a credential file to a claimed tree,
or before re-running a claim that stopped. `--dry-run` names every path it
would act on and applies none of them.

## What the patterns do not cover

Matching is on **names**, not contents, and the shipped list is a baseline
of the credential names software writes in general. A secret under a name
the list does not know about is yours to handle first: make it owner-only,
which a claim then leaves alone, or `!`-exclude it from your allowlist,
which every walk skips whatever its mode ([Permissions](permissions.md)).

Your own list lives at `~/.config/ai-tools/secret-patterns` and **replaces**
the baseline rather than adding to it — so a file written once holds this host
to the set it named then. Each launch records the difference to journald,
naming the baseline patterns your file drops. The file's grammar and the full
baseline are in `man 5 ai-tools-secret-patterns`.

## Git history is a separate exposure

A credential committed years ago and since removed is invisible in the working
tree and one `git show` away for anything that can read `.git`, which is
what a claim's `.git` prompt and the shallow clone answer — see [Choose a model
first](index.md#choose-a-model-first).
