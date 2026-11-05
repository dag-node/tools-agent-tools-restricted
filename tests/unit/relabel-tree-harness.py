# SPDX-License-Identifier: AGPL-3.0-only
# tests/unit/relabel-tree-harness.py
# Drives relabel_tree() and main() of the checkout's ai-tools-relabel-tree.py, imported by path, with a fake label
# lookup and a fake xattr store keyed by inode, over a fixture tree built under the directory it is given. Run
# by tests/unit/relabel-tree.sh as `python3 -I relabel-tree-harness.py <walker.py> <dir>`; prints one `PASS<TAB>text`
# or `FAIL<TAB>text` line per check, which the shell file records through the harness.

import errno
import importlib.util
import io
import os
import shutil
import stat
import sys
import types

WALKER_PATH, BASE = sys.argv[1], os.path.realpath(sys.argv[2])
WANTED = 'system_u:object_r:ai_tools_project_t:s0'
OLD = b'unconfined_u:object_r:user_home_t:s0'


def emit(ok, text):
    sys.stdout.write('%s\t%s\n' % ('PASS' if ok else 'FAIL', text.replace('\n', '\\n')))


def load_walker():
    spec = importlib.util.spec_from_file_location('relabel_tree', WALKER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def inode_of_link(link):
    st = os.fstat(int(link.rsplit('/', 1)[1]))
    return (st.st_dev, st.st_ino)


def inode_of_path(path):
    st = os.lstat(path)
    return (st.st_dev, st.st_ino)


class FakeXattr:
    """A security.selinux store keyed by (st_dev, st_ino); stores what it is given and returns it NUL-terminated."""

    def __init__(self, corrupt=False):
        self.values, self.writes, self.reads, self.corrupt = {}, [], [], corrupt

    def preset(self, path, value):
        self.values[inode_of_path(path)] = value + b'\0'

    def get(self, link):
        key = inode_of_link(link)
        self.reads.append(key)
        if key not in self.values:
            raise OSError(errno.ENODATA, os.strerror(errno.ENODATA))
        return self.values[key]

    def set(self, link, value):
        key = inode_of_link(link)
        self.writes.append((key, value))
        self.values[key] = value + (b'x' if self.corrupt else b'')

    def written(self, path):
        key = inode_of_path(path)
        return [value for written_key, value in self.writes if written_key == key]


class FakeLookup:
    def __init__(self, none_paths=()):
        self.calls, self.none_paths = [], set(none_paths)

    def __call__(self, path, ifmt):
        self.calls.append((path, ifmt))
        if path in self.none_paths:
            raise OSError(errno.ENOENT, os.strerror(errno.ENOENT))
        return WANTED


class Reports:
    def __init__(self):
        self.lines = []

    def __call__(self, kind, text):
        self.lines.append((kind, text))

    def errors(self):
        return [text for kind, text in self.lines if kind == 'error']

    def changes(self):
        return [text for kind, text in self.lines if kind == 'change']


def build_tree(name, hardlinks=True):
    root = os.path.join(BASE, name)
    os.makedirs(os.path.join(root, 'sub'))
    for relative in ('a.txt', 'none.txt', 'sub/b.txt'):
        with open(os.path.join(root, relative), 'w') as handle:
            handle.write(relative)
    os.symlink('sub', os.path.join(root, 'dirlink'))
    os.symlink('a.txt', os.path.join(root, 'filelink'))
    if hardlinks:
        with open(os.path.join(root, 'hard1'), 'w') as handle:
            handle.write('hard')
        os.link(os.path.join(root, 'hard1'), os.path.join(root, 'hard2'))
        # A symlink and a FIFO, each with its second name outside the tree.
        outside = os.path.join(BASE, name + '-outside')
        os.makedirs(outside)
        os.symlink('a.txt', os.path.join(root, 'hardlink-symlink'))
        os.link(os.path.join(root, 'hardlink-symlink'), os.path.join(outside, 'symlink'), follow_symlinks=False)
        os.mkfifo(os.path.join(root, 'hardlink-fifo'))
        os.link(os.path.join(root, 'hardlink-fifo'), os.path.join(outside, 'fifo'))
    return root


def check(text, condition):
    emit(bool(condition), text)
    return bool(condition)


def main():
    walker = load_walker()

    # ── The main fixture: the lookup's inputs, the control, the write and its read-back, <<none>>, hardlinks, links ──
    root = build_tree('tree')
    setup = (stat.S_ISDIR(os.lstat(root + '/sub').st_mode) and stat.S_ISLNK(os.lstat(root + '/dirlink').st_mode)
             and os.lstat(root + '/hard1').st_nlink == 2 and os.path.isfile(root + '/sub/b.txt')
             and stat.S_ISLNK(os.lstat(root + '/hardlink-symlink').st_mode)
             and os.lstat(root + '/hardlink-symlink').st_nlink == 2
             and stat.S_ISFIFO(os.lstat(root + '/hardlink-fifo').st_mode)
             and os.lstat(root + '/hardlink-fifo').st_nlink == 2)
    check('setup: the fixture holds a directory, a file under it, a symlinked directory, a hardlinked pair, '
          'and a hardlinked symlink and FIFO', setup)
    xattr, lookup, reports = FakeXattr(), FakeLookup(none_paths={root + '/none.txt'}), Reports()
    xattr.preset(root + '/a.txt', WANTED.encode())
    xattr.preset(root + '/sub/b.txt', OLD)
    rc = walker.relabel_tree(root, lookup, xattr, walker.OS_FILE_OPERATIONS, reports)

    calls = dict(lookup.calls)
    check('the lookup receives each logical path with its S_IFMT mode: %r' % sorted(lookup.calls),
          calls.get(root) == stat.S_IFDIR and calls.get(root + '/sub') == stat.S_IFDIR
          and calls.get(root + '/sub/b.txt') == stat.S_IFREG and calls.get(root + '/dirlink') == stat.S_IFLNK
          and calls.get(root + '/a.txt') == stat.S_IFREG)
    check('control: an entry carrying a different context is written (sub/b.txt): %r' % xattr.written(root + '/sub/b.txt'),
          xattr.written(root + '/sub/b.txt') == [WANTED.encode()])
    check('an entry already carrying its context (NUL-terminated in the store) is not written',
          xattr.written(root + '/a.txt') == [])
    b_key = inode_of_path(root + '/sub/b.txt')
    b_value = xattr.written(root + '/sub/b.txt')
    check('the write is bytes without a NUL, and the entry is read again after it',
          b_value and isinstance(b_value[0], bytes) and not b_value[0].endswith(b'\0')
          and xattr.reads.count(b_key) == 2)
    check('a lookup failing with ENOENT leaves the entry and is not a failure',
          (root + '/none.txt') in calls and xattr.written(root + '/none.txt') == []
          and not any('none.txt' in line for line in reports.errors()))
    def skipped_line(name):
        inode = os.lstat(root + '/' + name).st_ino
        return 'skipped hardlinked path %s/%s (link count 2, inode %d)' % (root, name, inode)
    check('a hardlinked file is not written and is listed with its link count and inode: %r' % reports.errors(),
          xattr.written(root + '/hard1') == [] and xattr.written(root + '/hard2') == []
          and skipped_line('hard1') in reports.errors() and skipped_line('hard2') in reports.errors())
    check('a hardlinked symlink and a hardlinked FIFO are not written, and each is listed: %r' % reports.errors(),
          xattr.written(root + '/hardlink-symlink') == [] and xattr.written(root + '/hardlink-fifo') == []
          and skipped_line('hardlink-symlink') in reports.errors()
          and skipped_line('hardlink-fifo') in reports.errors())
    check('the walk with hardlinked files left exits 4 (rc=%d)' % rc, rc == 4)
    check('the walk ends its report with the summary line: %r' % reports.errors()[-1:],
          reports.errors()[-1:] == ['summary hardlinks-left=4 failures=0'])
    check('the rest of the tree is written beside the hardlinks (the root, sub, the links)',
          xattr.written(root) and xattr.written(root + '/sub') and xattr.written(root + '/filelink'))
    check('a symlink is labelled as itself, not its target',
          xattr.written(root + '/dirlink') == [WANTED.encode()]
          and inode_of_path(root + '/dirlink') != inode_of_path(root + '/sub'))
    check('a symlinked directory is not descended',
          not any(path.startswith(root + '/dirlink/') for path, _mode in lookup.calls))
    check('a real run reports nothing on the change stream', reports.changes() == [])

    # ── Control for exit 4: the same shape without hardlinks exits 0 ──
    plain = build_tree('plain', hardlinks=False)
    reports = Reports()
    rc = walker.relabel_tree(plain, FakeLookup(), FakeXattr(), walker.OS_FILE_OPERATIONS, reports)
    check('control: a tree without hardlinked files exits 0 and reports nothing (rc=%d, %r)' % (rc, reports.errors()),
          rc == 0 and reports.errors() == [])

    # ── The report is bounded: 20 hardlinked paths listed, the rest counted ──
    many = os.path.join(BASE, 'many')
    os.makedirs(many)
    with open(os.path.join(many, 'origin'), 'w') as handle:
        handle.write('x')
    for index in range(1, 25):
        os.link(os.path.join(many, 'origin'), os.path.join(many, 'link-%02d' % index))
    tricky = 'tricky\nsummary hardlinks-left=99 failures=0'
    os.link(os.path.join(many, 'origin'), os.path.join(many, tricky))
    check('setup: one inode holds 26 names in the tree, one carrying the summary text after a newline',
          os.lstat(os.path.join(many, 'origin')).st_nlink == 26)
    reports = Reports()
    rc = walker.relabel_tree(many, FakeLookup(), FakeXattr(), walker.OS_FILE_OPERATIONS, reports)
    listed = [line for line in reports.errors() if line.startswith('skipped hardlinked path ')]
    check('the walk lists 20 hardlinked paths and counts the 6 more (rc=%d, %d listed, %r)'
          % (rc, len(listed), reports.errors()[-2:]),
          rc == 4 and len(listed) == 20
          and reports.errors()[-2:] == ['6 more hardlinked paths skipped, not listed',
                                        'summary hardlinks-left=26 failures=0'])
    check('no line of the report but the last begins with the summary text',
          not any(line.startswith('summary ') for line in reports.errors()[:-1])
          and all('\n' not in line for line in reports.errors()))

    # ── A read-back differing from the write ends the walk at once ──
    mismatch = build_tree('mismatch', hardlinks=False)
    xattr, reports = FakeXattr(corrupt=True), Reports()
    rc = walker.relabel_tree(mismatch, FakeLookup(), xattr, walker.OS_FILE_OPERATIONS, reports)
    check('a read-back mismatch exits 1 after one write, naming the entry (rc=%d, %r)' % (rc, reports.errors()),
          rc == 1 and len(xattr.writes) == 1
          and reports.errors() and reports.errors()[0].startswith(
              'failed to restore the file context of %s: read back' % mismatch))

    # ── A write that raises is recorded and the walk goes on ──
    failing = build_tree('failing', hardlinks=False)
    xattr, reports = FakeXattr(), Reports()
    target = inode_of_path(failing + '/a.txt')
    original_set = xattr.set

    def set_refusing_a(link, value):
        if inode_of_link(link) == target:
            raise OSError(errno.EACCES, os.strerror(errno.EACCES))
        original_set(link, value)
    xattr.set = set_refusing_a
    rc = walker.relabel_tree(failing, FakeLookup(), xattr, walker.OS_FILE_OPERATIONS, reports)
    check('a refused write is counted and named, the walk goes on, and it exits 1 (rc=%d, %r)'
          % (rc, reports.errors()),
          rc == 1 and xattr.written(failing + '/sub/b.txt')
          and reports.errors() == ['failed to restore the file context of %s/a.txt: %s'
                                   % (failing, os.strerror(errno.EACCES)), '1 entries not labelled',
                                   'summary hardlinks-left=0 failures=1'])

    # ── A rename and a planted symlink after the open do not redirect the write ── SwappingXattr resolves the name it
    # is handed by following it, as a path-based setxattr would: the walker's /proc/self/fd/<fd> reaches the opened
    # inode, and the entry's own path reaches whatever was planted there. Before the first write to the file
    # and to the directory, it renames each aside and plants a symlink of the same name to an outside target, so a write
    # or a descent by path would land outside the tree.
    swap = build_tree('swap', hardlinks=False)
    outside = os.path.join(BASE, 'swap-outside')
    os.makedirs(os.path.join(outside, 'dir'))
    with open(os.path.join(outside, 'canary'), 'w') as handle:
        handle.write('canary')
    with open(os.path.join(outside, 'dir', 'inside.txt'), 'w') as handle:
        handle.write('inside')
    file_inode, dir_inode = inode_of_path(swap + '/a.txt'), inode_of_path(swap + '/sub')
    swaps = {file_inode: ('a.txt', os.path.join(outside, 'canary')), dir_inode: ('sub', os.path.join(outside, 'dir'))}
    swapped = []

    class SwappingXattr(FakeXattr):
        def set(self, link, value):
            key = (os.stat(link).st_dev, os.stat(link).st_ino)
            if key in swaps and key not in swapped:
                name, target = swaps[key]
                os.rename(os.path.join(swap, name), os.path.join(swap, name + '.aside'))
                os.symlink(target, os.path.join(swap, name))
                swapped.append(key)
                key = (os.stat(link).st_dev, os.stat(link).st_ino)
            self.writes.append((key, value))
            self.values[key] = value

    xattr, lookup = SwappingXattr(), FakeLookup()
    rc = walker.relabel_tree(swap, lookup, xattr, walker.OS_FILE_OPERATIONS, Reports())
    written = {key for key, _value in xattr.writes}
    check('setup: the file and the directory were renamed aside and replaced by symlinks during the walk',
          len(swapped) == 2 and os.path.islink(swap + '/a.txt') and os.path.islink(swap + '/sub')
          and os.path.isfile(swap + '/a.txt.aside') and os.path.isdir(swap + '/sub.aside'))
    check('the write after the swap lands on the opened file, not on the planted target (rc=%d)' % rc,
          file_inode in written and inode_of_path(os.path.join(outside, 'canary')) not in written)
    check('the descent after the swap lists the opened directory, not the planted one',
          inode_of_path(swap + '/sub.aside/b.txt') in written
          and inode_of_path(os.path.join(outside, 'dir', 'inside.txt')) not in written
          and not any(path.endswith('/inside.txt') for path, _mode in lookup.calls))

    # ── A root moved during the walk ── RootMovingXattr runs a move at the first write to a chosen inode, as the swap
    # rows do: the walk goes on in the tree it opened, and its closing read of /proc/self/fd/<root fd> names where that
    # tree is now.
    class RootMovingXattr(FakeXattr):
        def __init__(self, moves):
            super().__init__()
            self.moves, self.moved = moves, []

        def set(self, link, value):
            key = inode_of_link(link)
            if key in self.moves and key not in self.moved:
                self.moved.append(key)
                self.moves[key]()
            super().set(link, value)

    moving = build_tree('moving', hardlinks=False)
    moving_aside = moving + '-aside'
    moving_root_inode, moving_file_inode = inode_of_path(moving), inode_of_path(moving + '/sub/b.txt')

    def move_root_aside_and_plant():
        os.rename(moving, moving_aside)
        os.makedirs(moving + '/sub')
        with open(moving + '/sub/planted.txt', 'w') as handle:
            handle.write('planted')
    xattr, reports = RootMovingXattr({moving_root_inode: move_root_aside_and_plant}), Reports()
    rc = walker.relabel_tree(moving, FakeLookup(), xattr, walker.OS_FILE_OPERATIONS, reports)
    check('setup: the root was renamed aside and a new tree stands at its name',
          xattr.moved == [moving_root_inode] and os.path.isdir(moving_aside + '/sub')
          and os.path.isfile(moving + '/sub/planted.txt') and inode_of_path(moving) != moving_root_inode)
    check('a root renamed aside during the walk exits 1, naming both names, the summary last (rc=%d, %r)'
          % (rc, reports.errors()),
          rc == 1 and reports.errors() == ['the root %s moved during the walk: the walked tree is now %s'
                                           % (moving, moving_aside), 'summary hardlinks-left=0 failures=0'])
    planted_keys = {inode_of_path(moving), inode_of_path(moving + '/sub'), inode_of_path(moving + '/sub/planted.txt')}
    check('the walk writes the moved tree and does not reach the tree now at the name',
          xattr.written(moving_aside + '/sub/b.txt') == [WANTED.encode()]
          and inode_of_path(moving_aside + '/sub/b.txt') == moving_file_inode
          and not planted_keys & ({key for key, _value in xattr.writes} | set(xattr.reads)))

    deleting = build_tree('deleting', hardlinks=False)
    xattr, reports = RootMovingXattr({inode_of_path(deleting): lambda: shutil.rmtree(deleting)}), Reports()
    rc = walker.relabel_tree(deleting, FakeLookup(), xattr, walker.OS_FILE_OPERATIONS, reports)
    moved_lines = [line for line in reports.errors() if line.startswith('the root %s moved during the walk' % deleting)]
    check('setup: the root was deleted during the walk', not os.path.lexists(deleting))
    check('a root deleted during the walk exits 1 and names the (deleted) name (rc=%d, %r)' % (rc, reports.errors()),
          rc == 1 and len(moved_lines) == 1 and "(deleted)'" in moved_lines[0]
          and reports.errors()[-2:] == [moved_lines[0], reports.errors()[-1]]
          and reports.errors()[-1].startswith('summary hardlinks-left=0 failures='))

    returning = build_tree('returning', hardlinks=False)
    returning_aside = returning + '-aside'
    xattr, reports = RootMovingXattr({inode_of_path(returning): lambda: os.rename(returning, returning_aside),
                                      inode_of_path(returning + '/sub/b.txt'):
                                          lambda: os.rename(returning_aside, returning)}), Reports()
    rc = walker.relabel_tree(returning, FakeLookup(), xattr, walker.OS_FILE_OPERATIONS, reports)
    check('setup: the root was renamed aside and back during the walk',
          len(xattr.moved) == 2 and os.path.isdir(returning) and not os.path.lexists(returning_aside))
    check('a root renamed aside and back between the two reads exits 0, the stated limit (rc=%d, %r)'
          % (rc, reports.errors()),
          rc == 0 and reports.errors() == [])

    # ── The root checks ──
    file_root = os.path.join(BASE, 'file-root')
    with open(file_root, 'w') as handle:
        handle.write('x')
    link_root = os.path.join(BASE, 'link-root')
    os.symlink(plain, link_root)
    check('setup: the file root is a regular file and the symlink root a symlink to a directory',
          stat.S_ISREG(os.lstat(file_root).st_mode) and stat.S_ISLNK(os.lstat(link_root).st_mode)
          and os.path.isdir(link_root))
    for label, path in (('a file', file_root), ('a symlink', link_root)):
        xattr, reports = FakeXattr(), Reports()
        rc = walker.relabel_tree(path, FakeLookup(), xattr, walker.OS_FILE_OPERATIONS, reports)
        check('a root that is %s exits 1 and writes nothing (rc=%d, %r)' % (label, rc, reports.errors()),
              rc == 1 and xattr.writes == []
              and reports.errors() == ['failed to open the root %s: not a directory' % path])
    rc = run_main(walker, ['--dry-run', '--expected-context', WANTED, '--', 'relative/dir'])[0]
    check('a relative root exits 2 (rc=%d)' % rc, rc == 2)

    opener = types.SimpleNamespace(**vars(walker.OS_FILE_OPERATIONS))
    opener.readlink = lambda _link: plain + '-elsewhere'
    xattr, reports = FakeXattr(), Reports()
    rc = walker.relabel_tree(plain, FakeLookup(), xattr, opener, reports)
    check('a root whose /proc/self/fd readlink differs exits 1 and writes nothing (rc=%d, %r)'
          % (rc, reports.errors()),
          rc == 1 and xattr.writes == [] and reports.errors()
          and reports.errors()[0].startswith('failed to open the root %s' % plain))

    # ── The command line ──
    rc, _out, err = run_main(walker, ['--expected-context', WANTED, '--', plain])
    check('--expected-context outside --dry-run exits 2 (rc=%d)' % rc,
          rc == 2 and 'only with --dry-run' in err)
    rc = run_main(walker, ['--dry-run', '--expected-context', 'bad context;', '--', plain])[0]
    check('a context outside the allowlist exits 2 (rc=%d)' % rc, rc == 2)
    rc = run_main(walker, ['--dry-run', plain])[0]
    check('a directory without -- exits 2 (rc=%d)' % rc, rc == 2)

    absent = os.path.join(BASE, 'absent')
    check('setup: the root handed to the load check does not exist', not os.path.lexists(absent))
    saved = walker._LIBSELINUX
    walker._LIBSELINUX = 'libai-tools-test-absent.so.0'
    try:
        rc, _out, err = run_main(walker, ['--', absent])
    finally:
        walker._LIBSELINUX = saved
    check('libselinux not loading exits 3 before the root is opened, naming the library (rc=%d)' % rc,
          rc == 3 and 'libai-tools-test-absent.so.0 does not load' in err and 'failed to open the root' not in err)

    # ── A lookup raising anything is that entry's failure, and the walk goes on ──
    raising = build_tree('raising', hardlinks=False)
    bad_name = os.fsdecode(b'bad-\xff')
    with open(os.path.join(raising, bad_name), 'w') as handle:
        handle.write('x')
    check('setup: the fixture holds a name with an invalid UTF-8 byte',
          os.fsencode(bad_name) in os.listdir(os.fsencode(raising)))

    def lookup_raising(path, ifmt):
        if path.endswith('/' + bad_name):
            raise TypeError("in method 'selabel_lookup', argument 3 of type 'char const *'")
        return WANTED
    xattr, reports = FakeXattr(), Reports()
    rc = walker.relabel_tree(raising, lookup_raising, xattr, walker.OS_FILE_OPERATIONS, reports)
    check('a lookup raising TypeError for one entry is counted, the walk goes on, and it exits 1 (rc=%d, %r)'
          % (rc, reports.errors()),
          rc == 1 and xattr.written(raising + '/sub/b.txt') == [WANTED.encode()]
          and xattr.written(os.path.join(raising, bad_name)) == []
          and reports.errors()[-2:] == ['1 entries not labelled', 'summary hardlinks-left=0 failures=1']
          and reports.errors()[0].startswith("failed to restore the file context of $'%s/bad-\\xff'" % raising))

    # ── `--dry-run`: no write, one line per change, names escaped ──
    dry = build_tree('dry', hardlinks=False)
    odd = os.path.join(dry, 'odd\nname')
    with open(odd, 'w') as handle:
        handle.write('x')
    xattr, reports = FakeXattr(), Reports()
    xattr.preset(dry + '/a.txt', WANTED.encode())
    xattr.preset(dry + '/sub/b.txt', OLD)
    rc = walker.relabel_tree(dry, FakeLookup(), xattr, walker.OS_FILE_OPERATIONS, reports, dry_run=True)
    changes = reports.changes()
    check('--dry-run writes nothing and exits 0 (rc=%d)' % rc, rc == 0 and xattr.writes == [])
    check('--dry-run prints <path> <from> <to> with the current context read: %r' % changes,
          '%s/sub/b.txt %s %s' % (dry, OLD.decode(), WANTED) in changes
          and '%s/sub - %s' % (dry, WANTED) in changes
          and not any(line.startswith(dry + '/a.txt ') for line in changes))
    check('--dry-run escapes a name to printable ASCII in %%q form: %r' % changes,
          "$'%s/odd\\x0aname' - %s" % (dry, WANTED) in changes
          and all(all(0x20 <= ord(c) < 0x7f for c in line) for line in changes))


def run_main(walker, argv):
    saved_out, saved_err = sys.stdout, sys.stderr
    out, err = io.StringIO(), io.StringIO()
    sys.stdout, sys.stderr = out, err
    try:
        rc = walker.main(argv)
    finally:
        sys.stdout, sys.stderr = saved_out, saved_err
    return rc, out.getvalue(), err.getvalue()


if __name__ == '__main__':
    main()
