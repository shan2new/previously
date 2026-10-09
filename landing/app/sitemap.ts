import type { MetadataRoute } from 'next';
import { legalPublication } from '@/lib/legal-content';
import { siteOrigin } from '@/lib/site-config';

export const dynamic = 'force-static';

export default function sitemap(): MetadataRoute.Sitemap {
  return [
    {
      url: `${siteOrigin}/`,
      changeFrequency: 'monthly',
      priority: 1,
    },
    { url: `${siteOrigin}/support`, changeFrequency: 'monthly', priority: 0.5 },
    ...(!legalPublication.draft ? ['privacy', 'terms', 'delete-account'].map((path) => ({
      url: `${siteOrigin}/${path}`,
      changeFrequency: 'yearly' as const,
      priority: 0.3,
    })) : []),
  ];
}
