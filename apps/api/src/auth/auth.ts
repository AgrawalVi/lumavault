import { passkey } from "@better-auth/passkey";
import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { admin, bearer, magicLink, organization } from "better-auth/plugins";
import type { Db } from "#/db/index.js";
import {
  AUTH_BASE_PATH,
  DEFAULT_USER_ROLE,
  HOUSEHOLD_ADMIN_ROLE,
  PASSKEY_RP_NAME,
  SUPER_ADMIN_ROLE,
} from "./constants.js";
import { householdAccess, householdRoles } from "./roles.js";

export interface MagicLinkMessage {
  email: string;
  url: string;
  token: string;
}

export interface AuthDeps {
  db: Db;
  /** Drizzle tables Better Auth reads and writes, from src/db/schemas/auth.ts. */
  tables: Record<string, unknown>;
  secret: string;
  /** Public origin of this API server, for example http://localhost:4000. */
  baseURL: string;
  /** Web app origins allowed to call Better Auth with cookies. */
  trustedOrigins: string[];
  /** Hostname passkeys are bound to, shared by every web app, for example localhost. */
  passkeyRpID: string;
  /** Sends a magic-link email. Wired to the mailer in M2. */
  sendMagicLink: (message: MagicLinkMessage) => Promise<void>;
}

/** Builds the Better Auth instance. Sign-in flows, emails, and sign-up rules arrive in M2. */
export function createAuth(deps: AuthDeps) {
  return betterAuth({
    secret: deps.secret,
    baseURL: deps.baseURL,
    basePath: AUTH_BASE_PATH,
    trustedOrigins: deps.trustedOrigins,
    database: drizzleAdapter(deps.db, { provider: "pg", schema: deps.tables }),
    emailAndPassword: { enabled: true },
    plugins: [
      passkey({ rpID: deps.passkeyRpID, rpName: PASSKEY_RP_NAME, origin: deps.trustedOrigins }),
      magicLink({ sendMagicLink: (message) => deps.sendMagicLink(message) }),
      bearer(),
      admin({ adminRoles: [SUPER_ADMIN_ROLE], defaultRole: DEFAULT_USER_ROLE }),
      organization({ ac: householdAccess, roles: householdRoles, creatorRole: HOUSEHOLD_ADMIN_ROLE }),
    ],
  });
}

export type Auth = ReturnType<typeof createAuth>;
