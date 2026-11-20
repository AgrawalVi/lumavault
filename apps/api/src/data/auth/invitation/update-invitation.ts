import { eq } from "drizzle-orm";
import type { DbOrTx } from "#/db/index.js";
import { invitation } from "#/db/schemas/auth.js";

export async function markInvitationAccepted(db: DbOrTx, invitationId: string): Promise<void> {
  await db.update(invitation).set({ status: "accepted" }).where(eq(invitation.id, invitationId));
}
