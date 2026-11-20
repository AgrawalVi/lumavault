import type { HouseholdRole } from "#/auth/constants.js";

/** A user's one household and their role in it. */
export interface HouseholdMembership {
  householdId: string;
  role: HouseholdRole;
  suspended: boolean;
}
