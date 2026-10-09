export type LegalKind = 'privacy' | 'terms' | 'support' | 'delete-account';
export type LegalSection = {
  title: string;
  paragraphs: string[];
  items?: string[];
  links?: { label: string; href: string }[];
};
export type LegalContent = {
  title: string;
  summary: string;
  sections: LegalSection[];
};

// Describes the installed release configuration and qualified data practices.
// Publication verification is recorded separately from consumer workflow QA.
export const legalPublication = {
  operator: 'Shantanu Sinha',
  contactEmail: 'shantanusinha95@gmail.com',
  effectiveDate: '6 October 2026' as string | null,
  draft: false,
};
export const legalContent: Record<LegalKind, LegalContent> = {
  privacy: {
    title: 'Privacy Policy',
    summary:
      'How Previously. handles your account, watching activity and information you choose to share.',
    sections: [
      {
        title: 'Who this policy covers',
        paragraphs: [
          'This policy covers the Previously. iPhone app, its supporting service, and this website. Previously. is operated by Shantanu Sinha. For privacy questions, contact shantanusinha95@gmail.com.',
        ],
      },
      {
        title: 'Information used to run Previously.',
        paragraphs: [
          'Previously. uses information you provide and information generated when you use the service. The exact information available depends on the features and sign-in methods you use.',
        ],
        items: [
          'Account information: your authentication identifier, an internal account identifier, name and email address when supplied, and account creation and last-opened timestamps. Clerk handles sign-in and authentication. Information supplied by Apple or Google depends on the sign-in method and the choices you make.',
          'Watching activity: saved shows, library statuses, watched episode counts, watch and rewatch sessions, and the dates those records are changed. Importing history also processes the entries and public AniList username you choose to supply.',
          'Preferences: selected country, language, streaming-provider preferences, recommendation feedback and audience settings when used. A selected country is a preference; it is not a GPS reading.',
          'Updates: notification content and its creation and read status.',
          'Feed interactions: likes, saved posts, reminders, hidden posts or shows, and episode ratings. Public comments and replies are disabled for the first release.',
          'On-device information: recent searches, cached show details and images, pending changes, settings, and app-managed export files. Copies you save or share outside Previously. remain under your control.',
          'Service requests: searches, requested pages and technical connection information processed by the app service, authentication provider and hosting infrastructure.',
        ],
      },
      {
        title: 'Why this information is used',
        paragraphs: [
          'Information is used to sign you in, maintain your library and progress, show relevant schedules and updates, honor your settings, respond to support requests, and operate and protect the service.',
        ],
        items: [
          'Notifications require your permission and are scheduled on the device by the current iPhone app.',
          'This website presents app screenshots and an interactive tour. It does not create an app account or update your library.',
          'Previously. does not sell personal information or run its own advertising program. Embedded trailers may include advertising supplied by the video provider. Aggregate operational reports show request throughput, errors, latency and totals such as recent active accounts and accounts with library progress. They are used to improve reliability and understand whether the app is useful; they do not track you across other apps or websites.',
        ],
      },
      {
        title: 'Services that receive information',
        paragraphs: [
          'Previously. uses the following services to provide authentication, catalog information and delivery. Those services also have their own privacy practices.',
        ],
        items: [
          'Clerk receives information needed for sign-in, authentication, session management and account security. This includes account information, a vendor device identifier, session and device tokens, device model, operating-system and app information, and technical connection information.',
          'When you choose Apple or Google sign-in, that provider handles authorization and shares the basic identity information you approve with Clerk. Google sign-in requests your name, email address and basic account identity; Previously. does not request permission to read or send Gmail messages. Apple lets you choose whether to share your email address or use Hide My Email.',
          'AniList and TMDB receive catalog search terms and catalog identifiers when the backend searches or matches shows. A public AniList username is sent to AniList when you request an import from that username. These requests do not deliberately include your Previously. authentication identifier or personal episode counts; importing a MyAnimeList export sends catalog identifiers for matching.',
          'AI search correction and paid model APIs are disabled in the launch configuration. Search text and personal watching activity are not sent to those services by Previously.',
          'The editorial catalog workflow may research public show metadata and announcements using operator tools. This is separate from personal account data and watching activity.',
          'Your device loads artwork from the image hosts referenced by the catalog. Those hosts receive ordinary image requests, which can expose network information such as an IP address.',
          'Embedded YouTube trailers connect directly to YouTube and may play automatically when a trailer enters view. The launch player uses privacy-enhanced embedding and a temporary web data store; YouTube can still receive the video request, IP address and other connection information, and can show non-personalized advertising. Opening an external link involves the destination service and its own privacy practices.',
          'The app backend runs on the operator’s Mac Mini. Cloudflare carries and protects the public connection to it. Vercel hosts this static website. These providers process ordinary connection information to deliver and protect their services. This website has no sign-in, advertising SDK or application analytics script.',
        ],
        links: [
          { label: 'Clerk privacy notice', href: 'https://clerk.com/legal/privacy' },
          { label: 'Apple privacy policy', href: 'https://www.apple.com/legal/privacy/' },
          { label: 'Google and YouTube privacy policy', href: 'https://policies.google.com/privacy' },
          { label: 'Cloudflare privacy policy', href: 'https://www.cloudflare.com/privacypolicy/' },
          { label: 'Vercel privacy notice', href: 'https://vercel.com/legal/privacy-notice' },
        ],
      },
      {
        title: 'Retention and deletion',
        paragraphs: [
          'Account information and watching records remain until changed or deleted. Removing an individual show from the library does not necessarily erase its episode progress.',
          'When an in-app deletion request is accepted, Previously. removes the account’s active app records and clears app-managed account history, pending changes, caches and temporary exports on that device. It also requests deletion of the Clerk sign-in identity. If Clerk is temporarily unavailable, the app identifies the request as pending and the service retries that cleanup automatically. A lost connection does not prove deletion succeeded; the app lets you check the request’s status.',
          'For an account linked to Apple, the app can ask you to confirm with Apple so the service can revoke that sign-in authorization during deletion. The authorization code and identity token are used only for that request; they are not saved in the app’s pending-change history or deletion ledger. If authorization cannot be revoked automatically, app-data deletion still proceeds and you receive instructions for removing Previously. from Sign in with Apple settings. Deletion status records whether Apple revocation completed or needs this manual step.',
          'A minimal hashed authentication identifier and deletion status are retained to prevent a deleted account from being recreated by an old session and to reconcile deletion requests. The deletion ledger’s raw authentication identifier is retained only while provider cleanup is pending. Existing moderation or security restriction records can separately retain an authentication identifier, reason and timestamps to protect the service and handle related requests; they are not public watching records.',
          'Routine diagnostic logs are stored in capped files that rotate daily. Each completed file is scheduled for removal seven days after its last entry, so a record in a daily file can be about eight days old before cleanup. The current service records sanitized diagnostic outcomes rather than request bodies, sign-in tokens or search text. Aggregate usage and operational snapshots are scheduled for removal after 30 days. Cleanup runs on a schedule rather than erasing each record at the instant it reaches that age.',
          'Routine database backups are scheduled for removal after seven days. A backup can contain earlier account records until that cleanup; a restore must reapply completed and pending account deletions before the service is reopened. Deletion does not instantly rewrite every backup. Backups are stored on the operator’s Mac Mini, with no off-device recovery copy; they do not protect against loss of that hardware or storage.',
          'Support correspondence is kept as needed to resolve the request, protect the service and meet applicable recordkeeping duties. Authentication and infrastructure providers may retain security or operational records under their own policies. Contact us to ask about a specific record or request.',
        ],
      },
      {
        title: 'Your controls and requests',
        paragraphs: [
          'You can change your library and supported preferences, control notifications in iPhone settings, and export information from Profile. JSON provides the app service’s account-data export, including library and supported account interactions; CSV provides the device’s library and progress for use in a spreadsheet. Copies you save or share are under your control. Contact support if you need help accessing another category of information.',
          'You can initiate account deletion from Profile without contacting support. The Account Deletion page also provides an email route if you cannot access the app. For privacy requests, contact Shantanu Sinha at shantanusinha95@gmail.com.',
          'Depending on where you live, applicable law may give you rights to access, correct, erase or restrict use of personal information, object to processing, withdraw consent, or complain to a relevant authority. Identity verification may be needed to protect your account when handling a request.',
        ],
      },
      {
        title: 'Security, location and audience',
        paragraphs: [
          'The configured public app API uses HTTPS. Access to account endpoints requires authentication. No method of transmission or storage can be guaranteed to eliminate every risk.',
          'Information may be processed in countries other than the one where you live when using authentication, catalog and hosting providers. We use account information to provide the service you request, operate and secure it, and respond to requests. Optional notifications depend on your device permission. Rights and any required safeguards depend on applicable law.',
          'Previously. is a TV and anime companion, and its catalog can include titles intended for mature audiences. Check the App Store age rating and your device’s parental controls. Contact us if you believe a child has provided personal information that requires removal.',
        ],
      },
      {
        title: 'Changes and contact',
        paragraphs: [
          'When this policy changes, its effective date will be updated and any notice required by applicable law will be provided. The operator is Shantanu Sinha. Privacy questions can be sent to shantanusinha95@gmail.com.',
        ],
      },
    ],
  },
  terms: {
    title: 'Terms of Use',
    summary:
      'The rules for using Previously. and its website, with room for the rights that applicable law protects.',
    sections: [
      {
        title: 'About Previously.',
        paragraphs: [
          'Previously. is a personal companion for tracking TV and anime. It organizes show information, seasons, episode progress and updates. It does not provide a license or subscription to watch third-party content, and it does not stream or download TV episodes.',
          'These terms cover the supporting service and website. The operator is Shantanu Sinha. The current release is free to use, with no subscription required. Embedded trailers may include advertising supplied by the video provider.',
        ],
      },
      {
        title: 'Apple’s app license',
        paragraphs: [
          'For an app distributed through Apple’s App Store, Apple’s standard end-user license agreement applies unless a valid custom agreement is supplied through App Store Connect. These service terms are not intended to replace the applicable app license or mandatory consumer rights.',
        ],
      },
      {
        title: 'Your account and use',
        paragraphs: [
          'Use the service lawfully, keep your sign-in credentials secure, and provide accurate information when you ask us to help with your account. Do not impersonate another person or access an account without permission.',
        ],
        items: [
          'Do not interfere with the service, bypass access controls, introduce malicious code or use the service to harm others.',
          'Do not use catalog material in a way that infringes its owner’s rights.',
          'Contact shantanusinha95@gmail.com if you believe someone has accessed your account without permission.',
        ],
      },
      {
        title: 'Catalog information and third-party content',
        paragraphs: [
          'Release dates, episode counts, artwork and other catalog information come from external sources and can change or contain errors. Check the relevant broadcaster or provider when a date or availability matters to you.',
          'Show names, images, trademarks and other third-party materials belong to their respective owners. Previously. does not claim ownership of them or imply an endorsement by a broadcaster, studio or streaming service.',
          'External services and linked destinations have their own terms and privacy policies. Access to a title may require a separate subscription or payment to its provider.',
        ],
      },
      {
        title: 'Availability and changes',
        paragraphs: [
          'Features may change as the service develops, and maintenance or external-provider issues can interrupt availability. Previously. does not promise uninterrupted service or that every catalog item will always be available.',
          'The app’s current backups are stored on the same hardware as its supporting service. They support recovery from some operational problems but cannot guarantee recovery after hardware or storage loss. You can keep your own copy of supported library information using the export option in Profile.',
          'Any future paid offering will have clear terms at purchase and use any required store billing integration. A future pricing change does not itself authorize a charge.',
        ],
      },
      {
        title: 'Your information and ending use',
        paragraphs: [
          'The Privacy Policy explains how account information and watching activity are handled. You can stop using the service, export supported library information and initiate account deletion in the app or request help through the published deletion page.',
          'Deleting the app from a device is not itself a request to delete a server account.',
        ],
      },
      {
        title: 'Rights and responsibility',
        paragraphs: [
          'To the extent permitted by applicable law, the service and catalog information are provided as available. Nothing in these terms excludes a right or responsibility that cannot lawfully be excluded, including mandatory consumer protections.',
        ],
      },
      {
        title: 'Questions about these terms',
        paragraphs: [
          'For questions, contact Shantanu Sinha at shantanusinha95@gmail.com.',
        ],
      },
    ],
  },
  support: {
    title: 'Support',
    summary:
      'Help with your library, progress, sign-in and data in Previously.',
    sections: [
      {
        title: 'Contact Previously.',
        paragraphs: [
          'Previously. is made by Shantanu Sinha. Email shantanusinha95@gmail.com for help with the app, your account or your information.',
          'When contacting support, include the app version, iPhone model, iOS version and a short description of what happened. Include the show title when the issue concerns catalog information.',
        ],
        items: [
          'Never send your password, sign-in code, session token or payment information.',
          'Only attach a screenshot if you are comfortable sharing everything visible in it.',
        ],
      },
      {
        title: 'Signing in with Apple or Google',
        paragraphs: [
          'Use the sign-in method associated with your Previously. account. Google sign-in uses basic account identity and email information; it does not give Previously. access to your Gmail messages. If you chose Hide My Email with Apple, your account may use an Apple relay address.',
          'If you are unsure which method you used, contact support before creating another account. Never share a sign-in code or password with support.',
        ],
      },
      {
        title: 'A show or date looks wrong',
        paragraphs: [
          'Catalog dates and episode details can change. Tell support which title, season or episode is affected and what looks incorrect. Previously. is a tracker; the broadcaster or streaming provider controls viewing access.',
        ],
      },
      {
        title: 'Your library and notifications',
        paragraphs: [
          'You can manage your followed shows and progress in the app. Notification permission can be changed in iPhone Settings. In Profile, JSON exports service-held app account information and CSV exports the device’s library and progress for a spreadsheet.',
        ],
      },
      {
        title: 'Account access and deletion',
        paragraphs: [
          'You can email shantanusinha95@gmail.com for sign-in help or a privacy request without reinstalling the app. The Account Deletion page explains deletion and pending requests. Support may need to verify account ownership before making account changes.',
        ],
      },
      {
        title: 'After deleting an account linked to Apple',
        paragraphs: [
          'If the app says Apple sign-in still needs to be removed, follow the steps on the Account Deletion page. This extra Apple settings step does not delay deletion of your active Previously. app data.',
        ],
      },
      {
        title: 'Release availability',
        paragraphs: [
          'Previously. is being built for iPhone. A public download link will be added to this website when it is available.',
        ],
      },
    ],
  },
  'delete-account': {
    title: 'Account Deletion',
    summary:
      'A direct place to request deletion of your Previously. account and associated data.',
    sections: [
      {
        title: 'Request deletion without the app',
        paragraphs: [
          'If you cannot use the app, email shantanusinha95@gmail.com with the subject “Previously. account deletion request” to contact Shantanu Sinha about deleting your account. You can use this route after uninstalling Previously.',
          'The request should identify the Previously. account you want deleted. Support may verify ownership to prevent someone else from deleting your account. Do not send your password or one-time sign-in code.',
        ],
      },
      {
        title: 'The in-app option',
        paragraphs: [
          'Open Profile → Delete account and confirm. Once the service accepts the request, the app removes active tracking data, clears app-managed account records on that device and signs you out.',
          'Clerk sign-in deletion can finish separately if the provider is temporarily unavailable. The app tells you when cleanup is pending, and the service retries automatically. If the connection is lost before a response arrives, use Check deletion status in the app to confirm what happened.',
          'If your account is linked to Apple, the app can ask you to confirm with Apple so its authorization can be revoked. Cancelling that confirmation does not submit the deletion request. If automatic Apple revocation is unavailable, deletion of app data can still proceed; the app tells you when a separate Apple settings step is needed.',
        ],
      },
      {
        title: 'What is removed',
        paragraphs: [
          'An accepted request covers these app-managed account records:',
        ],
        items: [
          'The Previously. account record and Clerk authentication identity and sessions.',
          'Saved shows, statuses, episode progress, watch and rewatch sessions, preferences, recommendation feedback and notification records.',
          'Feed likes, saved posts, reminders, hidden items and episode ratings. Public comments and replies are disabled in the first release; any older account-owned community records are covered by account deletion.',
          'App-managed local account history, caches and temporary export files on the device performing deletion.',
        ],
      },
      {
        title: 'If Apple sign-in needs a manual step',
        paragraphs: [
          'If deletion status says Apple sign-in still needs to be removed, open iPhone Settings, tap your name, and find Sign in with Apple. Select Previously. or its developer entry and follow the displayed option to stop using Sign in with Apple. Menu labels can differ by iOS version; Apple’s instructions below show the current steps.',
          'This removes the sign-in authorization; it does not delete your Apple Account. Deleting your Previously. account also does not delete a Google account or Gmail messages. Removing an app from Apple or Google account settings alone is not a request to delete its Previously. app data.',
        ],
        links: [
          { label: 'Apple: manage apps using Sign in with Apple', href: 'https://support.apple.com/en-us/102571' },
        ],
      },
      {
        title: 'What to expect after a request',
        paragraphs: [
          'Support may need to verify ownership for an email request. There is no required support call or email step for an in-app request.',
          'A minimal hashed deletion marker remains to prevent old sessions from recreating the account. The deletion ledger’s raw authentication identifier is cleared once sign-in deletion completes. Existing moderation or security restriction records can separately remain to protect the service, as described in the Privacy Policy.',
          'Earlier records can remain in routine database backups until their scheduled seven-day cleanup. Completed and pending deletions must be reapplied before restoring service from a backup. Daily diagnostic log files are scheduled for removal seven days after their last entry, so individual records can be about eight days old; aggregate snapshots are scheduled for removal after 30 days. Support and processor records follow the retention treatment described in the Privacy Policy.',
          'Copies you saved or shared outside the app are under your control and cannot be removed remotely by Previously. Removing Previously. does not delete a separate account you hold with a broadcaster or streaming service.',
        ],
      },
    ],
  },
};
