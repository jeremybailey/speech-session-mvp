#!/usr/bin/env python3
"""Keep source navigation on the shared StorySourceTag style."""
import re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
RULES = [
    (re.compile(r'\bDisclosureGroup\s*\(\s*"Sources?(?:\s*\(|")', re.I),
     "Use direct StorySourceTag links instead of source disclosure rows."),
    (re.compile(r'\bButton\s*\(\s*"Sources?(?:\s*\(|")', re.I),
     "Use StorySourceTag as the source button label."),
    (re.compile(r'\b(?:Text|Label)\s*\(\s*"Sources?\s*\(' , re.I),
     "Do not render a source-count label; use a named StorySourceTag."),
]
def violations(text):
    return [(text.count("\n", 0, m.start()) + 1, message)
            for pattern, message in RULES for m in pattern.finditer(text)]
def check(root=ROOT):
    errors = [f"{path.relative_to(root)}:{line}: {message}"
              for path in sorted((root / "SpeechSessionApp").rglob("*.swift"))
              for line, message in violations(path.read_text())]
    if errors:
        raise SystemExit("Source style lint failed:\n" + "\n".join(errors))
if __name__ == "__main__":
    check()
    print("Source style lint passed")
