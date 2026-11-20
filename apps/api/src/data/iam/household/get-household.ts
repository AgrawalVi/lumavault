import { eq } from "drizzle-orm";
import { isHouseholdRole } from "#/auth/role-checks.js";
import { member } from "#/db/schemas/auth.js";
import { iamHouseholds } from "#/db/schemas/iam.js";
import type { DbOrTx } from "#/db/index.js";
import type { HouseholdMembership } from "./types.js";

/** A user's one household, read from membership rather than the session, so it is always current. */
export async function getHouseholdByUserId(db: DbOrTx, userId: string): Promise<HouseholdMembership | null> {
  const [row] = await db
    .select({ householdId: member.organizationId, role: member.role, suspended: iamHouseholds.suspended })
    .from(member)
    .leftJoin(iamHouseholds, eq(iamHouseholds.householdId, member.organizationId))
    .where(eq(member.userId, userId))
    .limit(1);
  if (!row || !isHouseholdRole(row.role)) {
    return null;
  }
  return { householdId: row.householdId, role: row.role, suspended: row.suspended ?? false };
}
