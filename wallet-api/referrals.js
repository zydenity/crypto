// wallet-api/referrals.js
import crypto from 'crypto';

/* ============================ Schema ============================ */
export async function ensureReferralSchema(pool) {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS referral_codes (
      id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
      user_id INT UNSIGNED NOT NULL UNIQUE,
      code VARCHAR(32) NOT NULL UNIQUE,
      clicks INT UNSIGNED NOT NULL DEFAULT 0,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      CONSTRAINT fk_refcodes_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    )
  `);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS referral_relations (
      id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
      referrer_id INT UNSIGNED NOT NULL,
      referee_id  INT UNSIGNED NOT NULL UNIQUE,
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      UNIQUE KEY uniq_ref_pair (referrer_id, referee_id),
      CONSTRAINT fk_rel_referrer FOREIGN KEY (referrer_id) REFERENCES users(id) ON DELETE CASCADE,
      CONSTRAINT fk_rel_referee  FOREIGN KEY (referee_id)  REFERENCES users(id) ON DELETE CASCADE
    )
  `);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS referral_rewards (
      id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
      user_id INT UNSIGNED NOT NULL,          -- earner (upline)
      source_user_id INT UNSIGNED NOT NULL,   -- referee who generated the profit
      amount_usdt DECIMAL(18,6) NOT NULL DEFAULT 0,
      status ENUM('pending','paid') NOT NULL DEFAULT 'pending',
      created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
      INDEX idx_rewards_user (user_id),
      CONSTRAINT fk_rewards_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    )
  `);

  /* ---- SAFE ONLINE MIGRATIONS (tiered, per-day, idempotent) ---- */
  try { await pool.query(`ALTER TABLE referral_rewards ADD COLUMN tier TINYINT UNSIGNED NOT NULL DEFAULT 1 AFTER source_user_id`); } catch {}
  try { await pool.query(`ALTER TABLE referral_rewards ADD COLUMN source_day DATE NULL AFTER tier`); } catch {}
  try { await pool.query(`UPDATE referral_rewards SET source_day = DATE(created_at) WHERE source_day IS NULL`); } catch {}
  try { await pool.query(`ALTER TABLE referral_rewards MODIFY COLUMN source_day DATE NOT NULL`); } catch {}
  try { await pool.query(`ALTER TABLE referral_rewards ADD COLUMN paid_at TIMESTAMP NULL AFTER status`); } catch {}
  try { await pool.query(`CREATE UNIQUE INDEX uniq_comm_day ON referral_rewards (user_id, source_user_id, source_day, tier)`); } catch {} // idempotent key
}

/* ============================ Constants ============================ */
const L1_RATE = Number(process.env.REF_L1_RATE ?? '0.20'); // 20% of daily profit
const L2_RATE = Number(process.env.REF_L2_RATE ?? '0.15'); // 15% of daily profit

/* ============================ Helpers ============================ */
const CODE_RE = /^[A-Z0-9_-]{4,32}$/;

function randCode(n = 8) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  let s = '';
  for (let i = 0; i < n; i++) s += alphabet[Math.floor(Math.random() * alphabet.length)];
  return s;
}

async function generateUniqueCode(pool, uid) {
  for (let i = 0; i < 20; i++) {
    const base = i < 10 ? `U${uid}${randCode(3)}` : randCode(10);
    const code = base.slice(0, 12).toUpperCase();
    const [[row]] = await pool.query(`SELECT id FROM referral_codes WHERE code=? LIMIT 1`, [code]);
    if (!row) return code;
  }
  const tail = crypto.createHash('sha1').update(String(uid) + Date.now()).digest('hex').slice(0,4);
  return `U${uid}${tail}`.toUpperCase();
}

/* Create if missing, return code */
export async function setUserReferralCode(connOrPool, userId, desiredCode) {
  const pool = connOrPool;
  const [[row]] = await pool.query(`SELECT code FROM referral_codes WHERE user_id=?`, [userId]);
  if (row) return row.code;

  let code = desiredCode && CODE_RE.test(desiredCode.toUpperCase())
    ? desiredCode.toUpperCase()
    : await generateUniqueCode(pool, userId);

  try {
    await pool.query(`INSERT INTO referral_codes (user_id, code) VALUES (?,?)`, [userId, code]);
    return code;
  } catch {
    code = await generateUniqueCode(pool, userId);
    await pool.query(`INSERT INTO referral_codes (user_id, code) VALUES (?,?)`, [userId, code]);
    return code;
  }
}

/* Link L1 on signup (once) */
export async function attributeReferralOnSignup(conn, newUserId, referralCode) {
  if (!referralCode) return;
  const code = String(referralCode || '').trim().toUpperCase();
  if (!CODE_RE.test(code)) return;
  const [[owner]] = await conn.query(`SELECT user_id AS uid FROM referral_codes WHERE code=? LIMIT 1`, [code]);
  if (!owner) return;
  const referrerId = Number(owner.uid);
  if (!referrerId || referrerId === Number(newUserId)) return;
  try {
    await conn.query(`INSERT INTO referral_relations (referrer_id, referee_id) VALUES (?,?)`, [referrerId, newUserId]);
  } catch {}
}

/* Sum of PAID referral rewards that count toward spendable */
export async function referralBalanceContribution(pool, userId) {
  const [[row]] = await pool.query(
    `SELECT COALESCE(SUM(amount_usdt),0) AS paid
       FROM referral_rewards
      WHERE user_id=? AND status='paid'`,
    [userId]
  );
  return Number(row.paid || 0);
}

/* ---------- NEW: find L1/L2 uplines for a user ---------- */
export async function findUplines(pool, sourceUserId) {
  const [[l1]] = await pool.query(
    `SELECT referrer_id AS uid FROM referral_relations WHERE referee_id=? LIMIT 1`,
    [sourceUserId]
  );
  let lvl1 = l1?.uid ? Number(l1.uid) : null;

  let lvl2 = null;
  if (lvl1) {
    const [[l2]] = await pool.query(
      `SELECT referrer_id AS uid FROM referral_relations WHERE referee_id=? LIMIT 1`,
      [lvl1]
    );
    lvl2 = l2?.uid ? Number(l2.uid) : null;
  }
  return { lvl1, lvl2 };
}

/* ---------- NEW: idempotent upserts for commissions ---------- */
async function upsertCommission(pool, { earnerId, sourceId, tier, day, amount, mode = 'set' }) {
  if (!earnerId || !sourceId || !day) return;
  const amt = Number(amount || 0);
  if (!(amt > 0)) return;

  const sql = `
    INSERT INTO referral_rewards (user_id, source_user_id, tier, source_day, amount_usdt, status)
    VALUES (?,?,?,?,?,'pending')
    ON DUPLICATE KEY UPDATE
      amount_usdt = ${mode === 'add' ? 'amount_usdt + VALUES(amount_usdt)' : 'VALUES(amount_usdt)'},
      status='pending'
  `;
  await pool.query(sql, [earnerId, sourceId, tier, day, amt]);
}

/* ---------- NEW: public helpers to credit commissions ---------- */
// Add a delta (used by daily catch-up for past days)
export async function creditReferralDelta(pool, sourceUserId, day, deltaProfit) {
  const { lvl1, lvl2 } = await findUplines(pool, sourceUserId);
  if (lvl1) await upsertCommission(pool, { earnerId: lvl1, sourceId: sourceUserId, tier: 1, day, amount: deltaProfit * L1_RATE, mode: 'add' });
  if (lvl2) await upsertCommission(pool, { earnerId: lvl2, sourceId: sourceUserId, tier: 2, day, amount: deltaProfit * L2_RATE, mode: 'add' });
}

// Set the full-day value so far (used by realtime for TODAY)
export async function creditReferralAbsolute(pool, sourceUserId, day, totalProfitForDay) {
  const { lvl1, lvl2 } = await findUplines(pool, sourceUserId);
  if (lvl1) await upsertCommission(pool, { earnerId: lvl1, sourceId: sourceUserId, tier: 1, day, amount: totalProfitForDay * L1_RATE, mode: 'set' });
  if (lvl2) await upsertCommission(pool, { earnerId: lvl2, sourceId: sourceUserId, tier: 2, day, amount: totalProfitForDay * L2_RATE, mode: 'set' });
}

/* ============================ Routes (unchanged below) ============================ */
// ... keep your mountReferralRoutes implementation ...

/* ============================ Routes ============================ */
export function mountReferralRoutes(app, pool, auth) {
// referrals.js
// wallet-api/referrals.js
function detectClientOrigin(req) {
  // 1) explicit env (use in prod)
  if (process.env.APP_CLIENT_URL) return process.env.APP_CLIENT_URL; // e.g. http://app.myhost.com

  // 2) infer from browser headers (works in dev even with random ports)
  const h = req.get('origin') || req.get('referer');
  if (h) {
    try { const u = new URL(h); return `${u.protocol}//${u.host}`; } catch {}
  }

  // 3) last-ditch dev fallback (pick anything)
  return 'http://localhost:60608';
}

