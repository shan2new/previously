import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  output: 'export',
  // The site uses local, already prepared artwork and iPhone captures. Keep
  // delivery static instead of requiring an image optimization function.
  images: { unoptimized: true },
};

export default nextConfig;
