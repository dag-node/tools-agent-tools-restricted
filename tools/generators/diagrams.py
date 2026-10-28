#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# tools/generators/diagrams.py -- generate the SVG diagrams under docs/static/diagrams/.
# Each diagram is drawn once by its layout function and written twice, as <name>-light.svg and <name>-dark.svg, so
# the two themes cannot drift apart. A page embeds the pair through <picture> with a prefers-color-scheme source, and
# its <img alt> states the diagram's claims in prose, so the alt text changes with a label.
#
#     python3 tools/generators/diagrams.py generate   rewrite every SVG from the layouts
#     python3 tools/generators/diagrams.py stale      exit 1 when a committed SVG differs from its layout,
#                                                     or when no layout draws an SVG in that directory
#
# Standard library only. The output is deterministic, so a diff shows what a layout change moved.
import sys
from pathlib import Path
from xml.sax.saxutils import escape

OUT = Path(__file__).resolve().parents[2] / "docs" / "static" / "diagrams"

# A colour key names whose a thing is, and means the same on every diagram; a new layout picks a key by this meaning.
#   operator       you, the operator: your account, the ai-ops group, the files you write
#   operator_soft  an operator without a general sudo grant
#   sandbox        the sandbox account ai-tools, and the coding agent running as it
#   project        the claimed tree you and the coding agent share, and the access you both hold on it
#   root           root, and what stays out of the coding agent's reach: secret-named files, owner-only paths
#   group          your own primary group
#   external       a party outside the host that the host reads from
#   egress         what leaves the host
#   danger         a refusal or a stop: the sandbox account in ai-ops, ending every sandbox session
# The other keys are the neutral text, line and surface colours.
THEMES = {
    "light": dict(
        fg="#1f2328", muted="#59636e", line="#59636e", card="#ffffff", halo="#ffffff",
        zone_opacity="0.07", border="#d1d9e0",
        operator="#0969da", root="#bc4c00", sandbox="#8250df", project="#1a7f37",
        external="#59636e", egress="#cf222e",
        operator_soft="#218bff", group="#9a6700", danger="#a40e26",
    ),
    "dark": dict(
        fg="#f0f6fc", muted="#9198a1", line="#9198a1", card="#151b23", halo="#0d1117",
        zone_opacity="0.12", border="#3d444d",
        operator="#4493f8", root="#f0883e", sandbox="#ab7df8", project="#3fb950",
        external="#9198a1", egress="#f85149",
        operator_soft="#79c0ff", group="#d29922", danger="#ff7b72",
    ),
}

SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', monospace"


def spans(line):
    """Returns escaped text where `backticked` segments are set in the mono face."""
    parts = line.split("`")
    return "".join(
        f'<tspan font-family="{MONO}" font-size="11.5">{escape(p)}</tspan>' if i % 2 else escape(p)
        for i, p in enumerate(parts))


def arrows(markup):
    """Sets the arrows of a mono line in the sans face, where every font draws them full width."""
    for a in ("←", "→"):
        markup = markup.replace(a, f'<tspan font-family="{SANS}">{a}</tspan>')
    return markup


