# Security policy

Agent Tools Restricted is a confinement tool: its purpose is to keep
an autonomous coding agent inside a defined trust boundary. A hole
in that boundary is the most serious class of bug this project can have,
and reports of one are taken accordingly.

## Supported versions

Only the latest tagged release is supported for security updates. Earlier
versions do not receive backported fixes.

## Reporting a vulnerability

Please report suspected vulnerabilities privately:

* [GitHub private vulnerability
  reporting](https://github.com/dag-node/tools-agent-tools-restricted/security/advisories/new).
* Alternatively, email **[tools@dagnode.com](mailto:tools@dagnode.com)**
  with the subject prefix `[SECURITY]`.

Do not include vulnerability details in public issues or pull requests.

Include the affected version, operating system, SELinux status, reproduction
steps, and potential impact where available. A proof of concept is helpful
but not required. Remove credentials and other sensitive data from logs
before sharing them.

Reports of failures in the project's security boundaries are welcome. See
[Project scope](docs/about/scope.md) for documented limitations. If you are
unsure whether a finding is a vulnerability, report it privately.

## Handling and disclosure

Security reports are reviewed and prioritized according to their potential
impact. Response and remediation times depend on maintainer availability
and the complexity of the issue; no fixed timeframes are guaranteed.

Please coordinate public disclosure with the maintainer so that users can
receive a fix or mitigation where possible.
