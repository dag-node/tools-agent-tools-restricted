// SPDX-FileCopyrightText: 2026 Ondřej Nedomlel <tools@dagnode.com>
// SPDX-License-Identifier: MIT
// src/help.mts
// The command's help text, kept apart from the command so the words an operator reads are edited without touching
// argument parsing. It is printed for `--help` alone: a refusal prints one line and names `--help`, so a caller
// reading stderr for the failure class gets that line and not a screen of options it did not ask for.
//
// The option list and the exit statuses here restate what decide.mts implements; a flag added there is added here.
//
// VERSION is what `--version` prints and is this project's release, hand-maintained beside package.json rather than
// injected at build time: dist/ is exactly tsc's output from src/, so a rebuild from a tag reproduces it byte for
// byte, and a build step that rewrote a file would end that. The suite holds the two to each other, so a release
// cannot ship a version that disagrees with its own manifest.
export const VERSION = "0.1.2";
export const USAGE = `usage: <listing> | node decide.mjs filter --task "<one sentence>" --config <file> [--format lines|prose-check|msbuild] [--threshold 0.5] [--usage-log <file>]
  filter       keep the lines that bear on the task; the rest are listed by id on the summary line
  --config     the KEY=value file holding the API key, the endpoint and the tuned values. Required
  --format     lines (default), prose-check, or msbuild (a build log's diagnostics; the rest set aside)
  --threshold  the least P(true) that keeps an item, overriding the file's
  --usage-log  a file to append one JSON line of counts to; without it nothing is written
  -v, --version  print the client version and exit
  triage       deferred -- not dispatched in this release
exit: 0 result, 2 input, 3 configuration, 4 provider, 5 contract, 6 deadline, 1 unexpected`;
