import { type SQL, sql } from "drizzle-orm";
import { check, type PgColumn } from "drizzle-orm/pg-core";
import { IAM_APPS } from "#/iam/constants.js";

// Enabled apps are a text array checked against the app list. drizzle-kit keeps re-altering
// enum arrays and array defaults, so tables use a plain array with this check and a
// default set in code.
export function enabledAppsCheck(table: string, column: PgColumn) {
  const allowed: SQL = sql.raw(`array[${IAM_APPS.map((a) => `'${a}'`).join(", ")}]::text[]`);
  return check(`${table}_enabled_apps_known`, sql`${column} <@ ${allowed}`);
}
