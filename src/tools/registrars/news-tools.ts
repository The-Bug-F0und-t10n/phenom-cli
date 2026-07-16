import type { Tool } from '../../tools.js';
import { runNewsBriefingUseCase } from '../../use-cases/news-briefing.js';
import { PreferencesStore, isValidCategory, type NewsPreferences } from '../../news/preferences.js';
import type { NewsCategoryKey } from '../../news/types.js';

interface RegisterNewsToolsDeps {
  register: (tool: Tool) => void;
}

/**
 * News + civic-briefing tools.
 *
 * Currently exposes one tool: `get_civic_briefing` — wraps the briefing
 * use case so the model can pull weather + air-quality + public-health
 * for any city the user mentions. Returns the rendered newspaper view as
 * tool output, which the renderer in the CLI prints verbatim.
 */
export function registerNewsTools(deps: RegisterNewsToolsDeps): void {
  const { register } = deps;

  // ── get_civic_briefing ──────────────────────────────────────────
  register({
    name: 'get_civic_briefing',
    description: 'Civic + news briefing for a Brazilian city. Returns weather forecast, air quality, public-health alerts, and categorized news headlines from public RSS feeds. Output is a formatted text block with critical alerts on top. Call this ONLY when the user has explicitly asked for a city briefing, weather report, air-quality check, or news digest in the current message. Do NOT call it as a side-task or when the user merely greets you.',
    parameters: {
      type: 'object',
      properties: {
        city: {
          type: 'string',
          description: 'City name supplied by the user in the current message. Diacritics and case are ignored. If the user did not name a city in this message and a defaultCity is saved in preferences, that one is used; otherwise the call fails — do NOT invent a city.'
        },
        bypassCache: {
          type: 'boolean',
          description: 'Force a fresh fetch even if the cached briefing is still warm. Default false.'
        },
        includeNews: {
          type: 'boolean',
          description: 'Include RSS news headlines alongside civic data. Default true. Set to false for a fast civic-only briefing.'
        },
        itemsPerCategory: {
          type: 'number',
          description: 'Max news items per category. Default 5. Use a higher value for an extended briefing.'
        },
        width: {
          type: 'number',
          description: 'Render width in columns. Default uses the terminal width.'
        }
      },
      required: []
    },
    execute: async (args) => {
      let city = String(args.city || '').trim();
      const store = new PreferencesStore();
      if (!city) {
        const prefs = await store.load();
        if (prefs.defaultCity) city = prefs.defaultCity;
      }
      if (!city) {
        return { success: false, output: '', error: 'get_civic_briefing requer "city" ou um defaultCity salvo via set_news_preferences.' };
      }

      try {
        const widthRaw = Number(args.width);
        const itemsRaw = Number(args.itemsPerCategory);
        const result = await runNewsBriefingUseCase(city, {
          bypassCache: Boolean(args.bypassCache),
          includeNews: args.includeNews !== false,
          itemsPerCategory: Number.isFinite(itemsRaw) ? itemsRaw : undefined,
          render: Number.isFinite(widthRaw) ? { width: widthRaw } : undefined,
          preferences: store
        });

        const civicCount = result.briefing.civic.reduce((acc, c) => acc + c.alerts.length, 0);
        const newsCount = result.briefing.news.reduce((acc, c) => acc + c.items.length, 0);
        const cacheMark = result.fromCache ? ' [cache]' : '';
        const summary = `[CIVIC_BRIEFING] ${city} · ${civicCount} alerta(s) · ${newsCount} notícia(s)${cacheMark}`;

        return {
          success: true,
          output: `${summary}\n\n${result.rendered}`,
          error: null
        };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'get_civic_briefing failed' };
      }
    }
  });

  // ── get_news_preferences ────────────────────────────────────────
  register({
    name: 'get_news_preferences',
    description: 'Read the user\'s saved news preferences: default city, categories of interest, blocked categories/sources, language. Use this BEFORE setting preferences to know the current state, or to show the user what is configured.',
    parameters: {
      type: 'object',
      properties: {},
      required: []
    },
    execute: async () => {
      try {
        const store = new PreferencesStore();
        const prefs = await store.load();
        return {
          success: true,
          output: formatPreferences(prefs),
          error: null
        };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'get_news_preferences failed' };
      }
    }
  });

  // ── set_news_preferences ────────────────────────────────────────
  register({
    name: 'set_news_preferences',
    description: 'Modify the user\'s saved news preferences. Operations: "set_default_city" (city), "add_interest" / "remove_interest" (category), "block_category" / "unblock_category" (category), "block_source" / "unblock_source" (source name), "set_language" (pt|en). Only ONE operation per call. Preferences persist across sessions in .phenom-data/news-preferences.json.',
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          description: 'One of: set_default_city, add_interest, remove_interest, block_category, unblock_category, block_source, unblock_source, set_language, clear.'
        },
        value: {
          type: 'string',
          description: 'Value for the action. Category keys: politics, health, education, sports, economy, culture, security, technology, infrastructure, environment, general. Language: pt or en. City: free-form name supplied by the user. Source: free-form name of an RSS source supplied by the user.'
        }
      },
      required: ['action']
    },
    execute: async (args) => {
      const action = String(args.action || '').trim().toLowerCase();
      const value = String(args.value || '').trim();

      try {
        const store = new PreferencesStore();
        const current = await store.load();
        const next: NewsPreferences = JSON.parse(JSON.stringify(current));

        const requireCategory = (): NewsCategoryKey | null => {
          if (!isValidCategory(value)) return null;
          return value;
        };

        switch (action) {
          case 'set_default_city':
            if (!value) return { success: false, output: '', error: 'set_default_city requer value (nome da cidade).' };
            next.defaultCity = value;
            break;
          case 'clear':
            next.defaultCity = undefined;
            next.categoriesOfInterest = [];
            next.blockedCategories = [];
            next.preferredSources = [];
            next.blockedSources = [];
            break;
          case 'add_interest': {
            const cat = requireCategory();
            if (!cat) return { success: false, output: '', error: `Categoria inválida: "${value}". Use: politics, health, education, sports, economy, culture, security, technology, infrastructure, environment, general.` };
            if (!next.categoriesOfInterest.includes(cat)) next.categoriesOfInterest.push(cat);
            // Remove from blocked if it was there.
            next.blockedCategories = next.blockedCategories.filter(c => c !== cat);
            break;
          }
          case 'remove_interest': {
            const cat = requireCategory();
            if (!cat) return { success: false, output: '', error: `Categoria inválida: "${value}".` };
            next.categoriesOfInterest = next.categoriesOfInterest.filter(c => c !== cat);
            break;
          }
          case 'block_category': {
            const cat = requireCategory();
            if (!cat) return { success: false, output: '', error: `Categoria inválida: "${value}".` };
            if (!next.blockedCategories.includes(cat)) next.blockedCategories.push(cat);
            next.categoriesOfInterest = next.categoriesOfInterest.filter(c => c !== cat);
            break;
          }
          case 'unblock_category': {
            const cat = requireCategory();
            if (!cat) return { success: false, output: '', error: `Categoria inválida: "${value}".` };
            next.blockedCategories = next.blockedCategories.filter(c => c !== cat);
            break;
          }
          case 'block_source':
            if (!value) return { success: false, output: '', error: 'block_source requer value (nome da fonte).' };
            if (!next.blockedSources.includes(value)) next.blockedSources.push(value);
            break;
          case 'unblock_source':
            if (!value) return { success: false, output: '', error: 'unblock_source requer value.' };
            next.blockedSources = next.blockedSources.filter(s => s !== value);
            break;
          case 'set_language':
            if (value !== 'pt' && value !== 'en') return { success: false, output: '', error: 'set_language requer "pt" ou "en".' };
            next.language = value;
            break;
          default:
            return {
              success: false,
              output: '',
              error: `Action desconhecida: "${action}". Use uma destas: set_default_city, add_interest, remove_interest, block_category, unblock_category, block_source, unblock_source, set_language, clear.`
            };
        }

        await store.save(next);
        return {
          success: true,
          output: `[PREFERENCES_UPDATED] action=${action}` + (value ? ` value="${value}"` : '') + '\n\n' + formatPreferences(next),
          error: null
        };
      } catch (error: any) {
        return { success: false, output: '', error: error?.message || 'set_news_preferences failed' };
      }
    }
  });
}

// ── formatPreferences ──────────────────────────────────────────────────

function formatPreferences(p: NewsPreferences): string {
  const lines: string[] = ['[NEWS_PREFERENCES]'];
  lines.push(`defaultCity: ${p.defaultCity || '(não definido)'}`);
  lines.push(`language: ${p.language}`);
  lines.push(`categoriesOfInterest: ${p.categoriesOfInterest.length > 0 ? p.categoriesOfInterest.join(', ') : '(nenhuma — todas vêm em ordem natural)'}`);
  lines.push(`blockedCategories: ${p.blockedCategories.length > 0 ? p.blockedCategories.join(', ') : '(nenhuma)'}`);
  lines.push(`blockedSources: ${p.blockedSources.length > 0 ? p.blockedSources.join(', ') : '(nenhuma)'}`);
  return lines.join('\n');
}
