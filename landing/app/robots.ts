import { siteOrigin } from '@/lib/site-config';

export const dynamic = 'force-static';

export default function robots() {
  return {
    rules: [
      { userAgent: '*', allow: '/' },
      { userAgent: 'OAI-SearchBot', allow: '/' },
    ],
    sitemap: `${siteOrigin}/sitemap.xml`,
  };
}
