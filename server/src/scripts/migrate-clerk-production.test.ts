import { randomUUID, randomBytes, createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { chmod, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import postgres from "postgres";
import { describe, expect, it } from "vitest";
import {
  runMigration,
  migrationInventory,
  type MigrationClerk,
  type MigrationOptions,
  type MigrationUser,
} from "./migrate-clerk-production.js";
import { persistDeletionRecords, recordDeletionRequested } from "../../ops/ledger.mjs";
const sha = (value: string) => createHash("sha256").update(value).digest("hex");
const nonce = () => randomBytes(6).toString("hex");
const execute = promisify(execFile);
async function command(binary: string, args: string[], env: NodeJS.ProcessEnv) {
  return (await execute(binary, args, { env, timeout: 30_000, maxBuffer: 1024 * 1024 })).stdout;
}
function pgEnvironment(values: { DATABASE_URL: string }, database: string) {
  const url = new URL(values.DATABASE_URL);
  return { ...process.env, PGHOST: url.hostname, PGPORT: url.port || "5432", PGDATABASE: database };
}
function stubClerk() {
  const users = new Map<string, MigrationUser>();
  let creates = 0;
  let loseCreate = false;
  let banFail = false;
  const clerk: MigrationClerk = {
    instance: {
      async get() {
        return { id: "ins_fixture", environmentType: "production" };
      },
    },
    users: {
      async getUserList({ externalId }) {
        return {
          data: [...users.values()]
            .filter((user) => externalId.includes(user.externalId!))
            .map((user) => structuredClone(user)),
        };
      },
      async getUser(id) {
        const user = users.get(id);
        if (!user) throw new Error("fixture absent");
        return structuredClone(user);
      },
      async createUser(args) {
        creates++;
        const id = "user_production" + creates;
        const user: MigrationUser = {
          id,
          externalId: args.externalId,
          primaryEmailAddressId: "email_primary",
          banned: false,
          emailAddresses: [
            {
              id: "email_primary",
              emailAddress: args.emailAddress[0]!,
              verification: { status: "verified" },
            },
          ],
        };
        users.set(id, user);
        if (loseCreate) {
          loseCreate = false;
          throw new Error("response lost after create");
        }
        return structuredClone(user);
      },
      async banUser(id) {
        if (banFail) throw new Error("fixture ban failure");
        users.get(id)!.banned = true;
        return structuredClone(users.get(id));
      },
    },
  };
  return {
    clerk,
    users,
    get creates() {
      return creates;
    },
    loseNextCreate() {
      loseCreate = true;
    },
    failBan() {
      banFail = true;
    },
  };
}
async function fixture(
  run: (f: {
    directory: string;
    sql: postgres.Sql;
    options: MigrationOptions;
    stub: ReturnType<typeof stubClerk>;
    ids: [string, string, string];
    ledgerDirectory: string;
    phase: (
      mode: MigrationOptions["mode"],
      deps?: Parameters<typeof runMigration>[1],
    ) => ReturnType<typeof runMigration>;
    allData: () => Promise<Record<string, unknown>>;
  }) => Promise<void>,
) {
  const directory = await mkdtemp(join(tmpdir(), "previously-clerk-migration-")),
    db = "previously_clerk_fixture_" + nonce(),
    url = "postgres://localhost:5432/" + db,
    values = { DATABASE_URL: url },
    admin = pgEnvironment(values, "postgres");
  let sql: postgres.Sql | undefined;
  let owned = false;
  try {
    await command("createdb", [db], admin);
    owned = true;
    sql = postgres(url, { max: 1 });
    const ids: [string, string, string] = [randomUUID(), randomUUID(), randomUUID()];
    await sql`create table users(id uuid primary key,clerk_id text unique not null,email text,profile jsonb not null default '{}'::jsonb)`;
    await sql`create table moderation_bans(clerk_id text primary key,reason text not null,created_at timestamptz not null default now(),lifted_at timestamptz)`;
    await sql`create table account_deletions(identity_hash text primary key,clerk_id text,requested_at timestamptz not null default now(),completed_at timestamptz,attempts int not null default 0,next_attempt_at timestamptz not null default now())`;
    const tables = [
      "subscriptions",
      "progress",
      "user_preferences",
      "comments",
      "comment_likes",
      "feed_hides",
      "user_audience",
      "client_mutations",
      "future_owner",
    ];
    for (const table of tables) {
      const owner = table === "future_owner" ? "owner" : "user_id";
      await sql`create table ${sql(table)}(id serial primary key,${sql(owner)} uuid references users(id) on delete cascade,payload jsonb)`;
    }
    await sql`create table blocks(user_id uuid references users(id) on delete cascade,blocked_user_id uuid references users(id) on delete cascade,detail text)`;
    await sql`create table notifications(id serial primary key,user_id uuid references users(id) on delete cascade,actor_user_id uuid references users(id) on delete cascade,detail text)`;
    await sql`insert into users(id,clerk_id,email,profile) values(${ids[0]},'user_sourceA','alpha@example.invalid','{"theme":"dark"}'),(${ids[1]},'user_sourceB','beta@example.invalid','{"theme":"light"}'),(${ids[2]},'user_foreign','foreign@example.invalid','{}')`;
    for (const table of tables) {
      const owner = table === "future_owner" ? "owner" : "user_id";
      await sql`insert into ${sql(table)}(${sql(owner)},payload) values(${ids[0]},'{"episode":7}'),(${ids[1]},'{"episode":9}'),(${ids[2]},'{"episode":3}')`;
    }
    await sql`insert into blocks values(${ids[0]},${ids[2]},'outbound'),(${ids[2]},${ids[0]},'inbound')`;
    await sql`insert into notifications(user_id,actor_user_id,detail) values(${ids[2]},${ids[0]},'other inbox'),(${ids[0]},${ids[1]},'owned inbox')`;
    await sql`insert into moderation_bans(clerk_id,reason) values('user_sourceA','fixture active ban')`;
    const inventoryPath = join(directory, "inventory.json"),
      sourceConfigPath = join(directory, "source.env"),
      productionConfigPath = join(directory, "production.env"),
      statePath = join(directory, "state.json"),
      ops = join(directory, "ops"),
      ledgerDirectory = join(ops, "deletions");
    await writeFile(
      inventoryPath,
      JSON.stringify([
        {
          sourceUserId: "user_sourceA",
          email: "alpha@example.invalid",
          firstName: "A",
          verified: true,
        },
        { sourceUserId: "user_sourceB", email: "beta@example.invalid", verified: true },
      ]),
      { mode: 0o600 },
    );
    await writeFile(
      sourceConfigPath,
      "DATABASE_URL=" + url + "\nPORT=19599\nPREVIOUSLY_OPS_ROOT=" + ops + "\n",
      { mode: 0o600 },
    );
    await writeFile(productionConfigPath, "CLERK_SECRET_KEY=sk_live_stub_not_a_real_key\n", {
      mode: 0o600,
    });
    await persistDeletionRecords([], { directory: ledgerDirectory });
    const options: MigrationOptions = {
        mode: "plan",
        inventoryPath,
        sourceConfigPath,
        productionConfigPath,
        statePath,
        expectedSourceCount: 2,
        instanceId: "ins_fixture",
      },
      stub = stubClerk();
    const phase = (mode: MigrationOptions["mode"], deps: Parameters<typeof runMigration>[1] = {}) =>
      runMigration(
        { ...options, mode },
        { clerk: stub.clerk, requireStopped: async () => {}, ...deps },
      );
    const allData = async () => {
      const result: Record<string, unknown> = {};
      for (const table of [...tables, "blocks", "notifications"])
        result[table] = (await sql!`select to_jsonb(t) as data from ${sql!(table)} t`)
          .map((row) => JSON.stringify(row.data))
          .sort();
      result.users = (await sql!`select to_jsonb(t)-'clerk_id' as data from users t`)
        .map((row) => JSON.stringify(row.data))
        .sort();
      result.bans = (await sql!`select to_jsonb(t)-'clerk_id' as data from moderation_bans t`)
        .map((row) => JSON.stringify(row.data))
        .sort();
      return result;
    };
    await run({ directory, sql, options, stub, ids, ledgerDirectory, phase, allData });
  } finally {
    try {
      if (sql) await sql.end({ timeout: 5 });
    } finally {
      if (owned) await command("dropdb", ["--if-exists", db], admin);
      await rm(directory, { recursive: true });
    }
  }
}
describe("Clerk production migration with isolated real PG and stub-only Clerk", () => {
  it("rejects an existing destination app collision before creating or banning identities", () =>
    fixture(async (f) => {
      f.stub.users.set("user_existing", {
        id: "user_existing",
        externalId: "previously-development:user_sourceA",
        primaryEmailAddressId: "email_primary",
        banned: false,
        emailAddresses: [
          {
            id: "email_primary",
            emailAddress: "alpha@example.invalid",
            verification: { status: "verified" },
          },
        ],
      });
      await f.sql`update users set clerk_id='user_existing' where id=${f.ids[2]}`;
      await f.phase("plan");
      await expect(f.phase("identities")).rejects.toThrow("another app account");
      expect(f.stub.creates).toBe(0);
      expect(f.stub.users.get("user_existing")!.banned).toBe(false);
    }));
  it("keeps every internal UUID, full owned row, foreign row and active ban", () =>
    fixture(async (f) => {
      const before = await f.allData();
      expect((await f.phase("plan")).database).toBe("read-only");
      const state = JSON.parse(await readFile(f.options.statePath, "utf8"));
      expect(state.rows[0].owned.future_owner.count).toBe(1);
      expect(state.rows[0].owned.blocks.count).toBe(2);
      expect(state.rows[0].owned.notifications.count).toBe(2);
      await f.phase("identities");
      expect(f.stub.users.get("user_production1")?.banned).toBe(true);
      await f.phase("apply");
      expect(await f.allData()).toEqual(before);
      const users = await f.sql`select id,clerk_id from users order by clerk_id`;
      expect(users.find((row) => row.clerk_id === "user_production1")?.id).toBe(f.ids[0]);
      expect(users.find((row) => row.clerk_id === "user_production2")?.id).toBe(f.ids[1]);
      expect(users.find((row) => row.clerk_id === "user_foreign")?.id).toBe(f.ids[2]);
      expect((await f.sql`select clerk_id from moderation_bans`)[0]?.clerk_id).toBe(
        "user_production1",
      );
      expect((await stat(f.options.statePath)).mode & 0o777).toBe(0o600);
    }));
  it("resumes a lost identity-create response and refuses plan overwrite even without a saved target ID", () =>
    fixture(async (f) => {
      await f.phase("plan");
      f.stub.loseNextCreate();
      await expect(f.phase("identities")).rejects.toThrow("response lost");
      expect(f.stub.creates).toBe(1);
      const before = await readFile(f.options.statePath, "utf8");
      await expect(f.phase("plan")).rejects.toThrow("live identity mapping");
      expect(await readFile(f.options.statePath, "utf8")).toBe(before);
      await f.phase("identities");
      expect(f.stub.creates).toBe(2);
      await f.phase("apply");
    }));
  it("resumes after database commit but before mapping-state save without changing UUID/data", () =>
    fixture(async (f) => {
      await f.phase("plan");
      await f.phase("identities");
      const before = await f.allData();
      await expect(
        f.phase("apply", {
          afterDatabaseCommit: async () => {
            throw new Error("lost commit acknowledgement");
          },
        }),
      ).rejects.toThrow("lost commit acknowledgement");
      expect(JSON.parse(await readFile(f.options.statePath, "utf8")).appliedAt).toBeUndefined();
      await f.phase("apply");
      expect(await f.allData()).toEqual(before);
      expect(JSON.parse(await readFile(f.options.statePath, "utf8")).appliedAt).toBeTruthy();
    }));
  it("detects same-count content changes and refreshes only a verified stable mapping while stopped", () =>
    fixture(async (f) => {
      await f.phase("plan");
      await f.phase("identities");
      const mapping = JSON.parse(await readFile(f.options.statePath, "utf8")).rows.map(
        (row: { productionUserId: string }) => row.productionUserId,
      );
      await f.sql`update progress set payload='{"episode":88}' where user_id=${f.ids[0]}`;
      await expect(f.phase("apply")).rejects.toThrow("Owned data changed");
      let stopped = false;
      await f.phase("refresh", {
        requireStopped: async () => {
          stopped = true;
        },
      });
      expect(stopped).toBe(true);
      expect(
        JSON.parse(await readFile(f.options.statePath, "utf8")).rows.map(
          (row: { productionUserId: string }) => row.productionUserId,
        ),
      ).toEqual(mapping);
      const before = await f.allData();
      await f.phase("apply");
      expect(await f.allData()).toEqual(before);
    }));
  it("rejects a foreign target account without merging or modifying source rows", () =>
    fixture(async (f) => {
      await f.phase("plan");
      await f.phase("identities");
      await f.sql`update users set clerk_id='user_production1' where id=${f.ids[2]}`;
      const before = await f.allData();
      await expect(f.phase("apply")).rejects.toThrow("another app account");
      expect(await f.allData()).toEqual(before);
      expect((await f.sql`select clerk_id from users where id=${f.ids[0]}`)[0]?.clerk_id).toBe(
        "user_sourceA",
      );
    }));
  it("rejects deleted source/destination identities and journal-only precommit erasure", () =>
    fixture(async (f) => {
      await f.phase("plan");
      await f.sql`insert into account_deletions(identity_hash,clerk_id) values(${sha("user_sourceA")},'user_sourceA')`;
      await expect(f.phase("identities")).rejects.toThrow("erased identity");
      expect(f.stub.creates).toBe(0);
      await f.sql`delete from account_deletions`;
      await f.phase("identities");
      await f.sql`insert into account_deletions(identity_hash,clerk_id) values(${sha("user_production2")},'user_production2')`;
      await expect(f.phase("apply")).rejects.toThrow("erased identity");
      await f.sql`delete from account_deletions`;
      await recordDeletionRequested("user_sourceA", new Date(), { directory: f.ledgerDirectory });
      await expect(f.phase("apply")).rejects.toThrow("independently erased");
    }));
  it("rejects incomplete inventories before any Clerk lookup or write", () =>
    fixture(async (f) => {
      f.options.expectedSourceCount = 3;
      expect((await f.phase("plan")).completeInventory).toBe(false);
      for (const mode of ["identities", "refresh", "apply"] as const)
        await expect(f.phase(mode)).rejects.toThrow("incomplete");
      expect(f.stub.creates).toBe(0);
    }));
  it("rejects tampered state, foreign inventory IDs and changed destination ownership", () =>
    fixture(async (f) => {
      await f.phase("plan");
      let state = JSON.parse(await readFile(f.options.statePath, "utf8"));
      state.rows[0].sourceUserId = "user_arbitrary";
      await writeFile(f.options.statePath, JSON.stringify(state));
      await expect(f.phase("identities")).rejects.toThrow("outside the explicit inventory");
      await f.phase("plan");
      await f.phase("identities");
      f.stub.users.get("user_production2")!.externalId = "foreign-mapping";
      await expect(f.phase("apply")).rejects.toThrow("ownership did not match");
      expect(
        (
          await f.sql`select count(*)::int as count from users where clerk_id like 'user_source%'`
        )[0]?.count,
      ).toBe(2);
    }));
  it("revalidates primary verification and ban before apply", () =>
    fixture(async (f) => {
      await f.phase("plan");
      await f.phase("identities");
      const user = f.stub.users.get("user_production1")!;
      user.emailAddresses[0]!.verification!.status = "unverified";
      await expect(f.phase("apply")).rejects.toThrow("ownership did not match");
      user.emailAddresses[0]!.verification!.status = "verified";
      user.banned = false;
      await expect(f.phase("apply")).rejects.toThrow("ban was not preserved");
    }));
  it("rolls the whole reassociation back if a trigger mutates owned content", () =>
    fixture(async (f) => {
      await f.phase("plan");
      await f.phase("identities");
      const before = await f.allData();
      await f.sql`create function fixture_mutate_owned() returns trigger language plpgsql as $$ begin update progress set payload='{"episode":99}' where user_id=new.id; return new; end $$`;
      await f.sql`create trigger fixture_mutate after update on users for each row execute function fixture_mutate_owned()`;
      await expect(f.phase("apply")).rejects.toThrow("Owned data changed");
      expect(await f.allData()).toEqual(before);
      expect(
        (
          await f.sql`select count(*)::int as count from users where clerk_id like 'user_source%'`
        )[0]?.count,
      ).toBe(2);
    }));
  it("requires private files, correct production instance, trusted ledger and stopped service", () =>
    fixture(async (f) => {
      await chmod(f.options.inventoryPath, 0o644);
      await expect(f.phase("plan")).rejects.toThrow("private regular file");
      await chmod(f.options.inventoryPath, 0o600);
      await f.phase("plan");
      f.options.instanceId = "ins_other";
      await expect(f.phase("identities")).rejects.toThrow("destination does not match");
      f.options.instanceId = "ins_fixture";
      await expect(
        f.phase("identities", {
          requireStopped: async () => {
            throw new Error("service still running");
          },
        }),
      ).rejects.toThrow("service still running");
      await rm(join(f.ledgerDirectory, "current.json"));
      await expect(f.phase("identities")).rejects.toThrow();
      expect(f.stub.creates).toBe(0);
    }));
  it("prevents state overwriting a private input and removes transient locks", () =>
    fixture(async (f) => {
      await expect(
        runMigration({ ...f.options, statePath: f.options.sourceConfigPath }),
      ).rejects.toThrow("overwrite");
      await f.phase("plan");
      expect((await readdir(f.directory)).filter((name) => name.endsWith(".lock"))).toEqual([]);
    }));
  it("rejects duplicate/unverified inventories and excludes synthetic addresses case insensitively", () => {
    expect(() =>
      migrationInventory([
        { sourceUserId: "user_one", email: "A@example.invalid", verified: true },
        { sourceUserId: "user_two", email: "a@example.invalid", verified: true },
      ]),
    ).toThrow("Duplicate");
    expect(() =>
      migrationInventory([
        { sourceUserId: "user_one", email: "a@example.invalid", verified: false },
      ]),
    ).toThrow("verified");
    expect(
      migrationInventory([
        { sourceUserId: "user_one", email: "A+CLERK_TEST@example.invalid", verified: true },
      ]).excludedSynthetic,
    ).toBe(1);
  });
});
