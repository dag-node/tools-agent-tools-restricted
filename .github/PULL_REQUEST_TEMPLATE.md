## What and why

<!-- What changes, and the reasoning. For anything touching confinement, sudoers,
     the handback bridge, ownership, or secrets, state how the security invariants
     (CLAUDE.md, "Security model") are preserved. -->

## Checklist

- [ ] Branched from `develop` (`feature/<ticket-num>-<feature-name>`), PR targets `develop`
- [ ] `sudo tests/run.sh all` passes (state which categories, and whether the host is SELinux-enforcing)
- [ ] ShellCheck baseline clean: `find src -name '*.sh' -print0 | xargs -0 shellcheck && shellcheck install.sh`
- [ ] Rule files (`.claude/rules/*.rule.md`) updated in step with any behavior they document
