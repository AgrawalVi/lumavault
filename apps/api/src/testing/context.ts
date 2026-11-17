// Test helpers for code that needs a real ModuleContext. Never imported by the server.
import { type ContextValues, createContextValues } from "@connectrpc/connect";
import { createAuth } from "#/auth/auth.js";
import { loadConfig } from "#/config.js";
import * as authTables from "#/db/schemas/auth.js";
import type { TestDatabase } from "#/db/testing.js";
import { createEmailService } from "#/email/emails.js";
import { createMailer } from "#/email/mailer.js";
import type { ModuleContext } from "#/modules.js";
import { requestKey } from "#/request.js";

export const TEST_WEB_ORIGIN = "http://localhost:3000";

export const TEST_ENV = {
  NODE_ENV: "test",
  DATABASE_URL: "postgres://localhost:1/unused",
  LUMAVAULT_GATEWAY_URL: "http://localhost:8080",
  LUMAVAULT_TICKET_SECRET: "test-ticket-secret-that-is-32-bytes-or-more",
  LUMAVAULT_SERVICE_KEY: "test-service-key",
  BETTER_AUTH_SECRET: "test-auth-secret-that-is-32-bytes-or-more",
  LUMAVAULT_WEB_ORIGINS: TEST_WEB_ORIGIN,
  LUMAVAULT_PORTAL_URL: TEST_WEB_ORIGIN,
};

/** A ModuleContext on a test database, with Better Auth wired to its tables. */
export function createTestContext(database: Pick<TestDatabase, "db">, env: Record<string, string> = {}): ModuleContext {
  const config = loadConfig({ ...TEST_ENV, ...env });
  const auth = createAuth({
    db: database.db,
    tables: authTables,
    secret: config.authSecret,
    baseURL: config.apiUrl,
    trustedOrigins: config.webOrigins,
    passkeyRpID: "localhost",
    sendMagicLink: async () => {},
  });
  const email = createEmailService(createMailer({ from: config.mailFrom, log: () => {} }));
  return { config, db: database.db, auth, email };
}

export interface TestUser {
  id: string;
  email: string;
  headers: Headers;
}

/** Signs up a user and returns bearer headers for their session. */
export async function signUp(ctx: ModuleContext, email: string): Promise<TestUser> {
  const res = await ctx.auth.api.signUpEmail({ body: { name: email.split("@")[0] ?? email, email, password: "correct horse battery" } });
  if (!res.token) {
    throw new Error(`sign-up for ${email} returned no session token`);
  }
  return { id: res.user.id, email, headers: new Headers({ authorization: `Bearer ${res.token}` }) };
}

/** Connect context values for an RPC sent with these headers. */
export function rpcValues(headers: Headers = new Headers()): ContextValues {
  return createContextValues().set(requestKey, new Request("http://api.test/api/rpc/x", { headers }));
}
