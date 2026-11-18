import { sql } from "drizzle-orm";
import { bigint, check, index, integer, text, timestamp, uuid } from "drizzle-orm/pg-core";
import { DEFAULT_MEMBER_LIMIT, type IamApp, SECRET_HASH_PATTERN } from "#/iam/constants.js";
import { enabledAppsCheck } from "./enabled-apps.js";
import { organization, user } from "#/db/schemas/auth.js";
import { iamSchema } from "#/db/schemas/namespaces.js";

// Single-use links from the Super-Admin that let one email address create a household with a
// preset allowance. Only the SHA-256 of the link's secret is stored.
export const iamHouseholdInvites = iamSchema.table(
  "household_invites",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    tokenHash: text("token_hash").notNull().unique(),
    // Stored lowercased; only this address can use the invite.
    email: text("email").notNull(),
    storageCapBytes: bigint("storage_cap_bytes", { mode: "bigint" }).notNull(),
    enabledApps: text("enabled_apps").array().$type<IamApp[]>().notNull().$defaultFn(() => []),
    memberLimit: integer("member_limit").notNull().default(DEFAULT_MEMBER_LIMIT),
    note: text("note").notNull().default(""),
    createdBy: text("created_by")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    redeemedAt: timestamp("redeemed_at", { withTimezone: true }),
    redeemedBy: text("redeemed_by").references(() => user.id, { onDelete: "set null" }),
    householdId: text("household_id").references(() => organization.id, { onDelete: "set null" }),
    revokedAt: timestamp("revoked_at", { withTimezone: true }),
  },
  (t) => [
    enabledAppsCheck("household_invites", t.enabledApps),
    check("household_invites_token_hash_is_sha256", sql`${t.tokenHash} ~ ${sql.raw(`'${SECRET_HASH_PATTERN}'`)}`),
    check("household_invites_storage_cap_bytes_nonnegative", sql`${t.storageCapBytes} >= 0`),
    check("household_invites_member_limit_positive", sql`${t.memberLimit} >= 1`),
    index("household_invites_email_idx").on(t.email),
  ],
);
