import { IAM_APPS } from "#/iam/constants.js";
import { iamSchema } from "#/db/schemas/namespaces.js";

export const iamApp = iamSchema.enum("app", IAM_APPS);

export const uploadReservationStatus = iamSchema.enum("upload_reservation_status", [
  "pending",
  "finished",
  "cancelled",
  "expired",
]);

export const pairingStatus = iamSchema.enum("pairing_status", ["pending", "approved", "claimed", "expired"]);
