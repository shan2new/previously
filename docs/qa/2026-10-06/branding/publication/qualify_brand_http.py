"""Anonymous HTTPS qualification of a prepared landing artifact; no browser automation."""
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
EVIDENCE = ROOT / 'docs/qa/2026-10-06/branding/publication'
ORIGIN, LABEL = sys.argv[1:3]
CANONICAL = 'https://previously.cognipin.com'
prepared = json.loads((ROOT / 'docs/qa/2026-10-06/landing-final/prepared-static-build.json').read_text())
deployment = json.loads((EVIDENCE / 'deploy-receipt.json').read_text())
BASELINE = ROOT / 'docs/qa/2026-10-06/landing-final/device-id-draft-publication'
PROVENANCE = json.loads((EVIDENCE / 'asset-provenance.json').read_text())


class Document(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.text = []
        self.hidden = 0
        self.canonical = []
        self.robots = []
        self.h1 = 0
        self.external_scripts = []
        self.links = []
        self.icons = []
        self.social = {}
        self.images = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag in ('script', 'style'):
            self.hidden += 1
        if tag == 'h1':
            self.h1 += 1
        if tag == 'link' and attrs.get('rel') == 'canonical':
            self.canonical.append(attrs.get('href'))
        if tag == 'meta' and attrs.get('name') == 'robots':
            self.robots.append(attrs.get('content'))
        if tag == 'script' and attrs.get('src', '').startswith(('https:', 'http:', '//')):
            self.external_scripts.append(attrs['src'])
        if tag == 'link' and attrs.get('rel') in ('icon', 'apple-touch-icon'):
            self.icons.append({k: attrs.get(k) for k in ('rel', 'href', 'type', 'sizes')})
        if tag == 'meta' and (attrs.get('property', '').startswith('og:image') or attrs.get('name', '').startswith('twitter:image')):
            self.social[attrs.get('property') or attrs.get('name')] = attrs.get('content')
        if tag == 'img':
            self.images.append({k: attrs.get(k) for k in ('src', 'alt', 'width', 'height')})
        if tag == 'a':
            self.links.append(attrs.get('href', ''))

    def handle_endtag(self, tag):
        if tag in ('script', 'style'):
            self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden:
            self.text.append(data)

    def visible_text(self):
        return ' '.join(' '.join(self.text).split())


def read(path):
    req = urllib.request.Request(ORIGIN + path, headers={'User-Agent': 'PreviouslyReleaseQualification/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            return response.status, dict(response.headers), response.read(), response.url
    except urllib.error.HTTPError as response:
        return response.code, dict(response.headers), response.read(), response.url


routes, failures = [], []
security = {
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'strict-origin-when-cross-origin',
    'permissions-policy': 'camera=(), microphone=(), geolocation=()',
}

for path in ['/', '/privacy', '/terms', '/support', '/delete-account', '/robots.txt', '/sitemap.xml', '/__previously_release_missing__']:
    status, headers, body, final_url = read(path)
    lower = {k.lower(): v for k, v in headers.items()}
    expected_status = 404 if path == '/__previously_release_missing__' else 200
    row = {'path': path, 'status': status, 'expectedStatus': expected_status, 'finalURL': final_url,
           'sha256': hashlib.sha256(body).hexdigest(), 'bytes': len(body),
           'headers': {k: lower.get(k) for k in ['content-type'] + list(security)}}
    if status != expected_status:
        failures.append(path + ': unexpected HTTP status')
    if not final_url.startswith(ORIGIN + '/'):
        failures.append(path + ': redirected away from tested public origin')
    for key, value in security.items():
        if lower.get(key) != value:
            failures.append(path + ': missing/mismatched ' + key)
    if path in ['/', '/privacy', '/terms', '/support', '/delete-account']:
        local_path = BASELINE / ('canonical-' + ('home' if path == '/' else path.strip('/')) + '.html')
        local, public = Document(), Document()
        local.feed(local_path.read_text())
        public.feed(body.decode())
        expected = next(page for page in prepared['pages'] if page['path'] == path)
        expected_copy = local.visible_text()
        if path == '/':
            assert expected_copy.count('Today Pick up where you left off') == 1
            assert expected_copy.count('0 1 Today') == 1
            expected_copy = expected_copy.replace('Today Pick up where you left off', 'Home Pick up where you left off').replace('0 1 Today', '0 1 Home')
        row.update({'h1': public.h1, 'canonical': public.canonical, 'robots': public.robots,
                    'draftVisible': 'Working draft' in public.visible_text(),
                    'effectiveDateVisible': 'Effective date' in public.visible_text(),
                    'externalScripts': public.external_scripts,
                    'visibleCopyMatchesExpectedSource': public.visible_text() == expected_copy,
                    'legalCopyUnchanged': public.visible_text() == local.visible_text() if path != '/' else None,
                    'icons': public.icons, 'socialImages': public.social,
                    'brandImages': [i for i in public.images if i['src'] == '/brand/native-icon.png'],
                    'tourImages': [i for i in public.images if i['src'] and i['src'].startswith('/app/')],
                    'contactLinked': any(link.startswith('mailto:') for link in public.links)})
        if public.h1 != 1 or public.canonical != expected['canonical'] or public.robots != expected['robots']:
            failures.append(path + ': heading/canonical/robots mismatch')
        if row['draftVisible'] != expected['draftVisible'] or row['effectiveDateVisible'] != expected['effectiveDateVisible']:
            failures.append(path + ': draft/effective state mismatch')
        if not row['visibleCopyMatchesExpectedSource'] or not row['contactLinked'] or public.external_scripts:
            failures.append(path + ': copy/contact/script mismatch')
        if len(public.icons) != 2 or any(i['href'] != '/brand/native-icon.png' or i['type'] != 'image/png' or i['sizes'] != '152x152' for i in public.icons):
            failures.append(path + ': canonical icon metadata mismatch')
        if public.social.get('og:image') != CANONICAL + '/brand/native-icon.png' or public.social.get('twitter:image') != CANONICAL + '/brand/native-icon.png' or public.social.get('og:image:width') != '152' or public.social.get('og:image:height') != '152':
            failures.append(path + ': social icon metadata mismatch')
        if len(row['brandImages']) != 2:
            failures.append(path + ': shared header/footer icon mismatch')
        if any(old in body.decode() for old in PROVENANCE['retiredPublicAssets']):
            failures.append(path + ': retired asset reference')
        (EVIDENCE / (LABEL + '-' + ('home' if path == '/' else path.strip('/')) + '.html')).write_bytes(body)
    elif path in ['/robots.txt', '/sitemap.xml']:
        local = (ROOT / 'landing/out' / path.strip('/')).read_bytes()
        row['matchesPreparedBytes'] = body == local
        if body != local:
            failures.append(path + ': prepared output mismatch')
    routes.append(row)

previous_assets = json.loads((ROOT / 'docs/qa/2026-10-06/landing-release/vercel-production/public-http-assets.json').read_text())['assets']
prior_by_path = {a['path']: a for a in previous_assets}
manifest = json.loads((EVIDENCE / 'source-manifest.json').read_text())['files']
public_paths = sorted(p.removeprefix('public/') for p in manifest if p.startswith('public/'))


def check_asset(path):
    status, _, body, final_url = read('/' + path)
    expected = hashlib.sha256((ROOT / 'landing/public' / path).read_bytes()).hexdigest()
    actual = hashlib.sha256(body).hexdigest()
    return {'path': path, 'status': status, 'bytes': len(body), 'sha256': actual,
            'matchesLocalSource': actual == expected,
            'matchesPriorQualifiedAsset': actual == prior_by_path[path]['sha256'] if path in prior_by_path else None,
            'samePublicOrigin': final_url.startswith(ORIGIN + '/')}


with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
    assets = list(pool.map(check_asset, public_paths))
for asset in assets:
    if asset['status'] != 200 or not asset['matchesLocalSource'] or asset['matchesPriorQualifiedAsset'] is False or not asset['samePublicOrigin']:
        failures.append(asset['path'] + ': image/font asset mismatch')
retired = []
for path in PROVENANCE['retiredPublicAssets']:
    status, _, _, _ = read('/' + path)
    retired.append({'path': path, 'status': status})
    if status != 404:
        failures.append(path + ': retired asset remains public')

receipt = {'checkedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'deploymentId': deployment['id'],
           'origin': ORIGIN, 'scope': 'Anonymous HTTPS static branding candidate; unchanged legal copy and precise Home label delta compared with prior7LeP public HTML; exact original image hashes, canonical brand metadata and retired assets404; no local build or production auth claim',
           'draft': True, 'effectiveDate': None, 'routes': routes, 'assets': assets, 'retiredAssets': retired,
           'failures': failures, 'passed': not failures}
(EVIDENCE / (LABEL + '-http-assets.json')).write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps({'origin': ORIGIN, 'routes': len(routes), 'assets': len(assets), 'passed': not failures, 'failures': failures}))
if failures:
    raise SystemExit(1)
