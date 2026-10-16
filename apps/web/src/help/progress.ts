import { useEffect, useState } from 'react';

// First-steps progress, kept in this browser. Steps tick themselves as the user does them.
const KEY = 'axel-onboarding';
export type Step = 'openedUnit' | 'movedRequest' | 'usedExcel' | 'triedHelp' | 'openedBuilder' | 'ranGate' | 'published';

const read = (): Record<string, boolean> => {
  try { return JSON.parse(localStorage.getItem(KEY) ?? '{}'); } catch { return {}; }
};

export function markDone(step: Step) {
  const s = read();
  if (s[step]) return;
  s[step] = true;
  localStorage.setItem(KEY, JSON.stringify(s));
  window.dispatchEvent(new Event('axel-progress'));
}

export function resetProgress() {
  localStorage.removeItem(KEY);
  localStorage.removeItem(`${KEY}-hidden`);
  window.dispatchEvent(new Event('axel-progress'));
}

export function useProgress() {
  const [s, setS] = useState(read);
  useEffect(() => {
    const f = () => setS(read());
    window.addEventListener('axel-progress', f);
    window.addEventListener('storage', f);
    return () => { window.removeEventListener('axel-progress', f); window.removeEventListener('storage', f); };
  }, []);
  return s;
}
