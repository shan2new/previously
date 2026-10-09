'use client';
import Image from 'next/image';
import { ArrowDown, ArrowUpRight } from 'lucide-react';
import { ProductTour } from './product-tour';
import {
  Accordion,
  AccordionItem,
  AccordionTrigger,
  AccordionContent,
} from '@/components/ui/accordion';

const questions = [
  {
    q: 'Do I add every season separately?',
    a: 'Add the show once. Its seasons, episodes, movies and extras stay together, with progress for each season.',
  },
  {
    q: 'Can I watch shows here?',
    a: 'Previously. tracks your progress. Watch through your usual streaming services.',
  },
  {
    q: 'What is Previously Recap?',
    a: 'A catch-up on release changes since your last visit: newly aired episodes and returning shows. It doesn’t retell the plot.',
  },
  {
    q: 'Can I keep episode details hidden?',
    a: 'Yes. Unwatched episode titles and stills stay hidden until you choose to reveal them.',
  },
  {
    q: 'Can I export my library?',
    a: 'Yes. Export your shows and progress as JSON or CSV from Profile.',
  },
  {
    q: 'When can I get it?',
    a: 'An iPhone release is coming. The App Store link will appear here when it’s available.',
  },
];

export function Experience() {
  return (
    <>
      <section className="story-hero" aria-labelledby="hero-title">
        <div className="poster-wall" aria-hidden="true">
          {[
            'severance-poster.jpg',
            'frieren-poster.jpg',
            'arcane.jpg',
            'stranger-things.jpg',
            'silo.jpg',
            'succession.jpg',
            'bear.jpg',
            'attack-on-titan-2x3.jpg',
            'the-last-of-us.jpg',
            'breaking-bad.jpg',
            'frieren-poster.jpg',
            'severance-poster.jpg',
          ].map((poster, index) => (
            <Image
              unoptimized
              key={`${poster}-${index}`}
              src={`/images/${poster}`}
              width={500}
              height={750}
              alt=""
              loading="eager"
              fetchPriority="low"
            />
          ))}
        </div>
        <div className="hero-scrim" />
        <div className="hero-layout gallery-wrap">
          <div className="story-intro">
            <span className="hero-eyebrow">YOUR TV & ANIME COMPANION</span>
            <h1 id="hero-title">
              <span>Your shows.</span>
              <span>Right where</span>
              <span>you left them.</span>
            </h1>
            <p>
              Keep your place in every story. Track episodes, keep seasons
              together, and see what’s coming back.
            </p>
            <a className="gallery-cta" href="#experience">
              Explore the app <ArrowDown size={18} />
            </a>
            <span className="hero-platform">Coming soon for iPhone</span>
          </div>
          <a
            className="hero-product"
            href="#experience-library"
            aria-label="Explore Library in the iPhone app tour"
          >
            <span className="hero-handset-screen">
              <Image
                unoptimized
                src="/app/library-current.jpg"
                width={369}
                height={800}
                alt="Previously on iPhone, with your Returning, Watching and Planned shows together in the Library."
                loading="eager"
                fetchPriority="high"
              />
              <span className="hero-dynamic-island" aria-hidden="true" />
            </span>
            <span className="hero-product-caption">
              Inside your Library <ArrowUpRight size={14} />
            </span>
          </a>
        </div>
      </section>
      <ProductTour />
    </>
  );
}
export function Questions() {
  return (
    <Accordion className="faq-list">
      {questions.map(({ q, a }, index) => (
        <AccordionItem value={String(index)} key={q}>
          <AccordionTrigger className="faq-trigger">{q}</AccordionTrigger>
          <AccordionContent keepMounted className="faq-content">
            <p>{a}</p>
          </AccordionContent>
        </AccordionItem>
      ))}
    </Accordion>
  );
}
