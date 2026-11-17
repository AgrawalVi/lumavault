import { createAccessControl } from "better-auth/plugins/access";
import { defaultStatements, memberAc, ownerAc } from "better-auth/plugins/organization/access";
import { HOUSEHOLD_ADMIN_ROLE, HOUSEHOLD_MEMBER_ROLE } from "./constants.js";

// Households have two roles. Admins get everything Better Auth's owner role gets, members
// get its member defaults. IamService enforces the household rules on top of these.
export const householdAccess = createAccessControl(defaultStatements);

export const householdRoles = {
  [HOUSEHOLD_ADMIN_ROLE]: householdAccess.newRole(ownerAc.statements),
  [HOUSEHOLD_MEMBER_ROLE]: householdAccess.newRole(memberAc.statements),
};
