import { type ContextValues, createContextKey } from "@connectrpc/connect";
import { eq } from "drizzle-orm";
import {
  HOUSEHOLD_ADMIN_ROLE,
  HOUSEHOLD_MEMBER_ROLE,
  HOUSEHOLD_OWNER_ROLE,
  SUPER_ADMIN_ROLE,
} from "./auth/constants.js";
import { member } from "./db/schemas/auth.js";
import { iamHouseholds } from "./db/schemas/iam.js";
import type { ModuleContext } from "./modules.js";
import { requestKey } from "./request.js";

export type HouseholdRole = typeof HOUSEHOLD_OWNER_ROLE | typeof HOUSEHOLD_ADMIN_ROLE | typeof HOUSEHOLD_MEMBER_ROLE;

export interface Viewer {
  userId: string;
  name: string;
  email: string;
  isSuperAdmin: boolean;
  sessionId: string;
}

/** The viewer's one household and their role in it. */
export interface HouseholdMembership {
  householdId: string;
  role: HouseholdRole;
  suspended: boolean;
}

export interface RequestContext {
  viewer: Viewer | null;
  /** Null when signed out, or when the viewer belongs to no household. */
  household: HouseholdMembership | null;
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
  const viewer: Viewer = {
    userId: session.user.id,
    name: session.user.name,
    email: session.user.email,
    isSuperAdmin: hasRole(session.user.role, SUPER_ADMIN_ROLE),
    sessionId: session.session.id,
  };
  return { viewer, household: await householdOf(ctx, viewer.userId) };
}

/** A user's one household, read from membership rather than the session, so it is always current. */
export async function householdOf(ctx: Pick<ModuleContext, "db">, userId: string): Promise<HouseholdMembership | null> {
  const [row] = await ctx.db
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

// The admin plugin stores roles as a comma-separated list.
function hasRole(roles: string | null | undefined, role: string): boolean {
  return (roles ?? "").split(",").some((r) => r.trim() === role);
}

export function isHouseholdRole(role: string): role is HouseholdRole {
  return role === HOUSEHOLD_OWNER_ROLE || role === HOUSEHOLD_ADMIN_ROLE || role === HOUSEHOLD_MEMBER_ROLE;
}
