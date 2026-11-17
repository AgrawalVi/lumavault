import { Code, ConnectError } from "@connectrpc/connect";
import { eq } from "drizzle-orm";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { SUPER_ADMIN_ROLE } from "./auth/constants.js";
import { requestContext } from "./context.js";
import { user } from "./db/schemas/auth.js";
import { iamContributorGrants } from "./db/schemas/iam/grants.js";
import { iamHouseholds } from "./db/schemas/iam/households.js";
import { createTestDatabase, pushAllSchemas, type TestDatabase } from "./db/testing.js";
import {
  type GuardInput,
  requireContributorGrant,
  requireHouseholdAdmin,
  requireHouseholdMember,
  requireSignedIn,
  requireSuperAdmin,
} from "./guards.js";
import type { ModuleContext } from "./modules.js";
import { createTestContext, rpcValues, signUp, type TestUser } from "./testing/context.js";

let database: TestDatabase;
let ctx: ModuleContext;
let admin: TestUser;
let memberUser: TestUser;
let outsider: TestUser;
let owner: TestUser;
let householdId: string;

const as = (u?: TestUser): GuardInput => ({ values: rpcValues(u?.headers) });

async function codeOf(promise: Promise<unknown>): Promise<Code | "ok"> {
  try {
    await promise;
    return "ok";
  } catch (err) {
    return ConnectError.from(err).code;
  }
}

async function setSuspended(id: string, suspended: boolean): Promise<void> {
  await database.db.update(iamHouseholds).set({ suspended }).where(eq(iamHouseholds.householdId, id));
}

beforeAll(async () => {
  database = await createTestDatabase();
  await pushAllSchemas(database);
  ctx = createTestContext(database);

  admin = await signUp(ctx, "admin@example.com");
  memberUser = await signUp(ctx, "member@example.com");
  outsider = await signUp(ctx, "outsider@example.com");
  owner = await signUp(ctx, "owner@example.com");
  await database.db.update(user).set({ role: SUPER_ADMIN_ROLE }).where(eq(user.id, owner.id));

  const household = await ctx.auth.api.createOrganization({ body: { name: "Home", slug: "home" }, headers: admin.headers });
  householdId = household!.id;
  await database.db.insert(iamHouseholds).values({ householdId });
  await ctx.auth.api.addMember({ body: { userId: memberUser.id, organizationId: householdId, role: "member" } });
  await ctx.auth.api.setActiveOrganization({ body: { organizationId: householdId }, headers: memberUser.headers });
});

afterAll(async () => {
  await database?.drop();
});

describe("requestContext", () => {
  it("is empty when signed out", async () => {
    expect(await requestContext(as().values, ctx)).toEqual({ viewer: null, household: null });
  });

  it("reads the viewer, active household, and role", async () => {
    const { viewer, household } = await requestContext(as(admin).values, ctx);
    expect(viewer).toMatchObject({ userId: admin.id, isSuperAdmin: false, activeHouseholdId: householdId });
    expect(household).toEqual({ householdId, role: "admin", suspended: false });
  });

  it("resolves once per request", async () => {
    const input = as(admin);
    expect(requestContext(input.values, ctx)).toBe(requestContext(input.values, ctx));
  });
});

describe("guards", () => {
  it("requireSignedIn rejects signed-out callers with unauthenticated", async () => {
    expect(await codeOf(requireSignedIn(as(), ctx))).toBe(Code.Unauthenticated);
    expect(await codeOf(requireSignedIn(as(outsider), ctx))).toBe("ok");
  });

  it("requireSuperAdmin allows only the Super-Admin", async () => {
    expect(await codeOf(requireSuperAdmin(as(), ctx))).toBe(Code.Unauthenticated);
    expect(await codeOf(requireSuperAdmin(as(admin), ctx))).toBe(Code.PermissionDenied);
    expect(await codeOf(requireSuperAdmin(as(owner), ctx))).toBe("ok");
  });

  it("requireHouseholdMember needs an active household", async () => {
    expect(await codeOf(requireHouseholdMember(as(outsider), ctx))).toBe(Code.FailedPrecondition);
    expect(await codeOf(requireHouseholdMember(as(memberUser), ctx))).toBe("ok");
    expect(await codeOf(requireHouseholdMember(as(admin), ctx))).toBe("ok");
  });

  it("requireHouseholdAdmin allows only Admins", async () => {
    expect(await codeOf(requireHouseholdAdmin(as(memberUser), ctx))).toBe(Code.PermissionDenied);
    expect(await codeOf(requireHouseholdAdmin(as(admin), ctx))).toBe("ok");
  });

  it("a removed member loses the household even if the session still points at it", async () => {
    const leaver = await signUp(ctx, "leaver@example.com");
    await ctx.auth.api.addMember({ body: { userId: leaver.id, organizationId: householdId, role: "member" } });
    await ctx.auth.api.setActiveOrganization({ body: { organizationId: householdId }, headers: leaver.headers });
    expect(await codeOf(requireHouseholdMember(as(leaver), ctx))).toBe("ok");
    await ctx.auth.api.removeMember({ body: { memberIdOrEmail: leaver.email, organizationId: householdId }, headers: admin.headers });
    expect(await codeOf(requireHouseholdMember(as(leaver), ctx))).toBe(Code.FailedPrecondition);
  });
});

describe("suspended household", () => {
  it("blocks its data routes but not viewer or Super-Admin routes", async () => {
    await ctx.auth.api.addMember({ body: { userId: owner.id, organizationId: householdId, role: "member" } });
    await ctx.auth.api.setActiveOrganization({ body: { organizationId: householdId }, headers: owner.headers });
    await setSuspended(householdId, true);
    try {
      expect(await codeOf(requireHouseholdMember(as(memberUser), ctx))).toBe(Code.PermissionDenied);
      expect(await codeOf(requireHouseholdAdmin(as(admin), ctx))).toBe(Code.PermissionDenied);
      expect(await codeOf(requireSignedIn(as(memberUser), ctx))).toBe("ok");
      expect(await codeOf(requireSuperAdmin(as(owner), ctx))).toBe("ok");
    } finally {
      await setSuspended(householdId, false);
    }
  });
});

describe("requireContributorGrant", () => {
  let grantId: string;

  beforeAll(async () => {
    const [grant] = await database.db
      .insert(iamContributorGrants)
      .values({
        householdId,
        app: "photos",
        resourceKind: "album",
        resourceId: "album-1",
        granteeEmail: outsider.email,
        createdBy: admin.id,
      })
      .returning();
    grantId = grant!.id;
  });

  it("allows the grantee, matched by email before first use", async () => {
    const { grant } = await requireContributorGrant(as(outsider), ctx, grantId);
    expect(grant.resourceId).toBe("album-1");
  });

  it("rejects other users, malformed IDs, and revoked grants", async () => {
    expect(await codeOf(requireContributorGrant(as(memberUser), ctx, grantId))).toBe(Code.PermissionDenied);
    expect(await codeOf(requireContributorGrant(as(outsider), ctx, "not-a-uuid"))).toBe(Code.PermissionDenied);
    expect(await codeOf(requireContributorGrant(as(), ctx, grantId))).toBe(Code.Unauthenticated);
    await database.db.update(iamContributorGrants).set({ revokedAt: new Date() }).where(eq(iamContributorGrants.id, grantId));
    expect(await codeOf(requireContributorGrant(as(outsider), ctx, grantId))).toBe(Code.PermissionDenied);
  });
});
