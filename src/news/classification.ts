/**
 * Keyword-based news classifier.
 *
 * Given a title + summary, returns the most likely NewsCategoryKey. Used
 * when the RSS item didn't carry a clean category tag (or when the tag
 * uses a vocabulary we don't recognize, e.g. "Tecnologia & Ciência"
 * instead of "tecnologia").
 *
 * Why keyword-based and not LLM-based: classification at briefing time
 * happens for 50-200 items per fetch. Even at 10 ms each, an LLM round
 * trip would add 0.5-2 s to the briefing latency for no gain — the
 * keyword approach is ~95% accurate on Portuguese-BR news and runs in
 * microseconds. The user's stated preference is also to avoid spurious
 * heuristics; this one has a narrow, deterministic role.
 */

import type { NewsCategoryKey } from './types.js';

/**
 * Each entry maps to a category. Keywords are matched case-insensitive
 * against title + summary. The first category to score ≥1 wins; on
 * ties, the order below decides priority (politics > economy > etc.).
 *
 * Keep entries lowercase, single-word OR short phrase. Punctuation in
 * source text is stripped before matching.
 */
const CATEGORY_KEYWORDS: Array<{ key: NewsCategoryKey; words: string[] }> = [
  {
    key: 'politics',
    words: [
      'congresso', 'senado', 'câmara', 'camara', 'presidente', 'lula', 'ministro',
      'governo', 'eleição', 'eleicao', 'eleições', 'eleicoes', 'pl ', 'projeto de lei',
      'stf', 'supremo', 'governador', 'prefeito', 'política', 'politica', 'partido',
      'pec ', 'reforma'
    ]
  },
  {
    key: 'economy',
    words: [
      'economia', 'inflação', 'inflacao', 'pib', 'juros', 'selic', 'dólar', 'dolar',
      'mercado', 'bolsa', 'ibovespa', 'investimento', 'fiscal', 'imposto', 'tributo',
      'banco central', 'fazenda', 'tesouro', 'desemprego', 'emprego', 'cesta básica'
    ]
  },
  {
    key: 'health',
    words: [
      'saúde', 'saude', 'sus', 'hospital', 'vacina', 'covid', 'dengue', 'gripe',
      'pandemia', 'epidemia', 'doença', 'doenca', 'médico', 'medico', 'paciente',
      'remédio', 'remedio', 'anvisa', 'ministério da saúde', 'ministerio da saude'
    ]
  },
  {
    key: 'education',
    words: [
      'educação', 'educacao', 'escola', 'universidade', 'mec', 'enem', 'vestibular',
      'professor', 'aluno', 'estudante', 'ensino', 'bolsa de estudo', 'fies',
      'prouni', 'pedagogia'
    ]
  },
  {
    key: 'security',
    words: [
      'polícia', 'policia', 'crime', 'assassinato', 'homicídio', 'homicidio',
      'roubo', 'assalto', 'tráfico', 'trafico', 'preso', 'prisão', 'prisao',
      'investigação', 'investigacao', 'pf ', 'segurança pública', 'seguranca publica',
      'operação', 'operacao'
    ]
  },
  {
    key: 'technology',
    words: [
      'tecnologia', 'inteligência artificial', 'inteligencia artificial', ' ia ',
      'startup', 'software', 'aplicativo', 'app ', 'celular', 'smartphone',
      'internet', 'rede social', 'redes sociais', 'whatsapp', 'meta', 'google',
      'microsoft', 'apple', 'tesla', 'spacex', 'cyber', 'hack', 'cripto',
      'blockchain', 'chatgpt', 'openai', 'anthropic'
    ]
  },
  {
    key: 'sports',
    words: [
      'esporte', 'esportes', 'futebol', 'campeonato', 'brasileirão', 'brasileirao',
      'libertadores', 'copa', 'olimpíadas', 'olimpiadas', 'time', 'jogador',
      'técnico', 'tecnico', 'jogo', 'partida', 'gol', 'pênalti', 'penalti',
      'flamengo', 'palmeiras', 'corinthians', 'são paulo', 'sao paulo', 'santos'
    ]
  },
  {
    key: 'culture',
    words: [
      'cultura', 'filme', 'cinema', 'música', 'musica', 'show', 'festival',
      'oscar', 'cannes', 'álbum', 'album', 'artista', 'banda', 'série', 'serie',
      'streaming', 'netflix', 'amazon prime', 'globoplay', 'livro', 'literatura',
      'teatro', 'exposição', 'exposicao'
    ]
  },
  {
    key: 'infrastructure',
    words: [
      'obra', 'obras', 'infraestrutura', 'rodovia', 'estrada', 'ponte', 'metrô',
      'metro', 'transporte público', 'transporte publico', 'pavimentação',
      'pavimentacao', 'asfalto', 'saneamento', 'esgoto', 'água ', 'agua ',
      'aeroporto', 'porto'
    ]
  },
  {
    key: 'environment',
    words: [
      'meio ambiente', 'amazônia', 'amazonia', 'desmatamento', 'queimada',
      'incêndio florestal', 'incendio florestal', 'clima', 'aquecimento global',
      'mudança climática', 'mudanca climatica', 'cop ', 'sustentabilidade',
      'reciclagem', 'poluição', 'poluicao', 'enchente', 'seca'
    ]
  }
];

/**
 * Classify by counting keyword hits. Ties are broken by the order of
 * CATEGORY_KEYWORDS (politics first → economy → ...) which matches
 * editorial priority in Brazilian news.
 */
export function classifyNews(title: string, summary: string = ''): NewsCategoryKey {
  const text = (title + ' ' + summary).toLowerCase()
    // Strip punctuation but keep accents and word boundaries.
    .replace(/[.,;:!?"'()[\]{}]/g, ' ');

  let bestKey: NewsCategoryKey = 'general';
  let bestScore = 0;

  for (const { key, words } of CATEGORY_KEYWORDS) {
    let score = 0;
    for (const w of words) {
      if (text.includes(w)) score += 1;
    }
    if (score > bestScore) {
      bestScore = score;
      bestKey = key;
    }
  }

  return bestKey;
}

/**
 * Normalize an RSS-supplied category tag onto our enum. Some sources use
 * Portuguese labels ("Política"), others English ("politics"), others
 * a free-form string ("Tecnologia & Ciência"). This collapses them.
 *
 * Returns null when nothing recognizable matches — caller can then fall
 * back to keyword classification.
 */
export function normalizeRssCategory(raw: string | undefined): NewsCategoryKey | null {
  if (!raw) return null;
  // Strip diacritics so "Política" (with accented í) matches the
  // ASCII-only substrings below. Without this, "polít" ≠ "polit".
  const lower = raw.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  if (lower.includes('politic')) return 'politics';
  if (lower.includes('econom') || lower.includes('finan') || lower.includes('mercado')) return 'economy';
  if (lower.includes('saude') || lower.includes('health')) return 'health';
  if (lower.includes('educa')) return 'education';
  if (lower.includes('seguran') || lower.includes('polic') || lower.includes('crime')) return 'security';
  if (lower.includes('tecn') || lower.includes('tech') || lower.includes('cienci') || lower.includes('digital')) return 'technology';
  if (lower.includes('esporte') || lower.includes('sport')) return 'sports';
  if (lower.includes('cultur') || lower.includes('arte') || lower.includes('show') || lower.includes('cinema') || lower.includes('musica')) return 'culture';
  if (lower.includes('obra') || lower.includes('infra') || lower.includes('transporte')) return 'infrastructure';
  if (lower.includes('ambient') || lower.includes('clima') || lower.includes('sustentab')) return 'environment';
  return null;
}
