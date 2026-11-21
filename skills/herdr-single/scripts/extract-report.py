#!/usr/bin/env python3
"""Extract the last final-report block from an agent transcript on stdin.

The block starts at the last "STATUS:" line. FINDINGS may continue over several
paragraphs (Codex separates numbered items with blank lines), so the block ends at the
agent's own UI (a "Worked for" footer, an input prompt, a rule or a tip) or after two
consecutive blank lines, not at the first blank line."""
import re
import sys


PREFIX_MARKS = "•⏺●○◦▪‣-*>│┃╎┆┊"
UI = re.compile(r"^\s*(Worked for |›|> ?$|\? for shortcuts|└ Tip|Tip:|[─━═]{6,}|✻ |⎿ )")


def clean(line: str) -> str:
    line = line.lstrip()
    while line and line[0] in PREFIX_MARKS:
        line = line[1:].lstrip()
    return line


def extract(transcript: str) -> str:
    lines = transcript.splitlines()
    starts = [i for i, line in enumerate(lines)
              if clean(line).startswith("STATUS:") and "|" not in clean(line)]
    if not starts:
        return ""
    block = lines[starts[-1]:starts[-1] + 120]
    block[0] = clean(block[0])  # only the STATUS line loses its marker; later lines keep their bullets
    out, blanks, in_findings = [], 0, False
    for line in block:
        if out and UI.match(line):
            break
        if not line.strip():
            blanks += 1
            # Before FINDINGS a blank line ends the block; inside FINDINGS only two do.
            if not in_findings or blanks >= 2:
                break
            continue
        if blanks and out:
            out.append("")
        blanks = 0
        if clean(line).startswith("FINDINGS:"):
            # A findings list may span paragraphs; only "none" ends at the next blank line.
            in_findings = clean(line)[len("FINDINGS:"):].strip().rstrip(".").lower() != "none"
        out.append(line)
    return "\n".join(out).rstrip()


if __name__ == "__main__":
    print(extract(sys.stdin.read()))
