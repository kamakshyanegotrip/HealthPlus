#!/usr/bin/env node
/**
 * HealthPlus migration runner (HP-OIR-003 build item 3/5).
 *
 * Applies every .sql file in this directory, in filename-sorted order,
 * against the database named by DATABASE_URL. Filename order is load-bearing
 * (see migrations/README.md) -- 001_003_reconciled_baseline.sql must run
 * before 003a_..., which must run before 004_..., and so on through
 * 026e_....sql. Files in migrations/ops/ are NOT applied by this script --
 * those are operational wiring (pg_cron schedules), not schema, and are run
 * separately once pg_cron is enabled on the project.
 *
 * This does not read, log, or transmit the connection string anywhere except
 * to the `pg` client itself -- it comes only from the DATABASE_URL
 * environment variable you set in your own shell.
 *
 * Usage (PowerShell):
 *   $env:DATABASE_URL = "postgresql://postgres:<password>@<host>:5432/postgres"
 *   node migrations/run_migrations.mjs
 *
 * Usage (bash):
 *   export DATABASE_URL="postgresql://postgres:<password>@<host>:5432/postgres"
 *   node migrations/run_migrations.mjs
 *
 * Add --dry-run to list the files that would run, in order, without
 * connecting to any database or executing anything.
 */
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const MIGRATIONS_DIR = dirname(fileURLToPath(import.meta.url));

function listMigrationFiles() {
  return readdirSync(MIGRATIONS_DIR)
    .filter((name) => name.endsWith('.sql'))
    .sort(); // filename order is the execution order -- see migrations/README.md
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const files = listMigrationFiles();

  if (files.length === 0) {
    console.error(`No .sql files found in ${MIGRATIONS_DIR}`);
    process.exit(1);
  }

  console.log(`Found ${files.length} migration file(s), in this order:`);
  for (const f of files) console.log(`  ${f}`);
  console.log('');

  if (dryRun) {
    console.log('--dry-run: not connecting to any database.');
    return;
  }

  const databaseUrl = process.env.DATABASE_URL;
  if (!databaseUrl) {
    console.error(
      'DATABASE_URL is not set. Set it in your own shell first -- this script never asks for or stores it.\n' +
        '  PowerShell: $env:DATABASE_URL = "postgresql://postgres:<password>@<host>:5432/postgres"\n' +
        '  bash:       export DATABASE_URL="postgresql://postgres:<password>@<host>:5432/postgres"',
    );
    process.exit(1);
  }

  const { Client } = await import('pg');
  const client = new Client({ connectionString: databaseUrl });
  await client.connect();

  try {
    for (const file of files) {
      const sql = readFileSync(join(MIGRATIONS_DIR, file), 'utf8');
      process.stdout.write(`Applying ${file} ... `);
      try {
        await client.query(sql);
        console.log('OK');
      } catch (err) {
        console.log('FAILED');
        console.error(`\n${file} failed. Stopping here -- earlier migrations in this run already committed.`);
        console.error(String(err?.message ?? err));
        process.exitCode = 1;
        return;
      }
    }
    console.log('\nAll migrations applied successfully.');
  } finally {
    await client.end();
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
