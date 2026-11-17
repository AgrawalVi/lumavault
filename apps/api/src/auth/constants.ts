// Better Auth is mounted under this path on the API server.
export const AUTH_BASE_PATH = "/api/auth";

// Admin plugin roles on the user. "admin" is the Super-Admin flag; everyone else is "user".
export const SUPER_ADMIN_ROLE = "admin";
export const DEFAULT_USER_ROLE = "user";

// Household roles, stored on Better Auth organization members. Whoever creates a household
// becomes its admin.
export const HOUSEHOLD_ADMIN_ROLE = "admin";
export const HOUSEHOLD_MEMBER_ROLE = "member";

export const PASSKEY_RP_NAME = "LumaVault";
