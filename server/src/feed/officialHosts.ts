// The hosts whose pages may carry the gold "From the studio or network" check (brief §13).
//
// The research agent labels each piece of evidence with a tier, but it reads arbitrary web pages, so
// its "official" is a claim, not a fact: a prompt-injected or hallucinated page could name itself
// "Netflix" and lead every subscriber's post with the check. Evidence is therefore `official` only
// when its URL is on one of these hosts (feed/evidence.ts `verifiedTier`); every other "official"
// claim reads as `reputable`.
//
// REVIEWED DATA. Add a host only when every page on it (and on its subdomains) is published by the
// studio, network, streamer, publisher or broadcaster itself — a first-party press room, newsroom or
// official site. Never a platform that hosts other people's posts (YouTube, X, Instagram, TikTok,
// Reddit, bilibili), a wiki, a retailer, or a trade outlet (those are `trade`, and trade has no
// check by design). A show's own one-off official site (e.g. a `<title>-anime.jp`) is not listed:
// such pages read as reputable, which only costs the check.
//
// Matching is by suffix on a dot boundary after lower-casing and dropping a leading `www.`:
// `about.netflix.com` matches `netflix.com`; `netflix.com.evil.example` and `notnetflix.com` do not.

export const OFFICIAL_HOSTS: readonly string[] = [
  // Streamers
  'netflix.com',
  'crunchyroll.com',
  'hidive.com',
  'primevideo.com',
  'aboutamazon.com',
  'aboutamazon.in',
  'amazonmgmstudios.com',
  'disneyplus.com',
  'thewaltdisneycompany.com',
  'dgepress.com',
  'hulu.com',
  'max.com',
  'hbo.com',
  'wbd.com',
  'warnerbros.com',
  'apple.com',
  'paramountplus.com',
  'paramount.com',
  'paramountpressexpress.com',
  'peacocktv.com',
  'nbcuniversal.com',
  'nbcumv.com',
  'abema.tv',
  // Networks and broadcasters
  'nbc.com',
  'abc.com',
  'cbs.com',
  'fox.com',
  'amc.com',
  'amcplus.com',
  'fxnetworks.com',
  'starz.com',
  'sho.com',
  'adultswim.com',
  'cartoonnetwork.com',
  'bbc.co.uk',
  'bbc.com',
  'itv.com',
  'channel4.com',
  'nhk.or.jp',
  'tv-tokyo.co.jp',
  'tbs.co.jp',
  'fujitv.co.jp',
  'ntv.co.jp',
  'tv-asahi.co.jp',
  'mbs.jp',
  // Studios, distributors and publishers
  'sonypictures.com',
  'universalpictures.com',
  'aniplex.co.jp',
  'aniplexusa.com',
  'toei-anim.co.jp',
  'toho.co.jp',
  'mappa.co.jp',
  'ufotable.com',
  'kyotoanimation.co.jp',
  'production-ig.co.jp',
  'witstudio.co.jp',
  'bones.co.jp',
  'cloverworks.co.jp',
  'a1p.jp',
  'sunrise-inc.co.jp',
  'kadokawa.co.jp',
  'shueisha.co.jp',
  'kodansha.co.jp',
  'kodansha.us',
  'viz.com',
  'sentaifilmworks.com',
]

/** The host as matched: lower-cased, a trailing dot and a leading `www.` dropped. */
function canonicalHost(hostname: string): string {
  let host = hostname.toLowerCase()
  if (host.endsWith('.')) host = host.slice(0, -1)
  if (host.startsWith('www.')) host = host.slice(4)
  return host
}

/** True when `url` is on a listed host (itself or a subdomain of it). False for anything unparseable. */
export function isOfficialHost(url: string, hosts: readonly string[] = OFFICIAL_HOSTS): boolean {
  let hostname: string
  try {
    hostname = new URL(url).hostname
  } catch {
    return false
  }
  const host = canonicalHost(hostname)
  if (host === '') return false
  return hosts.some((listed) => host === listed || host.endsWith(`.${listed}`))
}
