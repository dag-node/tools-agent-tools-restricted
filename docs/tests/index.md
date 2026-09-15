# Tests

**Tests** — [all docs](../index.md)

```bash
sudo tests/run.sh unit          # hermetic: no deployed system, no live session
sudo tests/run.sh all           # every category, against this host
```

What the suite proves, what a host needs before it runs, and which category
answers which question. Run it from a repository checkout, through `sudo`:
the runner refuses a direct `root` invocation, because it resolves your
projects from `SUDO_USER`.

The categories differ in what they touch. **Unit** tests are hermetic — they
build their own fixtures, touch no real project, and need no installed stack,
which is why they are the subset a package build may run. **Integration** tests
drive the real commands against a deployed system with at least one enrolled
operator and a live user session. **Boundary** tests run *as the sandbox
account* and assert that the state each refusal exists to catch is unreachable
from there.

The last pair is the point. Every refusal this project guarantees is covered
twice: once by driving the helper into the state that should trigger it
and asserting it moves to less access, and once from inside the sandbox,
asserting that the state is unreachable to begin with. A host someone has
already broken is caught by the first; an agent trying to break it is caught
by the second.

The deployment under test may come from `dnf` — a from-source install is not
required, and the suite is run on demand rather than by any package scriptlet.
