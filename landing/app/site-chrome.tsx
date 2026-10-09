/* oxlint-disable nextjs/no-html-link-for-pages -- Native document navigation avoids unnecessary client routing. */
import Image from 'next/image';
import { ArrowUpRight } from 'lucide-react';
import { legalPublication } from '@/lib/legal-content';
export function Brand() {
  return (
    <a className="wordmark" href="/" aria-label="Previously. home">
      <Image
        unoptimized
        src="/brand/native-icon.png"
        width={36}
        height={36}
        alt=""
      />
      Previously<span>.</span>
    </a>
  );
}
export function SiteFooter() {
  return (
    <footer className="site-footer compact-footer">
      <div className="wrap">
        <div className="compact-footer-main">
          <Brand />
          <nav aria-label="Information">
            <a href="/privacy">Privacy</a>
            <a href="/terms">Terms</a>
            <a href="/delete-account">Account deletion</a>
            <a href="/support">
              Support <ArrowUpRight size={13} />
            </a>
          </nav>
        </div>
        <div className="compact-footer-meta">
          <span>
            © 2026 ·{' '}
            <a href={`mailto:${legalPublication.contactEmail}`}>
              Shantanu Sinha
            </a>
          </span>
          <nav aria-label="Shantanu’s profiles">
            <a href="https://github.com/shan2new">GitHub</a>
            <a href="https://www.linkedin.com/in/shan2new">LinkedIn</a>
          </nav>
          <span className="artwork-credit">Artwork © respective owners.</span>
        </div>
      </div>
    </footer>
  );
}
