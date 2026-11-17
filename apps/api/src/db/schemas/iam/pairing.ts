import { sql } from "drizzle-orm";
import { check, index, integer, text, timestamp, uniqueIndex, uuid } from "drizzle-orm/pg-core";
import { SECRET_HASH_PATTERN } from "#/iam/constants.js";
import { organization, user } from "#/db/schemas/auth.js";
import { iamSchema } from "#/db/schemas/namespaces.js";
import { pairingStatus } from "./enums.js";

// Apple TV sign-in by short code. The Apple TV keeps the device secret; only its SHA-256 is
// stored. The bearer session is minted when the Apple TV claims an approved request, so no
// session token is ever stored here.
export const iamPairingRequests = iamSchema.table(
  "pairing_requests",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    code: text("code").notNull(),
    deviceSecretHash: text("device_secret_hash").notNull(),
    deviceName: text("device_name").notNull(),
    status: pairingStatus("status").notNull().default("pending"),
    failedAttempts: integer("failed_attempts").notNull().default(0),
    requesterIp: text("requester_ip").notNull(),
    approvedBy: text("approved_by").references(() => user.id, { onDelete: "cascade" }),
    householdId: text("household_id").references(() => organization.id, { onDelete: "cascade" }),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
    expiresAt: timestamp("expires_at", { withTimezone: true }).notNull(),
    approvedAt: timestamp("approved_at", { withTimezone: true }),
    claimedAt: timestamp("claimed_at", { withTimezone: true }),
  },
  (t) => [
    check("pairing_requests_device_secret_hash_is_sha256", sql`${t.deviceSecretHash} ~ ${sql.raw(`'${SECRET_HASH_PATTERN}'`)}`),
    check("pairing_requests_failed_attempts_nonnegative", sql`${t.failedAttempts} >= 0`),
    uniqueIndex("pairing_requests_pending_code_unique").on(t.code).where(sql`${t.status} = 'pending'`),
    index("pairing_requests_requester_ip_idx").on(t.requesterIp, t.createdAt),
  ],
);
