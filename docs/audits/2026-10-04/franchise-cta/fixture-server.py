"""Isolated, in-memory CTA walkthrough. Run with python3; listens only on 127.0.0.1:8809.
No DB, upstream calls, account data or credentials. GET /_state records actual app writes.
POST /_reset restores fixtures; /_fail-next-detail exercises Retry without changing the app.
"""
import copy
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

NOW = int(time.time() * 1000)
DAY = 86400000
LOCK = threading.RLock()

def show(fid, name, start, counts, airing=False, upcoming=False, status=None, progress=0):
    parts = []
    for i, total in enumerate(counts):
        part = dict(mediaId=start+i, kind="season", sequence=i+1, label=f"Season {i+1}",
                    title=f"Season {i+1}", format="TV", isReleasing=airing,
                    status="NOT_YET_RELEASED" if upcoming else "RELEASING" if airing else "FINISHED",
                    totalEpisodes=total, airedEpisodes=0 if upcoming else 8 if airing else total,
                    progress=progress if i == 0 else 0, year=2026, genres=["Adventure"],
                    episodes=[dict(number=n, title=f"Episode {n}") for n in range(1, total+1)],
                    airings=[dict(episode=8, at=NOW-DAY), dict(episode=9, at=NOW+DAY)] if airing else [])
        if airing: part.update(nextEpisodeNumber=9, nextAiringAt=NOW+DAY, lastAiredAt=NOW-DAY)
        parts.append(part)
    value = dict(id=fid, title=name, source="anilist", parts=parts, year=2026, isReleasing=airing,
                 genres=["Adventure"], studios=["Fixture studio"], newParts=0,
                 synopsis="An isolated test show for the shared library actions.")
    if status: value.update(status=status, subscription=dict(status=status, addedAt=NOW-30*DAY))
    return value

INITIAL = {
    f["id"]: f for f in [
        show("cta-watching", "CTA Watching", 10000, [12, 8], status="watching", progress=3),
        show("cta-finished", "CTA Finished", 10100, [12, 8]),
        show("cta-airing", "CTA Airing", 10200, [12], airing=True),
        show("cta-upcoming", "CTA Upcoming", 10300, [12], upcoming=True),
        show("cta-recommended", "CTA Recommended", 10400, [12, 8]),
    ]
}
SHOWS = copy.deepcopy(INITIAL)
WRITES = []
FAIL_DETAIL = False

def library():
    return [f for f in SHOWS.values() if f.get("subscription")]

class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)

    def handle_request(self):
        global FAIL_DETAIL
        path = urlparse(self.path).path
        query = parse_qs(urlparse(self.path).query)
        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        code, body = 200, {"ok": True}
        with LOCK:
            if path == "/_reset" and self.command == "POST":
                SHOWS.clear(); SHOWS.update(copy.deepcopy(INITIAL)); WRITES.clear(); FAIL_DETAIL = False
            elif path == "/_fail-next-detail" and self.command == "POST": FAIL_DETAIL = True
            elif path == "/_state": body = dict(writes=WRITES, library=library())
            elif path == "/me/library": body = dict(franchises=library(), prevOpenedAt=NOW-3*DAY)
            elif path == "/me/opened": body = dict(prevOpenedAt=NOW-3*DAY)
            elif path == "/me/preferences": body = dict(audience="both")
            elif path == "/me/recommendations":
                f = SHOWS["cta-recommended"]
                body = dict(items=[dict(key="anilist:10400", franchiseId=f["id"], title=f["title"],
                             source="anilist", externalId=10400, episodes=20, airing=False,
                             reason=dict(kind="watching", count=1, seeds=[dict(franchiseId="cta-watching", title="CTA Watching")]))], generatedAt=NOW)
            elif path == "/me/feed":
                post = dict(id="news:cta", franchiseId="cta-finished", kind="dated", origin="catalogue",
                            installment="Season 3", fresh=True, discoveredAt=NOW,
                            time=dict(at=NOW, dateOnly=False, basis="catalogue"),
                            premiere=dict(at=NOW+30*DAY, precision="exact"), sources=[], viewer={}, counts={})
                body = dict(tab=query.get("tab", ["following"])[0], generatedAt=NOW, prevOpenedAt=NOW-3*DAY,
                            capabilities=dict(comments=False), franchises=list(SHOWS.values()), posts=[post], trending=list(SHOWS.values()))
            elif path == "/me/profile":
                body = dict(userId="cta-fixture", handle=None, displayName=None, currentTermsVersion="fixture", canComment=False)
            elif path == "/me/subscriptions" and self.command == "POST":
                f = SHOWS[payload["franchiseId"]]
                f.update(status=payload["status"], subscription=dict(status=payload["status"], addedAt=NOW))
                WRITES.append(dict(method=self.command, path=path, body=payload))
            elif path.startswith("/me/subscriptions/"):
                f = SHOWS[path.split("/")[3]]
                if self.command == "DELETE": f.pop("subscription", None); f.pop("status", None)
                else: f.update(status=payload["status"], subscription=dict(status=payload["status"], addedAt=NOW))
                WRITES.append(dict(method=self.command, path=path, body=payload))
            elif path.startswith("/me/franchises/") and path.endswith("/progress"):
                f = SHOWS[path.split("/")[3]]
                for value in payload["parts"]:
                    next(p for p in f["parts"] if p["mediaId"] == value["mediaId"])["progress"] = value["episodes"]
                status = payload.get("status") or "watching"
                f.update(status=status, subscription=dict(status=status, addedAt=NOW))
                body = dict(ok=True, franchiseId=f["id"], status=status, progress=[dict(mediaId=p["mediaId"], episodes=p["progress"]) for p in f["parts"]])
                WRITES.append(dict(method=self.command, path=path, body=payload))
            elif path == "/me/progress" and self.command == "PUT":
                for f in SHOWS.values():
                    for p in f["parts"]:
                        if p["mediaId"] == payload["mediaId"]: p["progress"] = payload["episodes"]
                WRITES.append(dict(method=self.command, path=path, body=payload))
            elif path in ["/search", "/franchises/trending"] or path.startswith("/discover/genres/"):
                body = dict(franchises=list(SHOWS.values()), sources=dict(anilist="ok", tmdb="ok"))
            elif path == "/discover/genres": body = dict(genres=[], generatedAt=NOW)
            elif path.startswith("/franchises/"):
                if path.endswith("/watch-providers"): body = dict(status="unavailable", country="IN", providers=[], link=None)
                elif FAIL_DETAIL:
                    FAIL_DETAIL = False
                    code, body = 503, dict(error="Fixture detail failure")
                else: body = SHOWS.get(path.split("/")[2], SHOWS["cta-finished"])
            elif path.startswith("/me/"): body = dict(items=[], franchises=[], unread=0)
            else: code, body = 404, dict(error="Fixture route not implemented")
            data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = handle_request

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8809), Handler).serve_forever()
