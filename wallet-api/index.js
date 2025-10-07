// wallet-api/index.js
import express from 'express';
import cors from 'cors';
import dotenv from 'dotenv';
import mysql from 'mysql2/promise';
import { z } from 'zod';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import multer from 'multer';
import bcrypt from 'bcrypt';
import jwt from 'jsonwebtoken';
import crypto from 'crypto';
// wallet-api/index.js
import {
  ensureReferralSchema,
  mountReferralRoutes,
  referralBalanceContribution,
  setUserReferralCode,
  attributeReferralOnSignup,
  // NEW:
  creditReferralDelta,
  creditReferralAbsolute,
} from './referrals.js';


dotenv.config();

// Polyfill fetch for older Node (Node 18+ has global fetch)
if (typeof fetch === 'undefined') {
  const { default: fetchFn } = await import('node-fetch');
  globalThis.fetch = fetchFn;
}

/* -------------------------- express / middleware -------------------------- */
const app = express();
app.use(
  cors({
    origin: true,
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  })
);
app.options('*', cors());
app.use(express.json());

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const uploadsDir = path.join(__dirname, 'uploads');
if (!fs.existsSync(uploadsDir)) fs.mkdirSync(uploadsDir);
app.use('/uploads', express.static(uploadsDir));

/* ---------------------------------- multer --------------------------------- */
const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, uploadsDir),
  filename: (_req, file, cb) => {
    const ext = path.extname(file.originalname || '').toLowerCase();
    cb(null, `${Date.now()}_${Math.round(Math.random() * 1e9)}${ext}`);
  },
});
const upload = multer({
  storage,
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const okMime = /^image\/(png|jpe?g|webp)$/i.test(file.mimetype || '');
    const okExt = /\.(png|jpe?g|webp)$/i.test(file.originalname || '');
    if (okMime || okExt) return cb(null, true);
    return cb(new Error('ONLY_IMAGES'));
  },
});

/* ---------------------------------- mysql ---------------------------------- */
const pool = mysql.createPool({
  uri: process.env.MYSQL_URL, // e.g. mysql://user:pass@localhost:3306/crypto_wallet
  waitForConnections: true,
  connectionLimit: 10,
  decimalNumbers: true, // DECIMAL -> Number
});

/* --------------------------------- helpers --------------------------------- */
async function hasColumn(conn, table, column) {
  const [rows] = await conn.query(
    `SELECT 1
       FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME = ?
        AND COLUMN_NAME = ?`,
    [table, column]
  );
  return rows.length > 0;
}
const APP_TZ = process.env.APP_TZ || '+08:00'; // Asia/Manila

async function todaySQL() {
  // Always compute "today" from UTC, converted to your target TZ, then DATE(...)
  const [[row]] = await pool.query(
    `SELECT DATE(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', ?)) AS today`,
    [APP_TZ]
  );
  return row.today; // 'YYYY-MM-DD'
}

// PH time meta: today and fraction of the day elapsed
async function nowTzMeta() {
  const [[row]] = await pool.query(
    `SELECT
       DATE(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', ?))  AS today,
       TIME_TO_SEC(TIME(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', ?))) AS sec_of_day`,
    [APP_TZ, APP_TZ]
  );
  return {
    today: row.today,
    frac: Math.min(Math.max(Number(row.sec_of_day) / 86400, 0), 1), // 0..1 of the day
  };
}

async function getDefaultAddressForUser(uid) {
  const [rows] = await pool.query(
    `SELECT address FROM wallet_addresses WHERE user_id=? AND is_default=1 LIMIT 1`,
    [uid]
  );
  return rows.length ? rows[0].address : null;
}
function randomHexAddress() {
  // Demo-only random 0x... (NOT a real on-chain keypair)
  return '0x' + crypto.randomBytes(20).toString('hex');
}
function rateForContractDays(days) {
  if (days <= 7) return 0.02;   // 1 week = 2% daily
  if (days <= 15) return 0.03;  // 15 days = 3% daily
  if (days <= 30) return 0.035;  // 30 days = 5% daily
  if (days <= 60) return 0.04;  // 60 days = 5% daily (adjust as desired)
  return 0.03;
}
function addDays(dateIso, n) {
  const dt = new Date(dateIso);
  dt.setUTCDate(dt.getUTCDate() + n);
  return dt.toISOString().slice(0, 10);
}
const todayISO = () => new Date().toISOString().slice(0, 10); // UTC date only

