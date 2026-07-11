#!/usr/bin/env python3
# /usr/local/bin/ai-tools-handback-client
# Client for the ai-tools handback privilege bridge.
#
# Usage: ai-tools-handback-client VERB ARG
#
# Connects to /run/ai-tools/handback.sock (AF_UNIX SOCK_STREAM), sends one
# "VERB ARG\n" request, reads the response, relays MSG lines to stderr (so the
# calling hook can surface NOTICEs in the Claude Code session), and exits 0 on
# OK or 1 on ERR/error.
#
# Replaces `sudo ai-tools-{chown,setgid,claude-symlink}` everywhere it was
# called from the agent process tree.  Those sudo calls fail silently under NNP
# (PR_SET_NO_NEW_PRIVS, forced by RestrictNamespaces=yes in the session service
# unit) because NNP drops the SUID bit on sudo, leaving it running as
# @SANDBOX_USER@ instead of root -- unable to read /etc/sudoers or switch UID.
# This client avoids SUID entirely: it connects a socket that only root and
# @SANDBOX_GROUP@ members can reach (0660 SocketGroup=@SANDBOX_GROUP@), and the
# daemon authenticates the connection via SO_PEERCRED.
#
# Deploy: install.sh deploys src/usr/local/bin/ai-tools-handback-client.py
# to /usr/local/bin/ai-tools-handback-client (750 root:@SANDBOX_GROUP@,
# @SANDBOX_GROUP@ substituted by install_subst).

import socket
import sys

_SOCK_PATH = '/run/ai-tools/handback.sock'


def main():
    if len(sys.argv) != 3:
        sys.stderr.write('usage: %s VERB ARG\n' % sys.argv[0])
        sys.exit(1)

    verb = sys.argv[1].upper()
    arg = sys.argv[2]

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            try:
                sock.connect(_SOCK_PATH)
            except OSError as exc:
                # Name the socket and the likely cause: a bare "[Errno 2] No such file
                # or directory" from connect() gives the caller nothing to act on.
                sys.stderr.write(
                    'ai-tools-handback-client: cannot reach the handback socket %s '
                    '(%s) -- is ai-tools-handback.socket running?\n'
                    % (_SOCK_PATH, exc)
                )
                sys.exit(1)
            sock.sendall(('%s %s\n' % (verb, arg)).encode('utf-8'))
            # Read the response line by line.  sock.makefile() wraps the socket in a
            # buffered text reader; closing it does NOT close the underlying socket
            # (Python documented behaviour), which is then closed by the with block.
            with sock.makefile('r', encoding='utf-8', errors='replace') as sf:
                for line in sf:
                    line = line.rstrip('\n')
                    if line.startswith('MSG '):
                        # Relay helper stderr (NOTICEs, warnings) to our stderr so
                        # the hook surfaces them in the Claude Code session.
                        sys.stderr.write(line[4:] + '\n')
                    elif line == 'OK':
                        sys.exit(0)
                    elif line.startswith('ERR'):
                        reason = line[4:] if len(line) > 4 else '(no reason)'
                        sys.stderr.write(
                            'ai-tools-handback-client: %s\n' % reason
                        )
                        sys.exit(1)
    except OSError as exc:
        sys.stderr.write('ai-tools-handback-client: %s\n' % exc)
        sys.exit(1)

    # Fell through with no OK or ERR -- daemon closed the connection without a
    # terminal response (crash, protocol error).
    sys.stderr.write('ai-tools-handback-client: incomplete response\n')
    sys.exit(1)


if __name__ == '__main__':
    main()
