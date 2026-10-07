// Standalone smoke test for the lib/db layer against local Postgres.
// Proves: pool connects, withUser sets identity+role, RLS applies, rpc works,
// forged identity sees nothing. Run after building neon_app + diocese_app role:
//   DATABASE_URL="postgres://diocese_app:devpw@localhost:5432/neon_app" \
//     node db/neon/tests/libdb_smoke.mjs
// (uses pg directly, mirroring src/lib/db/client.ts withUser logic, so it can
//  run as a plain .mjs without the Next/server-only import.)
import pg from 'pg';

const url = process.env.DATABASE_URL;
if (!url) { console.error('set DATABASE_URL'); process.exit(1); }
const pool = new pg.Pool({ connectionString: url, max: 4 });

async function withUser(uid, role, cb) {
  const c = await pool.connect();
  try {
    await c.query('begin');
    // set identity FIRST (while still the privileged app role that may execute
    // app.set_user), THEN drop to the RLS role. The GUC set by set_config(...,
    // true) is tx-local and survives SET ROLE.
    await c.query('select app.set_user($1::uuid, $2)', [uid, role]);
    await c.query(`set local role ${role}`);
    const out = await cb(c);
    await c.query('commit');
    return out;
  } catch (e) { try { await c.query('rollback'); } catch {} throw e; }
  finally { try { await c.query('reset role'); } catch {}; c.release(); }
}

let failures = 0;
const check = (name, cond) => { if (cond) console.log('  PASS', name); else { console.log('  FAIL', name); failures++; } };

try {
  // 1) owner sees all churches (seed from 30_bootstrap has 0 churches, so we
  //    assert identity resolution + role instead of row counts)
  const whoami = await withUser('00000000-0000-0000-0000-000000000000', 'anon', async (c) => {
    const r = await c.query('select app.uid() as uid, app.role() as role');
    return r.rows[0];
  });
  check('anon identity cleared/zero', whoami.role === 'anon');

  // 2) owner login via rpc (the bootstrap owner 000000/000000)
  const login = await withUser(null, 'anon', async (c) => {
    const r = await c.query("select public.account_login('000000','000000',true) as result");
    return r.rows[0].result;
  });
  check('account_login returns owner', login && login.person && login.person.code === '000000');
  check('account_login lists accounts', Array.isArray(login.accounts) && login.accounts.length >= 1);

  // 3) resolve servant session end-to-end through the layer
  const result = await withUser(null, 'service_role', async (c) => {
    const grant = login.grant;
    const sess = (await c.query(
      "select public.account_session_from_login($1,'servant',null,null,null,null,'smoke') as r",
      [grant]
    )).rows[0].r;
    const token = sess.token;
    const resolved = (await c.query('select public.servant_session_resolve($1) as r', [token])).rows[0].r;
    return { sess, resolved };
  });
  check('servant session is a token (not ticket)', result.sess.kind === 'servant' && !!result.sess.token && !result.sess.ticket);
  check('token resolves to the owner servant id', result.resolved === result.sess.servant_id);

  // 4) with that identity, RLS sees owner role
  const asOwner = await withUser(result.resolved, 'authenticated', async (c) => {
    const r = await c.query('select public.my_role() as role, public.is_owner() as owner');
    return r.rows[0];
  });
  check('RLS identity = owner', asOwner.role === 'owner' && asOwner.owner === true);

  // 5) forged identity → null role, not owner
  const forged = await withUser('ffffffff-ffff-ffff-ffff-ffffffffffff', 'authenticated', async (c) => {
    const r = await c.query('select public.my_role() as role, public.is_owner() as owner, (select count(*) from public.churches)::int as churches');
    return r.rows[0];
  });
  check('forged identity has null role', forged.role === null);
  check('forged identity not owner', forged.owner === false);
} catch (e) {
  console.error('ERROR', e.message); failures++;
} finally {
  await pool.end();
}

console.log(failures === 0 ? '\nLIBDB SMOKE PASSED' : `\nLIBDB SMOKE FAILED (${failures})`);
process.exit(failures === 0 ? 0 : 1);
