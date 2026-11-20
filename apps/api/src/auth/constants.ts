// Better Auth is mounted under this path on the API server.
export const AUTH_BASE_PATH = "/api/auth";

// Admin plugin roles on the user. "admin" is the Super-Admin flag; everyone else is "user".
export const SUPER_ADMIN_ROLE = "admin";
export const DEFAULT_USER_ROLE = "user";
export const USER_ROLES = [SUPER_ADMIN_ROLE, DEFAULT_USER_ROLE] as const;
export type UserRole = (typeof USER_ROLES)[number];

// Household roles, stored on Better Auth organization members. Each household has exactly one
// owner, who created it or was handed it, and who has every admin power.
export const HOUSEHOLD_OWNER_ROLE = "owner";
export const HOUSEHOLD_ADMIN_ROLE = "admin";
export const HOUSEHOLD_MEMBER_ROLE = "member";
export const HOUSEHOLD_ROLES = [HOUSEHOLD_OWNER_ROLE, HOUSEHOLD_ADMIN_ROLE, HOUSEHOLD_MEMBER_ROLE] as const;
export type HouseholdRole = (typeof HOUSEHOLD_ROLES)[number];

export const PASSKEY_RP_NAME = "LumaVault";

// Better Auth routes clients may never call. IamService does these actions server-side.
export const LOCKED_AUTH_PREFIXES = ["/organization/", "/admin/"] as const;