/* --------------------------------- schema ---------------------------------- */
async function ensureSchema() {
  const conn = await pool.getConnection();
  try {
    /* Users */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS users (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(80) NOT NULL,
        identifier VARCHAR(120) NOT NULL UNIQUE,
        password_hash VARCHAR(255) NOT NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    `);

    /* Address pool (reusable addresses) */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS address_pool (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        address CHAR(42) CHARACTER SET ascii COLLATE ascii_bin NOT NULL UNIQUE,
        network VARCHAR(32) NOT NULL DEFAULT 'ethereum',
        token_symbol VARCHAR(16) NOT NULL DEFAULT 'USDT',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
      )
    `);

    /* Banks master */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS banks (
        code    VARCHAR(32) PRIMARY KEY,
        name    VARCHAR(160) NOT NULL,
        channel ENUM('instapay','pesonet','both') NOT NULL DEFAULT 'both',
        active  TINYINT(1) NOT NULL DEFAULT 1
      )
    `);

    /* Bank transfers (off-ramps) */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS bank_transfers (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id INT UNSIGNED NOT NULL,
        from_address CHAR(42) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        bank_code VARCHAR(32) NOT NULL,
        account_number VARCHAR(64) NOT NULL,
        account_name   VARCHAR(120) NOT NULL,
        amount_usdt DECIMAL(36,18) NOT NULL,
        rate_usdt_php DECIMAL(18,6) NOT NULL,
        fx_fee_pct DECIMAL(6,4) NOT NULL DEFAULT 0.0100,
        payout_fee_php DECIMAL(18,2) NOT NULL DEFAULT 25.00,
        php_gross DECIMAL(18,2) NOT NULL,
        php_net   DECIMAL(18,2) NOT NULL,
        token_symbol VARCHAR(16) NOT NULL DEFAULT 'USDT',
        network VARCHAR(32) NOT NULL DEFAULT 'bank',
        reference VARCHAR(64) NULL,
        status ENUM('processing','sent','received','failed','canceled') NOT NULL DEFAULT 'processing',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_bt_user (user_id),
        INDEX idx_bt_from (from_address),
        CONSTRAINT fk_bt_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    `);

    /* Wallet addresses per user */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS wallet_addresses (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id INT UNSIGNED NOT NULL,
        label VARCHAR(64),
        address CHAR(42) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        network VARCHAR(32) NOT NULL DEFAULT 'ethereum',
        token_symbol VARCHAR(16) NOT NULL DEFAULT 'USDT',
        is_default TINYINT(1) NOT NULL DEFAULT 0,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_wallet_user (user_id),
        CONSTRAINT fk_wallet_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    `);
    try { await conn.query(`ALTER TABLE wallet_addresses DROP INDEX uniq_address`); } catch {}
    try { await conn.query(`CREATE UNIQUE INDEX uniq_user_addr ON wallet_addresses(user_id,address)`); } catch {}

    /* Deposits */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS deposits (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id INT UNSIGNED NULL,
        address CHAR(42) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        amount DECIMAL(36,18) NOT NULL,
        token_symbol VARCHAR(16) NOT NULL DEFAULT 'USDT',
        network VARCHAR(32) NOT NULL DEFAULT 'ethereum',
        source VARCHAR(32) NULL,
        tx_hash VARCHAR(100) NULL,
        image_path VARCHAR(255) NOT NULL,
        status ENUM('pending','verified','rejected') NOT NULL DEFAULT 'pending',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_dep_user (user_id),
        INDEX idx_dep_addr (address),
        CONSTRAINT fk_dep_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
      )
    `);

    /* Crypto transfers */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS transfers (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id INT UNSIGNED NOT NULL,
        from_address CHAR(42) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        to_address   VARCHAR(128) NOT NULL,
        amount DECIMAL(36,18) NOT NULL,
        token_symbol VARCHAR(16) NOT NULL DEFAULT 'USDT',
        network      VARCHAR(32) NOT NULL,
        status ENUM('pending','broadcast','confirmed','failed','rejected')
               NOT NULL DEFAULT 'pending',
        tx_hash VARCHAR(100) NULL,
        note    VARCHAR(255) NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        INDEX idx_user (user_id),
        INDEX idx_from (from_address),
        CONSTRAINT fk_tr_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    `);

    /* AI subscriptions (new schema with contracts & rate) */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS ai_subscriptions (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id INT UNSIGNED NOT NULL,
        from_address CHAR(42) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        symbol VARCHAR(16) NOT NULL,
        amount_usdt DECIMAL(36,18) NOT NULL,
        token_symbol VARCHAR(16) NOT NULL DEFAULT 'USDT',
        contract_days INT NULL,
        rate_daily DECIMAL(10,6) NULL,
        start_date DATE NULL,
        end_date   DATE NULL,
        last_credit_date DATE NULL,
        status ENUM('active','paused','canceled','completed') NOT NULL DEFAULT 'active',
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE KEY uniq_user_addr_sym (user_id, from_address, symbol),
        INDEX idx_ai_user (user_id),
        CONSTRAINT fk_ai_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    `);

    // Live migration: add/backfill columns safely (avoid 0000-00-00)
    if (!(await hasColumn(conn, 'ai_subscriptions', 'contract_days'))) {
      await conn.query(`ALTER TABLE ai_subscriptions ADD COLUMN contract_days INT NULL`);
    }
    await conn.query(`
      UPDATE ai_subscriptions
         SET contract_days = COALESCE(NULLIF(contract_days,0), 15)
       WHERE contract_days IS NULL OR contract_days = 0
    `);
    try { await conn.query(`ALTER TABLE ai_subscriptions MODIFY COLUMN contract_days INT NOT NULL`); } catch {}

    if (!(await hasColumn(conn, 'ai_subscriptions', 'rate_daily'))) {
      await conn.query(`ALTER TABLE ai_subscriptions ADD COLUMN rate_daily DECIMAL(10,6) NULL`);
    }
    await conn.query(`
      UPDATE ai_subscriptions
         SET rate_daily =
             COALESCE(NULLIF(rate_daily,0.0),
                      CASE
                        WHEN contract_days <= 7  THEN 0.02
                        WHEN contract_days <= 15 THEN 0.03
                        WHEN contract_days <= 30 THEN 0.05
                        WHEN contract_days <= 60 THEN 0.05
                        ELSE 0.03
                      END)
       WHERE rate_daily IS NULL OR rate_daily = 0.0
    `);
    try { await conn.query(`ALTER TABLE ai_subscriptions MODIFY COLUMN rate_daily DECIMAL(10,6) NOT NULL`); } catch {}

    if (!(await hasColumn(conn, 'ai_subscriptions', 'start_date'))) {
      await conn.query(`ALTER TABLE ai_subscriptions ADD COLUMN start_date DATE NULL`);
    }
    await conn.query(`
      UPDATE ai_subscriptions
         SET start_date = CURDATE()
       WHERE start_date IS NULL OR start_date = '0000-00-00'
    `);
    try { await conn.query(`ALTER TABLE ai_subscriptions MODIFY COLUMN start_date DATE NOT NULL`); } catch {}

    if (!(await hasColumn(conn, 'ai_subscriptions', 'end_date'))) {
      await conn.query(`ALTER TABLE ai_subscriptions ADD COLUMN end_date DATE NULL`);
    }
    await conn.query(`
      UPDATE ai_subscriptions
         SET end_date = DATE_ADD(
                          COALESCE(start_date, CURDATE()),
                          INTERVAL GREATEST(COALESCE(contract_days,15),1) - 1 DAY
                        )
       WHERE end_date IS NULL OR end_date = '0000-00-00'
    `);
    try { await conn.query(`ALTER TABLE ai_subscriptions MODIFY COLUMN end_date DATE NOT NULL`); } catch {}

    try {
      await conn.query(
        `ALTER TABLE ai_subscriptions
           MODIFY COLUMN status ENUM('active','paused','canceled','completed')
           NOT NULL DEFAULT 'active'`
      );
    } catch {}

    /* AI Profit ledger (daily credits become spendable) */
    await conn.query(`
      CREATE TABLE IF NOT EXISTS ai_profit_ledger (
        id INT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
        user_id INT UNSIGNED NOT NULL,
        from_address CHAR(42) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        symbol VARCHAR(16) NOT NULL,
        amount_usdt DECIMAL(36,18) NOT NULL,
        day_date DATE NOT NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        UNIQUE KEY uniq_ai_pl (user_id, from_address, symbol, day_date),
        INDEX idx_ai_pl_user_date (user_id, day_date),
        CONSTRAINT fk_ai_pl_user FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
      )
    `);
  } finally {
    conn.release();
  }

  // Seed PH banks once
  const [bkCount] = await pool.query(`SELECT COUNT(*) AS c FROM banks`);
  if (bkCount[0].c === 0) {
    const PH_BANKS = [
      ['BDO', 'BDO Unibank', 'both'],
      ['BPI', 'Bank of the Philippine Islands', 'both'],
      ['MBTC', 'Metrobank', 'both'],
      ['LBP', 'Land Bank of the Philippines', 'both'],
      ['PNB', 'Philippine National Bank', 'both'],
      ['SECB', 'Security Bank', 'both'],
      ['CHIB', 'China Banking Corporation', 'both'],
      ['UBP', 'UnionBank of the Philippines', 'both'],
      ['RCBC', 'Rizal Commercial Banking Corp.', 'both'],
      ['EWB', 'EastWest Bank', 'both'],
      ['AUB', 'Asia United Bank', 'both'],
      ['PSB', 'PSBank', 'both'],
      ['PBCOM', 'Philippine Bank of Communications', 'both'],
      ['BNCOM', 'Bank of Commerce', 'both'],
      ['MAYA', 'Maya Bank, Inc.', 'instapay'],
      ['CIMB', 'CIMB Bank Philippines', 'instapay'],
      ['TONIK', 'Tonik Digital Bank', 'instapay'],
      ['UNO', 'UNO Digital Bank', 'instapay'],
      ['OFB', 'Overseas Filipino Bank', 'pesonet'],
      ['SEABANK', 'SeaBank Philippines', 'instapay'],
      ['GOTYME', 'GoTyme Bank', 'instapay'],
    ];
    await pool.query(
      `INSERT INTO banks (code,name,channel,active) VALUES ` + PH_BANKS.map(() => '(?,?,?,1)').join(','),
      PH_BANKS.flat()
    );
  }
}