class Svg:
    """Collects drawing calls; colours are theme keys resolved at render time."""

    def __init__(self, width, height, title, desc):
        self.w, self.h, self.title, self.desc = width, height, title, desc
        self.ops = []

    # Each op is a function of the theme palette returning markup.
    def _add(self, fn):
        self.ops.append(fn)

    def zone(self, x, y, w, h, accent, title, sub=None, title_dx=14):
        """Draws a zone; title_dx moves its title and subtitle right, clear of an arrow entering at its top edge."""
        def f(t):
            s = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{t[accent]}" '
                 f'fill-opacity="{t["zone_opacity"]}" stroke="{t[accent]}" stroke-opacity="0.55"/>'
                 f'<text x="{x + title_dx}" y="{y + 22}" font-family="{SANS}" font-size="14" font-weight="600" '
                 f'fill="{t[accent]}">{escape(title)}</text>')
            if sub:
                s += (f'<text x="{x + title_dx}" y="{y + 39}" font-family="{SANS}" font-size="11.5" '
                      f'fill="{t["muted"]}">{escape(sub)}</text>')
            return s
        self._add(f)

    def box(self, x, y, w, h, accent, title, lines=(), mono_title=False, dashed=False, tag=None, mono_lines=False):
        def f(t):
            dash = ' stroke-dasharray="5 4"' if dashed else ""
            s = (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="7" fill="{t["card"]}" '
                 f'stroke="{t[accent]}" stroke-width="1.4"{dash}/>')
            s += (f'<rect x="{x}" y="{y + 7}" width="3" height="{h - 14}" rx="1.5" fill="{t[accent]}"/>')
            fam = MONO if mono_title else SANS
            s += (f'<text x="{x + 14}" y="{y + 22}" font-family="{fam}" font-size="13" font-weight="600" '
                  f'fill="{t["fg"]}">{escape(title)}</text>')
            if tag:
                s += (f'<text x="{x + w - 12}" y="{y + 21}" text-anchor="end" font-family="{MONO}" '
                      f'font-size="10.5" font-weight="600" fill="{t[accent]}">{escape(tag)}</text>')
            for i, line in enumerate(lines):
                if mono_lines:
                    s += (f'<text x="{x + 14}" y="{y + 40 + i * 15.5}" font-family="{MONO}" font-size="11" '
                          f'style="white-space:pre" fill="{t["muted"]}">{arrows(escape(line.replace("`", "")))}</text>')
                elif isinstance(line, str):
                    s += (f'<text x="{x + 14}" y="{y + 40 + i * 15.5}" font-family="{SANS}" font-size="12" '
                          f'fill="{t["muted"]}">{spans(line)}</text>')
                else:
                    # a line of (text, colour key or None, bold) segments
                    runs = "".join(f'<tspan{f" fill=\"{t[c]}\"" if c else ""}'
                                   f'{" font-weight=\"600\"" if b else ""}>{spans(text)}</tspan>'
                                   for text, c, b in line)
                    s += (f'<text x="{x + 14}" y="{y + 40 + i * 15.5}" font-family="{SANS}" font-size="12" '
                          f'fill="{t["muted"]}">{runs}</text>')
            return s
        self._add(f)

    def gear(self, cx, cy, r, accent):
        """Draws a cog of radius r: eight teeth, a body, and a hole in the card's colour."""
        def f(t):
            teeth = "".join(
                f'<rect x="{cx - r * 0.22:.2f}" y="{cy - r:.2f}" width="{r * 0.44:.2f}" height="{r * 0.5:.2f}" '
                f'rx="1" fill="{t[accent]}" transform="rotate({i * 45} {cx} {cy})"/>' for i in range(8))
            return (teeth + f'<circle cx="{cx}" cy="{cy}" r="{r * 0.72:.2f}" fill="{t[accent]}"/>'
                    f'<circle cx="{cx}" cy="{cy}" r="{r * 0.3:.2f}" fill="{t["card"]}"/>')
        self._add(f)

    def text(self, x, y, value, size=12, color="muted", weight="400", mono=False, anchor="start"):
        self._add(lambda t: (f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-family="{MONO if mono else SANS}" '
                             f'font-size="{size}" font-weight="{weight}" fill="{t[color]}">{escape(value)}</text>'))

    def line(self, points, color="line", dashed=False, arrow=True, halo=False, width=1.6):
        d = "M" + " L".join(f"{px} {py}" for px, py in points)

        def f(t):
            s = ""
            if halo:
                s += f'<path d="{d}" fill="none" stroke="{t["halo"]}" stroke-width="7"/>'
            dash = ' stroke-dasharray="6 5"' if dashed else ""
            mark = f' marker-end="url(#arrow-{color})"' if arrow else ""
            s += f'<path d="{d}" fill="none" stroke="{t[color]}" stroke-width="{width}"{dash}{mark}/>'
            return s
        self._add(f)

    def badge(self, x, y, n, color="fg"):
        self._add(lambda t: (f'<circle cx="{x}" cy="{y}" r="9.5" fill="{t[color]}"/>'
                             f'<text x="{x}" y="{y + 4}" text-anchor="middle" font-family="{SANS}" font-size="11" '
                             f'font-weight="700" fill="{t["card"]}">{n}</text>'))

    def render(self, theme):
        t = THEMES[theme]
        markers = "".join(
            f'<marker id="arrow-{k}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
            f'orient="auto-start-reverse"><path d="M0 0 L10 5 L0 10 z" fill="{t[k]}"/></marker>'
            for k in ("line", "egress", "fg", "muted", "operator", "sandbox", "root", "project"))
        body = "".join(op(t) for op in self.ops)
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="{self.w}" '
                f'height="{self.h}" role="img" aria-labelledby="title desc" xml:space="preserve">'
                f'<title id="title">{escape(self.title)}</title><desc id="desc">{escape(self.desc)}</desc>'
                f'<defs>{markers}</defs>{body}</svg>\n')


