CREATE TABLE "media_broadcast_times" (
	"media_id" integer PRIMARY KEY NOT NULL,
	"provider" text DEFAULT 'tvmaze' NOT NULL,
	"times" jsonb NOT NULL,
	"checked_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
ALTER TABLE "media_broadcast_times" ADD CONSTRAINT "media_broadcast_times_media_id_media_id_fk" FOREIGN KEY ("media_id") REFERENCES "public"."media"("id") ON DELETE cascade ON UPDATE no action;