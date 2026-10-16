const API = process.env.API_URL ?? 'http://localhost:4000/api';

// Finishes a login: returns the session token, completing the MiniMoth OTP step if the server asks for it.
// Tests must run with a mm_test_ key, where the code is always 000000 (override with TEST_OTP_CODE).
export async function finishLogin(r: Response): Promise<string> {
  const body: any = await r.json();
  if (body.token) return body.token;
  if (!body.otpRequired) throw new Error(`login failed: ${JSON.stringify(body)}`);
  const v = await fetch(`${API}/auth/verify-otp`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ challenge: body.challenge, code: process.env.TEST_OTP_CODE ?? '000000' }),
  });
  const vb: any = await v.json();
  if (!vb.token) throw new Error(`OTP step failed (run tests with a mm_test_ key): ${JSON.stringify(vb)}`);
  return vb.token;
}
