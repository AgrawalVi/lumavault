import { sql } from "drizzle-orm";
import { check, smallint, timestamp } from "drizzle-orm/pg-core";
import { INSTANCE_SETTINGS_ID } from "#/iam/constants.js";
import { iamSchema } from "#/db/schemas/namespaces.js";

// Exactly one row. First-run setup locks it, so two parallel setup calls cannot both create
// a Super-Admin.
export const iamInstanceSettings = iamSchema.table(
  "instance_settings",
  {
    id: smallint("id").primaryKey().default(INSTANCE_SETTINGS_ID),
    setupCompletedAt: timestamp("setup_completed_at", { withTimezone: true }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [check("instance_settings_single_row", sql`${t.id} = ${sql.raw(String(INSTANCE_SETTINGS_ID))}`)],
);
