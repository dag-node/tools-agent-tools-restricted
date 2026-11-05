#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# /usr/local/libexec/ai-tools/ai-tools-relabel-tree
# Descriptor-pinned recursive SELinux relabel of one tree, the walk `restorecon -FR` makes, for a tree the sandbox
# account can write while a process of that account may be live.
#
#   ai-tools-relabel-tree [--dry-run [--expected-context <ctx>]] -- <dir>
#
# <dir> is one absolute path, taken as given: the caller has canonicalized it. The walker opens it O_PATH|O_NOFOLLOW
# and exits 1 unless `/proc/self/fd/<fd>` reads back as the same path, so a symlink swapped into an ancestor the account
# can write (a project nested under another) is not followed. A root that is not a directory exits 1 as well: the caller
# read it as a directory when it canonicalized it, so a file or a symlink there was placed after that read.
#
# Every entry under it is opened O_PATH|O_NOFOLLOW relative to its parent's listing descriptor and typed with fstat,
# and its label is read, written and read back through `/proc/self/fd/<fd>`, so a rename or a planted symlink after
# the open does not redirect the write. getdents is refused on an O_PATH descriptor, so a directory is re-opened
# O_RDONLY|O_DIRECTORY through its O_PATH descriptor to list it, and the walk descends only while the two descriptors
# name the same (st_dev, st_ino). A symlink is labelled as itself; a symlinked directory is not descended. Mounts are
# crossed, as `restorecon -R` crosses them; the sandbox account cannot create a mount.
#
# The guarantee a descriptor gives is bounded by what the account can bring into the tree. The walker reaches only
# an inode the account could move or link there, and selinux/policy/ai_tools.te grants ai_tools_t rename and link
# (manage_*_pattern) on ai_tools_project_t, ai_tools_project_build_t, ai_tools_home_t and ai_tools_tmp_t alone. The
# residual is a host running Permissive whose operator set AI_TOOLS_REQUIRE_SELINUX=no in operator.conf, where the
# policy does not bound those moves.
#
# The label is the file-context database's for the logical path (the root plus the names opened under it), looked
# up once per entry through one selabel handle per run and written in full when it differs, customizable types included
# (`restorecon -F`). The lookup calls libselinux.so.1 through ctypes with the path as bytes: the selinux module's
# selabel_lookup refuses a str carrying an undecodable byte and refuses bytes, so a name the account gives an invalid
# UTF-8 byte would otherwise stop the walk. A path the database maps to <<none>> is left as it is. A regular file
# with more than one link is not written: through its other name it may be another project's or another operator's. It
# is listed on stderr when its label differs, and the walk exits 4.
#
# Exit status: 0 every entry labelled or already correct; 4 complete, with hardlinked files left; 1 an entry could not
# be labelled (the first named on stderr, then the count), a read-back differing from the write (which ends the walk),
# or the root check; 2 usage; 3 libselinux.so.1 does not load or lacks a function the lookup calls. A real run prints
# nothing on stdout. `--dry-run` writes nothing and prints `<path> <from> <to>` for each entry it would write, `-`
# for no current label; `--expected-context` replaces the lookup with <ctx> there and does not load libselinux. Every
# path printed is escaped to printable ASCII in bash `printf %q` form, since a name in the tree is the account's.
#
# walk() takes its collaborators as parameters, so tests/unit/relabel-tree-harness.py imports this file by path
# and drives it with fakes; main() binds the real ones. Installed 0750 root:root as ai-tools-relabel-tree.
# Its domain rule is cli.rule.md.

import ctypes
import errno
import os
import re
import stat
import sys
import types

