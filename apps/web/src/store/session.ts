import { create } from 'zustand';
import { persist } from 'zustand/middleware';
import { queryClient } from '../queryClient';

export interface User { id: string; email: string; name: string; hubAdmin: boolean }

// Query keys that are not site-scoped survive a switch; everything else is removed.
const GLOBAL_KEYS = new Set(['sites', 'me']);

interface Session {
  token: string | null;
  user: User | null;
  activeSiteId: string | null;
  preview: string | null;
  generation: number;
  login(token: string, user: User): void;
  logout(): void;
  switchSite(id: string | null, preview?: string | null): void;
}

export const useSession = create<Session>()(persist((set, get) => ({
  token: null,
  user: null,
  activeSiteId: null,
  preview: null,
  generation: 0,
  login: (token, user) => {
    queryClient.clear();
    set({ token, user, activeSiteId: null, preview: null, generation: get().generation + 1 });
  },
  logout: () => {
    queryClient.clear();
    set({ token: null, user: null, activeSiteId: null, preview: null, generation: get().generation + 1 });
  },
  switchSite: (id, preview = null) => {
    if (get().activeSiteId === id && get().preview === preview) return;
    // remove (not invalidate) so no row from the previous site or version can ever paint
    queryClient.removeQueries({ predicate: q => !GLOBAL_KEYS.has(String(q.queryKey[0])) });
    set({ activeSiteId: id, preview, generation: get().generation + 1 });
  },
}), { name: 'axel-session', partialize: s => ({ token: s.token, user: s.user }) as any }));