/* ---------------------------------- auth ----------------------------------- */
const JWT_SECRET = process.env.JWT_SECRET || 'dev_secret_change_me';
const TOKEN_EXPIRES = '30d';
const signToken = (payload) => jwt.sign(payload, JWT_SECRET, { expiresIn: TOKEN_EXPIRES });

function auth(req, res, next) {
  const h = req.headers.authorization || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : null;
  if (!token) return res.status(401).json({ error: 'NO_TOKEN' });
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    return res.status(401).json({ error: 'BAD_TOKEN' });
  }
}
// ...auth() definition above...

// Referral endpoints (mounted once)
mountReferralRoutes(app, pool, auth);

/* -------------------------------- constants -------------------------------- */
const FX_FEE_PCT = Number(process.env.FX_FEE_PCT ?? '0.01'); // 1%
const PAYOUT_FEE_PHP = Number(process.env.PAYOUT_FEE_PHP ?? '25'); // ₱25
const FALLBACK_USDT_PHP = Number(process.env.FALLBACK_USDT_PHP ?? '58'); // stub

/* --------------------------------- routes ---------------------------------- */
app.get('/health', (_req, res) => res.json({ ok: true }));
/* ====== AI Profit Summary Route ====== */
/* Paste near your other routes, after app.use(express.json()) */

function aiTodayISO() {
  // UTC date-only string (avoid reusing any existing todayISO() name)
  return new Date().toISOString().slice(0, 10);
}

async function getOne(conn, sql, params) {
  const [rows] = await conn.execute(sql, params);
  return rows && rows[0] ? rows[0] : {};
}

/* ====== AI Profit Summary Route (FIXED for your schema) ====== */
// REPLACE the existing aiTodayISO/getOne/handler + mounts with this:

/* ====== AI Profit Summary Route (final) ====== */
// Computes lifetime credited, today's credited, and today's expected, per user + address.
// Uses your schema: ai_profit_ledger(amount_usdt, from_address, day_date, user_id)

async function aiProfitSummary(req, res) {
  try {
    const uid = req.user.uid;
    let address = (req.query.address || '').toString().toLowerCase();
    if (!address) {
      address = await getDefaultAddressForUser(uid);
      if (!address) return res.status(404).json({ error: 'NO_DEFAULT' });
    }

    // Ensure ledger is up to date (same approach as /balance)
    await processAiProfitDaily();     // catch up to yesterday
    await processAiProfitRealtime();  // post today's pro-rata to now

    const { today } = await nowTzMeta();

    // Lifetime credited
    const [[tot]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS totalCredited
         FROM ai_profit_ledger
        WHERE user_id=? AND from_address=?`,
      [uid, address]
    );

    // Today's credited (same day_date model)
    const [[tdy]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS todayCredited
         FROM ai_profit_ledger
        WHERE user_id=? AND from_address=? AND day_date=?`,
      [uid, address, today]
    );

    // Today's expected (active subs whose window includes today)
    const [[exp]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt * rate_daily),0) AS todayExpected
         FROM ai_subscriptions
        WHERE user_id=? AND from_address=? AND status='active'
          AND start_date <= ? AND end_date >= ?`,
      [uid, address, today, today]
    );

    res.json({
      address,
      totalCredited: Number(tot.totalCredited),
      todayCredited: Number(tdy.todayCredited),
      todayExpected: Number(exp.todayExpected),
    });
  } catch (err) {
    console.error('AI_PROFIT_SUMMARY_ERROR:', err);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
}

// Auth-protected mounts (keep only these)
app.get('/ai/profit/summary', auth, aiProfitSummary);
app.get('/ai-profit/summary', auth, aiProfitSummary);
mountReferralRoutes(app, pool, auth);



// Mount both paths (compat)



/* --------------------------------- Balance --------------------------------- */
app.get('/balance', auth, async (req, res) => {
  try {
    // Ensure ledger is fresh before computing balance
    await processAiProfitDaily();     // catch up to yesterday
    await processAiProfitRealtime();  // post today's pro-rata to now

    const uid = req.user.uid;
    const tokenSymbol = String(req.query.tokenSymbol || 'USDT').toUpperCase();
    let address = (req.query.address ? String(req.query.address) : '').toLowerCase();

    if (!address) {
      address = await getDefaultAddressForUser(uid);
      if (!address) return res.status(404).json({ error: 'NO_DEFAULT' });
    }

    const [[dep]] = await pool.query(
      `SELECT
         COALESCE(SUM(CASE WHEN status='verified' THEN amount END), 0) AS dep_verified,
         COALESCE(SUM(CASE WHEN status='pending'  THEN amount END), 0) AS dep_pending
       FROM deposits
       WHERE user_id=? AND address=? AND token_symbol=?`,
      [uid, address, tokenSymbol]
    );

    const [[wd]] = await pool.query(
      `SELECT
         COALESCE(SUM(CASE WHEN status IN ('pending','broadcast','confirmed') THEN amount END), 0) AS wd_active
       FROM transfers
       WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [uid, address, tokenSymbol]
    );

    const [[bt]] = await pool.query(
      `SELECT
         COALESCE(SUM(CASE WHEN status IN ('processing','sent','received') THEN amount_usdt END), 0) AS bt_active
       FROM bank_transfers
       WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [uid, address, tokenSymbol]
    );

    // Active AI allocations (principal locked)
    const [[ai]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS ai_active
         FROM ai_subscriptions
        WHERE user_id=? AND from_address=? AND token_symbol=? AND status='active'`,
      [uid, address, tokenSymbol]
    );

    // Credited AI profits (spendable) — includes today's realtime posting
    const [[pl]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS ai_profit
         FROM ai_profit_ledger
        WHERE user_id=? AND from_address=?`,
      [uid, address]
    );
// NEW: referral paid commissions count toward spendable
const refPaid = await referralBalanceContribution(pool, uid);

const spendable =
  Number(dep.dep_verified) -
  Number(wd.wd_active) -
  Number(bt.bt_active) -
  Number(ai.ai_active) +
  Number(pl.ai_profit) +
  Number(refPaid);


    const debugOn = ['1','true','yes','on'].includes(String(req.query.debug || '').toLowerCase());
    res.json({
      address,
      tokenSymbol,
      verified: Math.max(spendable, 0),
      pending: Number(dep.dep_pending),
      withdrawing: Number(wd.wd_active) + Number(bt.bt_active),
      aiActive: Number(ai.ai_active),
      aiProfitCredited: Number(pl.ai_profit),
      referralPaid: Number(refPaid),

      ...(debugOn ? {
        debug: {
          dep_verified: Number(dep.dep_verified),
          wd_active: Number(wd.wd_active),
          bt_active: Number(bt.bt_active),
          ai_active: Number(ai.ai_active),
          ai_profit: Number(pl.ai_profit),
        }
      } : {})
    });
  } catch (e) {
    console.error('BALANCE_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR', message: e.message });
  }
});

/* ------------------------------ AUTH: register ----------------------------- */
app.post('/auth/register', async (req, res) => {
  console.log('REGISTER body:', req.body); // should show referralCode
  const parsed = z.object({
    name: z.string().min(1),
    identifier: z.string().min(3),
    password: z.string().min(6),
    referralCode: z.string().optional(), // NEW
  }).safeParse(req.body);

  if (!parsed.success) {
    return res.status(400).json({ error: 'BAD_REQUEST', details: parsed.error.flatten() });
  }

  const { name, identifier, password, referralCode } = parsed.data;
  const hash = await bcrypt.hash(password, 10);

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();

    const [r] = await conn.query(
      'INSERT INTO users (name,identifier,password_hash) VALUES (?,?,?)',
      [name, identifier, hash]
    );
    const userId = r.insertId;

    // **Generate unique referral code for this new user**
    const myRefCode = await setUserReferralCode(conn, userId);

    // **Attribute referral if a code was provided**
    await attributeReferralOnSignup(conn, userId, referralCode);

    // Wallet assignment (unchanged)
    const [poolRows] = await conn.query(
      `SELECT address, network, token_symbol
         FROM address_pool
        ORDER BY RAND()
        LIMIT 1`
    );

    let assignedAddress;
    let network = 'ethereum';
    let tokenSymbol = 'USDT';

    if (poolRows.length) {
      assignedAddress = (poolRows[0].address || '').toLowerCase();
      network = poolRows[0].network || 'ethereum';
      tokenSymbol = poolRows[0].token_symbol || 'USDT';
    } else {
      assignedAddress = randomHexAddress().toLowerCase();
    }

    await conn.query(
      `INSERT INTO wallet_addresses (user_id, label, address, network, token_symbol, is_default)
       VALUES (?,?,?,?,?,1)
       ON DUPLICATE KEY UPDATE is_default=VALUES(is_default), label=VALUES(label)`,
      [userId, 'My Wallet', assignedAddress, network, tokenSymbol]
    );
    await conn.query(
      'UPDATE wallet_addresses SET is_default=0 WHERE user_id=? AND address<>?',
      [userId, assignedAddress]
    );

    await conn.commit();

    const token = signToken({ uid: userId, idf: identifier, name });
    const base = `${req.protocol}://${req.get('host')}`;
    res.status(201).json({
      ok: true,
      userId,
      token,
      user: { id: userId, name, identifier, referralCode: myRefCode, referralLink: `${base}/r/${myRefCode}` },
      wallet: { address: assignedAddress, network, tokenSymbol },
    });
  } catch (e) {
    await conn.rollback();
    if (String(e.message).includes('Duplicate') || e.code === 'ER_DUP_ENTRY') {
      return res.status(409).json({ error: 'IDENTIFIER_TAKEN' });
    }
    console.error('REGISTER_ERROR:', e);
    return res.status(500).json({ error: 'DB_ERROR' });
  } finally {
    conn.release();
  }
});


