import type { ErrorRequestHandler, RequestHandler } from 'express';
import { ZodError } from 'zod';

export class AxelError extends Error {
  constructor(public code: string, public status: number, message: string, public extra: Record<string, unknown> = {}) {
    super(message);
  }
}
export const notFound = () => new AxelError('NOT_FOUND', 404, 'Not found.');

export const ah = (fn: (...a: Parameters<RequestHandler>) => Promise<unknown>): RequestHandler =>
  (req, res, next) => fn(req, res, next).catch(next);

export const errorHandler: ErrorRequestHandler = (err, _req, res, _next) => {
  if (err instanceof AxelError) return res.status(err.status).json({ code: err.code, message: err.message, ...err.extra });
  if (err instanceof ZodError) {
    const unknown = err.issues.flatMap(i => (i.code === 'unrecognized_keys' ? i.keys : []));
    if (unknown.length)
      return res.status(422).json({ code: 'FIELD_NOT_WRITABLE', message: `You can't set ${unknown.join(', ')} here.`, fields: unknown });
    return res.status(422).json({
      code: 'VALIDATION_FAILED', message: 'Some fields need attention.',
      errors: err.issues.map(i => ({ field: i.path.join('.'), message: i.message })),
    });
  }
  switch (err?.code) {
    case '23503': return res.status(422).json({ code: 'VALIDATION_FAILED', message: 'A referenced record does not exist in this site.' });
    case '23505': return res.status(409).json({ code: 'DUPLICATE', message: 'A record with that value already exists in this site.' });
    case '23514': return res.status(422).json({ code: 'LAW_VIOLATION', message: 'That change would break a stock rule (on-hand or reserved).', constraint: err.constraint });
    case '22P02': return res.status(404).json({ code: 'NOT_FOUND', message: 'Not found.' });
    case '42501': return res.status(404).json({ code: 'NOT_FOUND', message: 'Not found.' });
  }
  console.error(err);
  res.status(500).json({ code: 'INTERNAL', message: 'Something went wrong.' });
};
