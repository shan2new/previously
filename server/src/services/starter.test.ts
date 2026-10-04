import { describe, expect, it } from 'vitest'
import { alternateStarter } from './starter.js'

describe('alternateStarter', () => {
  it('alternates the catalogues, anime first', () => {
    expect(alternateStarter(['a1', 'a2', 'a3'], ['t1', 't2', 't3'], 6)).toEqual(['a1', 't1', 'a2', 't2', 'a3', 't3'])
  })

  it('stops at the limit, mid-pair if it must', () => {
    expect(alternateStarter(['a1', 'a2'], ['t1', 't2'], 3)).toEqual(['a1', 't1', 'a2'])
  })

  it('carries on with the longer catalogue when the other runs out', () => {
    expect(alternateStarter(['a1'], ['t1', 't2', 't3'], 10)).toEqual(['a1', 't1', 't2', 't3'])
    expect(alternateStarter([], ['t1', 't2'], 10)).toEqual(['t1', 't2'])
  })

  it('never lists a franchise twice', () => {
    expect(alternateStarter(['x', 'a2'], ['x', 't2'], 10)).toEqual(['x', 'a2', 't2'])
  })
})
