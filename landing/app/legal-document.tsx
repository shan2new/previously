/* oxlint-disable nextjs/no-html-link-for-pages -- Native document navigation avoids unnecessary client routing. */
import type { Metadata } from 'next';
import { ArrowLeft, ArrowUpRight, Mail } from 'lucide-react';
import {
  legalContent,
  legalPublication,
  type LegalKind,
} from '@/lib/legal-content';
import { Brand, SiteFooter } from './site-chrome';
export const legalLinks = [
  { href: '/privacy', label: 'Privacy Policy' },
  { href: '/terms', label: 'Terms of Use' },
  { href: '/support', label: 'Support' },
  { href: '/delete-account', label: 'Account Deletion' },
];
export function legalMetadata(kind: LegalKind): Metadata {
  const { title, summary } = legalContent[kind];
  return {
    title: `${title} — Previously.`,
    description: summary,
    alternates: { canonical: `/${kind}` },
    openGraph: {
      title: `${title} — Previously.`,
      description: summary,
      url: `/${kind}`,
      type: 'website',
      images: [{ url: '/brand/native-icon.png', width: 152, height: 152, alt: 'Previously app icon' }],
    },
    twitter: {
      card: 'summary',
      title: `${title} — Previously.`,
      description: summary,
      images: ['/brand/native-icon.png'],
    },
    robots: { index: kind === 'support' || !legalPublication.draft, follow: true },
  };
}
export function LegalDocument({ kind }: { kind: LegalKind }) {
  const doc = legalContent[kind];
  const draft = legalPublication.draft && kind !== 'support';
  return (
    <div className="legal-page">
      <a className="skip-link" href="#legal-main">
        Skip to content
      </a>
      <header className="site-header wrap">
        <Brand />
        <a className="legal-back" href="/">
          <ArrowLeft size={16} /> Back to Previously
        </a>
      </header>
      <main id="main">
        <div className="wrap">
          <nav className="legal-tabs" aria-label="Legal and support">
            {legalLinks.map((link) => (
              <a
                key={link.href}
                href={link.href}
                aria-current={link.href === `/${kind}` ? 'page' : undefined}
              >
                {link.label}
              </a>
            ))}
          </nav>
          <div className="legal-intro">
            <p className="section-label">PREVIOUSLY. / THE DETAILS</p>
            <h1>
              {doc.title}
              <span>.</span>
            </h1>
            <p>{doc.summary}</p>
            {!draft && legalPublication.effectiveDate && kind !== 'support' && (
              <p className="draft-status">Effective {legalPublication.effectiveDate}</p>
            )}
            {draft && (
              <p className="draft-status">
                <span /> Working draft · not yet effective
              </p>
            )}
          </div>
          <div className="legal-layout">
            <details className="mobile-contents">
              <summary>On this page</summary>
              <nav aria-label="Mobile page contents">
                {doc.sections.map((section, index) => (
                  <a href={`#section-${index + 1}`} key={section.title}>
                    <span>{String(index + 1).padStart(2, '0')}</span>
                    {section.title}
                  </a>
                ))}
              </nav>
            </details>
            <aside className="legal-sidebar">
              <p className="toc-label">ON THIS PAGE</p>
              <nav aria-label="On this page">
                {doc.sections.map((section, index) => (
                  <a href={`#section-${index + 1}`} key={section.title}>
                    <span>{String(index + 1).padStart(2, '0')}</span>
                    {section.title}
                  </a>
                ))}
              </nav>
              <div className="legal-contact">
                <Mail size={22} />
                <h2>
                  A real person.
                  <br />
                  An open inbox.
                </h2>
                <p>
                  Previously. is made by
                  <br />
                  <strong>Shantanu Sinha.</strong>
                </p>
                <a
                  className="contact-email"
                  href={`mailto:${legalPublication.contactEmail}`}
                >
                  {legalPublication.contactEmail}
                  <ArrowUpRight size={14} />
                </a>
                <div className="social-links">
                  <a
                    href="https://github.com/shan2new"
                    aria-label="Shantanu on GitHub"
                  >
                    GitHub
                  </a>
                  <a
                    href="https://www.linkedin.com/in/shan2new"
                    aria-label="Shantanu on LinkedIn"
                  >
                    LinkedIn
                  </a>
                </div>
              </div>
            </aside>
            <article id="legal-main" className="legal-article">
              {draft && (
                <div className="legal-draft">
                  <strong>About this draft</strong>
                  <p>
                    This copy describes the prepared consumer release. Its
                    effective date will be set when the deployed service and
                    its deletion and retention checks match these statements.
                  </p>
                </div>
              )}
              {(kind === 'support' || kind === 'delete-account') && (
                <a
                  className="legal-email-button"
                  href={`mailto:${legalPublication.contactEmail}?subject=${encodeURIComponent(kind === 'delete-account' ? 'Previously. account deletion request' : 'Previously. support')}`}
                >
                  <Mail size={18} />
                  {kind === 'delete-account'
                    ? 'Request account deletion'
                    : 'Email Shantanu'}
                  <ArrowUpRight size={18} />
                </a>
              )}
              {doc.sections.map((section, index) => (
                <section
                  className="legal-section"
                  id={`section-${index + 1}`}
                  key={section.title}
                >
                  <span className="legal-number">
                    {String(index + 1).padStart(2, '0')}
                  </span>
                  <h2>{section.title}</h2>
                  {section.paragraphs.map((p) => (
                    <p key={p}>{p}</p>
                  ))}
                  {section.items && (
                    <ul>
                      {section.items.map((item) => (
                        <li key={item}>{item}</li>
                      ))}
                    </ul>
                  )}
                  {section.links?.map((link) => (
                    <p className="legal-source" key={link.href}>
                      <a href={link.href}>
                        {link.label} <ArrowUpRight size={14} />
                      </a>
                    </p>
                  ))}
                </section>
              ))}
              {kind === 'terms' && (
                <p className="legal-source">
                  <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">
                    Read Apple’s standard end-user license agreement{' '}
                    <ArrowUpRight size={14} />
                  </a>
                </p>
              )}
              <div className="legal-end">
                <span>PREVIOUSLY. / {doc.title.toUpperCase()}</span>
                <a href="#main">Back to top ↑</a>
              </div>
            </article>
          </div>
        </div>
      </main>
      <SiteFooter />
    </div>
  );
}