# --------------------------------------------------------------------------
# system-overview: README.md
# --------------------------------------------------------------------------
def system_overview():
    s = Svg(1280, 770, "ai-tools system overview",
            "Your account launches the coding agent through a wrapper and a sudo rule into the ai-tools sandbox "
            "account; root helpers hand written files back; the claimed project is shared through file "
            "permissions; prompts and file contents leave the host for the model service.")
    # zones; the sandbox zone's title sits right of arrow 3, which enters at its top edge
    s.zone(20, 20, 300, 550, "operator", "Your account", "operator login, unconfined")
    s.zone(350, 20, 560, 230, "root", "root", "privileged helpers, outside the sandbox")
    s.zone(350, 280, 560, 290, "sandbox", "Sandbox account  ai-tools", "no login shell · no password · no sudo rule",
           title_dx=60)
    s.zone(940, 20, 320, 550, "project", "Claimed project tree", "shared through file permissions")
    s.zone(350, 600, 560, 150, "external", "Outside the host")

    # operator
    s.box(40, 68, 260, 72, "operator", "Your shell", ["run {coding-agent-name}", "in a claimed project"])
    s.box(40, 168, 260, 86, "operator", "coding-agent wrapper",
          ["`/usr/local/bin/{coding-agent-name}`", "runs as you; checks ai-ops", "membership and other gates"])
    s.box(40, 282, 260, 72, "operator", "allowed-projects",
          ["`~/.config/ai-tools` · maintained", "with the `atr projects` CLI"])
    # the root helpers read it on your behalf; an edge to them would cross the sudo and handback routes
    s.box(40, 370, 260, 86, "operator", "secret-patterns",
          ["`~/.config/ai-tools` · edited by you", "the root helpers read it to lock", "secret-named files away"])
    s.box(40, 472, 260, 86, "operator", "$ ai-tools",
          ["runs as you: claims projects, keeps", "your allowlist, reports status;", "root steps go through sudo"],
          mono_title=True)
    s.gear(287, 485, 6, "operator")

    # root
    s.box(370, 66, 182, 118, "root", "sudo",
          ["%ai-ops rules only:", "launch a session", "stop every session", "", "`/etc/sudoers.d/ai-tools`"])
    s.box(566, 66, 156, 86, "root", "relabel watcher",
          ["on a toolchain change:", "verify, write the pin,", "set the SELinux label"])
    s.box(735, 66, 160, 86, "root", "handback daemon",
          ["socket-activated;", "checks the caller's uid", "by kernel credential"])
    s.box(566, 170, 156, 56, "root", "/var/log/ai-tools", ["root-only trail"], mono_title=True)
    s.box(735, 166, 160, 80, "root", "# ai-tools-admin",
          ["root only: enrols", "operators, provisions", "toolchain and SELinux"], mono_title=True)
    s.gear(883, 181, 6, "root")

    # sandbox
    s.box(370, 336, 200, 70, "sandbox", "ai-tools-run", ["confinement shim", "checks the entrypoint pin"])
    s.box(370, 450, 200, 70, "sandbox", "nvm-update.timer", ["runs as ai-tools;", "verifies npm signatures"])
    # the unit frame holds the agent
    s._add(lambda t: (f'<rect x="600" y="326" width="295" height="214" rx="8" fill="none" stroke="{t["sandbox"]}" '
                      f'stroke-dasharray="4 3" stroke-width="1.2"/>'))
    s.text(612, 345, "transient systemd unit", 12.5, "fg", "600")
    s.text(612, 361, "ai_tools_t · restricted service", 11)
    s.box(615, 376, 265, 54, "sandbox", "coding-agent hooks", ["after each tool call and turn"])
    # the stable link is what the wrapper reads; the unit runs the versioned file it resolves to
    s.box(615, 446, 265, 86, "sandbox", "coding-agent entrypoint",
          ["its link in `/opt/ai-tools/bin` resolves", "to the versioned file in `.nvm`",
           "starts in the claimed project"])

    # project cards
    s.box(960, 76, 280, 100, "sandbox", "Files the coding agent writes",
          ["handed back per tool call and turn:", "you via owner bits, agent via group", "bits; world access removed"])
    s.box(960, 196, 280, 100, "root", "Secret-named files",
          [".env, *.key, *.pem, kubeconfig …", "locked to you alone, mode 600,", "before a claim grants anything"])
    s.box(960, 316, 280, 100, "root", "Owner-only paths",
          ["no group or other bits: your", "keep-private signal, which no", "claim opens"])
    s.box(960, 436, 280, 100, "operator", "Files you write",
          ["the coding agent reaches them", "through the ACL grant a claim", "writes; you stay out of its group"])
    # arrows 4 and 6 end on this bar, so each points at the tree rather than at the card beside its end
    s.line([(948, 76), (948, 536)], color="project", arrow=False, width=3)

    # external
    s.box(370, 640, 200, 64, "external", "npm registry", ["Node and the package", "of each coding agent"])
    s.box(600, 640, 295, 64, "egress", "Model service",
          ["receives prompts and the file", "contents the coding agent reads"])

    # arrows (crossing-free by layout; numbers match the key)
    s.line([(170, 140), (170, 166)])
    s.line([(170, 254), (170, 280)], color="muted")
    s.text(180, 272, "reads", 11)
    s.line([(300, 211), (335, 211), (335, 109), (368, 109)])
    s.line([(390, 184), (390, 334)])
    s.line([(570, 371), (598, 371)])
    s.line([(880, 489), (944, 489)])
    s.line([(880, 403), (904, 403), (904, 128), (899, 128)])
    s.line([(895, 109), (944, 109)])
    s.line([(747, 532), (747, 638)], color="egress")
    s.line([(530, 520), (530, 638)], dashed=True, color="muted")
    s.badge(170, 153, 1)
    s.badge(335, 160, 2)
    s.badge(390, 265, 3)
    s.badge(918, 489, 4)
    s.badge(904, 265, 5)
    s.badge(918, 109, 6)
    s.badge(747, 585, 7, "egress")

    # key
    s.text(20, 616, "How a session runs", 13, "fg", "600")
    key = ["you run {coding-agent-name} in a claimed project",
           "the wrapper checks, then calls its sudo rule",
           "ai-tools-run starts the session unit as ai-tools",
           "the coding agent reads and writes the project",
           "hooks ask the root daemon to hand files back",
           "the daemon returns ownership to you",
           "prompts and file contents leave the host"]
    for i, k in enumerate(key):
        s.badge(30, 636 + i * 17.5 - 4, i + 1, "egress" if i == 6 else "fg")
        s.text(46, 636 + i * 17.5, k, 11.5)
    return s


