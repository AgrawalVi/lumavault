import { Code, type ContextValues, ConnectError } from "@connectrpc/connect";
import { and, eq, isNull, or, sql } from "drizzle-orm";
import { HOUSEHOLD_ADMIN_ROLE } from "./auth/constants.js";
import { type ActiveHousehold, requestContext, type Viewer } from "./context.js";
import { iamContributorGrants } from "./db/schemas/iam/grants.js";
import { iamHouseholds } from "./db/schemas/iam/households.js";
import type { ModuleContext } from "./modules.js";

/** The part of a Connect handler context the guards read. */
export interface GuardInput {
  values: ContextValues;
}

export interface HouseholdCaller {
  viewer: Viewer;
  household: ActiveHousehold;
}

export type ContributorGrant = typeof iamContributorGrants.$inferSelect;

/** Any signed-in user. Use for viewer and household switching, which must work while suspended. */
export async function requireSignedIn(input: GuardInput, ctx: ModuleContext): Promise<Viewer> {
  const { viewer } = await requestContext(input.values, ctx);
  if (!viewer) {
    throw new ConnectError("sign in required", Code.Unauthenticated);
  }
  return viewer;
}

/** The server owner. Reachable no matter which household is active or suspended. */
export async function requireSuperAdmin(input: GuardInput, ctx: ModuleContext): Promise<Viewer> {
  const viewer = await requireSignedIn(input, ctx);
  if (!viewer.isSuperAdmin) {
    throw new ConnectError("Super-Admin only", Code.PermissionDenied);
  }
  return viewer;
}

/** Any member of the active household. A suspended household blocks its own data routes. */
export async function requireHouseholdMember(input: GuardInput, ctx: ModuleContext): Promise<HouseholdCaller> {
  const viewer = await requireSignedIn(input, ctx);
  const { household } = await requestContext(input.values, ctx);
  if (!household) {
    throw new ConnectError("no active household", Code.FailedPrecondition);
  }
  if (household.suspended) {
    throw new ConnectError("household is suspended", Code.PermissionDenied);
  }
  return { viewer, household };
}

/** An Admin of the active household. */
export async function requireHouseholdAdmin(input: GuardInput, ctx: ModuleContext): Promise<HouseholdCaller> {
  const caller = await requireHouseholdMember(input, ctx);
  if (caller.household.role !== HOUSEHOLD_ADMIN_ROLE) {
    throw new ConnectError("household Admin only", Code.PermissionDenied);
  }
  return caller;
}

/**
 * An unrevoked contributor grant issued to the caller, by user ID or by email before their
 * first sign-in. The granting household must not be suspended.
 */
export async function requireContributorGrant(
  input: GuardInput,
  ctx: ModuleContext,
  grantId: string,
): Promise<{ viewer: Viewer; grant: ContributorGrant }> {
  const viewer = await requireSignedIn(input, ctx);
  const [row] = await ctx.db
    .select({ grant: iamContributorGrants, suspended: iamHouseholds.suspended })
    .from(iamContributorGrants)
    .leftJoin(iamHouseholds, eq(iamHouseholds.householdId, iamContributorGrants.householdId))
    .where(
      and(
        eq(iamContributorGrants.id, sql`${grantId}::uuid`),
        isNull(iamContributorGrants.revokedAt),
        or(
          eq(iamContributorGrants.granteeUserId, viewer.userId),
          eq(iamContributorGrants.granteeEmail, viewer.email.toLowerCase()),
        ),
      ),
    )
    .limit(1)
    .catch((err: unknown) => {
      // A malformed ID is just a grant the caller does not have.
      if ((err as { cause?: { code?: string } }).cause?.code === "22P02") {
        return [];
      }
      throw err;
    });
  if (!row) {
    throw new ConnectError("no such contributor grant", Code.PermissionDenied);
  }
  if (row.suspended) {
    throw new ConnectError("household is suspended", Code.PermissionDenied);
  }
  return { viewer, grant: row.grant };
}
