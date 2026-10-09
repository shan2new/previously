// Public, build-time configuration. Never place credentials in this setting.
// The owned app domain has verified DNS and publicly reachable HTTPS.
const configuredOrigin = process.env.NEXT_PUBLIC_SITE_URL
  ?? 'https://previously.cognipin.com';
const parsedOrigin = new URL(configuredOrigin);
if (parsedOrigin.protocol !== 'https:' || parsedOrigin.pathname !== '/'
  || parsedOrigin.search || parsedOrigin.hash || parsedOrigin.username || parsedOrigin.password) {
  throw new Error('NEXT_PUBLIC_SITE_URL must be an HTTPS origin without a path or credentials');
}

export const siteOrigin = parsedOrigin.origin;
