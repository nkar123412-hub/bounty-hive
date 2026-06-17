import { Request, Response, NextFunction } from 'express';
import crypto from 'crypto';
import { prisma } from '../lib/prisma';

interface TelegramUser {
  id: number;
  first_name: string;
  last_name?: string;
  username?: string;
  photo_url?: string;
}

function validateTelegramHash(initData: string, botToken: string): boolean {
  const params = new URLSearchParams(initData);
  const hash = params.get('hash');
  if (!hash) return false;

  params.delete('hash');
  const checkString = [...params.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => `${k}=${v}`)
    .join('\n');

  const secret = crypto.createHmac('sha256', 'WebAppData').update(botToken).digest();
  const checkHash = crypto.createHmac('sha256', secret).update(checkString).digest('hex');

  try {
    return crypto.timingSafeEqual(Buffer.from(checkHash, 'hex'), Buffer.from(hash, 'hex'));
  } catch {
    return false;
  }
}

export async function telegramAuth(req: Request, res: Response, next: NextFunction) {
  // Read operations are public — no auth needed
  if (req.method === 'GET') return next();

  const initData = req.headers['x-telegram-init-data'] as string | undefined;
  const tonAddress = req.headers['x-ton-address'] as string | undefined;

  // Development bypass
  if (process.env.NODE_ENV === 'development' && !initData && !tonAddress) {
    // Ensure dev user exists in DB
    const devUser = await prisma.user.upsert({
      where: { id: 'dev-user' },
      update: {},
      create: { id: 'dev-user', telegramId: '0', username: 'dev', displayName: 'Dev User' },
    });
    req.user = { id: devUser.id, telegramId: '0', username: devUser.username ?? undefined, displayName: devUser.displayName ?? undefined };
    return next();
  }

  // Chrome / browser users: TON wallet address as identity
  }

  if (!initData) {
    return res.status(401).json({ error: 'Authentication required' });
  }

  try {
    const botToken = process.env.TELEGRAM_BOT_TOKEN;
    if (botToken && process.env.NODE_ENV !== 'development') {
      if (!validateTelegramHash(initData, botToken)) {
        return res.status(401).json({ error: 'Invalid Telegram auth' });
      }
    }

    const params = new URLSearchParams(initData);
    const userJson = params.get('user');
    if (!userJson) return res.status(401).json({ error: 'Missing user in auth data' });

    const tgUser: TelegramUser = JSON.parse(userJson);
    const telegramId = String(tgUser.id);

    // Upsert Telegram user in DB
    const user = await prisma.user.upsert({
      where: { telegramId },
      update: {
        username: tgUser.username,
        displayName: tgUser.first_name + (tgUser.last_name ? ` ${tgUser.last_name}` : ''),
        avatarUrl: tgUser.photo_url,
      },
      create: {
        telegramId,
        username: tgUser.username,
        displayName: tgUser.first_name + (tgUser.last_name ? ` ${tgUser.last_name}` : ''),
        avatarUrl: tgUser.photo_url,
      },
    });

    req.user = {
      id: user.id,
      telegramId: user.telegramId ?? '',
      username: user.username ?? undefined,
      displayName: user.displayName ?? undefined,
      avatarUrl: user.avatarUrl ?? undefined,
    };
    next();
  } catch {
    return res.status(401).json({ error: 'Invalid auth data' });
  }
}

declare global {
  namespace Express {
    interface Request {
      user?: {
        id: string;
        telegramId: string;
        username?: string;
        displayName?: string;
        avatarUrl?: string;
      };
    }
  }
}
