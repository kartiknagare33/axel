import { QueryClient } from '@tanstack/react-query';

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
      staleTime: 10_000,
      retry: (n, e: any) => {
        if (e?.message === 'stale-site-response') return false;
        if (e?.response && e.response.status < 500) return false;
        return n < 2;
      },
    },
  },
});
