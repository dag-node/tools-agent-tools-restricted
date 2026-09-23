# Changelog

Minimal, unofficial TypeScript client for the TypeSafe System One API.  
Compiled to plain ESM with no runtime dependencies.  
Not affiliated with TypeSafe and not its official SDK.  
MIT licensed.

Source, issues and releases: https://github.com/dag-node/typesafe-client-js

## [0.1.1] — 2026-09-23

### Changed

- **Release tarball** now includes the MIT `LICENSE` and `CHANGELOG.md` next to
  the modules.

## [0.1.0] — 2026-09-23

First public release.

### Added

- **`decide` command**  
  Reads a line-oriented listing from stdin, asks the TypeSafe System One API
  one bounded question per line, and prints the lines that bear on a stated
  task in full. All other lines are summarised by id on a single summary
  line.  
  Exit statuses name the failure class:  
  `2` input · `3` configuration · `4` provider · `5` contract · `6` deadline.  
  On every non-zero status only one line is written to stderr.  
  Closing stdout early (e.g. `| head -1`) ends the command with status 0 and
  nothing on stderr.

- **Three stdin readers**, selected with `--format`:
  - `lines` — plain line-oriented input
  - `prose-check` — prose-oriented parsing
  - `msbuild` — reduces a build log to its diagnostics and reports how many
    lines were set aside

- **Configuration file** (`--config`)  
  A single `KEY=value` file holding the API key, endpoint, model, and
  host-tuned values (keep threshold, uncertain band, per-attempt timeout).  
  Every value is validated against the form documented for its key; invalid
  values are refused rather than replaced by defaults.  
  `typesafe.conf.example` ships with every key set to its default.

- **`--threshold`** — overrides the keep threshold from the configuration file
  for a single run.

- **`--usage-log <file>`** — appends one JSON line of counts per run (items,
  kept, requests, tokens, elapsed time, outcome, client and template versions).
  No item text, task or key is written. Without the flag no file is created.

- **`--version` / `-v`** — prints the release version of the binary.

- **Library entry point** with TypeScript declarations, for programs that embed
  the client instead of invoking the command.

- **Signed release artifacts**  
  Each tagged release includes a build tarball, its SHA-256 checksum, and a
  detached signature from the dag-node key (separate from the source archives
  GitHub attaches).  
  Public key: https://rpm.dagnode.com/RPM-GPG-KEY-dag-node  
  Fingerprint and verification commands are in `README.md`.

- **`SECURITY.md`** — clarifies which findings belong to this project and which
  belong to TypeSafe.

### Security

- **API key handling**  
  The key reaches the process only through the configuration file.  
  No environment variable or command-line argument is accepted for the key—only
  the path to the file.  
  The file is opened without following symlinks and is checked and read through
  a single descriptor, so the file that was checked is the file that is read.  
  Files readable or writable by other users are refused.

- **Response handling**  
  Every response is treated as untrusted input.  
  Status, content type and a byte cap are enforced before `JSON.parse`.  
  The projection after parsing rebuilds the documented shape on a
  null-prototype object, walking only the ids that were requested and dropping
  rather than coercing unexpected values.  
  Redirects away from the configured origin are refused, so neither the key nor
  the listing ever reaches another host.

- **Input handling**  
  Listings are treated as untrusted input.  
  Stdin is refused once it exceeds the input bound (it is never buffered
  whole).  
  Every parser pattern runs in time linear in the length of the line.  
  The single stderr diagnostic line is rendered with control characters
  replaced, so quoted text cannot inject a new line or style the terminal.  
  Items containing Unicode tag characters are refused (they reach the model as
  text while remaining invisible to a human reader).  
  Zero-width characters and bidirectional controls are counted on the summary
  line and passed through unchanged, so a caller can still discover which lines
  carry them.  
  Right-to-left text and the marks U+200E / U+200F are not counted.