# --------------------------------------------------------------------------
# identities: docs/naming-conventions.md
# --------------------------------------------------------------------------
def identities():
    s = Svg(1280, 550, "ai-tools identities: the operators, the sandbox account, root, and their groups",
            "Operators op and svc-ci each hold ai-ops membership, a name in OPERATORS and their own allowlist; "
            "op also holds a general sudo grant. The ai-tools sandbox account runs every session and is not "
            "in ai-ops; root is not an operator. The operators group carries the two sudo rules; the sandbox group "
            "is how the coding agent reaches the files you write; your own group takes your secret-named files.")
    s.zone(20, 20, 600, 510, "operator", "Who is who",
           "OPERATORS=[op, svc-ci] in /etc/ai-tools/operator.conf")
    s.box(40, 70, 275, 176, "operator", "op", [
        [("operator: user in ", None, False), ("ai-ops", "fg", True), (" group,", None, False)],
        "named in OPERATORS, own allowlist",
        "+ a general sudo grant", "  (the host's sudoers, not ours)",
        "→ claims, unclaims, locks down", "   and claims for others"], mono_title=True, tag="WITH SUDO GRANT")
    s.box(330, 70, 270, 176, "operator_soft", "svc-ci", [
        [("operator: user in ", None, False), ("ai-ops", "fg", True), (" group,", None, False)],
        "named in OPERATORS, own allowlist",
        "no sudo grant", "",
        "→ launches sessions; its projects", "   are claimed for it with --for"], mono_title=True, tag="NO SUDO GRANT")
    s.box(40, 270, 560, 118, "sandbox", "ai-tools", [
        "the sandbox account: every session of every operator runs as it",
        "no login shell, no password, no sudo rule, owns none of your files",
        [("not in ai-ops", "danger", True), (": ai-tools-run refuses to launch if it ever is", None, False)],
        "its name is fixed by the package"], mono_title=True)
    s.box(40, 412, 560, 100, "root", "root", [
        "not an operator: every mutating command refuses root, to keep",
        "an operator's registries out of root's ownership — so a host",
        "needs at least one operator holding a sudo grant"], mono_title=True)

    s.zone(660, 20, 600, 510, "project", "The groups", "who is in each, and what it is for")
    s.box(680, 70, 560, 120, "operator", "ai-ops", [
        "the operators group: every operator is a member",
        "its two sudo rules run without a password:",
        [("start a session as ai-tools", "sandbox", True), (", and ", None, False),
         ("stop every sandbox session", "danger", True)],
        "the sandbox account is not in it"], mono_title=True, tag="OPERATORS")
    s.box(680, 206, 560, 120, "sandbox", "ai-tools", [
        "the sandbox account's group",
        "a claim grants it on the project tree: through it the coding",
        "agent reaches the files you write, whatever your umask",
        "a handed-back file keeps it, so the coding agent keeps access"], mono_title=True, tag="SANDBOX")
    s.box(680, 342, 560, 120, "group", "your group", [
        "each operator's own primary group",
        "a secret-named file is locked to you and it at mode 600",
        "an unclaim returns a handed-back file to it",
        ""], mono_title=True, tag="PER OPERATOR")
    s.line([(680, 492), (1240, 492)], color="muted", dashed=True, arrow=False, width=1.2)
    s.text(960, 486, "no cross-group membership", 11.5, "fg", "600", anchor="middle")
    s.text(960, 512, "no operator is in group ai-tools; ai-tools is in no operator's group", 11, anchor="middle")
    return s


