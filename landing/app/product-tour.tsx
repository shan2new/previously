'use client';

import { useEffect, useRef, useState } from 'react';
import Image from 'next/image';
import {
  ArrowUpRight,
  CalendarDays,
  LibraryBig,
  Maximize2,
  Search,
  TvMinimal,
} from 'lucide-react';
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';

// Captured from the running iPhone app, not reconstructed website interfaces.
const screens = [
  {
    id: 'today',
    label: 'Home',
    summary: 'Pick up where you left off',
    icon: TvMinimal,
    title: 'Ready when\nyou are.',
    description:
      'Pick up where you left off. When you’re caught up, see what’s coming and enjoy the quiet.',
    detail: 'New episodes, next up, and upcoming releases.',
    image: '/app/home-current.png',
    width: 1179,
    height: 2556,
    alt: 'Previously Home on iPhone: Black Clover Season 2 Episode 2, Recently aired, and the five app tabs.',
    caption: 'New episodes and the stories you follow, together on Home.',
  },
  {
    id: 'schedule',
    label: 'Schedule',
    summary: 'Know what’s coming',
    icon: CalendarDays,
    title: 'Something good\nto look forward to.',
    description:
      'See the next episodes of the shows you follow, day by day. Jump to a date or come straight back to today.',
    detail: 'Anime and TV, together in your schedule.',
    image: '/app/schedule-current.jpg',
    width: 369,
    height: 800,
    alt: 'Previously Schedule on iPhone: the Black Clover premiere, dated episodes and upcoming seasons, with the five app tabs.',
    caption: 'A sample schedule with upcoming episodes and returning shows.',
  },
  {
    id: 'library',
    label: 'Library',
    summary: 'Keep it all together',
    icon: LibraryBig,
    title: 'Every phase\nof your watching life.',
    description:
      'Watching. Planned. Watched. And the shows making a return. A library that knows where you are with each story.',
    detail: 'Every season stays with its show.',
    image: '/app/library-current.jpg',
    width: 369,
    height: 800,
    alt: 'Previously Library on iPhone: Re:ZERO next up, Returning and Watching shelves, and the five app tabs.',
    caption: 'A sample library, with your next episode and returning shows.',
  },
  {
    id: 'search',
    label: 'Search',
    summary: 'Find your next watch',
    icon: Search,
    title: 'Find your next\n“just one more.”',
    description:
      'Search TV and anime together, or follow a promising find from Trending now. Add the show to make it yours.',
    detail: 'One search. A whole new watchlist.',
    image: '/app/search-current.jpg',
    width: 369,
    height: 800,
    alt: 'Previously Search on iPhone: anime and TV search, For you, Trending and Genres, and a Trending now poster shelf.',
    caption: 'Find a new show and add it to your library.',
  },
];

function SeasonsView() {
  return (
    <Dialog>
      <DialogTrigger className="tour-link">
        See a show’s seasons <ArrowUpRight size={16} />
      </DialogTrigger>
      <DialogContent className="screen-dialog seasons-dialog">
        <DialogTitle>One show. Every season.</DialogTitle>
        <DialogDescription>
          Seasons, episode progress, movies and extras, together on the show
          page.
        </DialogDescription>
        <Image
          unoptimized
          src="/app/seasons.webp"
          width={1179}
          height={2556}
          alt="Game of Thrones in Previously, with the native season selector showing Seasons 1 through 8 above episode progress and Movies & extras."
        />
      </DialogContent>
    </Dialog>
  );
}

function ScreenView({ screen }: { screen: (typeof screens)[number] }) {
  return (
    <Dialog>
      <DialogTrigger
        className="native-screen-button"
        aria-label={`Enlarge ${screen.label} screenshot`}
      >
        <Image
          unoptimized
          src={screen.image}
          width={screen.width}
          height={screen.height}
          alt={screen.alt}
          className="native-screen"
          loading="lazy"
        />
        <span className="screen-enlarge">
          <Maximize2 size={14} /> View full screen
        </span>
      </DialogTrigger>
      <DialogContent className="screen-dialog">
        <DialogTitle>{screen.label} on iPhone</DialogTitle>
        <DialogDescription>
          {screen.caption}
        </DialogDescription>
        <Image
          unoptimized
          src={screen.image}
          width={screen.width}
          height={screen.height}
          alt={screen.alt}
        />
      </DialogContent>
    </Dialog>
  );
}

export function ProductTour() {
  const [view, setView] = useState('today');
  const tourRef = useRef<HTMLElement>(null);

  function selectView(next: string) {
    setView(next);
    // Keep shared links and repeated hero links aligned with the selected tab.
    const hash = next === 'today' ? '#experience' : `#experience-${next}`;
    window.history.replaceState(window.history.state, '', hash);
    // A sticky tab may be used after the story has scrolled out of view.
    // Bring the new story into view while retaining keyboard focus on its tab.
    const tour = tourRef.current;
    if (tour && tour.getBoundingClientRect().top < -80) {
      tour.scrollIntoView({
        block: 'start',
        behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches
          ? 'instant'
          : 'smooth',
      });
    }
  }

  useEffect(() => {
    // Preserve links into the previous landing page's tour.
    const routes: Record<string, string> = {
      '#experience': 'today',
      '#experience-library': 'library',
      '#experience-schedule': 'schedule',
      '#experience-updates': 'today',
      '#experience-search': 'search',
    };
    const sync = () => {
      const next = routes[window.location.hash];
      if (next) setView(next);
    };
    sync();
    window.addEventListener('hashchange', sync);
    return () => window.removeEventListener('hashchange', sync);
  }, []);

  return (
    <section
      ref={tourRef}
      className="product-tour gallery-wrap"
      id="experience"
      aria-labelledby="tour-title"
    >
      <span id="experience-library" className="tour-anchor" />
      <span id="experience-schedule" className="tour-anchor" />
      <span id="experience-updates" className="tour-anchor" />
      <span id="experience-search" className="tour-anchor" />
      <div className="tour-heading">
        <h2 id="tour-title">A little less keeping track.</h2>
        <span>A look inside the iPhone app</span>
      </div>
      <Tabs
        value={view}
        onValueChange={selectView}
        className="native-tour-tabs"
      >
        <TabsList
          className="native-tour-navigation"
          variant="line"
          aria-label="Explore the iPhone app"
        >
          {screens.map(({ id, label, summary, icon: Icon }) => (
            <TabsTrigger key={id} value={id} aria-label={label}>
              <Icon size={18} />
              <span className="tour-tab-copy">
                <span>{label}</span>
                <small>{summary}</small>
              </span>
            </TabsTrigger>
          ))}
        </TabsList>
        {screens.map((screen, index) => (
          <TabsContent
            key={screen.id}
            value={screen.id}
            className="native-tour-panel"
            keepMounted
          >
            <div className="tour-story">
              <span className="tour-chapter">
                0{index + 1} <span /> {screen.label}
              </span>
              <h3>{screen.title}</h3>
              <p>{screen.description}</p>
              <div className="tour-detail">
                <span />
                {screen.detail}
              </div>
              {screen.id === 'library' && <SeasonsView />}
            </div>
            <figure
              className={`native-screen-stage native-screen-stage-${screen.id}`}
            >
              <ScreenView screen={screen} />
            </figure>
          </TabsContent>
        ))}
      </Tabs>
      <p className="tour-footnote">
        Actual iPhone screens. Release information shown is a snapshot.
      </p>
    </section>
  );
}
