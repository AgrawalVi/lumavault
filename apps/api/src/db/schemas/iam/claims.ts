import { sql } from "drizzle-orm";
import { bigint, check, index, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { organization, user } from "#/db/schemas/auth.js";
import { iamSchema } from "#/db/schemas/namespaces.js";
import { iamApp } from "./enums.js";
import { iamUploadReservations } from "./reservations.js";

// Records which household paid for each stored Gateway object and who uploaded it. The object
// ID is the primary key, so an object can be claimed only once. releasedAt marks the one-time
// refund on delete.
export const iamObjectClaims = iamSchema.table(
  "object_claims",
  {
    objectId: text("object_id").primaryKey(),
    householdId: text("household_id").references(() => organization.id, { onDelete: "cascade" }),
    // Null for objects whose uploader has since deleted their account.
    uploadedBy: text("uploaded_by").references(() => user.id, { onDelete: "set null" }),
    reservationId: uuid("reservation_id")
      .unique()
      .references(() => iamUploadReservations.id, { onDelete: "set null" }),
    app: iamApp("app").notNull(),
    bytes: bigint("bytes", { mode: "bigint" }).notNull(),
    claimedAt: timestamp("claimed_at", { withTimezone: true }).notNull().defaultNow(),
    releasedAt: timestamp("released_at", { withTimezone: true }),
  },
  (t) => [
    check("object_claims_bytes_nonnegative", sql`${t.bytes} >= 0`),
    index("object_claims_household_uploader_idx").on(t.householdId, t.uploadedBy),
  ],
);
