import { sql } from "drizzle-orm";
import { index, text, timestamp, uniqueIndex, uuid } from "drizzle-orm/pg-core";
import { organization, user } from "#/db/schemas/auth.js";
import { iamSchema } from "#/db/schemas/namespaces.js";
import { iamApp } from "./enums.js";

// Lets someone outside a household add to one app resource, such as a Photos album. Their
// uploads are billed to the granting household. The app defines resource kind and ID.
export const iamContributorGrants = iamSchema.table(
  "contributor_grants",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    householdId: text("household_id")
      .notNull()
      .references(() => organization.id, { onDelete: "cascade" }),
    app: iamApp("app").notNull(),
    resourceKind: text("resource_kind").notNull(),
    resourceId: text("resource_id").notNull(),
    // Stored lowercased so lookups at sign-in match.
    granteeEmail: text("grantee_email").notNull(),
    granteeUserId: text("grantee_user_id").references(() => user.id, { onDelete: "set null" }),
    createdBy: text("created_by")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
  },
  (t) => [
    uniqueIndex("contributor_grants_active_unique")
      .on(t.householdId, t.app, t.resourceKind, t.resourceId, t.granteeEmail)
      .where(sql`${t.revokedAt} is null`),
    index("contributor_grants_grantee_email_idx").on(t.granteeEmail),
  ],
);
