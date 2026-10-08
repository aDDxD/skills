#!/usr/bin/env python3
"""Extract the last final-report block from an agent transcript on stdin."""
import sys


PREFIX_MARKS = "•⏺●○◦▪‣-*>│┃╎┆┊"


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
    block = lines[starts[-1]:starts[-1] + 40]
    block[0] = clean(block[0])  # only the STATUS line loses its marker; later lines keep their bullets
    return "\n".join(block)


if __name__ == "__main__":
    print(extract(sys.stdin.read()))
