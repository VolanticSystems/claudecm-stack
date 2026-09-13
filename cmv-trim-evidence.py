"""Did CMV auto-trim shrink records in place, or is the file simply small?

Compares a cmv auto-backup against the live transcript record by record, keyed
on uuid, and reports every record whose serialised length went DOWN. A record
that shrank was rewritten after the backup was taken, which is what in-place
trimming looks like from outside cmv.

    python cmv-trim-evidence.py <backup.jsonl> <live.jsonl>
"""
import io
import json
import sys


def index(path):
    out = {}
    for line in io.open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except Exception:
            continue
        u = r.get("uuid")
        if u:
            out[u] = (len(line), r)
    return out


old = index(sys.argv[1])
new = index(sys.argv[2])
shared = set(old) & set(new)
shrank = [(u, old[u][0], new[u][0]) for u in shared if new[u][0] < old[u][0]]
grew = [u for u in shared if new[u][0] > old[u][0]]

print("records in backup %d, in live %d, shared %d" % (len(old), len(new), len(shared)))
print("shared records that SHRANK : %d" % len(shrank))
print("shared records that GREW   : %d" % len(grew))
if shrank:
    saved = sum(a - b for _, a, b in shrank)
    print("bytes removed from shared records: %d" % saved)
    shrank.sort(key=lambda t: t[1] - t[2], reverse=True)
    for u, a, b in shrank[:5]:
        r = new[u][1]
        msg = r.get("message") or {}
        content = msg.get("content")
        text = ""
        if isinstance(content, list) and content:
            c = content[0]
            if isinstance(c, dict):
                text = json.dumps(c)[:200]
        elif isinstance(content, str):
            text = content[:200]
        print("")
        print("  %s  %d -> %d bytes  type=%s" % (u[:8], a, b, r.get("type")))
        print("  now: %s" % " ".join(text.split())[:180])
