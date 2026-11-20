import { eq } from "drizzle-orm";
import type { DbOrTx } from "#/db/index.js";
import { user } from "#/db/schemas/auth.js";

export async function setUserRole(db: DbOrTx, userId: string, role: string): Promise<void> {
  await db.update(user).set({ role }).where(eq(user.id, userId));
}
