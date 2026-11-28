# Runs on beast-arch: python3 devprog.py OUTDIR (chief-sweep copies it there; station-maintenance fleet 53).
# Feeds Ben's dev-progress dashboard (https://claude.ai/artifact/Tx1dPdoPrGB2kZ333zrvi8). Progress of each BMAD development repo, as JSON on stdout. Read-only.
SRC = open(__file__).read()
import json, os, re, subprocess, collections, glob
import yaml, sys
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp"
P = os.path.expanduser("~/projects")
REPOS = ["castiron", "dungeon-smash", "nihongo-smash", "confluence-consist", "keybind-find-meta", "trstn-meta"]
STORY = re.compile(r"^\d+\.\d+")
NORM = {"done": "done", "completed": "done", "complete": "done", "review": "review", "in-review": "review",
        "in-progress": "in progress", "in_progress": "in progress", "ready-for-dev": "ready", "ready_for_dev": "ready",
        "ready": "ready", "drafted": "backlog", "draft": "backlog", "backlog": "backlog", "todo": "backlog",
        "deferred": "deferred", "blocked": "blocked", "cancelled": "dropped", "canceled": "dropped", "dropped": "dropped",
        "superseded": "dropped", "optional": "deferred"}
def norm(s):
    s = str(s).strip().lower().split()[0] if str(s).strip() else "?"
    return NORM.get(s, s)
def stories(doc):
    out = {}
    def walk(o):
        if isinstance(o, dict):
            sid = o.get("id") or o.get("key") or o.get("story")
            if sid and "status" in o and STORY.match(str(sid)):
                out[str(sid)] = (norm(o["status"]), o.get("title") or str(sid))
            for k, v in o.items():
                if isinstance(v, str) and STORY.match(str(k)) and k not in out:   # development_status: {"1-2-x": status}
                    out[str(k)] = (norm(v), str(k))
                walk(v)
        elif isinstance(o, list):
            for i in o: walk(i)
    walk(doc)
    return out
res = []
for r in REPOS:
    d = os.path.join(P, r)
    f = (glob.glob(d + "/bmad-output/sprint-status.yaml") + glob.glob(d + "/_bmad-output/*/sprint-status.yaml"))
    st = {}
    if f:
        try: st = stories(yaml.safe_load(open(f[0])))
        except Exception as e: st = {}
    if not st and f:   # dev_status keys like 1-2-slug
        try:
            doc = yaml.safe_load(open(f[0]))
            ds = doc.get("development_status", {}) if isinstance(doc, dict) else {}
            st = {k: (norm(v), k) for k, v in ds.items() if re.match(r"^\d+-\d+", str(k))}
        except Exception: pass
    c = collections.Counter(s for s, _ in st.values())
    g = lambda *a: subprocess.run(["git", "-C", d] + list(a), capture_output=True, text=True).stdout
    days = collections.Counter(g("log", "--since=14.days", "--format=%cs").split())
    last = g("log", "-1", "--format=%cs %cr|%s").strip()
    done_recent = [t for s, t in st.values() if s == "done"]
    res.append({"repo": r, "status_file": f[0].replace(P + "/", "") if f else None, "counts": dict(c),
                "total": sum(c.values()), "commits_14d": dict(sorted(days.items())), "last_commit": last,
                "in_progress": [t for s, t in st.values() if s in ("in progress", "review")][:6]})
# herdr: each repo's agent status
try:
    al = json.loads(subprocess.run([os.path.expanduser("~/.local/bin/herdr"), "agent", "list"], capture_output=True, text=True).stdout)["result"]["agents"]
except Exception:
    al = []
ast = {}
for a in al:
    if a.get("agent") == "muse": continue
    ast.setdefault(os.path.basename(a.get("cwd", "")), a.get("agent_status"))
import datetime
today = datetime.date.today()
rows, act = [], []
for r in res:
    c = r["counts"]; t = r["total"] or 0
    d, ago, msg = (r["last_commit"].split(" ", 1)[0], r["last_commit"].split(" ", 1)[1].split("|")[0], r["last_commit"].split("|", 1)[1]) if r["last_commit"] else ("", "", "")
    rows.append({"repo": r["repo"], "agent": ast.get(r["repo"], "none"), "stories": t,
                 "done": c.get("done", 0), "review": c.get("review", 0), "in_progress": c.get("in progress", 0),
                 "ready": c.get("ready", 0), "backlog": c.get("backlog", 0), "deferred": c.get("deferred", 0) + c.get("blocked", 0),
                 "dropped": c.get("dropped", 0),
                 "pct_done": round(100 * c.get("done", 0) / max(1, t - c.get("dropped", 0)), 1),
                 "commits_14d": sum(r["commits_14d"].values()), "last_commit": d, "last_commit_ago": ago,
                 "last_commit_subject": msg[:120], "now": " / ".join(r["in_progress"])[:300], "status_file": r["status_file"] or ""})
    for i in range(13, -1, -1):
        day = (today - datetime.timedelta(days=i)).isoformat()
        act.append({"repo": r["repo"], "day": day, "commits": r["commits_14d"].get(day, 0)})
meta = [{"label": "devprog.py", "value": SRC, "type": "code", "lang": "python"},
        {"label": "Read", "value": "beast-arch ~/projects/<repo>: sprint-status.yaml, git log, herdr agent list"},
        {"label": "At", "value": datetime.datetime.now().isoformat(timespec="minutes")}]
json.dump({"rows": rows, "meta": meta}, open(os.path.join(OUT, "devprog-repos.json"), "w"))
json.dump({"rows": act, "meta": meta}, open(os.path.join(OUT, "devprog-activity.json"), "w"))
print(len(rows), len(act))
