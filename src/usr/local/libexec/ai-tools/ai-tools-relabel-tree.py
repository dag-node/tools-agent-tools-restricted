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
# read it as a directory when it canonicalized it, so a file or a symlink there was placed after that read. After
# the walk it reads `/proc/self/fd/<fd>` again, and a name other than <dir>, a ` (deleted)` suffix among them, is
# reported with both names and exits 1. A walk therefore exits 0 only where <dir> named the walked tree from the open
# through the end of the walk; the walk ends at that read, so a rename after it is not a race on the walk.
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
# UTF-8 byte would otherwise stop the walk. A path the database maps to <<none>> is left as it is. An entry other than
# a directory with more than one link is not written, whatever its file type: through its other name it may be another
# project's or another operator's. It is listed on stderr when its label differs, and the walk exits 4.
#
# Exit status: 0 every entry labelled or already correct; 4 complete, with hardlinked paths left; 1 an entry could not
# be labelled (the first named on stderr, then the count), a read-back differing from the write (which ends the walk),
# a root check, or a root that moved during the walk, whatever the walk's own result; each of these past the opening
# root check ends stderr with one `summary hardlinks-left=<n> failures=<n>` line. stderr names at most the first 20 hardlinked paths, then how many it did not list, so its size
# does not grow with the tree; a caller reads the counts from the summary line, which no escaped path can begin, since
# the escaping leaves no newline in a path; 2 usage; 3 libselinux.so.1 does not load or lacks a function the lookup
# calls. A real run prints nothing on stdout. `--dry-run` writes nothing and prints `<path> <from> <to>` for each entry
# it would write, `-` for no current label; `--expected-context` replaces the lookup with <ctx> there and does not load
# libselinux. Every path printed is escaped to printable ASCII in bash `printf %q` form, since a name in the tree is
# the account's.
#
# relabel_tree() takes its collaborators as parameters, so tests/unit/relabel-tree-harness.py imports this file by path
# and drives it with fakes; main() binds the real ones. Installed 0750 root:root as ai-tools-relabel-tree. Its domain
# rule is cli.rule.md.

import ctypes
import errno
import os
import re
import stat
import sys
import types

_PROGRAM = 'ai-tools-relabel-tree'
_HARDLINKS_LISTED = 20
_LIBSELINUX = 'libselinux.so.1'
_SELABEL_CTX_FILE = 0
_XATTR = 'security.selinux'
_PATH_OPEN_FLAGS = os.O_PATH | os.O_NOFOLLOW | os.O_CLOEXEC
_LISTING_OPEN_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
_NO_LABEL_ERRNOS = (errno.ENODATA, errno.ENOTSUP)
_USAGE = 'usage: %s [--dry-run [--expected-context <ctx>]] -- <dir>' % _PROGRAM
# A context is printed and compared, never parsed; the allowlist covers user:role:type:range with an MLS range.
_CONTEXT_PATTERN = re.compile(r'[A-Za-z0-9_.:,-]+\Z')
# The bytes bash `printf %q` leaves unquoted.
_SHELL_UNQUOTED_BYTES = frozenset(b'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_./-+:,@%=^')

OS_FILE_OPERATIONS = types.SimpleNamespace(open=os.open, listdir=os.listdir, fstat=os.fstat, readlink=os.readlink,
                                  close=os.close)
OS_EXTENDED_ATTRIBUTES = types.SimpleNamespace(get=lambda link: os.getxattr(link, _XATTR),
                                 set=lambda link, value: os.setxattr(link, _XATTR, value))


def format_shell_quoted(text):
    """Returns text (str, surrogateescape for undecodable bytes) as printable ASCII in bash `printf %q` form."""
    raw = os.fsencode(text)
    if not raw:
        return "''"
    if all(0x20 < byte < 0x7f for byte in raw):
        return ''.join(chr(byte) if byte in _SHELL_UNQUOTED_BYTES else '\\' + chr(byte) for byte in raw)
    escaped = []
    for byte in raw:
        if byte in (0x27, 0x5c):
            escaped.append('\\' + chr(byte))
        elif 0x20 <= byte < 0x7f:
            escaped.append(chr(byte))
        else:
            escaped.append('\\x%02x' % byte)
    return "$'" + ''.join(escaped) + "'"


def _get_proc_fd_path(fd):
    return '/proc/self/fd/%d' % fd


def _read_file_context(xattr, fd):
    """Returns the entry's context as bytes without a trailing NUL, or None for no label; raises OSError otherwise."""
    try:
        value = xattr.get(_get_proc_fd_path(fd))
    except OSError as error:
        if error.errno in _NO_LABEL_ERRNOS:
            return None
        raise
    return value[:-1] if value.endswith(b'\0') else value


