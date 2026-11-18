// Better Auth is mounted under this path on the API server.
export const AUTH_BASE_PATH = "/api/auth";

// Admin plugin roles on the user. "admin" is the Super-Admin flag; everyone else is "user".
export const SUPER_ADMIN_ROLE = "admin";
export const DEFAULT_USER_ROLE = "user";

// Household roles, stored on Better Auth organization members. Each household has exactly one
// owner, who created it or was handed it, and who has every admin power.
export const HOUSEHOLD_OWNER_ROLE = "owner";
export const HOUSEHOLD_ADMIN_ROLE = "admin";
export const HOUSEHOLD_MEMBER_ROLE = "member";

export const PASSKEY_RP_NAME = "LumaVault";
