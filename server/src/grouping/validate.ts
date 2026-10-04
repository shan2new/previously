import type { GroupingInput, GroupingResult } from './llm.js'
const PART_KINDS = new Set(['season', 'movie', 'ova', 'ona', 'special', 'music'])

/** Structured JSON is not necessarily a valid partition of catalogue identities. */
export function validateGrouping(result: GroupingResult, input: GroupingInput): void {
  const expected = new Set(input.candidates.map(c => c.id))
  const seen = new Set<number>()
  for (const f of result.franchises) {
    if (!f.canonicalName?.trim() || !f.parts.length) throw new Error('Empty franchise grouping')
    const sequences = new Set<string>(), labels = new Set<string>()
    for (const p of f.parts) {
      if (!expected.has(p.id) || seen.has(p.id)) throw new Error('Unknown or repeated catalogue identity')
      seen.add(p.id)
      if (!PART_KINDS.has(p.partKind) || !Number.isInteger(p.sequence) || p.sequence < 1 || !p.label?.trim()) throw new Error('Invalid part metadata')
      const key = `${p.partKind}:${p.sequence}`
      if (sequences.has(key)) throw new Error('Repeated within-kind sequence')
      sequences.add(key)
      const label = p.label.trim().toLowerCase().replace(/\s+/g, ' ')
      if (/^season \d+$/.test(label)) {
        if (labels.has(label)) throw new Error('Different catalogue entries share one numbered season label')
        labels.add(label)
      }
    }
  }
  if (seen.size !== expected.size) throw new Error('Grouping omitted catalogue identities')
}