# --------------------------------------------------------------------------
# ownership-lifecycle: docs/projects/permissions.md
# --------------------------------------------------------------------------
# An owner or group value takes the colour of whose it is.
WHOSE = {"you": "operator", "ai-tools": "sandbox", "your group": "group"}
ACCESS = {"rw": ("read · write", "project", True), "none": ("none", "muted", False),
          "asis": ("as it was", "muted", False)}


def access_row(s, x, y, who, state):
    """Draws one row of who-reaches-a-file: the party, then a chip naming its access."""
    label, color, solid = ACCESS[state]
    s.text(x, y, who, 11.5, "muted")

    def chip(t):
        fill = f'fill="{t[color]}" fill-opacity="0.16"' if solid else 'fill="none"'
        dash = "" if state == "rw" else ' stroke-dasharray="3 3"'
        return (f'<rect x="{x + 86}" y="{y - 12}" width="110" height="17" rx="8.5" {fill} '
                f'stroke="{t[color]}" stroke-width="1.1"{dash}/>')
    s._add(chip)
    s.text(x + 141, y + 1, label, 11, "fg" if state == "rw" else "muted", "600" if state == "rw" else "400",
           anchor="middle")


def ownership_lifecycle():
    s = Svg(1280, 600, "The life of a file in a claimed project",
            "A file of yours before a claim; after projects claim it moves to the sandbox group and loses world "
            "access; a file the coding agent writes is born owned by the sandbox account and you reach it through "
            "your grant; the handback returns it to you, or to you and your group alone when its name is "
            "a secret's; after projects unclaim a handed-back file is back in your group, the coding agent has no "
            "access and world access does not return.")
    agent = "Coding agent"
    stages = [
        ("1 · BEFORE THE CLAIM", "a file of yours", "you", "your group",
         [("You", "rw"), (agent, "asis"), ("Others", "asis")], ["whatever its mode gave it"]),
        ("2 · AFTER projects claim", "the same file", "you", "ai-tools",
         [("You", "rw"), (agent, "rw"), ("Others", "none")],
         ["owner-only paths and secret-", "named files are left out"]),
        ("3 · THE CODING AGENT WRITES", "a new file", "ai-tools", "ai-tools",
         [("You", "rw"), (agent, "rw"), ("Others", "none")],
         ["you reach it through your", "grant, before any handback"]),
        ("4 · HANDED BACK", "the coding agent's file", "you", "ai-tools",
         [("You", "rw"), (agent, "rw"), ("Others", "none")],
         ["after each tool call and turn;", "projects handback for the rest"]),
        ("5 · AFTER projects unclaim", "a handed-back file", "you", "your group",
         [("You", "rw"), (agent, "none"), ("Others", "none")],
         ["world access does not come", "back: back up before a claim"]),
    ]
    w, gap, y, h = 228, 25, 30, 300
    for i, (step, title, owner, group, access, notes) in enumerate(stages):
        x = 20 + i * (w + gap)
        accent = "operator" if i in (0, 4) else ("sandbox" if i == 2 else "project")
        s._add(lambda t, x=x, accent=accent: (
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="9" fill="{t["card"]}" '
            f'stroke="{t[accent]}" stroke-width="1.5"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="34" rx="9" fill="{t[accent]}" fill-opacity="0.13"/>'))
        s.text(x + 14, y + 22, step, 10.5, accent, "700")
        s.text(x + 14, y + 60, title, 13.5, "fg", "600")
        s.text(x + 14, y + 88, "owner", 11.5, "muted")
        s.text(x + 66, y + 88, owner, 12.5, WHOSE[owner], "600", mono=True)
        s.text(x + 14, y + 108, "group", 11.5, "muted")
        s.text(x + 66, y + 108, group, 12.5, WHOSE[group], "600", mono=True)
        s._add(lambda t, x=x: f'<line x1="{x + 14}" y1="{y + 124}" x2="{x + w - 14}" y2="{y + 124}" '
                              f'stroke="{t["border"]}"/>')
        for j, (who, state) in enumerate(access):
            access_row(s, x + 14, y + 150 + j * 27, who, state)
        for j, line in enumerate(notes):
            s.text(x + 14, y + 248 + j * 16, line, 11.5, "muted")
        if i < 4:
            s.line([(x + w + 3, y + h / 2), (x + w + gap - 3, y + h / 2)], color="fg")
    # the secret branch under stage 4
    bx = 20 + 3 * (w + gap)
    s.line([(bx + w / 2, y + h), (bx + w / 2, 382)], color="fg")
    s.text(bx + w / 2 + 8, 360, "a secret-named file", 11.5, "fg", "600")
    s._add(lambda t: (f'<rect x="{bx}" y="384" width="{w}" height="162" rx="9" fill="{t["card"]}" '
                      f'stroke="{t["root"]}" stroke-width="1.5"/>'))
    s.text(bx + 14, 410, "LOCKED TO YOU", 10.5, "root", "700")
    s.text(bx + 14, 436, "owner", 11.5, "muted")
    s.text(bx + 66, 436, "you", 12.5, WHOSE["you"], "600", mono=True)
    s.text(bx + 14, 456, "group", 11.5, "muted")
    s.text(bx + 66, 456, "your group", 12.5, WHOSE["your group"], "600", mono=True)
    for j, (who, state) in enumerate([("You", "rw"), (agent, "none"), ("Others", "none")]):
        access_row(s, bx + 14, 482 + j * 24, who, state)
    # what every step leaves alone
    s._add(lambda t: (f'<rect x="20" y="384" width="734" height="162" rx="9" fill="none" '
                      f'stroke="{t["border"]}" stroke-dasharray="5 4"/>'))
    s.text(36, 410, "What no step touches", 12.5, "fg", "600")
    for j, line in enumerate([
            "· a file you wrote is not re-owned by the handback: it acts only while the coding agent owns a file",
            "· an owner-only path, and one on a ! line of your allowlist, is skipped by every step",
            "· a session that ends early can leave files the coding agent owns: "
            "atr projects handback returns them",
            "· the files the coding agent writes inside .git come back at the start and end of each session"]):
        s.text(36, 436 + j * 21, line, 12, "muted")
    s.text(1260, 586, "who reaches a file, as getfacl -e reports it", 10.5, mono=True, anchor="end")
    return s


