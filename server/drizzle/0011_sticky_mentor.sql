CREATE TABLE "watch_sessions" (
	"id" uuid PRIMARY KEY NOT NULL,
	"user_id" uuid NOT NULL,
	"franchise_id" uuid NOT NULL,
	"scope_media_id" integer,
	"ordinal" integer NOT NULL,
	"started_at" bigint,
	"completed_at" bigint,
	"cancelled_at" bigint,
	"cancelled_at_episode" integer,
	"episodes" integer DEFAULT 0 NOT NULL,
	"restore_progress" jsonb,
	"restore_status" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"deleted_at" timestamp with time zone
);
--> statement-breakpoint
ALTER TABLE "watch_sessions" ADD CONSTRAINT "watch_sessions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "watch_sessions" ADD CONSTRAINT "watch_sessions_franchise_id_franchise_id_fk" FOREIGN KEY ("franchise_id") REFERENCES "public"."franchise"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "watch_sessions_user_idx" ON "watch_sessions" USING btree ("user_id","franchise_id");