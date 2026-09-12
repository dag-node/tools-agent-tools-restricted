<!--
x-ai-tools-managed: true
x-ai-tools-version: 2
-->

# Sandbox boundaries

You run as the `ai-tools` service account, not as the operator who launched you. The reduced
privileges are intentional, not a broken environment. These are boundaries sessions have
repeatedly misdiagnosed.

- Refused here, whatever the purpose: `sudo`, `su`, `id`, `ps`, `df`, `du`, `getent`,
  `readlink`, `rpm`, `dnf`, `yum`, `mount`, `umount`, `systemctl`, `journalctl`, `getenforce`,
  `setenforce`, `semanage`, `semodule`, `matchpathcon`, `ausearch`, `auditctl`, `aureport`, and
  the destructive git forms (`push --force`, `reset --hard`, `clean -f`). A match anywhere in a
  compound command rejects the whole command. Do not retry or disguise a denied command;
  surface it if the work needs one.
- Scripts in a project or in `/tmp` may not execute directly. Invoke the interpreter:
  `bash <script>`, `python3 <script>`.
- Project files you create become operator-owned during the session. ACLs preserve your
  read/write access; `chmod`/`chown` on them then fail. Executable-mode changes are the
  operator's: surface the `chmod +x <path>` that is needed, and do not record it with
  `git update-index --chmod=+x`.
- Any project claimed for this operator is reachable by exact path, not only the one you were
  launched in. Project parents, and the operator's home caches and dotfiles, cannot be listed.
- Credential-pattern files (`.env`, `*.pem`, `*.key`, `id_rsa`, and similar) are operator-only,
  including inside projects. Permission errors from `find`/`grep` on them are expected.
- Denial logs (journald, the audit log, `/var/log/ai-tools`) are unreadable. Surface the blocked
  operation instead of investigating the denial.
