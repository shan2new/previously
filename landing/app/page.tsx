/* oxlint-disable nextjs/no-html-link-for-pages -- Native document navigation avoids unnecessary client routing. */
import { ArrowUpRight } from 'lucide-react';
import { Experience, Questions } from './experience';
import { Brand, SiteFooter } from './site-chrome';
import { siteOrigin } from '@/lib/site-config';
import './gallery.css';
import './product-tour.css';
export default function Home() {
  return (
    <main id="main" className="gallery">
      <a className="skip-link" href="#hero-title">
        Skip to content
      </a>
      <header className="gallery-header gallery-wrap">
        <Brand />
        <nav aria-label="Main navigation">
          <a href="#experience">Explore the app</a>
          <a href="#questions">Questions</a>
          <a href="/support">
            Support <ArrowUpRight size={14} />
          </a>
          <span className="gallery-availability">iPhone · Coming soon</span>
        </nav>
      </header>
      <Experience />
      <section className="gallery-questions gallery-wrap" id="questions">
        <div>
          <h2>A few things to know.</h2>
          <a href="/support">
            Get in touch <ArrowUpRight size={15} />
          </a>
        </div>
        <Questions />
      </section>
      <SiteFooter />
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{
          __html: JSON.stringify({
            '@context': 'https://schema.org',
            '@type': 'SoftwareApplication',
            name: 'Previously.',
            description:
              'A TV and anime tracking app for iPhone. Keep your shows, seasons and episode progress together, see upcoming episodes, and catch up on release updates.',
            applicationCategory: 'EntertainmentApplication',
            operatingSystem: 'iOS 18 or later',
            url: siteOrigin,
            author: {
              '@type': 'Person',
              name: 'Shantanu Sinha',
              url: 'https://github.com/shan2new',
            },
            featureList: [
              'TV and anime episode tracking',
              'Seasons grouped under one show',
              'Upcoming episode schedule',
              'What-changed digest',
              'Spoiler controls',
              'Library export',
            ],
          }),
        }}
      />
    </main>
  );
}