/* -------------------------------- AUTH: login ------------------------------ */
app.post('/auth/login', async (req, res) => {
  const parsed = z.object({
    identifier: z.string().min(3),
    password: z.string().min(1),
  }).safeParse(req.body);
  if (!parsed.success)
    return res.status(400).json({ error: 'BAD_REQUEST', details: parsed.error.flatten() });

  const { identifier, password } = parsed.data;
  const [rows] = await pool.query(
    'SELECT id,name,identifier,password_hash FROM users WHERE identifier=? LIMIT 1',
    [identifier]
  );
  if (!rows.length) return res.status(401).json({ error: 'INVALID_CREDENTIALS' });

  const u = rows[0];
  const ok = await bcrypt.compare(password, u.password_hash);
  if (!ok) return res.status(401).json({ error: 'INVALID_CREDENTIALS' });

  const token = signToken({ uid: u.id, idf: u.identifier, name: u.name });
  res.json({ ok: true, token, user: { id: u.id, name: u.name, identifier: u.identifier } });
});

/* ------------------------------- Wallet APIs ------------------------------- */
const walletBody = z.object({
  address: z.string().regex(/^0x[a-fA-F0-9]{40}$/),
  label: z.string().optional(),
  network: z.string().optional(),
  tokenSymbol: z.string().optional(),
});

app.get('/wallet/default', auth, async (req, res) => {
  const uid = req.user.uid;
  const [rows] = await pool.query(
    `SELECT id,label,address,network,token_symbol AS tokenSymbol,is_default
       FROM wallet_addresses
      WHERE user_id=? AND is_default=1
      LIMIT 1`,
    [uid]
  );
  if (!rows.length) return res.status(404).json({ error: 'NO_DEFAULT' });
  res.json(rows[0]);
});

app.put('/wallet/default', auth, async (req, res) => {
  const parsed = walletBody.safeParse(req.body);
  if (!parsed.success) {
    return res.status(400).json({ error: 'BAD_REQUEST', details: parsed.error.flatten() });
  }

  const uid = req.user.uid;
  const { address, label = 'My Wallet', network = 'ethereum', tokenSymbol = 'USDT' } = parsed.data;

  const conn = await pool.getConnection();
  try {
    await conn.beginTransaction();
    await conn.query('UPDATE wallet_addresses SET is_default=0 WHERE user_id=?', [uid]);
    await conn.query(
      `INSERT INTO wallet_addresses (user_id,label,address,network,token_symbol,is_default)
       VALUES (?,?,?,?,?,1)
       ON DUPLICATE KEY UPDATE label=VALUES(label), network=VALUES(network),
                                token_symbol=VALUES(token_symbol), is_default=1`,
      [uid, label, address.toLowerCase(), network, tokenSymbol]
    );
    await conn.commit();
    res.json({ ok: true, address: address.toLowerCase() });
  } catch (e) {
    await conn.rollback();
    console.error(e);
    res.status(500).json({ error: 'DB_ERROR' });
  } finally {
    conn.release();
  }
});

app.get('/wallets', auth, async (req, res) => {
  const uid = req.user.uid;
  const [rows] = await pool.query(
    `SELECT id,label,address,network,token_symbol AS tokenSymbol,is_default
       FROM wallet_addresses
      WHERE user_id=?
      ORDER BY is_default DESC,id DESC`,
    [uid]
  );
  res.json(rows);
});

/* ------------------------------- Banks & Rates ----------------------------- */
app.get('/banks', auth, async (_req, res) => {
  const [rows] = await pool.query(`SELECT code,name,channel FROM banks WHERE active=1 ORDER BY name ASC`);
  res.json(rows);
});

app.get('/rates/usdt-php', auth, async (_req, res) => {
  res.json({ base: 'USDT', quote: 'PHP', rate: FALLBACK_USDT_PHP });
});

