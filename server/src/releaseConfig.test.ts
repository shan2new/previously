import { describe, expect, it } from 'vitest'
import { assertReleaseConfig } from './releaseConfig.js'

const valid = { APP_ENV: 'production', CLERK_SECRET_KEY: 'sk_live_synthetic', OBSERVABILITY_TOKEN: 'a'.repeat(48),
  GROUPING_LLM_DISABLED: true, SEARCH_CORRECT_DISABLED: true, SOCIAL_COMMENTS_ENABLED: false }
describe('production free-v1 boot contract', () => {
  it('accepts the configured consumer release', () => expect(() => assertReleaseConfig(valid)).not.toThrow())
  it.each([
    { CLERK_SECRET_KEY: 'sk_test_synthetic' }, { CLERK_SECRET_KEY: undefined },
    { OBSERVABILITY_TOKEN: 'short' }, { GROUPING_LLM_DISABLED: false },
    { SEARCH_CORRECT_DISABLED: false }, { SOCIAL_COMMENTS_ENABLED: true },
  ])('fails closed for a contradictory production setting %j', (change) => {
    expect(() => assertReleaseConfig({ ...valid, ...change })).toThrow()
  })
  it('does not restrict an isolated development fixture', () => {
    expect(() => assertReleaseConfig({ ...valid, APP_ENV: 'test', CLERK_SECRET_KEY: undefined })).not.toThrow()
  })
})
