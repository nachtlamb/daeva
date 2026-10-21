"""Minimal Valve KeyValues (text VDF/ACF) parser."""

import re

_TOKEN = re.compile(r'"((?:[^"\\]|\\.)*)"|([{}])|//[^\n]*|\s+')


def loads(text):
    stack = [{}]
    key = None
    for m in _TOKEN.finditer(text):
        s, brace = m.group(1), m.group(2)
        if brace == "{":
            d = {}
            stack[-1][key] = d
            stack.append(d)
            key = None
        elif brace == "}":
            stack.pop()
        elif s is not None:
            s = s.replace('\\"', '"').replace("\\\\", "\\")
            if key is None:
                key = s
            else:
                stack[-1][key] = s
                key = None
    return stack[0]


def load(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return loads(f.read())
