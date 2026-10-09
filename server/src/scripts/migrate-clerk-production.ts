// Explicit, resumable identity reassociation. No passwords, sessions or email-based merges.
import { createHash, randomBytes } from "node:crypto";
import { chmod, lstat, mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createConnection } from "node:net";
import { createClerkClient } from "@clerk/backend";
import { parse } from "dotenv";
import postgres from "postgres";
import { z } from "zod";
import { join } from "node:path";
import { homedir } from "node:os";
import { readDeletionLedger } from "../../ops/ledger.mjs";
const userId = z.string().regex(/^user_[A-Za-z0-9]+$/);
const inventorySchema = z
  .array(
    z
      .object({
        sourceUserId: userId,
        email: z.string().email(),
        firstName: z.string().nullish(),
        lastName: z.string().nullish(),
        verified: z.boolean(),
        provider: z.string().nullish(),
      })
      .strict(),
  )
  .min(1)
  .max(100);
export function migrationInventory(value: unknown) {
  const rows = inventorySchema
      .parse(value)
      .map((row) => ({ ...row, email: row.email.toLowerCase() })),
    ids = new Set<string>(),
    emails = new Set<string>();
  for (const row of rows) {
    if (ids.has(row.sourceUserId) || emails.has(row.email))
      throw new Error("Duplicate source identity; resolve explicitly.");
    ids.add(row.sourceUserId);
    emails.add(row.email);
    if (!row.verified)
      throw new Error("Only independently verified source email identities may be imported.");
  }
  return {
    included: rows.filter((row) => !row.email.includes("+clerk_test")),
    excludedSynthetic: rows.filter((row) => row.email.includes("+clerk_test")).length,
    sourceCount: rows.length,
  };
}
const sha = (value: string) => createHash("sha256").update(value).digest("hex");
const digest = z.string().regex(/^[a-f0-9]{64}$/);
const snapshotSchema = z.object({ count: z.number().int().nonnegative(), sha256: digest }).strict();
const rowSchema = z
  .object({
    sourceUserId: userId,
    email: z.string().email(),
    firstName: z.string().nullish(),
    lastName: z.string().nullish(),
    internalUserId: z.string().uuid().nullable(),
    productionUserId: userId.nullable(),
    owned: z.record(z.string(), snapshotSchema),
    accountSHA256: digest.nullable(),
    activeBan: z.boolean(),
    banSHA256: digest.nullable(),
  })
  .strict();
const stateSchema = z
  .object({
    version: z.literal(2),
    sourceHash: digest,
    instanceId: z
      .string()
      .regex(/^ins_[A-Za-z0-9]+$/)
      .nullable(),
    expectedSourceCount: z.number().int().min(1).max(100),
    rows: z.array(rowSchema).max(100),
    appliedAt: z.string().datetime().optional(),
  })
  .strict();