/* ------------------------------ Deposits APIs ------------------------------ */
app.post('/deposits', auth, upload.single('proof'), async (req, res) => {
  try {
    const { address, amount, tokenSymbol = 'USDT', network = 'ethereum', source, txHash } = req.body;
    if (!req.file) return res.status(400).json({ error: 'NO_FILE' });
    if (!/^0x[a-fA-F0-9]{40}$/.test(address || '')) return res.status(400).json({ error: 'BAD_ADDRESS' });
    const amt = Number(amount);
    if (!Number.isFinite(amt) || amt <= 0) return res.status(400).json({ error: 'BAD_AMOUNT' });

    const imagePath = `/uploads/${req.file.filename}`;
    await pool.query(
      `INSERT INTO deposits (user_id,address,amount,token_symbol,network,source,tx_hash,image_path,status)
       VALUES (?,?,?,?,?,?,?,?,'pending')`,
      [req.user.uid, address.toLowerCase(), amt, tokenSymbol, network, source ?? null, txHash ?? null, imagePath]
    );

    const base = `${req.protocol}://${req.get('host')}`;
    res.status(201).json({
      ok: true,
      deposit: {
        address: address.toLowerCase(),
        amount: amt,
        tokenSymbol,
        network,
        source,
        txHash,
        status: 'pending',
        imageUrl: `${base}${imagePath}`,
      },
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: 'UPLOAD_FAILED' });
  }
});

app.get('/deposits', auth, async (req, res) => {
  const uid = req.user.uid;
  const params = [uid];
  let where = 'user_id=?';
  if (req.query.address) {
    where += ' AND address=?';
    params.push(req.query.address.toString().toLowerCase());
  }
  const [rows] = await pool.query(
    `SELECT id,address,amount,token_symbol AS tokenSymbol,network,source,
            tx_hash AS txHash,image_path AS imagePath,status,created_at AS createdAt
       FROM deposits
      WHERE ${where}
      ORDER BY id DESC`,
    params
  );
  const base = `${req.protocol}://${req.get('host')}`;
  res.json(rows.map((r) => ({ ...r, imageUrl: `${base}${r.imagePath}` })));
});

/* ------------------------------- Transfers APIs ---------------------------- */
app.post('/transfers', auth, async (req, res) => {
  try {
    const { fromAddress, toAddress, amount, tokenSymbol = 'USDT', network = 'ethereum', note } = req.body || {};
    if (!fromAddress || !/^0x[a-fA-F0-9]{40}$/.test(fromAddress)) {
      return res.status(400).json({ error: 'BAD_FROM' });
    }
    if (!toAddress || typeof toAddress !== 'string' || toAddress.length < 8) {
      return res.status(400).json({ error: 'BAD_TO' });
    }
    const amt = Number(amount);
    if (!Number.isFinite(amt) || amt <= 0) return res.status(400).json({ error: 'BAD_AMOUNT' });

    // spendable = verified deposits – active crypto withdrawals – active bank transfers – active AI locks
    const [[dep]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status='verified' THEN amount END), 0) AS dep_verified
         FROM deposits WHERE user_id=? AND address=? AND token_symbol=?`,
      [req.user.uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[wd]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status IN ('pending','broadcast','confirmed') THEN amount END), 0) AS wd_active
         FROM transfers WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [req.user.uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[bt]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status IN ('processing','sent','received') THEN amount_usdt END),0) AS bt_active
         FROM bank_transfers WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [req.user.uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[ai]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS ai_active
         FROM ai_subscriptions WHERE user_id=? AND from_address=? AND token_symbol=? AND status='active'`,
      [req.user.uid, fromAddress.toLowerCase(), tokenSymbol]
    );

    const spendable = Number(dep.dep_verified) - Number(wd.wd_active) - Number(bt.bt_active) - Number(ai.ai_active);
    if (amt > spendable) return res.status(400).json({ error: 'INSUFFICIENT_FUNDS', spendable });

    const [r] = await pool.query(
      `INSERT INTO transfers
         (user_id, from_address, to_address, amount, token_symbol, network, status, note)
       VALUES (?,?,?,?,?,?, 'pending', ?)`,
      [req.user.uid, fromAddress.toLowerCase(), toAddress, amt, tokenSymbol, network, note ?? null]
    );

    res.status(201).json({
      ok: true,
      transfer: {
        id: r.insertId,
        fromAddress: fromAddress.toLowerCase(),
        toAddress,
        amount: amt,
        tokenSymbol,
        network,
        status: 'pending',
      },
    });
  } catch (e) {
    console.error('TRANSFER_CREATE_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
});

app.get('/transfers', auth, async (req, res) => {
  const uid = req.user.uid;
  const [rows] = await pool.query(
    `SELECT id, from_address AS fromAddress, to_address AS toAddress, amount, token_symbol AS tokenSymbol,
            network, status, tx_hash AS txHash, note, created_at AS createdAt
       FROM transfers
      WHERE user_id=?
      ORDER BY id DESC`,
    [uid]
  );
  res.json(rows);
});

