"""Compare the three copies of the launcher payload protocol.

The same "read a base64 payload from stdin, enforce a character ceiling, call
agentq-launcher.ps1 -ArgumentsBase64" logic exists three times: in the launcher
itself, in the Windows client, and inside the POSIX client (compressed to one
line and embedded in a base64 -EncodedCommand wrapper).  Same shape as the two
canonical agentq-server copies, same risk.

Compared as token sequences, not bytes: the POSIX copy is one line joined with
`;`, the Windows copy is indented, so a byte comparison is red on correct code.
"""
import re
import sys


def tokens(text):
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace() or c == ';':
            i += 1
            continue
        if c == '#':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c in '"\'':
            j = i + 1
            while j < n and text[j] != c:
                j += 1
            out.append(text[i:j + 1])
            i = j + 1
            continue
        j = i
        while j < n and not text[j].isspace() and text[j] not in '"\';#':
            j += 1
        out.append(text[i:j])
        i = j
    return out


def main(launcher_path, client_path, posix_path):
    launcher = open(launcher_path, encoding='utf-8').read()
    client = open(client_path, encoding='utf-8').read()
    posix = open(posix_path, encoding='utf-8').read()

    problems = []

    m = re.search(r"\$launcherWrapper = @'\n(.*?)\n'@", client, re.S)
    client_wrapper = m.group(1) if m else None
    if client_wrapper is None:
        problems.append("client agentq.ps1: $launcherWrapper here-string not found")

    m = re.search(r"windows_launcher_wrapper='(.*?)'\n", posix, re.S)
    posix_wrapper = m.group(1) if m else None
    if posix_wrapper is None:
        problems.append("POSIX client: windows_launcher_wrapper assignment not found")

    m = re.search(r'\[int\]\$MaximumCharacters\s*=\s*(\d+)', launcher)
    launcher_ceiling = m.group(1) if m else None
    if launcher_ceiling is None:
        problems.append(
            "launcher: Read-AgentQBoundedText no longer declares a default -MaximumCharacters")

    for label, text in (("client agentq.ps1", client_wrapper), ("POSIX client", posix_wrapper)):
        if text is None:
            continue
        found = re.findall(r'\$maximum\w*[Cc]haracters\s*=\s*(\d+)', text)
        if not found:
            problems.append("%s: embedded wrapper declares no payload character ceiling" % label)
        elif launcher_ceiling is not None and found[0] != launcher_ceiling:
            problems.append("%s: embedded wrapper ceiling is %s but the launcher enforces %s"
                            % (label, found[0], launcher_ceiling))

    if client_wrapper is not None and posix_wrapper is not None:
        a, b = tokens(client_wrapper), tokens(posix_wrapper)
        if a != b:
            problems.append("the Windows and POSIX embedded launcher wrappers have diverged")

    for p in problems:
        print(p)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:4]))
