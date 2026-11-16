-- Runs once when the Postgres volume is first created. Each LumaVault app owns one schema.
CREATE SCHEMA IF NOT EXISTS photos;
CREATE SCHEMA IF NOT EXISTS cinema;
CREATE SCHEMA IF NOT EXISTS arcade;
