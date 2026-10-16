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
  generation: number;
  login(token: string, user: User): void;
  logout(): void;
  switchSite(id: string | null): void;
}

export const useSession = create<Session>()(persist((set, get) => ({
  token: null,
  user: null,
  activeSiteId: null,
  generation: 0,
  login: (token, user) => {
    queryClient.clear();
    set({ token, user, activeSiteId: null, generation: get().generation + 1 });
  },
  logout: () => {
    queryClient.clear();
    set({ token: null, user: null, activeSiteId: null, generation: get().generation + 1 });
  },
  switchSite: id => {
    if (get().activeSiteId === id) return;
    // remove (not invalidate) so no row from the previous site can ever paint
    queryClient.removeQueries({ predicate: q => !GLOBAL_KEYS.has(String(q.queryKey[0])) });
    set({ activeSiteId: id, generation: get().generation + 1 });
  },
}), { name: 'axel-session', partialize: s => ({ token: s.token, user: s.user }) as any }));
