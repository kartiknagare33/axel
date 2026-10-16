import axios from 'axios';
import { useSession } from './store/session';

export const STALE = 'stale-site-response';
export const http = axios.create({ baseURL: '/api' });

http.interceptors.request.use(cfg => {
  const t = useSession.getState().token;
  if (t) cfg.headers.set('Authorization', `Bearer ${t}`);
  return cfg;
});
http.interceptors.response.use(r => r, e => {
  if (e.response?.status === 401 && !String(e.config?.url).includes('/auth/login')) useSession.getState().logout();
  return Promise.reject(e);
});

const h = (siteId: string) => ({ headers: { 'X-Site-Id': siteId } });

// Discard any response that started before a site switch.
async function guard<T>(p: () => Promise<T>): Promise<T> {
  const g = useSession.getState().generation;
  const r = await p();
  if (useSession.getState().generation !== g) throw new Error(STALE);
  return r;
}

export const site = {
  get: <T = any>(siteId: string, path: string, params?: object) =>
    guard(() => http.get<T>(`/${siteId}${path}`, { ...h(siteId), params }).then(r => r.data)),
  post: <T = any>(siteId: string, path: string, body?: unknown) =>
    http.post<T>(`/${siteId}${path}`, body, h(siteId)).then(r => r.data),
  patch: <T = any>(siteId: string, path: string, body?: unknown) =>
    http.patch<T>(`/${siteId}${path}`, body, h(siteId)).then(r => r.data),
  schema: (siteId: string) =>
    guard(() => http.get(`/sites/${siteId}/render-schema`, h(siteId)).then(r => r.data)),
};

export interface ApiErr {
  message: string; code?: string;
  errors?: { field: string; message: string }[];
  because?: Record<string, unknown>; suggestion?: string;
}
export const errOf = (e: any): ApiErr => ({
  message: e?.response?.data?.message ?? e?.message ?? 'Something went wrong.',
  code: e?.response?.data?.code,
  errors: e?.response?.data?.errors,
  because: e?.response?.data?.because,
  suggestion: e?.response?.data?.suggestion,
});
