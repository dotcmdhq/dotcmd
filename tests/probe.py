"""CI-only child process: validate arguments and return a distinctive exit code."""
import sys

expected = ["two words", "plain"]
if sys.argv[1:] != expected:
    print(f"Expected {expected!r}, got {sys.argv[1:]!r}", file=sys.stderr)
    sys.exit(1)
print("arguments: OK")
sys.exit(37)
