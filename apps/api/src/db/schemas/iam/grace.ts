import { sql } from "drizzle-orm";
import { bigint, check, index, text, timestamp } from "drizzle-orm/pg-core";
import { organization, user } from "#/db/schemas/auth.js";
import { iamSchema } from "#/db/schemas/namespaces.js";

// A user removed from, or who left, a household without joining another. Their private data
// stays in the old household, read-only to them and still counted against its cap, until
// deleteAt. Joining a household before then moves it. A user has at most one grace period.
export const iamGracePeriods = iamSchema.table(
  "grace_periods",
  {
    userId: text("user_id")
      .primaryKey()
      .references(() => user.id, { onDelete: "cascade" }),
    householdId: text("household_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    // The household's name when they left, kept in case it is later renamed or closed.
    householdName: text("household_name").notNull(),
    heldBytes: bigint("held_bytes", { mode: "bigint" }).notNull().default(sql`'0'`),
    startedAt: timestamp("started_at", { withTimezone: true }).notNull().defaultNow(),
    deleteAt: timestamp("delete_at", { withTimezone: true }).notNull(),
  },
  (t) => [
    check("grace_periods_held_bytes_nonnegative", sql`${t.heldBytes} >= 0`),
    index("grace_periods_delete_at_idx").on(t.deleteAt),
  ],
);
