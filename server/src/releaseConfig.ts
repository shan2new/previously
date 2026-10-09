type ReleaseConfig = {
  APP_ENV: string
  CLERK_SECRET_KEY?: string
  OBSERVABILITY_TOKEN?: string
  GROUPING_LLM_DISABLED: boolean
  SEARCH_CORRECT_DISABLED: boolean
  SOCIAL_COMMENTS_ENABLED: boolean
}

/** The consumer v1 contract: production identity cleanup, private diagnostics and zero API spend. */
export function assertReleaseConfig(config: ReleaseConfig): void {
  if (config.APP_ENV !== 'production') return
  if (!config.CLERK_SECRET_KEY?.startsWith('sk_live_')) throw new Error('Production release requires a Clerk production secret for account deletion.')
  if (!config.OBSERVABILITY_TOKEN || config.OBSERVABILITY_TOKEN.length < 32) throw new Error('Production release requires a private observability token of at least 32 characters.')
  if (!config.GROUPING_LLM_DISABLED || !config.SEARCH_CORRECT_DISABLED) throw new Error('Free v1 requires paid grouping and search-correction APIs to remain disabled.')
  if (config.SOCIAL_COMMENTS_ENABLED) throw new Error('Public comments remain disabled for v1.')
}
