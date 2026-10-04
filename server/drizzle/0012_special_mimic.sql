CREATE TABLE "user_audience" (
	"user_id" uuid PRIMARY KEY NOT NULL,
	"audience" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "user_audience" ADD CONSTRAINT "user_audience_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;