# --------------------------------------------------------------------------
# two-grants: docs/projects/permissions.md
# --------------------------------------------------------------------------
def two_grants():
    s = Svg(1280, 450, "Two grants let you and the coding agent co-write one tree",
            "A claim writes two grants on the project. The coding agent's group grant reaches the files you write, "
            "whatever your umask; your named grant reaches the files the coding agent writes, before the handback "
            "makes you their owner. Neither of you joins the other's group, others get no access, and every new "
            "file inherits both grants.")
    s.zone(20, 20, 250, 330, "operator", "You", "the operator in the ai-ops group")
    s.text(34, 92, "not in group ai-tools", 12, "fg")
    s.text(34, 112, "reach your files as their owner,", 11.5, "muted")
    s.text(34, 128, "the coding agent's through", 11.5, "muted")
    s.text(34, 144, "your named grant", 11.5, "muted")
    s.zone(1010, 20, 250, 330, "sandbox", "The coding agent", "runs as the ai-tools service")
    s.text(1024, 92, "in none of your groups", 12, "fg")
    s.text(1024, 112, "reaches its files as their owner,", 11.5, "muted")
    s.text(1024, 128, "yours through its group grant", 11.5, "muted")
    s.zone(330, 20, 620, 330, "project", "The claimed project", "both grants sit on every directory and are inherited")
    s.box(370, 90, 250, 110, "operator", "a file you write",
          ["owner: you", "written under any umask,", "it still opens to the coding agent"])
    s.box(660, 90, 250, 110, "sandbox", "a file the coding agent writes",
          ["owner: ai-tools, until the handback", "makes you its owner; you can", "open it before that runs"])
    # each party reaches its own files as their owner
    s.line([(270, 145), (366, 145)], color="operator")
    s.text(280, 136, "owner", 11, "operator")
    s.line([(1010, 145), (914, 145)], color="sandbox")
    s.text(1000, 136, "owner", 11, "sandbox", anchor="end")
    # and the other party's files through its grant
    s.line([(1010, 300), (495, 300), (495, 204)], color="sandbox", width=2.2)
    s.line([(270, 270), (785, 270), (785, 204)], color="operator", width=2.2)
    s._add(lambda t: (f'<rect x="520" y="226" width="250" height="34" rx="6" fill="{t["card"]}" '
                      f'stroke="{t["operator"]}"/>'
                      f'<rect x="520" y="306" width="330" height="34" rx="6" fill="{t["card"]}" '
                      f'stroke="{t["sandbox"]}"/>'))
    s.text(532, 248, "Grant 2 · your named grant", 12, "operator", "600")
    s.text(532, 328, "Grant 1 · the coding agent's group grant", 12, "sandbox", "600")
    facts = [("Others", "no access: a claim closes world access on every path it touches"),
             ("New files", "a project directory gives every new file the sandbox group and both grants"),
             ("Not granted", "owner-only paths, ! lines of your allowlist and secret-named files get neither grant"),
             ("Check it", "getfacl -e <path> shows effective access; ls -l marks a file carrying an ACL with +")]
    for j, (k, v) in enumerate(facts):
        s.text(34, 384 + j * 21, k, 12, "fg", "600")
        s.text(130, 384 + j * 21, v, 12, "muted")
    return s


