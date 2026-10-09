import type { Metadata } from 'next';
import { siteOrigin } from '@/lib/site-config';
import './globals.css';

export const metadata: Metadata = {
  metadataBase: new URL(siteOrigin),
  title: 'Previously. — TV & anime tracking, right where you left off',
  description:
    'Previously. keeps your TV shows and anime in one place. Track episodes across seasons, see what is coming next, and catch up on what changed while you were away.',
  alternates: { canonical: '/' },
  openGraph: {
    type: 'website',
    siteName: 'Previously.',
    title: 'Previously. — Your shows. Right where you left them.',
    description:
      'A little less keeping track. A lot more getting lost in a good story.',
    url: siteOrigin,
    images: [{ url: '/brand/native-icon.png', width: 152, height: 152, alt: 'Previously app icon' }],
  },
  twitter: {
    card: 'summary',
    title: 'Previously. — Your shows. Right where you left them.',
    description:
      'A personal TV and anime tracker for the stories you keep coming back to.',
    images: ['/brand/native-icon.png'],
  },
  icons: {
    icon: { url: '/brand/native-icon.png', type: 'image/png', sizes: '152x152' },
    apple: { url: '/brand/native-icon.png', type: 'image/png', sizes: '152x152' },
  },
  robots: { index: true, follow: true },
};
export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en" className="dark">
      <head>
        <meta name="theme-color" content="#09090b" />
        <link
          rel="preload"
          href="/fonts/Outfit-Regular.ttf"
          as="font"
          type="font/ttf"
          crossOrigin="anonymous"
        />
        <link
          rel="preload"
          href="/fonts/Outfit-Bold.ttf"
          as="font"
          type="font/ttf"
          crossOrigin="anonymous"
        />
      </head>
      <body>{children}</body>
    </html>
  );
}
