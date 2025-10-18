// wallet-api/utils/mailer.js
import nodemailer from 'nodemailer';
import dotenv from 'dotenv';
dotenv.config();

const SMTP_HOST = process.env.SMTP_HOST || 'smtp.hostinger.com';
const SMTP_PORT = Number(process.env.SMTP_PORT || 465);
const SMTP_USER = process.env.SMTP_USER;
const SMTP_PASS = process.env.SMTP_PASS;
const APP_BASE_URL = process.env.APP_BASE_URL || 'http://localhost:3000';

// header "From" (what users see)
const FROM_HEADER =
  process.env.SMTP_FROM ||
  process.env.MAIL_FROM ||
  `CryptoAI <${SMTP_USER}>`;

// create transporter
const transporter = nodemailer.createTransport({
  host: SMTP_HOST,
  port: SMTP_PORT,
  secure: SMTP_PORT === 465, // 465 = SSL/TLS, 587 = STARTTLS
  auth: { user: SMTP_USER, pass: SMTP_PASS },
});

export async function verifySmtp() {
  await transporter.verify();
  console.log(`SMTP OK: ${SMTP_HOST}:${SMTP_PORT}`);
}

export async function sendVerifyEmail({ to, name = '', token }) {
  const verifyUrl = `${APP_BASE_URL}/auth/verify?token=${encodeURIComponent(
    token
  )}`;

  const subject = 'Verify your CryptoAI email';
  const text = `Hi ${name},

Please verify your email by opening this link:

${verifyUrl}

If you did not create an account, you can ignore this message.`;

  const html = `
  <div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;line-height:1.4">
    <h2>Verify your email</h2>
    <p>Hi ${name || 'there'}, click the button below to activate your account.</p>
    <p><a href="${verifyUrl}" style="display:inline-block;padding:10px 16px;border-radius:8px;background:#6c5ce7;color:#fff;text-decoration:none">Verify email</a></p>
    <p>Or open this link: <br><a href="${verifyUrl}">${verifyUrl}</a></p>
  </div>`.trim();

  // IMPORTANT: Force envelope sender to the authenticated mailbox
  return transporter.sendMail({
    from: FROM_HEADER,        // header From: CryptoAI <auth@inexify.com>
    to,
    subject,
    text,
    html,
    envelope: { from: SMTP_USER, to }, // SMTP MAIL FROM: <auth@inexify.com>
    sender: SMTP_USER,                  // some providers check this too
    replyTo: SMTP_USER,
  });
}