DIAGRAMS = (("system-overview", system_overview), ("identities", identities),
            ("ownership-lifecycle", ownership_lifecycle), ("two-grants", two_grants))


def rendered():
    """Yields (path, markup) for every theme of every diagram."""
    for name, build in DIAGRAMS:
        svg = build()
        for theme in THEMES:
            yield OUT / f"{name}-{theme}.svg", svg.render(theme)


def main(argv):
    verb = argv[1] if len(argv) == 2 else ""
    if verb == "generate":
        OUT.mkdir(parents=True, exist_ok=True)
        for path, markup in rendered():
            path.write_text(markup, encoding="utf-8")
        return 0
    if verb == "stale":
        drawn = dict(rendered())
        stale = [path for path, markup in drawn.items()
                 if not path.is_file() or path.read_text(encoding="utf-8") != markup]
        for path in stale:
            print(f"{path} is stale; run: python3 tools/generators/diagrams.py generate", file=sys.stderr)
        # An SVG no layout draws is what a dropped or renamed layout leaves; generate does not remove a tracked file.
        leftover = sorted(set(OUT.glob("*.svg")) - drawn.keys()) if OUT.is_dir() else []
        for path in leftover:
            print(f"{path} is not drawn by any layout; remove it with git rm, or git mv it where a layout was renamed",
                  file=sys.stderr)
        return 1 if stale or leftover else 0
    print("usage: python3 tools/generators/diagrams.py generate|stale", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
