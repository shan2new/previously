CREATE TABLE "account_deletions" (
	"identity_hash" text PRIMARY KEY NOT NULL,
	"clerk_id" text,
	"requested_at" timestamp with time zone DEFAULT now() NOT NULL,
	"completed_at" timestamp with time zone,
	"attempts" integer DEFAULT 0 NOT NULL,
	"next_attempt_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "account_deletions_pending_idx" ON "account_deletions" USING btree ("next_attempt_at") WHERE "account_deletions"."completed_at" is null;