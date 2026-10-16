import { createContext, useContext } from 'react';
import { useQuery } from '@tanstack/react-query';
import type { RenderSchema } from '@axel/compiler';
import { http, site } from './api';

export interface SiteSummary {
  id: string; slug: string; name: string; role: string; versionId: string;
  theme?: { primary: string; layout: string }; modules: string[];
}
export type Schema = RenderSchema & { versionId: string };

export const RANK: Record<string, number> = { Public: 0, Member: 1, Manager: 2, Admin: 3 };

export const useSites = () =>
  useQuery({ queryKey: ['sites'], queryFn: () => http.get<SiteSummary[]>('/sites').then(r => r.data) });

export const useSchema = (siteId: string) =>
  useQuery({ queryKey: ['schema', siteId], queryFn: () => site.schema(siteId) as Promise<Schema> });

// Every site-scoped key starts with [entity, siteId] so a switch can never reuse another site's cache.
export const useList = (siteId: string, entity: string, params: Record<string, unknown> = {}, enabled = true) =>
  useQuery({
    queryKey: [entity, siteId, 'list', params],
    queryFn: () => site.get(siteId, `/${entity}`, { limit: 200, ...params }),
    enabled,
  });

export const useRecord = (siteId: string, entity: string, id: string) =>
  useQuery({ queryKey: [entity, siteId, 'one', id], queryFn: () => site.get(siteId, `/${entity}/${id}`) });

export interface SiteCtxValue { siteId: string; slug: string; name: string; base: string; schema: Schema }
export const SiteCtx = createContext<SiteCtxValue | null>(null);
export const useSite = () => {
  const v = useContext(SiteCtx);
  if (!v) throw new Error('useSite used outside a site');
  return v;
};