// Admin-ish: update crypto transfer status (simulate on-chain)
app.patch('/transfers/:id/status', async (req, res) => {
  const id = Number(req.params.id);
  const { status, txHash } = req.body || {};
  if (!['pending', 'broadcast', 'confirmed', 'failed', 'rejected'].includes(status)) {
    return res.status(400).json({ error: 'BAD_STATUS' });
  }
  await pool.query('UPDATE transfers SET status=?, tx_hash=? WHERE id=?', [status, txHash ?? null, id]);
  res.json({ ok: true });
});
// index.js
app.post('/admin/referrals/rerate-day', async (req, res) => {
  try {
    const day = String(req.body?.day || '').slice(0, 10);
    if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) return res.status(400).json({ error: 'BAD_DAY' });

    // All users who had profit that day
    const [uids] = await pool.query(
      `SELECT user_id AS uid
         FROM ai_profit_ledger
        WHERE day_date=?
        GROUP BY user_id`,
      [day]
    );

    for (const { uid } of uids) {
      const [[agg]] = await pool.query(
        `SELECT COALESCE(SUM(amount_usdt),0) AS profit
           FROM ai_profit_ledger
          WHERE user_id=? AND day_date=?`,
        [uid, day]
      );
      const total = Number(agg.profit || 0);

      // Re-set the day to new rates (won't touch 'paid' vs 'pending' status)
      await creditReferralAbsolute(pool, uid, day, total);
    }

    res.json({ ok: true, day, reRatedUsers: uids.length });
  } catch (e) {
    console.error('RERATE_DAY_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
});

/* ------------------------------ Bank transfers ----------------------------- */
app.post('/bank-transfers', auth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const { fromAddress, bankCode, accountNumber, accountName, amountUsdt, rate, note } = req.body || {};

    if (!fromAddress || !/^0x[a-fA-F0-9]{40}$/.test(fromAddress)) {
      return res.status(400).json({ error: 'BAD_FROM' });
    }
    if (!bankCode || !accountNumber || !accountName) {
      return res.status(400).json({ error: 'BAD_BANK_DETAILS' });
    }
    const amt = Number(amountUsdt);
    if (!Number.isFinite(amt) || amt <= 0) {
      return res.status(400).json({ error: 'BAD_AMOUNT' });
    }

    // validate bank exists
    const [[bank]] = await pool.query(`SELECT code FROM banks WHERE code=? AND active=1`, [bankCode]);
    if (!bank) return res.status(400).json({ error: 'BANK_NOT_SUPPORTED' });

    const tokenSymbol = 'USDT';
    // compute spendable (verified – active crypto withdrawals – active bank transfers – active AI locks)
    const [[dep]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status='verified' THEN amount END),0) AS dep_verified
         FROM deposits WHERE user_id=? AND address=? AND token_symbol=?`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[wd]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status IN ('pending','broadcast','confirmed') THEN amount END),0) AS wd_active
         FROM transfers WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[bt]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status IN ('processing','sent','received') THEN amount_usdt END),0) AS bt_active
         FROM bank_transfers WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[ai]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS ai_active
         FROM ai_subscriptions WHERE user_id=? AND from_address=? AND token_symbol=? AND status='active'`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );

    const spendable = Number(dep.dep_verified) - Number(wd.wd_active) - Number(bt.bt_active) - Number(ai.ai_active);
    if (amt > spendable) {
      return res.status(400).json({ error: 'INSUFFICIENT_FUNDS', spendable });
    }

    const fxRate = Number(rate) > 0 ? Number(rate) : FALLBACK_USDT_PHP;
    const phpGross = amt * fxRate;
    const fxFee = phpGross * FX_FEE_PCT;
    const phpNet = phpGross - fxFee - PAYOUT_FEE_PHP;
    if (phpNet <= 0) return res.status(400).json({ error: 'NET_LE_0' });

    const [r] = await pool.query(
      `INSERT INTO bank_transfers
         (user_id,from_address,bank_code,account_number,account_name,
          amount_usdt,rate_usdt_php,fx_fee_pct,payout_fee_php,php_gross,php_net,
          token_symbol,network,reference,status)
       VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'processing')`,
      [
        uid,
        fromAddress.toLowerCase(),
        bankCode,
        accountNumber,
        accountName,
        amt,
        fxRate,
        FX_FEE_PCT,
        PAYOUT_FEE_PHP,
        phpGross,
        phpNet,
        tokenSymbol,
        'bank',
        note ?? null,
      ]
    );

    res.status(201).json({
      ok: true,
      transfer: {
        id: r.insertId,
        fromAddress: fromAddress.toLowerCase(),
        bankCode,
        accountNumber,
        accountName,
        amountUsdt: amt,
        rateUsdtPhp: fxRate,
        fxFeePct: FX_FEE_PCT,
        payoutFeePhp: PAYOUT_FEE_PHP,
        phpGross,
        phpNet,
        status: 'processing',
      },
    });
  } catch (e) {
    console.error('BANK_TRANSFER_CREATE_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
});

app.get('/bank-transfers', auth, async (req, res) => {
  const uid = req.user.uid;
  const [rows] = await pool.query(
    `SELECT id,
            from_address AS fromAddress,
            bank_code AS bankCode,
            account_number AS accountNumber,
            account_name   AS accountName,
            amount_usdt    AS amountUsdt,
            rate_usdt_php  AS rateUsdtPhp,
            fx_fee_pct     AS fxFeePct,
            payout_fee_php AS payoutFeePhp,
            php_gross      AS phpGross,
            php_net        AS phpNet,
            token_symbol   AS tokenSymbol,
            network, status, reference,
            created_at     AS createdAt
       FROM bank_transfers
      WHERE user_id=?
      ORDER BY id DESC`,
    [uid]
  );
  res.json(rows);
});

app.get('/me', auth, (req, res) => res.json(req.user));

app.patch('/bank-transfers/:id/status', async (req, res) => {
  const id = Number(req.params.id);
  const { status, reference } = req.body || {};
  if (!['processing', 'sent', 'received', 'failed', 'canceled'].includes(status)) {
    return res.status(400).json({ error: 'BAD_STATUS' });
  }
  await pool.query('UPDATE bank_transfers SET status=?, reference=? WHERE id=?', [
    status,
    reference ?? null,
    id,
  ]);
  res.json({ ok: true });
});

/* ----------------- Near-real-time market (SSE + REST + cache) --------------- */
const MARKET_IDS = [
  'bitcoin',
  'ethereum',
  'tether',
  'usd-coin',
  'pudgy-penguins',
  '1000-sats',
  'aave',
  'cardano',
  'aevo',
  'ai16z',
];

let _marketCache = { at: 0, data: [] };
let _polling = false;
const POLL_MS = 15_000;
const _sseClients = new Set();

async function fetchMarketSnapshot() {
  const ids = MARKET_IDS.join(',');
  const url =
    `https://api.coingecko.com/api/v3/coins/markets` +
    `?vs_currency=php&ids=${encodeURIComponent(ids)}` +
    `&price_change_percentage=24h`;

  const headers = process.env.COINGECKO_API_KEY
    ? { 'x-cg-demo-api-key': process.env.COINGECKO_API_KEY }
    : {};
  const cg = await fetch(url, { headers });
  if (!cg.ok) throw new Error(`CoinGecko ${cg.status}`);
  const rows = await cg.json();

  return rows.map((r) => ({
    id: r.symbol?.toUpperCase() ?? r.id?.toUpperCase(),
    symbol: r.symbol?.toUpperCase(),
    name: r.name,
    price: r.current_price, // PHP
    change24h: r.price_change_percentage_24h_in_currency,
    logo: r.image,
  }));
}

async function refreshCacheAndMaybeBroadcast() {
  if (_polling) return;
  _polling = true;
  try {
    const data = await fetchMarketSnapshot();

    const prev = _marketCache.data;
    let changed = prev.length !== data.length;
    if (!changed) {
      for (let i = 0; i < data.length; i++) {
        if (data[i].id !== prev[i].id || data[i].price !== prev[i].price) {
          changed = true;
          break;
        }
      }
    }

    _marketCache = { at: Date.now(), data };
    if (changed && _sseClients.size) {
      const payload = `event: update\ndata:${JSON.stringify(data)}\n\n`;
      for (const res of _sseClients) res.write(payload);
    }
  } catch (e) {
    console.error('MARKET_POLL_ERROR:', e.message);
  } finally {
    _polling = false;
  }
}

// background polling + prime cache
setInterval(refreshCacheAndMaybeBroadcast, POLL_MS);
refreshCacheAndMaybeBroadcast().catch(() => {});

