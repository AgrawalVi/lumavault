import { sql } from "drizzle-orm";
import { bigint, boolean, check, integer, text, timestamp } from "drizzle-orm/pg-core";
import { DEFAULT_MEMBER_LIMIT, type IamApp } from "#/iam/constants.js";
import { enabledAppsCheck } from "./enabled-apps.js";
import { organization } from "#/db/schemas/auth.js";
import { iamSchema } from "#/db/schemas/namespaces.js";

// One row per Better Auth organization: the allowance the Super-Admin grants, and the
// household's storage accounting. Reserved bytes belong to uploads not yet finished.
export const iamHouseholds = iamSchema.table(
  "households",
  {
    householdId: text("household_id")
      .primaryKey()
      .references(() => organization.id, { onDelete: "cascade" }),
    storageCapBytes: bigint("storage_cap_bytes", { mode: "bigint" }).notNull().default(sql`'0'`),
    enabledApps: text("enabled_apps").array().$type<IamApp[]>().notNull().$defaultFn(() => []),
    memberLimit: integer("member_limit").notNull().default(DEFAULT_MEMBER_LIMIT),
    usedBytes: bigint("used_bytes", { mode: "bigint" }).notNull().default(sql`'0'`),
    reservedBytes: bigint("reserved_bytes", { mode: "bigint" }).notNull().default(sql`'0'`),
    suspended: boolean("suspended").notNull().default(false),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    updatedAt: timestamp("updated_at", { withTimezone: true })
      .notNull()
      .defaultNow()
      .$onUpdate(() => new Date()),
  },
  (t) => [
    enabledAppsCheck("households", t.enabledApps),
    check("households_storage_cap_bytes_nonnegative", sql`${t.storageCapBytes} >= 0`),
    check("households_used_bytes_nonnegative", sql`${t.usedBytes} >= 0`),
    check("households_reserved_bytes_nonnegative", sql`${t.reservedBytes} >= 0`),
    check("households_member_limit_positive", sql`${t.memberLimit} >= 1`),
  ],
);