type State = z.infer<typeof stateSchema>;
type Row = State["rows"][number];
type Connection = postgres.Sql | postgres.TransactionSql;
export type MigrationUser = {
  id: string;
  externalId: string | null;
  primaryEmailAddressId: string | null;
  banned: boolean;
  emailAddresses: { id: string; emailAddress: string; verification: { status: string } | null }[];
};
export type MigrationClerk = {
  instance: { get(): Promise<{ id: string; environmentType: string }> };
  users: {
    getUserList(args: { externalId: string[]; limit: number }): Promise<{ data: MigrationUser[] }>;
    getUser(id: string): Promise<MigrationUser>;
    createUser(args: {
      externalId: string;
      emailAddress: string[];
      firstName?: string;
      lastName?: string;
      skipPasswordRequirement: boolean;
    }): Promise<MigrationUser>;
    banUser(id: string): Promise<unknown>;
  };
};
export type MigrationOptions = {
  mode: "plan" | "identities" | "refresh" | "apply";
  inventoryPath: string;
  sourceConfigPath: string;
  statePath: string;
  expectedSourceCount: number;
  productionConfigPath?: string;
  instanceId?: string;
};
type Dependencies = {
  clerk?: MigrationClerk;
  requireStopped?: (port: number) => Promise<void>;
  afterDatabaseCommit?: () => Promise<void>;
};
async function privateRead(path: string) {
  const info = await lstat(path);
  if (!info.isFile() || info.isSymbolicLink() || (info.mode & 0o077) !== 0)
    throw new Error("Input must be a private regular file.");
  return readFile(path, "utf8");
}
async function privateParent(path: string) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const info = await lstat(dirname(path));
  if (!info.isDirectory() || info.isSymbolicLink())
    throw new Error("State directory must be a private regular directory.");
  await chmod(dirname(path), 0o700);
}
async function save(path: string, value: unknown) {
  await privateParent(path);
  const temporary = path + ".pending-" + randomBytes(6).toString("hex"),
    file = await open(temporary, "wx", 0o600);
  try {
    await file.writeFile(JSON.stringify(value, null, 2) + "\n");
    await file.sync();
  } finally {
    await file.close();
  }
  try {
    await rename(temporary, path);
    const directory = await open(dirname(path), "r");
    try {
      await directory.sync();
    } finally {
      await directory.close();
    }
  } finally {
    await rm(temporary, { force: true });
  }
}
async function lockState<T>(path: string, run: () => Promise<T>): Promise<T> {
  await privateParent(path);
  const lock = await open(path + ".lock", "wx", 0o600);
  try {
    await lock.writeFile(JSON.stringify({ pid: process.pid }));
    await lock.sync();
    return await run();
  } finally {
    await lock.close();
    await rm(path + ".lock", { force: true });
  }
}
async function optionalState(path: string): Promise<State | null> {
  try {
    return stateSchema.parse(JSON.parse(await privateRead(path)));
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}
function validateMapping(
  state: State,
  source: string,
  inventory: ReturnType<typeof migrationInventory>,
  expected: number,
) {
  if (
    state.sourceHash !== sha(source) ||
    state.expectedSourceCount !== expected ||
    state.rows.length !== inventory.included.length
  )
    throw new Error("Source inventory changed; mapping cannot be resumed.");
  const ids = new Set<string>(),
    targets = new Set<string>(),
    accounts = new Set<string>();
  for (const row of state.rows) {
    const original = inventory.included.find((item) => item.sourceUserId === row.sourceUserId);
    if (
      !original ||
      original.email !== row.email ||
      (original.firstName ?? null) !== (row.firstName ?? null) ||
      (original.lastName ?? null) !== (row.lastName ?? null) ||
      ids.has(row.sourceUserId)
    )
      throw new Error("State contains an identity outside the explicit inventory.");
    ids.add(row.sourceUserId);
    if (row.productionUserId) {
      if (
        targets.has(row.productionUserId) ||
        inventory.included.some((item) => item.sourceUserId === row.productionUserId)
      )
        throw new Error("State has a conflicting production mapping.");
      targets.add(row.productionUserId);
    }
    if (row.internalUserId) {
      if (accounts.has(row.internalUserId))
        throw new Error("State maps the same app account twice.");
      accounts.add(row.internalUserId);
    }
  }
}
async function ownedSnapshot(connection: Connection, id: string | null) {
  const owned: Row["owned"] = {};
  if (!id) return owned;
  // Every direct FK to users and conventional ownership column, including actor/blocked IDs.
  const columns =
    await connection`select distinct c.table_name,c.column_name from information_schema.columns c where c.table_schema='public' and c.table_name<>'users' and (c.column_name ~ '(^|_)user_id$' or exists(select 1 from pg_constraint fk join pg_class t on t.oid=fk.conrelid join pg_namespace n on n.oid=t.relnamespace join pg_attribute a on a.attrelid=t.oid and a.attnum=any(fk.conkey) where fk.contype='f' and n.nspname='public' and t.relname=c.table_name and a.attname=c.column_name and fk.confrelid='public.users'::regclass)) order by c.table_name,c.column_name`;
  const tables = new Map<string, string[]>();
  for (const row of columns) {
    const names = tables.get(row.table_name) ?? [];
    names.push(row.column_name);
    tables.set(row.table_name, names);
  }
  for (const [table, names] of tables) {
    let filter = connection`${connection(names[0]!)} = ${id}`;
    for (const name of names.slice(1))
      filter = connection`${filter} or ${connection(name)} = ${id}`;
    const records =
      await connection`select to_jsonb(t) as data from ${connection(table)} t where ${filter}`;
    owned[table] = {
      count: records.length,
      sha256: sha(JSON.stringify(records.map((row) => JSON.stringify(row.data)).sort())),
    };
  }
  return owned;
}
async function snapshot(
  connection: Connection,
  sourceId: string,
  destinationId: string | null = null,
) {
  const candidates = destinationId ? [sourceId, destinationId] : [sourceId],
    accounts =
      await connection`select id,clerk_id,email,to_jsonb(u)-'clerk_id' as data from users u where clerk_id in ${connection(candidates)}`;
  if (accounts.length > 1)
    throw new Error("Destination has another app account; refusing an email-based merge.");
  const account = accounts[0];
  const bans =
    await connection`select clerk_id,lifted_at,to_jsonb(b)-'clerk_id' as data from moderation_bans b where clerk_id in ${connection(candidates)}`;
  if (bans.length > 1) throw new Error("Conflicting moderation identity; review explicitly.");
  const ban = bans[0];
  return {
    internalUserId: (account?.id ?? null) as string | null,
    clerkId: account?.clerk_id as string | undefined,
    email: account?.email as string | null | undefined,
    owned: await ownedSnapshot(connection, account?.id ?? null),
    accountSHA256: account ? sha(JSON.stringify(account.data)) : null,
    activeBan: Boolean(ban && ban.lifted_at === null),
    banSHA256: ban ? sha(JSON.stringify(ban.data)) : null,
  };
}
async function rejectDeleted(connection: Connection, ids: string[], requireTable: boolean) {
  const [table] = await connection`select to_regclass('public.account_deletions') as name`;
  if (!table?.name) {
    if (requireTable)
      throw new Error("Apply the account-deletion migration before copying identities.");
    return;
  }
  const [deleted] =
    await connection`select 1 from account_deletions where identity_hash in ${connection(ids.map(sha))} limit 1`;
  if (deleted) throw new Error("An erased identity cannot be migrated.");
}
function assertOwnership(row: Row, current: Awaited<ReturnType<typeof snapshot>>) {
  if (
    current.internalUserId !== row.internalUserId ||
    (current.email && current.email.toLowerCase() !== row.email)
  )
    throw new Error("Internal account ownership changed.");
}
function assertUnchanged(row: Row, current: Awaited<ReturnType<typeof snapshot>>) {
  assertOwnership(row, current);
  if (
    JSON.stringify(row.owned) !== JSON.stringify(current.owned) ||
    row.accountSHA256 !== current.accountSHA256 ||
    row.banSHA256 !== current.banSHA256 ||
    row.activeBan !== current.activeBan
  )
    throw new Error("Owned data changed since the plan; refresh the stable mapping while stopped.");
}
function verifyUser(user: MigrationUser, row: Row) {
  const primary = user.emailAddresses.find((email) => email.id === user.primaryEmailAddressId);
  if (
    !userId.safeParse(user.id).success ||
    user.externalId !== "previously-development:" + row.sourceUserId ||
    primary?.emailAddress.toLowerCase() !== row.email ||
    primary.verification?.status !== "verified"
  )
    throw new Error("Production identity ownership did not match the explicit source.");
  if (row.productionUserId && row.productionUserId !== user.id)
    throw new Error("Existing mapping changed.");
}
async function requireStopped(port: number) {
  if (!Number.isInteger(port) || port < 1 || port > 65535)
    throw new Error("Invalid source service port.");
  await new Promise<void>((yes, no) => {
    const socket = createConnection({ host: "127.0.0.1", port });
    socket.setTimeout(1000);
    socket.once("connect", () => {
      socket.destroy();
      no(new Error("Stop the app service before identity reassociation."));
    });
    socket.once("timeout", () => {
      socket.destroy();
      no(new Error("Could not establish that the app service is stopped."));
    });
    socket.once("error", (error: NodeJS.ErrnoException) =>
      error.code === "ECONNREFUSED" ? yes() : no(new Error("Service-stop check failed.")),
    );
  });
}
export async function runMigration(options: MigrationOptions, dependencies: Dependencies = {}) {
  const inventoryPath = resolve(options.inventoryPath),
    sourceConfigPath = resolve(options.sourceConfigPath),
    statePath = resolve(options.statePath),
    productionConfigPath = options.productionConfigPath
      ? resolve(options.productionConfigPath)
      : null;
  if ([inventoryPath, sourceConfigPath, productionConfigPath].includes(statePath))
    throw new Error("State must not overwrite an input file.");
  const source = await privateRead(inventoryPath),
    inventory = migrationInventory(JSON.parse(source)),
    expected = options.expectedSourceCount;
  if (!Number.isInteger(expected) || expected < inventory.sourceCount || expected > 100)
    throw new Error("Expected source inventory count is required.");
  if (options.mode !== "plan" && expected !== inventory.sourceCount)
    throw new Error("Source inventory is incomplete; no identities will be copied.");
  const values = parse(await privateRead(sourceConfigPath)),
    database = postgres(values.DATABASE_URL ?? "postgres://localhost:5432/previously", { max: 1 });
  try {
    return await lockState(statePath, async () => {
      let state = await optionalState(statePath);
      if (options.mode === "plan") {
        if (
          state?.instanceId ||
          state?.rows.some((row) => row.productionUserId) ||
          state?.appliedAt
        )
          throw new Error(
            "A live identity mapping already exists; resume or refresh it instead of replacing the plan.",
          );
        state = {
          version: 2,
          sourceHash: sha(source),
          instanceId: null,
          expectedSourceCount: expected,
          rows: [],
        };
        await database.begin("isolation level repeatable read read only", async (tx) => {
          for (const original of inventory.included) {
            await rejectDeleted(tx, [original.sourceUserId], false);
            const current = await snapshot(tx, original.sourceUserId);
            if (current.email && current.email.toLowerCase() !== original.email)
              throw new Error("Source email differs from the owned database record.");
            state!.rows.push({
              sourceUserId: original.sourceUserId,
              email: original.email,
              firstName: original.firstName ?? null,
              lastName: original.lastName ?? null,
              internalUserId: current.internalUserId,
              productionUserId: null,
              owned: current.owned,
              accountSHA256: current.accountSHA256,
              activeBan: current.activeBan,
              banSHA256: current.banSHA256,
            });
          }
        });
        await save(statePath, state);
        return {
          mode: options.mode,
          sourceCount: inventory.sourceCount,
          expected,
          realIdentities: state.rows.length,
          excludedSynthetic: inventory.excludedSynthetic,
          completeInventory: inventory.sourceCount === expected,
          database: "read-only",
        };
      }
      if (!state) throw new Error("Create the read-only plan first.");
      validateMapping(state, source, inventory, expected);
      if (!productionConfigPath) throw new Error("A private production config is required.");
      const production = parse(await privateRead(productionConfigPath));
      if (!production.CLERK_SECRET_KEY?.startsWith("sk_live_"))
        throw new Error("A production Clerk secret is required.");
      const clerk: MigrationClerk =
          dependencies.clerk ?? createClerkClient({ secretKey: production.CLERK_SECRET_KEY }),
        instance = await clerk.instance.get();
      if (
        !options.instanceId ||
        instance.id !== options.instanceId ||
        instance.environmentType !== "production"
      )
        throw new Error("Clerk destination does not match the explicit production instance.");
      if (state.instanceId && state.instanceId !== instance.id)
        throw new Error("Mapping belongs to a different production instance.");
      await (dependencies.requireStopped ?? requireStopped)(Number(values.PORT ?? 8787));
      const ledgerDirectory = join(
        production.PREVIOUSLY_OPS_ROOT ||
          values.PREVIOUSLY_OPS_ROOT ||
          process.env.PREVIOUSLY_OPS_ROOT ||
          join(homedir(), "Infra", "previously"),
        "deletions",
      );
      const rejectJournalDeletion = async (ids: string[]) => {
        const ledger = await readDeletionLedger({ directory: ledgerDirectory });
        const hashes = new Set(ledger.payload.records.map((row) => row.identityHash));
        if (ids.some((id) => hashes.has(sha(id))))
          throw new Error("An independently erased identity cannot be migrated.");
      };
      // Preflight every identity before creating any: deletion, app collisions and current owned data.
      for (const row of state.rows) {
        const ids = [row.sourceUserId, ...(row.productionUserId ? [row.productionUserId] : [])];
        await rejectDeleted(database, ids, true);
        await rejectJournalDeletion(ids);
        const current = await snapshot(database, row.sourceUserId, row.productionUserId);
        assertOwnership(row, current);
        if (options.mode !== "refresh") assertUnchanged(row, current);
      }
      state.instanceId = instance.id;
      if (options.mode === "identities") {
        // Durable instance association prevents plan overwrite after a lost-response identity create.
        await save(statePath, state);
        for (const row of state.rows) {
          const externalId = "previously-development:" + row.sourceUserId;
          let user: MigrationUser;
          if (row.productionUserId) user = await clerk.users.getUser(row.productionUserId);
          else {
            const found = await clerk.users.getUserList({ externalId: [externalId], limit: 2 });
            if (found.data.length > 1) throw new Error("Ambiguous explicit identity mapping.");
            user =
              found.data[0] ??
              (await clerk.users.createUser({
                externalId,
                emailAddress: [row.email],
                firstName: row.firstName || undefined,
                lastName: row.lastName || undefined,
                skipPasswordRequirement: true,
              }));
          }
          verifyUser(user, row);
          if (
            inventory.included.some((sourceRow) => sourceRow.sourceUserId === user.id) ||
            state.rows.some((other) => other !== row && other.productionUserId === user.id)
          ) {
            throw new Error("Conflicting explicit production identity mapping.");
          }
          // An existing destination identity may already own another app UUID. Reject before banning or recording it.
          const current = await snapshot(database, row.sourceUserId, user.id);
          assertUnchanged(row, current);
          if (row.activeBan && !user.banned) await clerk.users.banUser(user.id);
          const verified = await clerk.users.getUser(user.id);
          verifyUser(verified, row);
          if (row.activeBan && !verified.banned)
            throw new Error("Active source ban was not preserved in production.");
          await rejectDeleted(database, [row.sourceUserId, user.id], true);
          await rejectJournalDeletion([row.sourceUserId, user.id]);
          row.productionUserId = user.id;
          await save(statePath, state);
        }
      } else {
        if (state.rows.some((row) => !row.productionUserId))
          throw new Error("Create and verify every mapped identity before reassociation.");
        // Revalidate every target on each apply/refresh; persisted IDs alone do not prove ownership.
        for (const row of state.rows) {
          const user = await clerk.users.getUser(row.productionUserId!);
          verifyUser(user, row);
          if (row.activeBan && !user.banned)
            throw new Error("Active source ban was not preserved in production.");
        }
        if (options.mode === "refresh") {
          await database.begin("isolation level repeatable read read only", async (tx) => {
            for (const row of state!.rows) {
              const current = await snapshot(tx, row.sourceUserId, row.productionUserId);
              assertOwnership(row, current);
              if (current.activeBan !== row.activeBan || current.banSHA256 !== row.banSHA256)
                throw new Error(
                  "Moderation changed; resolve and verify it explicitly before refreshing data.",
                );
              row.owned = current.owned;
              row.accountSHA256 = current.accountSHA256;
            }
          });
          await save(statePath, state);
        } else {
          await database.begin(async (tx) => {
            await tx`select pg_advisory_xact_lock(hashtextextended('previously-production-cutover',0))`;
            for (const row of state!.rows) {
              for (const id of [row.sourceUserId, row.productionUserId!].sort())
                await tx`select pg_advisory_xact_lock(hashtextextended(${id},0))`;
              await rejectDeleted(tx, [row.sourceUserId, row.productionUserId!], true);
              await rejectJournalDeletion([row.sourceUserId, row.productionUserId!]);
              await tx`select id from users where clerk_id in ${tx([row.sourceUserId, row.productionUserId!])} for update`;
              const before = await snapshot(tx, row.sourceUserId, row.productionUserId);
              assertUnchanged(row, before);
              if (row.internalUserId)
                await tx`update users set clerk_id=${row.productionUserId!} where id=${row.internalUserId}`;
              await tx`update moderation_bans set clerk_id=${row.productionUserId!} where clerk_id=${row.sourceUserId}`;
              const after = await snapshot(tx, row.sourceUserId, row.productionUserId);
              assertUnchanged(row, after);
            }
          });
          // Test seam models a committed transaction whose caller lost its response/state save.
          await dependencies.afterDatabaseCommit?.();
          state.appliedAt = new Date().toISOString();
          await save(statePath, state);
        }
      }
      return {
        mode: options.mode,
        identities: state.rows.length,
        mapped: state.rows.filter((row) => row.productionUserId).length,
        ownedAccounts: state.rows.filter((row) => row.internalUserId).length,
        librariesPreserved: options.mode === "apply",
      };
    });
  } finally {
    await database.end({ timeout: 5 });
  }
}
async function main() {
  const args = new Map<string, string>(),
    known = new Set([
      "--mode",
      "--inventory",
      "--source-config",
      "--state",
      "--expected-source-count",
      "--production-config",
      "--instance",
    ]);
  for (let index = 2; index < process.argv.length; index += 2) {
    const key = process.argv[index],
      value = process.argv[index + 1];
    if (!key || !known.has(key) || !value || args.has(key))
      throw new Error("Use explicit paired options.");
    args.set(key, value);
  }
  const mode = args.get("--mode");
  if (!["plan", "identities", "refresh", "apply"].includes(mode ?? ""))
    throw new Error("Mode must be plan, identities, refresh or apply.");
  const path = (key: string) => {
    const value = args.get(key);
    if (!value) throw new Error("Required private input path missing.");
    return value;
  };
  console.log(
    JSON.stringify(
      await runMigration({
        mode: mode as MigrationOptions["mode"],
        inventoryPath: path("--inventory"),
        sourceConfigPath: path("--source-config"),
        statePath: path("--state"),
        expectedSourceCount: Number(args.get("--expected-source-count")),
        productionConfigPath: args.get("--production-config"),
        instanceId: args.get("--instance"),
      }),
    ),
  );
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  void main().catch(() => {
    console.error(
      "Identity migration stopped. Private inputs/state remain available; no secret or user data is logged.",
    );
    process.exitCode = 1;
  });
}