def _format_error(error):
    if isinstance(error, OSError) and error.errno:
        return os.strerror(error.errno)
    return str(error) or type(error).__name__


class _RelabelRun:
    """The state of one run: the first failure, the failure count, and the hardlinked paths left."""

    def __init__(self, lookup, xattr, opener, report, dry_run):
        self.lookup, self.xattr, self.opener, self.report, self.dry_run = lookup, xattr, opener, report, dry_run
        self.first_failure = None
        self.failures = 0
        self.hardlinks_left = 0

    def record_failure(self, path, error):
        self.failures += 1
        if self.first_failure is None:
            self.first_failure = 'failed to restore the file context of %s: %s' % (
                format_shell_quoted(path), _format_error(error))

    def relabel_entry(self, path, fd, entry_stat):
        """Labels one entry; returns False when a read-back differs from the write, which ends the walk."""
        try:
            context = self.lookup(path, stat.S_IFMT(entry_stat.st_mode))
        except OSError as error:
            if error.errno == errno.ENOENT:
                return True
            self.record_failure(path, error)
            return True
        except Exception as error:  # recorded as the entry's failure; the walk goes on
            self.record_failure(path, error)
            return True
        wanted = context.encode('utf-8')
        try:
            current = _read_file_context(self.xattr, fd)
        except OSError as error:
            self.record_failure(path, error)
            return True
        if current == wanted:
            return True
        if not stat.S_ISDIR(entry_stat.st_mode) and entry_stat.st_nlink > 1:
            self.hardlinks_left += 1
            if self.hardlinks_left <= _HARDLINKS_LISTED:
                self.report('error', 'skipped hardlinked path %s (link count %d)'
                            % (format_shell_quoted(path), entry_stat.st_nlink))
            return True
        if self.dry_run:
            shown = '-' if current is None else format_shell_quoted(current.decode('utf-8', 'surrogateescape'))
            self.report('change', '%s %s %s' % (format_shell_quoted(path), shown, format_shell_quoted(context)))
            return True
        try:
            self.xattr.set(_get_proc_fd_path(fd), wanted)
        except OSError as error:
            self.record_failure(path, error)
            return True
        try:
            readback = _read_file_context(self.xattr, fd)
        except OSError as error:
            readback = ('unreadable: %s' % _format_error(error)).encode()
        if readback != wanted:
            shown = '-' if readback is None else format_shell_quoted(readback.decode('utf-8', 'surrogateescape'))
            self.first_failure = 'failed to restore the file context of %s: read back %s after writing %s' % (
                format_shell_quoted(path), shown, format_shell_quoted(context))
            self.failures += 1
            return False
        return True

    def open_directory_listing(self, path, path_fd, entry_stat):
        """Returns a listing descriptor naming the same inode as path_fd, or None after recording the failure."""
        try:
            listing_fd = self.opener.open('.', _LISTING_OPEN_FLAGS, dir_fd=path_fd)
        except OSError as error:
            self.record_failure(path, error)
            return None
        try:
            listing_stat = self.opener.fstat(listing_fd)
        except OSError as error:
            self.opener.close(listing_fd)
            self.record_failure(path, error)
            return None
        if (listing_stat.st_dev, listing_stat.st_ino) != (entry_stat.st_dev, entry_stat.st_ino):
            self.opener.close(listing_fd)
            self.record_failure(path, OSError(errno.ESTALE, 'the directory was replaced between its two opens'))
            return None
        return listing_fd

    def relabel_descendants(self, path, path_fd, entry_stat):
        """Walks the directory at path_fd depth-first; returns False when the walk has ended."""
        listing_fd = self.open_directory_listing(path, path_fd, entry_stat)
        if listing_fd is None:
            return True
        # Each frame is a directory's (logical path, path fd, listing fd, names still to open).
        stack = []
        try:
            names = self.opener.listdir(listing_fd)
        except OSError as error:
            self.record_failure(path, error)
            self.opener.close(listing_fd)
            return True
        stack.append((path, path_fd, listing_fd, iter(sorted(names))))
        try:
            while stack:
                parent_path, parent_path_fd, parent_listing, remaining_names = stack[-1]
                name = next(remaining_names, None)
                if name is None:
                    stack.pop()
                    self.opener.close(parent_listing)
                    if parent_path_fd != path_fd:
                        self.opener.close(parent_path_fd)
                    continue
                child_path = parent_path.rstrip('/') + '/' + name
                try:
                    child_fd = self.opener.open(name, _PATH_OPEN_FLAGS, dir_fd=parent_listing)
                except OSError as error:
                    self.record_failure(child_path, error)
                    continue
                try:
                    child_stat = self.opener.fstat(child_fd)
                except OSError as error:
                    self.opener.close(child_fd)
                    self.record_failure(child_path, error)
                    continue
                if not self.relabel_entry(child_path, child_fd, child_stat):
                    self.opener.close(child_fd)
                    return False
                if not stat.S_ISDIR(child_stat.st_mode):
                    self.opener.close(child_fd)
                    continue
                child_listing = self.open_directory_listing(child_path, child_fd, child_stat)
                if child_listing is None:
                    self.opener.close(child_fd)
                    continue
                try:
                    child_names = self.opener.listdir(child_listing)
                except OSError as error:
                    self.record_failure(child_path, error)
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


