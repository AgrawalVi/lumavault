interface BanFields {
  banned?: boolean | null;
  banExpires?: Date | null;
}

/** A ban with an expiry in the past no longer applies. */
export function isBanned(user: BanFields, now: Date = new Date()): boolean {
  if (!user.banned) {
    return false;
  }
  return !user.banExpires || user.banExpires > now;
}
