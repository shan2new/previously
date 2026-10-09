"""Anonymous qualification of the exact effective-policy artifact, without browser automation."""
import concurrent.futures
import datetime
import hashlib
import html.parser
import json
from pathlib import Path
import sys
import urllib.error
import urllib.request

ROOT = Path('/Users/shan2new/Projects/previously')
EVIDENCE = ROOT / 'docs/qa/2026-10-06/landing-final/effective-publication'
ORIGIN, LABEL = sys.argv[1:3]
CANONICAL = 'https://previously.cognipin.com'
manifest = json.loads((EVIDENCE / 'source-manifest.json').read_text())['files']
provenance = json.loads((ROOT / 'docs/qa/2026-10-06/branding/publication/asset-provenance.json').read_text())


class Document(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.text, self.canonical, self.robots, self.links, self.ids, self.external_scripts = [], [], [], [], [], []
        self.h1, self.hidden = 0, 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ('script', 'style'): self.hidden += 1
        if tag == 'h1': self.h1 += 1
        if attrs.get('id'): self.ids.append(attrs['id'])
        if tag == 'a': self.links.append(attrs.get('href', ''))
        if tag == 'script' and attrs.get('src', '').startswith(('https:', 'http:', '//')): self.external_scripts.append(attrs['src'])
        if tag == 'link' and attrs.get('rel') == 'canonical': self.canonical.append(attrs.get('href'))
        if tag == 'meta' and attrs.get('name') == 'robots': self.robots.append(attrs.get('content'))

    def handle_endtag(self, tag):
        if tag in ('script', 'style'): self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden: self.text.append(data)

    def visible_text(self):
        return ' '.join(' '.join(self.text).split())


def read(path):
    req = urllib.request.Request(ORIGIN + path, headers={'User-Agent': 'Previously-release-qualification/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            return response.status, dict(response.headers), response.read(), response.url
    except urllib.error.HTTPError as response:
        return response.code, dict(response.headers), response.read(), response.url


failures, routes = [], []
pages = ['/', '/privacy', '/terms', '/support', '/delete-account']
security = {'x-content-type-options': 'nosniff', 'referrer-policy': 'strict-origin-when-cross-origin', 'permissions-policy': 'camera=(), microphone=(), geolocation=()'}
for path in pages + ['/robots.txt', '/sitemap.xml', '/missing-release-qualification']:
    status, headers, body, final_url = read(path)
    expected_status = 404 if path == '/missing-release-qualification' else 200
    lower = {k.lower(): v for k, v in headers.items()}
    row = {'path': path, 'status': status, 'bytes': len(body), 'sha256': hashlib.sha256(body).hexdigest(), 'sameOrigin': final_url.startswith(ORIGIN + '/')}
    if status != expected_status or not row['sameOrigin']: failures.append(path + ': status/origin mismatch')
    if any(lower.get(k) != v for k, v in security.items()): failures.append(path + ': security header mismatch')
    if path in pages:
        name = 'index' if path == '/' else path.strip('/')
        local, public = Document(), Document()
        local.feed((ROOT / 'landing/out' / (name + '.html')).read_text())
        public.feed(body.decode())
        text = public.visible_text()
        date_expected = path in ['/privacy', '/terms', '/delete-account']
        row.update({'h1': public.h1, 'canonical': public.canonical, 'robots': public.robots, 'visibleCopyMatchesPreparedSource': text == local.visible_text(), 'effectiveDateVisible': 'Effective 6 October 2026' in text, 'draftVisible': 'Working draft' in text or 'About this draft' in text, 'contactLinked': any(x.startswith('mailto:shantanusinha95@gmail.com') for x in public.links), 'brokenInternalAnchors': [x for x in public.links if x.startswith('#') and x[1:] not in public.ids], 'externalScripts': public.external_scripts, 'linksMatchPreparedSource': public.links == local.links})
        if public.h1 != 1 or public.canonical != local.canonical or public.robots != local.robots: failures.append(path + ': metadata mismatch')
        if not row['visibleCopyMatchesPreparedSource'] or not row['linksMatchPreparedSource'] or not row['contactLinked'] or row['externalScripts'] or row['brokenInternalAnchors']: failures.append(path + ': text/links/script mismatch')
        if row['draftVisible'] or row['effectiveDateVisible'] != date_expected: failures.append(path + ': publication state mismatch')
        if any(x in body.decode() for x in provenance['retiredPublicAssets']): failures.append(path + ': retired asset reference')
        (EVIDENCE / (LABEL + '-' + ('home' if path == '/' else path.strip('/')) + '.html')).write_bytes(body)
    elif path in ['/robots.txt', '/sitemap.xml']:
        row['matchesPreparedBytes'] = body == (ROOT / 'landing/out' / path.strip('/')).read_bytes()
        if not row['matchesPreparedBytes']: failures.append(path + ': prepared output mismatch')
    routes.append(row)


def check_asset(path):
    status, _, body, final_url = read('/' + path)
    actual = hashlib.sha256(body).hexdigest()
    return {'path': path, 'status': status, 'bytes': len(body), 'sha256': actual, 'matchesSource': actual == manifest['public/' + path], 'sameOrigin': final_url.startswith(ORIGIN + '/')}


public_paths = sorted(p.removeprefix('public/') for p in manifest if p.startswith('public/'))
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    assets = list(pool.map(check_asset, public_paths))
for row in assets:
    if row['status'] != 200 or not row['matchesSource'] or not row['sameOrigin']: failures.append(row['path'] + ': asset mismatch')
retired = []
for path in provenance['retiredPublicAssets']:
    status, _, _, _ = read('/' + path.lstrip('/'))
    retired.append({'path': path, 'status': status})
    if status != 404: failures.append(path + ': retired asset public')
receipt = {'checkedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'origin': ORIGIN, 'draft': False, 'effectiveDate': '6 October 2026', 'routes': routes, 'assets': assets, 'retiredAssets': retired, 'failures': failures, 'passed': not failures, 'scope': 'Anonymous static website qualification against locally built effective source; no native authentication/deletion/import/export QA claim.'}
(EVIDENCE / (LABEL + '-http-assets.json')).write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'origin': ORIGIN, 'routes': len(routes), 'assets': len(assets), 'retired404': len(retired), 'passed': not failures, 'failures': failures}))
raise SystemExit(0 if not failures else 1)