// wallet-api/referrals.js (inside mountReferralRoutes)
app.get('/r/:code', async (req, res) => {
  const code = String(req.params.code || '').toUpperCase();
  if (/^[A-Z0-9_-]{4,32}$/.test(code)) {
    await pool.query(`UPDATE referral_codes SET clicks = clicks + 1 WHERE code=?`, [code]);
  }

  // In dev, we can't know Flutter's random port reliably.
  // If you set APP_CLIENT_URL, we'll use it; otherwise we fallback to Referer/Origin; else localhost:60608.
  const detect = () => {
    if (process.env.APP_CLIENT_URL) return process.env.APP_CLIENT_URL;      // e.g. http://localhost:60608
    const h = req.get('origin') || req.get('referer');
    if (h) { try { const u = new URL(h); return `${u.protocol}//${u.host}`; } catch {}
    }
    return 'http://localhost:60608'; // dev fallback
  };

  const client = detect();
  const route  = process.env.REF_ROUTE || '/login';
  // IMPORTANT: query BEFORE the hash so Flutter can read it (and keep hash routing)
  res.redirect(302, `${client}/?ref=${encodeURIComponent(code)}#${route}`);
});


// List *my* referred users
 app.get('/referrals/list', auth, async (req, res) => {
    const uid = req.user.uid;
    const limit = Math.min(parseInt(req.query.limit || '200', 10), 500);

    const [rows] = await pool.query(
      `SELECT
         rr.id           AS referralId,     -- 👈 relation row id
         rr.referee_id   AS userId,         -- (still returned if you need it)
         u.name          AS name,
         u.identifier    AS identifier,
         rr.created_at   AS createdAt,
         rc.code         AS refereeCode     -- the friend’s own referral code (optional)
       FROM referral_relations rr
       JOIN users u             ON u.id = rr.referee_id
       LEFT JOIN referral_codes rc ON rc.user_id = rr.referee_id
       WHERE rr.referrer_id = ?
       ORDER BY rr.id DESC
       LIMIT ?`,
      [uid, limit]
    );
  res.json(rows);
});

