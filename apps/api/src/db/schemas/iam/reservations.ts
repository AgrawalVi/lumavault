import { sql } from "drizzle-orm";
import { bigint, check, index, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { organization, user } from "#/db/schemas/auth.js";
import { iamSchema } from "#/db/schemas/namespaces.js";
import { iamApp, uploadReservationStatus } from "./enums.js";
import { iamContributorGrants } from "./grants.js";

// Bytes held against a household's cap while an upload is in flight. A null household means
// the instance-wide shared library, which bills no household.
export const iamUploadReservations = iamSchema.table(
  "upload_reservations",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    householdId: text("household_id").references(() => organization.id, { onDelete: "cascade" }),
    grantId: uuid("grant_id").references(() => iamContributorGrants.id, { onDelete: "set null" }),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    app: iamApp("app").notNull(),
    bytes: bigint("bytes", { mode: "bigint" }).notNull(),
    status: uploadReservationStatus("status").notNull().default("pending"),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    settledAt: timestamp("settled_at", { withTimezone: true }),
  },
  (t) => [
    check("upload_reservations_bytes_positive", sql`${t.bytes} > 0`),
    index("upload_reservations_pending_expiry_idx").on(t.expiresAt).where(sql`${t.status} = 'pending'`),
  ],
);
