CREATE TABLE "recommendation_impressions" (
	"user_id" uuid NOT NULL,
	"key" text NOT NULL,
	"visits" integer DEFAULT 1 NOT NULL,
	"first_shown_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_shown_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "recommendation_impressions_user_id_key_pk" PRIMARY KEY("user_id","key")
);
--> statement-breakpoint
ALTER TABLE "recommendation_impressions" ADD CONSTRAINT "recommendation_impressions_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;