// List my referral commissions (works with either table name)
app.get('/referrals/commissions', auth, async (req, res) => {
  const uid = req.user.uid;
  const limit = Math.min(Number(req.query.limit || 200), 500);
  try {
    // preferred table name in this codebase
    const [rows] = await pool.query(
      `SELECT id,
              source_user_id AS userId,
              amount_usdt    AS amountUsdt,
              status,
              created_at     AS createdAt,
              paid_at        AS paidAt
         FROM referral_rewards
        WHERE user_id=?
        ORDER BY id DESC
        LIMIT ?`,
      [uid, limit]
    );
    return res.json(rows);
  } catch (e) {
    // fallback for your older schema `referral_commissions`
    const [rows] = await pool.query(
      `SELECT id,
              referee_user_id AS userId,
              amount_usdt     AS amountUsdt,
              status,
              event,
              created_at      AS createdAt,
              paid_at         AS paidAt
         FROM referral_commissions
        WHERE referrer_user_id=?
        ORDER BY id DESC
        LIMIT ?`,
      [uid, limit]
    );
    return res.json(rows);
  }
});


  // My referral dashboard
  app.get('/referrals/me', auth, async (req, res) => {
    const uid = req.user.uid;

    const [[codeRow]] = await pool.query(
      `SELECT code, clicks FROM referral_codes WHERE user_id=? LIMIT 1`, [uid]
    );
    // Auto-provision if missing
    let code = codeRow?.code;
    if (!code) {
      code = await generateUniqueCode(pool, uid);
      await pool.query(`INSERT INTO referral_codes (user_id, code) VALUES (?,?)`, [uid, code]);
    }
    const clicks = Number(codeRow?.clicks || 0);

    const [[rel]] = await pool.query(
      `SELECT COUNT(*) AS cnt FROM referral_relations WHERE referrer_id=?`,
      [uid]
    );

    const [[rewards]] = await pool.query(
      `SELECT
         COALESCE(SUM(CASE WHEN status='paid' THEN amount_usdt END),0)     AS totalPaid,
         COALESCE(SUM(CASE WHEN status='pending' THEN amount_usdt END),0)  AS totalPending
       FROM referral_rewards
      WHERE user_id=?`,
      [uid]
    );

    const base = `${req.protocol}://${req.get('host')}`;
    res.json({
      code,
      link: `${base}/r/${code}`,
      clicks,
      referredCount: Number(rel.cnt || 0),
      totalPaid: Number(rewards.totalPaid || 0),
      totalPending: Number(rewards.totalPending || 0),
    });
  });

  // Set or create my code
  app.post('/referrals/code', auth, async (req, res) => {
    const uid = req.user.uid;
    const desired = String(req.body?.code || '').trim().toUpperCase();
    if (desired && !CODE_RE.test(desired)) {
      return res.status(400).json({ error: 'BAD_CODE', message: '4–32 chars A–Z 0–9 _ -' });
    }
    // If already has a code and no desired value, just return it.
    const [[exists]] = await pool.query(`SELECT code FROM referral_codes WHERE user_id=?`, [uid]);
    if (exists && !desired) {
      const base = `${req.protocol}://${req.get('host')}`;
      return res.json({ code: exists.code, link: `${base}/r/${exists.code}` });
    }
    try {
      // If desired provided, try to claim it
      if (desired) {
        await pool.query(
          `INSERT INTO referral_codes (user_id, code) VALUES (?,?)
           ON DUPLICATE KEY UPDATE code=VALUES(code)`,
          [uid, desired]
        );
        const base = `${req.protocol}://${req.get('host')}`;
        return res.json({ code: desired, link: `${base}/r/${desired}` });
      }
    } catch (e) {
      if (String(e.code) === 'ER_DUP_ENTRY') {
        return res.status(409).json({ error: 'CODE_TAKEN' });
      }
      throw e;
    }
    // Otherwise create a random one
    const code = await generateUniqueCode(pool, uid);
    await pool.query(`INSERT INTO referral_codes (user_id, code) VALUES (?,?)`, [uid, code]);
    const base = `${req.protocol}://${req.get('host')}`;
    res.json({ code, link: `${base}/r/${code}` });
  });
}
