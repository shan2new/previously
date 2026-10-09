CREATE TABLE "client_mutation_operations" (
	"user_id" uuid NOT NULL,
	"operation_id" uuid NOT NULL,
	"writer_id" uuid NOT NULL,
	"sequence" bigint NOT NULL,
	"request_hash" text NOT NULL,
	"kind" text NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "client_mutation_operations_user_id_operation_id_pk" PRIMARY KEY("user_id","operation_id")
);
--> statement-breakpoint
CREATE TABLE "client_mutation_resources" (
	"user_id" uuid NOT NULL,
	"writer_id" uuid NOT NULL,
	"resource_key" text NOT NULL,
	"sequence" bigint NOT NULL,
	"deleted_sequence" bigint DEFAULT 0 NOT NULL,
	CONSTRAINT "client_mutation_resources_user_id_writer_id_resource_key_pk" PRIMARY KEY("user_id","writer_id","resource_key")
);
--> statement-breakpoint
ALTER TABLE "client_mutation_operations" ADD CONSTRAINT "client_mutation_operations_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "client_mutation_resources" ADD CONSTRAINT "client_mutation_resources_user_id_users_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."users"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "client_mutations_writer_sequence_uq" ON "client_mutation_operations" USING btree ("user_id","writer_id","sequence");