def relabel_tree(root, lookup, xattr, opener, report, dry_run=False):
    """Relabels the tree at root and returns the exit status.

    lookup(path, ifmt) returns the context (str) for a logical path and an S_IFMT mode, raising OSError (ENOENT for
    <<none>>). xattr.get(link) / xattr.set(link, value) read and write the context as bytes through a magic link.
    opener carries open, listdir, fstat, readlink and close with the os module's signatures. report(kind, text) takes
    'change' (a dry-run line, stdout) or 'error' (a diagnostic, stderr).
    """
    try:
        root_fd = opener.open(root, _PATH_OPEN_FLAGS)
    except OSError as error:
        report('error', 'failed to open the root %s: %s' % (format_shell_quoted(root), _format_error(error)))
        return 1
    try:
        try:
            root_stat = opener.fstat(root_fd)
            resolved = opener.readlink(_get_proc_fd_path(root_fd))
        except OSError as error:
            report('error', 'failed to open the root %s: %s' % (format_shell_quoted(root), _format_error(error)))
            return 1
        if not stat.S_ISDIR(root_stat.st_mode):
            report('error', 'failed to open the root %s: not a directory' % format_shell_quoted(root))
            return 1
        if resolved != root:
            report('error', 'failed to open the root %s: it resolves to %s'
                   % (format_shell_quoted(root), format_shell_quoted(resolved)))
            return 1
        run = _RelabelRun(lookup, xattr, opener, report, dry_run)
        if run.relabel_entry(root, root_fd, root_stat):
            completed = run.relabel_descendants(root, root_fd, root_stat)
        else:
            completed = False
        root_moved = None
        try:
            closing = opener.readlink(_get_proc_fd_path(root_fd))
        except OSError as error:
            root_moved = 'failed to read the root %s again after the walk: %s' % (
                format_shell_quoted(root), _format_error(error))
        else:
            if closing != root:
                root_moved = 'the root %s moved during the walk: the walked tree is now %s' % (
                    format_shell_quoted(root), format_shell_quoted(closing))
    finally:
        opener.close(root_fd)
    if run.hardlinks_left > _HARDLINKS_LISTED:
        report('error', '%d more hardlinked paths skipped, not listed' % (run.hardlinks_left - _HARDLINKS_LISTED))
    status = 0
    if not completed:
        report('error', run.first_failure)
        status = 1
    elif run.failures:
        report('error', run.first_failure)
        report('error', '%d entries not labelled' % run.failures)
        status = 1
    elif run.hardlinks_left:
        status = 4
    if root_moved is not None:
        report('error', root_moved)
        status = 1
    if status:
        report('error', 'summary hardlinks-left=%d failures=%d' % (run.hardlinks_left, run.failures))
    return status


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
            return _usage('unknown argument %s' % format_shell_quoted(option))
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
            return _usage('the context %s is not a SELinux context' % format_shell_quoted(expected_context))
    root = operands[0]
    if not root.startswith('/'):
        return _usage('the directory %s is not an absolute path' % format_shell_quoted(root))
    return dry_run, expected_context, root


def _write_report(kind, text):
    stream = sys.stdout if kind == 'change' else sys.stderr
    stream.write(text + '\n')
    stream.flush()


def _open_file_context_lookup():
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
        return relabel_tree(root, lookup, OS_EXTENDED_ATTRIBUTES, OS_FILE_OPERATIONS, _write_report, dry_run=dry_run)
    lookup = _open_file_context_lookup()
    if isinstance(lookup, int):
        return lookup
    try:
        return relabel_tree(root, lookup, OS_EXTENDED_ATTRIBUTES, OS_FILE_OPERATIONS, _write_report, dry_run=dry_run)
    finally:
        lookup.close()


if __name__ == '__main__':
    sys.exit(main())
