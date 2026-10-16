import { AxelError } from './errors';

// MiniMoth OTP (https://minimoth.dev/docs): POST /v1/otp/send { phone }, POST /v1/otp/verify { phone, code }.
// We use the "OTP-only" recipe: MiniMoth proves the phone, Axel issues its own session JWT.
const BASE = process.env.MINIMOTH_BASE_URL ?? 'https://api.minimoth.dev';
const key = () => (process.env.MINIMOTH_API_KEY ?? '').trim();
const PLACEHOLDER = /^\+919000000\d{3}$/;

export const otpEnabled = () => key().length > 0;
export const otpMode = () => (key().startsWith('mm_test_') ? 'test' : key().startsWith('mm_live_') ? 'live' : key() ? 'unknown' : 'off');
export const maskPhone = (p: string) => (p.length > 6 ? `${p.slice(0, 3)} ******${p.slice(-4)}` : '******');

const MESSAGES: Record<string, [number, string]> = {
  OTP_RATE_LIMITED: [429, 'Too many codes were sent to this number. Wait 10 minutes and try again.'],
  INSUFFICIENT_BALANCE: [402, 'The OTP wallet is empty. Top up at app.minimoth.dev.'],
  INVALID_PHONE: [422, 'The mobile number on this account is not valid.'],
  SMS_FAILED: [502, 'The code could not be delivered on WhatsApp or SMS. Try again in a moment.'],
  INVALID_OTP: [400, 'That code is not right. Check it and try again.'],
  OTP_NOT_FOUND: [400, 'That code has expired or was already used. Send a new one.'],
  VERIFY_RATE_LIMITED: [429, 'Too many wrong attempts. Send a new code.'],
  INVALID_OTP_CODE: [422, 'Enter the 6-digit code.'],
  INVALID_API_KEY: [500, 'The OTP service key is not valid. Check MINIMOTH_API_KEY in .env.'],
  MISSING_API_KEY: [500, 'MINIMOTH_API_KEY is missing in .env.'],
  RATE_LIMITED: [429, 'The OTP service is busy. Try again in a minute.'],
};

async function call(path: string, body: unknown) {
  let r: Response;
  try {
    r = await fetch(BASE + path, { method: 'POST', headers: { 'X-Api-Key': key(), 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  } catch {
    throw new AxelError('OTP_UNAVAILABLE', 503, 'Could not reach the OTP service. Check the internet connection.');
  }
  const data: any = await r.json().catch(() => ({}));
  if (!r.ok) {
    const code = data?.code ?? 'OTP_ERROR';
    const [status, message] = MESSAGES[code] ?? [r.status >= 500 ? 502 : 400, data?.error ?? 'The OTP service returned an error.'];
    throw new AxelError(code, status, message, { provider: 'minimoth' });
  }
  return data;
}

export async function sendOtp(phone: string): Promise<{ otp_id: string; expires_at: string }> {
  if (otpMode() === 'live' && PLACEHOLDER.test(phone))
    throw new AxelError('OTP_PHONE_PLACEHOLDER', 400, 'This demo account only has a placeholder number. Set OTP_REQUIRED=admins for live mode, or give it a real number with pnpm set-phone.');
  return call('/v1/otp/send', { phone });
}

export async function verifyOtp(phone: string, code: string) {
  return call('/v1/otp/verify', { phone, code });
}