_PROGRAM = 'ai-tools-relabel-tree'
_LIBSELINUX = 'libselinux.so.1'
_SELABEL_CTX_FILE = 0
_XATTR = 'security.selinux'
_FLAGS_PATH = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC
_FLAGS_LIST = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
_NO_LABEL = (errno.ENODATA, errno.ENOTSUP)
_USAGE = 'usage: %s [--dry-run [--expected-context <ctx>]] -- <dir>' % _PROGRAM
# A context is printed and compared, never parsed; the allowlist covers user:role:type:range with an MLS range.
_CONTEXT_PATTERN = re.compile(r'[A-Za-z0-9_.:,-]+\Z')
# The bytes bash `printf %q` leaves unquoted.
_SHELL_SAFE = frozenset(b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-+:,@%=^')

OS_OPENER = types.SimpleNamespace(open=os.open, listdir=os.listdir, fstat=os.fstat, readlink=os.readlink,
                                  close=os.close)
OS_XATTR = types.SimpleNamespace(get=lambda link: os.getxattr(link, _XATTR),
                                 set=lambda link, value: os.setxattr(link, _XATTR, value))


def quote(text):
    """Returns text (str, surrogateescape for undecodable bytes) as printable ASCII in bash `printf %q` form."""
    raw = os.fsencode(text)
    if not raw:
        return "''"
    if all(0x20 < byte < 0x7f for byte in raw):
        return ''.join(chr(byte) if byte in _SHELL_SAFE else '\\' + chr(byte) for byte in raw)
    escaped = []
    for byte in raw:
        if byte in (0x27, 0x5c):
            escaped.append('\\' + chr(byte))
        elif 0x20 <= byte < 0x7f:
            escaped.append(chr(byte))
        else:
            escaped.append('\\x%02x' % byte)
    return "$'" + ''.join(escaped) + "'"


def _magic_link(fd):
    return '/proc/self/fd/%d' % fd


def _read_context(xattr, fd):
    """Returns the entry's context as bytes without a trailing NUL, or None for no label; raises OSError otherwise."""
    try:
        value = xattr.get(_magic_link(fd))
    except OSError as error:
        if error.errno in _NO_LABEL:
            return None
        raise
    return value[:-1] if value.endswith(b'\0') else value


def _error_text(error):
    if isinstance(error, OSError) and error.errno:
        return os.strerror(error.errno)
    return str(error) or type(error).__name__


class _Walk:
    """The state of one run: the first failure, the failure count, and the hardlinked files left."""

    def __init__(self, lookup, xattr, opener, report, dry_run):
        self.lookup, self.xattr, self.opener, self.report, self.dry_run = lookup, xattr, opener, report, dry_run
        self.first_failure = None
        self.failures = 0
        self.hardlinks_left = 0

    def fail(self, path, error):
        self.failures += 1
        if self.first_failure is None:
            self.first_failure = 'failed to restore the file context of %s: %s' % (quote(path), _error_text(error))

    def label(self, path, fd, st):
        """Labels one entry; returns False when a read-back differs from the write, which ends the walk."""
        try:
            context = self.lookup(path, stat.S_IFMT(st.st_mode))
        except OSError as error:
            if error.errno == errno.ENOENT:
                return True
            self.fail(path, error)
            return True
        except Exception as error:  # recorded as the entry's failure; the walk goes on
            self.fail(path, error)
            return True
        wanted = context.encode('utf-8')
        try:
            current = _read_context(self.xattr, fd)
        except OSError as error:
            self.fail(path, error)
            return True
        if current == wanted:
            return True
        if stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
            self.hardlinks_left += 1
            self.report('error', 'skipped hardlinked file %s (link count %d)' % (quote(path), st.st_nlink))
            return True
        if self.dry_run:
            shown = '-' if current is None else quote(current.decode('utf-8', 'surrogateescape'))
            self.report('change', '%s %s %s' % (quote(path), shown, quote(context)))
            return True
        try:
            self.xattr.set(_magic_link(fd), wanted)
        except OSError as error:
            self.fail(path, error)
            return True
        try:
            readback = _read_context(self.xattr, fd)
        except OSError as error:
            readback = ('unreadable: %s' % _error_text(error)).encode()
        if readback != wanted:
            shown = '-' if readback is None else quote(readback.decode('utf-8', 'surrogateescape'))
            self.first_failure = 'failed to restore the file context of %s: read back %s after writing %s' % (
                quote(path), shown, quote(context))
            self.failures += 1
            return False
        return True

    def open_listing(self, path, path_fd, st):
        """Returns a listing descriptor naming the same inode as path_fd, or None after recording the failure."""
        try:
            listing_fd = self.opener.open('.', _FLAGS_LIST, dir_fd=path_fd)
        except OSError as error:
            self.fail(path, error)
            return None
        try:
            listed = self.opener.fstat(listing_fd)
        except OSError as error:
            self.opener.close(listing_fd)
            self.fail(path, error)
            return None
        if (listed.st_dev, listed.st_ino) != (st.st_dev, st.st_ino):
            self.opener.close(listing_fd)
            self.fail(path, OSError(errno.ESTALE, 'the directory was replaced between its two opens'))
            return None
        return listing_fd

    def descend(self, path, path_fd, st):
        """Walks the directory at path_fd depth-first; returns False when the walk has ended."""
        listing_fd = self.open_listing(path, path_fd, st)
        if listing_fd is None:
            return True
        # Each frame is a directory's (logical path, path fd, listing fd, names still to open).
        stack = []
        try:
            names = self.opener.listdir(listing_fd)
        except OSError as error:
            self.fail(path, error)
            self.opener.close(listing_fd)
            return True
        stack.append((path, path_fd, listing_fd, iter(sorted(names))))
        try:
            while stack:
                parent_path, _parent_fd, parent_listing, pending = stack[-1]
                name = next(pending, None)
                if name is None:
                    stack.pop()
                    self.opener.close(parent_listing)
                    if _parent_fd != path_fd:
                        self.opener.close(_parent_fd)
                    continue
                child_path = parent_path.rstrip('/') + '/' + name
                try:
                    child_fd = self.opener.open(name, _FLAGS_PATH, dir_fd=parent_listing)
                except OSError as error:
                    self.fail(child_path, error)
                    continue
                try:
                    child_st = self.opener.fstat(child_fd)
                except OSError as error:
                    self.opener.close(child_fd)
                    self.fail(child_path, error)
                    continue
                if not self.label(child_path, child_fd, child_st):
                    self.opener.close(child_fd)
                    return False
                if not stat.S_ISDIR(child_st.st_mode):
                    self.opener.close(child_fd)
                    continue
                child_listing = self.open_listing(child_path, child_fd, child_st)
                if child_listing is None:
                    self.opener.close(child_fd)
                    continue
                try:
                    child_names = self.opener.listdir(child_listing)
                except OSError as error:
                    self.fail(child_path, error)
                    self.opener.close(child_listing)
                    self.opener.close(child_fd)
                    continue
                stack.append((child_path, child_fd, child_listing, iter(sorted(child_names))))
        finally:
            for _frame_path, frame_fd, frame_listing, _pending in stack:
                self.opener.close(frame_listing)
                if frame_fd != path_fd:
                    self.opener.close(frame_fd)
        return True


def walk(root, lookup, xattr, opener, report, dry_run=False):
    """Relabels the tree at root and returns the exit status.

    lookup(path, ifmt) returns the context (str) for a logical path and an S_IFMT mode, raising OSError (ENOENT for
    <<none>>). xattr.get(link) / xattr.set(link, value) read and write the context as bytes through a magic link.
    opener carries open, listdir, fstat, readlink and close with the os module's signatures. report(kind, text) takes
    'change' (a dry-run line, stdout) or 'error' (a diagnostic, stderr).
    """
    try:
        root_fd = opener.open(root, _FLAGS_PATH)
    except OSError as error:
        report('error', 'failed to open the root %s: %s' % (quote(root), _error_text(error)))
        return 1
    try:
        try:
            root_st = opener.fstat(root_fd)
            resolved = opener.readlink(_magic_link(root_fd))
        except OSError as error:
            report('error', 'failed to open the root %s: %s' % (quote(root), _error_text(error)))
            return 1
        if not stat.S_ISDIR(root_st.st_mode):
            report('error', 'failed to open the root %s: not a directory' % quote(root))
            return 1
        if resolved != root:
            report('error', 'failed to open the root %s: it resolves to %s' % (quote(root), quote(resolved)))
            return 1
        run = _Walk(lookup, xattr, opener, report, dry_run)
        if run.label(root, root_fd, root_st):
            completed = run.descend(root, root_fd, root_st)
        else:
            completed = False
    finally:
        opener.close(root_fd)
    if not completed:
        report('error', run.first_failure)
        return 1
    if run.failures:
        report('error', run.first_failure)
        report('error', '%d entries not labelled' % run.failures)
        return 1
    return 4 if run.hardlinks_left else 0


def _usage(message):
    sys.stderr.write('%s: %s\n%s\n' % (_PROGRAM, message, _USAGE))
    return 2


def parse_arguments(argv):
    """Returns (dry_run, expected_context, root), or an int exit status after printing the usage error."""
    dry_run, expected_context = False, None
    index = 0
    while index < len(argv) and argv[index] != '--':
        option = argv[index]
        if option == '--dry-run':
            dry_run = True
        elif option == '--expected-context':
            if index + 1 >= len(argv):
                return _usage('--expected-context takes a context')
            index += 1
            expected_context = argv[index]
        else:
            return _usage('unknown argument %s' % quote(option))
        index += 1
    if index >= len(argv):
        return _usage('the directory follows --')
    operands = argv[index + 1:]
    if len(operands) != 1:
        return _usage('one directory follows --')
    if expected_context is not None:
        if not dry_run:
            return _usage('--expected-context is accepted only with --dry-run')
        if not _CONTEXT_PATTERN.match(expected_context):
            return _usage('the context %s is not a SELinux context' % quote(expected_context))
    root = operands[0]
    if not root.startswith('/'):
        return _usage('the directory %s is not an absolute path' % quote(root))
    return dry_run, expected_context, root


def _report(kind, text):
    stream = sys.stdout if kind == 'change' else sys.stderr
    stream.write(text + '\n')
    stream.flush()


def _selinux_lookup():
    """Returns a lookup bound to one selabel handle, or an int exit status after the diagnostic.

    The lookup takes (path: str, ifmt: int) and returns the context as str; it raises OSError carrying
    selabel_lookup's errno, ENOENT for <<none>>. Its close() releases the handle.
    """
    try:
        library = ctypes.CDLL(_LIBSELINUX, use_errno=True)
        selabel_open, selabel_lookup = library.selabel_open, library.selabel_lookup
        selabel_close, freecon = library.selabel_close, library.freecon
    except (OSError, AttributeError) as error:
        sys.stderr.write('%s: %s does not load: %s\n' % (_PROGRAM, _LIBSELINUX, error))
        return 3
    selabel_open.restype = ctypes.c_void_p
    selabel_open.argtypes = [ctypes.c_uint, ctypes.c_void_p, ctypes.c_uint]
    selabel_lookup.restype = ctypes.c_int
    selabel_lookup.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p), ctypes.c_char_p, ctypes.c_int]
    selabel_close.restype = None
    selabel_close.argtypes = [ctypes.c_void_p]
    freecon.restype = None
    freecon.argtypes = [ctypes.c_void_p]
    handle = selabel_open(_SELABEL_CTX_FILE, None, 0)
    if not handle:
        sys.stderr.write('%s: failed to open the file-context database: %s\n'
                         % (_PROGRAM, os.strerror(ctypes.get_errno() or errno.EINVAL)))
        return 1

    def lookup(path, ifmt):
        context = ctypes.c_void_p()
        ctypes.set_errno(0)
        if selabel_lookup(handle, ctypes.byref(context), os.fsencode(path), ifmt) < 0:
            code = ctypes.get_errno() or errno.EINVAL
            raise OSError(code, os.strerror(code))
        try:
            return ctypes.string_at(context.value).decode('utf-8')
        finally:
            freecon(context)
    lookup.close = lambda: selabel_close(handle)
    return lookup


def main(argv=None):
    parsed = parse_arguments(sys.argv[1:] if argv is None else argv)
    if isinstance(parsed, int):
        return parsed
    dry_run, expected_context, root = parsed
    if expected_context is not None:
        def lookup(_path, _ifmt):
            return expected_context
        return walk(root, lookup, OS_XATTR, OS_OPENER, _report, dry_run=dry_run)
    lookup = _selinux_lookup()
    if isinstance(lookup, int):
        return lookup
    try:
        return walk(root, lookup, OS_XATTR, OS_OPENER, _report, dry_run=dry_run)
    finally:
        lookup.close()


if __name__ == '__main__':
    sys.exit(main())
