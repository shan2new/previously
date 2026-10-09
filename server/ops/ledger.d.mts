export interface DeletionLedgerRecord {
  identityHash: string;
  clerkId: string | null;
  requestedAt: Date | string;
  completedAt: Date | string | null;
  attempts: number;
  nextAttemptAt: Date | string;
  appleRevocation?: 'revoked' | 'manual_required' | 'not_applicable';
}
export interface DeletionLedgerSnapshot {
  version: number;
  payload: { generatedAt: string | null; records: DeletionLedgerRecord[] };
  sha256: string | null;
}
export interface LedgerOptions { directory?: string; requireExisting?: boolean; appleRevocation?: 'revoked' | 'manual_required' | 'not_applicable' }
export function persistDeletionRecords(records: readonly DeletionLedgerRecord[], options?: LedgerOptions): Promise<DeletionLedgerSnapshot>;
export function recordDeletionRequested(clerkId: string, requestedAt?: Date, options?: LedgerOptions): Promise<DeletionLedgerSnapshot>;
export function recordDeletionCompleted(clerkId: string, completedAt?: Date, options?: LedgerOptions): Promise<DeletionLedgerSnapshot>;
export function readDeletionLedger(options?: LedgerOptions): Promise<DeletionLedgerSnapshot>;