// SSE endpoint
app.get('/market/stream', async (req, res) => {
  res.set({
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders?.();

  if (!_marketCache.data.length) {
    try { await refreshCacheAndMaybeBroadcast(); } catch {}
  }
  res.write(`event: snapshot\ndata:${JSON.stringify(_marketCache.data)}\n\n`);
  res.write('retry: 10000\n\n'); // client retry

  _sseClients.add(res);
  const ping = setInterval(() => res.write(':\n\n'), 20_000);

  req.on('close', () => {
    clearInterval(ping);
    _sseClients.delete(res);
    try { res.end(); } catch {}
  });
});

// REST endpoint for markets (searchable)
app.get('/market/coins', async (req, res) => {
  try {
    const q = (req.query.q || '').toString().toLowerCase();
    const now = Date.now();
    const ttlMs = 60_000;

    if (now - _marketCache.at > ttlMs) {
      await refreshCacheAndMaybeBroadcast();
    }

    let list = _marketCache.data;
    if (q) {
      list = list.filter(
        (c) =>
          c.id.toLowerCase().includes(q) ||
          c.symbol.toLowerCase().includes(q) ||
          c.name.toLowerCase().includes(q)
      );
    }

    if (!list.length) {
      try {
        const fresh = await fetchMarketSnapshot();
        _marketCache = { at: Date.now(), data: fresh };
        list = fresh;
      } catch {}
    }

    if (!list.length) return res.status(503).json({ error: 'MARKET_UNAVAILABLE' });
    res.json(list);
  } catch (e) {
    console.error('MARKET_ERROR:', e);
    if (_marketCache.data.length) return res.json(_marketCache.data); // serve stale
    res.status(500).json({ error: 'MARKET_ERROR' });
  }
});

/* --------------------------- AI Subscriptions APIs ------------------------- */
// Upsert subscription (locks principal; sets contract & rate)
app.post('/ai/subscriptions', auth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const { fromAddress, symbol, amountUsdt, tokenSymbol = 'USDT', contractDays } = req.body || {};
    if (!/^0x[a-fA-F0-9]{40}$/.test(fromAddress || '')) return res.status(400).json({ error: 'BAD_FROM' });
    if (!symbol || typeof symbol !== 'string') return res.status(400).json({ error: 'BAD_SYMBOL' });
    const amt = Number(amountUsdt);
    if (!Number.isFinite(amt) || amt <= 0) return res.status(400).json({ error: 'BAD_AMOUNT' });
    const days = Number(contractDays);
    if (![7, 15, 30, 60].includes(days)) return res.status(400).json({ error: 'BAD_CONTRACT' });

    // compute spendable (must include active AI locks & profits)
    const [[dep]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status='verified' THEN amount END),0) AS dep_verified
         FROM deposits WHERE user_id=? AND address=? AND token_symbol=?`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[wd]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status IN ('pending','broadcast','confirmed') THEN amount END),0) AS wd_active
         FROM transfers WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[bt]] = await pool.query(
      `SELECT COALESCE(SUM(CASE WHEN status IN ('processing','sent','received') THEN amount_usdt END),0) AS bt_active
         FROM bank_transfers WHERE user_id=? AND from_address=? AND token_symbol=?`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[ai]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS ai_active
         FROM ai_subscriptions WHERE user_id=? AND from_address=? AND token_symbol=? AND status='active'`,
      [uid, fromAddress.toLowerCase(), tokenSymbol]
    );
    const [[pl]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS ai_profit
         FROM ai_profit_ledger WHERE user_id=? AND from_address=?`,
      [uid, fromAddress.toLowerCase()]
    );

    const spendable = Number(dep.dep_verified) - Number(wd.wd_active) - Number(bt.bt_active) - Number(ai.ai_active) + Number(pl.ai_profit);
    if (amt > spendable) return res.status(400).json({ error: 'INSUFFICIENT_FUNDS', spendable });

    const start = todayISO();
    const rate = rateForContractDays(days);
    const end = addDays(start, days - 1);

    // Upsert by (user, address, symbol)
    await pool.query(
      `INSERT INTO ai_subscriptions
         (user_id, from_address, symbol, amount_usdt, token_symbol, contract_days, rate_daily, start_date, end_date, last_credit_date, status)
       VALUES (?,?,?,?,?,?,?,?,?,NULL,'active')
       ON DUPLICATE KEY UPDATE
         amount_usdt=VALUES(amount_usdt),
         contract_days=VALUES(contract_days),
         rate_daily=VALUES(rate_daily),
         start_date=VALUES(start_date),
         end_date=VALUES(end_date),
         last_credit_date=NULL,
         status='active'`,
      [uid, fromAddress.toLowerCase(), symbol.toUpperCase(), amt, tokenSymbol.toUpperCase(), days, rate, start, end]
    );

    res.status(201).json({
      ok: true,
      subscription: {
        symbol: symbol.toUpperCase(),
        amountUsdt: amt,
        tokenSymbol: tokenSymbol.toUpperCase(),
        contractDays: days,
        rateDaily: rate,
        startDate: start,
        endDate: end,
        status: 'active',
      }
    });
  } catch (e) {
    console.error('AI_SUBS_UPSERT_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
});

// List subs (optionally filtered by address)
app.get('/ai/subscriptions', auth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const address = (req.query.address || '').toString().toLowerCase();
    const params = [uid];
    let where = `user_id=?`;
    if (address) { where += ` AND from_address=?`; params.push(address); }
    const [rows] = await pool.query(
      `SELECT symbol, amount_usdt AS amountUsdt, token_symbol AS tokenSymbol,
              contract_days AS contractDays, rate_daily AS rateDaily,
              start_date AS startDate, end_date AS endDate,
              last_credit_date AS lastCreditDate, status
         FROM ai_subscriptions
        WHERE ${where}
        ORDER BY symbol ASC`,
      params
    );
    res.json(rows);
  } catch (e) {
    console.error('AI_SUBS_LIST_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
});

// Pause/cancel/complete
app.patch('/ai/subscriptions/:symbol', auth, async (req, res) => {
  try {
    const uid = req.user.uid;
    const sym = req.params.symbol.toUpperCase();
    const { fromAddress, status } = req.body || {};
    if (!['active','paused','canceled','completed'].includes(status)) {
      return res.status(400).json({ error: 'BAD_STATUS' });
    }
    await pool.query(
      `UPDATE ai_subscriptions SET status=? WHERE user_id=? AND from_address=? AND symbol=?`,
      [status, uid, String(fromAddress || '').toLowerCase(), sym]
    );
    res.json({ ok: true });
  } catch (e) {
    console.error('AI_SUBS_PATCH_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
});

/* ----------------------- AI Profit daily credit worker --------------------- */
/* Catch up missing days up to YESTERDAY only (PH time). Today is handled by realtime worker. */
// Daily catch-up: credits MISSING days up to YESTERDAY; commissions use additive delta
async function processAiProfitDaily() {
  try {
    const { today } = await nowTzMeta();
    const [[y]] = await pool.query(`SELECT DATE_SUB(?, INTERVAL 1 DAY) AS yday`, [today]);
    const yday = String(y.yday);

    const [subs] = await pool.query(
      `SELECT id, user_id AS uid, from_address AS addr, symbol,
              amount_usdt AS amt, rate_daily AS rate,
              start_date AS startDate, end_date AS endDate,
              last_credit_date AS lastDate, status
         FROM ai_subscriptions
        WHERE status='active' AND start_date <= ?`,
      [today]
    );

    for (const s of subs) {
      const end = String(s.endDate);
      let last = s.lastDate ? String(s.lastDate) : null;
      let nextDate = last ? addDays(last, 1) : String(s.startDate);

      // Credit one row per missing day up to YESTERDAY only
      const cap = (yday < end ? yday : end);
      while (nextDate && nextDate <= cap) {
        const credit = Number(s.amt) * Number(s.rate);

        // Insert the missing day; only pay referral delta if we actually inserted
        const [ins] = await pool.query(
          `INSERT IGNORE INTO ai_profit_ledger
             (user_id, from_address, symbol, amount_usdt, day_date)
           VALUES (?,?,?,?,?)`,
          [s.uid, s.addr, s.symbol, credit, nextDate]
        );

        // --- NEW: commissions (additive delta for past days) ---
        if (ins && ins.affectedRows > 0) {
          // add L1=0.5%, L2=0.2% of that day's profit
          await creditReferralDelta(pool, s.uid, nextDate, credit);
        }

        await pool.query(`UPDATE ai_subscriptions SET last_credit_date=? WHERE id=?`, [nextDate, s.id]);
        nextDate = addDays(nextDate, 1);
      }

      // Auto-complete when finished
      if (today > end) {
        await pool.query(`UPDATE ai_subscriptions SET status='completed' WHERE id=?`, [s.id]);
      }
    }
  } catch (e) {
    console.error('AI_PROFIT_PROCESS_ERROR:', e);
  }
}

setInterval(processAiProfitDaily, 60_000);
// --- Add this in index.js ---
async function payReferralCommissionsForDay(day, minAmountUsdt = 0) {
  await pool.query(
    `UPDATE referral_rewards
        SET status='paid', paid_at=NOW()
      WHERE source_day=? AND status='pending' AND amount_usdt >= ?`,
    [day, Number(minAmountUsdt)]
  );
}

let _lastPaidDay = null;
async function referralPayoutCron() {
  // Pay YESTERDAY at ~00:05 PH time
  const { today } = await nowTzMeta();                   // PH date
  const [[y]] = await pool.query(`SELECT DATE_SUB(?, INTERVAL 1 DAY) AS yday`, [today]);
  const yday = String(y.yday);

  // Only run once per day after 00:05
  const [[t]] = await pool.query(
    `SELECT TIME_TO_SEC(TIME(CONVERT_TZ(UTC_TIMESTAMP(), '+00:00', ?))) AS sec`,
    [APP_TZ]
  );
  if (t.sec < 5 * 60) return; // before 00:05 PH, wait

  if (_lastPaidDay === yday) return;
  await payReferralCommissionsForDay(yday, 0); // optional threshold
  _lastPaidDay = yday;
}

// run every 2 minutes
setInterval(referralPayoutCron, 120_000);

/* ----------------------- AI Profit realtime (every few sec) ---------------- */
/* Post today's profit pro-rata into the ledger; idempotent & restart-safe. */
// Realtime: pro-rates TODAY and sets today's commission absolutely (idempotent)
let _rtTicking = false;
async function processAiProfitRealtime() {
  if (_rtTicking) return;
  _rtTicking = true;
  try {
    const { today, frac } = await nowTzMeta();
    if (frac <= 0) return;

    // Active subs whose contract window includes today
    const [subs] = await pool.query(
      `SELECT user_id AS uid, from_address AS addr, symbol,
              amount_usdt AS amt, rate_daily AS rate
         FROM ai_subscriptions
        WHERE status='active' AND start_date <= ? AND end_date >= ?`,
      [today, today]
    );
    if (!subs.length) return;

    // Upsert today's pro-rated profit so far
    const rows = subs.map(s => [
      s.uid,
      s.addr,
      s.symbol,
      (Number(s.amt) * Number(s.rate) * frac).toFixed(18),
      today
    ]);
    const placeholders = rows.map(() => '(?,?,?,?,?)').join(',');

    await pool.query(
      `INSERT INTO ai_profit_ledger (user_id, from_address, symbol, amount_usdt, day_date)
       VALUES ${placeholders}
       ON DUPLICATE KEY UPDATE amount_usdt = VALUES(amount_usdt)`,
      rows.flat()
    );

    // --- NEW: commissions (idempotent absolute for TODAY) ---
    // For each referee (uid), set L1/L2 commissions to (today's profit * rate)
    const uids = [...new Set(subs.map(s => Number(s.uid)))];
    for (const uid of uids) {
      const [[agg]] = await pool.query(
        `SELECT COALESCE(SUM(amount_usdt),0) AS profit
           FROM ai_profit_ledger
          WHERE user_id=? AND day_date=?`,
        [uid, today]
      );
      const totalProfitToday = Number(agg.profit || 0);
      if (totalProfitToday > 0) {
        // sets per-day value (won't double), L1=0.5%, L2=0.2%
        await creditReferralAbsolute(pool, uid, today, totalProfitToday);
      }
    }
  } catch (e) {
    console.error('AI_PROFIT_RT_ERROR:', e);
  } finally {
    _rtTicking = false;
  }
}

// tick every 5s (tune as needed)
setInterval(processAiProfitRealtime, 5_000);

/* ------------------------ AI: Profit Today (for Flutter) ------------------- */
app.get('/ai/profit/today', auth, async (req, res) => {
  try {
    const uid = req.user.uid;
    let address = (req.query.address || '').toString().toLowerCase();
    if (!address) {
      address = await getDefaultAddressForUser(uid);
      if (!address) return res.status(404).json({ error: 'NO_DEFAULT' });
    }
    const { today, frac } = await nowTzMeta();

    const [[expected]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt * rate_daily),0) AS expected
         FROM ai_subscriptions
        WHERE user_id=? AND from_address=? AND status='active'
          AND start_date <= ? AND end_date >= ?`,
      [uid, address, today, today]
    );
    const [[credited]] = await pool.query(
      `SELECT COALESCE(SUM(amount_usdt),0) AS credited
         FROM ai_profit_ledger
        WHERE user_id=? AND from_address=? AND day_date=?`,
      [uid, address, today]
    );

    res.json({
      address,
      day: today,
      fraction: frac,
      expected: Number(expected.expected),   // full-day target
      credited: Number(credited.credited),   // live, ledgered so far
      remaining: Math.max(Number(expected.expected) - Number(credited.credited), 0),
    });
  } catch (e) {
    console.error('AI_PROFIT_TODAY_ERROR:', e);
    res.status(500).json({ error: 'SERVER_ERROR' });
  }
});

/* ---------------------------- json error handler --------------------------- */
app.use((err, _req, res, _next) => {
  if (err) {
    if (err.message === 'ONLY_IMAGES')
      return res
        .status(400)
        .json({ error: 'INVALID_FILE', message: 'Only PNG/JPG/WEBP images are allowed.' });
    if (err.code === 'LIMIT_FILE_SIZE')
      return res.status(413).json({ error: 'FILE_TOO_LARGE', message: 'Max size is 8 MB.' });
    console.error(err);
    return res.status(500).json({ error: 'SERVER_ERROR', message: err.message });
  }
  res.status(500).json({ error: 'SERVER_ERROR' });
});

/* ---------------------------------- start ---------------------------------- */
const PORT = process.env.PORT || 3000;
app.listen(PORT, async () => {
  await ensureSchema();               // your core tables
  await ensureReferralSchema(pool);   // referral tables
  console.log(`API on :${PORT}`);
});

