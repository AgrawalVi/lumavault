import { type ContextValues, createContextKey } from "@connectrpc/connect";
import { and, eq } from "drizzle-orm";
import { HOUSEHOLD_ADMIN_ROLE, HOUSEHOLD_MEMBER_ROLE, SUPER_ADMIN_ROLE } from "./auth/constants.js";
import { member } from "./db/schemas/auth.js";
import { iamHouseholds } from "./db/schemas/iam/households.js";
import type { ModuleContext } from "./modules.js";
import { requestKey } from "./request.js";

export type HouseholdRole = typeof HOUSEHOLD_ADMIN_ROLE | typeof HOUSEHOLD_MEMBER_ROLE;

export interface Viewer {
  userId: string;
  name: string;
  email: string;
  isSuperAdmin: boolean;
  sessionId: string;
  /** The household chosen on the server session, if any. */
  activeHouseholdId: string | null;
}

/** The viewer's membership in their active household. */
export interface ActiveHousehold {
  householdId: string;
  role: HouseholdRole;
  suspended: boolean;
}

export interface RequestContext {
  viewer: Viewer | null;
  /** Null when signed out, when no household is active, or when the viewer left it. */
  household: ActiveHousehold | null;
}

// Each RPC resolves its context at most once, even when several guards ask for it.
const resolvedKey = createContextKey<Promise<RequestContext> | undefined>(undefined, {
  description: "resolved request context",
});

/** Who is calling, from the session cookie or bearer token on the request. */
export function requestContext(values: ContextValues, ctx: ModuleContext): Promise<RequestContext> {
  let resolved = values.get(resolvedKey);
  if (!resolved) {
    resolved = resolve(values, ctx);
    values.set(resolvedKey, resolved);
  }
  return resolved;
}

async function resolve(values: ContextValues, ctx: ModuleContext): Promise<RequestContext> {
  const request = values.get(requestKey);
  if (!request) {
    return { viewer: null, household: null };
  }
  const session = await ctx.auth.api.getSession({ headers: request.headers });
  if (!session) {
    return { viewer: null, household: null };
  }
  const activeHouseholdId = session.session.activeOrganizationId ?? null;
  const viewer: Viewer = {
    userId: session.user.id,
    name: session.user.name,
    email: session.user.email,
    isSuperAdmin: hasRole(session.user.role, SUPER_ADMIN_ROLE),
    sessionId: session.session.id,
    activeHouseholdId,
  };
  if (!activeHouseholdId) {
    return { viewer, household: null };
  }
  const [row] = await ctx.db
    .select({ role: member.role, suspended: iamHouseholds.suspended })
    .from(member)
    .leftJoin(iamHouseholds, eq(iamHouseholds.householdId, member.organizationId))
    .where(and(eq(member.organizationId, activeHouseholdId), eq(member.userId, viewer.userId)))
    .limit(1);
  if (!row || !isHouseholdRole(row.role)) {
    return { viewer, household: null };
  }
  return {
    viewer,
    household: { householdId: activeHouseholdId, role: row.role, suspended: row.suspended ?? false },
  };
}

// The admin plugin stores roles as a comma-separated list.
function hasRole(roles: string | null | undefined, role: string): boolean {
  return (roles ?? "").split(",").some((r) => r.trim() === role);
}

function isHouseholdRole(role: string): role is HouseholdRole {
  return role === HOUSEHOLD_ADMIN_ROLE || role === HOUSEHOLD_MEMBER_ROLE;
}
